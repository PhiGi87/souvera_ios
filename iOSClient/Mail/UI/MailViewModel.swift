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
    @Published var composeContext: MailComposeContext?
    @Published var sendFeedback: MailSendFeedback?
    @Published var expandedMailboxIds: Set<String> = []
    @Published var collapsedGroupIds: Set<String> = []
    @Published var folderScrollPosition: String?
    @Published var messageScrollPosition: String?
    /// Rückmeldung für Aktionen (z. B. Absender in die Blacklist) — wird wie
    /// das Sende-Feedback als Banner angezeigt.
    @Published var actionFeedback: MailSendFeedback?
    /// Zeitpunkt des nächsten automatischen Abrufs (für den Countdown-Ring
    /// in der Ordnerübersicht); nil = Auto-Refresh deaktiviert.
    @Published var nextAutoRefreshAt: Date?
    @Published var sortOrder: MailSortOrder = .dateDesc

    private var imapClient: MailImapClient?
    private var jmapClient: JmapClient?
    private var jmapApi: JmapApi?
    private var mailAccount: MailAccount?
    var currentMailbox: Mailbox?
    private var allMailboxes: [Mailbox] = []
    private var queryStates: [String: String] = [:]
    private var identityId: String?
    private var allIdentities: [[String: Any]] = []
    private var hasRecoveredCredential = false
    private var cameFromSearch = false
    private var lastSearchQuery = ""

    private var useJmap: Bool { NCBrandOptions.shared.useJmapMail }
    var transportLabel: String { useJmap ? "JMAP" : "IMAP" }
    var availableMailboxes: [Mailbox] { allMailboxes }

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
                return
            }
            applyAccount(account)
            await loadMailboxes()
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
                        await self.refreshMessages()
                    } else {
                        // Ordnerübersicht: Postfächer (Ungelesen-Zähler) aktualisieren
                        await self.loadMailboxes()
                    }
                }
            }
        }
    }

    /// Re-runs the setup from scratch, re-minting the mail credential if the
    /// server rejected the stored one.
    func retry() {
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
        guard !hasRecoveredCredential else { return }
        hasRecoveredCredential = true
        guard let renewed = await SouveraMailCredentialManager().renewCredential() else {
            mailboxes = .error(errorText(NSLocalizedString("_mail_credential_failed_", comment: "")))
            return
        }
        applyAccount(renewed)
        await loadMailboxes()
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

    func loadMailboxes() async {
        mailboxes = .loading
        if useJmap {
            await loadMailboxesJmap()
        } else {
            await loadMailboxesImap()
        }
    }

    private func loadMailboxesImap() async {
        guard let client = imapClient else { return }
        switch await client.fetchMailboxes() {
        case let .success(boxes):
            allMailboxes = sortMailboxGroups(boxes)
            mailboxes = .success(allMailboxes)
            if let inbox = allMailboxes.first(where: { $0.kind == .inbox }) { openMailbox(inbox) }
        case let .failure(message):
            if message.contains("[AUTH]"), !hasRecoveredCredential {
                await recoverCredentialAndReload()
                return
            }
            mailboxes = .error(errorText(message))
        }
    }

    private func loadMailboxesJmap() async {
        guard let api = jmapApi else { return }
        do {
            let session = try await jmapClient?.refreshSession()
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
            allMailboxes = sorted
            mailboxes = .success(sorted)
            MailCache.saveMailboxes(account: accountName, boxes: rawBoxes)
            if let inbox = sorted.first(where: { $0.kind == .inbox }) { openMailbox(inbox) }
        } catch {
            if isJmapAuthRecoverable(error), !hasRecoveredCredential {
                await recoverCredentialAndReload()
                return
            }
            // Offline: rebuild the folder list from the cache when possible.
            if let cached = MailCache.loadMailboxes(account: mailAccount?.account ?? ""),
               isOfflineError(error) {
                let boxes = cached.map { mailbox(from: $0) }
                let sorted = sortMailboxGroups(filterNonStandardSentFolders(boxes))
                allMailboxes = sorted
                mailboxes = .success(sorted)
                offlineNotice = NSLocalizedString("_mail_offline_", comment: "")
                if let inbox = sorted.first(where: { $0.kind == .inbox }) { openMailbox(inbox) }
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
                ownerIdentity: box.ownerIdentity, parentId: parentId
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
        // Only genuine auth rejections trigger a credential re-mint; a
        // missing session is a connectivity issue and must not re-mint.
        switch jmapError {
        case .authNeedsBearer:
            return true
        default:
            return false
        }
    }

    /// Leert den Papierkorb (zerstört alle Nachrichten des aktuellen
    /// Ordners dauerhaft).
    func emptyTrash() async {
        guard let mailbox = currentMailbox,
              case let .success(items) = messages,
              !items.isEmpty else { return }
        var ok = false
        if useJmap {
            do {
                _ = try await jmapApi?.deleteEmails(accountId: mailbox.accountId, emailIds: items.map(\.id))
                ok = true
            } catch {
                JmapLog.write("emptyTrash jmap failed: \(error)")
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
            await syncMessages()
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

    // MARK: - Messages

    func openMailbox(_ mailbox: Mailbox) {
        currentMailbox = mailbox
        messageScrollPosition = nil
        route = .messages(mailbox: mailbox)
        Task { await syncMessages() }
    }

    func syncMessages() async {
        guard let mailbox = currentMailbox else { return }
        messages = .loading
        if useJmap {
            await syncMessagesJmap(mailbox)
        } else {
            await syncMessagesImap(mailbox)
        }
    }

    private func syncMessagesImap(_ mailbox: Mailbox) async {
        guard let client = imapClient else { return }
        switch await client.syncMessages(mailboxPath: mailbox.path) {
        case let .success(list): messages = .success(list)
        case let .failure(message): messages = .error(errorText(message))
        }
    }

    private func syncMessagesJmap(_ mailbox: Mailbox, forceFullRefresh: Bool = false) async {
        guard let api = jmapApi else { return }
        do {
            _ = try await jmapClient?.refreshSession()
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
                    var emails = snapshot.emails.filter { !removed.contains($0.optString("id") ?? "") }
                    if !added.isEmpty {
                        let fetched = try await api.getEmails(accountId: accId, ids: added)
                        emails = mergeEmails(existing: emails, incoming: fetched)
                    }
                    let newState = changes.optString("newQueryState") ?? state
                    queryStates[cacheKey] = newState
                    MailCache.saveMessages(account: accountName, mailboxId: cacheKey, emails: emails, queryState: newState)
                    messages = .success(emails.map { JmapMapper.mapMessage(account: accountName, accountId: accId, mailboxId: cacheKey, json: $0) })
                    return
                } catch {
                    // Incremental path failed - fall through to a full refresh.
                }
            }

            // 2) Full refresh.
            let resp = try await api.queryEmails(accountId: accId, inMailboxId: jmapMailboxId, limit: 100)
            let ids = (resp["ids"] as? [String]) ?? []
            let state = resp.optString("queryState")
            queryStates[cacheKey] = state
            guard !ids.isEmpty else {
                messages = .success([])
                MailCache.saveMessages(account: accountName, mailboxId: cacheKey, emails: [], queryState: state)
                return
            }
            let list = try await api.getEmails(accountId: accId, ids: ids)
            MailCache.saveMessages(account: accountName, mailboxId: cacheKey, emails: list, queryState: state)
            messages = .success(list.map { JmapMapper.mapMessage(account: accountName, accountId: accId, mailboxId: cacheKey, json: $0) })
        } catch {
            // Only real connectivity problems count as "offline"; anything
            // else surfaces with its actual error text.
            if let cached = MailCache.loadMessages(account: mailAccount?.account ?? "", mailboxId: mailbox.id),
               isOfflineError(error) {
                let accId = mailbox.accountId
                messages = .success(cached.emails.map {
                    JmapMapper.mapMessage(account: mailAccount?.account ?? "", accountId: accId, mailboxId: mailbox.id, json: $0)
                })
                offlineNotice = NSLocalizedString("_mail_offline_", comment: "")
                return
            }
            JmapLog.write("sync failed for \(mailbox.id): \(error.localizedDescription)")
            messages = .error(errorText(error.localizedDescription))
        }
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
    func refreshMessages() async {
        guard let mailbox = currentMailbox else { return }
        messages = .loading
        if useJmap {
            await syncMessagesJmap(mailbox, forceFullRefresh: true)
        } else {
            await syncMessagesImap(mailbox)
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
        messageScrollPosition = message.id
        route = .detail(message: message)
        body = .loading
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
            if !message.isRead { await setRead([message], true) }
        case let .failure(m):
            body = .error(errorText(m))
        }
    }

    private func openMessageJmap(_ message: MailMessage) async {
        guard let json = await fetchMessageJson(message) else {
            body = .error(errorText("Message not found"))
            return
        }
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
           let blobId = htmlPart.optString("blobId"), !blobId.isEmpty {
            mapped = MessageBody(
                plainText: mapped.plainText,
                html: (try? await downloadTextBlob(accountId: accId, blobId: blobId)) ?? nil,
                attachments: mapped.attachments
            )
        }
        body = .success(mapped)
        if !message.isRead { await setRead([message], true) }
    }

    /// Fetches the full Email/get JSON for a message (Android-parity body
    /// properties).
    private func fetchMessageJson(_ message: MailMessage) async -> [String: Any]? {
        guard let api = jmapApi,
              let client = jmapClient,
              let session = try? await client.refreshSession()
        else { return nil }
        let accId = message.accountId.isEmpty ? session.primaryAccountId : message.accountId
        let bodyProperties: [String] = ["partId", "blobId", "size", "type", "name"]
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

    func delete(_ messagesToDelete: [MailMessage]) {
        Task {
            guard let first = messagesToDelete.first else { return }
            if useJmap {
                guard let api = jmapApi,
                      let client = jmapClient,
                      let session = try? await client.refreshSession() else { return }
                let accId = first.accountId.isEmpty ? session.primaryAccountId : first.accountId
                // Trash must live in the same JMAP account as the message.
                if let trash = allMailboxes.first(where: { $0.kind == .trash && $0.accountId == accId }),
                   let trashJmapId = trash.jmapId,
                   trashJmapId != currentMailbox?.jmapId {
                    _ = try? await api.moveEmails(accountId: accId, emailIds: messagesToDelete.map(\.emailId), targetMailboxId: trashJmapId)
                    invalidateCache(for: trash)
                } else {
                    _ = try? await api.deleteEmails(accountId: accId, emailIds: messagesToDelete.map(\.emailId))
                }
            } else {
                guard let mailbox = currentMailbox,
                      let client = imapClient else { return }
                for message in messagesToDelete {
                    guard let uid = UInt64(message.emailId) else { continue }
                    if let trash = allMailboxes.first(where: { $0.kind == .trash }), trash.path != mailbox.path {
                        _ = await client.move(mailboxPath: mailbox.path, uid: uid, targetPath: trash.path)
                    }
                }
            }
            afterListMutation(messagesToDelete.map(\.emailId))
        }
    }

    /// Moves messages to another mailbox of the same JMAP account
    /// (mirrors the Android move action).
    func move(_ messagesToMove: [MailMessage], to target: Mailbox) {
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
    }

    private func afterListMutation(_ removedIds: [String]) {
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
            route = .messages(mailbox: mailbox)
            Task { await syncMessages() }
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
            let resp = try await api.queryEmails(accountId: accId, inMailboxId: "", limit: 50, filterText: trimmed)
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
                    namespace: .personal, ownerIdentity: nil, parentId: nil
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
