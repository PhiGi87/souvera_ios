// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import UIKit
@testable import Nextcloud

@Suite("Souvera layout mode")
struct SouveraLayoutModeTests {

    private func traits(size: UIUserInterfaceSizeClass,
                        idiom: UIUserInterfaceIdiom) -> UITraitCollection {
        UITraitCollection(traitsFrom: [
            UITraitCollection(horizontalSizeClass: size),
            UITraitCollection(userInterfaceIdiom: idiom)
        ])
    }

    @Test("Compact phone keeps the glass header")
    func compactPhone() {
        let mode = SouveraLayoutMode(traitCollection: traits(size: .compact, idiom: .phone))
        #expect(mode.usesBridgeHeader == false)
        #expect(mode.isRegularWidth == false)
    }

    @Test("Regular phone (Duo inner) uses the bridge header")
    func regularPhone() {
        let mode = SouveraLayoutMode(traitCollection: traits(size: .regular, idiom: .phone))
        #expect(mode.usesBridgeHeader)
        #expect(mode.isRegularWidth)
    }

    @Test("iPad always uses the bridge header, even in compact width")
    func padCompactWidth() {
        let mode = SouveraLayoutMode(traitCollection: traits(size: .compact, idiom: .pad))
        #expect(mode.usesBridgeHeader)
        #expect(mode.isRegularWidth == false)
    }

    @Test("Pushed modules never render the bridge header")
    func pushed() {
        let mode = SouveraLayoutMode.pushed()
        #expect(mode.usesBridgeHeader == false)
        #expect(mode.isRegularWidth == false)
        #expect(mode.isPushed)
    }

    @Test("Trait updates switch the mode for the same scene")
    func traitUpdate() {
        let mode = SouveraLayoutMode(traitCollection: traits(size: .compact, idiom: .phone))
        mode.update(traitCollection: traits(size: .regular, idiom: .phone))
        #expect(mode.usesBridgeHeader)
        #expect(mode.isRegularWidth)
        mode.update(traitCollection: traits(size: .compact, idiom: .phone))
        #expect(mode.usesBridgeHeader == false)
    }

    @Test("Header fit only adds the missing status bar overlap")
    func headerFit() {
        #expect(SouveraHeaderFit.extraTopPadding(statusBarBottom: nil, safeAreaTop: 0) == 0)
        #expect(SouveraHeaderFit.extraTopPadding(statusBarBottom: 24, safeAreaTop: 0) == 24)
        #expect(SouveraHeaderFit.extraTopPadding(statusBarBottom: 24, safeAreaTop: 24) == 0)
        #expect(SouveraHeaderFit.extraTopPadding(statusBarBottom: 59, safeAreaTop: 20) == 32)
        #expect(SouveraHeaderFit.extraTopPadding(statusBarBottom: 10, safeAreaTop: 24) == 0)
    }

    @Test("Split only on regular width or a wide landscape")
    func splitRule() {
        #expect(SouveraLayoutMode.usesSplit(isRegularWidth: true,
                                           isLandscape: false,
                                           width: 669))
        #expect(SouveraLayoutMode.usesSplit(isRegularWidth: false,
                                           isLandscape: true,
                                           width: 678) == false)
        #expect(SouveraLayoutMode.usesSplit(isRegularWidth: false,
                                           isLandscape: true,
                                           width: 720))
        #expect(SouveraLayoutMode.usesSplit(isRegularWidth: false,
                                           isLandscape: true,
                                           width: 852))
        #expect(SouveraLayoutMode.usesSplit(isRegularWidth: false,
                                           isLandscape: false,
                                           width: 900) == false)
    }

    @Test("Action rail is only active on the outer display in portrait")
    func actionRailActivation() {
        let view = CGRect(x: 0, y: 0, width: 466, height: 678)
        let trailingRail = CGRect(x: 410, y: 360, width: 48, height: 280)
        let bottomTabBar = CGRect(x: 0, y: 630, width: 466, height: 48)

        #expect(SouveraActionRailLayout.isActive(
            horizontalSizeClass: .compact,
            idiom: .phone,
            isPortrait: true,
            tabBarFrame: trailingRail,
            viewBounds: view,
            tabBarHidden: false
        ))

        // Querformat: Buttons bleiben im Header.
        #expect(SouveraActionRailLayout.isActive(
            horizontalSizeClass: .compact,
            idiom: .phone,
            isPortrait: false,
            tabBarFrame: trailingRail,
            viewBounds: CGRect(x: 0, y: 0, width: 678, height: 466),
            tabBarHidden: false
        ) == false)

        // Untere Tab-Leiste, Innendisplay regular, ausgeblendete Leiste.
        #expect(SouveraActionRailLayout.isActive(
            horizontalSizeClass: .compact,
            idiom: .phone,
            isPortrait: true,
            tabBarFrame: bottomTabBar,
            viewBounds: view,
            tabBarHidden: false
        ) == false)
        #expect(SouveraActionRailLayout.isActive(
            horizontalSizeClass: .regular,
            idiom: .phone,
            isPortrait: true,
            tabBarFrame: trailingRail,
            viewBounds: view,
            tabBarHidden: false
        ) == false)
        #expect(SouveraActionRailLayout.isActive(
            horizontalSizeClass: .compact,
            idiom: .phone,
            isPortrait: true,
            tabBarFrame: trailingRail,
            viewBounds: view,
            tabBarHidden: true
        ) == false)
    }

    @Test("Action rail sits right above the tab bar")
    func actionRailFrame() {
        let view = CGRect(x: 0, y: 0, width: 466, height: 678)
        let tabBar = CGRect(x: 410, y: 420, width: 48, height: 240)
        let frame = SouveraActionRailLayout.frame(
            tabBarFrame: tabBar,
            headerBottom: 100,
            actionCount: 3,
            viewBounds: view
        )
        #expect(frame.maxY <= tabBar.minY - 8 + 0.5)
        #expect(frame.minY >= 100)
        #expect(frame.maxX <= view.maxX)
        #expect(frame.height == SouveraActionRailLayout.contentHeight(actionCount: 3))

        // Sidebar meldet ihre volle Container-Hoehe: Die Pille weicht nach
        // oben rechts aus, statt zu verschwinden.
        let fallback = SouveraActionRailLayout.frame(
            tabBarFrame: CGRect(x: 410, y: 0, width: 48, height: 678),
            headerBottom: 100,
            actionCount: 3,
            viewBounds: view
        )
        #expect(fallback.minY >= 100)
        #expect(fallback.height > 0)
    }

}
