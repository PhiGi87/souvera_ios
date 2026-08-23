// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Lokaler Fallback-Cache für den Link-Bereich: sichert die rohen
/// OCS-Antworten der Konversationsliste und der Nachrichten je Channel.
/// Bei Wartungsmodus/Offline wird daraus der letzte Stand geladen.
struct LinkCache {
    private static var cacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("link-cache", isDirectory: true)
    }

    private static func fileURL(_ name: String) -> URL? {
        guard let dir = cacheDirectory else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    // MARK: - Conversations

    static func saveConversations(raw: Data) {
        guard let url = fileURL("conversations.json") else { return }
        try? raw.write(to: url, options: .atomic)
    }

    static func loadConversations() -> [LinkConversation]? {
        guard let url = fileURL("conversations.json"),
              let data = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(OcsEnvelope<[LinkConversation]>.self, from: data) else { return nil }
        return env.ocs.data
    }

    // MARK: - Messages per channel

    static func saveMessages(token: String, raw: Data) {
        guard let url = fileURL("chat-\(token).json") else { return }
        try? raw.write(to: url, options: .atomic)
    }

    static func loadMessages(token: String) -> [LinkChatMessage]? {
        guard let url = fileURL("chat-\(token).json"),
              let data = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(OcsEnvelope<[LinkChatMessage]>.self, from: data) else { return nil }
        return env.ocs.data
    }
}
