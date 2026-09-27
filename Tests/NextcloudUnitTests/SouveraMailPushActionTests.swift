// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera mail push actions")
struct SouveraMailPushActionTests {

    @Test("Canonical email id is found by matching the blobId")
    func canonicalIdByBlobId() {
        let candidates: [(id: String, blobId: String?)] = [
            ("dp1yaaa93w", "blob-93w"),
            ("93w", "blob-93w"),
            ("ab1yaaa10x", "blob-10x")
        ]
        #expect(SouveraMailPushActionRunner.canonicalEmailId(blobId: "blob-93w", in: candidates) == "dp1yaaa93w")
        #expect(SouveraMailPushActionRunner.canonicalEmailId(blobId: "blob-10x", in: candidates) == "ab1yaaa10x")
    }

    @Test("Canonical lookup returns nil without a blobId match")
    func canonicalIdNoMatch() {
        let candidates: [(id: String, blobId: String?)] = [
            ("dp1yaaa93w", "blob-93w"),
            ("ab1yaaa10x", "blob-10x")
        ]
        #expect(SouveraMailPushActionRunner.canonicalEmailId(blobId: "blob-unknown", in: candidates) == nil)
        #expect(SouveraMailPushActionRunner.canonicalEmailId(blobId: "blob-93w", in: []) == nil)
    }

    @Test("Canonical lookup rejects an empty blobId")
    func canonicalIdEmptyBlob() {
        let candidates: [(id: String, blobId: String?)] = [
            ("dp1yaaa93w", "blob-93w")
        ]
        #expect(SouveraMailPushActionRunner.canonicalEmailId(blobId: "", in: candidates) == nil)
    }

    @Test("First candidate with matching blobId wins")
    func canonicalIdFirstMatch() {
        let candidates: [(id: String, blobId: String?)] = [
            ("first-canonical", "blob-1"),
            ("second-canonical", "blob-1")
        ]
        #expect(SouveraMailPushActionRunner.canonicalEmailId(blobId: "blob-1", in: candidates) == "first-canonical")
    }
}
