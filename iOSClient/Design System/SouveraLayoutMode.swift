// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 25.10.: EINE Layout-Wahrheit pro Szene/Tab. Trägt nur noch die
// Inhalts-Entscheidungen (Split ja/nein) - die Header kommen seit dem
// Header-Standard ausschließlich von der System-UINavigationBar.
//
// Der Modus wird vom Hosting-/Tab-NavigationController aus SEINEM
// traitCollection gespeist und per EnvironmentObject an die Module gereicht.

import SwiftUI
import UIKit
import Combine

/// Traegt den Layout-Modus eines Tabs/Fensters.
final class SouveraLayoutMode: ObservableObject {
    /// Regular width - Grundlage fuer Split-Layouts (iPad, Duo-Innendisplay).
    @Published private(set) var isRegularWidth: Bool
    /// In einen bestehenden NavigationController gepusht (Mehr-Menue):
    /// die aeussere Bar liefert Titel/Zurueck.
    let isPushed: Bool

    init(traitCollection: UITraitCollection, isPushed: Bool = false) {
        self.isPushed = isPushed
        self.isRegularWidth = traitCollection.horizontalSizeClass == .regular
    }

    /// Gepushte Module (Mehr-Menue): kein Split.
    static func pushed() -> SouveraLayoutMode {
        SouveraLayoutMode(
            traitCollection: UITraitCollection(traitsFrom: [
                UITraitCollection(horizontalSizeClass: .compact),
                UITraitCollection(userInterfaceIdiom: .phone)
            ]),
            isPushed: true
        )
    }

    /// Run 24.10.: Split nur auf echten Breiten. Das Außendisplay ist im
    /// Querformat (~678 pt) zu schmal fuer zwei Spalten.
    static let splitMinimumWidth: CGFloat = 720

    static func usesSplit(isRegularWidth: Bool, isLandscape: Bool, width: CGFloat) -> Bool {
        // Run 10.11.: Auch regular-Breite muss die echte Fensterbreite
        // gegen das Split-Minimum pruefen - im Splitscreen meldet die
        // Szene .regular, obwohl das Fenster schmal ist. width <= 0
        // (z. B. GeometryReader-Nullgroesse beim Start) liefert damit
        // korrekt false.
        if isRegularWidth && width >= splitMinimumWidth { return true }
        return isLandscape && width >= splitMinimumWidth
    }

    func update(traitCollection: UITraitCollection) {
        guard !isPushed else { return }
        let regular = traitCollection.horizontalSizeClass == .regular
        if regular != isRegularWidth {
            isRegularWidth = regular
        }
    }
}

/// Zugriff fuer UIKit-Klassen (Bar-Coordinator), ohne den konkreten
/// NavigationController-Typ zu kennen.
protocol SouveraLayoutModeProviding: AnyObject {
    var layoutMode: SouveraLayoutMode { get }
}
