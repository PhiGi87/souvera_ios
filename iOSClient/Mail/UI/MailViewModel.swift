// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// View model for the native mail client (IMAP/SMTP via MailImapClient).
// Manages folder list, message list, detail, compose and send flows.
//
// The JMAP implementation (JmapClient/JmapApi/JmapMapper) remains in the
// project as standby until the server-side JMAP route is opened for native
// clients - see the souvera_mail deployment notes.

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

    private var client: MailImapClient?
    private var mailAccount: MailAccount?
    private var currentMailbox: Mailbox?
    private var allMailboxes: [Mailbox] = []
    private var hasRecoveredCredential = false

    func start() {
        if client != nil { return }
        Task {
            let manager = SouveraMailCredentialManager()
            guard let account = await manager.ensureCombinedCredential() else {
                mailboxes = .error(errorText(NSLocalizedString("_mail_credential_failed_", comment: "")))
                return
            }
            applyAccount(account)
            await loadMailboxes()
            await loadAliases()
        }
    }

    /// Re-runs the setup from scratch, re-minting the mail credential if the
    /// server rejected the stored one (authentication failure).
    func retry() {
        client = nil
        mailAccount = nil
        mailboxes = .loading
        start()
    }

    private func applyAccount(_ account: MailAccount) {
        mailAccount = account

        // The souvera_mail server contract: `loginName` is the SASL username for
        // mail (IMAP/SMTP) and may differ from the Nextcloud user id.
        let mailLogin = account.saslUser
        fromAddress = mailLogin
        fromAddresses = [mailLogin]
        fromName = NCManageDatabase.shared.getActiveTableAccount()?.displayName ?? account.username

        client = MailImapClient(account: account)
    }

    /// The mail server rejected the credentials. Per the souvera_mail
    /// playbook this means the stored password is dead: mint a fresh combined
    /// password via login-flow and retry once.
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

    /// Whether an error message indicates rejected credentials (IMAP/SMTP
    /// authentication failure) - recoverable by re-minting the password.
    private func isAuthRecoverable(_ message: String) -> Bool {
        message.contains("[AUTH]")
    }

    private func errorText(_ message: String) -> String {
        "\(SouveraBuildInfo.label)\n\n\(message)"
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

    // MARK: - Folders

    func loadMailboxes() async {
        guard let client else { return }
        mailboxes = .loading
        switch await client.fetchMailboxes() {
        case let .success(boxes):
            allMailboxes = boxes.sorted { kindOrder($0.kind) < kindOrder($1.kind) }
            mailboxes = .success(allMailboxes)

            if let inbox = allMailboxes.first(where: { $0.kind == .inbox }) {
                openMailbox(inbox)
            }
        case let .failure(message):
            if isAuthRecoverable(message), !hasRecoveredCredential {
                await recoverCredentialAndReload()
                return
            }
            mailboxes = .error(errorText(message))
        }
    }

    // MARK: - Messages

    func openMailbox(_ mailbox: Mailbox) {
        currentMailbox = mailbox
        route = .messages(mailbox: mailbox)
        Task { await syncMessages() }
    }

    func syncMessages() async {
        guard let client, let mailbox = currentMailbox else { return }
        messages = .loading
        switch await client.syncMessages(mailboxPath: mailbox.path) {
        case let .success(list): messages = .success(list)
        case let .failure(message): messages = .error(errorText(message))
        }
    }

    // MARK: - Detail

    func openMessage(_ message: MailMessage) {
        route = .detail(message: message)
        body = .loading
        Task {
            guard let client, let mailbox = currentMailbox, let uid = UInt64(message.emailId) else { return }
            switch await client.fetchBody(mailboxPath: mailbox.path, uid: uid) {
            case let .success(b):
                body = .success(b)
                if !message.isRead { await setRead(message, true) }
            case let .failure(m):
                body = .error(errorText(m))
            }
        }
    }

    // MARK: - Flags

    func setRead(_ message: MailMessage, _ read: Bool) async {
        guard let client, let mailbox = currentMailbox, let uid = UInt64(message.emailId) else { return }
        _ = await client.setFlag(mailboxPath: mailbox.path, uid: uid, flag: .seen, value: read)
    }

    func toggleFlagged(_ message: MailMessage) {
        Task {
            guard let client, let mailbox = currentMailbox, let uid = UInt64(message.emailId) else { return }
            _ = await client.setFlag(mailboxPath: mailbox.path, uid: uid, flag: .flagged, value: !message.isFlagged)
            await syncMessages()
        }
    }

    func delete(_ message: MailMessage) {
        Task {
            guard let client, let mailbox = currentMailbox, let uid = UInt64(message.emailId) else { return }
            if let trash = allMailboxes.first(where: { $0.kind == .trash }), trash.path != mailbox.path {
                _ = await client.move(mailboxPath: mailbox.path, uid: uid, targetPath: trash.path)
            }
            route = .messages(mailbox: mailbox)
            await syncMessages()
        }
    }

    // MARK: - Send

    func send(_ outgoing: OutgoingMessage) {
        Task {
            guard let client else { return }
            isSending = true
            sendError = nil
            let sentPath = allMailboxes.first(where: { $0.kind == .sent })?.path
            let result = await client.send(fromAddress: fromAddress, fromName: fromName, outgoing: outgoing, sentPath: sentPath)
            isSending = false
            switch result {
            case .success:
                route = .messages(mailbox: currentMailbox ?? allMailboxes.first ?? Mailbox(
                    id: "", account: "", name: "", path: "INBOX", kind: .inbox,
                    unreadCount: 0, messageCount: 0, jmapId: nil, role: nil
                ))
                await syncMessages()
            case let .failure(message):
                sendError = errorText(message)
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
