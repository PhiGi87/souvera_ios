// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from souvera_android mail/model/* and mail/db/entity/*.
// Value types for the JMAP-based mail client, mirroring the Android models.

import Foundation

enum MailboxKind: String {
    case inbox, sent, drafts, trash, junk, regular
}

struct Mailbox: Identifiable, Hashable {
    let id: String
    let account: String
    let name: String
    let path: String
    let kind: MailboxKind
    var unreadCount: Int
    var messageCount: Int
    let jmapId: String?
    let role: String?

    static func makeId(account: String, path: String) -> String { "\(account)|\(path)" }
}

struct MailMessage: Identifiable {
    let id: String
    let account: String
    let mailboxId: String
    let emailId: String
    let messageId: String?
    let subject: String
    let fromAddress: String
    let fromDisplayName: String?
    let toAddresses: String
    let dateSent: Date
    var isRead: Bool
    var isFlagged: Bool
    let hasAttachments: Bool
    let sizeBytes: Int64
    let blobId: String?
    let threadId: String?
    let keywords: JSONDictionary?

    var displayFrom: String {
        if let name = fromDisplayName, !name.isEmpty { return name }
        return fromAddress
    }
}

struct MessageBody {
    let plainText: String?
    let html: String?
    let attachments: [AttachmentMeta]
}

struct AttachmentMeta: Identifiable, Hashable {
    var id: String { blobId ?? "\(name)|\(sizeBytes)" }
    let name: String
    let sizeBytes: Int64
    let mimeType: String
    let blobId: String?
    let partId: String?
}

struct OutgoingMessage {
    var to: [String] = []
    var cc: [String] = []
    var bcc: [String] = []
    var subject: String = ""
    var body: String = ""
    var bodyHtml: String = ""
    var attachments: [OutgoingAttachment] = []
    var inReplyTo: String? = nil
}

struct OutgoingAttachment: Identifiable {
    var id: String { fileURL.absoluteString }
    let name: String
    let mimeType: String
    let fileURL: URL
}

enum MailResult<T> {
    case success(T)
    case failure(String)
}
