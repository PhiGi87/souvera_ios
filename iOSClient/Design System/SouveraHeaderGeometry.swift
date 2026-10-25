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
// Run 25.10. (Apple-konform, iOS 27.1): Die Duo-Werte sind jetzt NUR noch
// Fallback. Auf iOS 27.1+ leitet die Spec Band-Position und Reserve aus den
// vom System gemeldeten Occlusion-Regionen (Kamera/Status-Kapsel) ab -
// nicht mehr aus Hartcodierten Pixelmassen (HIG: Layout aus Size Classes
// und Regionen ableiten, nicht aus Geraetedimensionen). Ohne Regionsdaten
// (iOS < 27.1, Simulator, Extensions) greift die Tabelle unverändert.
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

    /// Aktive Occlusion-Region (Kamera/Status-Kapsel) in Fensterkoordinaten.
    /// Der Frame enthaelt die System-Margins bereits (Apple-Vorgabe) - es
    /// darf kein zusaetzlicher Abstand addiert werden.
    struct Occlusion: Equatable {
        let frame: CGRect
    }

    // Fallback-Tabelle fuer die Duo-Klassen (iOS < 27.1 / ohne Regionen).
    private static let duoFallbackBandTop: CGFloat = 18
    private static let duoFallbackReserve: CGFloat = 206

    static func baseHeight(isLandscape: Bool, regularWidth: Bool) -> CGFloat {
        let wide = isLandscape && regularWidth
        if #available(iOS 26.0, *) {
            return wide ? 82 : 58
        }
        return wide ? 70 : 46
    }

    /// Rueckwartskompatible Variante ohne Regionsdaten (Fallback-Tabelle).
    static func spec(windowSize: CGSize,
                     horizontalSizeClass: UIUserInterfaceSizeClass,
                     idiom: UIUserInterfaceIdiom,
                     safeAreaTop: CGFloat) -> Spec {
        spec(windowSize: windowSize,
             horizontalSizeClass: horizontalSizeClass,
             idiom: idiom,
             safeAreaInsets: UIEdgeInsets(top: max(0, safeAreaTop), left: 0, bottom: 0, right: 0),
             occlusions: [])
    }

    /// Reine, unit-testbare Ableitung. `occlusions` sind aktive
    /// Occlusion-Regionen in Fensterkoordinaten (leer = Fallback-Tabelle).
    static func spec(windowSize: CGSize,
                     horizontalSizeClass: UIUserInterfaceSizeClass,
                     idiom: UIUserInterfaceIdiom,
                     safeAreaInsets: UIEdgeInsets,
                     occlusions: [Occlusion]) -> Spec {
        let isLandscape = windowSize.width > windowSize.height
        let isPhone = idiom == .phone
        let safeAreaTop = max(0, safeAreaInsets.top)
        let isInnerDisplay = isPhone && horizontalSizeClass == .regular
        // Duo-Aussendisplay: kompakt, die Kapsel overlayt das Fenster
        // (Safe Area rundum ~0) und das System meldet eine aktive
        // Occlusion. Bewusst NICHT ueber Pixelmasse erkannt (HIG:
        // Size Classes statt Geraetetyp); ein kompakter iPhone-Querformat-
        // Fall scheidet ueber die seitlichen Safe-Area-Insets aus.
        let isOuterDisplay = isPhone
            && horizontalSizeClass == .compact
            && safeAreaTop < 10
            && safeAreaInsets.left < 10
            && safeAreaInsets.right < 10
            && !occlusions.isEmpty

        if isInnerDisplay {
            let fallbackTop: CGFloat = isLandscape ? 0 : duoFallbackBandTop
            let fallbackReserve: CGFloat = isLandscape ? 0 : duoFallbackReserve
            let top = bandTop(occlusions: occlusions, fallback: fallbackTop)
            return Spec(
                height: baseHeight(isLandscape: isLandscape, regularWidth: true),
                bandTop: top,
                trailingReserve: trailingReserve(bandTop: top,
                                                 bandHeight: baseHeight(isLandscape: isLandscape, regularWidth: true),
                                                 windowWidth: windowSize.width,
                                                 occlusions: occlusions,
                                                 fallback: fallbackReserve)
            )
        }
        if isOuterDisplay {
            let top = bandTop(occlusions: occlusions, fallback: isLandscape ? 0 : duoFallbackBandTop)
            return Spec(
                height: baseHeight(isLandscape: false, regularWidth: false),
                bandTop: top,
                trailingReserve: trailingReserve(bandTop: top,
                                                 bandHeight: baseHeight(isLandscape: false, regularWidth: false),
                                                 windowWidth: windowSize.width,
                                                 occlusions: occlusions,
                                                 fallback: duoFallbackReserve)
            )
        }
        // iPhone / iPad: Band beginnt unter der System-Statusleiste.
        return Spec(
            height: baseHeight(isLandscape: isLandscape,
                               regularWidth: horizontalSizeClass == .regular),
            bandTop: safeAreaTop,
            trailingReserve: 0
        )
    }

    /// Band-Oberkante: meldet das System Occlusionen, die in die
    /// Fallback-Bandzone hineinragen, rueckt das Band unter deren
    /// Unterkante - sonst gilt der Fallback.
    private static func bandTop(occlusions: [Occlusion],
                                fallback: CGFloat) -> CGFloat {
        let topMaxY = occlusions
            .filter { $0.frame.minY <= fallback + 40 }
            .map(\.frame.maxY)
            .max()
        return max(fallback, topMaxY ?? fallback)
    }

    /// Reserve rechts: Occlusionen, die trotz der Band-Verschiebung noch
    /// DEUTLICH ins Band ragen, verdraengen die Button-Reihe (Breite von
    /// deren Vorderkante bis zum rechten Rand). Kante-an-Kante-Beruehrung
    /// gilt bewusst nicht als Konflikt (0.5 pt Toleranz wie beim
    /// Geometrie-Guard); ohne solche Regionen gilt der Fallback.
    private static func trailingReserve(bandTop: CGFloat,
                                        bandHeight: CGFloat,
                                        windowWidth: CGFloat,
                                        occlusions: [Occlusion],
                                        fallback: CGFloat) -> CGFloat {
        let band = CGRect(x: 0, y: bandTop, width: windowWidth, height: bandHeight)
        let reserve = occlusions
            .filter { $0.frame.minY < band.maxY - 0.5 && $0.frame.maxY > band.minY + 0.5 }
            .map { windowWidth - $0.frame.minX }
            .max()
        guard let reserve else { return fallback }
        return min(max(reserve, 0), windowWidth)
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

    /// Aktive Occlusion-Regionen des Key-Windows (iOS 27.1+). Aeltere
    /// Systeme melden keine Regionen - die Spec faellt auf die Tabelle
    /// zurueck. Die Default-Query liefert nur AKTIVE Regionen (z. B. ist
    /// die Innenkamera nur bei Nutzung aktiv, die Aussenkamera immer).
    static func currentOcclusions(in window: UIWindow?) -> [Occlusion] {
        guard let window else { return [] }
        if #available(iOS 27.1, *) {
            // reservedRegions ist MainActor-isoliert; der Aufruf erfolgt
            // aus UI-Kontext (viewDidLayoutSubviews / SwiftUI body).
            return MainActor.assumeIsolated {
                window.reservedRegions(kind: .occlusion)
            }
            .map { Occlusion(frame: $0.frame) }
        }
        return []
    }

    static func currentSpec() -> Spec {
        let window = currentWindow
        let traits = window?.traitCollection
        return spec(windowSize: window?.bounds.size ?? .zero,
                    horizontalSizeClass: traits?.horizontalSizeClass ?? .compact,
                    idiom: traits?.userInterfaceIdiom ?? .phone,
                    safeAreaInsets: window?.safeAreaInsets ?? .zero,
                    occlusions: currentOcclusions(in: window))
    }
}
