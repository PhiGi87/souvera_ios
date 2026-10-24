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

    /// Run 24.10.: Zusaetzlicher Abstand, wenn die Statusleiste den
    /// Header ueberlappt (Fenster ohne Safe-Area-Top). Wird gemessen,
    /// nicht geraten.
    @Published private(set) var headerExtraTop: CGFloat = 0
    @Published private(set) var headerExtraTrailing: CGFloat = 0

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

    /// Aktualisiert den Header-Zusatzabstand aus dem echten Fenster.
    func updateHeaderFit(window: UIWindow?) {
        let safeTop = window?.safeAreaInsets.top ?? 0
        let statusBottom = SouveraHeaderFit.statusBarBottom(in: window)
        let top = SouveraHeaderFit.extraTopPadding(statusBarBottom: statusBottom,
                                                  safeAreaTop: safeTop)
        if abs(top - headerExtraTop) > 0.5 {
            headerExtraTop = top
        }
        let trailing = SouveraHeaderFit.extraTrailingInset(window: window)
        if abs(trailing - headerExtraTrailing) > 0.5 {
            headerExtraTrailing = trailing
        }
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

/// Run 24.10.: Messwerte fuer den Header (Statusleiste vs. Safe Area).
enum SouveraHeaderFit {
    /// Reine Rechnung (unit-testbar): fehlender Abstand nach oben.
    static func extraTopPadding(statusBarBottom: CGFloat?, safeAreaTop: CGFloat) -> CGFloat {
        guard let bottom = statusBarBottom else { return 0 }
        return min(32, max(0, bottom - safeAreaTop))
    }

    /// Unterkante der Statusleiste in Fensterkoordinaten (nil, wenn keine).
    static func statusBarBottom(in window: UIWindow?) -> CGFloat? {
        guard let window,
              let scene = window.windowScene,
              let manager = scene.statusBarManager else { return nil }
        let frame = manager.statusBarFrame
        guard !frame.isEmpty else { return nil }
        let screen = window.screen
        let inWindow = window.convert(frame, from: screen.coordinateSpace)
        guard inWindow.intersects(window.bounds), inWindow.maxY > 0 else { return nil }
        return inWindow.maxY
    }

    /// Breite der Statusleiste, wenn sie den rechten Headerrand ueberlappt.
    static func extraTrailingInset(window: UIWindow?) -> CGFloat {
        guard let window,
              window.safeAreaInsets.top < 1,
              let scene = window.windowScene,
              let manager = scene.statusBarManager else { return 0 }
        let frame = manager.statusBarFrame
        guard !frame.isEmpty else { return 0 }
        let screen = window.screen
        let inWindow = window.convert(frame, from: screen.coordinateSpace)
        guard inWindow.intersects(window.bounds) else { return 0 }
        // Nur wenn die Leiste im oberen Bereich liegt (Statusleiste), nicht
        // bei einem beliebigen Systemelement.
        guard inWindow.minY < 60 else { return 0 }
        return min(120, max(0, inWindow.width) + 8)
    }
}
