// SPDX-FileCopyrightText: 2026 Host-On Service Provider GmbH (Souvera)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from souvera_android mail/ui/MailViewModel.kt (adapted for iOS/SwiftUI).
//
// First iOS version keeps message state in memory and fetches from IMAP on demand (no Realm offline
// cache yet — a deliberate simplification to minimise failure surface; offline caching can follow).

import Foundation
import Combine

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
    @Published var isSending = false
    @Published var sendError: String?

    private var client: MailImapClient?
    private var mailAccount: MailAccount?
    private var currentMailbox: Mailbox?
    private var allMailboxes: [Mailbox] = []

    func start() {
        if client != nil { return }
        Task {
            let manager = SouveraMailCredentialManager()
            guard let account = await manager.ensureCombinedCredential() else {
                mailboxes = .error(NSLocalizedString("_mail_credential_failed_", comment: ""))
                return
            }
            mailAccount = account
            fromAddress = account.username.contains("@") ? account.username : account.username
            fromName = NCManageDatabase.shared.getActiveTableAccount()?.displayName ?? account.username
            client = MailImapClient(account: account)
            await loadMailboxes()
        }
    }

    func loadMailboxes() async {
        guard let client else { return }
        mailboxes = .loading
        switch await client.fetchMailboxes() {
        case let .success(boxes):
            allMailboxes = boxes.sorted { kindOrder($0.kind) < kindOrder($1.kind) }
            mailboxes = .success(allMailboxes)
            // Auto-open the inbox.
            if let inbox = allMailboxes.first(where: { $0.kind == .inbox }) {
                openMailbox(inbox)
            }
        case let .failure(message):
            mailboxes = .error(message)
        }
    }

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
        case let .failure(message): messages = .error(message)
        }
    }

    func openMessage(_ message: MailMessage) {
        route = .detail(message: message)
        body = .loading
        Task {
            guard let client, let mailbox = currentMailbox else { return }
            switch await client.fetchBody(mailboxPath: mailbox.path, uid: message.uid) {
            case let .success(b):
                body = .success(b)
                if !message.isRead { await setRead(message, true) }
            case let .failure(m):
                body = .error(m)
            }
        }
    }

    func setRead(_ message: MailMessage, _ read: Bool) async {
        guard let client, let mailbox = currentMailbox else { return }
        _ = await client.setFlag(mailboxPath: mailbox.path, uid: message.uid, flag: .seen, value: read)
    }

    func toggleFlagged(_ message: MailMessage) {
        Task {
            guard let client, let mailbox = currentMailbox else { return }
            _ = await client.setFlag(mailboxPath: mailbox.path, uid: message.uid, flag: .flagged, value: !message.isFlagged)
            await syncMessages()
        }
    }

    func delete(_ message: MailMessage) {
        Task {
            guard let client, let mailbox = currentMailbox else { return }
            if let trash = allMailboxes.first(where: { $0.kind == .trash }), trash.path != mailbox.path {
                _ = await client.move(mailboxPath: mailbox.path, uid: message.uid, targetPath: trash.path)
            }
            route = .messages(mailbox: mailbox)
            await syncMessages()
        }
    }

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
                route = .messages(mailbox: currentMailbox ?? allMailboxes.first ?? Mailbox(id: "", account: "", name: "", path: "INBOX", kind: .inbox, unreadCount: 0, messageCount: 0))
                await syncMessages()
            case let .failure(message):
                sendError = message
            }
        }
    }

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
