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

/// Background refresh interval setting: while the app is active, the mail and
/// calendar modules re-sync automatically; the same interval is used as an
/// advisory value for BGAppRefresh. 0 = off.
enum SouveraAutoRefresh {
    static let defaultsKey = "souvera_auto_refresh_minutes"
    static let presets: [Int] = [0, 15, 30, 60]

    static var intervalMinutes: Int {
        UserDefaults.standard.integer(forKey: defaultsKey)
    }

    static var interval: TimeInterval? {
        let minutes = intervalMinutes
        return minutes > 0 ? TimeInterval(minutes * 60) : nil
    }

    static func set(minutes: Int) {
        UserDefaults.standard.set(minutes, forKey: defaultsKey)
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
