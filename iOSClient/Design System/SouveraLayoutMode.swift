// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 23.10. (Feedback: Header je nach Start-Orientierung/Fenster anders):
// EINE Layout-Wahrheit pro Szene. Frueher entschied die UIKit-Bar einmalig
// beim Aufbau (makeHostedTab) und die SwiftUI-Module bei jedem Body erneut
// ueber UITraitCollection.current bzw. die erste aktive Szene - bei zwei
// Fenstern und beim Wechsel von Hoch-/Querformat kamen dadurch Glas-Header
// UND Bridge-Bar gleichzeitig (oder unterschiedliche Buttons).
//
// Der Modus wird jetzt vom Hosting-NavigationController aus SEINEM
// traitCollection gespeist und per EnvironmentObject an die Module gereicht.

import SwiftUI
import UIKit
import Combine

/// Traegt den Layout-Modus eines Tabs/Fensters. Wird vom Hosting-
/// NavigationController aktualisiert (Trait-Wechsel) und von den
/// SwiftUI-Modulen beobachtet.
final class SouveraLayoutMode: ObservableObject {
    /// Sichtbare blaue UIKit-Bar + Bridge-Items (iPad, Duo-Innendisplay).
    @Published private(set) var usesBridgeHeader: Bool
    /// Regular width - Grundlage fuer Split-Layouts.
    @Published private(set) var isRegularWidth: Bool
    /// In einen bestehenden NavigationController gepusht (Mehr-Menue):
    /// die aeussere Bar liefert Titel/Zurueck, das Modul rendert keinen
    /// eigenen Header.
    let isPushed: Bool

    init(traitCollection: UITraitCollection, isPushed: Bool = false) {
        self.isPushed = isPushed
        let regular = traitCollection.horizontalSizeClass == .regular
        let pad = traitCollection.userInterfaceIdiom == .pad
        self.isRegularWidth = regular
        self.usesBridgeHeader = !isPushed && (pad || regular)
    }

    /// Gepushte Module (Mehr-Menue): kein eigener Header, kein Split.
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
        if isRegularWidth { return true }
        return isLandscape && width >= splitMinimumWidth
    }

    func update(traitCollection: UITraitCollection) {
        guard !isPushed else { return }
        let regular = traitCollection.horizontalSizeClass == .regular
        let pad = traitCollection.userInterfaceIdiom == .pad
        let bridge = pad || regular
        if bridge != usesBridgeHeader {
            usesBridgeHeader = bridge
        }
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
