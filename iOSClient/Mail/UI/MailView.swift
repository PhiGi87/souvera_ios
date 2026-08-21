// SPDX-FileCopyrightText: 2026 Host-On Service Provider GmbH (Souvera)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// SwiftUI surface for the native mail client: folder list → message list → detail → compose.
// Mirrors android mail/ui Compose screens.

import SwiftUI
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
            List(boxes) { box in
                Button { viewModel.openMailbox(box) } label: {
                    HStack {
                        Image(systemName: icon(for: box.kind)).foregroundStyle(Color(NCBrandColor.shared.customer))
                        Text(box.name)
                        Spacer()
                        if box.unreadCount > 0 { Text("\(box.unreadCount)").foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
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
                        Button { viewModel.toggleFlagged(message) } label: { Label("Flag", systemImage: "flag") }.tint(.orange)
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await viewModel.syncMessages() }
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
                            Label("\(att.name) (\(ByteCountFormatter.string(fromByteCount: att.sizeBytes, countStyle: .file)))", systemImage: "paperclip")
                                .font(.caption)
                        }
                    }
                }
            }
            .padding()
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
    @Environment(\.dismiss) private var dismiss

    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var showCcBcc = false
    @State private var selectedFromIndex = 0

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
                if let error = viewModel.sendError {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle(NSLocalizedString("_mail_compose_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
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
}
