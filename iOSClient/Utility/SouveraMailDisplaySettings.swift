// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Darstellungs-Optionen der Mail, pro Account gespeichert.

import Foundation

enum SouveraMailDisplaySettings {
    private static func key(_ base: String, account: String) -> String {
        let safe = account.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return "\(base)_\(safe)"
    }

    /// Fokus-Leser (iPad): Mail-Detail als zentrierte Karte über
    /// abgedunkeltem Hintergrund statt Vollbild-Overlay.
    static func focusReaderEnabled(account: String) -> Bool {
        UserDefaults.standard.bool(forKey: key("souvera_mail_focus_reader", account: account))
    }

    static func setFocusReader(_ enabled: Bool, account: String) {
        UserDefaults.standard.set(enabled, forKey: key("souvera_mail_focus_reader", account: account))
    }
}
