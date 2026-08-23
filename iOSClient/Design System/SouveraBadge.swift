// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Compact status / count pill used for unread counts, states and metadata.
struct SouveraBadge: View {

    enum Style {
        case neutral
        case brand
        case success
        case warning
        case error
    }

    var text: String
    var style: Style = .neutral

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, SouveraTokens.Spacing.xs)
            .padding(.vertical, SouveraTokens.Spacing.xxs)
            .background(background, in: Capsule())
            .accessibilityLabel(text)
    }

    private var foregroundStyle: Color {
        switch style {
        case .neutral: return Color.secondary
        case .brand: return Color.Souvera.brandPrimaryDeep
        case .success: return Color.green
        case .warning: return Color.orange
        case .error: return Color.red
        }
    }

    private var background: Color {
        switch style {
        case .neutral: return Color.secondary.opacity(0.15)
        case .brand: return Color.Souvera.brandSurface
        case .success: return Color.green.opacity(0.15)
        case .warning: return Color.orange.opacity(0.15)
        case .error: return Color.red.opacity(0.15)
        }
    }
}
