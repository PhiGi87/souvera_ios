// SPDX-FileCopyrightText: 2026 Host-On Service Provider GmbH (Souvera)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Translates swift-nio-imap (0.4.0) responses into the app's mail value types.
// Body content is assembled from streaming FETCH BODY[] responses.

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
            m.toAddresses = addresses(from: envelope.to)
            m.ccAddresses = addresses(from: envelope.cc)
            if let dateStr = envelope.date, let parsed = parseEnvelopeDate(dateStr) {
                m.dateSent = parsed
            }
        default:
            break
        }
    }

    private static func addresses<T: Collection>(from list: T) -> String {
        list.compactMap { addr in
            guard case let .singleAddress(single) = addr else { return nil }
            let mailbox = single.mailbox.map { String(buffer: $0) } ?? ""
            let host = single.host.map { String(buffer: $0) } ?? ""
            let name = single.personName.map { String(buffer: $0) } ?? ""
            let email = host.isEmpty ? mailbox : "\(mailbox)@\(host)"
            if name.isEmpty { return email }
            return "\(name) <\(email)>"
        }.joined(separator: ", ")
    }

    private static func parseEnvelopeDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let date = formatter.date(from: raw) { return date }
        formatter.dateFormat = "dd MMM yyyy HH:mm:ss Z"
        if let date = formatter.date(from: raw) { return date }
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.date(from: raw)
    }

    /// Assembles a MessageBody from streaming BODY[] FETCH data.
    /// Collects all .stream data chunks, then parses the result as MIME or plain text.
    static func body(from result: IMAPCommandResult) -> MessageBody {
        var bodyData = Data()
        for response in result.untagged {
            guard case let .fetch(fetch) = response else { continue }
            if case let .stream(_, buffer) = fetch, let buf = buffer {
                bodyData.append(buf.readData(length: buf.readableBytes) ?? Data())
            }
        }
        guard !bodyData.isEmpty else { return MessageBody(plainText: nil, html: nil, attachments: []) }
        return parseBodyContent(bodyData)
    }

    private static func parseBodyContent(_ data: Data) -> MessageBody {
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return MessageBody(plainText: nil, html: nil, attachments: [])
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let boundary = extractBoundary(from: raw) {
            return parseMultipart(raw, boundary: boundary)
        }

        let lower = trimmed.prefix(200).lowercased()
        let isHtml = lower.hasPrefix("<") || lower.contains("<html") || lower.contains("<!doctype html")
        if isHtml {
            return MessageBody(plainText: nil, html: trimmed, attachments: [])
        }
        return MessageBody(plainText: trimmed, html: nil, attachments: [])
    }

    /// Extracts the first Content-Type boundary from raw MIME body text.
    private static func extractBoundary(from body: String) -> String? {
        let lines = body.components(separatedBy: .newlines)
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("boundary=") {
                let parts = line.components(separatedBy: "boundary=")
                if parts.count >= 2 {
                    var b = parts[1].trimmingCharacters(in: .whitespaces)
                    b = b.trimmingCharacters(in: CharacterSet(charactersIn: "\";\'"))
                    if !b.isEmpty { return b }
                }
            }
        }
        return nil
    }

    /// Simple multipart MIME parser: walks parts separated by the boundary and extracts
    /// the first text/plain or text/html body.
    private static func parseMultipart(_ body: String, boundary: String) -> MessageBody {
        let parts = body.components(separatedBy: "--\(boundary)")
        var plainText: String?
        var htmlText: String?
        var attachments: [AttachmentMeta] = []

        for part in parts {
            guard let bodyStart = part.range(of: "\r\n\r\n") ?? part.range(of: "\n\n") else { continue }
            let headers = String(part[part.startIndex..<bodyStart.lowerBound])
            let content = String(part[bodyStart.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if content == "--" || content.isEmpty { continue }
            let lowerHeaders = headers.lowercased()

            if lowerHeaders.contains("text/plain") && plainText == nil {
                plainText = decodeContent(headers: headers, content: content)
            } else if lowerHeaders.contains("text/html") && htmlText == nil {
                htmlText = decodeContent(headers: headers, content: content)
            } else if lowerHeaders.contains("application/") || lowerHeaders.contains("image/") || lowerHeaders.contains("audio/") {
                let name = extractParameter(headers, named: "name") ?? "attachment"
                let mimeType = extractContentType(headers)
                attachments.append(AttachmentMeta(name: name, sizeBytes: Int64(content.count), mimeType: mimeType, partIndex: attachments.count))
            }
        }

        return MessageBody(plainText: plainText ?? (htmlText == nil ? nil : ""), html: htmlText, attachments: attachments)
    }

    private static func decodeContent(headers: String, content: String) -> String {
        let lower = headers.lowercased()
        if lower.contains("base64") {
            guard let data = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")) else { return content }
            return String(data: data, encoding: .utf8) ?? content
        }
        if lower.contains("quoted-printable") {
            return decodeQuotedPrintable(content)
        }
        return content
    }

    private static func decodeQuotedPrintable(_ text: String) -> String {
        var result = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "=" && text.index(i, offsetBy: 2, limitedBy: text.endIndex) != nil {
                let hex = String(text[text.index(after: i)...text.index(i, offsetBy: 2)])
                if let byte = UInt8(hex, radix: 16) {
                    result.append(Character(UnicodeScalar(byte)))
                    i = text.index(i, offsetBy: 3)
                    continue
                }
            }
            if text[i] == "=" && text.index(after: i) < text.endIndex && text[text.index(after: i)] == "\n" {
                i = text.index(i, offsetBy: 2)
                continue
            }
            if text[i] == "=" && text.index(after: i) < text.endIndex && text[text.index(after: i)] == "\r" {
                i = text.index(i, offsetBy: 3)
                continue
            }
            result.append(text[i])
            i = text.index(after: i)
        }
        return result
    }

    private static func extractParameter(_ headers: String, named: String) -> String? {
        let lower = headers.lowercased()
        guard let range = lower.range(of: "\(named)=\"") ?? lower.range(of: "\(named)=") else { return nil }
        var search = String(headers[range.upperBound...])
        if search.hasPrefix("\"") { search.removeFirst() }
        let end = search.firstIndex(of: "\"") ?? search.firstIndex(of: ";") ?? search.firstIndex(of: "\r") ?? search.endIndex
        return String(search[search.startIndex..<end]).trimmingCharacters(in: .whitespaces)
    }

    private static func extractContentType(_ headers: String) -> String {
        let lower = headers.lowercased()
        guard let range = lower.range(of: "content-type:") else { return "application/octet-stream" }
        let after = String(headers[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return after.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? "application/octet-stream"
    }
}

/// Accumulates FETCH attributes for one message before building the value type.
private struct PartialMessage {
    var uid: UInt64 = 0
    var subject = ""
    var fromAddress = ""
    var fromName: String?
    var toAddresses = ""
    var ccAddresses = ""
    var dateSent = Date(timeIntervalSince1970: 0)
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
            toAddresses: toAddresses,
            dateSent: dateSent,
            isRead: isRead,
            isFlagged: isFlagged,
            sizeBytes: size
        )
    }
}
