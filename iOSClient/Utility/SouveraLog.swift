// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Datei-Logger für alle Souvera-Diagnosen (Push-Registrierung, Calls,
/// Hintergrund-Sync, App-Lifecycle). Ergänzt die Konsolen-Logs (nkLog) um
/// eine auslesbare Datei, die über „Logs teilen" per Mail an Host-On geht.
enum SouveraLog {
    private static let maxFileSize: UInt64 = 2_000_000

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ tag: String, _ message: String) {
        write("[\(tag)] \(message)")
    }

    static func write(_ message: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent("souvera-app.log")
        let line = "[\(timestampFormatter.string(from: Date()))] \(message)\n"
        do {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? UInt64) ?? 0
            if size > maxFileSize {
                // Rotation: alte Datei behalten, neue beginnen.
                let backup = documents.appendingPathComponent("souvera-app.log.old")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: url, to: backup)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8))
            } else if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        } catch {
            // Loggen darf niemals werfen.
        }
    }

    /// Inhalt der Log-Datei (für den Versand).
    static func fileContent() -> String {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return "" }
        let url = documents.appendingPathComponent("souvera-app.log")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
