// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Schwebender Einladungs-Button (Glas) mit Badge - sichtbar, solange
// offene Einladungen vorliegen. Platziert ueber der Tab-Bar unten rechts.
import SwiftUI

struct SouveraInvitationFAB: View {
    @ObservedObject var center: SouveraInvitationCenter
    let action: () -> Void

    var body: some View {
        if center.totalCount > 0 {
            Button(action: action) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color(red: 0.1, green: 0.1, blue: 0.1))
                        .frame(width: 56, height: 56)
                        .modifier(SouveraHeaderGlass(shape: Circle()))
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
