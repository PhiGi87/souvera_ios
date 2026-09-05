// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Verlauf der tatsächlich verwendeten Empfänger, strikt pro Account
// gespeichert. Liefert die Vorschläge im Composer (ab 3 Zeichen), sortiert
// nach "zuletzt verwendet". Capture erfolgt beim erfolgreichen Senden.

import Foundation

struct UsedRecipient: Codable, Identifiable {
    var id: String { email }
    let email: String
    var displayName: String?
    var lastUsed: Date
    var useCount: Int
}

enum UsedRecipientStore {
    private static let maxEntries = 200

    private static func fileURL(account: String) -> URL {
        let safeAccount = account.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SouveraUsedRecipients", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(safeAccount).json")
    }

    private static func load(account: String) -> [UsedRecipient] {
        guard let data = try? Data(contentsOf: fileURL(account: account)),
              let list = try? JSONDecoder().decode([UsedRecipient].self, from: data)
        else { return [] }
        return list
    }

    private static func save(_ list: [UsedRecipient], account: String) {
        guard let data = try? JSONEncoder().encode(Array(list.prefix(maxEntries))) else { return }
        try? data.write(to: fileURL(account: account), options: .atomic)
    }

    /// Nimmt Empfänger (To/Cc/Bcc) beim Senden in den Verlauf auf.
    static func record(account: String, emails: [String], displayName: String? = nil) {
        guard !account.isEmpty else { return }
        var list = load(account: account)
        let now = Date()
        for raw in emails {
            let email = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard email.contains("@") else { continue }
            if let idx = list.firstIndex(where: { $0.email == email }) {
                list[idx].lastUsed = now
                list[idx].useCount += 1
                if let displayName, !displayName.isEmpty { list[idx].displayName = displayName }
            } else {
                list.append(UsedRecipient(email: email, displayName: displayName, lastUsed: now, useCount: 1))
            }
        }
        list.sort { $0.lastUsed > $1.lastUsed }
        save(list, account: account)
    }

    /// Vorschläge aus dem Verlauf: Filter ab 3 Zeichen auf E-Mail/Name,
    /// sortiert nach "zuletzt verwendet".
    static func suggestions(account: String, token: String, limit: Int = 6) -> [UsedRecipient] {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return [] }
        return load(account: account).filter {
            $0.email.localizedCaseInsensitiveContains(trimmed)
                || ($0.displayName ?? "").localizedCaseInsensitiveContains(trimmed)
        }
        .prefix(limit)
        .map { $0 }
    }

    /// Entfernt den Verlauf dieses Kontos (Logout/Account-Löschen).
    static func removeAccount(account: String) {
        try? FileManager.default.removeItem(at: fileURL(account: account))
    }
}
