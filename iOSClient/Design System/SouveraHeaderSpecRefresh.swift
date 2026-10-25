// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 25.10. (4b): Zentraler Spec-Refresh fuer die SwiftUI-Modul-Header.
// Mail, Kalender, Link und Mehr cachen den Header-Spec (@State); der
// Modifier liefert den gemeinsamen Aktualisierungs-Pfad fuer Kontext-
// Wechsel, die die Fenster-Groesse NICHT aendern (Duo Auf-/Zuklappen
// flippt die Size Class, Split-/Slide-Over ebenso). Groessenaenderungen
// decken die Views bereits ueber ihre Geometrie-Beobachtung ab.

import SwiftUI

struct SouveraHeaderSpecRefresh: ViewModifier {
    let refresh: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content
            .onChange(of: horizontalSizeClass) { _, _ in
                refresh()
            }
    }
}

extension View {
    /// Ruft `refresh` auf, wenn sich der Layout-Kontext des Headers
    /// aendert (Size Class: Duo faltbar, iPad Split/Slide Over).
    func souveraHeaderSpecRefresh(_ refresh: @escaping () -> Void) -> some View {
        modifier(SouveraHeaderSpecRefresh(refresh: refresh))
    }
}
