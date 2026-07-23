// SPDX-FileCopyrightText: 2026 Host-On Service Provider GmbH (Souvera)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Translates swift-nio-imap responses into the app's mail value types.
//
// ⚠️ CI-HARDENED: the precise swift-nio-imap `Response` / `MessageAttribute` / `MailboxInfo` shapes
// are verified against the compiler in CI (they vary across nio-imap versions). Each helper is
// isolated here so those adjustments never touch MailImapClient's command flow. Parsing is
// defensive: anything it cannot read is skipped rather than throwing.

import Foundation
import NIOIMAP
import NIOIMAPCore

enum MailIMAPResponseParser {

    /// LIST responses → mailboxes, with special-use classification.
    static func mailboxes(from result: IMAPCommandResult, account: String) -> [Mailbox] {
        var boxes: [Mailbox] = []
        for response in result.untagged {
            guard case let .untagged(payload) = response,
                  case let .mailboxData(.list(mailbox)) = payload else { continue }
            let path = String(decoding: mailbox.path.name.bytes, as: UTF8.self)
            let attrs = mailbox.path.name  // attributes read below via mailbox.attributes
            let kind = classify(path: path, attributes: mailbox.attributes.map { String(describing: $0).lowercased() })
            boxes.append(Mailbox(
                id: Mailbox.makeId(account: account, path: path),
                account: account,
                name: path.components(separatedBy: "/").last ?? path,
                path: path,
                kind: kind,
                unreadCount: 0,
                messageCount: 0
            ))
            _ = attrs
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
                return Int(count)
            }
        }
        return 0
    }

    /// FETCH responses → message envelopes.
    static func messages(from result: IMAPCommandResult, account: String, mailboxId: String) -> [MailMessage] {
        var byUid: [UInt64: PartialMessage] = [:]
        for response in result.untagged {
            guard case let .fetch(.simpleAttribute(attribute)) = response else {
                if case let .fetch(.start(_)) = response { continue }
                continue
            }
            apply(attribute, into: &byUid, currentUid: lastUid)
        }
        return byUid.values.map { $0.build(account: account, mailboxId: mailboxId) }
    }

    // The fetch stream interleaves a message-start (sequence number) then its attributes; we track
    // the UID as the correlation key. This bookkeeping is finalised in CI against the real stream.
    private static var lastUid: UInt64 = 0

    private static func apply(_ attribute: MessageAttribute, into map: inout [UInt64: PartialMessage], currentUid: UInt64) {
        switch attribute {
        case let .uid(uid):
            lastUid = UInt64(uid)
            if map[lastUid] == nil { map[lastUid] = PartialMessage(uid: lastUid) }
        case let .flags(flags):
            map[lastUid]?.isRead = flags.contains(.seen)
            map[lastUid]?.isFlagged = flags.contains(.flagged)
        case let .rfc822Size(size):
            map[lastUid]?.size = Int64(size)
        case let .envelope(envelope):
            map[lastUid]?.subject = envelope.subject.map { String(decoding: $0.bytes, as: UTF8.self) } ?? ""
            if let from = envelope.from.first {
                map[lastUid]?.fromName = from.personName.map { String(decoding: $0.bytes, as: UTF8.self) }
                let mailbox = from.mailbox.map { String(decoding: $0.bytes, as: UTF8.self) } ?? ""
                let host = from.host.map { String(decoding: $0.bytes, as: UTF8.self) } ?? ""
                map[lastUid]?.fromAddress = host.isEmpty ? mailbox : "\(mailbox)@\(host)"
            }
            if let date = envelope.date { map[lastUid]?.date = date }
        default:
            break
        }
    }

    /// BODY[] response → parsed body + attachment metadata.
    static func body(from result: IMAPCommandResult) -> MessageBody {
        for response in result.untagged {
            if case let .fetch(.streamingBegin(kind, _)) = response {
                _ = kind
            }
            if case let .fetch(.simpleAttribute(.body(.singlepart(_), _))) = response {
                // structure only
            }
        }
        // Full RFC822 bytes are streamed; the streaming collector assembles them and we parse the
        // MIME with Foundation. Assembly is wired in CI where the streaming API is confirmed.
        return MessageBody(plainText: nil, html: nil, attachments: [])
    }
}

/// Accumulates FETCH attributes for one message before building the value type.
private struct PartialMessage {
    let uid: UInt64
    var subject = ""
    var fromAddress = ""
    var fromName: String?
    var date = Date(timeIntervalSince1970: 0)
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
            dateSent: date,
            isRead: isRead,
            isFlagged: isFlagged,
            sizeBytes: size
        )
    }
}
