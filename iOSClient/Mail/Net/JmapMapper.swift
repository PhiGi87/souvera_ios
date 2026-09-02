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
        accountId: String,
        json: [String: Any],
        path: String? = nil,
        namespace: MailboxNamespace = .personal,
        ownerIdentity: String? = nil
    ) -> Mailbox {
        let name = json.optString("name") ?? path ?? "?"
        let resolvedPath = path ?? name
        let role = json.optString("role")
        let kind = resolveMailboxKind(role: role, name: name, path: resolvedPath)
        let jmapId = json.optString("id")
        let rights = json["myRights"] as? [String: Any]

        return Mailbox(
            id: Mailbox.makeId(account: account, path: resolvedPath),
            account: account,
            accountId: accountId,
            name: name,
            path: resolvedPath,
            kind: kind,
            unreadCount: json.optInt("unreadEmails"),
            messageCount: json.optInt("totalEmails"),
            jmapId: jmapId,
            role: role,
            namespace: namespace,
            ownerIdentity: ownerIdentity,
            parentId: json.optString("parentId"),
            mayRename: (rights?["mayRename"] as? Bool) ?? true,
            mayDelete: (rights?["mayDelete"] as? Bool) ?? true,
            mayCreateChild: (rights?["mayCreateChild"] as? Bool) ?? true
        )
    }

    static func mapMessage(
        account: String,
        accountId: String,
        mailboxId: String,
        json: [String: Any]
    ) -> MailMessage {
        // NSDictionary-Zugriff statt `as? [[String: Any]]`: die ObjC→Swift-
        // Bridging-Kaskade (NSArray → [[String: Any]]) blockierte bei großen
        // Mailboxen den Main-Thread (Watchdog 0xdead10cc).
        let fromFirst = (json["from"] as? [Any])?.first as? NSDictionary
        let fromAddress = fromFirst?["email"] as? String ?? ""
        let fromName = fromFirst?["name"] as? String

        let toList = json["to"] as? [Any] ?? []
        let ccList = json["cc"] as? [Any] ?? []
        let hasAtt = json.optBool("hasAttachment") || ((json["attachments"] as? [Any])?.count ?? 0) > 0
        let keywords = json["keywords"] as? [String: Any]

        let isRead = (keywords?["$seen"] as? Bool) ?? false
        let isFlagged = (keywords?["$flagged"] as? Bool) ?? false

        let toAddressStr = toList.compactMap { ($0 as? NSDictionary)?["email"] as? String }.joined(separator: ", ")
        let ccAddressStr = ccList.compactMap { ($0 as? NSDictionary)?["email"] as? String }.joined(separator: ", ")

        return MailMessage(
            id: "\(mailboxId)|\(json.optString("id") ?? "")",
            account: account,
            accountId: accountId,
            mailboxId: mailboxId,
            emailId: json.optString("id") ?? "",
            messageId: (json["messageId"] as? [Any])?.first as? String,
            subject: json.optString("subject") ?? "",
            fromAddress: fromAddress,
            fromDisplayName: fromName,
            toAddresses: toAddressStr,
            ccAddresses: ccAddressStr,
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

    static func mapBody(json: [String: Any]) -> MessageBody {
        let attachments = (json["attachments"] as? [[String: Any]])?.map { att in
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

        if let bodyValues = json["bodyValues"] as? [String: Any] {
            if let textParts = json["textBody"] as? [[String: Any]],
               let first = textParts.first,
               let partId = first.optString("partId"),
               let value = bodyValues[partId] as? [String: Any] {
                plainText = value.optString("value")?.normalizedLineEndings()
            }
            if let htmlParts = json["htmlBody"] as? [[String: Any]],
               let first = htmlParts.first,
               // Nur echte text/html-Parts als HTML rendern; text/plain-Parts
               // (z. B. bei gesendeten Mails) würden sonst ihre Zeilenumbrüche
               // im WKWebView verlieren.
               first.optString("type") == "text/html",
               let partId = first.optString("partId"),
               let value = bodyValues[partId] as? [String: Any] {
                html = value.optString("value")
            }
        }

        // When the server did not inline body values, the caller downloads
        // the text/html blobs via their blobIds (mirrors the Android client).
        // Never surface the raw blobId as text.

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
        // Only exact, standard English names identify system mailboxes.
        // Stalwart's sent special-use mailbox is "Sent Items"; a plain
        // "Sent" folder is user data and stays a regular folder.
        switch name {
        case "Inbox": return .inbox
        case "Sent Items", "Sent Messages": return .sent
        case "Drafts": return .drafts
        case "Trash", "Deleted Items": return .trash
        case "Junk", "Spam": return .junk
        default: return .regular
        }
    }

    private static func parseJmapDate(_ iso: String?) -> Date {        guard let iso, !iso.isEmpty else { return Date.distantPast }
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
