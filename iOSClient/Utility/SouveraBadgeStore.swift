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
            let account = (notification.userInfo?["account"] as? String)
                ?? LinkAccount.active()?.account
                ?? ""
            Task { @MainActor in
                self?.setLinkUnread(count, account: account)
            }
        })
    }

    func setMailUnread(_ count: Int, account: String) {
        guard !account.isEmpty else { return }
        mailUnread[account] = max(0, count)
        updateAppIconBadge()
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

    /// Aktualisiert das App-Icon-Badge. Respektiert den iOS-Schalter "Badges".
    func updateAppIconBadge() {
        let total = totalMailUnread
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let enabled = settings.badgeSetting == .enabled
            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber = enabled ? total : 0
            }
        }
    }
}
