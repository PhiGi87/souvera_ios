// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pollt die Talk-Konversationsliste im Vordergrund und hält Badge UND
/// Übersicht aktuell (loadConversations über Refresh-Notification).
/// Läuft unabhängig von der "Hintergrundaktualisierung"-Einstellung mit
/// einem eigenen Standardintervall - sonst stehen Badge und Liste still,
/// solange der Nutzer im Modul bleibt (Feedback 05.09.).
@MainActor
final class LinkBadgeMonitor {
    static let shared = LinkBadgeMonitor()

    private var task: Task<Void, Never>?
    private let baseInterval: UInt64 = 20_000_000_000

    private init() {}

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let seconds = SouveraAutoRefresh.interval ?? 0
                let nanos = seconds > 0
                    ? UInt64(seconds) * 1_000_000_000
                    : (self?.baseInterval ?? 20_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    private func tick() async {
        guard let account = LinkAccount.active() else {
            // Stiller Leerlauf sichtbar machen (iPad/Mac-Blindflug, Feedback
            // 05.09.): ohne Diagnose war ein scheiternder Poll unsichtbar.
            CallDebugLog.log("LinkBadgeMonitor", "tick skipped: no active account")
            return
        }
        let api = LinkOcsApi(account: account)
        guard let list = await api.listConversations() else {
            CallDebugLog.log("LinkBadgeMonitor", "tick failed (server) account=\(account.account)")
            return
        }
        guard !Task.isCancelled else { return }
        CallDebugLog.log("LinkBadgeMonitor", "tick ok account=\(account.account) rooms=\(list.count) unread=\(list.reduce(0) { $0 + $1.unreadMessages })")
        // Badge SOFORT (funktioniert auch, wenn das Link-Modul noch nie
        // geöffnet wurde - der ViewModel-Observer ist dann nicht registriert).
        LinkViewModel.postUnreadTotal(list, account: account.account)
        // Liste dem ViewModel anbieten (ohne zweiten Netz-Fetch übernehmen).
        NotificationCenter.default.post(
            name: .linkConversationsRefreshRequested,
            object: list,
            userInfo: ["account": account.account]
        )
    }
}
