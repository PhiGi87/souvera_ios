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

    @Test("Sidebar actions follow the visible system sidebar band")
    func sidebarActionsActivation() {
        let view = CGRect(x: 0, y: 0, width: 466, height: 678)
        let trailingRail = CGRect(x: 397, y: 0, width: 69, height: 678)
        let bottomTabBar = CGRect(x: 0, y: 868, width: 669, height: 83)

        // Außendisplay hochkant: Band rechts -> Aktionen ins Band.
        #expect(SouveraSidebarActions.isActive(
            sidebarAvailable: true,
            sidebarHidden: false,
            tabBarFrame: trailingRail,
            viewBounds: view,
            tabBarHidden: false
        ))

        // Innendisplay quer: gleiches Band -> ebenfalls aktiv.
        let innerLandscape = CGRect(x: 882, y: 0, width: 69, height: 669)
        #expect(SouveraSidebarActions.isActive(
            sidebarAvailable: true,
            sidebarHidden: false,
            tabBarFrame: innerLandscape,
            viewBounds: CGRect(x: 0, y: 0, width: 951, height: 669),
            tabBarHidden: false
        ))

        // Innendisplay hochkant: untere Tab-Leiste -> Header bleibt zuständig.
        #expect(SouveraSidebarActions.isActive(
            sidebarAvailable: true,
            sidebarHidden: false,
            tabBarFrame: bottomTabBar,
            viewBounds: CGRect(x: 0, y: 0, width: 669, height: 951),
            tabBarHidden: false
        ) == false)

        // Ausgeblendete/fehlende Sidebar.
        #expect(SouveraSidebarActions.isActive(
            sidebarAvailable: false,
            sidebarHidden: false,
            tabBarFrame: trailingRail,
            viewBounds: view,
            tabBarHidden: false
        ) == false)
        #expect(SouveraSidebarActions.isActive(
            sidebarAvailable: true,
            sidebarHidden: true,
            tabBarFrame: trailingRail,
            viewBounds: view,
            tabBarHidden: false
        ) == false)
    }

}
