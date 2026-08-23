// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Souvera button styles: primary (filled), secondary (bordered) and tertiary
/// (plain). One consistent style per semantic role across the whole workspace.
struct SouveraButtonStyle: ButtonStyle {

    enum Kind {
        case primary
        case secondary
        case tertiary
    }

    var kind: Kind = .primary
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(minHeight: SouveraTokens.Metrics.primaryButtonHeight)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, SouveraTokens.Spacing.lg)
            .background(background)
            .foregroundStyle(foregroundStyle)
            .clipShape(RoundedRectangle(cornerRadius: SouveraTokens.Radius.medium, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: SouveraTokens.Radius.medium, style: .continuous)
                        .strokeBorder(Color.Souvera.brandPrimary, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var background: Color {
        switch kind {
        case .primary: return Color.Souvera.brandPrimaryDeep
        case .secondary: return Color.Souvera.brandSurface
        case .tertiary: return Color.clear
        }
    }

    private var foregroundStyle: Color {
        switch kind {
        case .primary: return Color.Souvera.brandOnPrimary
        case .secondary: return Color.Souvera.brandPrimaryDeep
        case .tertiary: return Color.Souvera.brandPrimaryDeep
        }
    }
}
