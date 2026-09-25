// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera JMAP mail search filter")
struct SouveraJmapMailSearchTests {

    @Test("Plain text query uses the text filter")
    func plainTextFilter() {
        let filter = SouveraJmapMailSearch.buildFilter(query: "Jan")
        #expect(filter.count == 1)
        #expect((filter["text"] as? String) == "Jan")
    }

    @Test("Address-like query combines text, from, to, cc, bcc via OR")
    func addressFilter() {
        let filter = SouveraJmapMailSearch.buildFilter(query: "JanDominik.Schmidt@selh.de")
        #expect((filter["operator"] as? String) == "OR")
        let conditions = (filter["conditions"] as? [[String: Any]]) ?? []
        #expect(conditions.count == 5)
        #expect((conditions.first?["text"] as? String) == "JanDominik.Schmidt@selh.de")
        #expect((conditions.dropFirst().first?["from"] as? String) == "JanDominik.Schmidt@selh.de")
    }

    @Test("Address detection requires the @ sign")
    func addressDetection() {
        #expect(SouveraJmapMailSearch.isAddressLike("jan@selh.de"))
        #expect(SouveraJmapMailSearch.isAddressLike("@selh.de"))
        #expect(!SouveraJmapMailSearch.isAddressLike("Jan Schmidt"))
        #expect(!SouveraJmapMailSearch.isAddressLike(""))
    }

    @Test("Empty query yields an empty filter")
    func emptyQuery() {
        #expect(SouveraJmapMailSearch.buildFilter(query: "   ").isEmpty)
        #expect(SouveraJmapMailSearch.fallbackFilters(query: "  ").isEmpty)
    }

    @Test("Fallback filters cover text, from and to")
    func fallbackFilters() {
        let filters = SouveraJmapMailSearch.fallbackFilters(query: "jan@selh.de")
        #expect(filters.count == 3)
        #expect((filters[0]["text"] as? String) == "jan@selh.de")
        #expect((filters[1]["from"] as? String) == "jan@selh.de")
        #expect((filters[2]["to"] as? String) == "jan@selh.de")
    }

    @Test("Whitespace is trimmed before matching")
    func trimmedQueries() {
        let filter = SouveraJmapMailSearch.buildFilter(query: "  jan@selh.de  ")
        #expect((filter["operator"] as? String) == "OR")
        let conditions = (filter["conditions"] as? [[String: Any]]) ?? []
        #expect((conditions.first?["text"] as? String) == "jan@selh.de")
    }
}
