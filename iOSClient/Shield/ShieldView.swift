// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Souvera Shield: manages the spam/file/virus quarantines (view, release,
// delete) and the whitelist/blacklist of the mail stack.

import SwiftUI

struct ShieldView: View {
    @StateObject private var viewModel = ShieldViewModel()
    @State private var section: ShieldSection = .quarantine
    @State private var quarantineKind: ShieldApi.QuarantineKind = .spam
    @State private var detailEntry: ShieldSpamEntry?
    @State private var detailJson: [String: Any]?
    @State private var showAddEntry = false
    @State private var addEntryText = ""
    @State private var addEntryList: ShieldApi.ListKind = .whitelist

    enum ShieldSection: String, CaseIterable, Identifiable {
        case quarantine, whitelist, blacklist
        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .quarantine: return "_shield_quarantine_"
            case .whitelist: return "_shield_whitelist_"
            case .blacklist: return "_shield_blacklist_"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(ShieldSection.allCases) { section in
                    Text(NSLocalizedString(section.titleKey, comment: "")).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            if !viewModel.warnings.isEmpty {
                Text(viewModel.warnings.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            switch section {
            case .quarantine: quarantineSection
            case .whitelist: listSection(kind: .whitelist, state: viewModel.whitelist)
            case .blacklist: listSection(kind: .blacklist, state: viewModel.blacklist)
            }
        }
        .navigationTitle(NSLocalizedString("_shield_", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadAll() }
        .sheet(item: $detailEntry) { entry in
            ShieldDetailSheet(viewModel: viewModel, entry: entry)
        }
        .alert(NSLocalizedString("_shield_add_entry_", comment: ""), isPresented: $showAddEntry) {
            TextField(NSLocalizedString("_shield_entry_placeholder_", comment: ""), text: $addEntryText)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
            Button(NSLocalizedString("_shield_add_entry_", comment: "")) {
                let entry = addEntryText.trimmingCharacters(in: .whitespaces)
                addEntryText = ""
                guard !entry.isEmpty else { return }
                Task { await viewModel.addEntry(addEntryList, entry: entry) }
            }
            Button(NSLocalizedString("_cancel_", comment: ""), role: .cancel) {
                addEntryText = ""
            }
        }
        .overlay(alignment: .bottom) {
            if let feedback = viewModel.feedback {
                HStack(spacing: 8) {
                    Image(systemName: feedback.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(feedback.success ? .green : .red)
                    Text(feedback.message).font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.bottom, 20)
                .task(id: feedback) {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    viewModel.feedback = nil
                }
            }
        }
    }

    // MARK: - Quarantine

    private var quarantineSection: some View {
        VStack(spacing: 0) {
            Picker("", selection: $quarantineKind) {
                Text(NSLocalizedString("_shield_spam_", comment: "")).tag(ShieldApi.QuarantineKind.spam)
                Text(NSLocalizedString("_shield_files_", comment: "")).tag(ShieldApi.QuarantineKind.file)
                Text(NSLocalizedString("_shield_viruses_", comment: "")).tag(ShieldApi.QuarantineKind.virus)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            switch quarantineKind {
            case .spam: spamList
            case .file: genericList(state: viewModel.fileQuarantine, kind: .file)
            case .virus: genericList(state: viewModel.virusQuarantine, kind: .virus)
            }
        }
    }

    @ViewBuilder
    private var spamList: some View {
        switch viewModel.spamQuarantine {
        case .loading:
            Spacer(); ProgressView(); Spacer()
        case let .error(message):
            Spacer(); Text(message).foregroundStyle(.secondary); Spacer()
        case let .success(entries):
            if entries.isEmpty {
                Spacer()
                Text(NSLocalizedString("_shield_empty_", comment: "")).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(entries) { entry in
                    Button {
                        detailEntry = entry
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.subject.isEmpty ? entry.sender : entry.subject)
                                .font(.subheadline).lineLimit(1)
                            Text("\(entry.sender) · \(entry.time.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await viewModel.release(.spam, ids: [entry.id]) }
                        } label: {
                            Label(NSLocalizedString("_shield_release_", comment: ""), systemImage: "tray.and.arrow.up")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await viewModel.delete(.spam, ids: [entry.id]) }
                        } label: {
                            Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash")
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await viewModel.loadAll() }
            }
        }
    }

    @ViewBuilder
    private func genericList(state: ShieldUiState<[ShieldGenericEntry]>, kind: ShieldApi.QuarantineKind) -> some View {
        switch state {
        case .loading:
            Spacer(); ProgressView(); Spacer()
        case let .error(message):
            Spacer(); Text(message).foregroundStyle(.secondary); Spacer()
        case let .success(entries):
            if entries.isEmpty {
                Spacer()
                Text(NSLocalizedString("_shield_empty_", comment: "")).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.displayTitle).font(.subheadline).lineLimit(1)
                        Text(entry.displaySubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await viewModel.release(kind, ids: [entry.id]) }
                        } label: {
                            Label(NSLocalizedString("_shield_release_", comment: ""), systemImage: "tray.and.arrow.up")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await viewModel.delete(kind, ids: [entry.id]) }
                        } label: {
                            Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash")
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await viewModel.loadAll() }
            }
        }
    }

    // MARK: - Whitelist / Blacklist

    @ViewBuilder
    private func listSection(kind: ShieldApi.ListKind, state: ShieldUiState<[String]>) -> some View {
        switch state {
        case .loading:
            Spacer(); ProgressView(); Spacer()
        case let .error(message):
            Spacer(); Text(message).foregroundStyle(.secondary); Spacer()
        case let .success(entries):
            List {
                ForEach(entries, id: \.self) { entry in
                    Text(entry).font(.subheadline)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await viewModel.removeEntry(kind, entry: entry) }
                            } label: {
                                Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.plain)
            .refreshable { await viewModel.loadAll() }
            .safeAreaInset(edge: .bottom) {
                Button {
                    addEntryList = kind
                    showAddEntry = true
                } label: {
                    Label(NSLocalizedString("_shield_add_entry_", comment: ""), systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }
}

/// Detail view of a spam quarantine entry (message preview).
private struct ShieldDetailSheet: View {
    @ObservedObject var viewModel: ShieldViewModel
    let entry: ShieldSpamEntry
    @Environment(\.dismiss) private var dismiss
    @State private var detail: [String: Any]?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else if let detail {
                    List {
                        Section(NSLocalizedString("_shield_spam_", comment: "")) {
                            Text(entry.subject).font(.headline)
                            if let from = detail["from"] as? String, !from.isEmpty {
                                Text(from).font(.subheadline)
                            }
                            Text(entry.time.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let message = detail["message"] as? String, !message.isEmpty {
                            Section {
                                Text(message).textSelection(.enabled).font(.subheadline)
                            }
                        } else if let preview = detail["preview"] as? String, !preview.isEmpty {
                            Section {
                                Text(preview).textSelection(.enabled).font(.subheadline)
                            }
                        }
                        Section {
                            Button {
                                Task {
                                    await viewModel.release(.spam, ids: [entry.id])
                                    dismiss()
                                }
                            } label: {
                                Label(NSLocalizedString("_shield_release_", comment: ""), systemImage: "tray.and.arrow.up")
                            }
                            Button(role: .destructive) {
                                Task {
                                    await viewModel.delete(.spam, ids: [entry.id])
                                    dismiss()
                                }
                            } label: {
                                Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash")
                            }
                        }
                    }
                } else {
                    Text(NSLocalizedString("_shield_load_error_", comment: "")).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(NSLocalizedString("_shield_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
            }
        }
        .task {
            detail = await viewModel.spamDetail(id: entry.id)
            loading = false
        }
    }
}
