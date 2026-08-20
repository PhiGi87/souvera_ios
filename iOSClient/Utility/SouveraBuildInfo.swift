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
