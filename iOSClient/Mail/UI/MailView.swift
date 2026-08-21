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
    @State private var showCompose = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .onAppear { viewModel.start() }
        .sheet(isPresented: $showCompose) {
            MailComposeView(viewModel: viewModel)
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

    private var isMessages: Bool {
        if case .messages = viewModel.route { return true }
        return false
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !isFolders {
            ToolbarItem(placement: .topBarLeading) {
                Button { viewModel.back() } label: { Image(systemName: "chevron.backward") }
            }
        }
        if isMessages {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCompose = true } label: { Image(systemName: "square.and.pencil") }
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
            MailComposeView(viewModel: viewModel)
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
    /// (mirrors the Android folder sheet grouping).
    private func mailboxGroups(_ boxes: [Mailbox]) -> [MailboxGroup] {
        let personal = boxes.filter { $0.namespace == .personal }
        var groups: [MailboxGroup] = []
        if !personal.isEmpty {
            groups.append(MailboxGroup(
                id: "personal",
                label: NSLocalizedString("_mail_mailboxes_", comment: ""),
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
    @State private var moveTarget: (MailMessage, [Mailbox])?

    var body: some View {
        switch viewModel.messages {
        case .loading:
            ProgressView()
        case let .error(message):
            VStack(spacing: 12) {
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(NSLocalizedString("_mail_retry_", comment: "")) { viewModel.retry() }
                    .buttonStyle(.bordered)
            }
            .padding()
        case let .success(items):
            List {
                ForEach(items) { message in
                    Button { viewModel.openMessage(message) } label: {
                        MailRow(message: message)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { viewModel.delete(message) } label: { Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash") }
                        Button {
                            moveTarget = (message, viewModel.availableMailboxes.filter { $0.accountId == message.accountId })
                        } label: {
                            Label(NSLocalizedString("_mail_move_", comment: ""), systemImage: "folder")
                        }
                        .tint(.blue)
                        Button { viewModel.toggleFlagged(message) } label: { Label("Flag", systemImage: "flag") }.tint(.orange)
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await viewModel.syncMessages() }
            .sheet(item: Binding(
                get: { moveTarget.map { MoveSheetState(message: $0.0, mailboxes: $0.1) } },
                set: { if $0 == nil { moveTarget = nil } }
            )) { state in
                MailMovePickerView(
                    title: state.message.subject.isEmpty ? NSLocalizedString("_mail_no_subject_", comment: "") : state.message.subject,
                    mailboxes: state.mailboxes,
                    onSelect: { target in
                        viewModel.move(state.message, to: target)
                        moveTarget = nil
                    }
                )
            }
        }
    }
}

private struct MoveSheetState: Identifiable, Equatable {
    let message: MailMessage
    let mailboxes: [Mailbox]
    var id: String { message.id }

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
                            Button(role: .destructive) { viewModel.delete(message) } label: { Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash") }
                            Button { viewModel.toggleFlagged(message) } label: { Label("Flag", systemImage: "flag") }.tint(.orange)
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
        .padding(.vertical, 2)
    }
}

private struct MailDetailView: View {
    @ObservedObject var viewModel: MailViewModel
    let message: MailMessage

    @State private var previewURL: URL?
    @State private var downloadingIds: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(message.subject.isEmpty ? NSLocalizedString("_mail_no_subject_", comment: "") : message.subject)
                    .font(.title3).fontWeight(.semibold)
                HStack {
                    VStack(alignment: .leading) {
                        Text(message.displayFrom).fontWeight(.medium)
                        Text(message.dateSent, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Divider()
                switch viewModel.body {
                case .loading:
                    ProgressView()
                case let .error(m):
                    Text(m).foregroundStyle(.secondary)
                case let .success(body):
                    if let html = body.html, !html.isEmpty {
                        MailHtmlView(html: html)
                            .frame(minHeight: 300)
                    } else {
                        Text(body.plainText ?? "").textSelection(.enabled)
                    }
                    if !body.attachments.isEmpty {
                        Divider()
                        ForEach(body.attachments) { att in
                            Button {
                                Task {
                                    downloadingIds.insert(att.id)
                                    if let url = await viewModel.downloadAttachment(att, for: message) {
                                        previewURL = url
                                    }
                                    downloadingIds.remove(att.id)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "paperclip").font(.caption)
                                    Text(att.name).font(.caption).lineLimit(1)
                                    Spacer()
                                    if downloadingIds.contains(att.id) {
                                        ProgressView()
                                    } else {
                                        Text(ByteCountFormatter.string(fromByteCount: att.sizeBytes, countStyle: .file))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(8)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
        }
        .quickLookPreview($previewURL)
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
    @Environment(\.dismiss) private var dismiss

    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var showCcBcc = false
    @State private var selectedFromIndex = 0
    @State private var attachments: [OutgoingAttachment] = []
    @State private var showFilePicker = false
    @State private var suggestions: [RecipientSuggestion] = []
    @State private var suggestionTask: Task<Void, Never>?

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
                    TextField(NSLocalizedString("_mail_to_", comment: ""), text: $to)
                        .keyboardType(.emailAddress).autocapitalization(.none)
                        .onChange(of: to) { _, newValue in
                            suggestionTask?.cancel()
                            suggestionTask = Task {
                                try? await Task.sleep(nanoseconds: 150_000_000)
                                guard !Task.isCancelled else { return }
                                let token = newValue
                                    .split(separator: ",").last.map(String.init)?
                                    .split(separator: ";").last.map(String.init)?
                                    .trimmingCharacters(in: .whitespaces) ?? ""
                                let found = await ContactSuggestionSource().search(token)
                                if !Task.isCancelled { suggestions = found }
                            }
                        }
                    if !suggestions.isEmpty {
                        ForEach(suggestions) { suggestion in
                            Button {
                                replaceLastToken(in: &to, with: suggestion.email)
                                suggestions = []
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
                    if showCcBcc {
                        TextField(NSLocalizedString("_mail_cc_", comment: ""), text: $cc)
                            .keyboardType(.emailAddress).autocapitalization(.none)
                        TextField(NSLocalizedString("_mail_bcc_", comment: ""), text: $bcc)
                            .keyboardType(.emailAddress).autocapitalization(.none)
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
                            outgoing.to = to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            outgoing.cc = cc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            outgoing.bcc = bcc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            outgoing.subject = subject
                            outgoing.body = bodyText
                            outgoing.attachments = attachments
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
                    mimeType: mimeType(for: url.pathExtension),
                    fileURL: tmp
                ))
            } catch {}
        }
    }

    private func mimeType(for fileExtension: String) -> String {
        UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Replaces the token being typed (after the last comma/semicolon) with
    /// the picked suggestion, mirroring the Android RecipientField.
    private func replaceLastToken(in value: inout String, with email: String) {
        let comma = value.lastIndex(of: ",")
        let semi = value.lastIndex(of: ";")
        if let comma, let semi {
            let separatorIndex = max(comma, semi)
            value = "\(value[...separatorIndex]) \(email)"
        } else if let comma {
            value = "\(value[...comma]) \(email)"
        } else if let semi {
            value = "\(value[...semi]) \(email)"
        } else {
            value = email
        }
    }
}
