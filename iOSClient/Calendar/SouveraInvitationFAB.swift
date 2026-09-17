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
                // Run 19.09. (Feedback): leichtes ORANGE statt blau - der
                // pulsierende Button hebt sich so klar ab.
                Circle().fill(Color.orange.opacity(colorScheme == .dark ? 0.55 : 0.40))
            )
            .modifier(SouveraHeaderGlass(shape: Circle()))
    }
}

struct SouveraInvitationFAB: View {
    @ObservedObject var center: SouveraInvitationCenter
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var iconColor: Color {
        // Run 19.09.: Weiss auf dem orangen Glas - kontraststark in
        // Hell- und Dunkelmodus.
        Color.white
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
                        // Run 19.09. (Feedback): auch der Kalender-FAB
                        // pulsiert sichtbar.
                        .modifier(SouveraPulseEffect())
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

/// Puls-Effekt (sanfter Scale-Loop) für den Einladungs-Button in der Mail.
struct SouveraPulseEffect: ViewModifier {
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        Group {
            if reduceMotion {
                content
            } else {
                content
                    .scaleEffect(pulsing ? 1.08 : 1.0)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
                    .onAppear { pulsing = true }
            }
        }
    }
}
