/*
 SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
 SPDX-License-Identifier: GPL-2.0-or-later
*/

import SwiftUI
import Network

/// Zentrale Online/Offline-Quelle (App-weit EIN NWPathMonitor): die
/// Modul-Roots (Link, Mail, Kalender) zeigen daraus den dezenten
/// Offline-Banner - das orange NextcloudKit-Warnpopup ist damit ersetzt
/// (Run-Feedback 11.09.).
@MainActor
final class SouveraNetworkStatus: ObservableObject {
    static let shared = SouveraNetworkStatus()

    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "souvera.network.status"))
    }
}

/// Dezenter Offline-Hinweis (eine Zeile, Material-Hintergrund): gleiche
/// Optik/Textbasis in Mail, Kalender und Link statt der harten Warnung.
struct SouveraOfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("_mail_offline_", comment: ""))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }
}

extension View {
    /// Blendet den Offline-Banner am oberen Rand ein, solange kein Netz
    /// vorhanden ist (einheitlich in Mail, Kalender, Link).
    func souveraOfflineBanner() -> some View {
        @ObservedObject var status = SouveraNetworkStatus.shared
        return self
            .safeAreaInset(edge: .top, spacing: 0) {
                if !status.isOnline {
                    SouveraOfflineBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: status.isOnline)
    }
}
