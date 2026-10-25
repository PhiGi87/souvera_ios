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

    @Test("Duo outer display portrait: 58 pt, status reserve")
    func duoOuterPortrait() {
        let s = spec(466, 678, .compact, .phone, safeTop: 0)
        #expect(s.height == 58)
        #expect(s.bandTop == 18)
        #expect(s.trailingReserve == 206)
    }

    @Test("Duo outer display landscape: 58 pt, status reserve")
    func duoOuterLandscape() {
        let s = spec(678, 466, .compact, .phone, safeTop: 0)
        #expect(s.height == 58)
        #expect(s.bandTop == 0)
        #expect(s.trailingReserve == 206)
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
}
