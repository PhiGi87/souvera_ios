// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// View model for the native mail client. Supports two transports:
//   - JMAP (default, NCBrandOptions.shared.useJmapMail == true) - mirrors the
//     Android client and talks to Stalwart via JmapClient/JmapApi.
//   - IMAP/SMTP (fallback) via MailImapClient.
// The active transport is shown in the UI ("Mail via JMAP" / "Mail via IMAP").

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
    @Published var isSending = false
    @Published var sendError: String?
    @Published var searchResults: MailUiState<[MailMessage]> = .success([])

    private var imapClient: MailImapClient?
    private var jmapClient: JmapClient?
    private var jmapApi: JmapApi?
    private var mailAccount: MailAccount?
    private var currentMailbox: Mailbox?
    private var allMailboxes: [Mailbox] = []
    private var identityId: String?
    private var allIdentities: [[String: Any]] = []
    private var hasRecoveredCredential = false
    private var cameFromSearch = false
    private var lastSearchQuery = ""

    private var useJmap: Bool { NCBrandOptions.shared.useJmapMail }
    var transportLabel: String { useJmap ? "JMAP" : "IMAP" }
    var availableMailboxes: [Mailbox] { allMailboxes }

    func start() {
        if imapClient != nil || jmapClient != nil { return }
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

            var all: [Mailbox] = []

            // Personal mailboxes.
            let personalList = try await api.getMailboxes(accountId: primaryAccId)
            all += personalList.map {
                JmapMapper.mapMailbox(account: accountName, accountId: primaryAccId, json: $0)
            }

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
                    }
                }
            }

            let sorted = sortMailboxGroups(all)
            allMailboxes = sorted
            mailboxes = .success(sorted)
            if let inbox = sorted.first(where: { $0.kind == .inbox }) { openMailbox(inbox) }
        } catch {
            if isJmapAuthRecoverable(error), !hasRecoveredCredential {
                await recoverCredentialAndReload()
                return
            }
            let summary = await jmapClient?.diagnosticSummary() ?? ""
            let message = error.localizedDescription + (summary.isEmpty ? "" : "\n\n\(summary)")
            mailboxes = .error(errorText(message))
        }
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
        switch jmapError {
        case .authNeedsBearer:
            return true
        case .protocolError(let message):
            return message.contains("JMAP session not available")
        default:
            return false
        }
    }

    // MARK: - Messages

    func openMailbox(_ mailbox: Mailbox) {
        currentMailbox = mailbox
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

    private func syncMessagesJmap(_ mailbox: Mailbox) async {
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
            let resp = try await api.queryEmails(accountId: accId, inMailboxId: jmapMailboxId, limit: 100)
            let ids = (resp["ids"] as? [String]) ?? []
            guard !ids.isEmpty else {
                messages = .success([])
                return
            }
            let list = try await api.getEmails(accountId: accId, ids: ids)
            let msgList = list.map {
                JmapMapper.mapMessage(account: mailAccount?.account ?? "", accountId: accId, mailboxId: mailbox.id, json: $0)
            }
            messages = .success(msgList)
        } catch {
            messages = .error(errorText(error.localizedDescription))
        }
    }

    // MARK: - Detail

    func openMessage(_ message: MailMessage, fromSearch: Bool = false) {
        cameFromSearch = fromSearch
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
            if !message.isRead { await setRead(message, true) }
        case let .failure(m):
            body = .error(errorText(m))
        }
    }

    private func openMessageJmap(_ message: MailMessage) async {
        guard let api = jmapApi,
              let client = jmapClient,
              let session = try? await client.refreshSession()
        else { return }
        let accId = message.accountId.isEmpty ? session.primaryAccountId : message.accountId
        do {
            // Mirror the Android request exactly: only body part properties.
            // Stalwart then returns either inline bodyValues (used as-is) or
            // text/html blobIds, which are downloaded below.
            let bodyProperties: [String] = ["partId", "blobId", "size", "type", "name"]
            let list = try await api.getEmails(accountId: accId, ids: [message.emailId], bodyProperties: bodyProperties)
            if let json = list.first {
                var mapped = JmapMapper.mapBody(json: json)
                if mapped.plainText == nil, let textPart = (json["textBody"] as? [[String: Any]])?.first,
                   let blobId = textPart.optString("blobId"), !blobId.isEmpty {
                    mapped = MessageBody(
                        plainText: try? await downloadTextBlob(accountId: accId, blobId: blobId),
                        html: mapped.html,
                        attachments: mapped.attachments
                    )
                }
                if mapped.html == nil, let htmlPart = (json["htmlBody"] as? [[String: Any]])?.first,
                   let blobId = htmlPart.optString("blobId"), !blobId.isEmpty {
                    mapped = MessageBody(
                        plainText: mapped.plainText,
                        html: try? await downloadTextBlob(accountId: accId, blobId: blobId),
                        attachments: mapped.attachments
                    )
                }
                body = .success(mapped)
                if !message.isRead { await setRead(message, true) }
            } else {
                body = .error(errorText("Message not found"))
            }
        } catch {
            body = .error(errorText(error.localizedDescription))
        }
    }

    private func downloadTextBlob(accountId: String, blobId: String) async throws -> String? {
        guard let client = jmapClient else { return nil }
        let data = try await client.downloadBlob(accountId: accountId, blobId: blobId, mimeType: "text/plain")
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Flags

    func setRead(_ message: MailMessage, _ read: Bool) async {
        if useJmap {
            guard let api = jmapApi,
                  let client = jmapClient,
                  let session = try? await client.refreshSession() else { return }
            let accId = message.accountId.isEmpty ? session.primaryAccountId : message.accountId
            if read {
                _ = try? await api.setEmailFlags(accountId: accId, emailIds: [message.emailId], keywordsToAdd: ["$seen": true])
            } else {
                _ = try? await api.setEmailFlags(accountId: accId, emailIds: [message.emailId], keywordsToRemove: ["$seen"])
            }
        } else {
            guard let client = imapClient, let mailbox = currentMailbox, let uid = UInt64(message.emailId) else { return }
            _ = await client.setFlag(mailboxPath: mailbox.path, uid: uid, flag: .seen, value: read)
        }
    }

    func toggleFlagged(_ message: MailMessage) {
        Task {
            if useJmap {
                guard let api = jmapApi,
                      let client = jmapClient,
                      let session = try? await client.refreshSession() else { return }
                let accId = message.accountId.isEmpty ? session.primaryAccountId : message.accountId
                if message.isFlagged {
                    _ = try? await api.setEmailFlags(accountId: accId, emailIds: [message.emailId], keywordsToRemove: ["$flagged"])
                } else {
                    _ = try? await api.setEmailFlags(accountId: accId, emailIds: [message.emailId], keywordsToAdd: ["$flagged": true])
                }
            } else {
                guard let client = imapClient, let mailbox = currentMailbox, let uid = UInt64(message.emailId) else { return }
                _ = await client.setFlag(mailboxPath: mailbox.path, uid: uid, flag: .flagged, value: !message.isFlagged)
            }
            if currentMailbox != nil {
                await syncMessages()
            } else if !lastSearchQuery.isEmpty {
                await search(lastSearchQuery)
            }
        }
    }

    func delete(_ message: MailMessage) {
        Task {
            if useJmap {
                guard let api = jmapApi,
                      let client = jmapClient,
                      let session = try? await client.refreshSession() else { return }
                let accId = message.accountId.isEmpty ? session.primaryAccountId : message.accountId
                // Trash must live in the same JMAP account as the message.
                if let trash = allMailboxes.first(where: { $0.kind == .trash && $0.accountId == accId }),
                   let trashJmapId = trash.jmapId,
                   trashJmapId != currentMailbox?.jmapId {
                    _ = try? await api.moveEmails(accountId: accId, emailIds: [message.emailId], targetMailboxId: trashJmapId)
                } else {
                    _ = try? await api.deleteEmails(accountId: accId, emailIds: [message.emailId])
                }
            } else {
                guard let mailbox = currentMailbox,
                      let client = imapClient,
                      let uid = UInt64(message.emailId) else { return }
                if let trash = allMailboxes.first(where: { $0.kind == .trash }), trash.path != mailbox.path {
                    _ = await client.move(mailboxPath: mailbox.path, uid: uid, targetPath: trash.path)
                }
            }
            if let mailbox = currentMailbox {
                route = .messages(mailbox: mailbox)
                await syncMessages()
            } else if !lastSearchQuery.isEmpty {
                await search(lastSearchQuery)
            }
        }
    }

    /// Moves a message to another mailbox of the same JMAP account
    /// (mirrors the Android move action).
    func move(_ message: MailMessage, to target: Mailbox) {
        Task {
            guard useJmap, let api = jmapApi,
                  let client = jmapClient,
                  let session = try? await client.refreshSession() else { return }
            let accId = message.accountId.isEmpty ? session.primaryAccountId : message.accountId
            guard let targetJmapId = target.jmapId, !targetJmapId.isEmpty else { return }
            _ = try? await api.moveEmails(accountId: accId, emailIds: [message.emailId], targetMailboxId: targetJmapId)
            if currentMailbox != nil {
                await syncMessages()
            } else if !lastSearchQuery.isEmpty {
                await search(lastSearchQuery)
            }
        }
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
    /// URL for preview (QuickLook) or sharing.
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
                route = .messages(mailbox: currentMailbox ?? allMailboxes.first ?? Mailbox(
                    id: "", account: "", accountId: "", name: "", path: "INBOX", kind: .inbox,
                    unreadCount: 0, messageCount: 0, jmapId: nil, role: nil,
                    namespace: .personal, ownerIdentity: nil
                ))
                await syncMessages()
            case .failure(let error):
                sendError = errorText(error.localizedDescription)
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
            let draftsMailbox = allMailboxes.first(where: { $0.kind == .drafts })?.jmapId
                ?? allMailboxes.first(where: { $0.jmapId != nil })?.jmapId ?? ""

            let plainText = outgoing.body
            let htmlBody = outgoing.bodyHtml.isEmpty ? nil : outgoing.bodyHtml

            var blobIds: [String] = []
            for att in outgoing.attachments {
                guard let data = try? Data(contentsOf: att.fileURL) else { continue }
                if let uploaded = try? await client.uploadBlob(accountId: accId, data: data, contentType: att.mimeType) {
                    blobIds.append(uploaded.blobId)
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
                blobIds: blobIds
            )

            let created = draftResp["created"] as? [String: Any]
            let createdId = created?["new"] as? [String: Any]
            let emailId = createdId?.optString("id") ?? ""

            let resolvedIdentity = identity(for: fromAddress) ?? identityId
            if !emailId.isEmpty, let identId = resolvedIdentity, !identId.isEmpty {
                _ = try await api.submitEmail(accountId: accId, emailId: emailId, identityId: identId)
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
