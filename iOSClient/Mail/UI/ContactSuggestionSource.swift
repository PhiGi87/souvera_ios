// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Device-contact lookup for the composer's recipient field, mirroring the
// Android ContactSuggestionSource (mail/ContactSuggestionSource.kt).

import Contacts
import Foundation

struct RecipientSuggestion: Identifiable, Hashable {
    var id: String { email }
    let displayName: String?
    let email: String
}

final class ContactSuggestionSource {
    private let store = CNContactStore()

    func search(_ token: String, limit: Int = 6) async -> [RecipientSuggestion] {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as NSString,
            CNContactFamilyNameKey as NSString,
            CNContactEmailAddressesKey as NSString
        ]
        let predicate = CNContact.predicateForContacts(matchingName: trimmed)
        let contacts: [CNContact]
        do {
            contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        } catch {
            return []
        }

        var result: [RecipientSuggestion] = []
        for contact in contacts {
            for emailValue in contact.emailAddresses {
                let email = String(emailValue.value)
                if email.localizedCaseInsensitiveContains(trimmed) {
                    let name = [contact.givenName, contact.familyName]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    result.append(RecipientSuggestion(
                        displayName: name.isEmpty ? nil : name,
                        email: email
                    ))
                    if result.count >= limit { break }
                }
            }
            if result.count >= limit { break }
        }

        if result.count == 1, result[0].email.caseInsensitiveCompare(trimmed) == .orderedSame {
            return []
        }
        return Array(result.prefix(limit))
    }
}
