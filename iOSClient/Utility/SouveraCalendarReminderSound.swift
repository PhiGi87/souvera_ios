// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UserNotifications

/// Ton für Kalender-Erinnerungen (lokale Notifications).
/// Neben dem System-Standardton und "kein Ton" stehen ausgewählte
/// iOS-System-UI-Sounds zur Auswahl (Referenz per Dateiname - bei
/// unbekanntem Namen fällt iOS automatisch auf den Standardton zurück).
enum SouveraCalendarReminderSound: String, CaseIterable, Identifiable {
    case systemDefault
    case bell
    case chime
    case bowl
    case wind
    case none

    var id: String { rawValue }

    private static let defaultsKey = "souvera_calendar_reminder_sound"

    static var stored: SouveraCalendarReminderSound {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let sound = SouveraCalendarReminderSound(rawValue: raw) else { return .systemDefault }
            return sound
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// UNNotificationSound für die Erinnerungen (nil = kein Ton).
    var sound: UNNotificationSound? {
        switch self {
        case .systemDefault: return .default
        case .none: return nil
        case .bell: return Self.named("calendar-alert.caf")
        case .chime: return Self.named("new-mail.caf")
        case .bowl: return Self.named("sms-received1.caf")
        case .wind: return Self.named("mail-sent.caf")
        }
    }

    var titleKey: String {
        switch self {
        case .systemDefault: return "_cal_sound_default_"
        case .bell: return "_cal_sound_bell_"
        case .chime: return "_cal_sound_chime_"
        case .bowl: return "_cal_sound_bowl_"
        case .wind: return "_cal_sound_wind_"
        case .none: return "_cal_sound_none_"
        }
    }

    private static func named(_ name: String) -> UNNotificationSound? {
        UNNotificationSound(named: UNNotificationSoundName(name))
    }
}
