// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from souvera_android link/net/OcsModels.kt — the Nextcloud Talk ("Link") OCS API model layer.

import Foundation

/// Generic Nextcloud OCS v2 response envelope: `{ocs: {meta, data}}`.
struct OcsEnvelope<T: Decodable>: Decodable {
    let ocs: OcsBody<T>
}

struct OcsBody<T: Decodable>: Decodable {
    let meta: OcsMeta
    let data: T?
}

struct OcsMeta: Decodable {
    let status: String?
    let statuscode: Int
    let message: String?
}

/// A Talk ("Link") conversation as returned by `spreed`'s room API (v4).
struct LinkConversation: Decodable, Identifiable {
    let token: String
    let displayName: String
    let type: Int
    let unreadMessages: Int
    let hasCall: Bool
    let lastActivity: TimeInterval
    /// `lastMessage` is a chat-message object, or `[]`/absent when none — decoded loosely.
    let lastMessage: LinkChatMessage?
    /// Talk participant type: 1 = owner, 2 = moderator, 3 = user, 4 = guest.
    /// Löschen einer Konversation erfordert Owner oder Moderator.
    let participantType: Int

    var id: String { token }

    /// Nur Owner/Moderatoren dürfen einen Channel löschen.
    var canDelete: Bool { participantType == 1 || participantType == 2 }

    enum CodingKeys: String, CodingKey {
        case token, displayName, type, unreadMessages, hasCall, lastActivity, lastMessage, participantType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
        type = (try? c.decode(Int.self, forKey: .type)) ?? 0
        unreadMessages = (try? c.decode(Int.self, forKey: .unreadMessages)) ?? 0
        hasCall = (try? c.decode(Bool.self, forKey: .hasCall)) ?? false
        lastActivity = (try? c.decode(TimeInterval.self, forKey: .lastActivity)) ?? 0
        // Server sends `[]` when there is no last message; that fails object decoding, so tolerate it.
        lastMessage = try? c.decode(LinkChatMessage.self, forKey: .lastMessage)
        participantType = (try? c.decode(Int.self, forKey: .participantType)) ?? 0
    }

    /// Last message preview text; falls back to a file marker for shared files.
    func lastMessageText() -> String {
        guard let msg = lastMessage else { return "" }
        if let file = msg.fileName() { return "📎 \(file)" }
        return msg.message
    }

    var isOneToOne: Bool { type == LinkRoomType.oneToOne.rawValue }
}

enum LinkRoomType: Int {
    case oneToOne = 1
    case group = 2
    case `public` = 3
    case changelog = 4
}

/// A single chat message in a conversation.
struct LinkChatMessage: Decodable, Identifiable {
    let id: Int64
    let token: String
    let actorId: String
    let actorDisplayName: String
    let actorType: String
    let timestamp: TimeInterval
    let message: String
    let systemMessage: String
    /// Rich-object parameters; kept as raw JSON so we can pull out shared-file names.
    let messageParameters: [String: LinkRichObject]?

    enum CodingKeys: String, CodingKey {
        case id, token, actorId, actorDisplayName, actorType, timestamp, message, systemMessage, messageParameters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        token = (try? c.decode(String.self, forKey: .token)) ?? ""
        actorId = (try? c.decode(String.self, forKey: .actorId)) ?? ""
        actorDisplayName = (try? c.decode(String.self, forKey: .actorDisplayName)) ?? ""
        actorType = (try? c.decode(String.self, forKey: .actorType)) ?? ""
        timestamp = (try? c.decode(TimeInterval.self, forKey: .timestamp)) ?? 0
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
        systemMessage = (try? c.decode(String.self, forKey: .systemMessage)) ?? ""
        // messageParameters can be `[]` (empty array) or an object; tolerate both.
        messageParameters = try? c.decode([String: LinkRichObject].self, forKey: .messageParameters)
    }

    /// File name if this message is a shared file (Talk puts a `file` rich-object parameter), else nil.
    func fileName() -> String? {
        messageParameters?.values.first(where: { $0.type == "file" })?.name
    }

    /// File metadata if this message carries a shared/uploaded file.
    func fileInfo() -> LinkFileInfo? {
        guard let file = messageParameters?.values.first(where: { $0.type == "file" }),
              let name = file.name else { return nil }
        return LinkFileInfo(
            name: name,
            path: file.path,
            size: Int64(file.size ?? "0") ?? 0
        )
    }

    var isSystemMessage: Bool { !systemMessage.isEmpty }

    /// The deleted message id when this is a `message_deleted` system
    /// message (Talk keeps the deleted id in the parent rich object).
    var deletedParentId: Int64? {
        guard isSystemMessage, systemMessage == "message_deleted" else { return nil }
        if let parent = messageParameters?.values.first, let id = parent.id {
            return Int64(id)
        }
        return nil
    }
}

/// A Talk rich-object parameter (only the fields we use).
struct LinkRichObject: Decodable {
    let type: String?
    let name: String?
    let id: String?
    let path: String?
    let size: String?

    enum CodingKeys: String, CodingKey { case type, name, id, path, size }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decode(String.self, forKey: .type)
        name = try? c.decode(String.self, forKey: .name)
        id = try? c.decode(String.self, forKey: .id)
        path = try? c.decode(String.self, forKey: .path)
        size = try? c.decode(String.self, forKey: .size)
    }
}

struct LinkFileInfo {
    let name: String
    let path: String?
    let size: Int64
}

/// A user/group suggestion from the autocomplete API, used to start a new conversation.
struct LinkSuggestion: Decodable, Identifiable {
    let id: String
    let label: String
    let source: String

    init(id: String, label: String, source: String) {
        self.id = id
        self.label = label
        self.source = source
    }

    enum CodingKeys: String, CodingKey { case id, label, source }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        source = (try? c.decode(String.self, forKey: .source)) ?? ""
    }
}
