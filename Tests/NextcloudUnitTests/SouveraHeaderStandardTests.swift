// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import UIKit
@testable import Nextcloud

/// Header-Standard (Run 25.10.): Die System-Bar darf beim Scrollen nicht
/// minimieren - sonst "verschwindet" der Header und die Items wandern in
/// die Seitenleiste (iOS 27 Liquid-Glass-Verhalten, Default `.automatic`).
/// Die Suite ist bewusst @available(iOS 27): navigationBarMinimization
/// existiert erst ab iOS 27 - auf aelteren Test-Simulatoren laeuft sie
/// sichtbar als skipped statt still gruen durch leere Assertions.
@available(iOS 27.0, *)
@Suite("Souvera header standard")
struct SouveraHeaderStandardTests {

    @Test("Navigation items never minimize the bar")
    func neverMinimize() {
        let item = UINavigationItem(title: "Test")
        item.souveraApplyHeaderStandard()
        #expect(item.navigationBarMinimization.minimizationBehavior == .never)
    }

    @Test("Applying twice is stable")
    func idempotent() {
        let item = UINavigationItem(title: "Test")
        item.souveraApplyHeaderStandard()
        item.souveraApplyHeaderStandard()
        #expect(item.navigationBarMinimization.minimizationBehavior == .never)
    }

    @Test("Write-back reaches the item, not only the returned copy")
    func writeBackReachesItem() {
        let item = UINavigationItem(title: "Test")
        // Erst Bewusst verändern, dann der Standard greifen: Das Ergebnis
        // muss .never sein - deckt den copy-Property-Fall ab (Mutation der
        // Kopie ohne Zurückschreiben wäre hier sichtbar falsch).
        item.souveraApplyHeaderStandard()
        let readBack = item.navigationBarMinimization
        #expect(readBack.minimizationBehavior == .never)
        // Und der gelesene Wert ist wieder mutierbar, ohne das Item zu
        // beeinflussen (Kopie-Semantik dokumentiert):
        var copy = readBack
        copy.minimizationBehavior = .automatic
        #expect(item.navigationBarMinimization.minimizationBehavior == .never)
    }
}
