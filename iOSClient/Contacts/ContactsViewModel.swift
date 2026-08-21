// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// View model for the Souvera contacts module: loads the CardDAV address
// book, keeps a compressed local snapshot for offline use and performs
// create/update/delete operations.

import Combine
import Foundation

enum ContactsUiState<T> {
    case loading
    case success(T)
    case error(String)
}

struct ContactDraft {
    var name: String = ""
    var email: String = ""
    var phone: String = ""
    var organization: String = ""
}

@MainActor
final class ContactsViewModel: ObservableObject {
    @Published var contacts: ContactsUiState<[ContactEntry]> = .loading
    @Published var offlineNotice: String?
    @Published var directoryResults: [RecipientSuggestion] = []

    private let source = CardDavContactSource()
    private let suggestionSource = ContactSuggestionSource()
    private let cacheKey = "contacts"

    struct ContactEntry: Identifiable {
        let id: String
        let card: CardDavCard
        let parsed: ParsedContact

        var displayName: String {
            if !parsed.name.isEmpty { return parsed.name }
            if let first = parsed.emails.first { return first }
            return NSLocalizedString("_contact_unnamed_", comment: "")
        }
    }

    func load() async {
        contacts = .loading
        offlineNotice = nil

        let cards = await source.fetchCards()
        if !cards.isEmpty {
            apply(cards)
            return
        }

        // Empty could mean "no contacts" or "offline" - use the cache when
        // one exists.
        if let cached = Self.cachedCards(), !cached.isEmpty {
            apply(cached)
            offlineNotice = NSLocalizedString("_mail_offline_", comment: "")
        } else {
            contacts = .success([])
        }
    }

    func delete(_ entry: ContactEntry) async {
        _ = await source.delete(entry.card)
        await load()
    }

    /// Searches known users of the Souvera instance (directory).
    func searchDirectory(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else {
            directoryResults = []
            return
        }
        directoryResults = await suggestionSource.searchDirectory(trimmed)
    }

    func save(_ draft: ContactDraft, existing: ContactEntry?) async -> Bool {
        let emails = draft.email.trimmingCharacters(in: .whitespaces).isEmpty
            ? (existing?.parsed.emails ?? [])
            : [draft.email.trimmingCharacters(in: .whitespaces)]
        let phones = draft.phone.trimmingCharacters(in: .whitespaces).isEmpty
            ? (existing?.parsed.phones ?? [])
            : [draft.phone.trimmingCharacters(in: .whitespaces)]
        let parsed = ParsedContact(
            uid: existing?.parsed.uid ?? "",
            name: draft.name.trimmingCharacters(in: .whitespaces),
            emails: emails,
            phones: phones,
            organization: draft.organization.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil
                : draft.organization.trimmingCharacters(in: .whitespaces)
        )
        let ok: Bool
        if let existing {
            ok = await source.update(existing.card, contact: parsed)
        } else {
            ok = await source.create(parsed) != nil
        }
        if ok {
            await load()
        }
        return ok
    }

    private func apply(_ cards: [CardDavCard]) {
        let entries = cards
            .filter { !$0.href.isEmpty }
            .map { ContactEntry(id: $0.href, card: $0, parsed: CardDavContactSource.parseVcard($0.vcard)) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let array: [[String: Any]] = cards.map { card in
            var dict: [String: Any] = ["href": card.href, "vcard": card.vcard]
            dict["etag"] = card.etag ?? ""
            return dict
        }
        MailCache.saveJSON(array, key: cacheKey)
        contacts = .success(entries)
    }

    private static func cachedCards() -> [CardDavCard]? {
        guard let array = MailCache.loadJSON(key: "contacts") as? [[String: Any]] else { return nil }
        return array.compactMap { dict in
            guard let href = dict["href"] as? String,
                  let vcard = dict["vcard"] as? String else { return nil }
            return CardDavCard(href: href, etag: dict["etag"] as? String, vcard: vcard)
        }
    }
}
