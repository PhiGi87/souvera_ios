// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Temporärer Hinweis, dass der aktuelle Stand aus dem lokalen Cache stammt
/// (Server-Fehler). Identisch in Mail, Kalender und Link: Warndreieck +
/// Text, Material-Kapsel, unten eingeblendet.
struct SouveraCacheBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(NSLocalizedString("_cache_active_", comment: ""))
                .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.orange.opacity(0.35), lineWidth: 1))
        .shadow(radius: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
