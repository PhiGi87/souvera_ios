// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera form factor")
struct SouveraFormFactorTests {

    @Test("Regular width on iPhone is the Duo inner display / tent")
    func duoInner() {
        #expect(SouveraFormFactor.kind(horizontalSizeClass: .regular,
                                       idiom: .phone,
                                       width: 939) == .regularPhone)
    }

    @Test("Compact width on iPhone stays compact (outer display)")
    func phoneCompact() {
        #expect(SouveraFormFactor.kind(horizontalSizeClass: .compact,
                                       idiom: .phone,
                                       width: 466) == .compactPhone)
    }

    @Test("Regular width on iPad stays pad")
    func pad() {
        #expect(SouveraFormFactor.kind(horizontalSizeClass: .regular,
                                       idiom: .pad,
                                       width: 1024) == .pad)
    }

    @Test("Unknown size class falls back to compact")
    func unknownSizeClass() {
        #expect(SouveraFormFactor.kind(horizontalSizeClass: nil,
                                       idiom: .phone,
                                       width: 939) == .compactPhone)
    }
}
