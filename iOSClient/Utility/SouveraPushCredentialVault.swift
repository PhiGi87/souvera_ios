// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Persistent vault of every push-proxy registration this device ever made
// (deviceIdentifier + signature + publicKey), stored in the Keychain so it
// SURVIVES logout, account removal AND reinstall. Purpose: on a 409
// conflict ("device owned by another key") the app can self-heal by
// deleting the stale proxy rows with THEIR OWN historical credentials -
// no manual server-side cleanup needed anymore.

import Foundation
import Security

struct SouveraPushVaultEntry: Codable, Equatable {
    let deviceIdentifier: String
    let signature: String
    let publicKey: String
    let account: String
    let channel: String // "normal" | "voip"
    let date: Date
}

enum SouveraPushCredentialVault {
    private static let service = "eu.souvera.app.push.vault"
    private static let accountKey = "registrations"
    private static let maxEntries = 40

    // MARK: - Public API

    static func record(deviceIdentifier: String,
                       signature: String,
                       publicKey: String,
                       account: String,
                       channel: String) {
        guard !deviceIdentifier.isEmpty, !signature.isEmpty, !publicKey.isEmpty else { return }
        var entries = all()
        // Bestehenden Eintrag (gleicher Identifier + Kanal) aktualisieren.
        entries.removeAll { $0.deviceIdentifier == deviceIdentifier && $0.channel == channel }
        entries.append(SouveraPushVaultEntry(
            deviceIdentifier: deviceIdentifier,
            signature: signature,
            publicKey: publicKey,
            account: account,
            channel: channel,
            date: Date()
        ))
        if entries.count > maxEntries {
            entries.sort { $0.date > $1.date }
            entries = Array(entries.prefix(maxEntries))
        }
        save(entries)
    }

    static func all() -> [SouveraPushVaultEntry] {
        guard let data = read() else { return [] }
        return (try? JSONDecoder().decode([SouveraPushVaultEntry].self, from: data)) ?? []
    }

    static func remove(deviceIdentifier: String, channel: String) {
        var entries = all()
        let before = entries.count
        entries.removeAll { $0.deviceIdentifier == deviceIdentifier && $0.channel == channel }
        if entries.count != before { save(entries) }
    }

    // MARK: - Keychain (Generic Password, ein JSON-Blob)

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey
        ]
    }

    private static func read() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func save(_ entries: [SouveraPushVaultEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        SecItemDelete(baseQuery() as CFDictionary)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            SouveraLog.write("PushVault", "save failed: \(status)")
        }
    }
}
