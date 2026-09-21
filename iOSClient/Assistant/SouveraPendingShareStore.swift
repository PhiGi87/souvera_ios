// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Uebergabe geteilter Inhalte (Text/URL + Dateien) von der Share-Extension
// an die App (Mail-Anhang, Link-Raum). Ablage im App-Group-Container, damit
// beide Prozesse dieselben Dateien und denselben Datensatz sehen.

import Foundation

enum SouveraPendingShareStore {

    /// Maximalgroesse je Datei fuer alle Teilen-Wege (Android-Paritaet).
    static let maxFileBytes: Int64 = 10 * 1024 * 1024

    struct SharedFile: Codable {
        let name: String
        let mimeType: String
        let path: String
        let size: Int64
        let tooLarge: Bool
    }

    struct Share: Codable {
        let action: String
        let text: String
        let files: [SharedFile]
        let createdAt: Date
    }

    private static let key = "souvera.pendingShare"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup)
    }

    static func save(_ share: Share) {
        guard let defaults, let data = try? JSONEncoder().encode(share) else { return }
        defaults.set(data, forKey: key)
        defaults.synchronize()
    }

    /// Liefert den Datensatz NUR fuer die erwartete Aktion und raeumt ihn ab -
    /// so konsumieren sich Mail und Link nicht gegenseitig.
    static func loadAndClear(action: String) -> Share? {
        guard let defaults, let data = defaults.data(forKey: key),
              let share = try? JSONDecoder().decode(Share.self, from: data) else { return nil }
        guard share.action == action else { return nil }
        defaults.removeObject(forKey: key)
        defaults.synchronize()
        return share
    }

    /// Verzeichnis im App-Group-Container fuer die geteilten Dateien.
    static func filesDirectory() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: NCBrandOptions.shared.capabilitiesGroup) else { return nil }
        let dir = container.appendingPathComponent("SouveraShareIncoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Alte geteilte Dateien (> 24 h) aufraeumen.
    static func cleanupOldFiles() {
        guard let dir = filesDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for url in files {
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               date < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

extension Notification.Name {
    /// Wird vom Host nach dem Teilen-Deep-Link gepostet; object = "mail"/"talk".
    static let souveraShareHandoff = Notification.Name("souveraShareHandoff")
}
