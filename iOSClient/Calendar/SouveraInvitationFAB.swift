// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Schwebender Einladungs-Button (Glas) mit Badge - sichtbar, solange
// offene Einladungen vorliegen. Platziert ueber der Tab-Bar unten rechts.
import SwiftUI

/// Run 16.09. (B10): Gemeinsamer Style fuer Einladungs-Buttons (FAB und
/// Inline-Button in der Mail) - transparentes Souvera-Blau unter dem
/// Glas-Effekt, Icon farbfest fuer Hell- und Dunkelmodus lesbar.
struct SouveraInvitationFABBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                Circle().fill(
                    LinearGradient(colors: SouveraAppearance.gradientColors,
                                   startPoint: .top, endPoint: .bottom)
                        .opacity(colorScheme == .dark ? 0.45 : 0.30)
                )
            )
            .modifier(SouveraHeaderGlass(shape: Circle()))
    }
}

struct SouveraInvitationFAB: View {
    @ObservedObject var center: SouveraInvitationCenter
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var iconColor: Color {
        // Dunkelblau auf hellem Glas, Weiss im Dunkelmodus - in beiden
        // Modi kontraststark auf dem blaeulichen Glas.
        colorScheme == .dark ? .white : Color(red: 0.05, green: 0.15, blue: 0.35)
    }

    var body: some View {
        if center.totalCount > 0 {
            Button(action: action) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 56, height: 56)
                        .modifier(SouveraInvitationFABBackground())
                    Text("\(min(center.totalCount, 99))")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 6, y: -4)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(NSLocalizedString("_invitations_title_", comment: "")))
        }
    }
}
