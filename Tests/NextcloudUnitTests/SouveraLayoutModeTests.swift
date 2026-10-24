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
}
