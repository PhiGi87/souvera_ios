// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Dedupe-Gate für den "Server-Error: Cache aktiv"-Banner: verhindert
/// Banner-Spam bei wiederholten Fehlschlägen - der Banner darf höchstens
/// alle 5 Minuten neu getriggert werden (Mail, Kalender und Link nutzen
/// denselben Zeitraum, damit die Module einheitlich agieren).
final class SouveraCacheBannerGate {
    private var lastTrigger: Date?

    /// True, wenn der Banner jetzt gezeigt werden darf (>= 5 Minuten seit dem
    /// letzten Trigger); false, wenn der letzte Trigger noch frisch ist.
    @discardableResult
    func shouldTrigger() -> Bool {
        let now = Date()
        if let lastTrigger, now.timeIntervalSince(lastTrigger) < Self.minInterval {
            return false
        }
        lastTrigger = now
        return true
    }

    private static let minInterval: TimeInterval = 300
}
