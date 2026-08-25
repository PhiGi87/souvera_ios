// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Datei-Logger für alle Souvera-Diagnosen (Push-Registrierung, Calls,
/// Hintergrund-Sync, App-Lifecycle). Ergänzt die Konsolen-Logs (nkLog) um
/// eine auslesbare Datei, die über „Logs teilen" per Mail an Host-On geht.
enum SouveraLog {
    /// Maximalgröße PRO Log-Datei in Bytes (9 MB x 2 Dateien = ~18 MB
    /// kombiniertes "Logs teilen"-Dokument inkl. Kopf).
    static let maxFileBytes = 9_000_000

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
        appendLine(line, to: url)
        trimToLimit(at: url)
    }

    private static func appendLine(_ line: String, to url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8))
        } else if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }

    /// Entfernt die ÄLTESTEN Zeilen vom Anfang, bis die Datei wieder unter
    /// ~70% des Limits liegt (die neuesten Einträge bleiben erhalten).
    static func trimToLimit(at url: URL, maxBytes: Int = SouveraLog.maxFileBytes) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size > UInt64(maxBytes) else { return }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        let target = Int(Double(maxBytes) * 0.7)
        var current = data.count
        while current > target, lines.count > 1 {
            current -= (lines.removeFirst().utf8.count + 1)
        }
        let kept = lines.joined(separator: "\n")
        try? kept.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Einmalig beim App-Start: bestehende (ggf. historisch überdimensionierte)
    /// Log-Dateien aufs Limit trimmen; alte Rotationsdatei entfernen.
    static func trimStartupLogs() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let app = documents.appendingPathComponent("souvera-app.log")
        let mail = documents.appendingPathComponent("souvera-mail.log")
        trimToLimit(at: app)
        trimToLimit(at: mail)
        try? FileManager.default.removeItem(at: documents.appendingPathComponent("souvera-app.log.old"))
    }

    /// Inhalt der Log-Datei (für den Versand).
    static func fileContent() -> String {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return "" }
        let url = documents.appendingPathComponent("souvera-app.log")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
