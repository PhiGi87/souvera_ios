// SPDX-FileCopyrightText: 2026 Host-On Service Provider GmbH (Souvera)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from souvera_android mail/model/* and mail/db/entity/*. Plain value types for the native
// mail client. Persistence is handled by the app's Realm database (see MailStore); these mirror the
// android Room entities.

import Foundation

enum MailboxKind: String {
    case inbox, sent, drafts, trash, junk, regular
}

/// A mail folder (IMAP mailbox).
struct Mailbox: Identifiable, Hashable {
    let id: String           // "\(account)|\(path)"
    let account: String
    let name: String         // leaf display name
    let path: String         // IMAP full path
    let kind: MailboxKind
    var unreadCount: Int
    var messageCount: Int

    static func makeId(account: String, path: String) -> String { "\(account)|\(path)" }
}

/// A message envelope row (list view). Body/attachments are fetched on demand.
struct MailMessage: Identifiable, Hashable {
    let id: String           // "\(mailboxId)|\(uid)"
    let account: String
    let mailboxId: String
    let uid: UInt64
    let subject: String
    let fromAddress: String
    let fromDisplayName: String?
    let toAddresses: String
    let dateSent: Date
    var isRead: Bool
    var isFlagged: Bool
    let sizeBytes: Int64

    var displayFrom: String {
        if let name = fromDisplayName, !name.isEmpty { return name }
        return fromAddress
    }
}

/// A parsed message body plus attachment metadata.
struct MessageBody {
    let plainText: String?
    let html: String?
    let attachments: [AttachmentMeta]
}

struct AttachmentMeta: Identifiable, Hashable {
    var id: String { "\(name)|\(sizeBytes)" }
    let name: String
    let sizeBytes: Int64
    let mimeType: String
    /// Index within the message's attachment list, used to fetch the content on demand.
    let partIndex: Int
}

/// A message being composed.
struct OutgoingMessage {
    var to: [String] = []
    var cc: [String] = []
    var bcc: [String] = []
    var subject: String = ""
    var body: String = ""
    var bodyHtml: String = ""
    var attachments: [OutgoingAttachment] = []
}

struct OutgoingAttachment: Identifiable {
    var id: String { fileURL.absoluteString }
    let name: String
    let mimeType: String
    let fileURL: URL
}

/// Result wrapper mirroring android MailResult (success / user-facing error message).
enum MailResult<T> {
    case success(T)
    case failure(String)
}
