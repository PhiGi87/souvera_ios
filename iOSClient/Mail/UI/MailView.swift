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

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .onAppear { viewModel.start() }
        .sheet(item: Binding(
            get: { viewModel.composeContext },
            set: { viewModel.composeContext = $0 }
        )) { context in
            MailComposeView(viewModel: viewModel, context: context)
        }
    }

    private var navigationTitle: String {
        switch viewModel.route {
        case .folders: return NSLocalizedString("_mail_", comment: "")
        case let .messages(mailbox): return mailbox.name
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
                ProgressView()
            case let .error(message):
                VStack(spacing: 12) {
                    Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(NSLocalizedString("_mail_retry_", comment: "")) { viewModel.retry() }
                        .buttonStyle(.bordered)
                }
                .padding()
            case let .success(boxes):
                List {
                    ForEach(mailboxGroups(boxes)) { group in
                        Section {
                            ForEach(group.folders) { box in
                                Button { viewModel.openMailbox(box) } label: {
                                    HStack {
                                        Image(systemName: icon(for: box.kind)).foregroundStyle(Color(NCBrandColor.shared.customer))
                                        Text(folderDisplayName(box))
                                        Spacer()
                                        if box.unreadCount > 0 { Text("\(box.unreadCount)").foregroundStyle(.secondary) }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                Text(group.label)
                                Spacer()
                                if group.totalUnread > 0 { Text("\(group.totalUnread)") }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await viewModel.loadMailboxes() }
            }
        }
    }

    private struct MailboxGroup: Identifiable {
        let id: String
        let label: String
        let folders: [Mailbox]
        let totalUnread: Int
    }

    /// Personal mailboxes first, then one group per shared owner
    /// (mirrors the Android folder sheet grouping). The personal group is
    /// labeled with the user's own email address.
    private func mailboxGroups(_ boxes: [Mailbox]) -> [MailboxGroup] {
        let personal = boxes.filter { $0.namespace == .personal }
        var groups: [MailboxGroup] = []
        if !personal.isEmpty {
            let label = viewModel.ownEmailLabel.isEmpty
                ? NSLocalizedString("_mail_mailboxes_", comment: "")
                : viewModel.ownEmailLabel
            groups.append(MailboxGroup(
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
            groups.append(MailboxGroup(
                id: "shared_\(owner)",
                label: "\(NSLocalizedString("_mail_shared_prefix_", comment: "")) \(owner)",
                folders: folders,
                totalUnread: folders.reduce(0) { $0 + $1.unreadCount }
            ))
        }
        return groups
    }

    private func folderDisplayName(_ box: Mailbox) -> String {
        switch box.kind {
        case .inbox: return NSLocalizedString("_mail_folder_inbox_", comment: "")
        case .sent: return NSLocalizedString("_mail_folder_sent_", comment: "")
        case .drafts: return NSLocalizedString("_mail_folder_drafts_", comment: "")
        case .trash: return NSLocalizedString("_mail_folder_trash_", comment: "")
        case .junk: return NSLocalizedString("_mail_folder_junk_", comment: "")
        case .regular: return box.name
        }
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
                    ForEach(items) { message in
                        row(message)
                    }
                }
                .listStyle(.plain)
                .refreshable { await viewModel.refreshMessages() }
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
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if editing {
                    Button(NSLocalizedString("_done_", comment: "")) {
                        editing = false
                        selected.removeAll()
                    }
                } else {
                    Button { viewModel.startCompose(mode: .new) } label: { Image(systemName: "square.and.pencil") }
                    if !isEmptyList {
                        Button(NSLocalizedString("_edit_", comment: "")) { editing = true }
                    }
                }
            }
        }
        .onChange(of: editing) { _, value in
            if !value { selected.removeAll() }
        }
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
                        Text(box.name)
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
            HStack(spacing: 18) {
                actionButton(icon: "arrowshape.turn.up.left", label: NSLocalizedString("_mail_reply_", comment: "")) {
                    viewModel.startCompose(mode: .reply, message: message)
                }
                actionButton(icon: "arrowshape.turn.up.left.2", label: NSLocalizedString("_mail_reply_all_", comment: "")) {
                    viewModel.startCompose(mode: .replyAll, message: message)
                }
                actionButton(icon: "arrowshape.turn.up.right", label: NSLocalizedString("_mail_forward_", comment: "")) {
                    viewModel.startCompose(mode: .forward, message: message)
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
                        moveTarget = ([message], viewModel.availableMailboxes.filter { $0.accountId == message.accountId })
                    } label: {
                        Label(NSLocalizedString("_mail_move_", comment: ""), systemImage: "folder")
                    }
                    Button {
                        viewModel.toggleFlagged(message)
                    } label: {
                        Label(NSLocalizedString("_mail_flag_", comment: ""), systemImage: message.isFlagged ? "flag.slash" : "flag")
                    }
                    Button(role: .destructive) {
                        viewModel.delete([message])
                        viewModel.back()
                    } label: {
                        Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.body)
                }
                Spacer()
                Button(role: .destructive) {
                    viewModel.delete([message])
                    viewModel.back()
                } label: {
                    Image(systemName: "trash")
                }
            }
            .font(.body)
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

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                Text(label).font(.caption2)
            }
        }
        .buttonStyle(.plain)
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
            Form {
                if viewModel.fromAddresses.count > 1 {
                    Section {
                        Picker(NSLocalizedString("_mail_from_", comment: ""), selection: $selectedFromIndex) {
                            ForEach(Array(viewModel.fromAddresses.enumerated()), id: \.offset) { _, addr in
                                Text(addr).tag(viewModel.fromAddresses.firstIndex(of: addr) ?? 0)
                            }
                        }
                    }
                }
                Section {
                    recipientField(label: NSLocalizedString("_mail_to_", comment: ""), text: $to, kind: .to)
                    if showCcBcc {
                        recipientField(label: NSLocalizedString("_mail_cc_", comment: ""), text: $cc, kind: .cc)
                        recipientField(label: NSLocalizedString("_mail_bcc_", comment: ""), text: $bcc, kind: .bcc)
                    }
                    TextField(NSLocalizedString("_mail_subject_", comment: ""), text: $subject)
                    if !showCcBcc {
                        Button(NSLocalizedString("_mail_show_cc_bcc_", comment: "")) { showCcBcc = true }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextEditor(text: $bodyText).frame(minHeight: 220)
                }
                Section(NSLocalizedString("_mail_attachments_", comment: "")) {
                    ForEach(attachments) { att in
                        HStack {
                            Image(systemName: "paperclip").foregroundStyle(.secondary)
                            Text(att.name).font(.caption).lineLimit(1)
                            Spacer()
                            Button(role: .destructive) {
                                attachments.removeAll { $0.id == att.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
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
                }
                if let error = viewModel.sendError {
                    Text(error).foregroundStyle(.red)
                }
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
                NextcloudFilePickerView { url in
                    guard let url else { return }
                    attachments.append(OutgoingAttachment(
                        name: url.lastPathComponent,
                        mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                        fileURL: url
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

    private func recipientField(label: String, text: Binding<String>, kind: RecipientFieldKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).foregroundStyle(.secondary)
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
                }
            }
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
                    }
                    .buttonStyle(.plain)
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
