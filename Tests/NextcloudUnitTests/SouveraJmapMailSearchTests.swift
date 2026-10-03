// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera JMAP mail search filter")
struct SouveraJmapMailSearchTests {

    @Test("Tokenizer keeps the most meaningful alphanumeric run per term")
    func tokenizer() {
        // Punktierte Version -> laengster Lauf (Server kann "1.0.324" nicht).
        #expect(SouveraJmapMailSearch.searchTokens(for: "Souvera Workspace - Logs 1.0.324")
                == ["Souvera", "Workspace", "Logs", "324"])
        // Adresse -> Local-Part-Lauf (Punkte brechen den Serverfilter).
        #expect(SouveraJmapMailSearch.searchTokens(for: "p.grassegger@host-on.de") == ["grassegger"])
        // Einzelner Name bleibt.
        #expect(SouveraJmapMailSearch.searchTokens(for: "Kiessling") == ["Kiessling"])
        // Nur Trennzeichen -> keine Tokens.
        #expect(SouveraJmapMailSearch.searchTokens(for: " - ").isEmpty)
    }

    @Test("Multiple tokens produce an AND stage, then a broader OR stage")
    func stagedFilters() {
        let stages = SouveraJmapMailSearch.filterStages(query: "Souvera Logs 324")
        #expect(stages.count >= 3)
        // Stufe 1: AND ueber die Tokens (praezise).
        #expect((stages[0]["operator"] as? String) == "AND")
        let andConds = (stages[0]["conditions"] as? [[String: Any]]) ?? []
        #expect(andConds.count == 3)
        #expect((andConds.first?["operator"] as? String) == "OR")
        // Stufe 2: OR ueber alle Felder/Tokens (breiter).
        #expect((stages[1]["operator"] as? String) == "OR")
        // Stufe 3: roher text als letzter Ausweg.
        #expect((stages.last?["text"] as? String) == "Souvera Logs 324")
    }

    @Test("Single token searches text and address fields via OR")
    func singleTokenFilter() {
        let stages = SouveraJmapMailSearch.filterStages(query: "grassegger")
        #expect((stages.first?["operator"] as? String) == "OR")
        let conditions = (stages.first?["conditions"] as? [[String: Any]]) ?? []
        #expect(conditions.count == 5)
        #expect((conditions.first?["text"] as? String) == "grassegger")
        #expect((conditions.dropFirst().first?["from"] as? String) == "grassegger")
    }

    @Test("Address detection requires the @ sign")
    func addressDetection() {
        #expect(SouveraJmapMailSearch.isAddressLike("jan@selh.de"))
        #expect(SouveraJmapMailSearch.isAddressLike("@selh.de"))
        #expect(!SouveraJmapMailSearch.isAddressLike("Jan Schmidt"))
        #expect(!SouveraJmapMailSearch.isAddressLike(""))
    }

    @Test("Empty query yields no filters")
    func emptyQuery() {
        #expect(SouveraJmapMailSearch.filterStages(query: "   ").isEmpty)
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

    @Test("Search skip only for the identical, already answered query")
    func shouldSkipSearch() {
        // Gleiche Query + vorhandene Ergebnisse: überspringen (kein Blinken).
        #expect(MailViewModel.shouldSkipSearch(previousQuery: "hosting", newQuery: "hosting", hasExistingResults: true))
        // GEÄNDERTE Query: immer suchen (der alte Selbstvergleich-Bug).
        #expect(!MailViewModel.shouldSkipSearch(previousQuery: "hosting", newQuery: "hosting ssl", hasExistingResults: true))
        #expect(!MailViewModel.shouldSkipSearch(previousQuery: "hosting", newQuery: "host", hasExistingResults: true))
        // Gleiche Query, aber keine Ergebnisse vorhanden: suchen.
        #expect(!MailViewModel.shouldSkipSearch(previousQuery: "hosting", newQuery: "hosting", hasExistingResults: false))
    }
}
