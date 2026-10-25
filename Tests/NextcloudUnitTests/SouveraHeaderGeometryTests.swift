// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import UIKit
@testable import Nextcloud

/// Verbindliche Header-Regel (SouveraHeaderGeometry): Hoehe und
/// Button-Position muessen in der ganzen App je Geraeteklasse und
/// Orientierung identisch sein.
@Suite("Souvera header geometry")
struct SouveraHeaderGeometryTests {

    private func spec(_ width: CGFloat, _ height: CGFloat,
                      _ sizeClass: UIUserInterfaceSizeClass,
                      _ idiom: UIUserInterfaceIdiom,
                      safeTop: CGFloat = 0) -> SouveraHeaderGeometry.Spec {
        SouveraHeaderGeometry.spec(windowSize: CGSize(width: width, height: height),
                                   horizontalSizeClass: sizeClass,
                                   idiom: idiom,
                                   safeAreaTop: safeTop)
    }

    private var wideHeight: CGFloat {
        if #available(iOS 26.0, *) { return 82 }
        return 70
    }

    @Test("Duo inner display portrait: 58 pt, Band on status symbol row")
    func duoInnerPortrait() {
        let s = spec(669, 951, .regular, .phone)
        #expect(s.height == 58)
        #expect(s.bandTop == 18)
        #expect(s.trailingReserve == 206)
    }

    @Test("Duo inner display landscape: wide height, band at top")
    func duoInnerLandscape() {
        let s = spec(951, 669, .regular, .phone)
        #expect(s.height == wideHeight)
        #expect(s.bandTop == 0)
        #expect(s.trailingReserve == 0)
    }

    @Test("Duo outer display WITHOUT region data: safe compact fallback")
    func duoOuterPortrait() {
        // Run 25.10. (Apple-konform): Ohne Occlusion-Regionen ist der
        // Aussendisplay nicht mehr ueber Pixelmasse erkennbar - bewusst
        // der abgesicherte Kompakt-Fallback statt geratener Werte.
        let s = spec(466, 678, .compact, .phone, safeTop: 0)
        #expect(s.height == 58)
        #expect(s.bandTop == 0)
        #expect(s.trailingReserve == 0)
    }

    @Test("Duo outer display landscape WITHOUT region data: safe fallback")
    func duoOuterLandscape() {
        let s = spec(678, 466, .compact, .phone, safeTop: 0)
        #expect(s.height == 58)
        #expect(s.bandTop == 0)
        #expect(s.trailingReserve == 0)
    }

    @Test("iPhone portrait: band below status bar")
    func iPhonePortrait() {
        let s = spec(393, 852, .compact, .phone, safeTop: 59)
        #expect(s.height == 58)
        #expect(s.bandTop == 59)
        #expect(s.trailingReserve == 0)
    }

    @Test("iPhone landscape: 58 pt, band at top, no reserve")
    func iPhoneLandscape() {
        let s = spec(852, 393, .compact, .phone, safeTop: 0)
        #expect(s.height == 58)
        #expect(s.bandTop == 0)
        #expect(s.trailingReserve == 0)
    }

    @Test("iPad portrait: band below status bar")
    func iPadPortrait() {
        let s = spec(1024, 1366, .regular, .pad, safeTop: 24)
        #expect(s.height == 58)
        #expect(s.bandTop == 24)
        #expect(s.trailingReserve == 0)
    }

    @Test("iPad landscape: wide height, band below status bar")
    func iPadLandscape() {
        let s = spec(1366, 1024, .regular, .pad, safeTop: 24)
        #expect(s.height == wideHeight)
        #expect(s.bandTop == 24)
        #expect(s.trailingReserve == 0)
    }

    @Test("iPad split view (compact): like iPhone")
    func iPadSplit() {
        let s = spec(678, 1024, .compact, .pad, safeTop: 24)
        #expect(s.height == 58)
        #expect(s.bandTop == 24)
        #expect(s.trailingReserve == 0)
    }

    // MARK: - iOS 27.1: Occlusion-Regionen statt Pixelmasse (Run 25.10.)

    /// Duo-Aussendisplay WIRD NICHT MEHR ueber Pixelmassse erkannt:
    /// kompakt + Safe Area rundum 0 + aktive Kapsel-Occlusion.
    private func specWithRegions(_ width: CGFloat, _ height: CGFloat,
                                 _ sizeClass: UIUserInterfaceSizeClass,
                                 _ idiom: UIUserInterfaceIdiom,
                                 insets: UIEdgeInsets = .zero,
                                 occlusions: [CGRect]) -> SouveraHeaderGeometry.Spec {
        SouveraHeaderGeometry.spec(windowSize: CGSize(width: width, height: height),
                                   horizontalSizeClass: sizeClass,
                                   idiom: idiom,
                                   safeAreaInsets: insets,
                                   occlusions: occlusions.map { SouveraHeaderGeometry.Occlusion(frame: $0) })
    }

    @Test("Duo outer display detected via occlusion region, horizontal reserve")
    func duoOuterViaRegion() {
        // Status-Kapsel: x=130..336, y=8..40 (margins inklusive).
        // Run 25.10. (Fix): bandTop bleibt 18 (Tabelle) - das Band liegt
        // ALS HINTERGRUND hinter der Kapsel; nur die Button-Reihe weicht
        // HORIZONTAL aus (Reserve = Breite bis zur Region-Vorderkante).
        let s = specWithRegions(466, 678, .compact, .phone,
                                occlusions: [CGRect(x: 130, y: 8, width: 206, height: 32)])
        #expect(s.height == 58)
        #expect(s.bandTop == 18)
        #expect(s.trailingReserve == 336) // 466 - 130
    }

    @Test("Region intersecting the band derives the trailing reserve")
    func occlusionInsideBandReservesTrailing() {
        // Kapsel 50..80 schneidet das Band (18..76) -> Reserve abgeleitet.
        let s = specWithRegions(466, 678, .compact, .phone,
                                occlusions: [CGRect(x: 200, y: 50, width: 200, height: 30)])
        #expect(s.bandTop == 18)
        #expect(s.trailingReserve == 266) // 466 - 200
    }

    @Test("Tall capsule overlapping the band reserves trailing space")
    func tallCapsuleReservesTrailing() {
        let s = specWithRegions(466, 678, .compact, .phone,
                                occlusions: [CGRect(x: 100, y: 8, width: 260, height: 72)])
        #expect(s.bandTop == 18)
        #expect(s.trailingReserve == 366) // 466 - 100
    }

    @Test("Region intersecting the band derives the reserve")
    func regionInsideFallbackBandDerivesReserve() {
        let s = specWithRegions(466, 678, .compact, .phone,
                                occlusions: [CGRect(x: 150, y: 60, width: 200, height: 40)])
        #expect(s.bandTop == 18)
        #expect(s.trailingReserve == 316) // 466 - 150
    }

    @Test("Region above the band keeps the table fallback reserve")
    func regionAboveBandKeepsFallback() {
        // Region endet bei 18 (Kante am Band) -> kein Konflikt, Fallback 206.
        let s = specWithRegions(466, 678, .compact, .phone,
                                occlusions: [CGRect(x: 130, y: 0, width: 206, height: 18)])
        #expect(s.bandTop == 18)
        #expect(s.trailingReserve == 206)
    }

    @Test("Real inner-display frames from the field log keep table band top")
    func realSystemFramesKeepBandTop() {
        // Reale System-Frames (Log Build 202610251129): Innen hoch meldet
        // die Kapsel-Region mit maxY 82, in quer mit maxY 124 - die alte
        // Ableitung drueckte das Band darauf (82/124 pt, Reserve quer 0).
        // Korrekt: bandTop bleibt 18/0, Reserve wird horizontal abgeleitet.
        let portrait = specWithRegions(669, 951, .regular, .phone,
                                       occlusions: [CGRect(x: 263, y: 0, width: 206, height: 82)])
        #expect(portrait.height == 58)
        #expect(portrait.bandTop == 18)
        #expect(portrait.trailingReserve == 406) // 669 - 263

        let landscape = specWithRegions(951, 669, .regular, .phone,
                                        occlusions: [CGRect(x: 500, y: 0, width: 340, height: 124)])
        #expect(landscape.height == wideHeight)
        #expect(landscape.bandTop == 0)
        #expect(landscape.trailingReserve == 451) // 951 - 500
    }

    @Test("Landscape iPhone with Dynamic Island is NOT the Duo outer display")
    func landscapeiPhoneIsNotOuterDisplay() {
        // Querformat: seitliche Safe-Area-Insets (~59 pt) schliessen den
        // Duo-Aussendisplay aus - trotz aktiver Occlusion (Dynamic Island).
        let insets = UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)
        let s = specWithRegions(852, 393, .compact, .phone,
                                insets: insets,
                                occlusions: [CGRect(x: 376, y: 11, width: 100, height: 30)])
        #expect(s.height == 58)
        #expect(s.bandTop == 0)
        #expect(s.trailingReserve == 0)
    }

    @Test("Portrait iPhone with occlusion keeps the status-bar band")
    func portraitiPhoneWithOcclusion() {
        let insets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let s = specWithRegions(393, 852, .compact, .phone,
                                insets: insets,
                                occlusions: [CGRect(x: 120, y: 11, width: 150, height: 37)])
        #expect(s.height == 58)
        #expect(s.bandTop == 59)
        #expect(s.trailingReserve == 0)
    }

    @Test("Compact phone WITHOUT occlusion data falls back to the safe table")
    func compactWithoutRegionsFallsBack() {
        // Die abgesicherte Regel: ohne Regionsdaten kein Duo-Außendisplay.
        let s = specWithRegions(466, 678, .compact, .phone, occlusions: [])
        #expect(s.height == 58)
        #expect(s.bandTop == 0)
        #expect(s.trailingReserve == 0)
    }

    @Test("AGENTS.md table holds for every consumer input (SwiftUI == UIKit)")
    func identicalGeometryForAllSurfaces() {
        // Beide Konsumenten (SwiftUI-Modul-Header via currentSpec(),
        // UIKit-Bars via applyHeaderGeometry()) rufen DIESELBE spec()-
        // Funktion: identische Eingaben muessen die Tabellen-Werte der
        // verbindlichen Header-Regel liefern.
        let cases: [(String, CGSize, UIUserInterfaceSizeClass, UIUserInterfaceIdiom, UIEdgeInsets, CGFloat, CGFloat, CGFloat)] = [
            ("iPhone portrait", CGSize(width: 393, height: 852), .compact, .phone, UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0), 58, 59, 0),
            ("iPhone landscape", CGSize(width: 852, height: 393), .compact, .phone, .zero, 58, 0, 0),
            ("Duo inner portrait", CGSize(width: 669, height: 951), .regular, .phone, .zero, 58, 18, 206),
            ("Duo inner landscape", CGSize(width: 951, height: 669), .regular, .phone, .zero, wideHeight, 0, 0),
            ("iPad portrait", CGSize(width: 1024, height: 1366), .regular, .pad, UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0), 58, 24, 0),
            ("iPad landscape", CGSize(width: 1366, height: 1024), .regular, .pad, UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0), wideHeight, 24, 0),
            ("iPad split (compact)", CGSize(width: 678, height: 1024), .compact, .pad, UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0), 58, 24, 0)
        ]
        for (name, size, sizeClass, idiom, insets, expectedHeight, expectedBandTop, expectedReserve) in cases {
            let s = SouveraHeaderGeometry.spec(windowSize: size,
                                               horizontalSizeClass: sizeClass,
                                               idiom: idiom,
                                               safeAreaInsets: insets,
                                               occlusions: [])
            #expect(s.height == expectedHeight, "\(name): height")
            #expect(s.bandTop == expectedBandTop, "\(name): bandTop")
            #expect(s.trailingReserve == expectedReserve, "\(name): trailingReserve")
        }
    }
}
