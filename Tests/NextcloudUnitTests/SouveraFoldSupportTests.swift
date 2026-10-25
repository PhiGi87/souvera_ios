// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import SwiftUI
@testable import Nextcloud

/// Reine Rechnung der Falz-Begrenzung (SouveraDivisionConstraints):
/// Richtung der Falz und Overlay-Position muessen Apple-konform aus dem
/// Region-Frame folgen, unabhaengig vom Proxy.
@Suite("Souvera fold support")
struct SouveraFoldSupportTests {

    @Test("Vertical fold (book) moves the overlay behind the fold")
    func verticalFold() {
        let frame = CGRect(x: 330, y: 0, width: 9, height: 951)
        #expect(SouveraDivisionConstraints.isVerticalFold(frame))
        let c = SouveraDivisionConstraints.constraints(divisionFrame: frame,
                                                       viewSize: CGSize(width: 669, height: 951))
        #expect(c.maxWidth == 669 - 339 - 32)
        #expect(c.maxHeight == nil)
        #expect(c.offsetX == 339 / 2)
    }

    @Test("Horizontal fold (tent) keeps the overlay above the fold")
    func horizontalFold() {
        let frame = CGRect(x: 0, y: 470, width: 951, height: 11)
        #expect(SouveraDivisionConstraints.isVerticalFold(frame) == false)
        let c = SouveraDivisionConstraints.constraints(divisionFrame: frame,
                                                       viewSize: CGSize(width: 951, height: 669))
        #expect(c.maxWidth == nil)
        #expect(c.maxHeight == 470 - 8)
        #expect(c.offsetX == 0)
    }

    @Test("Inactive fold yields the empty constraints value")
    func inactiveFold() {
        // read() filtert auf isActive; ohne aktive Region bleibt der
        // leere Wert - das Overlay darf unbeschraenkt liegen.
        #expect(SouveraDivisionConstraints.none == SouveraDivisionConstraints())
    }
}
