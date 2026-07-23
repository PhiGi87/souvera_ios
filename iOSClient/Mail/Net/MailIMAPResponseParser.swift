// SPDX-FileCopyrightText: 2026 Host-On Service Provider GmbH (Souvera)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Translates swift-nio-imap (0.4.0) responses into the app's mail value types.
// Body content assembly (streaming FETCH) is added in a follow-up; envelope/flags/uid parsing is here.

import Foundation
import NIOCore
import NIOIMAP
import NIOIMAPCore

enum MailIMAPResponseParser {

    /// LIST responses → mailboxes, with special-use classification.
    static func mailboxes(from result: IMAPCommandResult, account: String) -> [Mailbox] {
        var boxes: [Mailbox] = []
        for response in result.untagged {
            guard case let .untagged(payload) = response,
                  case let .mailboxData(.list(info)) = payload else { continue }
            let path = String(decoding: info.path.name.bytes, as: UTF8.self)
            let attrs = info.attributes.map { String(describing: $0).lowercased() }
            boxes.append(Mailbox(
                id: Mailbox.makeId(account: account, path: path),
                account: account,
                name: path.components(separatedBy: "/").last ?? path,
                path: path,
                kind: classify(path: path, attributes: attrs),
                unreadCount: 0,
                messageCount: 0
            ))
        }
        return boxes
    }

    private static func classify(path: String, attributes: [String]) -> MailboxKind {
        if path.caseInsensitiveCompare("INBOX") == .orderedSame { return .inbox }
        func has(_ s: String) -> Bool { attributes.contains { $0.contains(s) } }
        if has("sent") { return .sent }
        if has("drafts") { return .drafts }
        if has("trash") { return .trash }
        if has("junk") { return .junk }
        let leaf = (path.components(separatedBy: "/").last ?? path).lowercased()
        switch leaf {
        case "sent", "sent items", "gesendet": return .sent
        case "drafts", "entwürfe": return .drafts
        case "trash", "deleted items", "papierkorb": return .trash
        case "junk", "spam": return .junk
        default: return .regular
        }
    }

    /// EXISTS count from a SELECT response.
    static func messageCount(from result: IMAPCommandResult) -> Int {
        for response in result.untagged {
            if case let .untagged(payload) = response,
               case let .mailboxData(.exists(count)) = payload {
                return count
            }
        }
        return 0
    }

    /// FETCH responses → message envelopes. The stream is: start(seq) then simpleAttribute(s).
    static func messages(from result: IMAPCommandResult, account: String, mailboxId: String) -> [MailMessage] {
        var current = PartialMessage()
        var built: [MailMessage] = []
        func flush() {
            if current.uid != 0 { built.append(current.build(account: account, mailboxId: mailboxId)) }
            current = PartialMessage()
        }
        for response in result.untagged {
            guard case let .fetch(fetch) = response else { continue }
            switch fetch {
            case .start, .startUID:
                flush()
            case let .simpleAttribute(attribute):
                apply(attribute, into: &current)
            default:
                break
            }
        }
        flush()
        return built
    }

    private static func apply(_ attribute: MessageAttribute, into m: inout PartialMessage) {
        switch attribute {
        case let .uid(uid):
            m.uid = UInt64(uid.rawValue)
        case let .flags(flags):
            m.isRead = flags.contains(.seen)
            m.isFlagged = flags.contains(.flagged)
        case let .rfc822Size(size):
            m.size = Int64(size)
        case let .envelope(envelope):
            m.subject = envelope.subject.map { String(buffer: $0) } ?? ""
            if let first = envelope.from.first, case let .singleAddress(addr) = first {
                m.fromName = addr.personName.map { String(buffer: $0) }
                let mailbox = addr.mailbox.map { String(buffer: $0) } ?? ""
                let host = addr.host.map { String(buffer: $0) } ?? ""
                m.fromAddress = host.isEmpty ? mailbox : "\(mailbox)@\(host)"
            }
        default:
            break
        }
    }

    /// BODY[] content is delivered via streaming FETCH responses; assembly is added in a follow-up.
    static func body(from result: IMAPCommandResult) -> MessageBody {
        MessageBody(plainText: nil, html: nil, attachments: [])
    }
}

/// Accumulates FETCH attributes for one message before building the value type.
private struct PartialMessage {
    var uid: UInt64 = 0
    var subject = ""
    var fromAddress = ""
    var fromName: String?
    var isRead = false
    var isFlagged = false
    var size: Int64 = 0

    func build(account: String, mailboxId: String) -> MailMessage {
        MailMessage(
            id: "\(mailboxId)|\(uid)",
            account: account,
            mailboxId: mailboxId,
            uid: uid,
            subject: subject,
            fromAddress: fromAddress,
            fromDisplayName: fromName,
            toAddresses: "",
            dateSent: Date(timeIntervalSince1970: 0),
            isRead: isRead,
            isFlagged: isFlagged,
            sizeBytes: size
        )
    }
}
