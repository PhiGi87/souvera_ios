// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// SwiftUI surface for "Link" (Nextcloud Talk): conversation list + live chat. Mirrors the android
// link/ui Compose screens (ConversationListScreen, ChatScreen) but idiomatic SwiftUI.

import SwiftUI

/// Root Link screen; switches between the conversation list and an open chat.
struct LinkView: View {
    @StateObject private var viewModel = LinkViewModel()
    @State private var callContext: CallContext?

    struct CallContext: Identifiable {
        let token: String
        let title: String
        let withVideo: Bool
        var id: String { "\(token)|\(withVideo)" }
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
                                callContext = CallContext(token: token, title: title, withVideo: false)
                            } label: {
                                Image(systemName: "phone.fill").foregroundStyle(.green)
                            }
                            Button {
                                callContext = CallContext(token: token, title: title, withVideo: true)
                            } label: {
                                Image(systemName: "video.fill").foregroundStyle(Color(NCBrandColor.shared.customer))
                            }
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
        .fullScreenCover(item: $callContext) { context in
            if let account = LinkAccount.active() {
                LinkCallViewControllerWrapper(
                    account: account,
                    token: context.token,
                    title: context.title,
                    withVideo: context.withVideo
                )
                .ignoresSafeArea()
            }
        }
    }

    private var navigationTitle: String {
        if case let .chat(_, title) = viewModel.route { return title }
        return NSLocalizedString("_link_", comment: "")
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.route {
        case .home:
            LinkConversationListView(viewModel: viewModel)
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

    func makeUIViewController(context: Context) -> LinkCallViewController {
        LinkCallViewController(account: account, token: token, title: title, withVideo: withVideo)
    }

    func updateUIViewController(_ uiViewController: LinkCallViewController, context: Context) {}
}

/// The list of conversations with a "start new conversation" search bar.
struct LinkConversationListView: View {
    @ObservedObject var viewModel: LinkViewModel
    @State private var searchQuery = ""

    var body: some View {
        List {
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

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            composer
        }
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
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(items.filter { !$0.isSystemMessage }) { message in
                            LinkMessageBubble(message: message, isOwn: message.actorId == viewModel.currentUserId)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: items.count) { _, _ in
                    if let last = items.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onAppear {
                    if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
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
