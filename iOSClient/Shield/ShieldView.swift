// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Souvera Shield: manages the spam/file/virus quarantines (view, release,
// delete) and the whitelist/blacklist of the mail stack.

import SwiftUI

struct ShieldView: View {
    @StateObject private var viewModel = ShieldViewModel()
    @ObservedObject var mailboxPicker: ShieldMailboxPicker
    @ObservedObject var addTrigger: ShieldAddTrigger
    @State private var section: ShieldSection = .quarantine
    @State private var quarantineKind: ShieldApi.QuarantineKind = .spam
    @State private var detailEntry: ShieldSpamEntry?
    @State private var detailJson: [String: Any]?
    @State private var showAddEntry = false
    @State private var addEntryText = ""
    @State private var addEntryList: ShieldApi.ListKind = .whitelist
    @State private var releaseChoice: ShieldReleaseRequest?

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

            if let mailbox = viewModel.selectedMailbox {
                Label(mailbox, systemImage: "tray")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

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
        .task {
            await viewModel.loadAll()
            mailboxPicker.mailboxes = viewModel.mailboxes
            if let selected = mailboxPicker.selected {
                viewModel.selectedMailbox = selected
            }
        }
        .onChange(of: viewModel.mailboxes) { _, newValue in
            mailboxPicker.mailboxes = newValue
        }
        .onChange(of: mailboxPicker.selected) { _, newValue in
            viewModel.selectedMailbox = newValue
        }
        .onChange(of: addTrigger.fire) { _, fired in
            if fired {
                addTrigger.fire = false
                guard section == .whitelist || section == .blacklist else { return }
                addEntryList = section == .blacklist ? .blacklist : .whitelist
                guard viewModel.canAddEntry else {
                    if let personal = viewModel.personalMailbox {
                        viewModel.feedback = ShieldViewModel.ShieldFeedback(
                            success: false,
                            message: String(format: NSLocalizedString("_shield_add_personal_only_", comment: ""), personal)
                        )
                    }
                    return
                }
                showAddEntry = true
            }
        }
        .onChange(of: section) { _, newValue in
            addTrigger.showAdd = newValue == .whitelist || newValue == .blacklist
        }
        .onAppear {
            addTrigger.showAdd = section == .whitelist || section == .blacklist
        }
        .sheet(item: $detailEntry) { entry in
            ShieldDetailSheet(viewModel: viewModel, entry: entry)
        }
        .alert(addEntryList == .blacklist
               ? NSLocalizedString("_shield_add_blacklist_", comment: "")
               : NSLocalizedString("_shield_add_whitelist_", comment: ""), isPresented: $showAddEntry) {
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
        .sheet(item: $releaseChoice) { request in
            ShieldReleaseSheet(request: request, viewModel: viewModel)
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
            let filtered = viewModel.filteredSpam()
            if filtered.isEmpty {
                Spacer()
                Text(NSLocalizedString("_shield_empty_", comment: "")).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { entry in
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
                            releaseChoice = ShieldReleaseRequest(
                                id: entry.id,
                                title: entry.subject.isEmpty ? entry.sender : entry.subject,
                                sender: entry.sender,
                                kind: .spam
                            )
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
            let filtered = viewModel.filteredGeneric(state)
            if filtered.isEmpty {
                Spacer()
                Text(NSLocalizedString("_shield_empty_", comment: "")).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.displayTitle).font(.subheadline).lineLimit(1)
                        Text(entry.displaySubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            releaseChoice = ShieldReleaseRequest(
                                id: entry.id,
                                title: entry.displayTitle,
                                sender: "",
                                kind: kind
                            )
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
    @State private var showReleaseChoice = false

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else if let detail {
                    let payload = detail["data"] as? [String: Any] ?? detail
                    List {
                        Section(NSLocalizedString("_shield_spam_", comment: "")) {
                            Text((payload["subject"] as? String) ?? entry.subject).font(.headline)
                            if let sender = payload["envelope_sender"] as? String, !sender.isEmpty {
                                Text(sender).font(.subheadline)
                            }
                            Text(entry.time.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let message = payload["content"] as? String, !message.isEmpty {
                            Section {
                                Text(message).textSelection(.enabled).font(.subheadline)
                            }
                        } else if let preview = payload["preview"] as? String, !preview.isEmpty {
                            Section {
                                Text(preview).textSelection(.enabled).font(.subheadline)
                            }
                        }
                        Section {
                            Button {
                                showReleaseChoice = true
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
        .sheet(isPresented: $showReleaseChoice) {
            ShieldReleaseSheet(
                request: ShieldReleaseRequest(
                    id: entry.id,
                    title: entry.subject.isEmpty ? entry.sender : entry.subject,
                    sender: entry.sender,
                    kind: .spam
                ),
                viewModel: viewModel,
                onDone: { dismiss() }
            )
        }
        .task {
            detail = await viewModel.spamDetail(id: entry.id)
            loading = false
        }
    }
}

/// Kompakte Overlay-Karte für "Zustellen": deutlich umrandet, Betreff als
/// Titel und zwei Aktionen (nur zustellen / zustellen + Whitelist).
/// Eine Zustellen-Anfrage aus der Quarantäne-Übersicht oder dem Detail.
struct ShieldReleaseRequest: Identifiable {
    let id: String
    let title: String
    let sender: String
    let kind: ShieldApi.QuarantineKind
    /// Whitelist-Option existiert serverseitig nur für die Spam-Quarantäne.
    var allowsWhitelist: Bool { kind == .spam }
}

private struct ShieldReleaseSheet: View {
    let request: ShieldReleaseRequest
    @ObservedObject var viewModel: ShieldViewModel
    var onDone: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text(NSLocalizedString("_shield_release_", comment: ""))
                .font(.headline)
            Text(request.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button {
                Task {
                    await viewModel.release(request.kind, ids: [request.id])
                    onDone?()
                    dismiss()
                }
            } label: {
                Label(NSLocalizedString("_shield_release_only_", comment: ""), systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            if request.allowsWhitelist, !request.sender.isEmpty {
                Button {
                    Task {
                        await viewModel.releaseWithWhitelist(ids: [request.id], entry: request.sender)
                        onDone?()
                        dismiss()
                    }
                } label: {
                    Label(NSLocalizedString("_shield_release_whitelist_", comment: ""), systemImage: "checkmark.shield.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            Button(NSLocalizedString("_cancel_", comment: ""), role: .cancel) {
                dismiss()
            }
        }
        .padding(18)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
        )
        .padding(14)
        .presentationDetents([.height(request.allowsWhitelist ? 330 : 240)])
        .presentationDragIndicator(.visible)
    }
}
