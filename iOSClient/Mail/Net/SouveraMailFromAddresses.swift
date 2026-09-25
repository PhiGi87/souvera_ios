// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 25.09. (Feedback: Absender-Auswahl bei mehreren Postfächern, auch
// shared): Helfer fuer die From-Liste im Compose.
//  - Identities (JMAP Identity/get) und Shared-Postfach-Eigentuemer
//    (`Shared Folders/<email>/...`, Mailbox.ownerIdentity) werden in die
//    Liste gemergt (dedupe, case-insensitive).
//  - Beim Antworten aus einem Shared-Ordner wird der Owner als From
//    vorausgewaehlt (Paritaet zum Webmail, souvera_mail v0.14.8).

import Foundation

enum SouveraMailFromAddresses {

    /// E-Mail des Shared-Postfach-Eigentuemers aus einem Ordner-Pfad
    /// (`Shared Folders/<email>/...`), sonst nil.
    static func sharedOwnerEmail(ofPath path: String) -> String? {
        guard let range = path.range(of: "^Shared Folders/([^/]+)/", options: .regularExpression) else {
            return nil
        }
        let remainder = path[range.upperBound...]
        let email = String(remainder.split(separator: "/", maxSplits: 1).first ?? "")
        return email.contains("@") ? email : nil
    }

    /// Mergt die From-Liste: bestehende Eintraege bleiben, Identities und
    /// Shared-Eigentuemer kommen dazu (dedupe case-insensitive, Reihenfolge
    /// stabil: Primary zuerst).
    static func merge(existing: [String], identities: [String], sharedOwners: [String]) -> [String] {
        var result: [String] = []
        func add(_ address: String) {
            let trimmed = address.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("@") else { return }
            guard !result.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
            result.append(trimmed)
        }
        existing.forEach(add)
        identities.forEach(add)
        sharedOwners.forEach(add)
        return result
    }
}
