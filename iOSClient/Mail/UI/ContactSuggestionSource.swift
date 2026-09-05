// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Contact lookup for the composer's recipient fields. Queries the user's
// Souvera/Nextcloud address book (CardDAV) first and falls back to the
// device contacts, mirroring the Android ContactSuggestionSource.

import Contacts
import Foundation

struct RecipientSuggestion: Identifiable, Hashable {
    var id: String { email }
    let displayName: String?
    let email: String
}

final class ContactSuggestionSource {
    private let store = CNContactStore()
    private let cardDav = CardDavContactSource()
    private let directory = NextcloudDirectorySource()

    /// Debounced search used while typing a recipient. Used recipients from
    /// the per-account history come first, then instance users, the CardDAV
    /// address book, and finally device contacts.
    func search(_ token: String, limit: Int = 6, account: String = "") async -> [RecipientSuggestion] {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return [] }

        var used: [RecipientSuggestion] = UsedRecipientStore
            .suggestions(account: account, token: trimmed, limit: limit)
            .map { RecipientSuggestion(displayName: $0.displayName, email: $0.email) }

        var results = used
        results += await directory.searchUsers(trimmed, limit: limit)
        results += await cardDav.fetchAllCards(limit: 50).compactMap { card -> RecipientSuggestion? in
            let parsed = CardDavContactSource.parseVcard(card.vcard)
            guard let email = parsed.emails.first else { return nil }
            return RecipientSuggestion(displayName: parsed.name.isEmpty ? nil : parsed.name, email: email.lowercased())
        }.filter {
            $0.email.localizedCaseInsensitiveContains(trimmed)
                || ($0.displayName ?? "").localizedCaseInsensitiveContains(trimmed)
        }
        results += await deviceSearch(trimmed, limit: max(0, limit - results.count))

        let deduped = dedupe(results)
        if deduped.count == 1, deduped[0].email.caseInsensitiveCompare(trimmed) == .orderedSame {
            return []
        }
        return Array(deduped.prefix(limit))
    }

    /// Directory-only search for the contact picker and contacts module.
    func searchDirectory(_ token: String, limit: Int = 10) async -> [RecipientSuggestion] {
        guard token.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        return await directory.searchUsers(token, limit: limit)
    }

    /// Full contact list for the contact picker sheet.
    func allContacts(limit: Int = 200) async -> [RecipientSuggestion] {
        var results = await cardDav.fetchContacts(limit: limit)
        results += await deviceAll(limit: max(0, limit - results.count))
        return dedupe(results).sorted {
            ($0.displayName ?? $0.email).localizedCaseInsensitiveCompare($1.displayName ?? $1.email) == .orderedAscending
        }
    }

    private func dedupe(_ list: [RecipientSuggestion]) -> [RecipientSuggestion] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.email.lowercased()).inserted }
    }

    // MARK: - Device contacts

    private var deviceContacts: [RecipientSuggestion] {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as NSString,
            CNContactFamilyNameKey as NSString,
            CNContactEmailAddressesKey as NSString
        ]
        let predicate = CNContact.predicateForContacts(matchingName: "")
        let contacts = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
        var result: [RecipientSuggestion] = []
        for contact in contacts {
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            for emailValue in contact.emailAddresses {
                let email = String(emailValue.value).lowercased()
                guard email.contains("@") else { continue }
                result.append(RecipientSuggestion(
                    displayName: name.isEmpty ? nil : name,
                    email: email
                ))
            }
        }
        return result
    }

    private func deviceSearch(_ token: String, limit: Int) async -> [RecipientSuggestion] {
        guard limit > 0 else { return [] }
        return Array(deviceContacts.filter {
            $0.email.localizedCaseInsensitiveContains(token)
                || ($0.displayName ?? "").localizedCaseInsensitiveContains(token)
        }.prefix(limit))
    }

    private func deviceAll(limit: Int) async -> [RecipientSuggestion] {
        guard limit > 0 else { return [] }
        return Array(deviceContacts.prefix(limit))
    }
}
