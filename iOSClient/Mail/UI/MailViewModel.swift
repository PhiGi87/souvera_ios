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

    static func == (lhs: MailRoute, rhs: MailRoute) -> Bool {
        switch (lhs, rhs) {
        case (.folders, .folders), (.compose, .compose): return true
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

    private var imapClient: MailImapClient?
    private var jmapClient: JmapClient?
    private var jmapApi: JmapApi?
    private var mailAccount: MailAccount?
    private var currentMailbox: Mailbox?
    private var allMailboxes: [Mailbox] = []
    private var identityId: String?
    private var hasRecoveredCredential = false

    private var useJmap: Bool { NCBrandOptions.shared.useJmapMail }
    var transportLabel: String { useJmap ? "JMAP" : "IMAP" }

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
            identityId = identities.first?.optString("id")
        } catch {
            identityId = nil
        }
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
            allMailboxes = boxes.sorted { kindOrder($0.kind) < kindOrder($1.kind) }
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
            let accId = session?.primaryAccountId ?? ""
            let list = try await api.getMailboxes(accountId: accId)
            let boxes = list.map { JmapMapper.mapMailbox(account: mailAccount?.account ?? "", json: $0) }
            allMailboxes = boxes.sorted { kindOrder($0.kind) < kindOrder($1.kind) }
            mailboxes = .success(allMailboxes)
            if let inbox = allMailboxes.first(where: { $0.kind == .inbox }) { openMailbox(inbox) }
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
            let session = try await jmapClient?.refreshSession()
            let accId = session?.primaryAccountId ?? ""
            guard let jmapMailboxId = mailbox.jmapId, !jmapMailboxId.isEmpty else {
                messages = .error(errorText("Mailbox has no JMAP ID"))
                return
            }
            let resp = try await api.queryEmails(accountId: accId, inMailboxId: jmapMailboxId)
            let ids = (resp["ids"] as? [String]) ?? []
            guard !ids.isEmpty else {
                messages = .success([])
                return
            }
            let list = try await api.getEmails(accountId: accId, ids: ids)
            let msgList = list.map {
                JmapMapper.mapMessage(account: mailAccount?.account ?? "", mailboxId: mailbox.id, json: $0)
            }
            messages = .success(msgList)
        } catch {
            messages = .error(errorText(error.localizedDescription))
        }
    }

    // MARK: - Detail

    func openMessage(_ message: MailMessage) {
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
        let accId = session.primaryAccountId
        do {
            let bodyProperties: [String] = ["bodyValues", "textBody", "htmlBody", "attachments"]
            let list = try await api.getEmails(accountId: accId, ids: [message.emailId], bodyProperties: bodyProperties)
            if let json = list.first {
                body = .success(JmapMapper.mapBody(json: json))
                if !message.isRead { await setRead(message, true) }
            } else {
                body = .error(errorText("Message not found"))
            }
        } catch {
            body = .error(errorText(error.localizedDescription))
        }
    }

    // MARK: - Flags

    func setRead(_ message: MailMessage, _ read: Bool) async {
        if useJmap {
            guard let api = jmapApi,
                  let client = jmapClient,
                  let session = try? await client.refreshSession() else { return }
            let accId = session.primaryAccountId
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
                let accId = session.primaryAccountId
                if message.isFlagged {
                    _ = try? await api.setEmailFlags(accountId: accId, emailIds: [message.emailId], keywordsToRemove: ["$flagged"])
                } else {
                    _ = try? await api.setEmailFlags(accountId: accId, emailIds: [message.emailId], keywordsToAdd: ["$flagged": true])
                }
            } else {
                guard let client = imapClient, let mailbox = currentMailbox, let uid = UInt64(message.emailId) else { return }
                _ = await client.setFlag(mailboxPath: mailbox.path, uid: uid, flag: .flagged, value: !message.isFlagged)
            }
            await syncMessages()
        }
    }

    func delete(_ message: MailMessage) {
        Task {
            guard let mailbox = currentMailbox else { return }
            if useJmap {
                guard let api = jmapApi,
                      let client = jmapClient,
                      let session = try? await client.refreshSession() else { return }
                let accId = session.primaryAccountId
                if let trash = allMailboxes.first(where: { $0.kind == .trash }),
                   let trashJmapId = trash.jmapId,
                   trashJmapId != mailbox.jmapId {
                    _ = try? await api.moveEmails(accountId: accId, emailIds: [message.emailId], targetMailboxId: trashJmapId)
                } else {
                    _ = try? await api.deleteEmails(accountId: accId, emailIds: [message.emailId])
                }
            } else {
                guard let client = imapClient, let uid = UInt64(message.emailId) else { return }
                if let trash = allMailboxes.first(where: { $0.kind == .trash }), trash.path != mailbox.path {
                    _ = await client.move(mailboxPath: mailbox.path, uid: uid, targetPath: trash.path)
                }
            }
            route = .messages(mailbox: mailbox)
            await syncMessages()
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
                    id: "", account: "", name: "", path: "INBOX", kind: .inbox,
                    unreadCount: 0, messageCount: 0, jmapId: nil, role: nil
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

            if !emailId.isEmpty, let identId = identityId {
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
            if let mailbox = currentMailbox { route = .messages(mailbox: mailbox) }
        case .messages, .compose:
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
