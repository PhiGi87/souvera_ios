// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// SwiftUI surface for "Link" (Nextcloud Talk): conversation list + live chat. Mirrors the android
// link/ui Compose screens (ConversationListScreen, ChatScreen) but idiomatic SwiftUI.

import SwiftUI
import UniformTypeIdentifiers

/// Root Link screen; switches between the conversation list and an open chat.
struct LinkView: View {
    @StateObject private var viewModel = LinkViewModel()
    @State private var callContext: CallContext?
    @State private var showCallBanner = false
    @State private var returnToCall = false
#if DEBUG
    @State private var simulatedIncoming: SimulatedCall?
#endif

    struct CallContext: Identifiable {
        let token: String
        let title: String
        let withVideo: Bool
        let silent: Bool
        var id: String { "\(token)|\(withVideo)|\(silent)" }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if case let .chat(token, title) = viewModel.route {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                viewModel.back()
                            } label: {
                                Image(systemName: "chevron.backward")
                            }
                        }
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button {
                                callContext = CallContext(token: token, title: title, withVideo: false, silent: false)
                            } label: {
                                Image(systemName: "phone.fill").foregroundStyle(.green)
                            }
                            Button {
                                callContext = CallContext(token: token, title: title, withVideo: true, silent: false)
                            } label: {
                                Image(systemName: "video.fill").foregroundStyle(Color(NCBrandColor.shared.customer))
                            }
                            Button {
                                // Stiller Anruf: niemand im Kanal wird angeklingelt
                                callContext = CallContext(token: token, title: title, withVideo: false, silent: true)
                            } label: {
                                Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
                            }
                            .accessibilityLabel(NSLocalizedString("_link_silent_call_", comment: ""))
                        }
                    }
                }
        }
        .onAppear {
            viewModel.start()
            if let pending = LinkViewModel.pendingOpenRoom {
                LinkViewModel.pendingOpenRoom = nil
                viewModel.openConversation(token: pending.token, title: pending.title)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .linkCallStateChanged)) { _ in
            showCallBanner = LinkVoIPManager.shared.activeCallInfo != nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .linkCallUIClose)) { _ in
            // Wichtig: die Cover-Items leeren, sonst bleibt nach dem Auflegen
            // ein weisser Cover-Bildschirm zurück.
            callContext = nil
            returnToCall = false
        }
#if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .linkSimulateIncomingCall)) { notification in
            guard let token = notification.userInfo?["token"] as? String else { return }
            let title = (notification.userInfo?["title"] as? String) ?? NSLocalizedString("_link_incoming_call_", comment: "")
            let hasVideo = (notification.userInfo?["hasVideo"] as? Bool) ?? false
            simulatedIncoming = SimulatedCall(token: token, title: title, hasVideo: hasVideo)
        }
#endif
        .overlay(alignment: .top) {
            if showCallBanner, let info = LinkVoIPManager.shared.activeCallInfo {
                activeCallBanner(title: info.title)
            }
        }
        .fullScreenCover(item: $callContext) { context in
            if let account = LinkAccount.active() {
                LinkCallViewControllerWrapper(
                    account: account,
                    token: context.token,
                    title: context.title,
                    withVideo: context.withVideo,
                    silent: context.silent
                )
                .ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $returnToCall) {
            if let info = LinkVoIPManager.shared.activeCallInfo,
               let session = LinkVoIPManager.shared.activeSession,
               let account = LinkAccount.active() {
                LinkCallViewControllerWrapper(
                    account: account,
                    token: info.token,
                    title: info.title,
                    withVideo: info.withVideo,
                    session: session
                )
                .ignoresSafeArea()
            }
        }
#if DEBUG
        .fullScreenCover(item: $simulatedIncoming) { call in
            IncomingCallOverlayView(
                title: call.title,
                hasVideo: call.hasVideo,
                onAccept: {
                    simulatedIncoming = nil
                    guard let account = LinkAccount.active() else { return }
                    _ = LinkVoIPManager.shared.startIncomingCall(
                        account: account,
                        token: call.token,
                        title: call.title,
                        withVideo: call.hasVideo
                    )
                    returnToCall = true
                },
                onDecline: {
                    simulatedIncoming = nil
                }
            )
        }
#endif
    }

#if DEBUG
    private struct SimulatedCall: Identifiable {
        let token: String
        let title: String
        let hasVideo: Bool
        var id: String { token }
    }
#endif

    /// Green banner shown while a call is running without its own UI.
    private func activeCallBanner(title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "phone.fill")
                .foregroundStyle(.white)
                .padding(6)
                .background(Circle().fill(Color.green))
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Button(NSLocalizedString("_link_call_return_", comment: "")) {
                returnToCall = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button(role: .destructive) {
                LinkVoIPManager.shared.endActiveCall()
            } label: {
                Image(systemName: "phone.down.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4)
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    private var navigationTitle: String {
        if case let .chat(_, title) = viewModel.route { return title }
        return NSLocalizedString("_link_", comment: "")
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.route {
        case .home:
            LinkConversationListView(viewModel: viewModel) { room in
                callContext = CallContext(token: room.token, title: room.displayName, withVideo: false, silent: false)
            }
        case let .chat(token, title):
            LinkChatView(viewModel: viewModel, token: token, title: title)
        }
    }
}

/// Hosts the UIKit in-call screen inside SwiftUI.
struct LinkCallViewControllerWrapper: UIViewControllerRepresentable {
    let account: LinkAccount
    let token: String
    let title: String
    let withVideo: Bool
    var silent: Bool = false
    var session: CallSession? = nil

    func makeUIViewController(context: Context) -> LinkCallViewController {
        LinkCallViewController(account: account, token: token, title: title, withVideo: withVideo, silent: silent, session: session)
    }

    func updateUIViewController(_ uiViewController: LinkCallViewController, context: Context) {}
}

#if DEBUG
/// Full-screen incoming call overlay for the simulator (CallKit cannot show
/// incoming calls there): accept starts the call session, decline dismisses.
struct IncomingCallOverlayView: View {
    let title: String
    let hasVideo: Bool
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.14, blue: 0.2), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()
                Text(NSLocalizedString("_link_incoming_call_", comment: ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if hasVideo {
                    Label(NSLocalizedString("_link_video_call_", comment: ""), systemImage: "video.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                HStack(spacing: 60) {
                    Button(action: onDecline) {
                        VStack(spacing: 6) {
                            Image(systemName: "phone.down.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(Circle().fill(Color.red))
                            Text(NSLocalizedString("_link_decline_", comment: ""))
                                .font(.caption)
                                .foregroundStyle(.white)
                        }
                    }
                    Button(action: onAccept) {
                        VStack(spacing: 6) {
                            Image(systemName: "phone.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(Circle().fill(Color.green))
                            Text(NSLocalizedString("_link_accept_", comment: ""))
                                .font(.caption)
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.bottom, 80)
            }
        }
    }
}
#endif

/// The list of conversations with a "start new conversation" search bar.
struct LinkConversationListView: View {
    @ObservedObject var viewModel: LinkViewModel
    @State private var searchQuery = ""
    @State private var deleteRoom: LinkConversation?
    /// Startet einen direkten Audio-Call für den Raum (vom Eltern-View).
    var onCall: (LinkConversation) -> Void = { _ in }

#if DEBUG
    /// Simuliert einen eingehenden Anruf (CallKit liefert im Simulator nicht).
    private func simulateIncomingCall(video: Bool) {
        var token = "debug-token"
        var title = NSLocalizedString("_link_incoming_call_", comment: "")
        if case let .success(rooms) = viewModel.conversations, let first = rooms.first {
            token = first.token
            title = first.displayName
        }
        LinkVoIPManager.shared.simulateIncomingCall(token: token, title: title, hasVideo: video)
    }
#endif

    var body: some View {
        List {
#if DEBUG
            Section(NSLocalizedString("_link_debug_", comment: "")) {
                Button {
                    simulateIncomingCall(video: false)
                } label: {
                    Label(NSLocalizedString("_link_debug_simulate_call_audio_", comment: ""), systemImage: "phone.fill")
                }
                Button {
                    simulateIncomingCall(video: true)
                } label: {
                    Label(NSLocalizedString("_link_debug_simulate_call_video_", comment: ""), systemImage: "video.fill")
                }
            }
#endif
            if !viewModel.userResults.isEmpty {
                Section(NSLocalizedString("_link_start_conversation_", comment: "")) {
                    ForEach(viewModel.userResults) { suggestion in
                        Button {
                            viewModel.startConversation(id: suggestion.id, source: suggestion.source, title: suggestion.label)
                            searchQuery = ""
                        } label: {
                            Label(suggestion.label, systemImage: suggestion.source == "groups" ? "person.3.fill" : "person.crop.circle")
                        }
                    }
                }
            }

            switch viewModel.conversations {
            case .loading:
                HStack { Spacer(); ProgressView(); Spacer() }
            case let .error(message):
                Text(message).foregroundStyle(.secondary)
            case let .success(rooms):
                if rooms.isEmpty {
                    Text(NSLocalizedString("_link_no_conversations_", comment: "")).foregroundStyle(.secondary)
                } else {
                    ForEach(rooms) { room in
                        Button {
                            viewModel.openConversation(token: room.token, title: room.displayName)
                        } label: {
                            LinkConversationRow(room: room)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) {
                            Button {
                                onCall(room)
                            } label: {
                                Label(NSLocalizedString("_link_swipe_call_", comment: ""), systemImage: "phone.fill")
                            }
                            .tint(.green)
                        }
                        .swipeActions(edge: .trailing) {
                            if room.canDelete {
                                Button(role: .destructive) {
                                    deleteRoom = room
                                } label: {
                                    Label(NSLocalizedString("_link_delete_room_", comment: ""), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchQuery, prompt: NSLocalizedString("_link_search_people_", comment: ""))
        .onChange(of: searchQuery) { _, newValue in
            viewModel.searchUsers(query: newValue)
        }
        .refreshable { viewModel.loadConversations() }
        .confirmationDialog(
            NSLocalizedString("_link_delete_room_", comment: ""),
            isPresented: Binding(
                get: { deleteRoom != nil },
                set: { if !$0 { deleteRoom = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("_delete_", comment: ""), role: .destructive) {
                if let room = deleteRoom {
                    Task { await viewModel.deleteConversation(token: room.token) }
                }
                deleteRoom = nil
            }
            Button(NSLocalizedString("_cancel_", comment: ""), role: .cancel) {
                deleteRoom = nil
            }
        } message: {
            Text(NSLocalizedString("_link_delete_room_confirm_", comment: ""))
                + Text("\n\"") + Text(deleteRoom?.displayName ?? "") + Text("\"")
        }
    }
}

private struct LinkConversationRow: View {
    let room: LinkConversation

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(NCBrandColor.shared.customer)).frame(width: 44, height: 44)
                Image(systemName: room.isOneToOne ? "person.fill" : "person.3.fill")
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(room.displayName).font(.body).fontWeight(.medium).lineLimit(1)
                    if room.hasCall {
                        Image(systemName: "phone.fill").foregroundStyle(.green).font(.caption)
                    }
                }
                Text(room.lastMessageText()).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if room.unreadMessages > 0 {
                Text("\(room.unreadMessages)")
                    .font(.caption2).fontWeight(.bold).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color(NCBrandColor.shared.customer)))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// A live chat: message list (auto-scrolls to newest) + composer.
struct LinkChatView: View {
    @ObservedObject var viewModel: LinkViewModel
    let token: String
    let title: String
    @State private var draft = ""
    @State private var showFilePicker = false
    @State private var showNextcloudPicker = false
    @State private var editingMessage: LinkChatMessage?
    @State private var previewURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            composer
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                let didStart = url.startAccessingSecurityScopedResource()
                let data = try? Data(contentsOf: url)
                if didStart { url.stopAccessingSecurityScopedResource() }
                guard let data else { return }
                viewModel.sendAttachment(
                    data: data,
                    fileName: url.lastPathComponent,
                    mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                )
            case .failure:
                break
            }
        }
        .sheet(isPresented: $showNextcloudPicker) {
            NextcloudFilePickerView { selection in
                guard let selection else { return }
                viewModel.shareAttachment(selection)
            }
        }
        .quickLookPreview($previewURL)
    }

    @ViewBuilder
    private var messageList: some View {
        switch viewModel.messages {
        case .loading:
            Spacer(); ProgressView(); Spacer()
        case let .error(message):
            Spacer(); Text(message).foregroundStyle(.secondary); Spacer()
        case let .success(items):
            ScrollViewReader { proxy in
                List {
                    ForEach(items.filter { !$0.isSystemMessage }) { message in
                        LinkMessageRow(
                            viewModel: viewModel,
                            message: message,
                            isOwn: message.actorId == viewModel.currentUserId,
                            onStartEdit: { editingMessage = message; draft = message.message },
                            onOpenFile: { info in
                                Task {
                                    if let url = await viewModel.downloadAttachment(info) {
                                        previewURL = url
                                    }
                                }
                            }
                        )
                        .id(message.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: items.count) { _, _ in
                    scrollToBottom(proxy, items: items)
                }
                .onAppear {
                    scrollToBottom(proxy, items: items)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, items: [LinkChatMessage]) {
        guard let last = items.last else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if editingMessage != nil {
                HStack {
                    Text(NSLocalizedString("_link_edit_message_", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(NSLocalizedString("_cancel_", comment: "")) {
                        editingMessage = nil
                        draft = ""
                    }
                    .font(.caption)
                    Button(NSLocalizedString("_contact_save_", comment: "")) {
                        if let message = editingMessage {
                            viewModel.editMessage(message, text: draft)
                            editingMessage = nil
                            draft = ""
                        }
                    }
                    .font(.caption).bold()
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                Divider()
            }
            HStack(spacing: 8) {
            Menu {
                Button {
                    showFilePicker = true
                } label: {
                    Label(NSLocalizedString("_link_attach_file_", comment: ""), systemImage: "doc.badge.plus")
                }
                Button {
                    showNextcloudPicker = true
                } label: {
                    Label(NSLocalizedString("_link_share_file_", comment: ""), systemImage: "building.columns")
                }
            } label: {
                Image(systemName: "paperclip")
                    .foregroundStyle(Color(NCBrandColor.shared.customer))
                    .frame(width: 30, height: 30)
            }
            TextField(NSLocalizedString("_link_message_", comment: ""), text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
            Button {
                let text = draft
                draft = ""
                viewModel.send(text: text)
            } label: {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color(NCBrandColor.shared.customer))
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }
}

/// One chat message row: bubble, optional file chip, swipe actions
/// (delete/edit for own messages).
private struct LinkMessageRow: View {
    @ObservedObject var viewModel: LinkViewModel
    let message: LinkChatMessage
    let isOwn: Bool
    let onStartEdit: () -> Void
    let onOpenFile: (LinkFileInfo) -> Void

    var body: some View {
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
            if let file = message.fileInfo() {
                Button {
                    onOpenFile(file)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip").font(.caption)
                        Text(file.name).font(.caption).lineLimit(1)
                        if file.size > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            LinkMessageBubble(message: message, isOwn: isOwn)
        }
        .swipeActions(edge: .trailing) {
            if isOwn {
                Button {
                    viewModel.deleteMessage(message)
                } label: {
                    Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash")
                }
                .tint(.red)
                Button {
                    onStartEdit()
                } label: {
                    Label(NSLocalizedString("_contact_edit_", comment: ""), systemImage: "pencil")
                }
                .tint(.blue)
            }
        }
    }
}

private struct LinkMessageBubble: View {
    let message: LinkChatMessage
    let isOwn: Bool

    var body: some View {
        HStack {
            if isOwn { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 2) {
                if !isOwn {
                    Text(message.actorDisplayName).font(.caption2).foregroundStyle(.secondary)
                }
                Text(displayText)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isOwn ? Color(NCBrandColor.shared.customer).opacity(0.9) : Color(.secondarySystemBackground))
            )
            .foregroundStyle(isOwn ? .white : .primary)
            if !isOwn { Spacer(minLength: 40) }
        }
    }

    private var displayText: String {
        if let file = message.fileName() { return "📎 \(file)" }
        return message.message
    }
}
