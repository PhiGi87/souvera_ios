// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from souvera_android link/ui/LinkViewModel.kt + LinkUiState.kt + LinkRoute.kt.
//
// Drives the native "Link" (Nextcloud Talk) chat: loads the conversation list, opens a chat, and
// keeps it live via the Talk chat long-poll (lookIntoFuture=1, 30s). Auth is the account
// app-password — the same credential the rest of the app uses.

import Foundation
import Combine

extension Notification.Name {
    /// Posted whenever the active call state changes (started/ended).
    static let linkCallStateChanged = Notification.Name("SouveraLinkCallStateChanged")
    /// Posted with the total number of unread messages (Link tab badge).
    static let linkUnreadChanged = Notification.Name("SouveraLinkUnreadChanged")
}

/// Loading/content/error state for a Link screen's data.
enum LinkUiState<T> {
    case loading
    case success(T)
    case error(String)
}

/// Which Link screen is showing.
enum LinkRoute: Equatable {
    case home
    case chat(token: String, title: String)
}

@MainActor
final class LinkViewModel: ObservableObject {
    /// Room requested by another module while the Link tab was not visible;
    /// opened on the next appearance.
    static var pendingOpenRoom: (token: String, title: String)?

    @Published var actionFeedback: LinkActionFeedback?

    @Published var route: LinkRoute = .home
    @Published var conversations: LinkUiState<[LinkConversation]> = .loading
    @Published var messages: LinkUiState<[LinkChatMessage]> = .loading
    @Published var userResults: [LinkSuggestion] = []
    /// In-Memory-Avatar-Cache (URL -> Bilddaten) für Raum- und Nutzer-Avatare.
    @Published var avatarCache: [String: Data] = [:]
    /// Offline-Hinweis (Server nicht erreichbar - Cache-Stand wird gezeigt).
    @Published var offlineNotice: String?
    /// Gibt es ältere Nachrichten im Verlauf (Scroll-Nachladen oben)?
    @Published var hasMoreHistory = false
    /// Erste ungelesene Nachricht (id > lastReadMessage) - Basis für die
    /// "Neue Nachrichten"-Trennlinie und die Eintrittsposition.
    @Published private(set) var unreadBoundary: Int64?
    /// true, sobald der User bis zu den neuesten Nachrichten gescrollt hat -
    /// die Trennlinie wird ausgeblendet, der Read-Marker gesetzt.
    @Published private(set) var hideUnreadSeparator = false
    /// Transienter Trigger für den "Server-Error: Cache aktiv"-Banner.
    @Published var cacheBannerActive = false

    private(set) var currentUserId: String = ""

    /// Push-Deep-Link-Beobachter (Chat-Raum direkt öffnen).
    private var deepLinkObserver: NSObjectProtocol?

    init() {
        deepLinkObserver = NotificationCenter.default.addObserver(
            forName: SouveraPushDeepLink.opened,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let target = notification.object as? SouveraPushDeepLink.Target else { return }
            Task { @MainActor [weak self] in
                self?.handleDeepLink(target)
            }
        }
    }

    private func handleDeepLink(_ target: SouveraPushDeepLink.Target) {
        switch target.kind {
        case .room:
            openConversation(token: target.token, title: target.title)
        default:
            break
        }
    }

    private var api: LinkOcsApi?
    private var pollTask: Task<Void, Never>?
    private var lastMessageId: Int64 = 0
    private let cacheBannerGate = SouveraCacheBannerGate()

    private let pollTimeout = 30
    private let historyAnchor: Int64 = 2_000_000_000

    /// Resolves the active account and loads the conversation list. Idempotent.
    func start() {
        if api == nil {
            guard let account = LinkAccount.active() else {
                conversations = .error("No account")
                return
            }
            currentUserId = account.username
            api = LinkOcsApi(account: account)
            NotificationCenter.default.addObserver(forName: .linkRoomsChanged, object: nil, queue: .main) { [weak self] _ in
                self?.loadConversations()
            }
            // Badge-Poll meldet neue Ungelesen-Zahlen: Liste live
            // aktualisieren, damit die Kanal-Badges sofort mitzählen.
            NotificationCenter.default.addObserver(forName: .linkUnreadChanged, object: nil, queue: .main) { [weak self] _ in
                self?.loadConversations()
            }
        }
        // Bei jedem Erscheinen des Tabs frisch laden, damit aus dem Kalender
        // erstellte Channels sofort sichtbar sind.
        loadConversations()
    }

    func searchUsers(query: String) {
        guard let api else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            userResults = []
            return
        }
        Task {
            let results = await api.searchUsers(query: trimmed)
            var all = results
            // Unbekannte E-Mail-Adresse: externen Nutzer einladen anbieten
            // (Federation, falls serverseitig aktiv, sonst Gast per E-Mail).
            if trimmed.contains("@"),
               !results.contains(where: { $0.id.lowercased() == trimmed.lowercased() }) {
                let source = await api.isFederationOutgoingEnabled() ? "federated" : "email_guest"
                all.append(LinkSuggestion(
                    id: trimmed,
                    label: String(format: NSLocalizedString("_link_chat_external_", comment: ""), trimmed),
                    source: source
                ))
            }
            self.userResults = all
        }
    }

    /// Erstellt einen eigenen freien Channel (Gruppenkonversation).
    func createChannel(name: String) {
        guard let api else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            guard let token = await api.createGroupRoom(name: trimmed) else {
                actionFeedback = LinkActionFeedback(
                    success: false,
                    message: NSLocalizedString("_link_channel_create_failed_", comment: "")
                )
                return
            }
            loadConversations()
            openConversation(token: token, title: trimmed)
            actionFeedback = LinkActionFeedback(
                success: true,
                message: NSLocalizedString("_link_channel_created_", comment: "")
            )
        }
    }

    /// Fügt dem geöffneten Channel einen Teilnehmer hinzu (nur mit
    /// Owner-/Moderator-Recht; die Oberfläche blendet den Button sonst aus).
    func addParticipant(_ suggestion: LinkSuggestion) {
        guard let api, let room = currentRoom else { return }
        let isExternal = suggestion.source == "email_guest" || suggestion.source == "federated"
        Task {
            switch suggestion.source {
            case "federated":
                await api.addParticipants(token: room.token, userIds: [], emails: [], federatedIds: [suggestion.id])
            case "email_guest":
                await api.addParticipants(token: room.token, userIds: [], emails: [suggestion.id])
            default:
                await api.addParticipants(token: room.token, userIds: [suggestion.id], emails: [])
            }
            userResults = []
            actionFeedback = LinkActionFeedback(
                success: true,
                message: String(format: NSLocalizedString("_link_participant_added_", comment: ""), suggestion.label)
            )
            if isExternal {
                // Externe Gäste: Raum öffentlich schalten (Beitritt über den
                // Link) und Lobby aktivieren - dann Link-Angebot zeigen.
                if room.type != 3 {
                    await api.makeRoomPublic(token: room.token)
                }
                await api.setLobby(token: room.token, enabled: true)
                let root = accountBaseUrl()
                externalInviteContext = ExternalInviteContext(
                    title: suggestion.label,
                    link: "\(root)/index.php/call/\(room.token)"
                )
            }
        }
    }

    private func accountBaseUrl() -> String {
        LinkAccount.active()?.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
    }

    /// Kontext für das "Externer Teilnehmer eingeladen"-Sheet.
    struct ExternalInviteContext: Identifiable {
        let title: String
        let link: String
        var id: String { link }
    }

    @Published var externalInviteContext: ExternalInviteContext?

    /// Lädt die Teilnehmerliste des geöffneten Channels.
    func loadParticipants() {
        guard let api, case let .chat(token, _) = route else { return }
        Task {
            let list = await api.listParticipants(token: token)
            // Geister ("Gelöschter Benutzer") ausblenden: Sessions ohne
            // gültigen Akteurstyp tauchen nicht in der Teilnehmerliste auf.
            self.participants = list.filter { $0.actorType != "deleted_users" }
        }
    }

    /// Entfernt einen Teilnehmer (Moderator-Recht erforderlich).
    func removeParticipant(_ participant: LinkParticipant) {
        guard let api, case let .chat(token, _) = route else { return }
        Task {
            let ok = await api.removeParticipant(token: token, attendeeId: participant.attendeeId)
            if ok {
                actionFeedback = LinkActionFeedback(
                    success: true,
                    message: String(format: NSLocalizedString("_link_participant_removed_", comment: ""), participant.displayName)
                )
                loadParticipants()
            } else {
                actionFeedback = LinkActionFeedback(
                    success: false,
                    message: NSLocalizedString("_link_participant_remove_failed_", comment: "")
                )
            }
        }
    }

    /// Toggelt eine Emoji-Reaktion (optimistisch lokal, Server bestätigt).
    func toggleReaction(message: LinkChatMessage, emoji: String) {
        guard let api, case let .chat(token, _) = route else { return }
        let removing = message.reactionsSelf.contains(emoji)
        // Optimistisches Update der lokalen Nachricht.
        applyReactionLocally(messageId: message.id, emoji: emoji, removing: removing)
        Task {
            let ok = removing
                ? await api.removeReaction(token: token, messageId: message.id, emoji: emoji)
                : await api.addReaction(token: token, messageId: message.id, emoji: emoji)
            if !ok {
                // Rollback + Reload zur Konsistenz.
                applyReactionLocally(messageId: message.id, emoji: emoji, removing: !removing)
                reloadMessages(token: token)
            }
        }
    }

    private func applyReactionLocally(messageId: Int64, emoji: String, removing: Bool) {
        guard case var .success(list) = messages else { return }
        guard let index = list.firstIndex(where: { $0.id == messageId }) else { return }
        var message = list[index]
        let currentCount = message.reactions[emoji] ?? 0
        if removing {
            let newCount = max(0, currentCount - 1)
            if newCount > 0 {
                message.reactions[emoji] = newCount
            } else {
                message.reactions.removeValue(forKey: emoji)
            }
            message.reactionsSelf.removeAll { $0 == emoji }
        } else {
            message.reactions[emoji] = currentCount + 1
            if !message.reactionsSelf.contains(emoji) {
                message.reactionsSelf.append(emoji)
            }
        }
        list[index] = message
        messages = .success(list)
    }

    func startConversation(id: String, source: String, title: String) {
        guard let api else { return }
        if source == "federated" || source == "email_guest" {
            Task {
                guard let token = await api.createGroupRoom(name: title) else {
                    actionFeedback = LinkActionFeedback(
                        success: false,
                        message: NSLocalizedString("_link_external_failed_", comment: "")
                    )
                    return
                }
                if source == "federated" {
                    await api.addParticipants(token: token, userIds: [], emails: [], federatedIds: [id])
                } else {
                    await api.addParticipants(token: token, userIds: [], emails: [id])
                }
                self.userResults = []
                self.loadConversations()
                self.openConversation(token: token, title: title)
                actionFeedback = LinkActionFeedback(
                    success: true,
                    message: String(format: NSLocalizedString("_link_external_created_", comment: ""), title)
                )
            }
            return
        }
        let roomType = source == "groups" ? LinkRoomType.group.rawValue : LinkRoomType.oneToOne.rawValue
        Task {
            let token = await api.createConversation(invite: id, roomType: roomType)
            self.userResults = []
            if let token {
                self.loadConversations()
                self.openConversation(token: token, title: title)
            }
        }
    }

    /// Löscht eine Konversation komplett (nur mit Owner-/Moderator-Recht;
    /// die Oberfläche blendet den Swipe sonst aus).
    func deleteConversation(token: String) async {
        guard let api else { return }
        let status = await api.deleteRoom(token: token)
        CallDebugLog.log("LinkViewModel", "deleteConversation \(token) -> \(status)")
        loadConversations()
        if (200..<300).contains(status) {
            actionFeedback = LinkActionFeedback(
                success: true,
                message: NSLocalizedString("_link_room_deleted_", comment: "")
            )
        } else {
            actionFeedback = LinkActionFeedback(
                success: false,
                message: NSLocalizedString("_link_room_delete_failed_", comment: "")
            )
        }
    }

    /// Signatur der Konversationsliste (Redundanz-Guard gegen identische
    /// SwiftUI-Updates, die List-Diff-Crashes auslösen können).
    private func conversationSignature(_ list: [LinkConversation]) -> String {
        list.map { "\($0.token):\($0.unreadMessages):\(Int($0.lastActivity)):\($0.lastMessage?.id ?? 0)" }
            .joined(separator: ",")
    }
    private var conversationsSignature = ""

    func loadConversations() {
        guard let api else { return }
        // Cache-first bei erstem Laden: sofortiger Inhalt statt Spinner.
        if case .loading = conversations, let cached = LinkCache.loadConversations() {
            let sorted = cached.sorted { $0.lastActivity > $1.lastActivity }
            self.conversationsSignature = conversationSignature(sorted)
            self.conversations = .success(sorted)
            Self.postUnreadTotal(cached)
        }
        Task {
            if let list = await api.listConversations() {
                let sorted = list.sorted { $0.lastActivity > $1.lastActivity }
                let signature = conversationSignature(sorted)
                if self.conversationsSignature != signature {
                    self.conversationsSignature = signature
                    self.conversations = .success(sorted)
                }
                // Call-Status des geöffneten Raums nachziehen (hasCall), damit
                // der "Teilnehmen"-Button sofort umschaltet. Offene Räume mit
                // leerem Titel (z. B. über /call/-Links geöffnet) bekommen
                // ihren Namen aus der Liste.
                if let room = self.currentRoom,
                   let fresh = sorted.first(where: { $0.token == room.token }) {
                    if fresh.hasCall != room.hasCall {
                        self.currentRoom = fresh
                    }
                    if case let .chat(token, title) = self.route, token == fresh.token, title.isEmpty {
                        self.route = .chat(token: token, title: fresh.displayName)
                    }
                }
                Self.postUnreadTotal(list)
                self.offlineNotice = nil
            } else if let cached = LinkCache.loadConversations() {
                // Server nicht erreichbar (Wartung/offline): letzter Stand.
                let sorted = cached.sorted { $0.lastActivity > $1.lastActivity }
                let signature = conversationSignature(sorted)
                if self.conversationsSignature != signature {
                    self.conversationsSignature = signature
                    self.conversations = .success(sorted)
                }
                Self.postUnreadTotal(cached)
                self.offlineNotice = NSLocalizedString("_link_offline_", comment: "")
                self.cacheBannerActive = self.cacheBannerGate.shouldTrigger()
            }
        }
    }

    /// Summiert ungelesene Nachrichten aller Channels und meldet sie als
    /// Tab-Badge (NotificationCenter).
    nonisolated static func postUnreadTotal(_ list: [LinkConversation]) {
        let total = list.reduce(0) { $0 + $1.unreadMessages }
        NotificationCenter.default.post(name: .linkUnreadChanged, object: total)
    }

    /// Raum-Avatar-URL für den Loader (Talk API v1, mit Versions-Parameter
    /// für Cache-Busting).
    func roomAvatarURL(for room: LinkConversation) -> String {
        api?.roomAvatarURL(token: room.token, avatarVersion: room.avatarVersion) ?? ""
    }

    /// Nutzer-Avatar-URL (Nachrichten) für den Loader.
    func userAvatarURL(for message: LinkChatMessage) -> String? {
        guard message.actorType == "users", !message.actorId.isEmpty else { return nil }
        return api?.userAvatarURL(actorId: message.actorId)
    }

    /// Lädt ein Avatar-Bild in den gemeinsamen Cache (idempotent).
    func loadAvatar(url: String) async {
        guard !url.isEmpty, avatarCache[url] == nil else { return }
        guard let api else { return }
        if let data = await api.fetchImage(url: url), !data.isEmpty {
            avatarCache[url] = data
        }
    }

    @Published var currentRoom: LinkConversation?
    @Published var participants: [LinkParticipant] = []

    func openConversation(token: String, title: String) {
        route = .chat(token: token, title: title)
        if case let .success(rooms) = conversations {
            currentRoom = rooms.first(where: { $0.token == token })
        }
        participants = []
        loadParticipants()
        messages = .loading
        lastMessageId = 0
        pollTask?.cancel()
        // Ungelesen-Zustand VOR dem Laden merken (Basis für Trennlinie
        // und Read-Marker); die Position wird daraus direkt bestimmt.
        let roomUnread = currentRoom?.unreadMessages ?? 0
        let roomLastRead = currentRoom?.lastReadMessage ?? 0
        unreadBoundary = nil
        hideUnreadSeparator = false
        connectSignaling(token: token)
        guard let api else { return }
        pollTask = Task {
            // Cache-first: gecachte Nachrichten SOFORT anzeigen - die
            // Eintrittsposition (Trennlinie bzw. Ende) wird im View über
            // scrollPosition deterministisch gesetzt, es gibt kein
            // sichtbares Scrollen. Der Cache bleibt Offline-Fallback.
            if let cached = LinkCache.loadMessages(token: token), !cached.isEmpty {
                let ordered = cached.sorted { $0.id < $1.id }.filter { !$0.isReactionEvent }
                self.lastMessageId = ordered.last?.id ?? 0
                self.messages = .success(ordered)
                self.updateUnreadBoundary(roomLastRead: roomLastRead, roomUnread: roomUnread)
            }
            var history = await api.getMessages(token: token, lastKnownId: historyAnchor, future: false, timeoutSeconds: 0)
            if history.isEmpty, let cached = LinkCache.loadMessages(token: token) {
                // Server nicht erreichbar: letzte bekannte Nachrichten zeigen.
                history = cached
                offlineNotice = NSLocalizedString("_link_offline_", comment: "")
                cacheBannerActive = cacheBannerGate.shouldTrigger()
            } else {
                offlineNotice = nil
            }
            if Task.isCancelled { return }
            let ordered = history.sorted { $0.id < $1.id }.filter { !$0.isReactionEvent }
            self.lastMessageId = ordered.last?.id ?? 0
            self.messages = .success(ordered)
            self.updateUnreadBoundary(roomLastRead: roomLastRead, roomUnread: roomUnread)
            // Verlauf beim Eintritt NUR bei ungelesenen Nachrichten komplett
            // nachladen (sonst läuft das Netz unsichtbar im Hintergrund und
            // ältere Seiten kommen per Scroll nach).
            if roomUnread > 0 {
                await self.loadFullHistory(token: token)
                self.updateUnreadBoundary(roomLastRead: roomLastRead, roomUnread: roomUnread)
            }
            await self.pollNewMessages(token: token)
        }
    }

    /// Berechnet die erste ungelesene Nachricht aus dem geladenen Fenster.
    private func updateUnreadBoundary(roomLastRead: Int64, roomUnread: Int) {
        guard roomUnread > 0, roomLastRead > 0 else {
            unreadBoundary = nil
            return
        }
        guard case let .success(items) = messages else {
            unreadBoundary = nil
            return
        }
        let sorted = items.sorted { $0.id < $1.id }
        unreadBoundary = sorted.first(where: { $0.id > roomLastRead })?.id
    }

    private var markReadWorkItem: DispatchWorkItem?

    /// Der User ist bis zu den neuesten Nachrichten gescrollt: Trennlinie
    /// ausblenden und den Read-Marker setzen (Talk-Muster, 1 s debounced).
    func noteScrolledToNewest() {
        guard unreadBoundary != nil, !hideUnreadSeparator else { return }
        hideUnreadSeparator = true
        guard let room = currentRoom, room.unreadMessages > 0 else { return }
        guard case let .chat(token, _) = route else { return }
        markReadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let api = self.api else { return }
            let lastId = self.lastMessageId
            Task {
                await api.markRoomRead(token: token, lastReadMessage: lastId)
                // Raum-Liste nachziehen: Unread-Zähler/Badge aktualisieren.
                await self.loadConversations()
            }
        }
        markReadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    /// Lädt den kompletten Chat-Verlauf (Seite für Seite nach oben älter),
    /// bis eine Seite unvollständig ist. Die Liste wächst dabei inkrementell;
    /// die Scrollposition bleibt unten. Kein Zeitlimit.
    private func loadFullHistory(token: String) async {
        guard let api else { return }
        var all: [LinkChatMessage]
        if case let .success(current) = messages {
            all = current
        } else {
            return
        }
        var known = Set(all.map(\.id))
        var anchor = all.map(\.id).min() ?? 0
        hasMoreHistory = anchor > 0
        var pages = 0
        while anchor > 0, pages < 200, !Task.isCancelled {
            let older = await api.getMessages(token: token, lastKnownId: anchor, future: false, timeoutSeconds: 0, saveCache: false)
            if older.isEmpty { break }
            let fresh = older.filter { known.insert($0.id).inserted && !$0.isReactionEvent }
            let newAnchor = older.map(\.id).min() ?? anchor
            guard newAnchor < anchor else { break }
            anchor = newAnchor
            if !fresh.isEmpty {
                all.append(contentsOf: fresh)
                if !Task.isCancelled {
                    self.messages = .success(all.sorted { $0.id < $1.id })
                }
            }
            if older.count < 100 { break }
            pages += 1
        }
        hasMoreHistory = false
        if !Task.isCancelled, case let .success(list) = messages {
            self.messages = .success(list.sorted { $0.id < $1.id })
        }
        CallDebugLog.log("LinkViewModel", "full history loaded for \(token): \(all.count) messages")
    }

    /// Nachladen älterer Nachrichten beim Scrollen nach oben (Sicherheitsnetz,
    /// falls der Historie-Loop unterbrochen wurde).
    func loadEarlierHistory() {
        guard let api, case let .chat(token, _) = route, hasMoreHistory else { return }
        Task {
            await loadFullHistory(token: token)
        }
    }

    private func pollNewMessages(token: String) async {
        guard let api else { return }
        while !Task.isCancelled, case let .chat(currentToken, _) = route, currentToken == token {
            let fresh = await api.getMessages(token: token, lastKnownId: lastMessageId, future: true, timeoutSeconds: pollTimeout)
            if Task.isCancelled { return }
            if !fresh.isEmpty {
                lastMessageId = fresh.map(\.id).max() ?? lastMessageId
                let current: [LinkChatMessage]
                if case let .success(existing) = messages { current = existing } else { current = [] }
                let merged = (current + fresh)
                var seen = Set<Int64>()
                var deletedIds = Set<Int64>()
                for message in merged {
                    if let parentId = message.deletedParentId {
                        deletedIds.insert(parentId)
                    }
                }
                let deduped = merged
                    .filter { !$0.isReactionEvent }
                    .filter { !deletedIds.contains($0.id) }
                    .filter { seen.insert($0.id).inserted }
                    .sorted { $0.id < $1.id }
                messages = .success(deduped)
            }
        }
    }

    func send(text: String, replyTo: Int64? = nil) {
        guard let api else { return }
        guard case let .chat(token, _) = route else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        let outgoing = mentionAwareMessage(trimmed)
        Task { await api.sendMessage(token: token, message: outgoing, replyTo: replyTo) }
    }

    /// Leitet eine Nachricht in einen anderen Channel weiter (wie Talk Web:
    /// aufgelöster Text als neue Nachricht im Ziel; Mentions behalten ihre
    /// @"<id>"-Form und werden dort wieder zu Pillen).
    func forwardMessage(_ message: LinkChatMessage, to target: LinkConversation) {
        guard let api else { return }
        let text = message.forwardText()
        guard !text.isEmpty else { return }
        Task {
            await api.sendMessage(token: target.token, message: text)
            actionFeedback = LinkActionFeedback(
                success: true,
                message: NSLocalizedString("_link_forwarded_", comment: "")
            )
        }
    }

    /// Talk parst Mentions nur in der Form @"<ID>" (User-ID,
    /// guest/<sessionId>, federated_user/<cloudId>, ...) - @"Anzeigename"
    /// bleibt im Nachrichtentext roh stehen. Deshalb vor dem Senden alle
    /// @"<Anzeigename>"-Vorkommen der Raum-Teilnehmer auf die ID-Form
    /// mappen (genau wie es Talk Web mit `mentionId` tut).
    private func mentionAwareMessage(_ text: String) -> String {
        var result = text
        let candidates = participants
            .filter { !$0.displayName.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.displayName.count > $1.displayName.count }
        for participant in candidates {
            let name = participant.displayName
            let mentionId = Self.mentionId(for: participant)
            guard mentionId != name else { continue }
            result = result.replacingOccurrences(of: "@\"\(name)\"", with: "@\"\(mentionId)\"")
        }
        return result
    }

    /// Talk-Mention-ID je Akteurstyp (wie Talk Web): users → userId,
    /// guests → guest/<sessionId>, federated_user → federated_user/<cloudId>,
    /// emails → email/<address>, groups → group/<gid>, sonst unverändert.
    static func mentionId(for participant: LinkParticipant) -> String {
        switch participant.actorType {
        case "users": return participant.actorId
        case "guests": return "guest/\(participant.actorId)"
        case "federated_users": return "federated_user/\(participant.actorId)"
        case "emails": return "email/\(participant.actorId)"
        case "groups": return "group/\(participant.actorId)"
        default: return participant.actorId
        }
    }

    // MARK: - Delete / edit

    func deleteMessage(_ message: LinkChatMessage) {
        guard let api else { return }
        guard case let .chat(token, _) = route else { return }
        Task {
            if await api.deleteMessage(token: token, messageId: message.id) {
                removeLocalMessages([message.id])
            }
        }
    }

    func editMessage(_ message: LinkChatMessage, text: String) {
        guard let api else { return }
        guard case let .chat(token, _) = route else { return }
        Task {
            if await api.editMessage(token: token, messageId: message.id, text: text) {
                reloadMessages(token: token)
            }
        }
    }

    /// Removes messages locally (own deletions and `message_deleted`
    /// system messages coming from the server).
    private func removeLocalMessages(_ ids: [Int64]) {
        guard case var .success(existing) = messages else { return }
        existing.removeAll { ids.contains($0.id) }
        messages = .success(existing)
    }

    /// Fetches the full recent history once (used after edits/deletions).
    private func reloadMessages(token: String) {
        Task {
            let history = await api?.getMessages(token: token, lastKnownId: historyAnchor, future: false, timeoutSeconds: 0) ?? []
            let ordered = history.sorted { $0.id < $1.id }.filter { !$0.isReactionEvent }
            self.lastMessageId = ordered.last?.id ?? 0
            self.messages = .success(ordered)
        }
    }

    /// Downloads a chat file attachment into the app cache for preview.
    func downloadAttachment(_ info: LinkFileInfo) async -> URL? {
        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else { return nil }
        let root = tbl.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let user = tbl.user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tbl.user
        // Talk liefert den Pfad relativ zur Nutzer-Wurzel ("Souvera/Link/...")
        // - die DAV-URL braucht einen führenden Slash, sonst 404.
        let rawRelative = info.path ?? "/Talk/\(info.name)"
        let relative = rawRelative.hasPrefix("/") ? rawRelative : "/\(rawRelative)"
        guard let url = URL(string: "\(root)/remote.php/dav/files/\(user)\(relative)") else { return nil }

        var req = URLRequest(url: url)
        let davPassword = NCPreferences().getPassword(account: tbl.account)
        let raw = "\(tbl.user):\(davPassword)"
        req.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        let folder = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("link-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = info.name.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let file = folder.appendingPathComponent("\(UUID().uuidString)_\(safeName)")
        do {
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    /// Opens the folder of a chat file in the Files module (the user's
    /// request: tapping a shared file shows it in the Dateien tab). Files at
    /// the user root (shared Souvera files) have no folder - the Files tab
    /// opens the home folder instead.
    /// Items für das iOS-Teilen-Sheet: Nachrichtentext, erkannte URL-Links
    /// und ein geteilter Anhang als heruntergeladene Datei.
    func shareItems(for message: LinkChatMessage) async -> [Any] {
        var items: [Any] = []
        let text = message.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            items.append(text)
            if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                let ns = text as NSString
                let matches = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
                for match in matches {
                    if let url = match.url { items.append(url) }
                }
            }
        }
        if let info = message.fileInfo(), let path = info.path,
           let fileURL = await api?.downloadChatAttachment(path: path) {
            items.append(fileURL)
        }
        return items
    }

    func openFileInFiles(_ info: LinkFileInfo) {
        let raw = info.path ?? ""
        let folderPath = (raw as NSString).deletingLastPathComponent
        CallDebugLog.log("LinkViewModel", "openFileInFiles path=\(raw) folder=\(folderPath)")
        NotificationCenter.default.post(name: .openFileInFiles, object: folderPath)
    }

    // MARK: - Attachments

    /// Uploads a local file into the current chat (Talk 24+ attachment flow:
    /// Draft-Ordner → DAV-Upload → Attachment-Post).
    func sendAttachment(data: Data, fileName: String, mimeType: String) {
        guard let api else { return }
        guard case let .chat(token, _) = route else { return }
        Task {
            let ok = await api.uploadFileToChat(token: token, data: data, fileName: fileName, mimeType: mimeType)
            if !ok {
                actionFeedback = LinkActionFeedback(
                    success: false,
                    message: NSLocalizedString("_link_upload_failed_", comment: "")
                )
            }
        }
    }

    /// Shares an existing Souvera/Nextcloud file into the current chat.
    func shareAttachment(_ selection: NextcloudFileSelection) {
        guard let api else { return }
        guard case let .chat(token, _) = route else { return }
        Task {
            await api.shareFileToChat(token: token, relativePath: selection.relativePath)
        }
    }

    @discardableResult
    func back() -> Bool {
        if case .chat = route {
            pollTask?.cancel()
            signaling.disconnect()
            typingNames = []
            route = .home
            loadConversations()
            return true
        }
        return false
    }

    deinit {
        pollTask?.cancel()
        roomPollTask?.cancel()
        if let deepLinkObserver {
            NotificationCenter.default.removeObserver(deepLinkObserver)
        }
        let client = signaling
        Task { @MainActor in
            client.disconnect()
        }
    }

    // MARK: - Typing-Indikatoren

    let signaling = LinkSignalingClient()
    /// Anzeigenamen der aktuell tippenden Personen.
    @Published var typingNames: [String] = []

    private func connectSignaling(token: String) {
        signaling.disconnect()
        typingNames = []
        signaling.onTypingChanged = { [weak self] names in
            self?.typingNames = names
        }
        guard let account = LinkAccount.active(),
              let roomId = currentRoom?.roomId, roomId != 0 else { return }
        Task {
            guard let settings = await api?.fetchSignalingSettings() else { return }
            signaling.connect(account: account, token: token, roomId: roomId, settings: settings)
        }
    }

    /// Trennt die Chat-Signaling-Verbindung (Typing/Call-Events). Wichtig
    /// für Push-Notifications: Solange eine Session aktiv ist, unterdrückt
    /// Talk Pushes - deshalb beim Tab-Wechsel/Background sofort trennen.
    func disconnectSignaling() {
        signaling.disconnect()
        typingNames = []
    }

    /// Stellt die Signaling-Verbindung wieder her, wenn ein Chat offen ist
    /// (Rückkehr in den Tab).
    func reconnectSignalingIfNeeded() {
        guard case let .chat(token, _) = route else { return }
        connectSignaling(token: token)
    }

    // MARK: - In-App-Incoming-Call (Vordergrund)

    /// Raum mit laufendem Call, für den noch keine In-App-Anruf-UI gezeigt
    /// wurde (Foreground: PushKit liefert keine VoIP-Pushes).
    @Published var incomingCallRoom: LinkConversation?

    /// Call-Zustand pro Raum aus dem letzten Poll: Die In-App-Anruf-UI
    /// erscheint NUR beim Übergang kein Call -> Call (frisch gestarteter
    /// Call, während die App läuft). Läuft der Call bereits beim ersten
    /// Poll (App-Start oder Raum-Öffnen), gibt es KEINEN Fullscreen - man
    /// steigt über den "Teilnehmen"-Button im Chat ein.
    private var previousCallState: [String: Bool] = [:]
    private var roomPollTask: Task<Void, Never>?

    /// Periodischer Vordergrund-Poll der Raumliste (alle 10 s): erkennt
    /// laufende Calls, aktualisiert hasCall und löst die In-App-Anruf-UI aus.
    func startRoomPolling() {
        roomPollTask?.cancel()
        roomPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.loadConversations()
                self.detectIncomingCall()
            }
        }
    }

    func stopRoomPolling() {
        roomPollTask?.cancel()
        roomPollTask = nil
    }

    /// Zeigt die In-App-Anruf-UI nur, wenn ein Call FRISCH startet (Übergang
    /// false->true im Poll) und wir selbst nicht im Call sind. Ein bereits
    /// laufender Call beim Öffnen der App/des Raums löst keinen Fullscreen
    /// aus. Der Zustand wird auch während eines eigenen Calls nachgezogen,
    /// damit nach dem Verlassen wieder frische Calls erkannt werden.
    private func detectIncomingCall() {
        guard case let .success(rooms) = conversations else { return }
        var freshCall: LinkConversation?
        for room in rooms {
            let hasCall = room.hasCall
            let previous = previousCallState[room.token]
            previousCallState[room.token] = hasCall
            if hasCall, previous == false, freshCall == nil {
                freshCall = room
            }
        }
        guard let freshCall,
              LinkVoIPManager.shared.activeSession == nil,
              !LinkVoIPManager.shared.hasRingingCall,
              incomingCallRoom == nil else { return }
        CallDebugLog.log("LinkViewModel", "in-app incoming call detected (fresh) room=\(freshCall.token)")
        incomingCallRoom = freshCall
    }

    /// Ablehnen der In-App-Anruf-UI (Raum wird für diesen Call nicht erneut
    /// gemeldet).
    func dismissIncomingCall() {
        incomingCallRoom = nil
    }

    /// Fullscreen minimieren: Der klingelnde Anruf wandert in die schmale
    /// Leiste oben in der App (Annehmen/Ablehnen), man kann weiterarbeiten.
    func minimizeIncomingCall() {
        guard let room = incomingCallRoom else { return }
        SouveraCallBannerModel.shared.minimizedIncoming = room
        // Dynamic Island / Lock-Screen: Live Activity für den klingelnden
        // Anruf starten (Annehmen/Ablehnen per Insel-Buttons möglich).
        SouveraCallLiveActivity.start(title: room.displayName)
        dismissIncomingCall()
    }
}

/// Kurzer Rückmelde-Hinweis für Link-Aktionen (Toast).
struct LinkActionFeedback: Equatable {
    let success: Bool
    let message: String
}
