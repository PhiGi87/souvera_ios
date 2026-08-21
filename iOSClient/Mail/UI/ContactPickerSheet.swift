// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Contact picker sheet for the composer: shows the Souvera/Nextcloud
// address book plus device contacts, with a search field. Tapping a row
// adds the email address to the recipient field.

import SwiftUI

struct ContactPickerSheet: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var contacts: [RecipientSuggestion] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else {
                    List(filtered) { contact in
                        Button {
                            onSelect(contact.email)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(contact.displayName ?? contact.email)
                                    .font(.subheadline)
                                if contact.displayName != nil {
                                    Text(contact.email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: Text(NSLocalizedString("_mail_search_contacts_", comment: "")))
            .navigationTitle(NSLocalizedString("_contacts_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
            }
        }
        .task {
            contacts = await ContactSuggestionSource().allContacts()
            loading = false
        }
    }

    private var filtered: [RecipientSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return contacts }
        return contacts.filter {
            $0.email.localizedCaseInsensitiveContains(trimmed)
                || ($0.displayName ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }
}
