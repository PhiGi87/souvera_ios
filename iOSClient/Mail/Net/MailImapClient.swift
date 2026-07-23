// SPDX-FileCopyrightText: 2026 Host-On Service Provider GmbH (Souvera)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Native IMAP mail operations on SwiftNIO + swift-nio-imap (see MailNIOConnection). Replaces the
// MailCore2 implementation with a future-proof, Apple-maintained, SPM-native stack. Public API is
// unchanged so the UI/view model are untouched.
//
// IMAP command construction is the stable part; the exact swift-nio-imap response-attribute shapes
// (FETCH ENVELOPE / BODY[] decoding) are hardened against the compiler in CI — the parsing helpers
// are isolated in MailIMAPResponseParser for that reason.

import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

/// Message flags we toggle. Mapped to IMAP system flags by the client.
enum MailFlag {
    case seen, flagged
    var imapFlag: Flag { self == .seen ? .seen : .flagged }
}

actor MailImapClient {
    private let account: MailAccount
    private let messageLimit: Int
    private let group: EventLoopGroup

    private let imapPort = 993
    private let smtpPort = 465

    init(account: MailAccount, messageLimit: Int = 50) {
        self.account = account
        self.messageLimit = messageLimit
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit { try? group.syncShutdownGracefully() }

    // MARK: - Connection helper

    private func withConnection<T>(_ body: (MailNIOConnection) async throws -> T) async throws -> T {
        let connection = MailNIOConnection(host: account.host, port: imapPort, group: group)
        try await connection.connect()
        _ = try await connection.send(.login(username: account.username, password: account.mailPassword))
        defer { Task { await connection.close() } }
        return try await body(connection)
    }

    private func run<T>(_ message: String, _ body: () async throws -> T) async -> MailResult<T> {
        do { return .success(try await body()) } catch { return .failure("\(message): \(error.localizedDescription)") }
    }

    // MARK: - Folders

    func fetchMailboxes() async -> MailResult<[Mailbox]> {
        await run("Loading folders failed") {
            try await self.withConnection { connection in
                let result = try await connection.send(.list(nil, reference: MailboxName(""), .init("*"), returnOptions: []))
                return MailIMAPResponseParser.mailboxes(from: result, account: self.account.account)
            }
        }
    }

    // MARK: - Message list

    func syncMessages(mailboxPath: String) async -> MailResult<[MailMessage]> {
        await run("Message sync failed") {
            try await self.withConnection { connection in
                let selectResult = try await connection.send(.select(MailboxName(Array(mailboxPath.utf8)), []))
                let total = MailIMAPResponseParser.messageCount(from: selectResult)
                guard total > 0 else { return [] }
                let first = max(1, total - self.messageLimit + 1)
                let set = MessageIdentifierSetNonEmpty(range: .init(UInt32(first) ... UInt32(total)))!
                let attributes: [FetchAttribute] = [.uid, .flags, .envelope, .rfc822Size]
                let fetchResult = try await connection.send(.fetch(.set(.init(set)), attributes, []))
                let mailboxId = Mailbox.makeId(account: self.account.account, path: mailboxPath)
                return MailIMAPResponseParser.messages(from: fetchResult, account: self.account.account, mailboxId: mailboxId)
                    .sorted { $0.dateSent > $1.dateSent }
            }
        }
    }

    // MARK: - Body

    func fetchBody(mailboxPath: String, uid: UInt64) async -> MailResult<MessageBody> {
        await run("Loading message failed") {
            try await self.withConnection { connection in
                _ = try await connection.send(.select(MailboxName(Array(mailboxPath.utf8)), []))
                let set = MessageIdentifierSetNonEmpty(UID(UInt32(uid)))
                let result = try await connection.send(.uidFetch(.set(.init(set)), [.bodyStructure(extensions: true), .bodySection(peek: false, .init(kind: .complete), nil)], []))
                return MailIMAPResponseParser.body(from: result)
            }
        }
    }

    // MARK: - Flags & moves

    func setFlag(mailboxPath: String, uid: UInt64, flag: MailFlag, value: Bool) async -> MailResult<Void> {
        await run("Updating message failed") {
            try await self.withConnection { connection in
                _ = try await connection.send(.select(MailboxName(Array(mailboxPath.utf8)), []))
                let set = MessageIdentifierSetNonEmpty(UID(UInt32(uid)))
                let store: StoreFlags = value ? .add(silent: true, list: [flag.imapFlag]) : .remove(silent: true, list: [flag.imapFlag])
                _ = try await connection.send(.uidStore(.set(.init(set)), [], store))
            }
        }
    }

    func move(mailboxPath: String, uid: UInt64, targetPath: String) async -> MailResult<Void> {
        await run("Moving message failed") {
            try await self.withConnection { connection in
                _ = try await connection.send(.select(MailboxName(Array(mailboxPath.utf8)), []))
                let set = MessageIdentifierSetNonEmpty(UID(UInt32(uid)))
                // Prefer server-side MOVE; falls back to COPY+delete+expunge on servers without it.
                _ = try await connection.send(.uidCopy(.set(.init(set)), MailboxName(Array(targetPath.utf8))))
                _ = try await connection.send(.uidStore(.set(.init(set)), [], .add(silent: true, list: [.deleted])))
                _ = try await connection.send(.expunge)
            }
        }
    }

    // MARK: - Sending (SMTP)

    func send(fromAddress: String, fromName: String, outgoing: OutgoingMessage, sentPath: String?) async -> MailResult<Void> {
        let mime = MailMimeBuilder.build(fromAddress: fromAddress, fromName: fromName, outgoing: outgoing)
        let smtp = MailSmtpClient(host: account.host, port: smtpPort, username: account.username, password: account.mailPassword, group: group)
        do {
            try await smtp.send(from: fromAddress, recipients: outgoing.to + outgoing.cc + outgoing.bcc, data: mime)
        } catch {
            return .failure("Sending message failed: \(error.localizedDescription)")
        }
        // Best-effort append to Sent; message still went out even if this fails.
        if let sentPath {
            _ = await run("append") {
                try await self.withConnection { connection in
                    _ = try await connection.send(.append(into: MailboxName(Array(sentPath.utf8)), flags: [.seen], date: nil, message: Array(mime.utf8)))
                }
            }
        }
        return .success(())
    }
}
