// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from souvera_android mail/model/* and mail/db/entity/*.
// Value types for the JMAP-based mail client, mirroring the Android models.

import Foundation

enum MailboxKind: String {
    case inbox, sent, drafts, trash, junk, regular
}

enum MailSortOrder: String, CaseIterable, Identifiable {
    case dateDesc
    case dateAsc
    case unreadFirst

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .dateDesc: return "_mail_sort_date_desc_"
        case .dateAsc: return "_mail_sort_date_asc_"
        case .unreadFirst: return "_mail_sort_unread_"
        }
    }
}

/// RFC 2342 IMAP namespace a mailbox belongs to. Stalwart exposes the user's
/// own folders as [personal], role/team mailboxes as [shared], and delegated
/// access to another person's mailbox as [otherUsers]. Shared mailboxes are
/// grouped by [Mailbox.ownerIdentity] in the folder list.
enum MailboxNamespace {
    case personal, shared, otherUsers
}

struct Mailbox: Identifiable, Hashable {
    let id: String
    let account: String
    /// JMAP account id this mailbox lives in ("e" = personal, "j" = shared).
    let accountId: String
    let name: String
    let path: String
    let kind: MailboxKind
    var unreadCount: Int
    var messageCount: Int
    let jmapId: String?
    let role: String?
    let namespace: MailboxNamespace
    let ownerIdentity: String?
    let parentId: String?
    /// JMAP myRights: darf dieser Ordner umbenannt/gelöscht werden bzw.
    /// Unterordner aufnehmen? (Systemordner liefern hier false.)
    let mayRename: Bool
    let mayDelete: Bool
    let mayCreateChild: Bool

    static func makeId(account: String, path: String) -> String { "\(account)|\(path)" }

    /// Localized display name: system mailboxes use the active language
    /// (e.g. INBOX → "Posteingang"), user folders show their real name.
    var displayName: String {
        switch kind {
        case .inbox: return NSLocalizedString("_mail_folder_inbox_", comment: "")
        case .sent: return NSLocalizedString("_mail_folder_sent_", comment: "")
        case .drafts: return NSLocalizedString("_mail_folder_drafts_", comment: "")
        case .trash: return NSLocalizedString("_mail_folder_trash_", comment: "")
        case .junk: return NSLocalizedString("_mail_folder_junk_", comment: "")
        case .regular: return name
        }
    }
}

/// One node of the collapsible mailbox tree (JMAP parentId hierarchy).
struct MailboxNode: Identifiable {
    let mailbox: Mailbox
    let children: [MailboxNode]

    var id: String { mailbox.id }
    var totalUnread: Int {
        mailbox.unreadCount + children.reduce(0) { $0 + $1.totalUnread }
    }
}

struct MailMessage: Identifiable {
    let id: String
    let account: String
    let accountId: String
    let mailboxId: String
    let emailId: String
    let messageId: String?
    let subject: String
    let fromAddress: String
    let fromDisplayName: String?
    let toAddresses: String
    let ccAddresses: String
    let dateSent: Date
    var isRead: Bool
    var isFlagged: Bool
    let hasAttachments: Bool
    let sizeBytes: Int64
    let blobId: String?
    let threadId: String?
    let keywords: [String: Any]?

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

struct MailSendFeedback: Equatable {
    let success: Bool
    let message: String
}

/// Context for the compose sheet: a new message or a reply/reply-all/forward
/// with pre-filled recipients, subject, quoted body and (for forwards) the
/// original attachments - the user can still remove them before sending.
struct MailComposeContext: Identifiable {
    enum ComposeMode {
        case new, reply, replyAll, forward
    }

    let mode: ComposeMode
    let message: MailMessage?
    var to: [String]
    var cc: [String]
    var subject: String
    var quoteBody: String
    var preAttachments: [OutgoingAttachment]

    var id: String { message?.id ?? "new" }
}
