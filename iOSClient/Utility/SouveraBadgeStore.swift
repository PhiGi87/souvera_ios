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
        // das Badge nur dann an. Die App setzt hier immer den Mail-Zähler.
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
    /// ALLE Accounts; `forceValue` überschreibt den Zähler (z. B. 0 beim
    /// frischen Install ohne Konto).
    private func applyAppIconBadge(forceValue: Int? = nil) {
        badgeDebounceTask?.cancel()
        badgeDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            let value = forceValue ?? self.totalMailUnread
            if #available(iOS 16.0, *) {
                try? await UNUserNotificationCenter.current().setBadgeCount(value)
            } else {
                UIApplication.shared.applicationIconBadgeNumber = value
            }
            SouveraLog.write("Badge", "app icon badge -> value=\(value)")
        }
    }

    /// Öffentlicher Einstieg (z. B. nach Erteilung der Notifications-
    /// Berechtigung), um den Schalter neu einzulesen und das Badge zu setzen.
    func refreshNow() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let accounts = await NCManageDatabase.shared.getAllTableAccountAsync()
            // Stale-Einträge entfernen: Konten, die nicht mehr in der DB
            // sind (abgemeldet/gelöscht), dürfen Badge und Mehr-Zähler
            // nicht weiter befüllen.
            let known = Set(accounts.map { $0.account })
            var pruned = false
            for key in Set(self.mailUnread.keys).union(self.linkUnread.keys) where !known.contains(key) {
                self.mailUnread.removeValue(forKey: key)
                self.linkUnread.removeValue(forKey: key)
                pruned = true
            }
            if pruned {
                self.postTotalsChanged()
            }
            if accounts.isEmpty || self.mailUnread.isEmpty {
                // Frische Installation / alle Konten abgemeldet / Kaltstart
                // vor dem ersten Sync: der vom OS übernommene Badge-Stand
                // (überlebt App-Updates!) muss auf 0 - sonst zeigt das Icon
                // den Stand des Vorgänger-Kontos (Feedback 05.09.). Der
                // Sync setzt sofort danach den echten Wert.
                self.applyAppIconBadge(forceValue: 0)
            } else {
                self.applyAppIconBadge()
            }
        }
    }

    /// Entfernt alle Zähler EINES Kontos (Abmelden/löschen) und
    /// aktualisiert Badge + Mehr-Zähler.
    func removeAccount(account: String) {
        guard !account.isEmpty else { return }
        mailUnread.removeValue(forKey: account)
        linkUnread.removeValue(forKey: account)
        applyAppIconBadge()
        postTotalsChanged()
    }
}
