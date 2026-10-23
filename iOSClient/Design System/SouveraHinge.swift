// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 07.10. (iPhone Duo): Hinge-Beobachtung für den Tent-Modus.
// iOS 27.1 führt `onHingeChange` ein (Status geschlossen/teilgefaltet/offen
// plus kontinuierlicher Winkel). Die App nutzt das nur als Layout-Hinweis
// (teilgefaltet = Inhalte oben, Bedienung unten) - auf älteren Systemen
// bleibt alles unverändert.

import SwiftUI

/// Beobachtet, ob das Gerät teilgefaltet (Tent) ist. Auf Systemen ohne
/// Hinge (alle bisherigen iPhones/iPads) bleibt der Wert `false`.
struct SouveraHingeTracking: ViewModifier {
    let onChange: (Bool) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                let partiallyFolded = context.hinge?.status == .partiallyOpen
                onChange(partiallyFolded)
            }
        } else {
            content
        }
    }
}

extension View {
    /// Meldet Änderungen des Tent-/Falt-Zustands (nur iPhone Duo, iOS 27+).
    func souveraHingeTracking(_ onChange: @escaping (Bool) -> Void) -> some View {
        modifier(SouveraHingeTracking(onChange: onChange))
    }
}
