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

    @Test("Compact phone is not regular width")
    func compactPhone() {
        let mode = SouveraLayoutMode(traitCollection: traits(size: .compact, idiom: .phone))
        #expect(mode.isRegularWidth == false)
    }

    @Test("Regular phone (Duo inner) is regular width")
    func regularPhone() {
        let mode = SouveraLayoutMode(traitCollection: traits(size: .regular, idiom: .phone))
        #expect(mode.isRegularWidth)
    }

    @Test("Pushed modules start compact")
    func pushed() {
        let mode = SouveraLayoutMode.pushed()
        #expect(mode.isRegularWidth == false)
        #expect(mode.isPushed)
    }

    @Test("Trait updates switch the width class for the same scene")
    func traitUpdate() {
        let mode = SouveraLayoutMode(traitCollection: traits(size: .compact, idiom: .phone))
        mode.update(traitCollection: traits(size: .regular, idiom: .phone))
        #expect(mode.isRegularWidth)
        mode.update(traitCollection: traits(size: .compact, idiom: .phone))
        #expect(mode.isRegularWidth == false)
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

}
