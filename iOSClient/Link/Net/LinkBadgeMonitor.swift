// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pollt die Talk-Konversationsliste im Hintergrund und meldet die Summe
/// ungelesener Nachrichten als `.linkUnreadChanged` (Tab-Badge am Link-Button).
/// Das Intervall stammt aus der globalen Hintergrundaktualisierungs-Einstellung
/// (0 = deaktiviert); läuft unabhängig vom sichtbaren Tab.
@MainActor
final class LinkBadgeMonitor {
    static let shared = LinkBadgeMonitor()

    private var task: Task<Void, Never>?
    private let baseInterval: UInt64 = 5_000_000_000

    private init() {}

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let seconds = SouveraAutoRefresh.interval ?? 0
                let nanos = seconds > 0
                    ? UInt64(seconds) * 1_000_000_000
                    : (self?.baseInterval ?? 5_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    private func tick() async {
        // Hintergrundaktualisierung deaktiviert: kein Poll.
        guard (SouveraAutoRefresh.interval ?? 0) > 0 else { return }
        guard let account = LinkAccount.active() else { return }
        let api = LinkOcsApi(account: account)
        guard let list = await api.listConversations() else { return }
        guard !Task.isCancelled else { return }
        LinkViewModel.postUnreadTotal(list)
    }
}
