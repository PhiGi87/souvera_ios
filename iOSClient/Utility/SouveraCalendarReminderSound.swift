// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UserNotifications
import AVFAudio

/// Ton für Kalender-Erinnerungen (lokale Notifications).
/// Neben dem System-Standardton und "kein Ton" stehen vier selbst
/// SYNTHETISIERTE Chimes zur Auswahl - die System-UI-Sounds per Dateiname
/// griffen auf iOS 26 nicht zuverlässig. Die generierten WAVs liegen im
/// App-Container unter Library/Sounds (offiziell unterstützter Ort für
/// eigene Notification-Sounds).
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
    /// Eigene Töne werden bei Bedarf generiert (Library/Sounds).
    var sound: UNNotificationSound? {
        switch self {
        case .systemDefault: return .default
        case .none: return nil
        case .bell, .chime, .bowl, .wind:
            SouveraToneSynthesizer.ensureAllGenerated()
            guard let fileName = SouveraToneSynthesizer.fileName(for: self) else { return .default }
            return UNNotificationSound(named: UNNotificationSoundName(fileName))
        }
    }

    /// Probehören (Picker): spielt den Ton direkt ab.
    func previewPlay() {
        guard let url = SouveraToneSynthesizer.url(for: self),
              FileManager.default.fileExists(atPath: url.path) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        player?.play()
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

}
