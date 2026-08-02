// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from souvera_android mail/net/jmap/JmapMapper.kt.
//
// Maps JMAP JSON response objects into the app's domain entities.
// Pure functions; no side effects.

import Foundation

enum JmapMapper {

    static func mapMailbox(
        account: String,
        json: JSONDictionary,
        path: String? = nil
    ) -> Mailbox {
        let name = json.optString("name") ?? path ?? "?"
        let resolvedPath = path ?? name
        let role = json.optString("role")
        let kind = resolveMailboxKind(role: role, name: name, path: resolvedPath)
        let jmapId = json.optString("id")

        return Mailbox(
            id: Mailbox.makeId(account: account, path: resolvedPath),
            account: account,
            name: name,
            path: resolvedPath,
            kind: kind,
            unreadCount: json.optInt("unreadEmails"),
            messageCount: json.optInt("totalEmails"),
            jmapId: jmapId,
            role: role
        )
    }

    static func mapMessage(
        account: String,
        mailboxId: String,
        json: JSONDictionary
    ) -> MailMessage {
        let fromList = json["from"] as? [JSONDictionary] ?? []
        let toList = json["to"] as? [JSONDictionary] ?? []
        let hasAtt = json.optBool("hasAttachment") || ((json["attachments"] as? [Any])?.count ?? 0) > 0
        let keywords = json["keywords"] as? JSONDictionary

        let isRead = (keywords?["$seen"] as? Bool) ?? false
        let isFlagged = (keywords?["$flagged"] as? Bool) ?? false

        let fromFirst = fromList.first
        let fromAddress = fromFirst?.optString("email") ?? ""
        let fromName = fromFirst?.optString("name")

        let toAddressStr = toList.compactMap { $0.optString("email") }.joined(separator: ", ")

        return MailMessage(
            id: "\(mailboxId)|\(json.optString("id") ?? "")",
            account: account,
            mailboxId: mailboxId,
            emailId: json.optString("id") ?? "",
            messageId: (json["messageId"] as? [String])?.first,
            subject: json.optString("subject") ?? "",
            fromAddress: fromAddress,
            fromDisplayName: fromName,
            toAddresses: toAddressStr,
            dateSent: parseJmapDate(json.optString("receivedAt")),
            isRead: isRead,
            isFlagged: isFlagged,
            hasAttachments: hasAtt,
            sizeBytes: json.optInt64("size"),
            blobId: json.optString("blobId"),
            threadId: json.optString("threadId"),
            keywords: keywords
        )
    }

    static func mapBody(json: JSONDictionary) -> MessageBody {
        let attachments = (json["attachments"] as? [JSONDictionary])?.map { att in
            AttachmentMeta(
                name: att.optString("name") ?? att.optString("partId") ?? "attachment",
                sizeBytes: att.optInt64("size"),
                mimeType: att.optString("type") ?? "application/octet-stream",
                blobId: att.optString("blobId"),
                partId: att.optString("partId")
            )
        } ?? []

        var plainText: String?
        var html: String?

        if let bodyValues = json["bodyValues"] as? JSONDictionary {
            if let textParts = json["textBody"] as? [JSONDictionary],
               let first = textParts.first,
               let partId = first.optString("partId"),
               let value = bodyValues[partId] as? JSONDictionary {
                plainText = value.optString("value")
            }
            if let htmlParts = json["htmlBody"] as? [JSONDictionary],
               let first = htmlParts.first,
               let partId = first.optString("partId"),
               let value = bodyValues[partId] as? JSONDictionary {
                html = value.optString("value")
            }
        }

        if plainText == nil && html == nil {
            if let textParts = json["textBody"] as? [JSONDictionary],
               let first = textParts.first {
                plainText = first.optString("blobId")
            }
            if let htmlParts = json["htmlBody"] as? [JSONDictionary],
               let first = htmlParts.first {
                html = first.optString("blobId")
            }
        }

        return MessageBody(plainText: plainText, html: html, attachments: attachments)
    }

    static func resolveMailboxKind(role: String?, name: String, path: String) -> MailboxKind {
        switch role {
        case "inbox": return .inbox
        case "sent": return .sent
        case "drafts": return .drafts
        case "trash": return .trash
        case "junk": return .junk
        case "archive": return .regular
        default: break
        }
        let lower = name.lowercased()
        switch lower {
        case "inbox": return .inbox
        case "sent": return .sent
        case "drafts", "entwürfe": return .drafts
        case "trash", "deleted items", "papierkorb": return .trash
        case "junk", "spam": return .junk
        default: return .regular
        }
    }

    private static func parseJmapDate(_ iso: String?) -> Date {
        guard let iso, !iso.isEmpty else { return Date.distantPast }
        let cleaned = iso.replacingOccurrences(of: "Z", with: "+00:00")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: cleaned) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: cleaned) { return date }
        formatter.formatOptions = [.withFullDate]
        if let date = formatter.date(from: cleaned) { return date }
        return Date.distantPast
    }
}
