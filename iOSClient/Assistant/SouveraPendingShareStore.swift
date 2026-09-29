// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Uebergabe geteilter Inhalte (Text/URL + Dateien) von der Share-Extension
// an die App (Mail-Anhang, Link-Raum). Ablage im App-Group-Container, damit
// beide Prozesse dieselben Dateien und denselben Datensatz sehen.

import Foundation

enum SouveraPendingShareStore {

    /// Aktionen des Teilen-Handoffs.
    static let actionMail = "mail"
    static let actionTalk = "talk"
    static let actionFiles = "files"

    /// Ziel-Abhängige Grenzen je Datei (Run 29.09., Feedback): Chat/Raum
    /// 10 MB, Mail-Anhang 20 MB, Dateien-Upload 100 MB. Dateien bis zur
    /// Files-Grenze werden kopiert und von jedem Ziel nach seiner Grenze
    /// bewertet; darueber hinaus bleibt nur der Hinweis.
    static let talkLimitBytes: Int64 = 10 * 1024 * 1024
    static let mailLimitBytes: Int64 = 20 * 1024 * 1024
    static let filesLimitBytes: Int64 = 100 * 1024 * 1024

    /// Kompatibilitaet: groesste kopierbare Datei (= Files-Grenze).
    static var maxFileBytes: Int64 { filesLimitBytes }

    /// Ziel-Grenze fuer eine Aktion ("mail"/"talk"/"files").
    static func limitBytes(for action: String) -> Int64 {
        switch action {
        case actionMail: return mailLimitBytes
        case actionTalk: return talkLimitBytes
        default: return filesLimitBytes
        }
    }

    /// Pure Pruefung (unit-testbar): passt die Dateigroesse zum Ziel?
    static func allows(sizeBytes: Int64, for action: String) -> Bool {
        sizeBytes <= limitBytes(for: action)
    }

    /// Alle Dateien des Shares passen zum Ziel (Text-only immer ja).
    static func allowsAll(_ files: [SharedFile], for action: String) -> Bool {
        files.allSatisfy { allows(sizeBytes: $0.size, for: action) }
    }

    /// Groesse der ersten Datei, die das Ziel-Limit sprengt (fuer den Hinweis).
    static func firstOversize(_ files: [SharedFile], for action: String) -> SharedFile? {
        files.first { !allows(sizeBytes: $0.size, for: action) }
    }

    struct SharedFile: Codable {
        let name: String
        let mimeType: String
        let path: String
        let size: Int64
        /// Decode-Kompatibilitaet (alter 10-MB-Store): im neuen Modell
        /// nur noch true, wenn die Datei NICHT kopiert wurde (>100 MB).
        let tooLarge: Bool

        init(name: String, mimeType: String, path: String, size: Int64, tooLarge: Bool) {
            self.name = name
            self.mimeType = mimeType
            self.path = path
            self.size = size
            self.tooLarge = tooLarge
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            mimeType = try container.decode(String.self, forKey: .mimeType)
            path = try container.decode(String.self, forKey: .path)
            size = try container.decode(Int64.self, forKey: .size)
            tooLarge = try container.decodeIfPresent(Bool.self, forKey: .tooLarge) ?? false
        }
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
