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
        // Kein badgeSetting-Gate mehr: iOS respektiert den "Badges"-Schalter
        // des Nutzers (Einstellungen > Mitteilungen) bereits selbst und zeigt
        // das Badge nur dann an. Die App setzt hier immer den Mail-Zähler;
        // bei leerem Store wird bewusst NICHT auf 0 gesetzt (kein Flackern
        // beim App-Start, bevor die Mail gezählt hat).
        if !self.mailUnread.isEmpty {
            self.applyAppIconBadge()
        }
    }

    func setMailUnread(_ count: Int, account: String) {
        guard !account.isEmpty else { return }
        mailUnread[account] = max(0, count)
        applyAppIconBadge()
        postTotalsChanged()
    }

    func setLinkUnread(_ count: Int, account: String) {
        guard !account.isEmpty else { return }
        linkUnread[account] = max(0, count)
        postTotalsChanged()
    }

    private func postTotalsChanged() {
        NotificationCenter.default.post(name: .souveraBadgeTotalsChanged, object: nil)
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

    /// Summe aus Mail + Link über alle Accounts AUSSER dem übergebenen
    /// (für den Mehr-Tab-Badge: der aktive Account wird nicht mitgezählt).
    func unreadExcluding(account: String) -> Int {
        let mail = mailUnread.filter { $0.key != account }.values.reduce(0, +)
        let link = linkUnread.filter { $0.key != account }.values.reduce(0, +)
        return mail + link
    }

    /// Setzt das App-Icon-Badge (debounced). Zählt nur ungelesene Mails über
    /// ALLE Accounts.
    private func applyAppIconBadge() {
        badgeDebounceTask?.cancel()
        badgeDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            let value = self.totalMailUnread
            if #available(iOS 16.0, *) {
                try? await UNUserNotificationCenter.current().setBadgeCount(value)
            } else {
                UIApplication.shared.applicationIconBadgeNumber = value
            }
            SouveraLog.write("Badge", "app icon badge -> total=\(value) value=\(value)")
        }
    }

    /// Öffentlicher Einstieg (z. B. nach Erteilung der Notifications-
    /// Berechtigung), um den Schalter neu einzulesen und das Badge zu setzen.
    func refreshNow() {
        refreshBadgeSetting()
    }
}
