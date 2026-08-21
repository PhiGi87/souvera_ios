// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Souvera contacts: CardDAV-backed address book. Lists contacts with a
// search field, shows a detail view with all email addresses and phone
// numbers, and supports creating, editing and deleting contacts.

import SwiftUI

struct SouveraContactsView: View {
    @StateObject private var viewModel = ContactsViewModel()
    @State private var searchQuery = ""
    @State private var detailEntry: ContactsViewModel.ContactEntry?
    @State private var editDraft: (ContactDraft, ContactsViewModel.ContactEntry?)?
    @State private var showNewContact = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(NSLocalizedString("_contacts_", comment: ""))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            editDraft = (ContactDraft(), nil)
                        } label: {
                            Image(systemName: "person.badge.plus")
                        }
                    }
                }
        }
        .task { await viewModel.load() }
        .sheet(item: $detailEntry) { entry in
            ContactDetailSheet(viewModel: viewModel, entry: entry) { draft in
                editDraft = (draft, entry)
            }
        }
        .sheet(item: Binding(
            get: { editDraft.map { EditSheetState(draft: $0.0, existing: $0.1) } },
            set: { if $0 == nil { editDraft = nil } }
        )) { state in
            ContactEditSheet(viewModel: viewModel, draft: state.draft, existing: state.existing)
        }
    }

    private struct EditSheetState: Identifiable {
        let draft: ContactDraft
        let existing: ContactsViewModel.ContactEntry?
        var id: String { existing?.id ?? "new" }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let notice = viewModel.offlineNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            switch viewModel.contacts {
            case .loading:
                Spacer()
                ProgressView()
                Spacer()
            case let .error(message):
                Spacer()
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                Spacer()
            case let .success(entries):
                if entries.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text(NSLocalizedString("_contact_empty_", comment: ""))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    List(filtered(entries)) { entry in
                        Button {
                            detailEntry = entry
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color(NCBrandColor.shared.customer))
                                    .frame(width: 38, height: 38)
                                    .overlay(
                                        Text(String(entry.displayName.prefix(1)).uppercased())
                                            .foregroundStyle(.white)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayName).font(.body).fontWeight(.medium)
                                    if let email = entry.parsed.emails.first {
                                        Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await viewModel.delete(entry) }
                            } label: {
                                Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash")
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await viewModel.load() }
                }
            }
        }
        .searchable(text: $searchQuery, prompt: Text(NSLocalizedString("_mail_search_contacts_", comment: "")))
    }

    private func filtered(_ entries: [ContactsViewModel.ContactEntry]) -> [ContactsViewModel.ContactEntry] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.parsed.emails.contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }
    }
}

/// Detail view of one contact with edit and delete actions.
private struct ContactDetailSheet: View {
    @ObservedObject var viewModel: ContactsViewModel
    let entry: ContactsViewModel.ContactEntry
    let onEdit: (ContactDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Circle()
                            .fill(Color(NCBrandColor.shared.customer))
                            .frame(width: 56, height: 56)
                            .overlay(
                                Text(String(entry.displayName.prefix(1)).uppercased())
                                    .font(.title3).foregroundStyle(.white)
                            )
                        Text(entry.displayName).font(.title3).fontWeight(.semibold)
                    }
                    .padding(.vertical, 6)
                }
                if !entry.parsed.emails.isEmpty {
                    Section(NSLocalizedString("_contact_email_", comment: "")) {
                        ForEach(entry.parsed.emails, id: \.self) { email in
                            Text(email)
                        }
                    }
                }
                if !entry.parsed.phones.isEmpty {
                    Section(NSLocalizedString("_contact_phone_", comment: "")) {
                        ForEach(entry.parsed.phones, id: \.self) { phone in
                            Text(phone)
                        }
                    }
                }
                if let org = entry.parsed.organization, !org.isEmpty {
                    Section(NSLocalizedString("_contact_org_", comment: "")) {
                        Text(org)
                    }
                }
                Section {
                    Button {
                        var draft = ContactDraft()
                        draft.name = entry.parsed.name
                        draft.email = entry.parsed.emails.first ?? ""
                        draft.phone = entry.parsed.phones.first ?? ""
                        draft.organization = entry.parsed.organization ?? ""
                        onEdit(draft)
                        dismiss()
                    } label: {
                        Label(NSLocalizedString("_contact_edit_", comment: ""), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        Task { await viewModel.delete(entry) }
                        dismiss()
                    } label: {
                        Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash")
                    }
                }
            }
            .navigationTitle(NSLocalizedString("_contacts_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
            }
        }
    }
}

/// Create/edit form for one contact.
private struct ContactEditSheet: View {
    @ObservedObject var viewModel: ContactsViewModel
    @State var draft: ContactDraft
    let existing: ContactsViewModel.ContactEntry?
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("_contact_name_", comment: ""), text: $draft.name)
                    TextField(NSLocalizedString("_contact_email_", comment: ""), text: $draft.email)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                    TextField(NSLocalizedString("_contact_phone_", comment: ""), text: $draft.phone)
                        .keyboardType(.phonePad)
                    TextField(NSLocalizedString("_contact_org_", comment: ""), text: $draft.organization)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle(existing == nil
                             ? NSLocalizedString("_contact_new_", comment: "")
                             : NSLocalizedString("_contact_edit_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(NSLocalizedString("_contact_save_", comment: "")) {
                            saving = true
                            Task {
                                let ok = await viewModel.save(draft, existing: existing)
                                if ok {
                                    dismiss()
                                } else {
                                    saving = false
                                    errorMessage = NSLocalizedString("_contact_save_error_", comment: "")
                                }
                            }
                        }
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }
}
