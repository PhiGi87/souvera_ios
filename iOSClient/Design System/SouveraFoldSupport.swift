// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 23.10. (iPhone Duo): Reserved Regions (iOS 27.1).
// - Division-Regionen beschreiben die Falz. Schwebende Overlays werden in
//   eine Hälfte verschoben, statt über die Falz zu laufen.
// - Für zwei zusammengehörige Bereiche (Kalender: Monat + Terminliste)
//   nutzt die App ArrangementView, das die Aufteilung um die Falz herum
//   übernimmt.
//
// Alles ist availability-gated: auf älteren Systemen bleibt der bisherige
// Aufbau unverändert.

import SwiftUI

/// Zweispaltige Anordnung, die bei einer aktiven Falz (iOS 27.1+) auf
/// `ArrangementView` umschaltet und sonst den übergebenen Fallback zeigt.
struct SouveraDuoSplit<Fallback: View>: View {
    let primary: AnyView
    let secondary: AnyView
    let fallback: () -> Fallback

    var body: some View {
        if #available(iOS 27.1, *) {
            GeometryReader { proxy in
                let division = proxy.reservedRegions(kind: .division).first
                if let division, division.frame.height > division.frame.width {
                    ArrangementView {
                        primary
                    } secondary: {
                        secondary
                    }
                    .arrangementViewStyle(.split)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    fallback()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            fallback()
        }
    }
}

/// Begrenzt ein schwebendes Overlay auf die Hälfte neben/über der Falz.
/// Liefert die Begrenzung und den Versatz in der Overlay-Koordinatenachse.
struct SouveraDivisionConstraints: Equatable {
    var maxWidth: CGFloat?
    var maxHeight: CGFloat?
    var offsetX: CGFloat = 0

    static let none = SouveraDivisionConstraints()

    /// Liest die erste aktive Division-Region aus dem Proxy.
    @available(iOS 27.1, *)
    static func read(_ proxy: GeometryProxy) -> SouveraDivisionConstraints {
        guard let division = proxy.reservedRegions(kind: .division).first else {
            return .none
        }
        let frame = division.frame
        if frame.height > frame.width {
            // Vertikale Falz (Buch): Overlay in die hintere Hälfte.
            return SouveraDivisionConstraints(
                maxWidth: max(0, proxy.size.width - frame.maxX - 32),
                maxHeight: nil,
                offsetX: frame.maxX / 2
            )
        } else {
            // Horizontale Falz (Tent): Overlay in der oberen Hälfte halten.
            return SouveraDivisionConstraints(
                maxWidth: nil,
                maxHeight: max(0, frame.minY - 8),
                offsetX: 0
            )
        }
    }
}
