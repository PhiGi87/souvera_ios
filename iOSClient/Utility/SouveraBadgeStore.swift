// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation
import UserNotifications
import UIKit

/// Zentrale Quelle für ungelesene Zähler pro Account.
///
/// Hält Mail- und Link-Ungelesen getrennt pro Account und leitet daraus das
/// App-Icon-Badge ab. Das App-Icon-Badge zählt NUR ungelesene Mails (Summe
/// aller Accounts) und respektiert den iOS-Schalter "Badges" unter
/// Einstellungen > Mitteilungen (iOS unterdrückt das Badge nicht selbst -
/// die App muss `badgeSetting` prüfen).
@MainActor
final class SouveraBadgeStore: ObservableObject {
    static let shared = SouveraBadgeStore()

    @Published private(set) var mailUnread: [String: Int] = [:]
    @Published private(set) var linkUnread: [String: Int] = [:]

    private var observers: [NSObjectProtocol] = []
    /// Gecachter "Badges"-Schalter aus den iOS-Einstellungen. Wird beim Init
    /// einmal abgefragt und beim Setzen direkt angewendet (kein erneuter,
    /// asynchroner Roundtrip pro Badge-Update).
    private var badgesEnabled = true
    /// Debounce-Task: kurzzeitige 0↔28-Schwankungen beim Laden werden
    /// zusammengefasst, damit das App-Icon-Badge nicht flackert.
    private var badgeDebounceTask: Task<Void, Never>?

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .mailUnreadChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let account = info["account"] as? String,
                  let count = info["count"] as? Int else { return }
            Task { @MainActor in
                self?.setMailUnread(count, account: account)
            }
        })
        observers.append(center.addObserver(
            forName: .linkUnreadChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let count = notification.object as? Int ?? 0
            let account = (notification.userInfo?["account"] as? String) ?? ""
            Task { @MainActor in
                self?.setLinkUnread(count, account: account)
            }
        })
        refreshBadgeSetting()
    }

    private func refreshBadgeSetting() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let enabled = settings.badgeSetting == .enabled
            Task { @MainActor in
                guard let self else { return }
                self.badgesEnabled = enabled
                self.applyAppIconBadge()
            }
        }
    }

    func setMailUnread(_ count: Int, account: String) {
        guard !account.isEmpty else { return }
        mailUnread[account] = max(0, count)
        applyAppIconBadge()
    }

    func setLinkUnread(_ count: Int, account: String) {
        guard !account.isEmpty else { return }
        linkUnread[account] = max(0, count)
    }

    func unreadMail(account: String) -> Int {
        mailUnread[account] ?? 0
    }

    func unreadLink(account: String) -> Int {
        linkUnread[account] ?? 0
    }

    var totalMailUnread: Int {
        mailUnread.values.reduce(0, +)
    }

    /// Setzt das App-Icon-Badge (debounced). Zählt nur ungelesene Mails über
    /// ALLE Accounts und respektiert den "Badges"-Schalter.
    private func applyAppIconBadge() {
        badgeDebounceTask?.cancel()
        badgeDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            let total = self.totalMailUnread
            let value = self.badgesEnabled ? total : 0
            if #available(iOS 16.0, *) {
                try? await UNUserNotificationCenter.current().setBadgeCount(value)
            } else {
                UIApplication.shared.applicationIconBadgeNumber = value
            }
            SouveraLog.write("Badge", "app icon badge -> total=\(total) badgesEnabled=\(self.badgesEnabled) value=\(value)")
        }
    }

    /// Öffentlicher Einstieg (z. B. nach Erteilung der Notifications-
    /// Berechtigung), um den Schalter neu einzulesen und das Badge zu setzen.
    func refreshNow() {
        refreshBadgeSetting()
    }
}
