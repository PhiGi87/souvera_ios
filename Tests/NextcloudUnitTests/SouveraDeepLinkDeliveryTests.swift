// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera deep link delivery guard")
struct SouveraDeepLinkDeliveryTests {

    private let now = Date()
    private let opened = Date().addingTimeInterval(-2)

    @Test("Different mail is always processed")
    func otherMail() {
        #expect(MailViewModel.shouldProcessDeepLinkDelivery(
            currentEmailId: "abc123", targetEmailId: "xyz789",
            lastOpenedAt: opened, now: now))
    }

    @Test("Same mail within the window is skipped")
    func sameMailFresh() {
        #expect(!MailViewModel.shouldProcessDeepLinkDelivery(
            currentEmailId: "abc123", targetEmailId: "abc123",
            lastOpenedAt: opened, now: now))
    }

    @Test("Same mail after the window is processed (real re-open)")
    func sameMailStale() {
        let stale = now.addingTimeInterval(-60)
        #expect(MailViewModel.shouldProcessDeepLinkDelivery(
            currentEmailId: "abc123", targetEmailId: "abc123",
            lastOpenedAt: stale, now: now))
    }

    @Test("Same mail without an open timestamp is processed")
    func noTimestamp() {
        #expect(MailViewModel.shouldProcessDeepLinkDelivery(
            currentEmailId: "abc123", targetEmailId: "abc123",
            lastOpenedAt: nil, now: now))
    }
}
