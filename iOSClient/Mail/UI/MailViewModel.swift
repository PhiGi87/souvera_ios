// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// View model for the native mail client. Supports two transports:
//   - JMAP (default, NCBrandOptions.shared.useJmapMail == true) - mirrors the
//     Android client and talks to Stalwart via JmapClient/JmapApi.
//   - IMAP/SMTP (fallback) via MailImapClient.
// The active transport is shown in the UI ("Mail via JMAP" / "Mail via IMAP").
//
// Message lists are cached locally (compressed JSON snapshots) and refreshed
// incrementally via Email/queryChanges when a previous query state is known;
// on network failure the last cached state is shown.

import Combine
import Foundation

enum MailUiState<T> {
    case loading
    case success(T)
    case error(String)
}

enum MailRoute: Equatable {
    case folders
    case messages(mailbox: Mailbox)
    case detail(message: MailMessage)
    case compose
    case search

    /// Detail-Message der aktuellen Route (nil = keine Detailansicht).
    var detailMessage: MailMessage? {
        if case let .detail(message) = self { return message }
        return nil
    }

    /// true = Detailansicht aktiv (Liste bleibt darunter gemountet, P62b).
    var isDetail: Bool { detailMessage != nil }

    static func == (lhs: MailRoute, rhs: MailRoute) -> Bool {
        switch (lhs, rhs) {
        case (.folders, .folders), (.compose, .compose), (.search, .search): return true
        case let (.messages(a), .messages(b)): return a.id == b.id
        case let (.detail(a), .detail(b)): return a.id == b.id
        default: return false
        }
    }
}

@MainActor
final class MailViewModel: ObservableObject {
    @Published var route: MailRoute = .folders
    /// true, solange der ERSTE Ladevorgang nach dem Öffnen der App läuft:
    /// Die Ordnerliste wird dann noch nicht angezeigt (kein Flash), sondern
    /// ein neutraler Spinner; danach wird direkt der letzte Ordner geöffnet.
    @Published private(set) var isInitialLoad = true

    /// Zuletzt geöffnete Mailbox (UserDefaults) - beim App-Start wird
    /// direkt dieser Ordner statt der Ordnerliste angezeigt. PRO ACCOUNT
    /// (kein Vermischen zwischen Accounts).
    private static let lastMailboxKey = "souvera_mail_last_mailbox_id_"
    static func lastMailboxId(account: String) -> String? {
        let key = lastMailboxKey + account
        if UserDefaults.standard.string(forKey: key) == nil {
            // Migration: alten globalen Wert übernehmen.
            if let legacy = UserDefaults.standard.string(forKey: "souvera_mail_last_mailbox_id") {
                UserDefaults.standard.set(legacy, forKey: key)
                UserDefaults.standard.removeObject(forKey: "souvera_mail_last_mailbox_id")
                return legacy
            }
        }
        return UserDefaults.standard.string(forKey: key)
    }
    static func setLastMailboxId(_ id: String, account: String) {
        UserDefaults.standard.set(id, forKey: lastMailboxKey + account)
    }
    @Published var mailboxes: MailUiState<[Mailbox]> = .loading
    @Published var messages: MailUiState<[MailMessage]> = .loading
    @Published var body: MailUiState<MessageBody> = .loading
    @Published var fromAddress = ""
    @Published var fromName = ""
    @Published var fromAddresses: [String] = []
    @Published var ownEmailLabel = ""
    @Published var isSending = false
    @Published var sendError: String?
    @Published var searchResults: MailUiState<[MailMessage]> = .success([])
    @Published var offlineNotice: String?
    /// Transienter Trigger für den "Server-Error: Cache aktiv"-Banner
    /// (fade-in beim Öffnen, fade-out nach 3 s).
    @Published var cacheBannerActive = false
    @Published var composeContext: MailComposeContext?
    @Published var sendFeedback: MailSendFeedback?
    @Published var expandedMailboxIds: Set<String> = []
    @Published var collapsedGroupIds: Set<String> = []
    @Published var folderScrollPosition: String?
    /// Rückmeldung für Aktionen (z. B. Absender in die Blacklist) — wird wie
    /// das Sende-Feedback als Banner angezeigt.
    @Published var actionFeedback: MailSendFeedback?
    /// Zeitpunkt des nächsten automatischen Abrufs (für den Countdown-Ring
    /// in der Ordnerübersicht); nil = Auto-Refresh deaktiviert.
    @Published var nextAutoRefreshAt: Date?
    @Published var sortOrder: MailSortOrder = .dateDesc
    /// Scroll-Nachladen: gibt es ältere Mails im aktuellen Ordner?
    @Published var hasMoreMessages = false
    /// Scroll-Nachladen läuft gerade (Sentinel zeigt Spinner).
    @Published var isLoadingMore = false
    /// Netz-Ladevorgang mit LEERER Übersicht (Erstladung ohne Cache bzw.
    /// Scroll-Nachladen): zeigt das Overlay "Mail-Abruf läuft…". Bei
    /// vorhandener (Cache-)Liste bleibt die Ansicht sichtbar und der
    /// Refresh läuft ohne Overlay im Hintergrund.
    @Published private(set) var isFetchingMail = false
    /// Pagination-State des aktuellen Ordners (letzte geladene Id + mehr?).
    private var pageState: (lastId: String?, hasMore: Bool) = (nil, false)

    private var imapClient: MailImapClient?
    private var jmapClient: JmapClient?
    private var jmapApi: JmapApi?
    private var mailAccount: MailAccount?
    var currentMailbox: Mailbox?
    private var allMailboxes: [Mailbox] = []
    private var queryStates: [String: String] = [:]
    private let cacheBannerGate = SouveraCacheBannerGate()
    /// Signatur der Postfachliste (Redundanz-Guard gegen identische
    /// SwiftUI-Updates).
    private var mailboxesSignature = ""
    /// Mail-IDs, deren Flags lokal geändert wurden (mailboxId → emailIds).
    /// Der inkrementelle Sync lädt diese immer frisch nach, weil Flag-
    /// Änderungen in queryChanges nicht als Query-Änderung auftauchen.
    private var dirtyFlagIds: [String: Set<String>] = [:]
    private var identityId: String?
    private var allIdentities: [[String: Any]] = []
    private var hasRecoveredCredential = false
    /// Zeitpunkt des letzten Recovery-Versuchs - nach 10 Minuten wird ein
    /// neuer Versuch erlaubt (kein Dauer-Offline nach einmaligem Fehlschlag).
    private var lastRecoveryAttempt: Date?
    private var cameFromSearch = false
    private var lastSearchQuery = ""

    private var useJmap: Bool { NCBrandOptions.shared.useJmapMail }
    var transportLabel: String { useJmap ? "JMAP" : "IMAP" }
    var availableMailboxes: [Mailbox] { allMailboxes }

    /// Deep-Link-Beobachter + Pending für den Kaltstart (Link kommt an,
    /// bevor der erste Mailbox-Load fertig ist).
    private var deepLinkObserver: NSObjectProtocol?
    /// P62g: Push-Refresh-Beobachter.
    private var pushRefreshObserver: NSObjectProtocol?
    /// Multi-Account: Account-Wechsel-Beobachter.
    private var accountChangeObserver: NSObjectProtocol?
    /// Multi-Account-Generation: erhöht sich bei jedem Account-Wechsel/
    /// Reset. Laufende asynchrone Ladungen verwerfen veraltete Ergebnisse
    /// (sonst überschreibt ein alter Task den Zustand mit den Mails des
    /// vorherigen Accounts).
    private var generation = 0
    private var pendingDeepLink: SouveraPushDeepLink.Target?

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
        // P62g: Mail-Push (Vordergrund) -> offene Mailbox sofort nachziehen.
        pushRefreshObserver = NotificationCenter.default.addObserver(
            forName: .mailPushReceived,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshOnEntry(force: true)
            }
        }
        // Multi-Account: beim Account-Wechsel den gesamten Mail-Zustand
        // (JmapClient, Cache, UI) auf den neuen Account umstellen.
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(NCGlobal.shared.notificationCenterChangeUser),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetForAccountChange()
            }
        }
    }

    deinit {
        if let deepLinkObserver {
            NotificationCenter.default.removeObserver(deepLinkObserver)
        }
        if let pushRefreshObserver {
            NotificationCenter.default.removeObserver(pushRefreshObserver)
        }
        if let accountChangeObserver {
            NotificationCenter.default.removeObserver(accountChangeObserver)
        }
    }

    private func handleDeepLink(_ target: SouveraPushDeepLink.Target) {
        switch target.kind {
        case .mail:
            if case .success = mailboxes {
                Task { await openMailByJmapId(account: target.account, emailId: target.emailId, mailboxPath: target.mailboxPath) }
            } else {
                pendingDeepLink = target
            }
        default:
            break
        }
    }

    /// Öffnet eine Mail direkt aus einer Push-Notification (Deep-Link):
    /// Ordner-Kontext sicherstellen (mailboxPath, Fallback INBOX), die Mail
    /// per JMAP laden und die Detail-Ansicht öffnen. "Zurück" führt in den
    /// jeweiligen Ordner.
    func openMailByJmapId(account: String, emailId: String, mailboxPath: String = "") async {
        if case let .success(boxes) = mailboxes {
            var contextBox: Mailbox?
            let trimmedPath = mailboxPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPath.isEmpty {
                contextBox = boxes.first(where: { $0.name == trimmedPath || $0.path == trimmedPath })
                    ?? boxes.first(where: { $0.name.lowercased() == trimmedPath.lowercased() || $0.path.lowercased() == trimmedPath.lowercased() })
            }
            if contextBox == nil {
                contextBox = boxes.first(where: { $0.kind == .inbox })
            }
            if let box = contextBox {
                if currentMailbox?.id != box.id {
                    openMailbox(box)
                } else {
                    // P66b: Der Zielordner ist bereits offen - die Liste
                    // trotzdem SOFORT aktualisieren, sonst bleibt sie nach
                    // dem Push-Tap stehen (nur die Detailansicht öffnete).
                    Task { await refreshMessages() }
                }
            }
        }
        guard let api = jmapApi, let client = jmapClient else {
            SouveraLog.write("Mail", "deep link: no jmap client")
            return
        }
        do {
            let session = try await client.refreshSession()
            let accId = currentMailbox?.accountId ?? session.primaryAccountId
            let emails = try await api.getEmails(accountId: accId, ids: [emailId])
            guard let json = emails.first else {
                actionFeedback = MailSendFeedback(
                    success: false,
                    message: NSLocalizedString("_mail_deep_link_missing_", comment: "")
                )
                return
            }
            let mailboxId = currentMailbox?.id ?? ""
            var message = JmapMapper.mapMessage(
                account: mailAccount?.account ?? "",
                accountId: accId,
                mailboxId: mailboxId,
                json: json
            )
            // P62e: Der Push-ObjectId ist serverseitig eine KURZFORM
            // ("93w" statt "dp1yaaa93w"). Email/get beantwortet sie mit der
            // Kurzform, Email/set (gelesen/löschen) wirkt mit ihr aber
            // NICHT (Server-No-Op). Deshalb: die KANONISCHE Zeile (volle
            // ID) aus der Live-Liste per blobId ermitteln und stattdessen
            // verwenden - sonst entstehen Duplikate, das Gelesen-Markieren
            // zieht nicht und Swipe-Löschungen kommen wieder.
            if let fetchedBlobId = message.blobId,
               case let .success(items) = messages,
               let canonical = items.first(where: { $0.blobId == fetchedBlobId }) {
                message = canonical
                SouveraLog.write("Mail", "deep link: canonical id found for \(emailId) -> \(canonical.emailId)")
            }
            // P66b: Die Mail SOFORT in die Liste mergen, damit die Übersicht
            // augenblicklich stimmt (der Refresh läuft parallel weiter).
            // P62c: Die Mail bleibt bis zum Server-Nachweis GESCHÜTZT -
            // parallele Sync-Publishes können sie nicht mehr entfernen
            // (das war die Ursache "Mail fehlt nach Zurück").
            protectedListIds.insert(message.emailId)
            if case let .success(items) = messages,
               !items.contains(where: { $0.emailId == message.emailId || ($0.blobId != nil && $0.blobId == message.blobId) }) {
                var updated = items
                updated.insert(message, at: 0)
                messages = .success(updated)
            }
            // Über openMessage statt direkt route = .detail: lädt den Body
            // (Cache-first, Fallbacks) und markiert die Mail als gelesen -
            // sonst bliebe der Body der VORHERIGEN Mail sichtbar und die
            // Mail ungelesen.
            openMessage(message)
        } catch {
            SouveraLog.write("Mail", "deep link mail failed: \(error.localizedDescription)")
            actionFeedback = MailSendFeedback(
                success: false,
                message: NSLocalizedString("_mail_deep_link_failed_", comment: "")
            )
        }
    }

    /// Applies the selected sort order to a loaded message list.
    func sortMessages(_ list: [MailMessage]) -> [MailMessage] {
        switch sortOrder {
        case .dateDesc:
            return list.sorted { $0.dateSent > $1.dateSent }
        case .dateAsc:
            return list.sorted { $0.dateSent < $1.dateSent }
        case .unreadFirst:
            return list.sorted {
                if $0.isRead != $1.isRead { return !$0.isRead }
                return $0.dateSent > $1.dateSent
            }
        }
    }

    func start() {
        if imapClient != nil || jmapClient != nil { return }
        startAutoRefresh()
        Task {
            let manager = SouveraMailCredentialManager()
            guard let account = await manager.ensureCombinedCredential() else {
                mailboxes = .error(errorText(NSLocalizedString("_mail_credential_failed_", comment: "")))
                isInitialLoad = false
                return
            }
            applyAccount(account)
            await loadMailboxes()
            isInitialLoad = false
            if let pending = pendingDeepLink {
                pendingDeepLink = nil
                handleDeepLink(pending)
            }
            await loadAliases()
            await loadIdentities()
        }
    }

    private var autoRefreshTask: Task<Void, Never>?
    private var lastAutoRefresh: Date = Date()

    /// Periodically refreshes the open mailbox in the foreground according to
    /// the "Hintergrundaktualisierung" setting. Publishes the next refresh
    /// time so the folder list can render a countdown ring.
    func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let interval = SouveraAutoRefresh.interval else {
                    if self.nextAutoRefreshAt != nil {
                        self.nextAutoRefreshAt = nil
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
                let next = self.lastAutoRefresh.addingTimeInterval(interval)
                if self.nextAutoRefreshAt != next {
                    self.nextAutoRefreshAt = next
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastAutoRefresh) >= interval {
                    self.lastAutoRefresh = Date()
                    self.nextAutoRefreshAt = Date().addingTimeInterval(interval)
                    guard self.composeContext == nil else { continue }
                    if self.currentMailbox != nil {
                        await self.refreshMessagesIncremental()
                    } else {
                        // Ordnerübersicht: Postfächer (Ungelesen-Zähler) aktualisieren
                        await self.loadMailboxes(autoOpenInbox: false)
                    }
                }
            }
        }
    }

    /// Multi-Account: nach einem Account-Wechsel den kompletten Mail-Zustand
    /// verwerfen und mit dem aktiven Account neu aufbauen (JmapClient,
    /// Cache-/UI-Zustand - kein Vermischen zwischen Accounts).
    private func resetForAccountChange() {
        generation += 1
        imapClient = nil
        jmapClient = nil
        jmapApi = nil
        mailAccount = nil
        currentMailbox = nil
        allMailboxes = []
        queryStates = [:]
        pageState = (nil, false)
        hasMoreMessages = false
        isLoadingMore = false
        identityId = nil
        allIdentities = []
        hasRecoveredCredential = false
        lastRecoveryAttempt = nil
        mailboxesSignature = ""
        dirtyFlagIds = [:]
        expandedMailboxIds = []
        collapsedGroupIds = []
        fromAddress = ""
        fromName = ""
        fromAddresses = []
        ownEmailLabel = ""
        mailboxes = .loading
        messages = .loading
        body = .loading
        searchResults = .success([])
        offlineNotice = nil
        sendError = nil
        isInitialLoad = true
        start()
    }

    /// Re-runs the setup from scratch, re-minting the mail credential if the
    /// server rejected the stored one.
    func retry() {
        generation += 1
        imapClient = nil
        jmapClient = nil
        jmapApi = nil
        mailAccount = nil
        mailboxes = .loading
        start()
    }

    private func applyAccount(_ account: MailAccount) {
        mailAccount = account

        let mailLogin = account.saslUser
        fromAddress = mailLogin
        fromAddresses = [mailLogin]
        ownEmailLabel = mailLogin
        fromName = NCManageDatabase.shared.getActiveTableAccount()?.displayName ?? account.username

        if useJmap {
            let baseUrl = account.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let client = JmapClient(
                baseUrl: baseUrl,
                username: mailLogin,
                password: account.mailPassword
            )
            jmapClient = client
            jmapApi = JmapApi(client: client)
        } else {
            imapClient = MailImapClient(account: account)
        }
    }

    private func recoverCredentialAndReload() async {
        if hasRecoveredCredential {
            guard let lastRecoveryAttempt, Date().timeIntervalSince(lastRecoveryAttempt) >= 600 else { return }
        }
        hasRecoveredCredential = true
        lastRecoveryAttempt = Date()
        SouveraLog.write("Mail", "credential recovery attempt (renewCombinedCredential)")
        guard let renewed = await SouveraMailCredentialManager().renewCredential() else {
            SouveraLog.write("Mail", "credential recovery FAILED")
            mailboxes = .error(errorText(NSLocalizedString("_mail_credential_failed_", comment: "")))
            return
        }
        // Frisches MailAccount anwenden: baut den JmapClient komplett neu
        // auf (Session-Cache weg).
        applyAccount(renewed)
        // Validierung: Liefert die neue Credential eine Session MIT Accounts?
        // Falls nicht (Server-Mint-Problem), EINMAL erneut minten.
        var validated = false
        if let session = try? await jmapClient?.refreshSession(), isSessionUsable(session) {
            validated = true
        }
        if !validated {
            SouveraLog.write("Mail", "mint validation failed - retrying once")
            if let renewed2 = await SouveraMailCredentialManager().renewCredential() {
                applyAccount(renewed2)
                if let session = try? await jmapClient?.refreshSession(), isSessionUsable(session) {
                    validated = true
                }
            }
        }
        mailboxes = .loading
        SouveraLog.write("Mail", "credential renewed (validated=\(validated)) - reloading")
        await loadMailboxes(autoOpenInbox: false)
    }

    private func errorText(_ message: String) -> String {
        "\(SouveraBuildInfo.label)\n\nMail via \(transportLabel)\n\n\(message)"
    }

    private func loadAliases() async {
        guard let account = mailAccount else { return }
        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else { return }
        let baseUrl = tbl.urlBase
        let root = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(root)/ocs/v2.php/apps/souvera_mail/api/v1/aliases") else { return }
        var req = URLRequest(url: url)
        let davPassword = NCPreferences().getPassword(account: account.account)
        let raw = "\(account.username):\(davPassword)"
        req.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = json["ocs"] as? [String: Any],
              let data = ocs["data"] as? [[String: Any]] else { return }
        let aliases = data.compactMap { $0["alias"] as? String ?? $0["email"] as? String }
        for alias in aliases where !fromAddresses.contains(alias) {
            fromAddresses.append(alias)
        }
    }

    private func loadIdentities() async {
        guard useJmap, let api = jmapApi else { return }
        do {
            let session = try await jmapClient?.refreshSession()
            let accId = session?.primaryAccountId ?? ""
            let identities = try await api.getIdentities(accountId: accId)
            allIdentities = identities
            identityId = identity(for: fromAddress) ?? identities.first?.optString("id")
        } catch {
            identityId = nil
        }
    }

    /// The JMAP Identity matching the given from-address, if any.
    private func identity(for address: String) -> String? {
        allIdentities.first(where: { ($0.optString("email") ?? "") == address })?.optString("id")
    }

    // MARK: - Folders

    /// Lädt die Postfachliste neu. `autoOpenInbox` steuert, ob danach
    /// automatisch der Posteingang geöffnet wird - nur beim Start/Retry
    /// gewünscht, niemals bei internen Aktualisierungen (Badge-Abgleich etc.),
    /// weil der Routen-Wechsel den Nutzer aus der aktuellen Ansicht wirft.
    func loadMailboxes(autoOpenInbox: Bool = true) async {
        // Cache-First: letzten Postfach-Stand sofort anzeigen (kein Spinner
        // nach dem ersten Login), Live-Load ersetzt ihn im Hintergrund.
        if case .loading = mailboxes,
           let cached = MailCache.loadMailboxes(account: mailAccount?.account ?? "") {
            let boxes = sortMailboxGroups(filterNonStandardSentFolders(cached.map { mailbox(from: $0) }))
            applyMailboxes(boxes)
        }
        if useJmap {
            await loadMailboxesJmap(autoOpenInbox: autoOpenInbox)
        } else {
            await loadMailboxesImap(autoOpenInbox: autoOpenInbox)
        }
        updateUnreadBadge()
    }

    /// Sofortiger Badge-Zähler (persönlicher Posteingang).
    @Published private(set) var personalInboxUnread: Int = 0

    private func postUnreadBadge(_ count: Int) {
        personalInboxUnread = max(0, count)
        JmapLog.write("Mail unread badge -> \(personalInboxUnread)")
        // Per-Account-Badge (der Tab-Badge folgt dem AKTIVEN Account; das
        // System-Badge korrigiert der Background-Sync als Summe).
        NotificationCenter.default.post(
            name: .mailUnreadChanged,
            object: nil,
            userInfo: ["account": mailAccount?.account ?? "", "count": personalInboxUnread]
        )
    }

    /// Ungelesen gesamt → Badge am Mail-Tab (NotificationCenter).
    func updateUnreadBadge() {
        let count: Int
        if case let .success(boxes) = mailboxes {
            // Nur der Posteingang des eigenen Postfachs zählt.
            count = boxes
                .filter { $0.kind == .inbox && $0.namespace == .personal }
                .reduce(0) { $0 + $1.unreadCount }
        } else {
            count = personalInboxUnread
        }
        postUnreadBadge(count)
    }

    private func loadMailboxesImap(autoOpenInbox: Bool) async {
        guard let client = imapClient else { return }
        switch await client.fetchMailboxes() {
        case let .success(boxes):
            applyMailboxes(sortMailboxGroups(boxes))
            if autoOpenInbox {
                openPreferredMailbox(allMailboxes)
            }
        case let .failure(message):
            if message.contains("[AUTH]"), !hasRecoveredCredential {
                await recoverCredentialAndReload()
                return
            }
            mailboxes = .error(errorText(message))
        }
    }

    private func loadMailboxesJmap(autoOpenInbox: Bool) async {
        guard let api = jmapApi else { return }
        let gen = generation
        do {
            let session = try await jmapClient?.refreshSession()
            guard gen == self.generation else { return }
            // Leere Accounts = tote Credential: sofort erneuern.
            if !isSessionUsable(session) {
                SouveraLog.write("Mail", "session with empty accounts - recovering credential")
                let blocked = hasRecoveredCredential
                    && (lastRecoveryAttempt.map { Date().timeIntervalSince($0) < 600 } ?? false)
                if !blocked {
                    await recoverCredentialAndReload()
                    return
                }
                mailboxes = .error(errorText(NSLocalizedString("_mail_credential_failed_", comment: "")))
                return
            }
            let primaryAccId = session?.primaryAccountId ?? ""
            let accountName = mailAccount?.account ?? ""
            ownEmailLabel = session?.username ?? mailAccount?.username ?? ownEmailLabel

            var all: [Mailbox] = []
            var rawBoxes: [[String: Any]] = []

            // Personal mailboxes.
            let personalList = try await api.getMailboxes(accountId: primaryAccId)
            all += personalList.map {
                JmapMapper.mapMailbox(account: accountName, accountId: primaryAccId, json: $0)
            }
            rawBoxes += personalList.map { cacheMailboxJson($0, accountId: primaryAccId, path: nil, owner: nil, namespace: "personal") }

            // Shared mailboxes: session accounts with isPersonal=false.
            if let session {
                for sharedAcc in session.accounts.values where !sharedAcc.isPersonal && sharedAcc.id != primaryAccId {
                    guard let sharedList = try? await api.getMailboxes(accountId: sharedAcc.id) else {
                        continue // shared mailbox might not be accessible
                    }
                    for json in sharedList {
                        let name = json.optString("name") ?? "?"
                        let path = "\(sharedAcc.name)/\(name)"
                        all.append(JmapMapper.mapMailbox(
                            account: accountName,
                            accountId: sharedAcc.id,
                            json: json,
                            path: path,
                            namespace: .shared,
                            ownerIdentity: sharedAcc.name
                        ))
                        rawBoxes.append(cacheMailboxJson(json, accountId: sharedAcc.id, path: path, owner: sharedAcc.name, namespace: "shared"))
                    }
                }
            }

            let sorted = sortMailboxGroups(filterNonStandardSentFolders(all))
            applyMailboxes(sorted)
            // Verbindung steht wieder: Recovery-Sperre zurücksetzen.
            hasRecoveredCredential = false
            MailCache.saveMailboxes(account: accountName, boxes: rawBoxes)
            if autoOpenInbox {
                openPreferredMailbox(sorted)
            }
        } catch {
            // Auth-Fehler: Recovery (mit 10-Minuten-Sperre im Gate) statt
            // dauerhaftem Cache/Offline.
            if isJmapAuthRecoverable(error) {
                let blocked = hasRecoveredCredential
                    && (lastRecoveryAttempt.map { Date().timeIntervalSince($0) < 600 } ?? false)
                if !blocked {
                    SouveraLog.write("Mail", "mailboxes 401 (pwd=…\(SouveraMailCredentialManager.suffix(mailAccount?.mailPassword ?? ""))) - renewing credential")
                    await recoverCredentialAndReload()
                    return
                }
            }
            // Cache-Fallback bei JEDEM Fehler (auch 404/HTML/nicht-JSON vom
            // Server): letzten Stand anzeigen statt Fehlerbildschirm.
            if let cached = MailCache.loadMailboxes(account: mailAccount?.account ?? "") {
                let boxes = cached.map { mailbox(from: $0) }
                let sorted = sortMailboxGroups(filterNonStandardSentFolders(boxes))
                applyMailboxes(sorted)
                offlineNotice = NSLocalizedString("_mail_offline_", comment: "")
                cacheBannerActive = cacheBannerGate.shouldTrigger()
                if autoOpenInbox {
                    openPreferredMailbox(sorted)
                }
                return
            }
            JmapLog.write("mailbox load failed: \(error.localizedDescription)")
            let summary = await jmapClient?.diagnosticSummary() ?? ""
            let message = error.localizedDescription + (summary.isEmpty ? "" : "\n\n\(summary)")
            mailboxes = .error(errorText(message))
        }
    }

    private func cacheMailboxJson(_ json: [String: Any], accountId: String, path: String?, owner: String?, namespace: String) -> [String: Any] {
        var dict = json
        dict["_accountId"] = accountId
        dict["_path"] = path ?? json.optString("name")
        dict["_owner"] = owner
        dict["_namespace"] = namespace
        dict["_parentId"] = json.optString("parentId")
        return dict
    }

    private func mailbox(from cached: [String: Any]) -> Mailbox {
        var box = JmapMapper.mapMailbox(
            account: mailAccount?.account ?? "",
            accountId: cached.optString("_accountId") ?? "",
            json: cached,
            path: cached.optString("_path"),
            namespace: cached.optString("_namespace") == "shared" ? .shared : .personal,
            ownerIdentity: cached.optString("_owner")
        )
        // mapMailbox reads parentId from json["parentId"]; cached snapshots
        // store it under "_parentId", so patch it in.
        if let parentId = cached.optString("_parentId") {
            box = Mailbox(
                id: box.id, account: box.account, accountId: box.accountId,
                name: box.name, path: box.path, kind: box.kind,
                unreadCount: box.unreadCount, messageCount: box.messageCount,
                jmapId: box.jmapId, role: box.role, namespace: box.namespace,
                ownerIdentity: box.ownerIdentity, parentId: parentId,
                mayRename: box.mayRename, mayDelete: box.mayDelete,
                mayCreateChild: box.mayCreateChild
            )
        }
        return box
    }

    /// Hides non-special-use mailboxes named "Sent" when the account has a
    /// real sent special-use mailbox ("Sent Items" on Stalwart).
    private func filterNonStandardSentFolders(_ boxes: [Mailbox]) -> [Mailbox] {
        var result = boxes
        for accId in Set(boxes.map(\.accountId)) {
            let group = boxes.filter { $0.accountId == accId }
            guard group.contains(where: { $0.role == "sent" }) else { continue }
            result.removeAll { box in
                box.accountId == accId
                    && box.role == nil
                    && box.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Sent") == .orderedSame
            }
        }
        return result
    }

    /// Builds the collapsible mailbox tree from the JMAP parentId hierarchy.
    func mailboxTree(for boxes: [Mailbox]) -> [MailboxNode] {
        let byParent = Dictionary(grouping: boxes) { $0.parentId ?? "" }
        func children(of id: String?) -> [MailboxNode] {
            let list = byParent[id ?? ""] ?? []
            return list
                .sorted { (kindOrder($0.kind), $0.name.lowercased()) < (kindOrder($1.kind), $1.name.lowercased()) }
                .map { MailboxNode(mailbox: $0, children: children(of: $0.jmapId)) }
        }
        return children(of: nil)
    }

    /// Personal mailboxes first (kind order), then shared groups by owner.
    private func sortMailboxGroups(_ boxes: [Mailbox]) -> [Mailbox] {
        let personal = boxes.filter { $0.namespace == .personal }
            .sorted { (kindOrder($0.kind), $0.name.lowercased()) < (kindOrder($1.kind), $1.name.lowercased()) }
        let shared = boxes.filter { $0.namespace != .personal }
            .sorted {
                let lhsOwner = $0.ownerIdentity ?? $0.path.components(separatedBy: "/").first ?? ""
                let rhsOwner = $1.ownerIdentity ?? $1.path.components(separatedBy: "/").first ?? ""
                if lhsOwner != rhsOwner { return lhsOwner < rhsOwner }
                if kindOrder($0.kind) != kindOrder($1.kind) { return kindOrder($0.kind) < kindOrder($1.kind) }
                return $0.name.lowercased() < $1.name.lowercased()
            }
        return personal + shared
    }

    private func isJmapAuthRecoverable(_ error: Error) -> Bool {
        guard let jmapError = error as? JmapException else { return false }
        // Echte Auth-Ablehnungen (Session-GET-401 UND POST-401) lösen eine
        // Credential-Erneuerung aus - ein Verbindungsproblem nicht.
        switch jmapError {
        case .authNeedsBearer:
            return true
        case .httpError(let code, _):
            return code == 401
        default:
            return false
        }
    }

    // MARK: - Ordner-Verwaltung (JMAP Mailbox/set)

    /// Legt einen Ordner an - auf Root-Ebene (parent nil) oder als
    /// Unterordner des übergebenen Elternordners.
    func createMailbox(name: String, parent: Mailbox?) async {
        guard let api = jmapApi, let client = jmapClient,
              let session = try? await client.refreshSession() else { return }
        let accId = parent?.accountId ?? session.primaryAccountId
        var create: [String: Any] = ["name": name]
        if let parentId = parent?.jmapId, !parentId.isEmpty {
            create["parentId"] = parentId
        }
        do {
            _ = try await api.setMailboxes(accountId: accId, create: [create])
            JmapLog.write("Mailbox created: \(name) parent=\(parent?.jmapId ?? "root")")
            await loadMailboxes(autoOpenInbox: false)
        } catch {
            JmapLog.write("Mailbox create failed: \(error)")
        }
    }

    /// Benennt einen Ordner um (nur bei mayRename).
    func renameMailbox(_ mailbox: Mailbox, to name: String) async {
        guard let api = jmapApi, let client = jmapClient,
              let id = mailbox.jmapId, !id.isEmpty,
              (try? await client.refreshSession()) != nil else { return }
        do {
            _ = try await api.setMailboxes(accountId: mailbox.accountId, update: [["id": id, "name": name]])
            JmapLog.write("Mailbox renamed: \(mailbox.name) -> \(name)")
            await loadMailboxes(autoOpenInbox: false)
        } catch {
            JmapLog.write("Mailbox rename failed: \(error)")
        }
    }

    /// Löscht einen Ordner (nur bei mayDelete); `removeEmails` steuert, ob
    /// die enthaltenen Mails mitgelöscht werden (onDestroyRemoveEmails).
    func deleteMailbox(_ mailbox: Mailbox, removeEmails: Bool) async {
        guard let api = jmapApi, let client = jmapClient,
              let id = mailbox.jmapId, !id.isEmpty,
              (try? await client.refreshSession()) != nil else { return }
        do {
            _ = try await api.setMailboxes(
                accountId: mailbox.accountId,
                destroy: [id],
                onDestroyRemoveEmails: removeEmails
            )
            JmapLog.write("Mailbox destroyed: \(mailbox.name) removeEmails=\(removeEmails)")
            if currentMailbox?.id == mailbox.id {
                currentMailbox = nil
                route = .folders
            }
            await loadMailboxes(autoOpenInbox: false)
        } catch {
            JmapLog.write("Mailbox destroy failed: \(error)")
        }
    }

    func emptyTrash() async {
        guard let mailbox = currentMailbox else { return }
        var ok = false
        if useJmap {
            guard let api = jmapApi, let client = jmapClient,
                  let jmapMailboxId = mailbox.jmapId, !jmapMailboxId.isEmpty else {
                actionFeedback = MailSendFeedback(
                    success: false,
                    message: NSLocalizedString("_mail_trash_empty_failed_", comment: "")
                )
                return
            }
            do {
                _ = try await client.refreshSession()
                // ALLE Mails des Papierkorbs erfassen (paginiert) - nicht nur
                // die aktuell geladene Seite.
                var allIds: [String] = []
                var lastId: String?
                for _ in 0..<50 {
                    let resp = try await api.queryEmails(
                        accountId: mailbox.accountId,
                        inMailboxId: jmapMailboxId,
                        limit: 100,
                        anchor: lastId,
                        position: lastId == nil ? 0 : 1
                    )
                    let ids = (resp["ids"] as? [String]) ?? []
                    guard !ids.isEmpty else { break }
                    allIds.append(contentsOf: ids)
                    if ids.count < 100 { break }
                    lastId = ids.last
                }
                // In Batches löschen und das Ergebnis PRÜFEN (notDestroyed).
                var notDestroyed = 0
                var index = 0
                while index < allIds.count {
                    let end = min(index + 100, allIds.count)
                    let batch = Array(allIds[index..<end])
                    let resp = try await api.deleteEmails(accountId: mailbox.accountId, emailIds: batch)
                    notDestroyed += (resp["notDestroyed"] as? [Any])?.count ?? 0
                    index = end
                }
                ok = notDestroyed == 0
                JmapLog.write("emptyTrash: \(allIds.count) mails, notDestroyed=\(notDestroyed)")
            } catch {
                JmapLog.write("emptyTrash jmap failed: \(error)")
                ok = false
            }
        } else {
            ok = await imapClient?.emptyMailbox(mailboxPath: mailbox.path) ?? false
        }
        actionFeedback = MailSendFeedback(
            success: ok,
            message: ok
                ? NSLocalizedString("_mail_trash_emptied_", comment: "")
                : NSLocalizedString("_mail_trash_empty_failed_", comment: "")
        )
        if ok {
            // Cache/Query-State des Papierkorbs invalidieren, Liste leeren.
            let accountName = mailAccount?.account ?? ""
            MailCache.remove(account: accountName, mailboxId: mailbox.id)
            queryStates.removeValue(forKey: mailbox.id)
            dirtyFlagIds.removeValue(forKey: mailbox.id)
            pageState = (nil, false)
            hasMoreMessages = false
            messages = .success([])
            await loadMailboxes(autoOpenInbox: false)
        }
    }

    // MARK: - Shield Blacklist

    /// Übernimmt die Absender der Nachrichten in die Shield-Blacklist.
    func blacklistSenders(_ messages: [MailMessage]) async {
        let addresses = Array(Set(messages.map { $0.fromAddress.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }))
        guard !addresses.isEmpty else { return }
        let api = ShieldApi()
        var succeeded = 0
        for address in addresses {
            if await api.add(.blacklist, entry: address) {
                succeeded += 1
            }
        }
        if succeeded == addresses.count {
            actionFeedback = MailSendFeedback(
                success: true,
                message: String(format: NSLocalizedString("_mail_blacklist_success_", comment: ""), succeeded)
            )
        } else if succeeded > 0 {
            actionFeedback = MailSendFeedback(
                success: true,
                message: String(format: NSLocalizedString("_mail_blacklist_partial_", comment: ""), succeeded, addresses.count)
            )
        } else {
            actionFeedback = MailSendFeedback(
                success: false,
                message: NSLocalizedString("_mail_blacklist_failed_", comment: "")
            )
        }
    }

    /// „Blacklist & löschen": löscht zuerst (über die FIFO-Queue) und trägt
    /// danach die Absender in die Shield-Blacklist ein. Genau EIN kombiniertes
    /// Feedback statt zweier konkurrierender Schreiber (sonst überschreibt
    /// der langsamere Blacklist-Lauf das Lösch-Feedback).
    func blacklistAndDelete(_ messages: [MailMessage]) async {
        let ids = messages.map(\.emailId)
        optimisticRemove(ids)
        let previous = deleteWorkTask
        await previous?.value
        let deleted = await performDelete(messages, ids: ids)
        // Queue-Marker aktualisieren, damit Folge-Löschungen hinter uns laufen.
        deleteWorkTask = Task {}

        let addresses = Array(Set(messages.map { $0.fromAddress.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }))
        var blacklisted = 0
        if !addresses.isEmpty {
            let api = ShieldApi()
            for address in addresses {
                if await api.add(.blacklist, entry: address) {
                    blacklisted += 1
                }
            }
        }

        let blacklistOk = addresses.isEmpty || blacklisted == addresses.count
        if deleted && blacklistOk {
            actionFeedback = MailSendFeedback(
                success: true,
                message: NSLocalizedString("_mail_blacklist_deleted_", comment: "")
            )
        } else if deleted {
            actionFeedback = MailSendFeedback(
                success: false,
                message: NSLocalizedString("_mail_blacklist_failed_", comment: "")
            )
        } else if blacklistOk {
            actionFeedback = MailSendFeedback(
                success: false,
                message: NSLocalizedString("_mail_delete_failed_", comment: "")
            )
        } else {
            actionFeedback = MailSendFeedback(
                success: false,
                message: NSLocalizedString("_mail_blacklist_failed_", comment: "")
            )
        }
    }

    // MARK: - Messages

    func openMailbox(_ mailbox: Mailbox) {
        Self.setLastMailboxId(mailbox.id, account: mailAccount?.account ?? "")
        // Talk-Muster (markNotificationsAsRead): Beim Öffnen des Post-
        // eingangs zugestellte Mail-Notifications aus der Mitteilungs-
        // zentrale entfernen.
        if mailbox.kind == .inbox {
            Self.clearDeliveredMailNotifications()
        }
        currentMailbox = mailbox
        route = .messages(mailbox: mailbox)
        listGeneration += 1
        protectedListIds.removeAll()
        messages = .loading
        pageState = (nil, false)
        hasMoreMessages = false
        isLoadingMore = false
        prefetchGeneration += 1
        Task { await syncMessages() }
    }

    private static func clearDeliveredMailNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { $0.request.identifier.hasPrefix("mail_") }
                .map { $0.request.identifier }
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    /// Öffnet beim App-Start den ZULETZT benutzten Ordner (Fallback INBOX).
    private func openPreferredMailbox(_ boxes: [Mailbox]) {
        if let lastId = Self.lastMailboxId(account: mailAccount?.account ?? ""),
           let last = boxes.first(where: { $0.id == lastId }) {
            openMailbox(last)
            return
        }
        if let inbox = boxes.first(where: { $0.kind == .inbox }) {
            openMailbox(inbox)
        }
    }

    func syncMessages() async {
        guard let mailbox = currentMailbox else { return }
        let generation = listGeneration
        // Cache-First: letzten Nachrichten-Snapshot SOFORT anzeigen, der
        // Live-Sync ersetzt ihn im Hintergrund. Spinner nur ohne Cache
        // (erster Aufruf nach Login).
        let accountName = mailAccount?.account ?? ""
        if case .loading = messages,
           let snapshot = MailCache.loadMessages(account: accountName, mailboxId: mailbox.id) {
            guard generation == listGeneration else { return }
            // P62f: Cache-first-Publish filtern (optimistisch entfernte Mails
            // dürfen nicht wieder auftauchen).
            let filteredSnapshot = snapshot.emails.filter { !pendingRemovedIds.contains($0.optString("id") ?? "") }
            messages = .success(filteredSnapshot.map {
                JmapMapper.mapMessage(account: accountName, accountId: mailbox.accountId, mailboxId: mailbox.id, json: $0)
            })
        }
        if useJmap {
            await syncMessagesJmap(mailbox)
        } else {
            await syncMessagesImap(mailbox)
        }
    }

    private func syncMessagesImap(_ mailbox: Mailbox) async {
        guard let client = imapClient else { return }
        let generation = listGeneration
        switch await client.syncMessages(mailboxPath: mailbox.path) {
        case let .success(list):
            guard generation == listGeneration else { return }
            hasMoreMessages = false
            pageState = (nil, false)
            messages = .success(list)
        case let .failure(message):
            guard generation == listGeneration else { return }
            messages = .error(errorText(message))
        }
    }

    private func syncMessagesJmap(_ mailbox: Mailbox, forceFullRefresh: Bool = false) async {
        guard let api = jmapApi else { return }
        let accountGen = self.generation
        // P62c: Sync-In-Flight-Guard - läuft bereits ein Sync dieser
        // Mailbox, wird der neue Wunsch nur vorgemerkt und danach EINMAL
        // nachgezogen (keine parallelen Publishes, die sich überschreiben).
        let generation = listGeneration
        guard !mailboxSyncInFlight else {
            mailboxSyncQueued = true
            return
        }
        mailboxSyncInFlight = true
        defer {
            mailboxSyncInFlight = false
            if mailboxSyncQueued, listGeneration == generation {
                mailboxSyncQueued = false
                Task { [weak self] in await self?.refreshMessages() }
            }
        }
        do {
            let session = try await jmapClient?.refreshSession()
            guard accountGen == self.generation else { return }
            // Leere Accounts = tote Credential: erneuern und neu laden.
            if !isSessionUsable(session) {
                SouveraLog.write("Mail", "sync: session with empty accounts - recovering credential")
                let blocked = hasRecoveredCredential
                    && (lastRecoveryAttempt.map { Date().timeIntervalSince($0) < 600 } ?? false)
                if !blocked {
                    await recoverCredentialAndReload()
                    if let mailbox = currentMailbox { openMailbox(mailbox) }
                    return
                }
            }
            let accId = mailbox.accountId
            guard !accId.isEmpty else {
                messages = .error(errorText("Mailbox has no JMAP account id"))
                return
            }
            guard let jmapMailboxId = mailbox.jmapId, !jmapMailboxId.isEmpty else {
                messages = .error(errorText("Mailbox has no JMAP ID"))
                return
            }
            let accountName = mailAccount?.account ?? ""
            let cacheKey = mailbox.id
            offlineNotice = nil

            // 1) Incremental refresh via Email/queryChanges when a previous
            //    query state and a cached snapshot are known.
            if !forceFullRefresh,
               let state = queryStates[cacheKey],
               let snapshot = MailCache.loadMessages(account: accountName, mailboxId: cacheKey) {
                do {
                    let changes = try await api.queryEmailChanges(accountId: accId, sinceState: state, inMailboxId: jmapMailboxId)
                    let removed = Set((changes["removed"] as? [String]) ?? [])
                    // Stalwart returns `added` as objects [{id, index}] (RFC
                    // 8620 allows both plain ids and positioned objects).
                    let added: [String] = (changes["added"] as? [Any])?.compactMap { item in
                        if let id = item as? String { return id }
                        if let dict = item as? [String: Any], let id = dict["id"] as? String { return id }
                        return nil
                    } ?? []
                    // Flag-Änderungen (gelesen/ungelesen, Flag) sind KEINE
                    // Query-Result-Änderungen - queryChanges liefert sie
                    // nicht. Lokal geänderte Nachrichten deshalb immer frisch
                    // nachladen, sonst würde ein inkrementeller Sync den
                    // alten (Cache-)Zustand zurückspielen.
                    let dirty = Array(dirtyFlagIds[cacheKey] ?? [])
                    var emails = snapshot.emails.filter { !removed.contains($0.optString("id") ?? "") }
                    let refetch = Array(Set(added + dirty))
                    if !refetch.isEmpty {
                        let fetched = try await api.getEmails(accountId: accId, ids: refetch)
                        emails = mergeEmails(existing: emails, incoming: fetched)
                        dirtyFlagIds[cacheKey] = nil
                    }
                    let newState = changes.optString("newQueryState") ?? state
                    guard generation == listGeneration else { return }
                    queryStates[cacheKey] = newState
                    // P62f: Auch den CACHE-Save filtern - sonst re-seedet der
                    // inkrementelle Sync (Snapshot von VOR der Löschung) die
                    // gelöschten Mails in den Cache (Reappear-Muster).
                    let keptEmails = emails.filter { !self.pendingRemovedIds.contains($0.optString("id") ?? "") }
                    MailCache.saveMessages(account: accountName, mailboxId: cacheKey, emails: keptEmails, queryState: newState)
                    messages = .success(filterPendingRemoved(protectingLiveMessages(emails.map { JmapMapper.mapMessage(account: accountName, accountId: accId, mailboxId: cacheKey, json: $0) })))
                    pageState = (lastId: emails.last?.optString("id"), hasMore: emails.count >= 100)
                    hasMoreMessages = pageState.hasMore
                    JmapLog.write("sync \(mailbox.name) incremental: added=\(added.count) removed=\(removed.count) dirty=\(dirty.count)")
                    return
                } catch {
                    // Incremental path failed - fall through to a full refresh.
                }
            }

            // 2) Full refresh: Seiten à 100 laden und an die bestehende
            //    Liste anhängen (Merge + Dedupe), bis (a) eine Seite
            //    unvollständig ist (Ende des Postfachs) oder (b) mindestens
            //    30 Tage abgedeckt sind. Der Rest kommt per Scroll nach.
            let pageSize = 100
            let minimumCoverage = Date().addingTimeInterval(-30 * 86400)
            // Bestehenden Cache-Snapshot als Basis behalten: bereits per
            // Scroll geladene ältere Mails bleiben erhalten, frische Seiten
            // überschreiben überlappende Einträge.
            var byId: [String: [String: Any]] = [:]
            if let snapshot = MailCache.loadMessages(account: accountName, mailboxId: cacheKey) {
                for email in snapshot.emails {
                    if let id = email.optString("id") { byId[id] = email }
                }
            }
            // Cache-first: gespeicherten Stand SOFORT anzeigen (Übersicht
            // bleibt nie leer); der Refresh läuft dann im Hintergrund ohne
            // Overlay. Ohne Cache: Overlay "Mail-Abruf läuft…" zeigen und
            // die Liste progressiv aufbauen.
            if byId.isEmpty {
                isFetchingMail = true
            } else {
                let cachedList = byId.values.sorted { ($0["receivedAt"] as? String ?? "") > ($1["receivedAt"] as? String ?? "") }
                messages = .success(filterPendingRemoved(protectingLiveMessages(cachedList.map { JmapMapper.mapMessage(account: accountName, accountId: accId, mailboxId: cacheKey, json: $0) })))
            }
            var lastId: String?
            var hasMore = false
            var state = ""
            let maxPages = 3
            var oldestDate: Date?
            for _ in 0..<maxPages {
                // Pro-Seite-Fehlerisolation: Schlägt eine Folgeseite fehl,
                // bricht der Loop ab und die bereits geladenen Mails werden
                // angezeigt - KEIN Offline-Fallback, nur weil Seite 2+
                // zickt (das war die Offline-Regression des letzten Builds).
                let ids: [String]
                let page: [[String: Any]]
                do {
                    let resp = try await api.queryEmails(
                        accountId: accId,
                        inMailboxId: jmapMailboxId,
                        limit: pageSize,
                        anchor: lastId,
                        position: lastId == nil ? 0 : 1
                    )
                    ids = (resp["ids"] as? [String]) ?? []
                    state = resp.optString("queryState") ?? state
                    guard !ids.isEmpty else { break }
                    page = try await api.getEmails(accountId: accId, ids: ids)
                } catch {
                    // Auth-Fehler NIE verschlucken: der äußere Catch stößt
                    // sonst nie die Credential-Recovery an.
                    if isJmapAuthRecoverable(error) {
                        JmapLog.write("sync \(mailbox.name): auth error on page - \(error.localizedDescription)")
                        throw error
                    }
                    JmapLog.write("sync \(mailbox.name): page failed after \(byId.count) mails - \(error.localizedDescription)")
                    if byId.isEmpty { throw error }
                    break
                }
                var addedCount = 0
                for email in page {
                    guard let id = email.optString("id") else { continue }
                    if byId[id] == nil { addedCount += 1 }
                    byId[id] = email
                }
                lastId = ids.last
                // Ältestes Datum der Seite für die 30-Tage-Abdeckung.
                if let oldest = page.compactMap({ ($0["receivedAt"] as? String) }).sorted().first,
                   let parsed = Self.jmapDate(oldest) {
                    oldestDate = parsed
                }
                let pageHasMore = ids.count >= pageSize
                hasMore = pageHasMore
                // PROGRESSIVER Aufbau: nach jeder Seite die kumulierte Liste
                // publizieren - die Übersicht wächst sichtbar, statt die
                // ganze Zeit nur zu kreiseln.
                let collected = byId.values.sorted { ($0["receivedAt"] as? String ?? "") > ($1["receivedAt"] as? String ?? "") }
                guard generation == listGeneration else { return }
                queryStates[cacheKey] = state
                pageState = (lastId: lastId, hasMore: pageHasMore)
                hasMoreMessages = pageHasMore
                messages = .success(filterPendingRemoved(protectingLiveMessages(collected.map { JmapMapper.mapMessage(account: accountName, accountId: accId, mailboxId: cacheKey, json: $0) })))
                if !pageHasMore {
                    break
                }
                if addedCount > 0, let oldestDate, oldestDate <= minimumCoverage {
                    break
                }
            }
            let collected = byId.values.sorted { ($0["receivedAt"] as? String ?? "") > ($1["receivedAt"] as? String ?? "") }
            guard generation == listGeneration else { return }
            queryStates[cacheKey] = state
            pageState = (lastId: lastId, hasMore: hasMore)
            hasMoreMessages = hasMore
            dirtyFlagIds[cacheKey] = nil
            let savedCollected = collected.filter { !self.pendingRemovedIds.contains($0.optString("id") ?? "") }
            MailCache.saveMessages(account: accountName, mailboxId: cacheKey, emails: savedCollected, queryState: state)
            messages = .success(filterPendingRemoved(protectingLiveMessages(savedCollected.map { JmapMapper.mapMessage(account: accountName, accountId: accId, mailboxId: cacheKey, json: $0) })))
            // P62f-Fix: Erst NACH dem vollständigen Publish des Server-
            // Stands (Voll-Refresh) sind die optimistisch entfernten IDs
            // freigegeben - nur hier, nicht nach gequeueten Refreshes.
            if forceFullRefresh {
                pendingRemovedIds.removeAll()
            }
            isFetchingMail = false
            prefetchBodies(mailbox: mailbox)

            // P64 Stale-Verifikation: Cached-Einträge, die serverseitig nicht
            // mehr existieren (z. B. auf anderem Gerät gelöscht), per Batch
            // Email/get (max. 500 IDs) aus Cache + Liste entfernen. Läuft
            // im Hintergrund nach dem Full-Refresh.
            let finalSnapshot = collected
            let finalState = state
            Task { [weak self] in
                guard let self else { return }
                let cachedIds = finalSnapshot.compactMap { $0.optString("id") }
                guard !cachedIds.isEmpty else { return }
                var missing: [String] = []
                for chunk in stride(from: 0, to: cachedIds.count, by: 500) {
                    guard self.listGeneration == generation else { return }
                    let batch = Array(cachedIds[chunk..<min(chunk + 500, cachedIds.count)])
                    if let fetched = try? await api.getEmails(accountId: accId, ids: batch) {
                        let present = Set(fetched.compactMap { $0.optString("id") })
                        missing += batch.filter { !present.contains($0) }
                    }
                }
                guard !missing.isEmpty, self.listGeneration == generation else { return }
                let removedSet = Set(missing)
                JmapLog.write("P64 stale verification removed \(removedSet.count) of \(cachedIds.count) cached mails")
                var kept = finalSnapshot.filter { !removedSet.contains($0.optString("id") ?? "") }
                kept = kept.filter { !self.pendingRemovedIds.contains($0.optString("id") ?? "") }
                MailCache.saveMessages(account: accountName, mailboxId: cacheKey, emails: kept, queryState: finalState)
                // Live-Liste ebenfalls bereinigen: auf einem anderen Gerät /
                // im Web gelöschte Mails entfernen. NUR Entfernen auf Basis des
                // AKTUELLEN Listenstands (kein Republish des alten Snapshots -
                // das war der Reappear-Race-Kanal).
                if case var .success(list) = self.messages {
                    list.removeAll { removedSet.contains($0.emailId) }
                    self.messages = .success(list)
                }
            }
        } catch {
            isFetchingMail = false
            // 401: Credential erneuern und den aktuellen Ordner neu laden.
            if isJmapAuthRecoverable(error) {
                let blocked = hasRecoveredCredential
                    && (lastRecoveryAttempt.map { Date().timeIntervalSince($0) < 600 } ?? false)
                if !blocked {
                    SouveraLog.write("Mail", "sync 401 for \(mailbox.id) (pwd=…\(SouveraMailCredentialManager.suffix(mailAccount?.mailPassword ?? ""))) - renewing credential")
                    await recoverCredentialAndReload()
                    if let mailbox = currentMailbox {
                        openMailbox(mailbox)
                    }
                    return
                }
            }
            // Cache-Fallback bei JEDEM Fehler (auch Server-Antworten wie
            // 404/HTML/nicht-JSON): letzten Nachrichten-Stand anzeigen.
            guard generation == listGeneration else { return }
            if let cached = MailCache.loadMessages(account: mailAccount?.account ?? "", mailboxId: mailbox.id) {
                let accId = mailbox.accountId
                messages = .success(cached.emails.map {
                    JmapMapper.mapMessage(account: mailAccount?.account ?? "", accountId: accId, mailboxId: mailbox.id, json: $0)
                })
                offlineNotice = NSLocalizedString("_mail_offline_", comment: "")
                cacheBannerActive = cacheBannerGate.shouldTrigger()
                return
            }
            JmapLog.write("sync failed for \(mailbox.id): \(error.localizedDescription)")
            messages = .error(errorText(error.localizedDescription))
        }
    }

    /// Scroll-Nachladen: lädt die nächste Seite älterer Mails des aktuellen
    /// Ordners und hängt sie an die Liste an (Merge + Dedupe, Cache-Save).
    /// Kein Paging-UI - die Liste wächst nahtlos beim Scrollen.
    func loadMore() {
        guard useJmap, !isLoadingMore, hasMoreMessages,
              let mailbox = currentMailbox, let api = jmapApi,
              let jmapMailboxId = mailbox.jmapId, !jmapMailboxId.isEmpty,
              let lastId = pageState.lastId, !lastId.isEmpty else { return }
        let generation = listGeneration
        isLoadingMore = true
        // Nachgeladene Mails sind nicht im Cache: Overlay zeigen.
        isFetchingMail = true
        Task {
            defer { isLoadingMore = false }
            do {
                _ = try await jmapClient?.refreshSession()
                let accId = mailbox.accountId
                let accountName = mailAccount?.account ?? ""
                let resp = try await api.queryEmails(accountId: accId, inMailboxId: jmapMailboxId, limit: 100, anchor: lastId, position: 1)
                let ids = (resp["ids"] as? [String]) ?? []
                guard !ids.isEmpty else {
                    hasMoreMessages = false
                    pageState = (lastId: lastId, hasMore: false)
                    return
                }
                let page = try await api.getEmails(accountId: accId, ids: ids)
                let snapshot = MailCache.loadMessages(account: accountName, mailboxId: mailbox.id)
                var emails = snapshot?.emails ?? []
                var known = Set(emails.compactMap { $0.optString("id") })
                var added = 0
                for email in page {
                    guard let id = email.optString("id"), !known.contains(id) else { continue }
                    emails.append(email)
                    known.insert(id)
                    added += 1
                }
                emails.sort { ($0["receivedAt"] as? String ?? "") > ($1["receivedAt"] as? String ?? "") }
                let hasMore = ids.count >= 100
                guard generation == listGeneration else { return }
                pageState = (lastId: ids.last, hasMore: hasMore)
                hasMoreMessages = hasMore
                let keptEmails = emails.filter { !self.pendingRemovedIds.contains($0.optString("id") ?? "") }
                MailCache.saveMessages(account: accountName, mailboxId: mailbox.id, emails: keptEmails, queryState: snapshot?.queryState ?? "")
                messages = .success(filterPendingRemoved(protectingLiveMessages(keptEmails.map { JmapMapper.mapMessage(account: accountName, accountId: accId, mailboxId: mailbox.id, json: $0) })))
                prefetchBodies(mailbox: mailbox)
                JmapLog.write("loadMore \(mailbox.name): page=\(ids.count) added=\(added) hasMore=\(hasMore)")
                isFetchingMail = false
            } catch {
                hasMoreMessages = false
                isFetchingMail = false
                JmapLog.write("loadMore failed for \(mailbox.id): \(error.localizedDescription)")
            }
        }
    }

    /// Generation des aktuellen Postfachs - ein Wechsel bricht laufende
    /// Prefetch-Queues ab.
    private var prefetchGeneration = 0

    /// List-Generation (P62): Zählt Ordner-Wechsel. Läuft noch ein
    /// Sync des ALTEN Ordners, darf dessen Ergebnis NICHT mehr in den
    /// Zustand des NEUEN Ordners schreiben (Flap-Fix). Auch loadMore
    /// und Prefetch hängen an dieser Generation.
    private var listGeneration = 0

    /// P62c: Mail-IDs, die Sync-Publishes überleben MÜSSEN (z. B. die per
    /// Deep-Link geöffnete Mail, die noch nicht im Server-Snapshot stand).
    /// Jeder Publish vereinigt die Liste mit diesen Live-Einträgen.
    private var protectedListIds: Set<String> = []

    /// P62c: Sync-In-Flight-Guard - kein zweiter voller Sync derselben
    /// Mailbox parallel (die parallelen Syncs überschrieben sich sonst
    /// gegenseitig und warfen die Deep-Link-Mail wieder raus).
    private var mailboxSyncInFlight = false
    private var mailboxSyncQueued = false
    /// P62d: Debounce-Task für den Refresh nach Mutationen (Löschen/
    /// Verschieben) - ein Refresh nach der LETZTEN Mutation statt pro Swipe.
    private var mutationRefreshTask: Task<Void, Never>?
    /// P62f: Optimistisch entfernte Mail-IDs - Sync-Publishes und Cache-Saves
    /// filtern sie, bis der Debounce-Refresh (Server-Wahrheit) bestätigt.
    /// Verhindert das Wiederauftauchen gelöschter Mails durch parallel
    /// laufende Syncs (log-belegter Reappear).
    private var pendingRemovedIds: Set<String> = []
    /// P62f: FIFO für Lösch-/Move-Tasks (keine parallelen Session-Races
    /// zwischen Folge-Löschungen).
    private var deleteWorkTask: Task<Void, Never>?

    /// P62c: Vereinigt einen Publish mit den Live-Einträgen, deren IDs
    /// geschützt sind (Deep-Link-Mail) - bis der Server sie selbst liefert.
    private func protectingLiveMessages(_ published: [MailMessage]) -> [MailMessage] {
        guard !protectedListIds.isEmpty else { return published }
        let publishedIds = Set(published.map(\.emailId))
        // P62e: Auch per blobId deduplizieren - die serverseitige Kurz-ID
        // ("93w") und die kanonische ID ("dp1yaaa93w") sind dieselbe Mail;
        // ohne blobId-Vergleich würde die geschützte Kurz-ID-Zeile neben
        // der kanonischen Zeile doppelt erscheinen.
        let publishedBlobs = Set(published.compactMap(\.blobId))
        let protected = protectedListIds.filter { id in
            guard !publishedIds.contains(id) else { return false }
            if case let .success(live) = messages,
               let liveMessage = live.first(where: { $0.emailId == id }),
               let blob = liveMessage.blobId {
                return !publishedBlobs.contains(blob)
            }
            return true
        }
        guard !protected.isEmpty else {
            protectedListIds.subtract(publishedIds)
            return published
        }
        var result = published
        if case let .success(live) = messages {
            for message in live where protected.contains(message.emailId) {
                result.append(message)
            }
        }
        result.sort { $0.dateSent > $1.dateSent }
        return result
    }

    /// P62f: Filtert optimistisch entfernte IDs aus einer Publish-Liste.
    private func filterPendingRemoved(_ published: [MailMessage]) -> [MailMessage] {
        guard !pendingRemovedIds.isEmpty else { return published }
        return published.filter { !pendingRemovedIds.contains($0.emailId) }
    }

    /// IMAP-artiger Voll-Cache: lädt die Bodies der geladenen Mails im
    /// Hintergrund nach (gedrosselt, abbrechbar, überspringt Gecachtes).
    private func prefetchBodies(mailbox: Mailbox) {
        guard useJmap else { return }
        prefetchGeneration += 1
        let generation = prefetchGeneration
        guard case let .success(items) = messages else { return }
        let accountName = mailAccount?.account ?? ""
        let targets = items.prefix(25).filter {
            MailCache.loadBody(account: accountName, emailId: $0.emailId) == nil
        }
        guard !targets.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            // Keine (verwertbare) Session = tote Credential: Prefetch
            // aussetzen, sonst feuern 25x Email/get sinnlos gegen 401.
            guard let session = try? await self.jmapClient?.refreshSession(),
                  self.isSessionUsable(session) else { return }
            for message in targets {
                guard self.prefetchGeneration == generation,
                      self.currentMailbox?.id == mailbox.id else { return }
                if MailCache.loadBody(account: accountName, emailId: message.emailId) != nil { continue }
                if let fetched = await self.loadBodyFor(message) {
                    MailCache.saveBody(account: accountName, emailId: message.emailId, body: fetched)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            JmapLog.write("prefetch done for \(mailbox.name) (\(targets.count) mails)")
        }
    }

    /// Lädt den Body einer Mail (JSON → mapBody → Blob-Downloads).
    private func loadBodyFor(_ message: MailMessage) async -> MessageBody? {
        guard let json = await fetchMessageJson(message) else { return nil }
        var mapped = JmapMapper.mapBody(json: json)
        let accId = message.accountId
        if mapped.plainText == nil, let textPart = (json["textBody"] as? [[String: Any]])?.first,
           let blobId = textPart.optString("blobId"), !blobId.isEmpty {
            mapped = MessageBody(
                plainText: (try? await downloadTextBlob(accountId: accId, blobId: blobId)) ?? nil,
                html: mapped.html,
                attachments: mapped.attachments
            )
        }
        if mapped.html == nil, let htmlPart = (json["htmlBody"] as? [[String: Any]])?.first,
           htmlPart.optString("type") == "text/html",
           let blobId = htmlPart.optString("blobId"), !blobId.isEmpty {
            mapped = MessageBody(
                plainText: mapped.plainText,
                html: (try? await downloadTextBlob(accountId: accId, blobId: blobId)) ?? nil,
                attachments: mapped.attachments
            )
        }
        return mapped
    }

    /// JMAP-Datum (receivedAt) parsen (ISO8601 mit/ohne Bruchteile).
    private static func jmapDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: value)
    }

    /// True, wenn die JMAP-Session gültige Accounts hat. Stalwart liefert
    /// bei toter/abgelaufener Credential eine LEERE Gast-Session (200 mit
    /// accounts={}) statt 401 - das muss als Auth-Problem erkannt werden.
    private func isSessionUsable(_ session: JmapSessionInfo?) -> Bool {
        guard let session else { return false }
        return !session.primaryAccountId.isEmpty && !session.accounts.isEmpty
    }

    /// True for network-level failures (no/slow connection), false for
    /// protocol or server errors that should be shown as-is.
    private func isOfflineError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .internationalRoamingOff, .dataNotAllowed, .callIsActive:
                return true
            default:
                return false
            }
        }
        if let jmapError = error as? JmapException {
            if case .protocolError(let message) = jmapError {
                return message.contains("timed out")
            }
        }
        return false
    }

    /// Pull-to-refresh: always a full query so read/unread states stay fresh.
    /// Der bestehende Listenstand bleibt während des Ladens sichtbar.
    func refreshMessages() async {
        guard let mailbox = currentMailbox else { return }
        if useJmap {
            await syncMessagesJmap(mailbox, forceFullRefresh: true)
        } else {
            await syncMessagesImap(mailbox)
        }
        // Badge autoritativ nachziehen - extern ankommende Mails würden
        // sonst erst mit dem nächsten Postfach-Load zählen.
        await refreshUnreadBadge()
    }

    /// P62g: Modul-Eintritt / Push: die offene Mailbox SOFORT (inkrementell)
    /// nachziehen, damit neue Mails nicht erst mit dem Auto-Refresh-Timer
    /// auftauchen. Gedrosselt (~8 s), außer `force` (Push) oder das
    /// NSE-Flag "souvera_mail_refresh_needed" ist gesetzt (Mail-Push kam,
    /// während die App zu war).
    private static let refreshNeededFlagKey = "souvera_mail_refresh_needed"
    private var lastEntryRefresh: Date = .distantPast

    func refreshOnEntry(force: Bool = false) {
        guard let mailbox = currentMailbox else { return }
        let groupDefaults = UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup)
        let flagSet = (groupDefaults?.bool(forKey: Self.refreshNeededFlagKey)) ?? false
        if flagSet {
            groupDefaults?.set(false, forKey: Self.refreshNeededFlagKey)
        }
        let elapsed = Date().timeIntervalSince(lastEntryRefresh)
        guard force || flagSet || elapsed >= 8 else { return }
        lastEntryRefresh = Date()
        JmapLog.write("refreshOnEntry (force=\(force) flag=\(flagSet))")
        // P62g: VOLLER Refresh beim Eintritt - Stalwarts queryChanges meldet
        // neue Mails unzuverlässig; der Voll-Refresh garantiert den
        // Server-Stand (neue Mails sofort). Throttle oben verhindert Exzesse.
        Task { await refreshMessages() }
    }

    /// P62f: Inkrementeller Refresh (queryChanges statt Voll-Refresh) -
    /// für den Auto-Refresh-Timer (sonst lädt jeder Zyklus 300 Mails neu).
    func refreshMessagesIncremental() async {
        guard let mailbox = currentMailbox else { return }
        if useJmap {
            await syncMessagesJmap(mailbox, forceFullRefresh: false)
        } else {
            await syncMessagesImap(mailbox)
        }
        await refreshUnreadBadge()
    }

    /// Autoritative Ungelesen-Zählung für den persönlichen Posteingang
    /// (JMAP Email/query mit notKeyword $seen) - aktualisiert Badge und
    /// Ordnerzähler. Fallback: komplette Postfachliste (unreadEmails).
    func refreshUnreadBadge() async {
        if useJmap {
            if let api = jmapApi, let client = jmapClient,
               let session = try? await client.refreshSession() {
                let accId = session.primaryAccountId
                if let boxes = try? await api.getMailboxes(accountId: accId),
                   let inbox = boxes.first(where: { ($0["role"] as? String) == "inbox" }),
                   let inboxId = inbox["id"] as? String,
                   let resp = try? await api.queryEmails(accountId: accId, inMailboxId: inboxId, limit: 0, calculateTotal: true, notKeyword: "$seen"),
                   let total = resp["total"] as? Int {
                    JmapLog.write("Mail unread count (Email/query) -> \(total)")
                    postUnreadBadge(total)
                    applyUnreadCountToMailboxList(total)
                    return
                }
            }
        }
        // Server nicht erreichbar: Badge aus dem Postfach-Cache
        // rekonstruieren (Roh-JSON enthält unreadEmails der Inbox).
        if let cached = MailCache.loadMailboxes(account: mailAccount?.account ?? ""),
           let inbox = cached.first(where: { ($0["role"] as? String) == "inbox" }) {
            let total = inbox["unreadEmails"] as? Int ?? 0
            JmapLog.write("Mail unread count (cache) -> \(total)")
            postUnreadBadge(total)
            if currentMailbox != nil {
                applyUnreadCountToMailboxList(total)
            }
            return
        }
        await loadMailboxes(autoOpenInbox: false)
    }

    /// Setzt den absoluten Ungelesen-Zähler des persönlichen Posteingangs
    /// in der Ordnerliste (absolute Variante des Delta-Pfads).
    private func applyUnreadCountToMailboxList(_ count: Int) {
        guard let mailbox = currentMailbox,
              mailbox.kind == .inbox, mailbox.namespace == .personal else { return }
        var updated = allMailboxes.map { box -> Mailbox in
            guard box.id == mailbox.id else { return box }
            var copy = box
            copy.unreadCount = max(0, count)
            return copy
        }
        allMailboxes = updated
        if case let .success(boxes) = mailboxes {
            updated = boxes.map { box -> Mailbox in
                guard box.id == mailbox.id else { return box }
                var copy = box
                copy.unreadCount = max(0, count)
                return copy
            }
            mailboxes = .success(updated)
        }
    }

    private func mergeEmails(existing: [[String: Any]], incoming: [[String: Any]]) -> [[String: Any]] {
        var byId: [String: [String: Any]] = [:]
        for email in existing {
            if let id = email.optString("id") { byId[id] = email }
        }
        for email in incoming {
            if let id = email.optString("id") { byId[id] = email }
        }
        return byId.values.sorted { ($0.optString("receivedAt") ?? "") > ($1.optString("receivedAt") ?? "") }
    }

    // MARK: - Detail
    func openMessage(_ message: MailMessage, fromSearch: Bool = false) {
        cameFromSearch = fromSearch
        route = .detail(message: message)
        body = .loading
        // P62e: Gelesen-Status SOFORT lokal flippen (vor dem Server-Call) -
        // beim Zurückwechseln in die Übersicht ist die Zeile damit ohne
        // Verzögerung korrekt. Der Server-Call persistiert anschließend
        // (setRead erhält bewusst das ORIGINAL-Message, damit das
        // Badge-Delta korrekt berechnet bleibt).
        if !message.isRead {
            var flipped = message
            flipped.isRead = true
            updateLocalMessage(flipped)
            Task { await setRead([message], true) }
        }
        Task {
            if useJmap {
                await openMessageJmap(message)
            } else {
                await openMessageImap(message)
            }
        }
    }

    private func openMessageImap(_ message: MailMessage) async {
        guard let client = imapClient, let mailbox = currentMailbox, let uid = UInt64(message.emailId) else { return }
        switch await client.fetchBody(mailboxPath: mailbox.path, uid: uid) {
        case let .success(b):
            body = .success(b)
            // P62e: Read-Marking läuft bereits zentral in openMessage.
        case let .failure(m):
            body = .error(errorText(m))
        }
    }

    private func openMessageJmap(_ message: MailMessage) async {
        let accountName = mailAccount?.account ?? ""
        // Cache-First: Gecachten Body SOFORT anzeigen (auch offline lesbar),
        // der Live-Load ersetzt ihn im Hintergrund.
        if let cached = MailCache.loadBody(account: accountName, emailId: message.emailId) {
            body = .success(cached)
        }
        guard let json = await fetchMessageJson(message) else {
            JmapLog.write("openMessage failed: no Email/get JSON for \(message.emailId)")
            if case .success = body {
                return // Cache-Stand bleibt sichtbar
            }
            body = .error(errorText("Message not found"))
            return
        }
        var mapped = JmapMapper.mapBody(json: json)
        let accId = message.accountId
        JmapLog.write("openMessage \(message.emailId): keys=\(json.keys.sorted().joined(separator: ",")) plain=\(mapped.plainText != nil) html=\(mapped.html != nil)")
        if mapped.plainText == nil, let textPart = (json["textBody"] as? [[String: Any]])?.first,
           let blobId = textPart.optString("blobId"), !blobId.isEmpty {
            mapped = MessageBody(
                plainText: (try? await downloadTextBlob(accountId: accId, blobId: blobId)) ?? nil,
                html: mapped.html,
                attachments: mapped.attachments
            )
        }
        if mapped.html == nil, let htmlPart = (json["htmlBody"] as? [[String: Any]])?.first,
           htmlPart.optString("type") == "text/html",
           let blobId = htmlPart.optString("blobId"), !blobId.isEmpty {
            mapped = MessageBody(
                plainText: mapped.plainText,
                html: (try? await downloadTextBlob(accountId: accId, blobId: blobId)) ?? nil,
                attachments: mapped.attachments
            )
        }
        // Gesendete Mails haben oft NUR einen text/plain-Part (der dann auch
        // als htmlBody auftaucht) - der darf nicht als HTML gerendert werden,
        // sonst kollabiert das WKWebView alle Zeilenumbrüche. Ohne echtes
        // HTML bleibt html=nil und der Text-Pfad zeigt die Umbrüche korrekt.
        // Letzter Fallback: weder Inline- noch Blob-Body bekommen - die Mail
        // noch einmal mit den Standard-Properties (ohne bodyProperties)
        // nachladen, bevor eine leere Ansicht entsteht.
        if mapped.plainText == nil, mapped.html == nil {
            JmapLog.write("openMessage \(message.emailId): body empty, retrying with default properties")
            if let fallback = await fetchMessageJson(message, withBodyProperties: false) {
                let retried = JmapMapper.mapBody(json: fallback)
                if retried.plainText != nil || retried.html != nil {
                    JmapLog.write("openMessage \(message.emailId): fallback body loaded")
                    mapped = MessageBody(
                        plainText: retried.plainText,
                        html: retried.html,
                        attachments: retried.attachments
                    )
                }
            }
        }
        MailCache.saveBody(account: accountName, emailId: message.emailId, body: mapped)
        body = .success(mapped)
    }

    /// Fetches the full Email/get JSON for a message (Android-parity body
    /// properties). With `withBodyProperties` false the default property set
    /// is used (fallback when the trimmed set yields no body).
    private func fetchMessageJson(_ message: MailMessage, withBodyProperties: Bool = true) async -> [String: Any]? {
        guard let api = jmapApi,
              let client = jmapClient,
              let session = try? await client.refreshSession()
        else { return nil }
        let accId = message.accountId.isEmpty ? session.primaryAccountId : message.accountId
        let bodyProperties: [String]? = withBodyProperties ? ["partId", "blobId", "size", "type", "name"] : nil
        guard let list = try? await api.getEmails(accountId: accId, ids: [message.emailId], bodyProperties: bodyProperties) else {
            return nil
        }
        return list.first
    }

    private func downloadTextBlob(accountId: String, blobId: String) async throws -> String? {
        guard let client = jmapClient else { return nil }
        let data = try await client.downloadBlob(accountId: accountId, blobId: blobId, mimeType: "text/plain")
        return String(data: data, encoding: .utf8)?.normalizedLineEndings()
    }

    // MARK: - Flags (read/unread, flagged)

    func setRead(_ messagesToMark: [MailMessage], _ read: Bool) async {
        guard let first = messagesToMark.first else { return }
        // Badge-Delta VOR der lokalen Aktualisierung berechnen, sonst ist
        // `isRead` bereits der neue Wert und das Delta wäre immer 0.
        var badgeDelta = 0
        if currentMailbox?.kind == .inbox, currentMailbox?.namespace == .personal {
            for message in messagesToMark {
                if read && !message.isRead { badgeDelta -= 1 }
                if !read && message.isRead { badgeDelta += 1 }
            }
        }
        if useJmap {
            guard let api = jmapApi,
                  let client = jmapClient,
                  let session = try? await client.refreshSession() else { return }
            let accId = first.accountId.isEmpty ? session.primaryAccountId : first.accountId
            let ids = messagesToMark.map(\.emailId)
            if read {
                _ = try? await api.setEmailFlags(accountId: accId, emailIds: ids, keywordsToAdd: ["$seen": true])
            } else {
                _ = try? await api.setEmailFlags(accountId: accId, emailIds: ids, keywordsToRemove: ["$seen"])
            }
            for message in messagesToMark {
                applyLocalKeyword(message, keyword: "$seen", value: read)
            }
        } else {
            guard let client = imapClient, let mailbox = currentMailbox else { return }
            for message in messagesToMark {
                guard let uid = UInt64(message.emailId) else { continue }
                _ = await client.setFlag(mailboxPath: mailbox.path, uid: uid, flag: .seen, value: read)
                applyLocalKeyword(message, keyword: "$seen", value: read)
            }
        }
        // Badge + Ordnerzähler sofort lokal anpassen - KEIN loadMailboxes()
        // hinterher: dessen openMailbox würde die Route umschalten und den
        // Nutzer aus Detail-/Listenansicht werfen.
        if badgeDelta != 0 {
            postUnreadBadge(personalInboxUnread + badgeDelta)
        }
        applyUnreadDeltaToMailboxList(delta: badgeDelta)
    }

    /// Setzt die Postfachliste nur, wenn sich die Signatur geändert hat
    /// (verhindert redundante SwiftUI-Updates und List-Diff-Probleme).
    private func applyMailboxes(_ boxes: [Mailbox]) {
        let signature = boxes.map { "\($0.id):\($0.unreadCount):\($0.messageCount)" }.joined(separator: ",")
        guard signature != mailboxesSignature else { return }
        mailboxesSignature = signature
        allMailboxes = boxes
        mailboxes = .success(boxes)
    }

    /// Zieht ein Unread-Delta lokal durch die Postfachliste (Badge-Abgleich
    /// ohne Server-Roundtrip), damit Ordnerzähler nicht veralten.
    private func applyUnreadDeltaToMailboxList(delta: Int) {
        guard delta != 0, let mailbox = currentMailbox else { return }
        var updated = allMailboxes.map { box -> Mailbox in
            guard box.id == mailbox.id else { return box }
            var copy = box
            copy.unreadCount = max(0, copy.unreadCount + delta)
            return copy
        }
        if updated != allMailboxes {
            allMailboxes = updated
        }
        if case let .success(boxes) = mailboxes {
            updated = boxes.map { box -> Mailbox in
                guard box.id == mailbox.id else { return box }
                var copy = box
                copy.unreadCount = max(0, copy.unreadCount + delta)
                return copy
            }
            mailboxes = .success(updated)
        }
    }

    func toggleFlagged(_ message: MailMessage) {
        Task {
            let newValue = !message.isFlagged
            if useJmap {
                guard let api = jmapApi,
                      let client = jmapClient,
                      let session = try? await client.refreshSession() else { return }
                let accId = message.accountId.isEmpty ? session.primaryAccountId : message.accountId
                if newValue {
                    _ = try? await api.setEmailFlags(accountId: accId, emailIds: [message.emailId], keywordsToAdd: ["$flagged": true])
                } else {
                    _ = try? await api.setEmailFlags(accountId: accId, emailIds: [message.emailId], keywordsToRemove: ["$flagged"])
                }
            } else {
                guard let client = imapClient, let mailbox = currentMailbox, let uid = UInt64(message.emailId) else { return }
                _ = await client.setFlag(mailboxPath: mailbox.path, uid: uid, flag: .flagged, value: newValue)
            }
            applyLocalKeyword(message, keyword: "$flagged", value: newValue)
            if currentMailbox == nil, !lastSearchQuery.isEmpty {
                await search(lastSearchQuery)
            }
        }
    }

    /// Updates the in-memory message (list + detail + search results) and the
    /// cached snapshot for a keyword change.
    private func applyLocalKeyword(_ message: MailMessage, keyword: String, value: Bool) {
        var updated = message
        if keyword == "$seen" {
            updated.isRead = value
        } else if keyword == "$flagged" {
            updated.isFlagged = value
        }
        dirtyFlagIds[message.mailboxId, default: []].insert(message.emailId)
        updateLocalMessage(updated)

        // Mirror the change into the cached snapshot.
        let accountName = mailAccount?.account ?? ""
        guard let snapshot = MailCache.loadMessages(account: accountName, mailboxId: message.mailboxId) else { return }
        var emails = snapshot.emails
        for i in emails.indices where emails[i].optString("id") == message.emailId {
            var keywords = emails[i]["keywords"] as? [String: Any] ?? [:]
            keywords[keyword] = value
            emails[i]["keywords"] = keywords
        }
        MailCache.saveMessages(account: accountName, mailboxId: message.mailboxId, emails: emails, queryState: snapshot.queryState)
    }

    private func updateLocalMessage(_ updated: MailMessage) {
        if case var .success(list) = messages, let idx = list.firstIndex(where: { $0.id == updated.id }) {
            list[idx] = updated
            messages = .success(list)
        }
        if case var .success(results) = searchResults, let idx = results.firstIndex(where: { $0.id == updated.id }) {
            results[idx] = updated
            searchResults = .success(results)
        }
    }

    // MARK: - Move / Delete

    /// P62d: Entfernt Mails SYNCHRON aus Live-Liste, Cache und Badge
    /// (optimistisch, vor dem Server-Call) - der Swipe "flappt" damit nicht
    /// mehr, weil die Zeile sofort verschwindet.
    private func optimisticRemove(_ ids: [String]) {
        let removed = Set(ids)
        guard !removed.isEmpty else { return }
        // P62f: bis zum bestätigenden Refresh filtern Syncs die IDs aus.
        pendingRemovedIds.formUnion(removed)
        if useJmap, let mailbox = currentMailbox {
            let accountName = mailAccount?.account ?? ""
            if let snapshot = MailCache.loadMessages(account: accountName, mailboxId: mailbox.id) {
                let filtered = snapshot.emails.filter { !removed.contains($0.optString("id") ?? "") }
                MailCache.saveMessages(account: accountName, mailboxId: mailbox.id, emails: filtered, queryState: snapshot.queryState)
            }
        }
        if currentMailbox?.kind == .inbox, currentMailbox?.namespace == .personal,
           case let .success(list) = messages {
            let unreadRemoved = list
                .filter { removed.contains($0.emailId) && !$0.isRead }
                .count
            if unreadRemoved > 0 {
                postUnreadBadge(personalInboxUnread - unreadRemoved)
            }
        }
        if case var .success(list) = messages {
            list.removeAll { removed.contains($0.emailId) }
            messages = .success(list)
        }
        if case var .success(results) = searchResults {
            results.removeAll { removed.contains($0.emailId) }
            searchResults = .success(results)
        }
    }

    func delete(_ messagesToDelete: [MailMessage]) {
        // P62d: OPTIMISTISCH - Zeile/Badge/Cache sofort entfernen, damit der
        // Swipe nicht "flappt", während der Server-Call läuft.
        optimisticRemove(messagesToDelete.map(\.emailId))
        // P62f: FIFO - Folge-Löschungen laufen nicht parallel (Session-Races).
        let ids = messagesToDelete.map(\.emailId)
        let work = { [weak self] in
            let ok = await self?.performDelete(messagesToDelete, ids: ids) ?? false
            if ok {
                self?.actionFeedback = MailSendFeedback(
                    success: true,
                    message: NSLocalizedString("_mail_deleted_", comment: "")
                )
            }
        }
        let previous = deleteWorkTask
        deleteWorkTask = Task {
            await previous?.value
            await work()
        }
    }

    /// Server-Call des Löschens + Ergebnisprüfung (P62f): No-Op
    /// (oldState==newState) = bereits verschoben; echter Fehler = Zeile
    /// wiederherstellen + Feedback statt still schlucken.
    private func performDelete(_ messagesToDelete: [MailMessage], ids: [String]) async -> Bool {
        guard let first = messagesToDelete.first else { return false }
        do {
            if useJmap {
                guard let api = jmapApi,
                      let client = jmapClient else { return false }
                let session = try await client.refreshSession()
                let accId = first.accountId.isEmpty ? session.primaryAccountId : first.accountId
                // Trash must live in the same JMAP account as the message.
                if let trash = allMailboxes.first(where: { $0.kind == .trash && $0.accountId == accId }),
                   let trashJmapId = trash.jmapId,
                   trashJmapId != currentMailbox?.jmapId {
                    let resp = try await api.moveEmails(accountId: accId, emailIds: ids, targetMailboxId: trashJmapId)
                    let noOp = (resp["oldState"] as? String) == (resp["newState"] as? String)
                    if noOp {
                        JmapLog.write("delete: already moved (no-op) for \(ids.joined(separator: ","))")
                    }
                    invalidateCache(for: trash)
                } else {
                    _ = try await api.deleteEmails(accountId: accId, emailIds: ids)
                }
            } else {
                guard let mailbox = currentMailbox,
                      let client = imapClient else { return false }
                for message in messagesToDelete {
                    guard let uid = UInt64(message.emailId) else { continue }
                    if let trash = allMailboxes.first(where: { $0.kind == .trash }), trash.path != mailbox.path {
                        _ = await client.move(mailboxPath: mailbox.path, uid: uid, targetPath: trash.path)
                    }
                }
            }
        } catch {
            // P62f: Server-Fehler - Filter aufheben, Zeilen wiederherstellen
            // (Refresh holt den Server-Stand) und Feedback zeigen.
            JmapLog.write("delete FAILED for \(ids.joined(separator: ",")): \(error.localizedDescription)")
            pendingRemovedIds.subtract(ids)
            actionFeedback = MailSendFeedback(
                success: false,
                message: NSLocalizedString("_mail_delete_failed_", comment: "")
            )
            Task { await refreshMessages() }
            return false
        }
        afterListMutation(ids)
        return true
    }

    /// Moves messages to another mailbox of the same JMAP account
    /// (mirrors the Android move action).
    func move(_ messagesToMove: [MailMessage], to target: Mailbox) {
        // P62d: auch Verschieben optimistisch (kein Flappen beim Move).
        optimisticRemove(messagesToMove.map(\.emailId))
        Task {
            guard let first = messagesToMove.first else { return }
            if useJmap {
                guard let api = jmapApi,
                      let client = jmapClient,
                      let session = try? await client.refreshSession() else { return }
                let accId = first.accountId.isEmpty ? session.primaryAccountId : first.accountId
                guard let targetJmapId = target.jmapId, !targetJmapId.isEmpty else { return }
                _ = try? await api.moveEmails(accountId: accId, emailIds: messagesToMove.map(\.emailId), targetMailboxId: targetJmapId)
                // The target folder's cached snapshot and query state are now
                // stale - force a full refresh the next time it opens.
                invalidateCache(for: target)
            } else {
                guard let mailbox = currentMailbox, let client = imapClient else { return }
                for message in messagesToMove {
                    guard let uid = UInt64(message.emailId) else { continue }
                    _ = await client.move(mailboxPath: mailbox.path, uid: uid, targetPath: target.path)
                }
            }
            afterListMutation(messagesToMove.map(\.emailId))
        }
    }

    private func invalidateCache(for mailbox: Mailbox) {
        let accountName = mailAccount?.account ?? ""
        MailCache.remove(account: accountName, mailboxId: mailbox.id)
        queryStates.removeValue(forKey: mailbox.id)
        dirtyFlagIds.removeValue(forKey: mailbox.id)
    }

    private func afterListMutation(_ removedIds: [String]) {
        // Quell-Cache bereinigen: Ohne diesen Schritt würde der nächste
        // Cache-first-Publish (Full-Refresh nach der Mutation) die
        // verschobene/gelöschte Mail wieder einblenden - der Cache-Snapshot
        // enthält sie ja noch.
        if useJmap, let mailbox = currentMailbox {
            let accountName = mailAccount?.account ?? ""
            if let snapshot = MailCache.loadMessages(account: accountName, mailboxId: mailbox.id) {
                let filtered = snapshot.emails.filter { !removedIds.contains($0.optString("id") ?? "") }
                MailCache.saveMessages(account: accountName, mailboxId: mailbox.id, emails: filtered, queryState: snapshot.queryState)
            }
        }
        // Badge sofort: entfernte ungelesene Nachrichten des Posteingangs abziehen.
        if currentMailbox?.kind == .inbox, currentMailbox?.namespace == .personal,
           case let .success(list) = messages {
            let unreadRemoved = list
                .filter { removedIds.contains($0.emailId) && !$0.isRead }
                .count
            if unreadRemoved > 0 {
                postUnreadBadge(personalInboxUnread - unreadRemoved)
            }
        }
        Task { await loadMailboxes(autoOpenInbox: false) }
        // Remove from the visible list (server confirms the change).
        if case var .success(list) = messages {
            list.removeAll { removedIds.contains($0.emailId) }
            messages = .success(list)
        }
        let removed = Set(removedIds)
        if case var .success(results) = searchResults {
            results.removeAll { removed.contains($0.emailId) }
            searchResults = .success(results)
        }
        if let mailbox = currentMailbox {
            // Route nur erzwingen, wenn der Nutzer nicht inzwischen zur
            // Ordnerliste zurückgegangen ist - sonst würde eine fertige
            // Lösch-Task die Navigation überschreiben (Zurück-Button
            // wirkungslos).
            if case .folders = route { return }
            route = .messages(mailbox: mailbox)
            // P62d: Voller Sync DEBOUNCED (ein Refresh 0,8 s nach der
            // LETZTEN Mutation statt pro Swipe) - schnelle Swipe-Löschungen
            // lösen keine Refresh-Stürme mehr aus (Flap-Ursache).
            mutationRefreshTask?.cancel()
            mutationRefreshTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                // P62f-Fix: pendingRemovedIds werden NUR im Sync selbst
                // freigegeben, wenn der Full-Refresh TATSÄCHLICH lief
                // (sonst leert ein gequeueter Refresh den Filter zu früh
                // und die Mail taucht wieder auf - Log-Beweis).
                await self?.refreshMessages()
            }
        } else if !lastSearchQuery.isEmpty {
            Task { await search(lastSearchQuery) }
        }
    }

    // MARK: - Compose (new / reply / reply-all / forward)

    func startCompose(mode: MailComposeContext.ComposeMode = .new, message: MailMessage? = nil) {
        composeContext = nil
        Task {
            var quote = ""
            var attachments: [OutgoingAttachment] = []
            var to: [String] = []
            var cc: [String] = []
            var subject = ""

            if let message {
                if let json = await fetchMessageJson(message) {
                    var plain = JmapMapper.mapBody(json: json).plainText
                    if plain == nil, let textPart = (json["textBody"] as? [[String: Any]])?.first,
                       let blobId = textPart.optString("blobId"), !blobId.isEmpty {
                        plain = try? await downloadTextBlob(accountId: message.accountId, blobId: blobId)
                    }
                    quote = buildQuote(for: message, plain: plain ?? "")
                    if mode == .forward {
                        attachments = await downloadOriginalAttachments(message, json: json)
                    }
                }
                switch mode {
                case .reply:
                    to = [message.fromAddress]
                case .replyAll:
                    to = [message.fromAddress]
                    var others: [String] = message.toAddresses.commaSeparated() + message.ccAddresses.commaSeparated()
                    others.removeAll { $0.caseInsensitiveCompare(message.fromAddress) == .orderedSame || $0.caseInsensitiveCompare(fromAddress) == .orderedSame }
                    cc = Array(Set(others))
                case .forward:
                    subject = message.subject.hasPrefix("Fwd:") ? message.subject : "Fwd: \(message.subject)"
                case .new:
                    break
                }
                if mode == .reply || mode == .replyAll {
                    subject = message.subject.hasPrefix("Re:") ? message.subject : "Re: \(message.subject)"
                }
            }

            composeContext = MailComposeContext(
                mode: mode,
                message: message,
                to: to,
                cc: cc,
                subject: subject,
                quoteBody: quote,
                preAttachments: attachments
            )
        }
    }

    private func buildQuote(for message: MailMessage, plain: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let header = String(format: NSLocalizedString("_mail_quote_header_", comment: ""), dateFormatter.string(from: message.dateSent), message.displayFrom)
        guard !plain.isEmpty else { return "" }
        let quoted = plain
            .normalizedLineEndings()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        return "\n\n\(header)\n\(quoted)"
    }

    private func downloadOriginalAttachments(_ message: MailMessage, json: [String: Any]) async -> [OutgoingAttachment] {
        let metas = JmapMapper.mapBody(json: json).attachments
        var result: [OutgoingAttachment] = []
        for meta in metas {
            guard let url = await downloadAttachment(meta, for: message) else { continue }
            result.append(OutgoingAttachment(name: meta.name, mimeType: meta.mimeType, fileURL: url))
        }
        return result
    }

    // MARK: - Search

    /// JMAP Email/query with a text filter across all mailboxes
    /// (mirrors the Android search screen).
    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastSearchQuery = ""
            searchResults = .success([])
            return
        }
        lastSearchQuery = trimmed
        searchResults = .loading
        guard useJmap, let api = jmapApi,
              let client = jmapClient,
              let session = try? await client.refreshSession() else {
            searchResults = .error(errorText("Search unavailable"))
            return
        }
        let accId = session.primaryAccountId
        do {
            let resp = try await api.queryEmails(accountId: accId, inMailboxId: "", limit: 100, filterText: trimmed)
            let ids = (resp["ids"] as? [String]) ?? []
            guard !ids.isEmpty else {
                searchResults = .success([])
                return
            }
            let list = try await api.getEmails(accountId: accId, ids: ids)
            let mapped = list.map {
                JmapMapper.mapMessage(account: mailAccount?.account ?? "", accountId: accId, mailboxId: "search", json: $0)
            }
            searchResults = .success(mapped)
        } catch {
            searchResults = .error(errorText(error.localizedDescription))
        }
    }

    // MARK: - Attachments

    /// Downloads an attachment blob into the app cache and returns the file
    /// URL for preview (QuickLook), sharing or forwarding.
    func downloadAttachment(_ attachment: AttachmentMeta, for message: MailMessage) async -> URL? {
        guard useJmap, let client = jmapClient else { return nil }
        let accId = message.accountId.isEmpty
            ? ((try? await client.refreshSession())?.primaryAccountId ?? "")
            : message.accountId
        guard !accId.isEmpty, let blobId = attachment.blobId, !blobId.isEmpty else { return nil }
        guard let data = try? await client.downloadBlob(accountId: accId, blobId: blobId, mimeType: attachment.mimeType) else { return nil }

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = cacheDir.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = attachment.name.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let file = folder.appendingPathComponent("\(message.emailId)_\(safeName)")
        do {
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    // MARK: - Send

    func send(_ outgoing: OutgoingMessage) {
        Task {
            isSending = true
            sendError = nil
            let result: Result<Void, Error>
            if useJmap {
                result = await sendJmap(outgoing)
            } else {
                result = await sendImap(outgoing)
            }
            isSending = false
            switch result {
            case .success:
                sendFeedback = MailSendFeedback(
                    success: true,
                    message: NSLocalizedString("_mail_sent_", comment: "")
                )
                composeContext = nil
                route = .messages(mailbox: currentMailbox ?? allMailboxes.first ?? Mailbox(
                    id: "", account: "", accountId: "", name: "", path: "INBOX", kind: .inbox,
                    unreadCount: 0, messageCount: 0, jmapId: nil, role: nil,
                    namespace: .personal, ownerIdentity: nil, parentId: nil,
                    mayRename: false, mayDelete: false, mayCreateChild: false
                ))
                await syncMessages()
            case .failure(let error):
                sendError = errorText(error.localizedDescription)
                sendFeedback = MailSendFeedback(success: false, message: error.localizedDescription)
            }
        }
    }

    private func sendImap(_ outgoing: OutgoingMessage) async -> Result<Void, Error> {
        guard let client = imapClient else { return .failure(MailSendError.noClient) }
        let sentPath = allMailboxes.first(where: { $0.kind == .sent })?.path
        switch await client.send(fromAddress: fromAddress, fromName: fromName, outgoing: outgoing, sentPath: sentPath) {
        case .success: return .success(())
        case .failure(let message): return .failure(MailSendError.smtp(message))
        }
    }

    private func sendJmap(_ outgoing: OutgoingMessage) async -> Result<Void, Error> {
        guard let api = jmapApi,
              let client = jmapClient,
              let session = try? await client.refreshSession()
        else { return .failure(MailSendError.noClient) }
        let accId = session.primaryAccountId
        do {
            let draftsMailbox = allMailboxes.first(where: { $0.kind == .drafts && $0.accountId == accId })?.jmapId
                ?? allMailboxes.first(where: { $0.jmapId != nil })?.jmapId ?? ""

            let plainText = outgoing.body
            let htmlBody = outgoing.bodyHtml.isEmpty ? nil : outgoing.bodyHtml

            var specs: [JmapAttachmentSpec] = []
            for att in outgoing.attachments {
                guard let data = try? Data(contentsOf: att.fileURL) else { continue }
                if let uploaded = try? await client.uploadBlob(accountId: accId, data: data, contentType: att.mimeType) {
                    specs.append(JmapAttachmentSpec(
                        blobId: uploaded.blobId,
                        name: att.name,
                        mimeType: att.mimeType,
                        sizeBytes: Int64(data.count)
                    ))
                }
            }

            let draftResp = try await api.createDraft(
                accountId: accId,
                mailboxId: draftsMailbox,
                fromAddress: fromAddress,
                toAddresses: outgoing.to,
                ccAddresses: outgoing.cc,
                bccAddresses: outgoing.bcc,
                subject: outgoing.subject,
                htmlBody: htmlBody,
                plainText: plainText,
                inReplyTo: outgoing.inReplyTo,
                attachments: specs
            )

            let created = draftResp["created"] as? [String: Any]
            let createdId = created?["new"] as? [String: Any]
            let emailId = createdId?.optString("id") ?? ""

            let resolvedIdentity = identity(for: fromAddress) ?? identityId
            if !emailId.isEmpty, let identId = resolvedIdentity, !identId.isEmpty {
                _ = try await api.submitEmail(accountId: accId, emailId: emailId, identityId: identId)

                // Make sure the submitted mail lands in the Sent folder of
                // this account (some servers do not move it automatically),
                // and arrives there as read ($seen).
                if let sent = allMailboxes.first(where: { $0.role == "sent" && $0.accountId == accId })
                    ?? allMailboxes.first(where: { $0.kind == .sent && $0.accountId == accId }),
                   let sentJmapId = sent.jmapId, !sentJmapId.isEmpty {
                    _ = try? await api.moveEmails(accountId: accId, emailIds: [emailId], targetMailboxId: sentJmapId, markRead: true)
                    invalidateCache(for: sent)
                }
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    enum MailSendError: LocalizedError {
        case noClient
        case smtp(String)

        var errorDescription: String? {
            switch self {
            case .noClient: return "Mail client not ready"
            case .smtp(let message): return message
            }
        }
    }

    // MARK: - Navigation

    func back() {
        switch route {
        case .detail:
            if let mailbox = currentMailbox {
                route = .messages(mailbox: mailbox)
            } else if cameFromSearch {
                route = .search
            } else {
                route = .folders
            }
        case .messages, .compose, .search:
            route = .folders
        case .folders:
            break
        }
    }

    private func kindOrder(_ kind: MailboxKind) -> Int {
        switch kind {
        case .inbox: return 0
        case .drafts: return 1
        case .sent: return 2
        case .junk: return 3
        case .trash: return 4
        case .regular: return 5
        }
    }
}

extension String {
    func commaSeparated() -> [String] {
        split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

extension Notification.Name {
    /// Ungelesen-Anzahl geändert (Mail-Tab-Badge); object = Int.
    static let mailUnreadChanged = Notification.Name("mailUnreadChanged")
    /// P62g: Mail-Push eingetroffen (Vordergrund) - die offene Mailbox soll
    /// sofort nachziehen (userInfo: account).
    static let mailPushReceived = Notification.Name("mailPushReceived")
    /// Summe über ALLE Accounts (System-Badge am App-Icon).
    static let mailTotalUnreadChanged = Notification.Name("mailTotalUnreadChanged")
}
