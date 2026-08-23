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
    /// Posted when another module (e.g. the calendar) wants the Link tab to
    /// open a specific conversation.
    static let openLinkRoom = Notification.Name("SouveraOpenLinkRoom")
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

    private(set) var currentUserId: String = ""

    private var api: LinkOcsApi?
    private var pollTask: Task<Void, Never>?
    private var lastMessageId: Int64 = 0

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
        }
    }

    /// Lädt die Teilnehmerliste des geöffneten Channels.
    func loadParticipants() {
        guard let api, case let .chat(token, _) = route else { return }
        Task {
            let list = await api.listParticipants(token: token)
            self.participants = list
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

    func loadConversations() {
        guard let api else { return }
        Task {
            if let list = await api.listConversations() {
                self.conversations = .success(list.sorted { $0.lastActivity > $1.lastActivity })
                Self.postUnreadTotal(list)
                self.offlineNotice = nil
            } else if let cached = LinkCache.loadConversations() {
                // Server nicht erreichbar (Wartung/offline): letzter Stand.
                self.conversations = .success(cached.sorted { $0.lastActivity > $1.lastActivity })
                Self.postUnreadTotal(cached)
                self.offlineNotice = NSLocalizedString("_link_offline_", comment: "")
            }
        }
    }

    /// Summiert ungelesene Nachrichten aller Channels und meldet sie als
    /// Tab-Badge (NotificationCenter).
    static func postUnreadTotal(_ list: [LinkConversation]) {
        let total = list.reduce(0) { $0 + $1.unreadMessages }
        NotificationCenter.default.post(name: .linkUnreadChanged, object: total)
    }

    /// Raum-Avatar-URL für den Loader.
    func roomAvatarURL(token: String) -> String {
        api?.roomAvatarURL(token: token) ?? ""
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
        guard let api else { return }
        pollTask = Task {
            // Load the newest messages: lookIntoFuture=0 pages backwards from a high anchor id, so
            // it returns the most recent page (there is no "give me the latest" without an anchor).
            var history = await api.getMessages(token: token, lastKnownId: historyAnchor, future: false, timeoutSeconds: 0)
            if history.isEmpty, let cached = LinkCache.loadMessages(token: token) {
                // Server nicht erreichbar: letzte bekannte Nachrichten zeigen.
                history = cached
                offlineNotice = NSLocalizedString("_link_offline_", comment: "")
            }
            if Task.isCancelled { return }
            let ordered = history.sorted { $0.id < $1.id }.filter { !$0.isReactionEvent }
            self.lastMessageId = ordered.last?.id ?? 0
            self.messages = .success(ordered)
            await self.pollNewMessages(token: token)
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
        let relative = info.path ?? "/Talk/\(info.name)"
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

    // MARK: - Attachments

    /// Uploads a local file into the current chat.
    func sendAttachment(data: Data, fileName: String, mimeType: String) {
        guard let api else { return }
        guard case let .chat(token, _) = route else { return }
        Task { await api.uploadFileToChat(token: token, data: data, fileName: fileName, mimeType: mimeType) }
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
            route = .home
            loadConversations()
            return true
        }
        return false
    }

    deinit { pollTask?.cancel() }
}

/// Kurzer Rückmelde-Hinweis für Link-Aktionen (Toast).
struct LinkActionFeedback: Equatable {
    let success: Bool
    let message: String
}
