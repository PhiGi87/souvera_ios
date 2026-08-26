// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import NextcloudKit

/// Per-Gruppen-Push-Toggles (P70). Standard ist "an": Solange der Nutzer
/// nichts ändert, bleibt das Push-Verhalten wie bisher.
///
/// - Mail & Kalender: NC-Normal-Push-Zeile (Mail läuft über die NC-Kette,
///   Kalender-Erinnerungen sind lokal - der Toggle unterdrückt die
///   Mail-Push-Verarbeitung UND das lokale Zustellen).
/// - Link/Talk: Talk/VoIP-Kanal (eigene Gerätezeile + Proxy).
enum SouveraPushToggles {

    static let mailCalendarKey = "souvera_push_mail_calendar_enabled"
    static let linkTalkKey = "souvera_push_link_talk_enabled"

    /// Ablage in der App-Gruppe, damit auch die Notification Service
    /// Extension den Filter liest (Übergangs-Pushes unterdrücken).
    static var store: UserDefaults {
        UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup) ?? .standard
    }

    static var mailCalendarEnabled: Bool {
        get { store.object(forKey: mailCalendarKey) as? Bool ?? true }
        set { store.set(newValue, forKey: mailCalendarKey) }
    }

    static var linkTalkEnabled: Bool {
        get { store.object(forKey: linkTalkKey) as? Bool ?? true }
        set { store.set(newValue, forKey: linkTalkKey) }
    }

    /// Umschalten Mail & Kalender: Push-Zeile aller Accounts an-/abmelden.
    static func applyMailCalendar(_ enabled: Bool) {
        mailCalendarEnabled = enabled
        SouveraLog.write("PushToggles", "mail/calendar push -> \(enabled)")
        Task {
            for tbl in await NCManageDatabase.shared.getAllTableAccountAsync() {
                if enabled {
                    await NCPushNotification.shared.subscribingNextcloudServerPushNotification(account: tbl.account, urlBase: tbl.urlBase)
                } else {
                    await NCPushNotification.shared.unsubscribingNextcloudServerPushNotification(account: tbl.account, urlBase: tbl.urlBase)
                }
            }
        }
    }

    /// Umschalten Link/Talk: Talk-Gerätezeile + Proxy-Zeile abmelden bzw.
    /// neu registrieren.
    static func applyLinkTalk(_ enabled: Bool) {
        linkTalkEnabled = enabled
        SouveraLog.write("PushToggles", "link/talk push -> \(enabled)")
        if enabled {
            LinkVoIPManager.shared.refreshVoipRegistration()
        } else {
            Task {
                for tbl in await NCManageDatabase.shared.getAllTableAccountAsync() {
                    await LinkVoIPManager.unregisterVoipPush(baseUrl: tbl.urlBase, username: tbl.user)
                }
            }
        }
    }
}
