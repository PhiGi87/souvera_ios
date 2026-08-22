// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Version / build / git-commit information shown in the UI so testers can
/// always tell which build they are running.
///
/// The git commit is injected by the CI build via
/// `INFOPLIST_KEY_SouveraGitCommit=$(git rev-parse --short HEAD)`.
struct SouveraBuildInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    static var gitCommit: String {
        Bundle.main.object(forInfoDictionaryKey: "SouveraGitCommit") as? String ?? ""
    }

    /// e.g. "Souvera 33.1.0 (Build 14) · 5538b1d"
    static var label: String {
        var parts = ["Souvera \(version) (Build \(buildNumber))"]
        if !gitCommit.isEmpty {
            parts.append(gitCommit)
        }
        return parts.joined(separator: " · ")
    }
}

/// In-App-Sprachwahl (System/Deutsch/English/Español/Français/Nederlands).
enum SouveraLanguage {
    static let defaultsKey = "AppleLanguages"
    static let supportedCodes = ["de", "en", "es", "fr", "nl"]

    static var currentCode: String {
        let languages = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        if let first = languages.first, supportedCodes.contains(first) {
            return first
        }
        return "system"
    }

    static func set(_ code: String) {
        if code == "system" {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set([code], forKey: defaultsKey)
        }
    }
}

/// Background refresh interval setting: while the app is active, the mail and
/// calendar modules re-sync automatically; the same interval is used as an
/// advisory value for BGAppRefresh. Werte in Sekunden; 0 = aus.
enum SouveraAutoRefresh {
    static let defaultsKey = "souvera_auto_refresh_seconds"
    static let legacyMinutesKey = "souvera_auto_refresh_minutes"
    /// Aus, 30 Sekunden, 2, 5 und 15 Minuten.
    static let presets: [Int] = [0, 30, 120, 300, 900]

    static var intervalSeconds: Int {
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            return UserDefaults.standard.integer(forKey: defaultsKey)
        }
        // Migration vom früheren Minuten-Wert.
        let legacy = UserDefaults.standard.integer(forKey: legacyMinutesKey)
        if legacy > 0 {
            let seconds = legacy * 60
            UserDefaults.standard.set(seconds, forKey: defaultsKey)
            UserDefaults.standard.removeObject(forKey: legacyMinutesKey)
            return seconds
        }
        // Standard: 5 Minuten.
        return 300
    }

    static var interval: TimeInterval? {
        let seconds = intervalSeconds
        return seconds > 0 ? TimeInterval(seconds) : nil
    }

    static func set(seconds: Int) {
        UserDefaults.standard.set(seconds, forKey: defaultsKey)
    }

    static func label(for seconds: Int) -> String {
        if seconds <= 0 {
            return NSLocalizedString("_settings_auto_refresh_off_", comment: "")
        }
        if seconds < 60 {
            return String(format: NSLocalizedString("_settings_auto_refresh_seconds_", comment: ""), seconds)
        }
        return String(format: NSLocalizedString("_settings_auto_refresh_minutes_", comment: ""), seconds / 60)
    }
}

/// Builds the combined "normal voip" push token string understood by the
/// Nextcloud push proxy (both halves separated by a single space).
enum SouveraPushRegistrar {
    static func combinedToken(normal: String, voip: String) -> String {
        let parts = [normal, voip].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }
}
