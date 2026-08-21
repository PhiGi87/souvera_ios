// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from souvera_android link/ui/LinkViewModel.kt + LinkUiState.kt + LinkRoute.kt.
//
// Drives the native "Link" (Nextcloud Talk) chat: loads the conversation list, opens a chat, and
// keeps it live via the Talk chat long-poll (lookIntoFuture=1, 30s). Auth is the account
// app-password — the same credential the rest of the app uses.

import Foundation
import Combine

extension Notification.Name {
    /// Posted when another module (e.g. the calendar) wants the Link tab to
    /// open a specific conversation.
    static let openLinkRoom = Notification.Name("SouveraOpenLinkRoom")
}

/// Loading/content/error state for a Link screen's data.
enum LinkUiState<T> {
    case loading
    case success(T)
    case error(String)
}

/// Which Link screen is showing.
enum LinkRoute: Equatable {
    case home
    case chat(token: String, title: String)
}

@MainActor
final class LinkViewModel: ObservableObject {
    /// Room requested by another module while the Link tab was not visible;
    /// opened on the next appearance.
    static var pendingOpenRoom: (token: String, title: String)?

    @Published var route: LinkRoute = .home
    @Published var conversations: LinkUiState<[LinkConversation]> = .loading
    @Published var messages: LinkUiState<[LinkChatMessage]> = .loading
    @Published var userResults: [LinkSuggestion] = []

    private(set) var currentUserId: String = ""

    private var api: LinkOcsApi?
    private var pollTask: Task<Void, Never>?
    private var lastMessageId: Int64 = 0

    private let pollTimeout = 30
    private let historyAnchor: Int64 = 2_000_000_000

    /// Resolves the active account and loads the conversation list. Idempotent.
    func start() {
        if api != nil { return }
        guard let account = LinkAccount.active() else {
            conversations = .error("No account")
            return
        }
        currentUserId = account.username
        api = LinkOcsApi(account: account)
        loadConversations()
    }

    func searchUsers(query: String) {
        guard let api else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            userResults = []
            return
        }
        Task {
            let results = await api.searchUsers(query: trimmed)
            self.userResults = results
        }
    }

    func startConversation(id: String, source: String, title: String) {
        guard let api else { return }
        let roomType = source == "groups" ? LinkRoomType.group.rawValue : LinkRoomType.oneToOne.rawValue
        Task {
            let token = await api.createConversation(invite: id, roomType: roomType)
            self.userResults = []
            if let token {
                self.loadConversations()
                self.openConversation(token: token, title: title)
            }
        }
    }

    func loadConversations() {
        guard let api else { return }
        Task {
            let list = await api.listConversations()
            self.conversations = .success(list.sorted { $0.lastActivity > $1.lastActivity })
        }
    }

    func openConversation(token: String, title: String) {
        route = .chat(token: token, title: title)
        messages = .loading
        lastMessageId = 0
        pollTask?.cancel()
        guard let api else { return }
        pollTask = Task {
            // Load the newest messages: lookIntoFuture=0 pages backwards from a high anchor id, so
            // it returns the most recent page (there is no "give me the latest" without an anchor).
            let history = await api.getMessages(token: token, lastKnownId: historyAnchor, future: false, timeoutSeconds: 0)
            if Task.isCancelled { return }
            let ordered = history.sorted { $0.id < $1.id }
            self.lastMessageId = ordered.last?.id ?? 0
            self.messages = .success(ordered)
            await self.pollNewMessages(token: token)
        }
    }

    private func pollNewMessages(token: String) async {
        guard let api else { return }
        while !Task.isCancelled, case let .chat(currentToken, _) = route, currentToken == token {
            let fresh = await api.getMessages(token: token, lastKnownId: lastMessageId, future: true, timeoutSeconds: pollTimeout)
            if Task.isCancelled { return }
            if !fresh.isEmpty {
                lastMessageId = fresh.map(\.id).max() ?? lastMessageId
                let current: [LinkChatMessage]
                if case let .success(existing) = messages { current = existing } else { current = [] }
                let merged = (current + fresh)
                var seen = Set<Int64>()
                let deduped = merged.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
                messages = .success(deduped)
            }
        }
    }

    func send(text: String) {
        guard let api else { return }
        guard case let .chat(token, _) = route else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        Task { await api.sendMessage(token: token, message: trimmed) }
    }

    @discardableResult
    func back() -> Bool {
        if case .chat = route {
            pollTask?.cancel()
            route = .home
            loadConversations()
            return true
        }
        return false
    }

    deinit { pollTask?.cancel() }
}
