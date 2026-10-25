// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import UIKit
@testable import Nextcloud

/// Header-Standard (Run 25.10.): Die System-Bar darf beim Scrollen nicht
/// minimieren - sonst "verschwindet" der Header und die Items wandern in
/// die Seitenleiste (iOS 27 Liquid-Glass-Verhalten, Default `.automatic`).
@Suite("Souvera header standard")
struct SouveraHeaderStandardTests {

    @Test("Navigation items never minimize the bar")
    func neverMinimize() {
        let item = UINavigationItem(title: "Test")
        item.souveraApplyHeaderStandard()
        if #available(iOS 27.0, *) {
            #expect(item.navigationBarMinimization.minimizationBehavior == .never)
        }
    }

    @Test("Applying twice is stable")
    func idempotent() {
        let item = UINavigationItem(title: "Test")
        item.souveraApplyHeaderStandard()
        item.souveraApplyHeaderStandard()
        if #available(iOS 27.0, *) {
            #expect(item.navigationBarMinimization.minimizationBehavior == .never)
        }
    }
}
