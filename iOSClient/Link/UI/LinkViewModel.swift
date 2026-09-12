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
import Network

extension Notification.Name {
    /// Posted whenever the active call state changes (started/ended).
    static let linkCallStateChanged = Notification.Name("SouveraLinkCallStateChanged")
    /// Posted with the total number of unread messages (Link tab badge).
    static let linkUnreadChanged = Notification.Name("SouveraLinkUnreadChanged")
    /// Vordergrund-Auffrischung der Konversationsliste (LinkBadgeMonitor):
    /// List + Badge in einem loadConversations()-Durchlauf aktualisieren.
    static let linkConversationsRefreshRequested = Notification.Name("SouveraLinkConversationsRefreshRequested")
    /// Push-getriggerter Reload (Talk-Push empfangen): entprelltes
    /// loadConversations() - Neue Mails erscheinen ~1 s nach dem Senden.
    static let linkConversationsReloadRequested = Notification.Name("SouveraLinkConversationsReloadRequested")
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
    /// P68k: Inline-Bilder des Chats (Key = Message-ID; leeres Data =
    /// Laden fehlgeschlagen -> Chip-Fallback).
    @Published var chatImageCache: [Int64: Data] = [:]
    /// Bilder, deren Download endgueltig fehlgeschlagen ist (max. 2
    /// Versuche) - die Zelle zeigt dann "nicht verfuegbar" statt fuer
    /// immer "Bild wird geladen..." (Run-Feedback 11.09.).
    @Published var chatImageFailed: Set<Int64> = []
    /// Versuchszaehler pro Bild (Session-scoped, nicht publiziert).
    private var imageLoadAttempts: [Int64: Int] = [:]
    /// P68o: PDF-Anhänge: Thumbnail (1. Seite) + Temp-URL für QuickLook.
    @Published var chatPdfThumbCache: [Int64: Data] = [:]
    @Published var chatPdfCache: [Int64: URL] = [:]
    /// Offline-Hinweis (Server nicht erreichbar - Cache-Stand wird gezeigt).
    @Published var offlineNotice: String?
    /// "Anfang der Unterhaltung" erreicht (kein älterer Verlauf mehr)?
    /// Run-Vereinfachung 10.09.: Der VERLAUF WIRD KOMPLETT geladen - der
    /// 7-Tage-/Min-10-Fenstermechanismus (Pull, Render-Fenster, Re-Anchor)
    /// ist entfallen, weil inkrementelles Nachladen mit SwiftUI-self-
    /// sizing-Zellen keine ruhige Scroll-Erfahrung liefert (Log 10.09.).
    @Published private(set) var hasMoreHistory = false
    /// Der komplette Verlauf lädt gerade im Hintergrund (Bubble-Spinner).
    @Published private(set) var isLoadingHistory = false
    /// Die erste Seite (bzw. der Cache) ist da - die Eintritts-
    /// positionierung darf setzen (Listenstart sichtbar).
    @Published private(set) var windowLoadDone = false
    /// Erste ungelesene Nachricht (id > lastReadMessage) - Basis für die
    /// "Neue Nachrichten"-Trennlinie und die Eintrittsposition.
    @Published private(set) var unreadBoundary: Int64?
    /// Gepufferte, noch NICHT publizierte aeltere Verlaufs-Batches
    /// (Vollverlauf-Kette). Publiziert wird on-demand am Verlaufskopf
    /// (publishOlderBatch): Inserts erfolgen dort, wo der Anker-Scroll
    /// des Controllers exakt ist (Anker-Zelle realisiert) - Hintergrund-
    /// Prepends waehrend des Lesens am Ende wuerden die Liste "herum-
    /// irren" lassen (Log 11.09. 15:25).
    private var pendingOlderBatches: [[LinkChatMessage]] = []
    private var historyChainReachedStart = false
    /// true, sobald der User bis zu den neuesten Nachrichten gescrollt hat -
    /// die Trennlinie wird ausgeblendet, der Read-Marker gesetzt.
    @Published private(set) var hideUnreadSeparator = false
    /// Transienter Trigger für den "Server-Error: Cache aktiv"-Banner.
    @Published var cacheBannerActive = false

    private(set) var currentUserId: String = ""

    /// Offline-Warteschlange (Run 11.09.): Nachrichten, die offline
    /// eingegeben wurden - persistiert (LinkCache), im Chat mit
    /// Pendenz-Marker sichtbar, Versand automatisch bei Rueckkehr online.
    @Published private(set) var pendingMessages: [LinkPendingMessage] = []
    @Published private(set) var isOnline = true
    private let pathMonitor = NWPathMonitor()
    private var nextPendingTempId: Int64 = -1
    private var pollFailureStreak = 0

    /// Push-Deep-Link-Beobachter (Chat-Raum direkt öffnen).
    private var deepLinkObserver: NSObjectProtocol?
    private var accountChangeObserver: NSObjectProtocol?
    private var linkRoomsObserver: NSObjectProtocol?
    private var refreshObserver: NSObjectProtocol?
    private var reloadObserver: NSObjectProtocol?
    /// Debounce für push-getriggerte Reloads (Mindestabstand 2 s).
    private var lastPushReload: Date?
    /// Multi-Account-Generation: erhöht sich bei jedem Account-Wechsel.
    /// Laufende asynchrone Ladungen tragen ihre Generation und verwerfen
    /// veraltete Ergebnisse (sonst überschreibt ein alter Task die Liste
    /// mit den Räumen des vorherigen Accounts -> Flapping).
    private var generation = 0

    init() {
        startNetworkMonitor()
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
        // Multi-Account: beim Account-Wechsel den Link/Talk-Zustand auf den
        // neuen Account umstellen (LinkOcsApi, Conversations, Chat-State).
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(NCGlobal.shared.notificationCenterChangeUser),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetForAccountChange()
            }
        }
        // EINMALIG registriert (nicht in start() - sonst akkumulieren sich
        // Observer bei jedem Account-Wechsel und die Liste flappt).
        linkRoomsObserver = NotificationCenter.default.addObserver(
            forName: .linkRoomsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.loadConversations()
        }
        // Vordergrund-Poll des LinkBadgeMonitor: den gelieferten Listenstand
        // übernehmen (Liste UND Badge aktuell, ohne zweiten Netz-Fetch).
        refreshObserver = NotificationCenter.default.addObserver(
            forName: .linkConversationsRefreshRequested, object: nil, queue: .main
        ) { [weak self] notification in
            guard let list = notification.object as? [LinkConversation] else { return }
            Task { @MainActor [weak self] in
                self?.applyRefreshedConversations(list)
            }
        }
        // Push-Trigger: Talk-Push empfangen -> entprellt die Liste frisch
        // vom Server laden (Mindestabstand 2 s gegen Nachrichten-Bursts).
        reloadObserver = NotificationCenter.default.addObserver(
            forName: .linkConversationsReloadRequested, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let last = self.lastPushReload, Date().timeIntervalSince(last) < 2 {
                    return
                }
                self.lastPushReload = Date()
                self.loadConversations()
            }
        }
        // KEIN .linkUnreadChanged-Observer hier: loadConversations() postet
        // selbst .linkUnreadChanged (via postUnreadTotal). Ein Observer darauf
        // würde synchron re-entrant loadConversations() -> LinkAccount.active()
        // -> Realm-Read auf dem Main-Thread auslösen (File-Lock-Deadlock,
        // Watchdog-Kill 0xdead10cc) und zusätzlich eine Endlos-Reload-Schleife
        // erzeugen. Der Badge wird vom Tab-Controller + SouveraBadgeStore
        // konsumiert, nicht von LinkViewModel selbst.
    }

    /// Multi-Account: verwirft den kompletten Link/Talk-Zustand und baut
    /// ihn mit dem aktiven Account neu auf.
    private func resetForAccountChange() {
        generation += 1
        api = nil
        pollTask?.cancel()
        pollTask = nil
        route = .home
        conversations = .loading
        messages = .loading
        currentRoom = nil
        participants = []
        userResults = []
        avatarCache = [:]
        chatImageCache = [:]
        chatPdfThumbCache = [:]
        chatPdfCache = [:]
        chatImageFailed = []
        imageLoadAttempts = [:]
        loadPendingMessages()
        unreadBoundary = nil
        lastMessageId = 0
        currentUserId = ""
        offlineNotice = nil
        typingNames = []
        conversationsSignature = ""
        pendingOlderBatches = []
        historyChainReachedStart = false
        start()
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
        loadPendingMessages()
        if api == nil {
            guard let account = LinkAccount.active() else {
                conversations = .error("No account")
                return
            }
            currentUserId = account.username
            api = LinkOcsApi(account: account)
        }
        // Bei jedem Erscheinen des Tabs frisch laden, damit aus dem Kalender
        // erstellte Channels sofort sichtbar sind.
        loadConversations()
    }

    /// P68o: Ist die Nachricht eine PDF-Datei?
    func isPdfMessage(_ message: LinkChatMessage) -> Bool {
        guard let info = message.fileInfo() else { return false }
        return (info.name as NSString).pathExtension.lowercased() == "pdf"
    }

    /// P68o: Lädt ein Chat-PDF (WebDAV - funktioniert für hochgeladene
    /// Anhänge UND Souvera-Dateien-Freigaben) und erzeugt das Thumbnail
    /// der ersten Seite.
    func loadChatPdf(for message: LinkChatMessage) async {
        guard chatPdfThumbCache[message.id] == nil,
              let info = message.fileInfo(),
              let path = info.path,
              let api else { return }
        guard let url = await api.downloadChatAttachment(path: path) else {
            await MainActor.run { chatPdfThumbCache[message.id] = Data() }
            return
        }
        guard let thumb = NCUtility().pdfThumbnail(url: url, width: 220),
              let thumbData = thumb.jpegData(compressionQuality: 0.85) else {
            await MainActor.run { chatPdfThumbCache[message.id] = Data() }
            return
        }
        await MainActor.run {
            chatPdfThumbCache[message.id] = thumbData
            chatPdfCache[message.id] = url
        }
    }

    /// P68k: Ist die Nachricht eine anzeigbare Bild-Datei?
    func isImageMessage(_ message: LinkChatMessage) -> Bool {
        guard let info = message.fileInfo() else { return false }
        let ext = (info.name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp"].contains(ext)
    }

    /// P68k: Lädt ein Chat-Bild (WebDAV) und skaliert es fürs Thumbnail
    /// herunter (Speicherschutz bei großen Fotos).
    func loadChatImage(for message: LinkChatMessage) async {
        let id = message.id
        // Bereits geladen oder endgueltig gescheitert (2 Versuche): fertig.
        if let cached = chatImageCache[id], !cached.isEmpty { return }
        if chatImageFailed.contains(id), (imageLoadAttempts[id] ?? 0) >= 2 { return }
        guard let info = message.fileInfo(), let api else {
            CallDebugLog.log("LinkVM", "chat image \(id): no fileInfo/api - skipped")
            return
        }
        guard let path = info.path else {
            // Ohne Pfad dauerhaft nicht ladbar (kein Retry-Spam).
            CallDebugLog.log("LinkVM", "chat image \(id): fileInfo without path (\(info.name))")
            await MainActor.run {
                chatImageFailed.insert(id)
                imageLoadAttempts[id] = 2
                chatImageCache[id] = Data()
            }
            return
        }
        let attempt = (imageLoadAttempts[id] ?? 0) + 1
        imageLoadAttempts[id] = attempt
        if let url = await api.downloadChatAttachment(path: path),
           let data = try? Data(contentsOf: url), !data.isEmpty {
            let scaled = await Self.downscaledImageData(data, maxDimension: 1280) ?? data
            CallDebugLog.log("LinkVM", "chat image \(id): loaded \(data.count) bytes (attempt \(attempt))")
            await MainActor.run {
                chatImageCache[id] = scaled
                chatImageFailed.remove(id)
            }
        } else {
            CallDebugLog.log("LinkVM", "chat image \(id): download FAILED (attempt \(attempt))")
            if attempt < 2 {
                // Ein Retry nach 1s (Funkloch/Timeout), danach Fehl-Marker.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !Task.isCancelled {
                    await loadChatImage(for: message)
                }
                return
            }
            await MainActor.run {
                chatImageFailed.insert(id)
                chatImageCache[id] = Data()
            }
        }
    }

    /// Skaliert Bilddaten auf maxDimension (längste Kante) herunter.
    nonisolated static func downscaledImageData(_ data: Data, maxDimension: CGFloat) async -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let largest = max(image.size.width, image.size.height)
        guard largest > maxDimension else { return data }
        let scale = maxDimension / largest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.85)
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

    /// Setzt DIE eine Reaktion des Users (Run-Vorgabe: maximal eine eigene
    /// Reaktion je Nachricht): eine bestehende eigene Reaktion wird
    /// überschrieben; dieselbe Reaktion bleibt unverändert (Entfernen
    /// ausschließlich über removeOwnReaction). Optimistisch lokal, Server
    /// bestätigt; bei Fehlschlag Rollback + Reload.
    func setReaction(message: LinkChatMessage, emoji: String) {
        guard let api, case let .chat(token, _) = route else { return }
        let previous = message.reactionsSelf.first
        guard previous != emoji else { return }
        applyReactionReplace(messageId: message.id, from: previous, to: emoji)
        Task {
            var ok = true
            if let previous {
                ok = await api.removeReaction(token: token, messageId: message.id, emoji: previous)
            }
            if ok {
                ok = await api.addReaction(token: token, messageId: message.id, emoji: emoji)
            }
            if !ok {
                // Rollback + Reload zur Konsistenz.
                applyReactionReplace(messageId: message.id, from: emoji, to: previous)
                reloadMessages(token: token)
            }
        }
    }

    /// Entfernt die eigene Reaktion einer Nachricht (Popup-Option,
    /// Run-Vorgabe E2).
    func removeOwnReaction(message: LinkChatMessage) {
        guard let api, case let .chat(token, _) = route else { return }
        guard let previous = message.reactionsSelf.first else { return }
        applyReactionReplace(messageId: message.id, from: previous, to: nil)
        Task {
            if !(await api.removeReaction(token: token, messageId: message.id, emoji: previous)) {
                applyReactionReplace(messageId: message.id, from: nil, to: previous)
                reloadMessages(token: token)
            }
        }
    }

    /// Lokaler Replace: `from`-Emoji (Count −1, aus reactionsSelf raus) und
    /// `to`-Emoji (Count +1, einziger Eintrag in reactionsSelf). `nil` =
    /// nichts hinzufügen (Entfernen).
    private func applyReactionReplace(messageId: Int64, from: String?, to: String?) {
        guard case var .success(list) = messages else { return }
        guard let index = list.firstIndex(where: { $0.id == messageId }) else { return }
        var message = list[index]
        if let from {
            let current = message.reactions[from] ?? 0
            let newCount = max(0, current - 1)
            if newCount > 0 {
                message.reactions[from] = newCount
            } else {
                message.reactions.removeValue(forKey: from)
            }
            message.reactionsSelf.removeAll { $0 == from }
        }
        if let to {
            message.reactions[to] = (message.reactions[to] ?? 0) + 1
            message.reactionsSelf = [to]
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

    /// Gäste-Zugang für einen Raum an/aus (public/private schalten).
    /// Aktualisiert danach die Raumliste (neuer Typ public/group).
    @discardableResult
    func toggleGuestAccess(token: String, enabled: Bool) async -> Bool {
        guard let api else { return false }
        if enabled {
            await api.makeRoomPublic(token: token)
        } else {
            await api.makeRoomPrivate(token: token)
        }
        loadConversations()
        actionFeedback = LinkActionFeedback(
            success: true,
            message: NSLocalizedString(enabled ? "_link_guests_allowed_" : "_link_guests_disallowed_", comment: "")
        )
        return true
    }

    /// Gäste-Link für einen öffentlichen Raum (Talk-Muster: {server}/call/{token}).
    func guestURL(for room: LinkConversation) -> String {
        "\(accountBaseUrl())/index.php/call/\(room.token)"
    }

    /// Übernimmt einen vom LinkBadgeMonitor gelieferten Listenstand (ohne
    /// zweiten Netz-Fetch); gleiche Logik wie der Netz-Zweig in
    /// loadConversations (Signatur-Guard gegen identische Updates).
    func applyRefreshedConversations(_ list: [LinkConversation]) {
        let sorted = list.sorted { $0.lastActivity > $1.lastActivity }
        let signature = conversationSignature(sorted)
        if conversationsSignature != signature {
            conversationsSignature = signature
            conversations = .success(sorted)
        }
        // Call-Status des geöffneten Raums nachziehen (hasCall) und offene
        // Räume mit leerem Titel benennen - wie in loadConversations.
        if let room = currentRoom,
           let fresh = sorted.first(where: { $0.token == room.token }) {
            if fresh.hasCall != room.hasCall {
                currentRoom = fresh
            }
            if case let .chat(token, title) = route, token == fresh.token, title.isEmpty {
                route = .chat(token: token, title: fresh.displayName)
            }
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
        let gen = generation
        // Cache-first bei erstem Laden: sofortiger Inhalt statt Spinner.
        let cacheAccount = LinkAccount.active()?.account ?? ""
        if case .loading = conversations, let cached = LinkCache.loadConversations(account: cacheAccount) {
            let sorted = cached.sorted { $0.lastActivity > $1.lastActivity }
            self.conversationsSignature = conversationSignature(sorted)
            self.conversations = .success(sorted)
            Self.postUnreadTotal(cached, account: cacheAccount)
        }
        Task {
            if let list = await api.listConversations() {
                guard gen == self.generation else { return }
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
                Self.postUnreadTotal(list, account: cacheAccount)
                self.offlineNotice = nil
            } else if let cached = LinkCache.loadConversations(account: cacheAccount) {
                // Server nicht erreichbar (Wartung/offline): letzter Stand.
                let sorted = cached.sorted { $0.lastActivity > $1.lastActivity }
                let signature = conversationSignature(sorted)
                if self.conversationsSignature != signature {
                    self.conversationsSignature = signature
                    self.conversations = .success(sorted)
                }
                Self.postUnreadTotal(cached, account: cacheAccount)
                self.offlineNotice = NSLocalizedString("_link_offline_", comment: "")
                self.cacheBannerActive = self.cacheBannerGate.shouldTrigger()
            }
        }
    }

    /// Summiert ungelesene Nachrichten aller Channels und meldet sie als
    /// Tab-Badge (NotificationCenter). `account` wird für den Account-Wechsel-
    /// Badge im Mehr-Menü mitgegeben.
    nonisolated static func postUnreadTotal(_ list: [LinkConversation], account: String) {
        let total = list.reduce(0) { $0 + $1.unreadMessages }
        NotificationCenter.default.post(
            name: .linkUnreadChanged,
            object: total,
            userInfo: ["account": account]
        )
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
        pendingOlderBatches = []
        historyChainReachedStart = false
        // Ungelesen-Zustand VOR dem Laden merken (Basis für Trennlinie
        // und Read-Marker); die Position wird daraus direkt bestimmt.
        let roomUnread = currentRoom?.unreadMessages ?? 0
        let roomLastRead = currentRoom?.lastReadMessage ?? 0
        unreadBoundary = nil
        hideUnreadSeparator = false
        connectSignaling(token: token)
        // Run-Fix "Vollverlauf lädt nicht": hasMoreHistory FRÜH auf true -
        // der Eintritts-Settle (Cache-first) kann FEUERN, bevor der Live-
        // Fetch am Ende der Funktion den Wert setzt; loadFullHistory-
        // Background hat dann abgelehnt und nie wieder einen Versuch
        // gestartet (Log 10.09. 18:30: kein full-history-Eintrag, Verlauf
        // eingefroren am 31.08.). loadFullHistory korrigiert über
        // reachedStart.
        hasMoreHistory = true
        guard let api else { return }
        let gen = generation
        pollTask = Task {
            let boundaryTarget: Int64? = roomUnread > 0 ? roomLastRead : nil
            var loaded: [LinkChatMessage] = []
            var covered = false

            /// Publiziert den Stand und setzt die Entry-Flags (einmalig).
            /// Closure statt lokaler func: lokale Funktionen erben die
            /// Actor-Isolation nicht (Compile-Fehler in Swift 5-Modus).
            let publish = {
                let ordered = loaded.sorted { $0.id < $1.id }.filter { !$0.isHiddenSystemMessage }
                self.lastMessageId = ordered.last?.id ?? self.lastMessageId
                self.messages = .success(ordered)
                LinkCache.saveMessageArray(ordered, token: token)
                if !self.windowLoadDone {
                    self.windowLoadDone = true
                    self.hasMoreHistory = true
                }
                self.updateUnreadBoundary(roomLastRead: roomLastRead, roomUnread: roomUnread)
            }

            /// Abdeckungs-Check: Die Trennlinie (erste Meldung > lastRead)
            /// ist nur darstellbar, wenn eine Meldung <= lastRead geladen
            /// ist (oder kein Ungelesen existiert).
            let isCovered = { (items: [LinkChatMessage]) -> Bool in
                guard let boundaryTarget else { return true }
                guard let oldest = items.map(\.id).min() else { return false }
                return oldest <= boundaryTarget
            }

            // OFFLINE (Run 12.09.): NICHT auf Live-Fetches warten - der
            // Cache wird SOFORT publiziert (Abdeckung egal), sonst hingen
            // die timeout=0-Fetches minutenlang und der Chat blieb leer.
            if !isOnline {
                if let cached = LinkCache.loadMessages(token: token), !cached.isEmpty {
                    loaded = cached.sorted { $0.id < $1.id }.filter { !$0.isHiddenSystemMessage }
                    self.lastMessageId = loaded.last?.id ?? 0
                }
                covered = true
                publish()
                CallDebugLog.log("LinkVM", "offline entry: cache published (\(loaded.count) messages), live chain skipped")
                self.windowLoadDone = true
                return
            }

            // Cache-first: gecachte Nachrichten SOFORT anzeigen, WENN sie
            // die Trennlinie abdecken (Run-Vorgabe "lieber länger aber
            // sauber": sonst zentrierter Ladekreis, bis die Abdeckung per
            // Kettenladen steht - kein Teil-Render mit späterem Sprung).
            // Der Cache bleibt Offline-Fallback.
            if let cached = LinkCache.loadMessages(token: token), !cached.isEmpty {
                loaded = cached.sorted { $0.id < $1.id }.filter { !$0.isHiddenSystemMessage }
                self.lastMessageId = loaded.last?.id ?? 0
                if isCovered(loaded) {
                    covered = true
                    publish()
                    offlineNotice = nil
                }
            }
            var anchor = loaded.map(\.id).min() ?? historyAnchor

            // Live-Fetch Phase 1: die NEUESTE Seite (historyAnchor) - der
            // Refresh aktualisiert den Cache-Stand; danach Kettenladen
            // (ganze Seiten) bis die Trennlinie abgedeckt ist (max. 10
            // Seiten Sicherheitscap; tiefer liegende Historie kommt in
            // Phase 2).
            var history = await api.getMessages(token: token, lastKnownId: historyAnchor, future: false, timeoutSeconds: 10) ?? []
            guard gen == self.generation else { return }
            if history.isEmpty, loaded.isEmpty, let cached = LinkCache.loadMessages(token: token) {
                // Server nicht erreichbar (FEHLER oder leer): letzte
                // bekannte Nachrichten zeigen (Offline-Fallback).
                loaded = cached.sorted { $0.id < $1.id }.filter { !$0.isHiddenSystemMessage }
                offlineNotice = NSLocalizedString("_link_offline_", comment: "")
                cacheBannerActive = cacheBannerGate.shouldTrigger()
                covered = true
                publish()
            } else {
                for message in history where loaded.first(where: { $0.id == message.id }) == nil {
                    loaded.append(message)
                }
                loaded.sort { $0.id < $1.id }
                offlineNotice = nil
                // Anchor für die Abdeckungs-Kette auf die älteste geladene
                // Meldung setzen (sonst würde die Kette dieselbe Seite
                // erneut anfordern).
                anchor = loaded.map(\.id).min() ?? anchor
                if isCovered(loaded) {
                    covered = true
                    publish()
                }
            }
            var coverPages = 0
            while gen == self.generation, !Task.isCancelled, !covered, coverPages < 10 {
                coverPages += 1
                let older = await api.getMessages(token: token, lastKnownId: anchor, future: false, timeoutSeconds: 10, saveCache: false) ?? []
                guard gen == self.generation else { return }
                guard !older.isEmpty else {
                    // Gesprächsanfang vor der Trennlinie: alles zeigen.
                    covered = true
                    publish()
                    break
                }
                for message in older where loaded.first(where: { $0.id == message.id }) == nil {
                    loaded.append(message)
                }
                loaded.sort { $0.id < $1.id }
                if isCovered(loaded) {
                    covered = true
                    publish()
                    break
                }
                anchor = loaded.map(\.id).min() ?? anchor
            }

            // P68j: Room-Objekt nachziehen, falls beim Eintritt (z. B. über
            // Deep-Link) noch kein currentRoom vorhanden war - sonst fehlt
            // die "Neue Nachrichten"-Trennlinie (lastReadMessage = 0).
            if self.currentRoom == nil, case let .success(rooms) = self.conversations {
                self.currentRoom = rooms.first(where: { $0.token == token })
            }
            if !covered {
                // Sicherheitsnetz (Cap erreicht): zeigen, was da ist.
                covered = true
                publish()
            }
            // Run-Vereinfachung 10.09.: Phase 2 (Rest-Historie) lädt im
            // Hintergrund nach dem Settle (Vollverlauf statt 7-Tage-Fenster).
            self.windowLoadDone = true
            await self.pollNewMessages(token: token)
        }
    }

    /// Berechnet die erste ungelesene Nachricht aus dem geladenen Fenster.
    private func updateUnreadBoundary(roomLastRead: Int64, roomUnread: Int) {
        guard roomUnread > 0 else {
            unreadBoundary = nil
            return
        }
        guard case let .success(items) = messages else {
            unreadBoundary = nil
            return
        }
        let sorted = items.sorted { $0.id < $1.id }
        if roomLastRead > 0 {
            unreadBoundary = sorted.first(where: { $0.id > roomLastRead })?.id
        } else {
            // lastReadMessage == 0 (frischer Raum/Account bzw. Room-Objekt
            // noch nicht geladen): ALLES im Fenster ist ungelesen - die
            // Trennlinie markiert dann den Anfang der neuen Nachrichten.
            unreadBoundary = sorted.first?.id
        }
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

    /// Run-Vereinfachung 10.09.: Lädt den KOMPLETTEN Verlauf rückwärts in
    /// 100er-Seiten bis zum Gesprächsanfang. Der frühere 7-Tage-/Min-10-
    /// Fenstermechanismus (Pull, Render-Fenster, Re-Anchor) ist entfallen -
    /// inkrementelles Nachladen mit SwiftUI-self-sizing-Zellen lieferte
    /// keine ruhige Scroll-Erfahrung (Log 10.09.: Ketten-Pulls, Zucken).
    /// Fehlerhafte Fetches (nil) werden 1x wiederholt und brechen dann ab,
    /// OHNE den Gesprächsanfang zu markieren. Generation-Guard (Run-Fix):
    /// ein Raumwechsel bricht den Load des VORHERIGEN Raums ab - sonst
    /// veröffentlicht der alte Load in die Nachrichtenliste des neuen
    /// Raums (Kreuzkontamination, Log 10.09. 17:23/17:24).
    private func loadFullHistory(token: String, generation gen: Int) async {
        guard let api, gen == self.generation else { return }
        guard case let .success(current) = messages, !current.isEmpty else {
            hasMoreHistory = false
            return
        }
        var all = current
        var known = Set(all.map(\.id))
        var anchor = all.map(\.id).min() ?? 0
        guard anchor > 0 else {
            hasMoreHistory = false
            return
        }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        var oldestLoaded = all.map(\.timestamp).min() ?? Date.distantFuture.timeIntervalSince1970
        var reachedStart = false
        var pages = 0
        while !Task.isCancelled, pages < 500, gen == self.generation {
            var older = await api.getMessages(token: token, lastKnownId: anchor, future: false, timeoutSeconds: 10, saveCache: false)
            if older == nil, !Task.isCancelled, gen == self.generation {
                // FEHLER (Transport/HTTP/Decode) - NICHT als
                // Gesprächsanfang missdeuten: 1 Retry, danach Abbruch mit
                // unverändertem hasMoreHistory.
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                older = await api.getMessages(token: token, lastKnownId: anchor, future: false, timeoutSeconds: 10, saveCache: false)
            }
            guard let older else {
                CallDebugLog.log("LinkViewModel", "full-history fetch FAILED for \(token) anchor=\(anchor) - aborting (moreOlder stays \(hasMoreHistory))")
                return
            }
            if older.isEmpty {
                // Echte, erfolgreiche Leerantwort = Gesprächsanfang.
                reachedStart = true
                break
            }
            let fresh = older.filter { known.insert($0.id).inserted && !$0.isHiddenSystemMessage }
            let newAnchor = older.map(\.id).min() ?? anchor
            guard newAnchor < anchor else { break }
            anchor = newAnchor
            if !fresh.isEmpty {
                all.append(contentsOf: fresh)
                oldestLoaded = min(oldestLoaded, fresh.map(\.timestamp).min() ?? oldestLoaded)
                if !Task.isCancelled, gen == self.generation {
                    // NICHT sofort publizieren (Insert-oben beim Lesen am
                    // Ende = Herumirren, Log 11.09.): puffern; der
                    // Controller fordert Batches on-demand am Verlaufskopf
                    // an (publishOlderBatch) und haelt dort die Position
                    // ueber den Anker-Scroll.
                    pendingOlderBatches.append(fresh.sorted { $0.id < $1.id })
                }
            }
            if older.count < 100 {
                reachedStart = true
                break
            }
            // Drosselung: Dem Layout/Self-Sizing zwischen den Batches Luft
            // geben, damit die Insert-oben-Kette die Liste nicht flutet
            // (ruhiges Hochscrollen, kein Ruckeln).
            try? await Task.sleep(nanoseconds: 300_000_000)
            pages += 1
        }
        historyChainReachedStart = reachedStart
        hasMoreHistory = (!reachedStart && anchor > 0) || !pendingOlderBatches.isEmpty
        CallDebugLog.log("LinkViewModel", "full history loaded for \(token): total=\(all.count) oldest=\(Int(oldestLoaded)) reachedStart=\(reachedStart) buffered=\(pendingOlderBatches.count) batches")
    }

    /// Publiziert die naechsten gepufferten aelteren Nachrichten (on-demand
    /// am Verlaufskopf, vom Controller angefordert): 1+ Batches bis ~60
    /// Nachrichten in `messages` einfuegen. Der Controller erkennt das
    /// Prepend und haelt die Leseposition ueber den Anker-Scroll. Bei
    /// leerem Puffer wird hasMoreHistory endgueltig gesetzt (dann zeigt
    /// die Bubble "Anfang der Unterhaltung").
    @discardableResult
    func publishOlderBatch() -> Bool {
        guard case let .success(current) = messages else { return false }
        guard !pendingOlderBatches.isEmpty else {
            if historyChainReachedStart {
                hasMoreHistory = false
            }
            return false
        }
        var published = pendingOlderBatches.removeFirst()
        while let next = pendingOlderBatches.first, published.count + next.count <= 60 {
            published.append(contentsOf: pendingOlderBatches.removeFirst())
        }
        messages = .success((published + current).sorted { $0.id < $1.id })
        if pendingOlderBatches.isEmpty, historyChainReachedStart {
            hasMoreHistory = false
        }
        return true
    }

    /// Startet den Vollverlauf-Load im Hintergrund (nach sitzender
    /// Eintrittspositionierung, Run-Vereinfachung 10.09.). Der Load trägt
    /// die aktuelle Generation und verfällt beim Raumwechsel.
    func loadFullHistoryInBackground() {
        guard case let .chat(token, _) = route, hasMoreHistory, !isLoadingHistory else { return }
        guard isOnline else {
            CallDebugLog.log("LinkVM", "offline - full history fetch skipped")
            return
        }
        let gen = generation
        Task { [weak self] in
            await self?.loadFullHistory(token: token, generation: gen)
        }
    }

    private func pollNewMessages(token: String) async {
        guard let api else { return }
        while !Task.isCancelled, case let .chat(currentToken, _) = route, currentToken == token {
            let result = await api.getMessages(token: token, lastKnownId: lastMessageId, future: true, timeoutSeconds: pollTimeout)
            if Task.isCancelled { return }
            // Backoff bei Transport-/HTTP-Fehlern: der fruehere Hot-Loop
            // spamte hunderte Requests pro Sekunde (Log dyd2aaa1ba,
            // Offline-Phase). 1s -> 2s -> ... max 30s, Reset bei Erfolg.
            guard let fresh = result else {
                pollFailureStreak += 1
                let delay = UInt64(min(30, pollFailureStreak) * 1_000_000_000)
                CallDebugLog.log("LinkVM", "poll FAILED (streak \(pollFailureStreak)) - backoff \(delay / 1_000_000_000)s")
                try? await Task.sleep(nanoseconds: delay)
                continue
            }
            pollFailureStreak = 0
            if !fresh.isEmpty {
                // "Anruf fuer alle beenden" (talk-ios NCChatController):
                // der Server schreibt eine Systemnachricht call_ended_
                // everyone/call_ended in den Raum - vor dem (gewuenschten)
                // Filtern auf diese Nachricht pruefen und den aktiven Call
                // fuer diesen Raum beenden (Run-Feedback 12.09.).
                if fresh.contains(where: { ($0.systemMessage == "call_ended_everyone" || $0.systemMessage == "call_ended") && $0.token == token }),
                   LinkVoIPManager.shared.hasActiveCall(for: token) {
                    CallDebugLog.log("LinkVM", "call_ended_everyone received - ending active call for \(token)")
                    LinkVoIPManager.shared.endActiveCall()
                }
                // Zugestellte pendent Nachrichten aus der Queue raeumen:
                // eigene, frische Nachricht mit identischem Text trifft ein
                // -> das ✓✓-Pendant wird zur echten Nachricht.
                let ownTexts = Set(fresh
                    .filter { $0.actorId == currentUserId }
                    .map(\.message))
                if !ownTexts.isEmpty {
                    pendingMessages.removeAll { $0.state == .sent && ownTexts.contains($0.text) }
                }
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
                    .filter { !$0.isHiddenSystemMessage }
                    .filter { !deletedIds.contains($0.id) }
                    .filter { seen.insert($0.id).inserted }
                    .sorted { $0.id < $1.id }
                messages = .success(deduped)
                // Stand in den Cache (offline Re-Entry behaelt zugestellte
                // Nachrichten - Run-Feedback 12.09.).
                LinkCache.saveMessageArray(deduped, token: token)
            }
        }
    }

    func send(text: String, replyTo: Int64? = nil) {
        guard let api else { return }
        guard case let .chat(token, _) = route else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        let outgoing = mentionAwareMessage(trimmed)
        // Offline: in die persistente Warteschlange - die UI leitet die
        // pendent Nachricht direkt aus der Queue ab (Marker inklusive).
        guard isOnline else {
            enqueuePending(token: token, text: outgoing, replyTo: replyTo)
            return
        }
        let gen = generation
        Task { [weak self] in
            let ok = await api.sendMessage(token: token, message: outgoing, replyTo: replyTo)
            guard let self, gen == self.generation else { return }
            if !ok {
                CallDebugLog.log("LinkVM", "send FAILED (online path) - enqueueing as pending")
                await MainActor.run {
                    self.enqueuePending(token: token, text: outgoing, replyTo: replyTo)
                }
            }
        }
    }

    /// Sendet alle geparkten Nachrichten EINES Raums der Reihe nach;
    /// bricht beim ersten Fehler ab (noch offline).
    private var isFlushingPending = false

    func flushPendingMessages(token: String) {
        guard isOnline, let api else { return }
        // NUR .queued senden: ein zweites "back ONLINE"-Event durfte die
        // .sent-Eintraege (warten auf Poll-Bestaetigung) erneut senden ->
        // Doppel-Zustellung + falsche Reihenfolge (Run-Feedback 12.09.,
        // Log dznyaaa1lp: Monitor feuerte 08:31 UND 08:32).
        guard !isFlushingPending else { return }
        let queue = pendingMessages.filter { $0.token == token && $0.state == .queued }
        guard !queue.isEmpty else { return }
        isFlushingPending = true
        CallDebugLog.log("LinkVM", "flushing \(queue.count) queued pending messages for \(token)")
        Task { [weak self] in
            // Guard loest sich erst am ENDE des Flush-Task (defer im sync
            // Teil wuerde sofort zuruecksetzen).
            defer { Task { @MainActor [weak self] in self?.isFlushingPending = false } }
            for pending in queue {
                guard let self, self.isOnline else { return }
                let ok = await api.sendMessage(token: pending.token,
                                               message: pending.text,
                                               replyTo: pending.replyTo)
                guard ok else {
                    CallDebugLog.log("LinkVM", "flush failed - stopping (still offline?)")
                    return
                }
                await MainActor.run {
                    // 2. Haken: Server hat angenommen. Die Zeile bleibt
                    // bestehen, bis die echte Nachricht per Poll eintrifft
                    // (Match in pollNewMessages) - kein Flackern.
                    if let idx = self.pendingMessages.firstIndex(where: { $0.id == pending.id }) {
                        self.pendingMessages[idx].state = .sent
                        self.persistPendingMessages()
                    }
                }
            }
        }
    }

    // MARK: - Offline-Warteschlange

    private func enqueuePending(token: String, text: String, replyTo: Int64?) {
        let pending = LinkPendingMessage(id: nextPendingTempId, token: token,
                                         text: text, replyTo: replyTo,
                                         createdAt: Date().timeIntervalSince1970,
                                         state: .queued)
        nextPendingTempId -= 1
        pendingMessages.append(pending)
        persistPendingMessages()
    }

    private func persistPendingMessages() {
        LinkCache.savePendingMessages(pendingMessages, account: cacheAccountKey)
    }

    private func loadPendingMessages() {
        var loaded = LinkCache.loadPendingMessages(account: cacheAccountKey)
        // Defensive: doppelte IDs in der Persistenz filtern (kein Fall
        // heute, aber eine Diffable-Duplikat-Assertion darf nie entstehen).
        var seen = Set<Int64>()
        loaded = loaded.filter { seen.insert($0.id).inserted }
        pendingMessages = loaded
        // KRITISCH: den Temp-ID-Zaehler HINTER die geladenen IDs setzen.
        // Ohne das kollidierte die erste neue Nachricht nach einem
        // App-Neustart mit einer persistierten ID (beide -1) -> doppelte
        // Item-Identifier im Diffable-Snapshot -> SIGABRT (TestFlight-
        // Crashs 12.09., offline um 00:22/00:23).
        nextPendingTempId = (loaded.map(\.id).min() ?? 0) - 1
    }

    private var cacheAccountKey: String {
        LinkAccount.active()?.account ?? "unknown"
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                if online, !self.isOnline {
                    self.isOnline = true
                    CallDebugLog.log("LinkVM", "network back ONLINE - flushing pending queue")
                    // Offene Nachrichten aller Raeume der Reihe nach senden.
                    let tokens = Set(self.pendingMessages.map(\.token))
                    for token in tokens {
                        self.flushPendingMessages(token: token)
                    }
                    // Raum-Poll neu starten: der Offline-Eintrag hat die
                    // Live-Kette uebersprungen (Run 12.09.).
                    if case let .chat(token, _) = self.route {
                        self.pollTask?.cancel()
                        self.pollTask = Task { [weak self] in
                            await self?.pollNewMessages(token: token)
                        }
                    }
                } else if !online, self.isOnline {
                    self.isOnline = false
                    CallDebugLog.log("LinkVM", "network OFFLINE - sends go to pending queue")
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "souvera.link.pathmonitor"))
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
            let history = await api?.getMessages(token: token, lastKnownId: historyAnchor, future: false, timeoutSeconds: 10) ?? []
            let ordered = history.sorted { $0.id < $1.id }.filter { !$0.isHiddenSystemMessage }
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
        if let accountChangeObserver {
            NotificationCenter.default.removeObserver(accountChangeObserver)
        }
        if let linkRoomsObserver {
            NotificationCenter.default.removeObserver(linkRoomsObserver)
        }
        if let refreshObserver {
            NotificationCenter.default.removeObserver(refreshObserver)
        }
        if let reloadObserver {
            NotificationCenter.default.removeObserver(reloadObserver)
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

    // MARK: - Raum-Polling (Vordergrund)

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
            }
        }
    }

    func stopRoomPolling() {
        roomPollTask?.cancel()
        roomPollTask = nil
    }

}

/// Kurzer Rückmelde-Hinweis für Link-Aktionen (Toast).
struct LinkActionFeedback: Equatable {
    let success: Bool
    let message: String
}
