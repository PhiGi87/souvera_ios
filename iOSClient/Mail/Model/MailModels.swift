// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
enum MailboxKind: String { case inbox, sent, drafts, trash, junk, regular }
struct Mailbox: Identifiable, Hashable {
    let id: String; let account: String; let name: String; let path: String
    let kind: MailboxKind; var unreadCount: Int = 0; var messageCount: Int = 0
    var jmapId: String? = nil; var role: String? = nil
    static func makeId(account: String, path: String) -> String { "\(account)|\(path)" }
}
struct MailMessage: Identifiable {
    let id: String; let account: String; let mailboxId: String; let uid: UInt64 = 0
    let subject: String; let fromAddress: String; let fromDisplayName: String?
    let toAddresses: String; let dateSent: Date; var isRead: Bool = false
    var isFlagged: Bool = false; let sizeBytes: Int64 = 0; var emailId: String = ""
    var messageId: String? = nil; var hasAttachments: Bool = false
    var blobId: String? = nil; var threadId: String? = nil; var keywords: [String: Any]? = nil
}
struct MessageBody { let plainText: String?; let html: String?; let attachments: [AttachmentMeta] }
struct AttachmentMeta: Identifiable, Hashable {
    var id: String { blobId ?? "\(name)|\(sizeBytes)" }; let name: String
    let sizeBytes: Int64; let mimeType: String; let partIndex: Int = 0
    var blobId: String? = nil; var partId: String? = nil
}
struct OutgoingMessage { var to: [String] = []; var cc: [String] = []; var bcc: [String] = []
    var subject: String = ""; var body: String = ""; var bodyHtml: String = ""
    var attachments: [OutgoingAttachment] = []; var inReplyTo: String? = nil
}
struct OutgoingAttachment: Identifiable { var id: String { fileURL.absoluteString }
    let name: String; let mimeType: String; let fileURL: URL
}
enum MailResult<T> { case success(T); case failure(String) }
