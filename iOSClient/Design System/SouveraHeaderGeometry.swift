// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 25.10.: EINZIGE Wahrheit fuer Header-Hoehe und Button-Position in der
// gesamten App (Mail, Kalender, Link, Dateien, Mehr und alle Unterseiten).
//
// Bis hierhin baute jede Oberflaeche ihren Header selbst - SwiftUI-Module
// per safeAreaInset, UIKit-Bars ueber die Systemhoehe. Auf dem Duo liefert
// das System je nach Zustand 0/24/46/58/82/140 pt, wodurch Hoehe und
// Button-Reihe ueberall anders waren. Ab jetzt gilt ausschliesslich die
// Tabelle unten; keine Komponente darf Hoehe oder Position selbst ableiten.
//
// | Geraeteklasse                  | hoch | quer | Band oben | Reserve |
// |--------------------------------|------|------|-----------|---------|
// | iPhone kompakt                 |   58 |   58 | Status    |       0 |
// | Duo Aussendisplay 466x678      |   58 |   58 | 18 / 0    |     206 |
// | Duo Innendisplay 669x951       |   58 |   82 | 18 / 0    |     206 |
// | iPad regular                   |   58 |   82 | Status    |       0 |
// | iPad Split/Slide Over          |   58 |   58 | Status/0  |       0 |
// | iOS < 26                       |   46 |   70 | wie oben  | wie oben|
//
// "Band oben" ist die Oberkante des Bereichs, in dem die Header-Buttons
// vertikal zentriert sitzen. Auf dem Duo liegt die Bandmitte auf der Zeile
// der Status-Symbole (Uhr/Ring/WLAN) - hochkant 18..76, quer 0..82.

import UIKit

enum SouveraHeaderGeometry {

    struct Spec: Equatable {
        /// Hoehe des Header-Bands (Buttons vertikal zentriert).
        let height: CGFloat
        /// Oberkante des Bands in Fensterkoordinaten (0 = ganz oben).
        let bandTop: CGFloat
        /// Rechts freigehaltene Zone der Status-Kapsel.
        let trailingReserve: CGFloat
        let leadingInset: CGFloat = 12
        let trailingInset: CGFloat = 12
        /// Abstand zwischen Band-Unterkante und Inhalt.
        let contentGap: CGFloat = 12
    }

    /// Duo-Aussendisplay: 466 x 678 pt (Status-Kapsel ueberlagert oben,
    /// Window-Safe-Area oben ist praktisch 0).
    private static let outerShortSide: CGFloat = 466
    private static let outerLongSide: CGFloat = 678

    static func baseHeight(isLandscape: Bool, regularWidth: Bool) -> CGFloat {
        let wide = isLandscape && regularWidth
        if #available(iOS 26.0, *) {
            return wide ? 82 : 58
        }
        return wide ? 70 : 46
    }

    static func spec(windowSize: CGSize,
                     horizontalSizeClass: UIUserInterfaceSizeClass,
                     idiom: UIUserInterfaceIdiom,
                     safeAreaTop: CGFloat) -> Spec {
        let isLandscape = windowSize.width > windowSize.height
        let isPhone = idiom == .phone
        let short = min(windowSize.width, windowSize.height)
        let long = max(windowSize.width, windowSize.height)
        let isOuterDisplay = isPhone
            && horizontalSizeClass == .compact
            && safeAreaTop < 10
            && abs(short - outerShortSide) <= 24
            && abs(long - outerLongSide) <= 30
        let isInnerDisplay = isPhone && horizontalSizeClass == .regular

        if isInnerDisplay {
            return Spec(
                height: baseHeight(isLandscape: isLandscape, regularWidth: true),
                bandTop: isLandscape ? 0 : 18,
                trailingReserve: isLandscape ? 0 : 206
            )
        }
        if isOuterDisplay {
            return Spec(
                height: baseHeight(isLandscape: false, regularWidth: false),
                bandTop: isLandscape ? 0 : 18,
                trailingReserve: 206
            )
        }
        // iPhone / iPad: Band beginnt unter der System-Statusleiste.
        return Spec(
            height: baseHeight(isLandscape: isLandscape,
                               regularWidth: horizontalSizeClass == .regular),
            bandTop: max(0, safeAreaTop),
            trailingReserve: 0
        )
    }

    // MARK: - Zugriff auf die aktuelle Szene

    static var currentWindow: UIWindow? {
        // Wird ausschliesslich aus UI-Code aufgerufen; assumeIsolated haelt
        // die MainActor-Isolation von UIApplication.shared ein.
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
            return scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        }
    }

    static var currentSafeAreaTop: CGFloat {
        currentWindow?.safeAreaInsets.top ?? 0
    }

    static func currentSpec() -> Spec {
        let window = currentWindow
        let bounds = window?.bounds.size ?? UIScreen.main.bounds.size
        let traits = window?.traitCollection
        return spec(windowSize: bounds,
                    horizontalSizeClass: traits?.horizontalSizeClass ?? .compact,
                    idiom: traits?.userInterfaceIdiom ?? .phone,
                    safeAreaTop: window?.safeAreaInsets.top ?? 0)
    }
}
