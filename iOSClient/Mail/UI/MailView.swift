// SPDX-FileCopyrightText: 2026 Host-On Service Provider GmbH (Souvera)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// SwiftUI surface for the native mail client: folder list → message list → detail → compose.
// Mirrors android mail/ui Compose screens.

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import WebKit

struct MailView: View {
    @StateObject private var viewModel = MailViewModel()
    @State private var detailMoveTarget: ([MailMessage], [Mailbox])?
    @State private var blacklistTarget: [MailMessage]?
    @State private var showNewFolderSheet = false
    @State private var searchQuery = ""
    @State private var searchActive = false
    @State private var searchDebounceTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .onChange(of: searchQuery) { _, newValue in
                    scheduleSearch(newValue)
                }
                .onChange(of: viewModel.route) { _, newRoute in
                    // Zurück aus einer Detailansicht, die aus der Suche
                    // geöffnet wurde: Suchfeld + Ergebnisliste wieder zeigen.
                    searchActive = (newRoute == .search)
                }
                .toolbar {
                    toolbar
                }
        }
        .confirmationDialog(
            NSLocalizedString("_mail_blacklist_confirm_title_", comment: ""),
            isPresented: Binding(
                get: { blacklistTarget != nil },
                set: { if !$0 { blacklistTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: blacklistTarget
        ) { messages in
            Button(NSLocalizedString("_mail_blacklist_short_", comment: ""), role: .destructive) {
                blacklistTarget = nil
                Task { await viewModel.blacklistSenders(messages) }
            }
            Button(NSLocalizedString("_mail_blacklist_and_delete_", comment: ""), role: .destructive) {
                blacklistTarget = nil
                Task { await viewModel.blacklistAndDelete(messages) }
            }
            Button(NSLocalizedString("_cancel_", comment: ""), role: .cancel) {
                blacklistTarget = nil
            }
        } message: { messages in
            Text(blacklistMessage(for: messages))
        }
        .onAppear {
            viewModel.start()
            // P62g: JEDER Modul-Eintritt zieht die offene Mailbox nach -
            // neue Mails erscheinen sofort statt erst mit dem Auto-Refresh.
            viewModel.refreshOnEntry()
        }
        .souveraCacheBanner(active: $viewModel.cacheBannerActive)
        .overlay(alignment: .bottom) {
            if viewModel.isSending {
                // Solange die Mail gesendet wird: Info-Overlay unten (wie der
                // "Email gesendet"-Banner), verschwindet beim Abschluss.
                HStack(spacing: 8) {
                    ProgressView()
                    Text(NSLocalizedString("_mail_sending_", comment: ""))
                        .font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.horizontal)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if viewModel.isFetchingMail {
                // Erstladung ohne Cache bzw. Scroll-Nachladen: die Übersicht
                // wächst bereits sichtbar, das Overlay zeigt den laufenden
                // Abruf an (wie "Mail wird gesendet…").
                HStack(spacing: 8) {
                    ProgressView()
                    Text(NSLocalizedString("_mail_fetching_", comment: ""))
                        .font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.horizontal)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let feedback = viewModel.actionFeedback ?? viewModel.sendFeedback {
                MailSendBanner(feedback: feedback)
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: viewModel.sendFeedback) { _, feedback in
            guard feedback != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                viewModel.sendFeedback = nil
            }
        }
        .onChange(of: viewModel.actionFeedback) { _, feedback in
            guard feedback != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                viewModel.actionFeedback = nil
            }
        }
        .sheet(item: Binding(
            get: { viewModel.composeContext },
            set: { viewModel.composeContext = $0 }
        )) { context in
            MailComposeView(viewModel: viewModel, context: context)
        }
        .sheet(isPresented: $showNewFolderSheet) {
            MailNewFolderSheet(viewModel: viewModel)
        }
        .sheet(item: Binding(
            get: { detailMoveTarget.map { MoveSheetState(messages: $0.0, mailboxes: $0.1) } },
            set: { if $0 == nil { detailMoveTarget = nil } }
        )) { state in
            MailMovePickerView(
                viewModel: viewModel,
                title: state.messages.first?.subject ?? "",
                mailboxes: state.mailboxes,
                onSelect: { target in
                    viewModel.move(state.messages, to: target)
                    viewModel.back()
                    detailMoveTarget = nil
                }
            )
        }
    }

    private var navigationTitle: String {
        switch viewModel.route {
        case .folders: return NSLocalizedString("_mail_", comment: "")
        case .messages: return "" 
        case .detail: return ""
        case .compose: return NSLocalizedString("_mail_compose_", comment: "")
        case .search: return NSLocalizedString("_mail_search_", comment: "")
        }
    }

    private var isFolders: Bool {
        if case .folders = viewModel.route { return true }
        return false
    }

    private func blacklistMessage(for messages: [MailMessage]) -> String {
        let addresses = Array(Set(messages.map { $0.fromAddress }
            .filter { !$0.isEmpty }))
        if addresses.isEmpty { return "" }
        let preview = addresses.prefix(3).joined(separator: ", ")
        if addresses.count > 3 {
            return String(format: NSLocalizedString("_mail_blacklist_confirm_multi_", comment: ""), preview, addresses.count)
        }
        return preview
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !isFolders {
            ToolbarItem(placement: .topBarLeading) {
                Button { viewModel.back() } label: {
                    Image(systemName: "chevron.backward")
                        .frame(width: 28, height: 28)
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
        }
        if case let .messages(mailbox) = viewModel.route {
            // Ordnername als normale Schrift linksbündig - als .principal-
            // Element (keine Button-Kapsel), volle Restbreite zwischen
            // Zurück-Pfeil und Trailing-Items, damit nichts abgeschnitten wird.
            ToolbarItem(placement: .principal) {
                HStack(spacing: 0) {
                    Text(mailbox.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)
            }
        }
        if case let .detail(message) = viewModel.route {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Schnellaktion Antworten + EIN Sammelmenü für alles Weitere -
                // mehrere Trailing-Items würden von iOS in ein automatisches
                // "..."-Menü gekippt (Verschachtelung "..." > "...").
                Button {
                    viewModel.startCompose(mode: .reply, message: message)
                } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                }
                .accessibilityLabel(NSLocalizedString("_mail_reply_", comment: ""))
                Menu {
                    Button {
                        viewModel.startCompose(mode: .replyAll, message: message)
                    } label: {
                        Label(NSLocalizedString("_mail_reply_all_", comment: ""), systemImage: "arrowshape.turn.up.left.2")
                    }
                    Button {
                        viewModel.startCompose(mode: .forward, message: message)
                    } label: {
                        Label(NSLocalizedString("_mail_forward_", comment: ""), systemImage: "arrowshape.turn.up.right")
                    }
                    Button {
                        Task { await viewModel.setRead([message], !message.isRead) }
                    } label: {
                        Label(message.isRead
                              ? NSLocalizedString("_mail_mark_unread_", comment: "")
                              : NSLocalizedString("_mail_mark_read_", comment: ""),
                              systemImage: message.isRead ? "envelope" : "envelope.open")
                    }
                    Button {
                        detailMoveTarget = ([message], viewModel.availableMailboxes.filter { $0.accountId == message.accountId })
                    } label: {
                        Label(NSLocalizedString("_mail_move_", comment: ""), systemImage: "folder")
                    }
                    Button {
                        viewModel.toggleFlagged(message)
                    } label: {
                        Label(NSLocalizedString("_mail_flag_", comment: ""), systemImage: message.isFlagged ? "flag.slash" : "flag")
                    }
                    Button {
                        blacklistTarget = [message]
                    } label: {
                        Label(NSLocalizedString("_mail_blacklist_sender_", comment: ""), systemImage: "exclamationmark.shield")
                    }
                    Button(role: .destructive) {
                        viewModel.delete([message])
                    } label: {
                        Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        if isFolders {
            ToolbarItem(placement: .topBarLeading) {
                AutoRefreshRingView(viewModel: viewModel)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { searchActive = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel(NSLocalizedString("_mail_search_", comment: ""))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewFolderSheet = true } label: { Image(systemName: "folder.badge.plus") }
                    .accessibilityLabel(NSLocalizedString("_mail_new_folder_", comment: ""))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if searchActive {
            mailSearchField
        } else {
            switch viewModel.route {
            case .folders:
                // Cache-first: MailFolderListView zeigt den gecachten
                // Postfach-Stand sofort (eigener Spinner nur ohne Cache),
                // der Live-Load ersetzt ihn im Hintergrund.
                MailFolderListView(viewModel: viewModel)
            case .messages, .detail:
                // P62b: EINE Listen-Instanz für beide Zustände - die Detailansicht
                // liegt als deckendes Overlay darüber. Nur so bleibt die
                // SwiftUI-Identität der Liste erhalten und die Scrollposition
                // überlebt den Detail-Roundtrip (getrennte Branches erzeugten
                // jeweils NEUE Instanzen -> Scroll ging verloren).
                ZStack {
                    MailMessageListView(viewModel: viewModel, toolbarActive: !viewModel.route.isDetail)
                    if let message = viewModel.route.detailMessage {
                        MailDetailView(viewModel: viewModel, message: message)
                    }
                }
            case .compose:
                MailComposeView(viewModel: viewModel, context: MailComposeContext(mode: .new, message: nil, to: [], cc: [], subject: "", quoteBody: "", preAttachments: []))
            case .search:
                mailSearchResults
            }
        }
    }

    /// Suchfeld + Inline-Suchergebnisse (ausgelöst per Such-Button im Header).
    private var mailSearchField: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(NSLocalizedString("_mail_search_hint_", comment: ""), text: $searchQuery)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                Button(NSLocalizedString("_cancel_", comment: "")) {
                    searchActive = false
                    searchQuery = ""
                    viewModel.searchResults = .success([])
                }
            }
            .padding(12)
            Divider()
            mailSearchResults
        }
    }

    /// Inline-Suchergebnisse.
    @ViewBuilder
    private var mailSearchResults: some View {
        switch viewModel.searchResults {
        case .loading:
            Spacer()
            ProgressView()
            Spacer()
        case let .error(message):
            Spacer()
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            Spacer()
        case let .success(items):
            if items.isEmpty {
                Spacer()
                Text(NSLocalizedString("_mail_search_no_results_", comment: ""))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    Section {
                        ForEach(items) { message in
                            Button {
                                // Suchliste ausblenden, damit die Detailansicht
                                // sichtbar wird (Route .detail liegt sonst dahinter).
                                searchActive = false
                                viewModel.openMessage(message, fromSearch: true)
                            } label: {
                                MailRow(message: message)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { viewModel.delete([message]) } label: {
                                    Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash")
                                }
                                Button { viewModel.toggleFlagged(message) } label: {
                                    Label(NSLocalizedString("_mail_flag_", comment: ""), systemImage: "flag")
                                }.tint(.orange)
                            }
                            .swipeActions(edge: .leading) {
                                Button { viewModel.startCompose(mode: .reply, message: message) } label: {
                                    Label(NSLocalizedString("_mail_reply_", comment: ""), systemImage: "arrowshape.turn.up.left")
                                }
                                .tint(.green)
                            }
                        }
                    } footer: {
                        Text(NSLocalizedString("_mail_search_includes_attachments_", comment: ""))
                            .font(.caption)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    /// Debounced die JMAP-Serversuche anstoßen.
    private func scheduleSearch(_ query: String) {
        searchDebounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            viewModel.searchResults = .success([])
            return
        }
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await viewModel.search(trimmed)
        }
    }
}

/// Transient overlay shown after sending a message (success or failure).
struct MailSendBanner: View {
    let feedback: MailSendFeedback

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: feedback.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(feedback.success ? .green : .red)
            Text(feedback.message)
                .font(.subheadline)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 6)
    }
}

private struct MailFolderListView: View {
    @ObservedObject var viewModel: MailViewModel
    @State private var showScrollTop = false
    @State private var renameTarget: Mailbox?
    @State private var renameText = ""
    @State private var deleteTarget: Mailbox?

    var body: some View {
        VStack(spacing: 0) {
            switch viewModel.mailboxes {
            case .loading:
                Spacer()
                ProgressView()
                Spacer()
            case let .error(message):
                VStack(spacing: 12) {
                    Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(NSLocalizedString("_mail_retry_", comment: "")) { viewModel.retry() }
                        .buttonStyle(.bordered)
                }
                .padding()
            case let .success(boxes):
                folderList(boxes)
            }
        }
    }

    @ViewBuilder
    private func folderList(_ boxes: [Mailbox]) -> some View {
        folderListContent(boxes)
    }

    private func folderListContent(_ boxes: [Mailbox]) -> some View {
        ScrollViewReader { proxy in
        List {
            ForEach(groups(boxes)) { group in
                Section {
                    if viewModel.collapsedGroupIds.contains(group.id) {
                        EmptyView()
                    } else {
                        // Flat row list (instead of a nested VStack) so every
                        // folder and subfolder gets a separator line.
                        ForEach(visibleRows(for: viewModel.mailboxTree(for: group.folders))) { row in
                            MailboxTreeRow(
                                viewModel: viewModel,
                                node: row.node,
                                depth: row.depth,
                                onRename: { mailbox in
                                    renameText = mailbox.name
                                    renameTarget = mailbox
                                },
                                onDelete: { mailbox in
                                    deleteTarget = mailbox
                                }
                            )
                        }
                    }
                } header: {
                    Button {
                        toggleGroup(group.id)
                    } label: {
                        HStack {
                            Image(systemName: viewModel.collapsedGroupIds.contains(group.id) ? "chevron.right" : "chevron.down")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(group.label)
                            Spacer()
                            if group.totalUnread > 0 { Text("\(group.totalUnread)").foregroundStyle(.secondary) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollPosition(id: $viewModel.folderScrollPosition, anchor: .top)
        .refreshable { await viewModel.loadMailboxes() }
        .overlay(alignment: .bottom) {
            let firstRowId = firstVisibleRowId(boxes)
            if let firstId = firstRowId {
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
                .padding(.bottom, 16)
                .opacity(showScrollTop ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: showScrollTop)
            }
        }
        .scrollTopObserver { offset in
            let visible = offset > 120
            if visible != showScrollTop {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showScrollTop = visible
                }
            }
        }
        .alert(NSLocalizedString("_mail_rename_folder_", comment: ""), isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField(NSLocalizedString("_mail_folder_name_", comment: ""), text: $renameText)
            Button(NSLocalizedString("_ok_", comment: "")) {
                if let target = renameTarget {
                    let newName = renameText.trimmingCharacters(in: .whitespaces)
                    if !newName.isEmpty {
                        Task { await viewModel.renameMailbox(target, to: newName) }
                    }
                }
                renameTarget = nil
            }
            Button(NSLocalizedString("_cancel_", comment: ""), role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            NSLocalizedString("_mail_delete_folder_", comment: ""),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("_mail_delete_folder_with_mails_", comment: ""), role: .destructive) {
                if let target = deleteTarget {
                    Task { await viewModel.deleteMailbox(target, removeEmails: true) }
                }
                deleteTarget = nil
            }
            Button(NSLocalizedString("_mail_delete_folder_only_", comment: ""), role: .destructive) {
                if let target = deleteTarget {
                    Task { await viewModel.deleteMailbox(target, removeEmails: false) }
                }
                deleteTarget = nil
            }
            Button(NSLocalizedString("_cancel_", comment: ""), role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget.map { String(format: NSLocalizedString("_mail_delete_folder_confirm_", comment: ""), $0.displayName) } ?? "")
        }
        }
    }

    /// Erste sichtbare Ordnerzeile (erste aufgeklappte Gruppe).
    private func firstVisibleRowId(_ boxes: [Mailbox]) -> String? {
        for group in groups(boxes) {
            if viewModel.collapsedGroupIds.contains(group.id) { continue }
            if let first = visibleRows(for: viewModel.mailboxTree(for: group.folders)).first {
                return first.id
            }
        }
        return nil
    }

    private struct VisibleTreeRow: Identifiable {
        let node: MailboxNode
        let depth: Int
        var id: String { node.id }
    }

    /// Flattens the visible (expanded) tree into a row list.
    private func visibleRows(for nodes: [MailboxNode], depth: Int = 0) -> [VisibleTreeRow] {
        var rows: [VisibleTreeRow] = []
        for node in nodes {
            rows.append(VisibleTreeRow(node: node, depth: depth))
            if viewModel.expandedMailboxIds.contains(node.mailbox.id) {
                rows.append(contentsOf: visibleRows(for: node.children, depth: depth + 1))
            }
        }
        return rows
    }

    private struct FolderGroup: Identifiable {
        let id: String
        let label: String
        let folders: [Mailbox]
        let totalUnread: Int
    }

    /// Personal group first, then one collapsible group per shared owner.
    private func groups(_ boxes: [Mailbox]) -> [FolderGroup] {
        let personal = boxes.filter { $0.namespace == .personal }
        var result: [FolderGroup] = []
        if !personal.isEmpty {
            let label = viewModel.ownEmailLabel.isEmpty
                ? NSLocalizedString("_mail_mailboxes_", comment: "")
                : viewModel.ownEmailLabel
            result.append(FolderGroup(
                id: "personal",
                label: label,
                folders: personal,
                totalUnread: personal.reduce(0) { $0 + $1.unreadCount }
            ))
        }
        let shared = boxes.filter { $0.namespace != .personal }
        let byOwner = Dictionary(grouping: shared) { $0.ownerIdentity ?? $0.path.components(separatedBy: "/").first ?? "?" }
        for owner in byOwner.keys.sorted() {
            let folders = byOwner[owner] ?? []
            result.append(FolderGroup(
                id: "shared_\(owner)",
                label: "\(NSLocalizedString("_mail_shared_prefix_", comment: "")) \(owner)",
                folders: folders,
                totalUnread: folders.reduce(0) { $0 + $1.unreadCount }
            ))
        }
        return result
    }

    private func toggleGroup(_ id: String) {
        if viewModel.collapsedGroupIds.contains(id) {
            viewModel.collapsedGroupIds.remove(id)
        } else {
            viewModel.collapsedGroupIds.insert(id)
        }
    }
}

/// One collapsible row of the mailbox tree: folders with children get a
/// disclosure chevron and start collapsed; unread counts sum up children.
/// Basis-Zeile des Ordnerbaums (Chevron, Icon, Name, Unread-Zähler) -
/// gemeinsam genutzt von Ordnerliste, Verschieben-Fenster und
/// Positionsauswahl beim Anlegen.
private struct MailboxTreeRowBase: View {
    let node: MailboxNode
    let depth: Int
    let isExpanded: Bool
    var showsUnread: Bool = true
    let onToggleExpand: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if node.children.isEmpty {
                Color.clear.frame(width: 28, height: 1)
            } else {
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button(action: onTap) {
                HStack(spacing: 8) {
                    Image(systemName: icon(for: node.mailbox.kind))
                        .font(.body)
                        .foregroundStyle(Color(NCBrandColor.shared.customer))
                        .frame(width: 24)
                    Text(node.mailbox.displayName)
                        .font(.body)
                    Spacer()
                    if showsUnread {
                        // Immer die EIGENEN Ungelesenen des Ordners zeigen -
                        // die Summe der Unterordner steht in deren Zeilen,
                        // sobald der Ordner aufgeklappt ist.
                        if node.mailbox.unreadCount > 0 {
                            Text("\(node.mailbox.unreadCount)").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, CGFloat(depth) * 14)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func icon(for kind: MailboxKind) -> String {
        switch kind {
        case .inbox: return "tray.fill"
        case .sent: return "paperplane.fill"
        case .drafts: return "doc.fill"
        case .trash: return "trash.fill"
        case .junk: return "xmark.bin.fill"
        case .regular: return "folder.fill"
        }
    }
}

/// Ordnerliste-Zeile: öffnet den Ordner; Swipe bietet Umbenennen/Löschen
/// (nur wenn die JMAP-Rechte mayRename/mayDelete es erlauben).
private struct MailboxTreeRow: View {
    @ObservedObject var viewModel: MailViewModel
    let node: MailboxNode
    let depth: Int
    let onRename: (Mailbox) -> Void
    let onDelete: (Mailbox) -> Void

    var body: some View {
        MailboxTreeRowBase(
            node: node,
            depth: depth,
            isExpanded: viewModel.expandedMailboxIds.contains(node.mailbox.id),
            onToggleExpand: {
                if viewModel.expandedMailboxIds.contains(node.mailbox.id) {
                    viewModel.expandedMailboxIds.remove(node.mailbox.id)
                } else {
                    viewModel.expandedMailboxIds.insert(node.mailbox.id)
                }
            },
            onTap: { viewModel.openMailbox(node.mailbox) }
        )
        .swipeActions(edge: .trailing) {
            if node.mailbox.mayRename {
                Button {
                    onRename(node.mailbox)
                } label: {
                    Label(NSLocalizedString("_mail_rename_folder_", comment: ""), systemImage: "pencil")
                }
                .tint(.blue)
            }
            if node.mailbox.mayDelete {
                Button(role: .destructive) {
                    onDelete(node.mailbox)
                } label: {
                    Label(NSLocalizedString("_mail_delete_folder_", comment: ""), systemImage: "trash")
                }
            }
        }
    }
}

private struct MailMessageListView: View {
    @ObservedObject var viewModel: MailViewModel
    /// false = Liste ist unter der Detailansicht versteckt gemountet; ihre
    /// Toolbar-Items (Bearbeiten/Sortierung/"Neue Mail") dürfen dann nicht
    /// in der Einzelansicht erscheinen.
    var toolbarActive: Bool = true
    @State private var editing = false
    @State private var selected = Set<String>()
    @State private var moveTarget: ([MailMessage], [Mailbox])?
    @State private var showScrollTop = false
    @State private var scrollOffset: CGFloat = 0
    @State private var blacklistTarget: [MailMessage]?
    @State private var showEmptyTrashConfirm = false

    var body: some View {
        withDialogs
    }

    /// Stufe 1: Basis-Liste inkl. Overlay/Sheet/Toolbar/Aktionsleiste.
    private var baseContent: some View {
        VStack(spacing: 0) {
            if let notice = viewModel.offlineNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            switch viewModel.messages {
            case .loading:
                // Kein Ladekreis: Der Fortschritt läuft über das Overlay
                // "Mail-Abruf läuft…" und die Liste wächst progressiv nach.
                Spacer(minLength: 0)
            case let .error(message):
                Spacer()
                VStack(spacing: 12) {
                    Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(NSLocalizedString("_mail_retry_", comment: "")) { viewModel.retry() }
                        .buttonStyle(.bordered)
                }
                .padding()
                Spacer()
            case let .success(items):
                messageList(items: items)
            }
        }
        .sheet(item: moveSheetBinding) { state in
            MailMovePickerView(
                viewModel: viewModel,
                title: state.messages.count == 1
                    ? (state.messages.first?.subject.isEmpty == false ? state.messages.first!.subject : NSLocalizedString("_mail_no_subject_", comment: ""))
                    : "\(state.messages.count)",
                mailboxes: state.mailboxes,
                onSelect: { target in
                    viewModel.move(state.messages, to: target)
                    editing = false
                    selected.removeAll()
                    moveTarget = nil
                }
            )
        }
        .toolbar {
            if toolbarActive, editing {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(NSLocalizedString("_done_", comment: "")) {
                        editing = false
                        selected.removeAll()
                    }
                }
            } else if toolbarActive {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        if !isEmptyList {
                            Button { editing = true } label: {
                                Label(NSLocalizedString("_edit_", comment: ""), systemImage: "checklist")
                            }
                        }
                        Menu {
                            ForEach(MailSortOrder.allCases) { order in
                                Button {
                                    viewModel.sortOrder = order
                                } label: {
                                    if viewModel.sortOrder == order {
                                        Label(NSLocalizedString(order.titleKey, comment: ""), systemImage: "checkmark")
                                    } else {
                                        Text(NSLocalizedString(order.titleKey, comment: ""))
                                    }
                                }
                            }
                        } label: {
                            Label(NSLocalizedString("_mail_sort_", comment: ""), systemImage: "arrow.up.arrow.down")
                        }
                        if viewModel.currentMailbox?.kind == .trash {
                            Button {
                                showEmptyTrashConfirm = true
                            } label: {
                                Label(NSLocalizedString("_mail_trash_empty_", comment: ""), systemImage: "trash.slash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(NSLocalizedString("_mail_more_", comment: ""))
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { viewModel.startCompose(mode: .new) } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel(NSLocalizedString("_mail_compose_", comment: ""))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editing && !selected.isEmpty {
                HStack(spacing: 0) {
                    Button {
                        let messages = selectedMessages
                        Task {
                            await viewModel.setRead(messages, true)
                            selected.removeAll()
                            editing = false
                        }
                    } label: {
                        selectionAction(icon: "envelope.open", label: NSLocalizedString("_mail_mark_read_", comment: ""))
                    }
                    Button {
                        let messages = selectedMessages
                        Task {
                            await viewModel.setRead(messages, false)
                            selected.removeAll()
                            editing = false
                        }
                    } label: {
                        selectionAction(icon: "envelope", label: NSLocalizedString("_mail_mark_unread_", comment: ""))
                    }
                    Button {
                        let messages = selectedMessages
                        if let first = messages.first {
                            moveTarget = (messages, viewModel.availableMailboxes.filter { $0.accountId == first.accountId })
                        }
                    } label: {
                        selectionAction(icon: "folder", label: NSLocalizedString("_mail_move_", comment: ""))
                    }
                    Button(role: .destructive) {
                        let messages = selectedMessages
                        viewModel.delete(messages)
                        selected.removeAll()
                        editing = false
                    } label: {
                        selectionAction(icon: "trash", label: NSLocalizedString("_delete_", comment: ""))
                    }
                    Button {
                        blacklistTarget = selectedMessages
                    } label: {
                        selectionAction(icon: "exclamationmark.shield", label: NSLocalizedString("_mail_blacklist_short_", comment: ""))
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(.bar)
            }
        }
    }

    /// Stufe 2: Verhalten + Dialoge.
    private var withDialogs: some View {
        baseContent
        .onChange(of: editing) { _, value in
            if !value { selected.removeAll() }
        }
        .confirmationDialog(
            NSLocalizedString("_mail_trash_empty_", comment: ""),
            isPresented: $showEmptyTrashConfirm,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("_mail_trash_empty_", comment: ""), role: .destructive) {
                Task { await viewModel.emptyTrash() }
            }
            Button(NSLocalizedString("_cancel_", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("_mail_trash_empty_confirm_", comment: ""))
        }
        .confirmationDialog(
            NSLocalizedString("_mail_blacklist_confirm_title_", comment: ""),
            isPresented: Binding(
                get: { blacklistTarget != nil },
                set: { if !$0 { blacklistTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: blacklistTarget
        ) { messages in
            Button(NSLocalizedString("_mail_blacklist_short_", comment: ""), role: .destructive) {
                blacklistTarget = nil
                Task { await viewModel.blacklistSenders(messages) }
            }
            Button(NSLocalizedString("_mail_blacklist_and_delete_", comment: ""), role: .destructive) {
                blacklistTarget = nil
                Task { await viewModel.blacklistAndDelete(messages) }
                selected.removeAll()
                editing = false
            }
            Button(NSLocalizedString("_cancel_", comment: ""), role: .cancel) {
                blacklistTarget = nil
            }
        } message: { messages in
            Text(blacklistConfirmMessage(for: messages))
        }
    }

    /// Die Nachrichtenliste als eigene Funktion (hält den Body klein).
    @ViewBuilder
    private func messageList(items: [MailMessage]) -> some View {
        let sorted = viewModel.sortMessages(items)
        ScrollViewReader { proxy in
            List {
                ForEach(sorted) { message in
                    row(message)
                        .id(message.id)
                }
                // Sentinel: beim Erreichen des Listenendes ältere Mails
                // nachladen (kein Paging-UI, nahtloses Wachsen). Unsichtbarer
                // Trigger ohne Ladekreis - der Fortschritt ist über das
                // Overlay "Mail-Abruf läuft…" sichtbar.
                if viewModel.hasMoreMessages && !editing {
                    Color.clear
                        .frame(height: 1)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .onAppear { viewModel.loadMore() }
                }
            }
            .listStyle(.plain)
            // Die Liste bleibt beim Öffnen einer Mail gemountet (ZStack in
            // content) - die Scrollposition bleibt dadurch automatisch
            // erhalten, ohne Anchor-Restore.
            .refreshable { await viewModel.refreshMessages() }
            .overlay(alignment: .bottom) {
                if let firstId = sorted.first?.id {
                    scrollTopButton(proxy: proxy, firstId: firstId)
                        .padding(.bottom, 84)
                        .opacity(showScrollTop ? 1 : 0)
                        .animation(.easeInOut(duration: 0.25), value: showScrollTop)
                }
            }
            .scrollTopObserver { offset in
                updateScrollTop(offset: offset)
            }
        }
    }

    private var moveSheetBinding: Binding<MoveSheetState?> {
        Binding(
            get: { moveTarget.map { MoveSheetState(messages: $0.0, mailboxes: $0.1) } },
            set: { if $0 == nil { moveTarget = nil } }
        )
    }

    private func blacklistConfirmMessage(for messages: [MailMessage]) -> String {
        let addresses = Array(Set(messages.map { $0.fromAddress }
            .filter { !$0.isEmpty }))
        if addresses.isEmpty { return "" }
        let preview = addresses.prefix(3).joined(separator: ", ")
        if addresses.count > 3 {
            return String(format: NSLocalizedString("_mail_blacklist_confirm_multi_", comment: ""), preview, addresses.count)
        }
        return preview
    }

    private func selectionAction(icon: String, label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
            Text(label).font(.caption2).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }

    private var selectedMessages: [MailMessage] {
        if case let .success(items) = viewModel.messages {
            return items.filter { selected.contains($0.id) }
        }
        return []
    }

    private var isEmptyList: Bool {
        if case let .success(items) = viewModel.messages { return items.isEmpty }
        return true
    }

    private func updateScrollTop(offset: CGFloat) {
        let visible = offset > 120
        if visible != showScrollTop {
            withAnimation(.easeInOut(duration: 0.25)) {
                showScrollTop = visible
            }
        }
    }

    /// Glass-Look-Scroll-to-top-Button (Fade über `showScrollTop`).
    @ViewBuilder
    private func scrollTopButton(proxy: ScrollViewProxy, firstId: String) -> some View {
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
    }

    @ViewBuilder
    private func row(_ message: MailMessage) -> some View {
        if editing {
            Button {
                if selected.contains(message.id) {
                    selected.remove(message.id)
                } else {
                    selected.insert(message.id)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected.contains(message.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(Color(NCBrandColor.shared.customer))
                    MailRowContent(message: message)
                }
            }
            .buttonStyle(.plain)
        } else {
            Button { viewModel.openMessage(message) } label: {
                MailRow(message: message, showsRecipient: viewModel.currentMailbox?.kind == .sent)
            }
            .buttonStyle(.plain)
            // P68m: Langer Druck = Detail-"..."-Menü (ohne Antworten):
            // Weiterleiten, Gelesen/Ungelesen, Markieren, Absender-Blacklist.
            // Blacklist nutzt den vorhandenen Bestätigungsdialog.
            .contextMenu {
                Button {
                    viewModel.startCompose(mode: .forward, message: message)
                } label: {
                    Label(NSLocalizedString("_mail_forward_", comment: ""), systemImage: "arrowshape.turn.up.right")
                }
                Button {
                    Task { await viewModel.setRead([message], !message.isRead) }
                } label: {
                    Label(message.isRead
                          ? NSLocalizedString("_mail_mark_unread_", comment: "")
                          : NSLocalizedString("_mail_mark_read_", comment: ""),
                          systemImage: message.isRead ? "envelope" : "envelope.open")
                }
                Button {
                    viewModel.toggleFlagged(message)
                } label: {
                    Label(NSLocalizedString("_mail_flag_", comment: ""), systemImage: message.isFlagged ? "flag.slash" : "flag")
                }
                Button {
                    blacklistTarget = [message]
                } label: {
                    Label(NSLocalizedString("_mail_blacklist_sender_", comment: ""), systemImage: "exclamationmark.shield")
                }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { viewModel.delete([message]) } label: {
                    Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash")
                }
                Button {
                    moveTarget = ([message], viewModel.availableMailboxes.filter { $0.accountId == message.accountId })
                } label: {
                    Label(NSLocalizedString("_mail_move_", comment: ""), systemImage: "folder")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .leading) {
                Button { viewModel.startCompose(mode: .reply, message: message) } label: {
                    Label(NSLocalizedString("_mail_reply_", comment: ""), systemImage: "arrowshape.turn.up.left")
                }
                .tint(.green)
            }
        }
    }
}

private struct MoveSheetState: Identifiable, Equatable {
    let messages: [MailMessage]
    let mailboxes: [Mailbox]
    var id: String { messages.map(\.id).joined(separator: "|") }

    static func == (lhs: MoveSheetState, rhs: MoveSheetState) -> Bool {
        lhs.id == rhs.id
    }
}

private struct MailMovePickerView: View {
    @ObservedObject var viewModel: MailViewModel
    let title: String
    let mailboxes: [Mailbox]
    let onSelect: (Mailbox) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows(for: viewModel.mailboxTree(for: mailboxes))) { row in
                    MailboxTreeRowBase(
                        node: row.node,
                        depth: row.depth,
                        isExpanded: expanded.contains(row.node.mailbox.id),
                        onToggleExpand: { toggle(row.node.mailbox.id) },
                        onTap: {
                            onSelect(row.node.mailbox)
                            dismiss()
                        }
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
            }
        }
    }

    private struct TreeRow: Identifiable {
        let node: MailboxNode
        let depth: Int
        var id: String { node.id }
    }

    private func rows(for nodes: [MailboxNode], depth: Int = 0) -> [TreeRow] {
        var result: [TreeRow] = []
        for node in nodes {
            result.append(TreeRow(node: node, depth: depth))
            if expanded.contains(node.mailbox.id) {
                result.append(contentsOf: rows(for: node.children, depth: depth + 1))
            }
        }
        return result
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }
}

/// Sheet zum Anlegen eines Ordners: Name + Position (Root oder
/// Unterordner im Baum).
private struct MailNewFolderSheet: View {
    @ObservedObject var viewModel: MailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var parent: Mailbox?
    @State private var expanded: Set<String> = []

    private var personalFolders: [Mailbox] {
        if case let .success(boxes) = viewModel.mailboxes {
            return boxes.filter { $0.namespace == .personal && $0.jmapId != nil }
        }
        return []
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("_mail_folder_name_", comment: ""), text: $name)
                        .autocorrectionDisabled()
                }
                Section(NSLocalizedString("_mail_folder_position_", comment: "")) {
                    Button {
                        parent = nil
                    } label: {
                        HStack {
                            Image(systemName: "tray.full")
                                .foregroundStyle(Color(NCBrandColor.shared.customer))
                            Text(NSLocalizedString("_mail_folder_position_root_", comment: ""))
                            Spacer()
                            if parent == nil {
                                Image(systemName: "checkmark")
                                    .font(.subheadline)
                                    .foregroundStyle(Color(NCBrandColor.shared.customer))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    ForEach(rows(for: viewModel.mailboxTree(for: personalFolders))) { row in
                        MailboxTreeRowBase(
                            node: row.node,
                            depth: row.depth,
                            isExpanded: expanded.contains(row.node.mailbox.id),
                            showsUnread: false,
                            onToggleExpand: { toggle(row.node.mailbox.id) },
                            onTap: { parent = row.node.mailbox }
                        )
                        .overlay(alignment: .trailing) {
                            if parent?.id == row.node.mailbox.id {
                                Image(systemName: "checkmark")
                                    .font(.subheadline)
                                    .foregroundStyle(Color(NCBrandColor.shared.customer))
                            }
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("_mail_new_folder_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("_mail_create_", comment: "")) {
                        let targetParent = parent
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        Task {
                            await viewModel.createMailbox(name: trimmed, parent: targetParent)
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private struct TreeRow: Identifiable {
        let node: MailboxNode
        let depth: Int
        var id: String { node.id }
    }

    private func rows(for nodes: [MailboxNode], depth: Int = 0) -> [TreeRow] {
        var result: [TreeRow] = []
        for node in nodes {
            result.append(TreeRow(node: node, depth: depth))
            if expanded.contains(node.mailbox.id) {
                result.append(contentsOf: rows(for: node.children, depth: depth + 1))
            }
        }
        return result
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }
}

private struct MailRow: View {
    let message: MailMessage
    var showsRecipient = false

    var body: some View {
        MailRowContent(message: message, showsRecipient: showsRecipient)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct MailRowContent: View {
    let message: MailMessage
    var showsRecipient = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(message.isRead ? Color.clear : Color(NCBrandColor.shared.customer)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(showsRecipient ? message.displayTo : message.displayFrom)
                        .fontWeight(message.isRead ? .regular : .semibold).lineLimit(1)
                    Spacer()
                    if message.isFlagged { Image(systemName: "flag.fill").foregroundStyle(.orange).font(.caption2) }
                    Text(MailDateFormatter.listLabel(for: message.dateSent)).font(.caption2).foregroundStyle(.secondary)
                }
                Text(message.subject.isEmpty ? NSLocalizedString("_mail_no_subject_", comment: "") : message.subject)
                    .font(.subheadline).lineLimit(1).foregroundStyle(message.isRead ? .secondary : .primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MailDetailView: View {
    @ObservedObject var viewModel: MailViewModel
    let message: MailMessage

    @State private var previewURL: URL?
    @State private var downloadingIds: Set<String> = []
    @State private var moveTarget: ([MailMessage], [Mailbox])?
    @State private var htmlHeight: CGFloat = 120

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                    .padding(.vertical, 12)
                bodyArea
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        // P62b: opaker Hintergrund - die darunter gemountete Nachrichtenliste
        // darf nicht durchscheinen und keine Taps durchlassen.
        .background(Color(.systemBackground))
        .quickLookPreview($previewURL)
        .sheet(item: Binding(
            get: { moveTarget.map { MoveSheetState(messages: $0.0, mailboxes: $0.1) } },
            set: { if $0 == nil { moveTarget = nil } }
        )) { state in
            MailMovePickerView(
                viewModel: viewModel,
                title: state.messages.first?.subject ?? "",
                mailboxes: state.mailboxes,
                onSelect: { target in
                    viewModel.move(state.messages, to: target)
                    viewModel.back()
                    moveTarget = nil
                }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.subject.isEmpty ? NSLocalizedString("_mail_no_subject_", comment: "") : message.subject)
                .font(.title3).fontWeight(.semibold)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.displayFrom).fontWeight(.medium)
                        .contextMenu {
                            Button {
                                // P65: Absender(-Adresse) kopieren.
                                UIPasteboard.general.string = message.fromAddress
                                SouveraToastCenter.shared.show(
                                    SouveraToast(
                                        message: NSLocalizedString("_mail_sender_copied_", comment: ""),
                                        style: .neutral
                                    )
                                )
                            } label: {
                                Label(NSLocalizedString("_mail_sender_copied_", comment: ""), systemImage: "doc.on.doc")
                            }
                        }
                    Text(MailDateFormatter.detailLabel(for: message.dateSent)).font(.caption).foregroundStyle(.secondary)
                    if !message.toAddresses.isEmpty {
                        Text("\(NSLocalizedString("_mail_to_", comment: "")): \(message.toAddresses)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            if case let .success(body) = viewModel.body, !body.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(body.attachments) { att in
                            attachmentChip(att)
                        }
                    }
                }
            }
        }
    }

    private func attachmentChip(_ att: AttachmentMeta) -> some View {
        Button {
            Task {
                downloadingIds.insert(att.id)
                if let url = await viewModel.downloadAttachment(att, for: message) {
                    previewURL = url
                }
                downloadingIds.remove(att.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "paperclip").font(.caption)
                Text(att.name).font(.caption).lineLimit(1)
                if downloadingIds.contains(att.id) {
                    ProgressView()
                } else {
                    Text(ByteCountFormatter.string(fromByteCount: att.sizeBytes, countStyle: .file))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var bodyArea: some View {
        switch viewModel.body {
        case .loading:
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 24)
        case let .error(m):
            VStack(spacing: 8) {
                Text(m).foregroundStyle(.secondary)
                Button(NSLocalizedString("_mail_detail_retry_", comment: "")) {
                    viewModel.openMessage(message)
                }
                .font(.subheadline)
            }
            .padding(.vertical, 12)
        case let .success(body):
            if let html = body.html, !html.isEmpty {
                // Self-sizing web view: the content flows directly below the
                // header (same margins, one scrollable column).
                MailHtmlView(html: html, height: $htmlHeight)
                    .frame(height: max(htmlHeight, 120))
            } else {
                Text(SouveraLinkOpener.linkified(body.plainText ?? ""))
                    .textSelection(.enabled)
                    .souveraOpenURLAction()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
    }
}

/// Renders an HTML email body in a self-sizing WKWebView (its scroll view is
/// disabled; the surrounding ScrollView scrolls everything as one column).
private struct MailHtmlView: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard !context.coordinator.loaded else { return }
        context.coordinator.loaded = true
        let wrapped = "<html><head><meta name='viewport' content='width=device-width, initial-scale=1'></head><body style='font-family:-apple-system;font-size:15px;margin:0'>\(html)</body></html>"
        webView.loadHTMLString(wrapped, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: MailHtmlView
        var loaded = false

        init(_ parent: MailHtmlView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { value, _ in
                guard let value = value as? NSNumber else { return }
                DispatchQueue.main.async {
                    self.parent.height = CGFloat(value.doubleValue)
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Link-Klicks nicht im WebView navigieren, sondern über den
            // SouveraLinkOpener öffnen (extern im Browser, Call-Links im
            // Link-Modul).
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
                SouveraLinkOpener.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

struct MailComposeView: View {
    @ObservedObject var viewModel: MailViewModel
    let context: MailComposeContext
    @Environment(\.dismiss) private var dismiss

    @State private var to: String
    @State private var cc: String
    @State private var bcc: String
    @State private var subject: String
    @State private var bodyText: String
    @State private var showCcBcc: Bool
    @State private var selectedFromIndex = 0
    @State private var attachments: [OutgoingAttachment]
    @State private var showFilePicker = false
    @State private var showNextcloudPicker = false
    @State private var showPhotoPicker = false
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var contactPickerField: RecipientFieldKind?
    @State private var suggestions: [RecipientSuggestion] = []
    @State private var suggestionTask: Task<Void, Never>?
    @State private var activeSuggestionField: RecipientFieldKind?

    enum RecipientFieldKind { case to, cc, bcc }

    init(viewModel: MailViewModel, context: MailComposeContext) {
        self.viewModel = viewModel
        self.context = context
        _to = State(initialValue: context.to.joined(separator: ", "))
        _cc = State(initialValue: context.cc.joined(separator: ", "))
        _bcc = State(initialValue: "")
        _subject = State(initialValue: context.subject)
        _bodyText = State(initialValue: context.quoteBody)
        _showCcBcc = State(initialValue: false)
        _attachments = State(initialValue: context.preAttachments)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if viewModel.fromAddresses.count > 1 {
                    HStack(spacing: 8) {
                        Text(NSLocalizedString("_mail_from_", comment: ""))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Picker("", selection: $selectedFromIndex) {
                            ForEach(Array(viewModel.fromAddresses.enumerated()), id: \.offset) { _, addr in
                                Text(addr).tag(viewModel.fromAddresses.firstIndex(of: addr) ?? 0)
                            }
                        }
                        .pickerStyle(.menu)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                }

                recipientField(label: NSLocalizedString("_mail_to_", comment: ""), text: $to, kind: .to)
                Divider()
                if showCcBcc {
                    recipientField(label: NSLocalizedString("_mail_cc_", comment: ""), text: $cc, kind: .cc)
                    Divider()
                    recipientField(label: NSLocalizedString("_mail_bcc_", comment: ""), text: $bcc, kind: .bcc)
                    Divider()
                }

                HStack(spacing: 8) {
                    Text(NSLocalizedString("_mail_subject_", comment: ""))
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    TextField("", text: $subject)
                    if !showCcBcc {
                        Button {
                            showCcBcc = true
                        } label: {
                            Image(systemName: "chevron.down.circle")
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()

                // The body fills all remaining space and grows with the
                // text instead of scrolling inside a small box.
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        if bodyText.isEmpty {
                            Text(NSLocalizedString("_mail_message_", comment: ""))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 12)
                                .padding(.top, 8)
                        }
                        AutoGrowingTextView(text: $bodyText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                attachmentsBar
            }
            .navigationTitle(composeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case let .success(urls):
                    importFiles(urls)
                case .failure:
                    break
                }
            }
            .sheet(isPresented: $showNextcloudPicker) {
                NextcloudFilePickerView { selection in
                    guard let selection else { return }
                    attachments.append(OutgoingAttachment(
                        name: selection.name,
                        mimeType: selection.mimeType,
                        fileURL: selection.localURL
                    ))
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoSelections, maxSelectionCount: 10, matching: .images)
            .onChange(of: photoSelections) { _, items in
                importPhotos(items)
            }
            .sheet(item: $contactPickerField) { kind in
                ContactPickerSheet { email in
                    switch kind {
                    case .to:
                        to = appendRecipient(to, email: email)
                    case .cc:
                        cc = appendRecipient(cc, email: email)
                    case .bcc:
                        bcc = appendRecipient(bcc, email: email)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSending {
                        ProgressView()
                    } else {
                        Button(NSLocalizedString("_mail_send_", comment: "")) {
                            var outgoing = OutgoingMessage()
                            outgoing.to = to.commaSeparated()
                            outgoing.cc = cc.commaSeparated()
                            outgoing.bcc = bcc.commaSeparated()
                            outgoing.subject = subject
                            outgoing.body = bodyText
                            outgoing.attachments = attachments
                            outgoing.inReplyTo = context.message?.messageId
                            viewModel.fromAddress = viewModel.fromAddresses[selectedFromIndex]
                            viewModel.send(outgoing)
                            dismiss()
                        }
                        .disabled(to.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    /// Attachment chips plus the attach menu (local file / Souvera files).
    private var attachmentsBar: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { att in
                        HStack(spacing: 5) {
                            Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary)
                            Text(att.name).font(.caption).lineLimit(1)
                            Button {
                                attachments.removeAll { $0.id == att.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                    Menu {
                        Button {
                            showFilePicker = true
                        } label: {
                            Label(NSLocalizedString("_mail_attachment_add_", comment: ""), systemImage: "plus.circle")
                        }
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label(NSLocalizedString("_link_attach_photos_", comment: ""), systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showNextcloudPicker = true
                        } label: {
                            Label(NSLocalizedString("_mail_souvera_files_", comment: ""), systemImage: "building.columns")
                        }
                    } label: {
                        Image(systemName: "paperclip")
                            .foregroundStyle(Color(NCBrandColor.shared.customer))
                            .padding(8)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            if let error = viewModel.sendError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
    }

    private func recipientField(label: String, text: Binding<String>, kind: RecipientFieldKind) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                TextField("", text: text)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .onChange(of: text.wrappedValue) { _, newValue in
                        suggestionTask?.cancel()
                        suggestionTask = Task {
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            guard !Task.isCancelled else { return }
                            let token = newValue
                                .split(separator: ",").last.map(String.init)?
                                .split(separator: ";").last.map(String.init)?
                                .trimmingCharacters(in: .whitespaces) ?? ""
                            let found = await ContactSuggestionSource().search(token)
                            if !Task.isCancelled {
                                suggestions = found
                                activeSuggestionField = kind
                            }
                        }
                    }
                Button {
                    contactPickerField = kind
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .foregroundStyle(Color(NCBrandColor.shared.customer))
                        .frame(width: 28, height: 28)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if activeSuggestionField == kind && !suggestions.isEmpty {
                ForEach(suggestions) { suggestion in
                    Button {
                        text.wrappedValue = replaceLastToken(text.wrappedValue, with: suggestion.email)
                        suggestions = []
                        activeSuggestionField = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.displayName ?? suggestion.email).font(.subheadline)
                            if suggestion.displayName != nil {
                                Text(suggestion.email).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// Replaces the token being typed (after the last comma/semicolon) with
    /// the picked suggestion, mirroring the Android RecipientField.
    private func replaceLastToken(_ value: String, with email: String) -> String {
        var result = value
        let comma = result.lastIndex(of: ",")
        let semi = result.lastIndex(of: ";")
        if let comma, let semi {
            let separatorIndex = max(comma, semi)
            result = "\(result[...separatorIndex]) \(email)"
        } else if let comma {
            result = "\(result[...comma]) \(email)"
        } else if let semi {
            result = "\(result[...semi]) \(email)"
        } else {
            result = email
        }
        return result
    }

    private func appendRecipient(_ value: String, email: String) -> String {
        let parts = value.commaSeparated()
        if parts.contains(email) { return value }
        return parts.isEmpty ? email : "\(value), \(email)"
    }

    /// Copies picked files into the app's temporary directory so they stay
    /// readable after the picker's security-scoped access ends.

    private var composeTitle: String {
        switch context.mode {
        case .new: return NSLocalizedString("_mail_compose_", comment: "")
        case .reply: return NSLocalizedString("_mail_reply_", comment: "")
        case .replyAll: return NSLocalizedString("_mail_reply_all_", comment: "")
        case .forward: return NSLocalizedString("_mail_forward_", comment: "")
        }
    }
    /// Fotos aus dem System-Picker übernehmen (kein Berechtigungsdialog -
    /// der System-Picker läuft außerhalb der App).
    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            var counter = 0
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first
                let ext = type?.preferredFilenameExtension ?? "jpg"
                counter += 1
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Foto_\(Int(Date().timeIntervalSince1970))_\(counter).\(ext)")
                do {
                    try data.write(to: tmp, options: .atomic)
                    attachments.append(OutgoingAttachment(
                        name: tmp.lastPathComponent,
                        mimeType: type?.preferredMIMEType ?? "image/jpeg",
                        fileURL: tmp
                    ))
                } catch {}
            }
            await MainActor.run { photoSelections = [] }
        }
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls {
            let didStart = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if didStart { url.stopAccessingSecurityScopedResource() }
            guard let data else { continue }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
            do {
                try data.write(to: tmp, options: .atomic)
                attachments.append(OutgoingAttachment(
                    name: url.lastPathComponent,
                    mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                    fileURL: tmp
                ))
            } catch {}
        }
    }
}

extension MailComposeView.RecipientFieldKind: Identifiable {
    var id: Int {
        switch self {
        case .to: return 0
        case .cc: return 1
        case .bcc: return 2
        }
    }
}

/// Auto-growing multi-line text editor for the mail body: always supports
/// line breaks, grows with the content and lets the surrounding ScrollView
/// handle scrolling once the text exceeds the available space.
private struct AutoGrowingTextView: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.text = text
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AutoGrowingTextView

        init(_ parent: AutoGrowingTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}

/// Rückwärts laufender Countdown-Ring für den nächsten automatischen
/// Abruf (Kreis leert sich bis zum Abruf, dann startet er neu).
struct AutoRefreshRingView: View {
    @ObservedObject var viewModel: MailViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let nextAt = viewModel.nextAutoRefreshAt,
               let interval = SouveraAutoRefresh.interval, interval > 0 {
                let remaining = max(0, nextAt.timeIntervalSinceNow)
                let progress = remaining / interval
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: min(1, progress))
                        .stroke(Color(NCBrandColor.shared.customer), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: progress)
                }
                .frame(width: 18, height: 18)
                .frame(width: 24, height: 24, alignment: .center)
                .accessibilityLabel(String(format: NSLocalizedString("_mail_auto_refresh_ring_", comment: ""), Int(remaining / 60), Int(remaining.truncatingRemainder(dividingBy: 60))))
            }
        }
    }
}

extension View {
    /// Scroll-Offset-Beobachter (iOS 18+); auf älteren Systemen ohne Effekt.
    @ViewBuilder
    func scrollTopObserver(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, newValue in
                onChange(newValue)
            }
        } else {
            self
        }
    }
}
