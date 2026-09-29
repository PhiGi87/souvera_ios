// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 29.09. (Feedback: Termin-Änderungen dauerten bei schlechter
// Verbindung lange, bis sie sichtbar wurden): Persistente Warteschlange
// für CalDAV-Schreiboperationen. Das Gerät zeigt Änderungen SOFORT an,
// der Server-Schreib läuft im Hintergrund; scheitert er (schlechter
// Empfang), bleibt der Auftrag bestehen und wird beim nächsten Flush
// (Foreground, erfolgreicher Sync, Netzrückkehr) erneut zugestellt.

import Foundation

enum SouveraCalendarPendingWrites {

    enum Kind: String, Codable {
        case create
        case update
        case delete
    }

    struct PendingWrite: Codable, Identifiable {
        let id: String
        let kind: Kind
        let calendarHref: String
        /// Ressourcen-Pfad RELATIV zum Kalender (z. B. "uid.ics").
        let href: String
        let uid: String
        /// Neuer ICS-Inhalt (create/update); bei delete nur informativ.
        let ics: String
        var attempts: Int
        let createdAt: Date
    }

    private static let key = "souvera.calendarPendingWrites"

    private static var defaults: UserDefaults { UserDefaults.standard }

    // MARK: - Queue

    static func loadAll() -> [PendingWrite] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([PendingWrite].self, from: data) else { return [] }
        return list
    }

    static func save(_ writes: [PendingWrite]) {
        guard let data = try? JSONEncoder().encode(writes) else { return }
        defaults.set(data, forKey: key)
    }

    static func enqueue(kind: Kind, calendarHref: String, href: String, uid: String, ics: String) {
        var list = loadAll()
        // Dedupe: dieselbe Ressource nur einmal in der Schlange (der
        // letzte Stand zählt - Update überschreibt ältere Aufträge).
        list.removeAll { $0.calendarHref == calendarHref && $0.href == href }
        list.append(PendingWrite(id: UUID().uuidString,
                                 kind: kind,
                                 calendarHref: calendarHref,
                                 href: href,
                                 uid: uid,
                                 ics: ics,
                                 attempts: 0,
                                 createdAt: Date()))
        save(list)
        SouveraLog.write("Calendar", "pending write queued: \(kind.rawValue) \(href) (\(list.count) queued)")
    }

    static func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var list = loadAll()
        list.removeAll { ids.contains($0.id) }
        save(list)
    }

    // MARK: - Retry-Steuerung (pure, unit-testbar)

    /// Backoff zwischen Zustellversuchen: 2 s / 5 s / 10 s, danach
    /// gedeckelt auf 10 s (der Flush läuft eh nur bei Gelegenheiten).
    static func backoffSeconds(attempts: Int) -> UInt64 {
        switch max(0, attempts) {
        case 0: return 2
        case 1: return 5
        default: return 10
        }
    }

    /// Aufträge aufgeben, die trotz Queue dauerhaft scheitern (z. B.
    /// 403): nach 20 Versuchen verwerfen (Diagnose-Log im Aufrufer).
    static let maxAttempts = 20
}

extension Notification.Name {
    /// Flush-Aufforderung für die Kalender-Warteschlange (verzögerter
    /// Retry nach fehlgeschlagenem Sofortversuch).
    static let calendarPendingFlushRequested = Notification.Name("souveraCalendarPendingFlushRequested")
}
