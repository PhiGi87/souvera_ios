// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera mail from addresses")
struct SouveraMailFromAddressesTests {

    @Test("Shared owner email is extracted from the folder path")
    func sharedOwnerEmail() {
        #expect(SouveraMailFromAddresses.sharedOwnerEmail(ofPath: "Shared Folders/reseller@souvera.eu/INBOX") == "reseller@souvera.eu")
        #expect(SouveraMailFromAddresses.sharedOwnerEmail(ofPath: "Shared Folders/team-vertrieb@souvera.eu/Sent Items") == "team-vertrieb@souvera.eu")
        #expect(SouveraMailFromAddresses.sharedOwnerEmail(ofPath: "INBOX") == nil)
        #expect(SouveraMailFromAddresses.sharedOwnerEmail(ofPath: "Shared Folders/no-email-here/INBOX") == nil)
    }

    @Test("Merge dedupes case-insensitively and keeps the primary first")
    func merge() {
        let merged = SouveraMailFromAddresses.merge(
            existing: ["a.raatz@host-on.de"],
            identities: ["A.Raatz@Host-On.de", "reseller@souvera.eu"],
            sharedOwners: ["team@souvera.eu", "a.raatz@host-on.de"])
        #expect(merged == ["a.raatz@host-on.de", "reseller@souvera.eu", "team@souvera.eu"])
    }

    @Test("Merge drops non-address entries and trims whitespace")
    func mergeTrims() {
        let merged = SouveraMailFromAddresses.merge(
            existing: ["  primary@x.de  "],
            identities: ["not-an-address"],
            sharedOwners: ["shared@y.de"])
        #expect(merged == ["primary@x.de", "shared@y.de"])
    }

    @Test("Single mailbox stays a single entry (no picker)")
    func singleMailbox() {
        let merged = SouveraMailFromAddresses.merge(
            existing: ["only@x.de"],
            identities: ["only@x.de"],
            sharedOwners: [])
        #expect(merged == ["only@x.de"])
    }
}
