// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// JMAP-Suchfilter fuer Mail (Run 01.10., Feedback "Suche nicht genau").
// Empirisch an Stalwart belegt:
//   - `text`/`subject`/`from`/`to` scheitern an Begriffen mit PUNKT
//     ("1.0.324" -> 0, "p.grassegger" -> 0, "host-on.de" -> 0);
//   - einzelne Wort-Terme treffen ("Souvera"+"Workspace"+"Logs" -> Treffer,
//     "grassegger" -> Treffer).
// Der Builder zerlegt die Query daher in aussagekraeftige alphanumerische
// Tokens (Adresse -> Local-Part-Lauf, "1.0.324" -> "324") und liefert eine
// Kette von Filtern abnehmender Praezision; der Aufrufer probiert sie
// nacheinander, bis Treffer kommen.

import Foundation

enum SouveraJmapMailSearch {

    /// Reine Tokenisierung (unit-testbar): je Whitespace-Begriff den
    /// aussagekraeftigsten alphanumerischen Lauf bestimmen.
    /// - Adresse ("p.grassegger@host-on.de") -> Local-Part-Lauf ("grassegger")
    /// - punktierte Version ("1.0.324") -> laengster Lauf ("324")
    /// - Begriff ohne verwertbaren Lauf (z. B. "-") entfaellt.
    static func searchTokens(for query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var tokens: [String] = []
        for rawTerm in trimmed.components(separatedBy: .whitespacesAndNewlines) where !rawTerm.isEmpty {
            var candidate = rawTerm
            if let at = candidate.firstIndex(of: "@") {
                candidate = String(candidate[..<at])
            }
            let runs = candidate
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 }
            if let best = runs.max(by: { $0.count < $1.count }) {
                tokens.append(best)
            }
        }
        var seen = Set<String>()
        return tokens.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Filter-Stufen in absteigender Praezision:
    ///  1. AND(OR(text,from,to,cc,bcc)) ueber ALLE Tokens (praezise),
    ///  2. OR(text,from,to,cc,bcc) ueber ALLE Tokens (breiter),
    ///  3. {"text": <Original>} (letzter Ausweg, bisheriges Verhalten).
    static func filterStages(query: String) -> [[String: Any]] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var stages: [[String: Any]] = []
        let tokens = searchTokens(for: trimmed)
        if !tokens.isEmpty {
            if tokens.count == 1 {
                stages.append(orFilter(conditions: conditions(for: tokens[0])))
            } else {
                stages.append(["operator": "AND",
                               "conditions": tokens.map { orFilter(conditions: conditions(for: $0)) }])
                stages.append(orFilter(conditions: tokens.flatMap { conditions(for: $0) }))
            }
        }
        stages.append(["text": trimmed])
        return stages
    }

    /// Erste (praeziseste) Stufe.
    static func buildFilter(query: String) -> [String: Any] {
        filterStages(query: query).first ?? [:]
    }

    /// Zustaendige Einzelfilter eines Tokens ueber alle Text-/Adressfelder.
    private static func conditions(for token: String) -> [[String: Any]] {
        [["text": token], ["from": token], ["to": token], ["cc": token], ["bcc": token]]
    }

    /// Adress-artig = enthaelt "@".
    static func isAddressLike(_ query: String) -> Bool {
        query.contains("@")
    }

    /// JMAP-FilterOperator OR ueber die Einzeldaten.
    static func orFilter(conditions: [[String: Any]]) -> [String: Any] {
        ["operator": "OR", "conditions": conditions]
    }

    /// Fallback, falls der Server Operatoren ablehnt: Einzelsuchen
    /// (text + from + to), deren IDs vom Aufrufer gemergt werden.
    static func fallbackFilters(query: String) -> [[String: Any]] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [["text": trimmed], ["from": trimmed], ["to": trimmed]]
    }
}
