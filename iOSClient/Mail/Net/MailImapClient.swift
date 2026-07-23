// SPDX-FileCopyrightText: 2026 Host-On Service Provider GmbH (Souvera)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from souvera_android mail/net/MailSession.kt + mail/repository/MessageRepository.kt,
// using MailCore2 (MCOIMAPSession/MCOSMTPSession) in place of Jakarta/Angus Mail.
//
// Auth is always the combined app-password SouveraMailCredentialManager provisions — confirmed
// working over plain SASL, no OAuth2. IMAP is 993 (implicit TLS); SMTP is 465 (implicit TLS).
// Port 587 is not used on this server.

import Foundation
import MailCore

actor MailImapClient {
    private let account: MailAccount

    // Ports/timeouts match the android MailSession constants.
    private let imapPort: UInt32 = 993
    private let smtpPort: UInt32 = 465
    private let messageLimit: Int

    init(account: MailAccount, messageLimit: Int = 50) {
        self.account = account
        self.messageLimit = messageLimit
    }

    // MARK: - Sessions

    private func imapSession() -> MCOIMAPSession {
        let session = MCOIMAPSession()
        session.hostname = account.host
        session.port = imapPort
        session.username = account.username
        session.password = account.mailPassword
        session.connectionType = .TLS
        session.authType = .saslNone // PLAIN/LOGIN
        return session
    }

    private func smtpSession() -> MCOSMTPSession {
        let session = MCOSMTPSession()
        session.hostname = account.host
        session.port = smtpPort
        session.username = account.username
        session.password = account.mailPassword
        session.connectionType = .TLS
        session.authType = .saslNone
        return session
    }

    // MARK: - Folders

    func fetchMailboxes() async -> MailResult<[Mailbox]> {
        await run("Loading folders failed") {
            let op = self.imapSession().fetchAllFoldersOperation()
            let folders: [MCOIMAPFolder] = try await withCheckedThrowingContinuation { cont in
                op!.start { error, folders in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: folders ?? []) }
                }
            }
            return folders.map { folder in
                let path = folder.path ?? ""
                return Mailbox(
                    id: Mailbox.makeId(account: self.account.account, path: path),
                    account: self.account.account,
                    name: path.components(separatedBy: "/").last ?? path,
                    path: path,
                    kind: Self.classify(path: path, flags: folder.flags),
                    unreadCount: 0,
                    messageCount: 0
                )
            }
        }
    }

    private static func classify(path: String, flags: MCOIMAPFolderFlag) -> MailboxKind {
        if path.caseInsensitiveCompare("INBOX") == .orderedSame { return .inbox }
        if flags.contains(.sentMail) { return .sent }
        if flags.contains(.drafts) { return .drafts }
        if flags.contains(.trash) { return .trash }
        if flags.contains(.spam) { return .junk }
        let leaf = (path.components(separatedBy: "/").last ?? path).lowercased()
        switch leaf {
        case "sent", "sent items", "gesendet": return .sent
        case "drafts", "entwürfe": return .drafts
        case "trash", "deleted items", "papierkorb": return .trash
        case "junk", "spam": return .junk
        default: return .regular
        }
    }

    // MARK: - Message list sync

    /// Fetches the most recent [messageLimit] envelopes for [mailboxPath] (headers+flags+size+uid).
    func syncMessages(mailboxPath: String) async -> MailResult<[MailMessage]> {
        await run("Message sync failed") {
            let session = self.imapSession()
            let infoOp = session.folderInfoOperation(mailboxPath)
            let info: MCOIMAPFolderInfo = try await withCheckedThrowingContinuation { cont in
                infoOp!.start { error, info in
                    if let error { cont.resume(throwing: error) }
                    else if let info { cont.resume(returning: info) }
                    else { cont.resume(throwing: MailError.empty) }
                }
            }
            let total = Int(info.messageCount)
            guard total > 0 else { return [] }
            let last = UInt64(total)
            let first = UInt64(max(1, total - self.messageLimit + 1))
            let range = MCORange(location: first, length: last - first)
            let kind: MCOIMAPMessagesRequestKind = [.headers, .flags, .size, .uid]
            let fetchOp = session.fetchMessagesByNumberOperation(withFolder: mailboxPath, requestKind: kind, numbers: MCOIndexSet(range: range))
            let messages: [MCOIMAPMessage] = try await withCheckedThrowingContinuation { cont in
                fetchOp!.start { error, messages, _ in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: (messages as? [MCOIMAPMessage]) ?? []) }
                }
            }
            let mailboxId = Mailbox.makeId(account: self.account.account, path: mailboxPath)
            return messages.map { self.map(message: $0, mailboxId: mailboxId) }
                .sorted { $0.dateSent > $1.dateSent }
        }
    }

    private func map(message: MCOIMAPMessage, mailboxId: String) -> MailMessage {
        let header = message.header
        let from = header?.from
        return MailMessage(
            id: "\(mailboxId)|\(message.uid)",
            account: account.account,
            mailboxId: mailboxId,
            uid: UInt64(message.uid),
            subject: header?.subject ?? "",
            fromAddress: from?.mailbox ?? "",
            fromDisplayName: from?.displayName,
            toAddresses: (header?.to as? [MCOAddress])?.compactMap { $0.mailbox }.joined(separator: ", ") ?? "",
            dateSent: header?.date ?? Date(timeIntervalSince1970: 0),
            isRead: message.flags.contains(.seen),
            isFlagged: message.flags.contains(.flagged),
            sizeBytes: Int64(message.size)
        )
    }

    // MARK: - Message body

    func fetchBody(mailboxPath: String, uid: UInt64) async -> MailResult<MessageBody> {
        await run("Loading message failed") {
            let op = self.imapSession().fetchMessageOperation(withFolder: mailboxPath, uid: UInt32(uid))
            let data: Data = try await withCheckedThrowingContinuation { cont in
                op!.start { error, data in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: data ?? Data()) }
                }
            }
            guard let parser = MCOMessageParser(data: data) else { return MessageBody(plainText: nil, html: nil, attachments: []) }
            let attachments = (parser.attachments() as? [MCOAttachment] ?? []).enumerated().map { index, att in
                AttachmentMeta(
                    name: att.filename ?? "attachment",
                    sizeBytes: Int64(att.data?.count ?? 0),
                    mimeType: att.mimeType ?? "application/octet-stream",
                    partIndex: index
                )
            }
            return MessageBody(plainText: parser.plainTextBodyRendering(), html: parser.htmlBodyRendering(), attachments: attachments)
        }
    }

    // MARK: - Flags & moves

    func setFlag(mailboxPath: String, uid: UInt64, flag: MCOMessageFlag, value: Bool) async -> MailResult<Void> {
        await run("Updating message failed") {
            let kind: MCOIMAPStoreFlagsRequestKind = value ? .add : .remove
            let op = self.imapSession().storeFlagsOperation(withFolder: mailboxPath, uids: MCOIndexSet(index: uid), kind: kind, flags: flag)
            try await Self.awaitImap(op)
        }
    }

    func move(mailboxPath: String, uid: UInt64, targetPath: String) async -> MailResult<Void> {
        await run("Moving message failed") {
            let session = self.imapSession()
            let copyOp = session.copyMessagesOperation(withFolder: mailboxPath, uids: MCOIndexSet(index: uid), destFolder: targetPath)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                copyOp!.start { error, _ in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: ()) }
                }
            }
            try await Self.awaitImap(session.storeFlagsOperation(withFolder: mailboxPath, uids: MCOIndexSet(index: uid), kind: .add, flags: .deleted))
            try await Self.awaitImap(session.expungeOperation(mailboxPath))
        }
    }

    // MARK: - Sending

    func send(fromAddress: String, fromName: String, outgoing: OutgoingMessage, sentPath: String?) async -> MailResult<Void> {
        await run("Sending message failed") {
            let builder = MCOMessageBuilder()
            builder.header.from = MCOAddress(displayName: fromName, mailbox: fromAddress)
            builder.header.to = outgoing.to.map { MCOAddress(mailbox: $0) }
            builder.header.cc = outgoing.cc.map { MCOAddress(mailbox: $0) }
            builder.header.bcc = outgoing.bcc.map { MCOAddress(mailbox: $0) }
            builder.header.subject = outgoing.subject
            builder.htmlBody = outgoing.bodyHtml.isEmpty ? MailImapClient.htmlEscape(outgoing.body) : outgoing.bodyHtml
            builder.textBody = outgoing.body
            for attachment in outgoing.attachments {
                if let data = try? Data(contentsOf: attachment.fileURL),
                   let part = MCOAttachment(data: data, filename: attachment.name) {
                    part.mimeType = attachment.mimeType
                    builder.addAttachment(part)
                }
            }
            let data = builder.data()!
            let sendOp = self.smtpSession().sendOperation(with: data)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                sendOp!.start { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: ()) }
                }
            }
            // Best-effort append to Sent; message still went out even if this fails.
            if let sentPath {
                let append = self.imapSession().appendMessageOperation(withFolder: sentPath, messageData: data, flags: .seen)
                _ = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt64, Error>) in
                    append!.start { error, uid in
                        if let error { cont.resume(throwing: error) } else { cont.resume(returning: uid) }
                    }
                }
            }
        }
    }

    private static func htmlEscape(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        return "<html><body>\(escaped)</body></html>"
    }

    // MARK: - MailCore async bridging

    /// Runs a body and maps thrown errors to a user-facing MailResult.failure.
    private func run<T>(_ message: String, _ body: () async throws -> T) async -> MailResult<T> {
        do { return .success(try await body()) } catch { return .failure("\(message): \(error.localizedDescription)") }
    }

    /// Bridges an error-only MailCore IMAP operation (store flags, expunge) to async/await.
    private static func awaitImap(_ op: MCOIMAPOperation?) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op!.start { error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: ()) }
            }
        }
    }

    enum MailError: Error { case empty }
}
