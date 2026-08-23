// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pollt die Talk-Konversationsliste im Hintergrund und meldet die Summe
/// ungelesener Nachrichten als `.linkUnreadChanged` (Tab-Badge am Link-Button).
/// Startet unabhängig vom sichtbaren Tab; bei fehlendem Konto läuft der Tick
/// leer weiter.
@MainActor
final class LinkBadgeMonitor {
    static let shared = LinkBadgeMonitor()

    private var task: Task<Void, Never>?
    private let pollInterval: UInt64 = 30_000_000_000

    private init() {}

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: self?.pollInterval ?? 30_000_000_000)
            }
        }
    }

    private func tick() async {
        guard let account = LinkAccount.active() else { return }
        let api = LinkOcsApi(account: account)
        guard let list = await api.listConversations() else { return }
        guard !Task.isCancelled else { return }
        LinkViewModel.postUnreadTotal(list)
    }
}
