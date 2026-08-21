// SPDX-FileCopyrightText: 2026 Host-On Service Provider GmbH (Souvera)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// SwiftUI surface for the native mail client: folder list → message list → detail → compose.
// Mirrors android mail/ui Compose screens.

import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct MailView: View {
    @StateObject private var viewModel = MailViewModel()
    @State private var detailMoveTarget: ([MailMessage], [Mailbox])?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .onAppear { viewModel.start() }
        .overlay(alignment: .bottom) {
            if let feedback = viewModel.sendFeedback {
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
        .sheet(item: Binding(
            get: { viewModel.composeContext },
            set: { viewModel.composeContext = $0 }
        )) { context in
            MailComposeView(viewModel: viewModel, context: context)
        }
        .sheet(item: Binding(
            get: { detailMoveTarget.map { MoveSheetState(messages: $0.0, mailboxes: $0.1) } },
            set: { if $0 == nil { detailMoveTarget = nil } }
        )) { state in
            MailMovePickerView(
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
        case let .messages(mailbox): return mailbox.displayName
        case .detail: return ""
        case .compose: return NSLocalizedString("_mail_compose_", comment: "")
        case .search: return NSLocalizedString("_mail_search_", comment: "")
        }
    }

    private var isFolders: Bool {
        if case .folders = viewModel.route { return true }
        return false
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !isFolders {
            ToolbarItem(placement: .topBarLeading) {
                Button { viewModel.back() } label: { Image(systemName: "chevron.backward") }
            }
        }
        if case let .detail(message) = viewModel.route {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    viewModel.startCompose(mode: .reply, message: message)
                } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                }
                Button {
                    viewModel.startCompose(mode: .replyAll, message: message)
                } label: {
                    Image(systemName: "arrowshape.turn.up.left.2")
                }
                Button {
                    viewModel.startCompose(mode: .forward, message: message)
                } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                }
                Menu {
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Button(role: .destructive) {
                    viewModel.delete([message])
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        if isFolders {
            ToolbarItem(placement: .topBarTrailing) {
                Button { viewModel.route = .search } label: { Image(systemName: "magnifyingglass") }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.route {
        case .folders:
            MailFolderListView(viewModel: viewModel)
        case .messages:
            MailMessageListView(viewModel: viewModel)
        case let .detail(message):
            MailDetailView(viewModel: viewModel, message: message)
        case .compose:
            MailComposeView(viewModel: viewModel, context: MailComposeContext(mode: .new, message: nil, to: [], cc: [], subject: "", quoteBody: "", preAttachments: []))
        case .search:
            MailSearchView(viewModel: viewModel)
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

    var body: some View {
        VStack(spacing: 0) {
            Text("Mail via \(viewModel.transportLabel) · \(SouveraBuildInfo.label)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 4)
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
                                depth: row.depth
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
            if viewModel.folderScrollPosition != nil, let firstId = boxes.first?.id {
                Button {
                    withAnimation { viewModel.folderScrollPosition = firstId }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color(NCBrandColor.shared.customer)))
                        .shadow(radius: 3)
                }
                .accessibilityLabel(NSLocalizedString("_mail_scroll_top_", comment: ""))
                .padding(.bottom, 10)
            }
        }
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
private struct MailboxTreeRow: View {
    @ObservedObject var viewModel: MailViewModel
    let node: MailboxNode
    let depth: Int

    private var isExpanded: Bool {
        viewModel.expandedMailboxIds.contains(node.mailbox.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            if node.children.isEmpty {
                Color.clear.frame(width: 28, height: 1)
            } else {
                Button {
                    if isExpanded {
                        viewModel.expandedMailboxIds.remove(node.mailbox.id)
                    } else {
                        viewModel.expandedMailboxIds.insert(node.mailbox.id)
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button {
                viewModel.openMailbox(node.mailbox)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon(for: node.mailbox.kind))
                        .font(.body)
                        .foregroundStyle(Color(NCBrandColor.shared.customer))
                        .frame(width: 24)
                    Text(node.mailbox.displayName)
                        .font(.body)
                    Spacer()
                    if !isExpanded, !node.children.isEmpty, node.totalUnread > 0 {
                        Text("\(node.totalUnread)").foregroundStyle(.secondary)
                    } else if node.mailbox.unreadCount > 0 {
                        Text("\(node.mailbox.unreadCount)").foregroundStyle(.secondary)
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

private struct MailMessageListView: View {
    @ObservedObject var viewModel: MailViewModel
    @State private var editing = false
    @State private var selected = Set<String>()
    @State private var moveTarget: ([MailMessage], [Mailbox])?

    var body: some View {
        VStack(spacing: 0) {
            if let notice = viewModel.offlineNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            switch viewModel.messages {
            case .loading:
                Spacer()
                ProgressView()
                Spacer()
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
                List {
                    ForEach(viewModel.sortMessages(items)) { message in
                        row(message)
                    }
                }
                .listStyle(.plain)
                .scrollPosition(id: $viewModel.messageScrollPosition, anchor: .top)
                .refreshable { await viewModel.refreshMessages() }
                .overlay(alignment: .bottom) {
                    if viewModel.messageScrollPosition != nil, let firstId = viewModel.sortMessages(items).first?.id {
                        Button {
                            withAnimation { viewModel.messageScrollPosition = firstId }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.subheadline.bold())
                                .foregroundStyle(Color.white)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Color(NCBrandColor.shared.customer)))
                                .shadow(radius: 3)
                        }
                        .accessibilityLabel(NSLocalizedString("_mail_scroll_top_", comment: ""))
                        .padding(.bottom, 10)
                    }
                }
            }
        }
        .sheet(item: Binding(
            get: { moveTarget.map { MoveSheetState(messages: $0.0, mailboxes: $0.1) } },
            set: { if $0 == nil { moveTarget = nil } }
        )) { state in
            MailMovePickerView(
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
            ToolbarItemGroup(placement: .topBarTrailing) {
                if editing {
                    Button(NSLocalizedString("_done_", comment: "")) {
                        editing = false
                        selected.removeAll()
                    }
                } else {
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
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    Button { viewModel.startCompose(mode: .new) } label: { Image(systemName: "square.and.pencil") }
                    if !isEmptyList {
                        Button { editing = true } label: { Image(systemName: "checklist") }
                            .accessibilityLabel(NSLocalizedString("_edit_", comment: ""))
                    }
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
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(.bar)
            }
        }
        .onChange(of: editing) { _, value in
            if !value { selected.removeAll() }
        }
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
                MailRow(message: message)
            }
            .buttonStyle(.plain)
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
    let title: String
    let mailboxes: [Mailbox]
    let onSelect: (Mailbox) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(mailboxes) { box in
                Button {
                    onSelect(box)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Color(NCBrandColor.shared.customer))
                        Text(box.displayName)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
            }
        }
    }
}

private struct MailSearchView: View {
    @ObservedObject var viewModel: MailViewModel
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(NSLocalizedString("_mail_search_hint_", comment: ""), text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await viewModel.search(query) } }
                if !query.isEmpty {
                    Button {
                        query = ""
                        Task { await viewModel.search("") }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            Divider()
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
                    Text(query.isEmpty
                         ? NSLocalizedString("_mail_search_hint_", comment: "")
                         : NSLocalizedString("_mail_search_no_results_", comment: ""))
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List(items) { message in
                        Button { viewModel.openMessage(message, fromSearch: true) } label: {
                            MailRow(message: message)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { viewModel.delete([message]) } label: { Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash") }
                            Button { viewModel.toggleFlagged(message) } label: { Label(NSLocalizedString("_mail_flag_", comment: ""), systemImage: "flag") }.tint(.orange)
                        }
                        .swipeActions(edge: .leading) {
                            Button { viewModel.startCompose(mode: .reply, message: message) } label: {
                                Label(NSLocalizedString("_mail_reply_", comment: ""), systemImage: "arrowshape.turn.up.left")
                            }
                            .tint(.green)
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
    }
}

private struct MailRow: View {
    let message: MailMessage

    var body: some View {
        MailRowContent(message: message)
            .padding(.vertical, 2)
    }
}

private struct MailRowContent: View {
    let message: MailMessage

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(message.isRead ? Color.clear : Color(NCBrandColor.shared.customer)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.displayFrom).fontWeight(message.isRead ? .regular : .semibold).lineLimit(1)
                    Spacer()
                    if message.isFlagged { Image(systemName: "flag.fill").foregroundStyle(.orange).font(.caption2) }
                    Text(message.dateSent, style: .date).font(.caption2).foregroundStyle(.secondary)
                }
                Text(message.subject.isEmpty ? NSLocalizedString("_mail_no_subject_", comment: "") : message.subject)
                    .font(.subheadline).lineLimit(1).foregroundStyle(message.isRead ? .secondary : .primary)
            }
        }
    }
}

private struct MailDetailView: View {
    @ObservedObject var viewModel: MailViewModel
    let message: MailMessage

    @State private var previewURL: URL?
    @State private var downloadingIds: Set<String> = []
    @State private var moveTarget: ([MailMessage], [Mailbox])?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            bodyArea
        }
        .quickLookPreview($previewURL)
        .sheet(item: Binding(
            get: { moveTarget.map { MoveSheetState(messages: $0.0, mailboxes: $0.1) } },
            set: { if $0 == nil { moveTarget = nil } }
        )) { state in
            MailMovePickerView(
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
                    Text(message.dateSent, style: .date).font(.caption).foregroundStyle(.secondary)
                    if !message.toAddresses.isEmpty {
                        Text("\(NSLocalizedString("_mail_to_", comment: "")): \(message.toAddresses)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            if case let .success(body) = viewModel.body, !body.attachments.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(body.attachments) { att in
                            attachmentChip(att)
                        }
                    }
                }
            }
        }
        .padding()
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
            Spacer()
            ProgressView()
            Spacer()
        case let .error(m):
            Spacer()
            Text(m).foregroundStyle(.secondary).padding()
            Spacer()
        case let .success(body):
            if let html = body.html, !html.isEmpty {
                // HTML fills the entire remaining area and scrolls itself.
                MailHtmlView(html: html)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(body.plainText ?? "")
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
    }
}

/// Renders an HTML email body in a WKWebView.
private struct MailHtmlView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let wrapped = "<html><head><meta name='viewport' content='width=device-width, initial-scale=1'></head><body style='font-family:-apple-system;font-size:15px'>\(html)</body></html>"
        webView.loadHTMLString(wrapped, baseURL: nil)
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
            .navigationTitle(NSLocalizedString("_mail_compose_", comment: ""))
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
