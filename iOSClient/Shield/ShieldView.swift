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
    @State private var showScrollTop = false

    private var addEntryTitle: String {
        if addEntryList == .blacklist {
            return NSLocalizedString("_shield_add_blacklist_", comment: "")
        }
        return NSLocalizedString("_shield_add_whitelist_", comment: "")
    }

    private var header: some View {
        VStack(spacing: 0) {
            // Ausgewähltes Postfach (oder "Alle Postfächer") steht über dem
            // Segment-Toggle.
            Label(
                viewModel.selectedMailbox ?? NSLocalizedString("_shield_all_mailboxes_", comment: ""),
                systemImage: "tray"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 2)

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
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .quarantine: quarantineSection
        case .whitelist: listSection(kind: .whitelist, state: viewModel.whitelist)
        case .blacklist: listSection(kind: .blacklist, state: viewModel.blacklist)
        }
    }

    private func handleAddFire() {
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
        decorated
    }

    /// Stufe 1: Basis-View + Overlay/Alert.
    private var baseView: some View {
        VStack(spacing: 0) {
            header
            sectionContent
        }
        .alert(addEntryTitle, isPresented: $showAddEntry, actions: addEntryAlertActions) {
            Text(NSLocalizedString("_shield_entry_placeholder_", comment: ""))
        }
        .souveraToast()
    }

    /// Stufe 2: Sheets.
    private var withSheets: some View {
        baseView
            .sheet(item: $detailEntry) { entry in
                ShieldDetailSheet(viewModel: viewModel, entry: entry)
            }
            .sheet(item: $releaseChoice) { request in
                ShieldReleaseSheet(request: request, viewModel: viewModel)
            }
    }

    /// Stufe 3a: Bindings.
    private var withBindings: some View {
        withSheets
            .onChange(of: viewModel.mailboxes) { _, newValue in
                mailboxPicker.mailboxes = newValue
            }
            .onChange(of: mailboxPicker.selected) { _, newValue in
                viewModel.selectedMailbox = newValue
            }
            .onChange(of: addTrigger.fire) { _, fired in
                if fired { handleAddFire() }
            }
            .onChange(of: section) { _, newValue in
                addTrigger.showAdd = newValue == .whitelist || newValue == .blacklist
                showScrollTop = false
            }
            .onChange(of: quarantineKind) { _, _ in
                showScrollTop = false
            }
    }

    /// Stufe 3b: Feedback-Toast (eigene Stufe, hält den Type-Checker klein).
    private var withFeedbackToast: some View {
        withBindings
            .onChange(of: viewModel.feedback) { _, newValue in
                if let feedback = newValue {
                    SouveraToastCenter.shared.show(
                        SouveraToast(
                            message: feedback.message,
                            style: feedback.success ? .success : .error
                        )
                    )
                }
            }
            .onAppear {
                addTrigger.showAdd = section == .whitelist || section == .blacklist
            }
    }

    /// Stufe 4: Initial-Load.
    private var decorated: some View {
        withFeedbackToast
            .task {
                await viewModel.loadAll()
                mailboxPicker.mailboxes = viewModel.mailboxes
                if let selected = mailboxPicker.selected {
                    viewModel.selectedMailbox = selected
                }
            }
    }

    @ViewBuilder
    private func addEntryAlertActions() -> some View {
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

    // MARK: - Quarantine

    /// Up-Pfeil wie im Mail-Modul: erscheint nach ~120 pt Scroll, scrollt
    /// sanft zum ersten Eintrag der aktuellen Liste.
    @ViewBuilder
    private func scrollTopButton(proxy: ScrollViewProxy, firstId: String) -> some View {
        if showScrollTop, !firstId.isEmpty {
            Button {
                withAnimation { proxy.scrollTo(firstId, anchor: .top) }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(NCBrandColor.shared.customer))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("_mail_scroll_top_", comment: ""))
            .padding(.bottom, 70)
            .transition(.opacity)
        }
    }

    private func updateShieldScrollTop(_ offset: CGFloat) {
        let visible = offset > 120
        if visible != showScrollTop {
            withAnimation(.easeInOut(duration: 0.25)) {
                showScrollTop = visible
            }
        }
    }

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
            SouveraStateView(state: .loading)
        case let .error(message):
            SouveraStateView(state: .error(message: message), retry: { Task { await viewModel.loadAll() } })
        case let .success(entries):
            let filtered = viewModel.filteredSpam()
            if filtered.isEmpty {
                SouveraStateView(state: .empty(
                    title: NSLocalizedString("_shield_empty_", comment: ""),
                    systemImage: "tray"
                ))
            } else {
                ScrollViewReader { proxy in
                    List(filtered) { entry in
                        Button {
                            detailEntry = entry
                        } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle().fill(Color(.secondarySystemBackground)).frame(width: 36, height: 36)
                                    Image(systemName: "envelope.badge.shield.half.filled")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.orange.opacity(0.75))
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.subject.isEmpty ? entry.sender : entry.subject)
                                        .font(.subheadline).lineLimit(1)
                                    Text("\(entry.sender) · \(entry.time.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
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
                    .scrollTopObserver { updateShieldScrollTop($0) }
                    .overlay(alignment: .bottom) {
                        scrollTopButton(proxy: proxy, firstId: filtered.first?.id ?? "")
                    }
                    .refreshable { await viewModel.loadAll() }
                }
            }
        }
    }

    @ViewBuilder
    private func genericList(state: ShieldUiState<[ShieldGenericEntry]>, kind: ShieldApi.QuarantineKind) -> some View {
        switch state {
        case .loading:
            SouveraStateView(state: .loading)
        case let .error(message):
            SouveraStateView(state: .error(message: message), retry: { Task { await viewModel.loadAll() } })
        case let .success(entries):
            let filtered = viewModel.filteredGeneric(state)
            if filtered.isEmpty {
                SouveraStateView(state: .empty(
                    title: NSLocalizedString("_shield_empty_", comment: ""),
                    systemImage: "tray"
                ))
            } else {
                let iconName = kind == .virus ? "shield.slash" : "doc.fill"
                let iconTint: Color = kind == .virus ? .red.opacity(0.7) : .blue.opacity(0.7)
                ScrollViewReader { proxy in
                    List(filtered) { entry in
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().fill(Color(.secondarySystemBackground)).frame(width: 36, height: 36)
                                Image(systemName: iconName)
                                    .font(.system(size: 15))
                                    .foregroundStyle(iconTint)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.displayTitle).font(.subheadline).lineLimit(1)
                                Text(entry.displaySubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
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
                    .scrollTopObserver { updateShieldScrollTop($0) }
                    .overlay(alignment: .bottom) {
                        scrollTopButton(proxy: proxy, firstId: filtered.first?.id ?? "")
                    }
                    .refreshable { await viewModel.loadAll() }
                }
            }
        }
    }

    // MARK: - Whitelist / Blacklist

    @ViewBuilder
    private func listSection(kind: ShieldApi.ListKind, state: ShieldUiState<[String]>) -> some View {
        switch state {
        case .loading:
            SouveraStateView(state: .loading)
        case let .error(message):
            SouveraStateView(state: .error(message: message), retry: { Task { await viewModel.loadAll() } })
        case let .success(entries):
            let iconTint: Color = kind == .whitelist ? .green.opacity(0.7) : .red.opacity(0.7)
            ScrollViewReader { proxy in
                List {
                    ForEach(entries, id: \.self) { entry in
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().fill(Color(.secondarySystemBackground)).frame(width: 36, height: 36)
                                Image(systemName: kind == .whitelist ? "checkmark.shield" : "shield.slash")
                                    .font(.system(size: 15))
                                    .foregroundStyle(iconTint)
                            }
                            Text(entry).font(.subheadline)
                        }
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
                .scrollTopObserver { updateShieldScrollTop($0) }
                .overlay(alignment: .bottom) {
                    scrollTopButton(proxy: proxy, firstId: entries.first ?? "")
                }
                .refreshable { await viewModel.loadAll() }
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
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.green.opacity(0.15)).frame(width: 56, height: 56)
                Image(systemName: "tray.and.arrow.up")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .padding(.top, 6)

            Text(NSLocalizedString("_shield_release_", comment: "") + "?")
                .font(.headline)

            VStack(alignment: .leading, spacing: 3) {
                Text(request.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                if !request.sender.isEmpty {
                    Text(request.sender)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

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
                    Label(NSLocalizedString("_shield_release_whitelist_", comment: ""), systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button(NSLocalizedString("_cancel_", comment: ""), role: .cancel) {
                dismiss()
            }
            .font(.subheadline)
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }
}
