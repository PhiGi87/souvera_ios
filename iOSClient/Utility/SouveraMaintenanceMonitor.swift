// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NextcloudKit

extension Notification.Name {
    /// Posted with the maintenance state (Bool) whenever it changes.
    static let maintenanceChanged = Notification.Name("SouveraMaintenanceChanged")
}

/// Prüft periodisch, ob die Souvera/Nextcloud-Instanz im Wartungsmodus ist
/// (`status.php` über NextcloudKit). Bei Wartung zeigt die Oberfläche einen
/// Info-Punkt am Mehr-Tab und eine Hinweiszeile im Mehr-Menü; die Module
/// arbeiten in der Zeit mit ihrem lokalen Cache weiter.
@MainActor
final class SouveraMaintenanceMonitor: ObservableObject {
    static let shared = SouveraMaintenanceMonitor()

    @Published private(set) var isMaintenance = false

    private var task: Task<Void, Never>?
    private let pollInterval: UInt64 = 60_000_000_000

    private init() {}

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.check()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.pollInterval ?? 60_000_000_000)
                await self?.check()
            }
        }
    }

    func checkNow() async {
        await check()
    }

    private func check() async {
        guard let account = NCManageDatabase.shared.getActiveTableAccount() else { return }
        let result = await NextcloudKit.shared.getServerStatusAsync(serverUrl: account.urlBase) { _ in }
        switch result.result {
        case .success(let serverInfo):
            let maintenance = serverInfo.maintenance
            if maintenance != isMaintenance {
                isMaintenance = maintenance
                NotificationCenter.default.post(name: .maintenanceChanged, object: maintenance)
            }
        case .failure:
            // Netzwerkfehler ist keine Wartung - Zustand unverändert lassen.
            break
        }
    }
}
