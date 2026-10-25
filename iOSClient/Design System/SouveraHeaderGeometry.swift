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
// Fallback. Auf iOS 27.1+ wird die horizontale Reserve aus den vom System
// gemeldeten Occlusion-Regionen (Kamera/Status-Kapsel) abgeleitet - nicht
// mehr aus Hartcodierten Pixelmassen (HIG: Layout aus Size Classes und
// Regionen ableiten, nicht aus Geraetedimensionen). bandTop folgt NIE einer
// Region (Tabelle/Safe Area - der Band-Grund liegt hinter der Kapsel);
// nur die Button-Reihe weicht horizontal aus. Ohne Regionsdaten
// (iOS < 27.1, Simulator, Extensions) greift die Tabelle unveraendert.
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
    ///
    /// Run 25.10. (Apple-konform, horizontale Ausweichrichtung): Occlusion-
    /// Regionen steuern AUSSCHLIESSLICH die horizontale Reserve der Button-
    /// Reihe ("place CONTENT outside this area" - der Band-Grund liegt als
    /// Hintergrund hinter der Status-Kapsel). bandTop folgt nie einer
    /// Region, sondern der Tabelle bzw. der Safe Area - das vollstaendige
    /// Runterdruecken des Bands war der Regressionsfehler von heute früh
    /// (Band bei 82/124 pt, Reserve quer 0 statt 206).
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

        if isInnerDisplay || isOuterDisplay {
            let height = isInnerDisplay
                ? baseHeight(isLandscape: isLandscape, regularWidth: true)
                : baseHeight(isLandscape: false, regularWidth: false)
            let fallbackTop: CGFloat = isLandscape ? 0 : duoFallbackBandTop
            let fallbackReserve: CGFloat = (isOuterDisplay || !isLandscape) ? duoFallbackReserve : 0
            let top = max(safeAreaTop, fallbackTop)
            return Spec(
                height: height,
                bandTop: top,
                trailingReserve: trailingReserve(bandTop: top,
                                                 bandHeight: height,
                                                 windowWidth: windowSize.width,
                                                 occlusions: occlusions,
                                                 fallback: fallbackReserve)
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

    /// Reserve rechts: Occlusionen, die das Band DEUTLICH vertikal
    /// schneiden, verdraengen die Button-Reihe horizontal (Breite von der
    /// Vorderkante der Region bis zum rechten Rand). Kante-an-Kante gilt
    /// bewusst nicht als Konflikt (0.5 pt Toleranz wie beim Geometrie-
    /// Guard); ohne treffende Region gilt der Fallback der Tabelle.
    private static func trailingReserve(bandTop: CGFloat,
                                        bandHeight: CGFloat,
                                        windowWidth: CGFloat,
                                        occlusions: [Occlusion],
                                        fallback: CGFloat) -> CGFloat {
        let bandMaxY = bandTop + bandHeight
        let reserve = occlusions
            .filter { $0.frame.maxY > bandTop + 0.5 && $0.frame.minY < bandMaxY - 0.5 }
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

    /// Spec der aktuellen Umgebung OHNE Regionsdaten (Tabellen-Fallback).
    /// Run 25.10. (Apple-konform): Regionen werden nie global vom ersten
    /// Key-Window gelesen ("check in the view that positions the content"),
    /// sondern vom positionierenden View bereitgestellt (UIKit:
    /// SouveraReservedRegionObserver, SwiftUI: SouveraLayoutMode des
    /// Hosting-NavigationControllers) und hier uebergeben.
    static func currentSpec() -> Spec {
        let window = currentWindow
        let traits = window?.traitCollection
        return spec(windowSize: window?.bounds.size ?? .zero,
                    horizontalSizeClass: traits?.horizontalSizeClass ?? .compact,
                    idiom: traits?.userInterfaceIdiom ?? .phone,
                    safeAreaInsets: window?.safeAreaInsets ?? .zero,
                    occlusions: [])
    }

    /// currentSpec() mit region-abgeleiteter horizontaler Reserve.
    /// `occlusionFrames` kommen vom positionierenden Kontext (Observer
    /// bzw. Modul-Layout, Fensterkoordinaten); ohne Regionen bleibt die
    /// Tabellen-Reserve. Bewusst [CGRect] - der Aufrufer (SouveraLayoutMode)
    /// wird auch in Extension-Targets kompiliert.
    static func currentSpec(windowWidth: CGFloat,
                            occlusionFrames: [CGRect]) -> Spec {
        let base = currentSpec()
        guard !occlusionFrames.isEmpty else { return base }
        let width = windowWidth > 0 ? windowWidth : (currentWindow?.bounds.width ?? 0)
        let reserve = trailingReserve(bandTop: base.bandTop,
                                      bandHeight: base.height,
                                      windowWidth: width,
                                      occlusions: occlusionFrames.map { Occlusion(frame: $0) },
                                      fallback: base.trailingReserve)
        return Spec(height: base.height, bandTop: base.bandTop, trailingReserve: reserve)
    }
}
