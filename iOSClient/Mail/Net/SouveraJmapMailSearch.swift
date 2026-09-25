// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// JMAP-Suchfilter fuer Mail (Run 25.09., Feedback "Adresse finden liefert
// nichts"): Stalwarts `text`-Filter matcht Namen/Betreff/Body, aber KEINE
// E-Mail-Adressen in From/To. Der Builder kombiniert daher text + from +
// to + cc + bcc per FilterOperator OR; scheitert der OR-Pfad am Server,
// liefert `fallbackQueries` Einzelsuchen zum Mergen.

import Foundation

enum SouveraJmapMailSearch {

    /// Baut den Filter fuer `Email/query`. Heuristik: eine Query mit "@"
    /// ist adress-artig (dann from/to/cc/bcc zusaetzlich), sonst nur
    /// `text` (bewaehrt und schnell).
    static func buildFilter(query: String) -> [String: Any] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        if isAddressLike(trimmed) {
            return orFilter(conditions: [
                ["text": trimmed],
                ["from": trimmed],
                ["to": trimmed],
                ["cc": trimmed],
                ["bcc": trimmed],
            ])
        }
        return ["text": trimmed]
    }

    /// Adress-artig = enthaelt "@" (deckt user@host, bare Domain-Suche via
    /// "@host" und Namenspräfixe vor dem @ ab).
    static func isAddressLike(_ query: String) -> Bool {
        query.contains("@")
    }

    /// JMAP-FilterOperator OR ueber die Einzeldaten.
    static func orFilter(conditions: [[String: Any]]) -> [String: Any] {
        ["operator": "OR", "conditions": conditions]
    }

    /// Fallback, falls der Server den OR-Operator ablehnt: Einzelsuchen
    /// (text + from + to), deren IDs vom Aufrufer gemergt werden.
    static func fallbackFilters(query: String) -> [[String: Any]] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [["text": trimmed], ["from": trimmed], ["to": trimmed]]
    }
}
