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

    /// Run 23.10.: Ordnerspalte im Split-Layout eingeklappt (pro Account).
    static func foldersCollapsed(account: String) -> Bool {
        UserDefaults.standard.bool(forKey: key("souvera_mail_folders_collapsed", account: account))
    }

    static func setFoldersCollapsed(_ collapsed: Bool, account: String) {
        UserDefaults.standard.set(collapsed, forKey: key("souvera_mail_folders_collapsed", account: account))
    }

    // MARK: - Lokale E-Mail-Signatur (Run 25.11.)

    /// Brand-String, wenn der Nutzer noch keine lokale Signatur
    /// hinterlegt hat. Bewusst NICHT lokalisiert (Markenzeichen).
    private static let defaultLocalSignature = "Gesendet mit Souvera Workspace."

    /// Lokale Signatur des Nutzers (pro Account). Fehlt der Key,
    /// wird der Brand-Default geliefert; ein vorhandener - auch
    /// leerer - Wert wird 1:1 geliefert (leer = keine Signatur).
    static func localSignature(account: String) -> String {
        let storageKey = key("souvera_mail_signature_local", account: account)
        if UserDefaults.standard.object(forKey: storageKey) is String {
            return UserDefaults.standard.string(forKey: storageKey) ?? ""
        }
        return defaultLocalSignature
    }

    static func setLocalSignature(_ text: String, account: String) {
        UserDefaults.standard.set(text, forKey: key("souvera_mail_signature_local", account: account))
    }
}
