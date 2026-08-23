// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from souvera_android link/net/OcsModels.kt — the Nextcloud Talk ("Link") OCS API model layer.

import Foundation
import SwiftUI
import UIKit

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
    /// Avatar-Version (Cache-Busting für den Raum-Avatar).
    let avatarVersion: String
    /// True, wenn der Raum einen eigenen Avatar hat.
    let isCustomAvatar: Bool

    var id: String { token }

    /// Nur Owner/Moderatoren dürfen einen Channel löschen.
    var canDelete: Bool { participantType == 1 || participantType == 2 }
    /// Teilnehmer hinzufügen erfordert ebenfalls Owner-/Moderator-Recht.
    var canManage: Bool { participantType == 1 || participantType == 2 }

    enum CodingKeys: String, CodingKey {
        case token, displayName, type, unreadMessages, hasCall, lastActivity, lastMessage, participantType, avatarVersion, isCustomAvatar
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
        avatarVersion = (try? c.decode(String.self, forKey: .avatarVersion)) ?? ""
        isCustomAvatar = (try? c.decode(Bool.self, forKey: .isCustomAvatar)) ?? false
    }

    /// Last message preview text; falls back to a file marker for shared files.
    func lastMessageText() -> String {
        guard let msg = lastMessage else { return "" }
        if let file = msg.fileName() { return "📎 \(file)" }
        return msg.displayText()
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
    /// Emoji-Reaktionen: Emoji -> Anzahl.
    var reactions: [String: Int] = [:]
    /// Emojis, mit denen der aktuelle Nutzer selbst reagiert hat.
    var reactionsSelf: [String] = []
    /// Elternteil bei Antworten (Talk liefert die volle Nachricht mit; als
    /// eigener Typ, um die Struct-Rekursion zu vermeiden).
    let parent: LinkParent?

    enum CodingKeys: String, CodingKey {
        case id, token, actorId, actorDisplayName, actorType, timestamp, message, systemMessage, messageParameters, reactions, reactionsSelf, parent
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
        // reactions kann ein Objekt oder `[]` sein; tolerant dekodieren.
        reactions = (try? c.decode([String: Int].self, forKey: .reactions)) ?? [:]
        reactionsSelf = (try? c.decode([String].self, forKey: .reactionsSelf)) ?? []
        parent = try? c.decode(LinkParent.self, forKey: .parent)
    }

    /// Talk erzeugt für jede Reaktion eine Systemnachricht; der Browser
    /// blendet diese aus der Ansicht aus (die Reaktion steht ohnehin am
    /// Elternteil). Diese Nachrichten gehören nicht in den Verlauf.
    var isReactionEvent: Bool {
        systemMessage == "reaction" || systemMessage == "reaction_revoked" || systemMessage == "reaction_deleted"
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

    /// AttributedString für die Bubble: {mention-...}-Platzhalter werden als
    /// @Name mit hellem Orangen-Hintergrund (Pill) gerendet, alle anderen
    /// Platzhalter als Klartext ersetzt. Rohe @"Name"-Reste (alte, unparste
    /// Nachrichten) werden ebenfalls als Pille dargestellt.
    func attributedDisplayText() -> AttributedString {
        var legacyMentions: [String: String] = [:]
        var working = message
        var legacyIndex = 0
        while let range = working.range(of: #"@\"[^\"]+\""#, options: .regularExpression) {
            let raw = String(working[range])
            let name = String(raw.dropFirst(2).dropLast())
            let key = "mention-legacy-\(legacyIndex)"
            legacyIndex += 1
            legacyMentions[key] = name
            working.replaceSubrange(range, with: "{\(key)}")
        }
        var output = AttributedString()
        var remaining = Substring(working)
        while let open = remaining.firstIndex(of: "{") {
            output += AttributedString(String(remaining[..<open]))
            if let close = remaining[open...].firstIndex(of: "}") {
                let key = String(remaining[remaining.index(after: open)..<close])
                let name = messageParameters?[key]?.name ?? messageParameters?[key]?.id ?? legacyMentions[key] ?? key
                var piece = AttributedString(key.hasPrefix("mention-") ? "@\(name)" : name)
                if key.hasPrefix("mention-") {
                    // Schrift je nach Modus: hell = schwarz, dunkel = orange
                    // (orange auf hellem Grund wäre zu kontrastarm).
                    piece.foregroundColor = Color(uiColor: UIColor { trait in
                        trait.userInterfaceStyle == .dark ? .systemOrange : .black
                    })
                    piece.backgroundColor = Color.orange.opacity(0.22)
                }
                output += piece
                remaining = remaining[remaining.index(after: close)...]
            } else {
                output += AttributedString(String(remaining[open...]))
                remaining = ""
            }
        }
        output += AttributedString(String(remaining))
        return output
    }

    /// Platzhalter wie {user1} oder {mention-user1} werden durch die Namen
    /// aus den messageParameters ersetzt (Systemnachrichten UND normale
    /// Nachrichten - sonst zeigt z. B. die Kanal-Vorschau rohe Platzhalter).
    func displayText() -> String {
        var text = message
        if let params = messageParameters, !params.isEmpty {
            for (key, object) in params {
                let name = object.name ?? object.id ?? ""
                if !name.isEmpty {
                    text = text.replacingOccurrences(of: "{\(key)}", with: name)
                }
            }
        }
        return text
    }

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
/// Teilnehmer einer Konversation (GET participants).
struct LinkParticipant: Decodable, Identifiable {
    let attendeeId: Int
    let actorType: String
    let actorId: String
    let displayName: String
    let participantType: Int

    var id: Int { attendeeId }

    enum CodingKeys: String, CodingKey {
        case attendeeId, actorType, actorId, displayName, participantType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attendeeId = (try? c.decode(Int.self, forKey: .attendeeId)) ?? 0
        actorType = (try? c.decode(String.self, forKey: .actorType)) ?? ""
        actorId = (try? c.decode(String.self, forKey: .actorId)) ?? ""
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? actorId
        participantType = (try? c.decode(Int.self, forKey: .participantType)) ?? 0
    }
}

/// Elternteil einer Antwort (Talk liefert die volle Nachricht als `parent`,
/// ohne weitere Verschachtelung). Eigener Typ statt rekursivem
/// LinkChatMessage (Struct-Rekursion wäre nicht zulässig).
struct LinkParent: Decodable {
    let id: Int64
    let actorId: String
    let actorDisplayName: String
    let timestamp: TimeInterval
    let message: String
    let systemMessage: String

    var isSystemMessage: Bool { !systemMessage.isEmpty }

    enum CodingKeys: String, CodingKey {
        case id, actorId, actorDisplayName, timestamp, message, systemMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int64.self, forKey: .id)) ?? 0
        actorId = (try? c.decode(String.self, forKey: .actorId)) ?? ""
        actorDisplayName = (try? c.decode(String.self, forKey: .actorDisplayName)) ?? ""
        timestamp = (try? c.decode(TimeInterval.self, forKey: .timestamp)) ?? 0
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
        systemMessage = (try? c.decode(String.self, forKey: .systemMessage)) ?? ""
    }
}

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
