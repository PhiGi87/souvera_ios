// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import NextcloudKit

/// Per-Account-Push-Toggles (P70/Multi-Account). Standard ist "an": Solange
/// der Nutzer nichts ändert, bleibt das Push-Verhalten wie bisher.
///
/// - Mail & Kalender: NC-Normal-Push-Zeile (Mail läuft über die NC-Kette,
///   Kalender-Erinnerungen sind lokal - der Toggle unterdrückt die
///   Mail-Push-Verarbeitung UND das lokale Zustellen).
/// - Link/Talk: Talk/VoIP-Kanal (eigene Gerätezeile + Proxy).
///
/// Jeder Account kann seine Toggles unabhängig setzen.
enum SouveraPushToggles {

    static let mailCalendarKey = "souvera_push_mail_calendar_enabled_"
    static let linkTalkKey = "souvera_push_link_talk_enabled_"

    /// Ablage in der App-Gruppe, damit auch die Notification Service
    /// Extension den Filter liest (Übergangs-Pushes unterdrücken).
    static var store: UserDefaults {
        UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup) ?? .standard
    }

    static func mailCalendarEnabled(account: String) -> Bool {
        store.object(forKey: mailCalendarKey + account) as? Bool ?? true
    }

    static func linkTalkEnabled(account: String) -> Bool {
        store.object(forKey: linkTalkKey + account) as? Bool ?? true
    }

    static func setMailCalendar(_ enabled: Bool, account: String) {
        store.set(enabled, forKey: mailCalendarKey + account)
    }

    static func setLinkTalk(_ enabled: Bool, account: String) {
        store.set(enabled, forKey: linkTalkKey + account)
    }

    /// Umschalten Mail & Kalender für EINEN Account.
    static func applyMailCalendar(_ enabled: Bool, account: String) {
        setMailCalendar(enabled, account: account)
        SouveraLog.write("PushToggles", "mail/calendar push -> \(enabled) account=\(account)")
        Task {
            guard let tbl = await NCManageDatabase.shared.getTableAccountAsync(predicate: NSPredicate(format: "account == %@", account)) else { return }
            if enabled {
                await NCPushNotification.shared.subscribingNextcloudServerPushNotification(account: tbl.account, urlBase: tbl.urlBase)
            } else {
                await NCPushNotification.shared.unsubscribingNextcloudServerPushNotification(account: tbl.account, urlBase: tbl.urlBase)
            }
        }
    }

    /// Umschalten Link/Talk für EINEN Account.
    static func applyLinkTalk(_ enabled: Bool, account: String) {
        setLinkTalk(enabled, account: account)
        SouveraLog.write("PushToggles", "link/talk push -> \(enabled) account=\(account)")
        if enabled {
            LinkVoIPManager.shared.refreshVoipRegistration()
        } else {
            Task {
                guard let tbl = await NCManageDatabase.shared.getTableAccountAsync(predicate: NSPredicate(format: "account == %@", account)) else { return }
                await LinkVoIPManager.unregisterVoipPush(baseUrl: tbl.urlBase, username: tbl.user, account: account)
            }
        }
    }
}
