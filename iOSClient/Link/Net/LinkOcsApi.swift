// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from souvera_android link/net/OcsApi.kt.
//
// Thin client for the Nextcloud Talk ("Link") OCS API (app `spreed`). Uses HTTP Basic with the
// account app-password, exactly like NextcloudKit. Long-poll requests get their own long read
// timeout; everything else uses the short one. Chat is API v1, rooms are API v4.

import Foundation

actor LinkOcsApi {
    private let account: LinkAccount
    private let base: String
    private let root: String
    private let session: URLSession
    private let longPollSession: URLSession
    private let decoder = JSONDecoder()

    init(account: LinkAccount) {
        self.account = account
        self.root = account.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.base = self.root + "/ocs/v2.php/apps/spreed"

        let short = URLSessionConfiguration.ephemeral
        short.timeoutIntervalForRequest = Self.readTimeout
        short.timeoutIntervalForResource = Self.readTimeout
        self.session = URLSession(configuration: short)

        let long = URLSessionConfiguration.ephemeral
        long.timeoutIntervalForRequest = Self.longPollTimeout
        long.timeoutIntervalForResource = Self.longPollTimeout
        self.longPollSession = URLSession(configuration: long)
    }

    // MARK: - Rooms & chat

    func listConversations() async -> [LinkConversation] {
        guard let body = await get("\(base)/api/v4/room") else { return [] }
        return decodeList(body)
    }

    /// Recent history (`future=false`) or the long-poll for new messages (`future=true`). For the
    /// initial history fetch `lastKnownId` is 0 and MUST be omitted — sending `lastKnownMessageId=0`
    /// with lookIntoFuture=0 means "messages older than 0" and returns nothing. The long-poll always
    /// sends it (0 = from the beginning).
    func getMessages(token: String, lastKnownId: Int64, future: Bool, timeoutSeconds: Int) async -> [LinkChatMessage] {
        let includeLastKnown = future || lastKnownId > 0
        let lastKnownParam = includeLastKnown ? "&lastKnownMessageId=\(lastKnownId)" : ""
        let url = "\(base)/api/v1/chat/\(token)?lookIntoFuture=\(future ? 1 : 0)" +
            "\(lastKnownParam)&timeout=\(timeoutSeconds)&limit=\(Self.pageLimit)&setReadMarker=1"
        guard let body = await get(url, longPoll: future) else { return [] }
        return decodeList(body)
    }

    func sendMessage(token: String, message: String) async {
        let payload = try? JSONSerialization.data(withJSONObject: ["message": message])
        var req = signed(url: "\(base)/api/v1/chat/\(token)", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        _ = try? await session.data(for: req)
    }

    /// Autocomplete users/groups to start a new conversation with.
    func searchUsers(query: String) async -> [LinkSuggestion] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = "\(root)/ocs/v2.php/core/autocomplete/get?search=\(encoded)&itemType=call&itemId=new" +
            "&shareTypes[]=0&shareTypes[]=1&limit=\(Self.searchLimit)"
        guard let body = await get(url) else { return [] }
        return decodeList(body)
    }

    /// Creates (or returns) a conversation with [invite]; roomType 1 = one-to-one user, 2 = group.
    func createConversation(invite: String, roomType: Int) async -> String? {
        let encoded = invite.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? invite
        let src = roomType == LinkRoomType.group.rawValue ? "&source=groups" : ""
        let req = signed(url: "\(base)/api/v4/room?roomType=\(roomType)&invite=\(encoded)\(src)", method: "POST")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode ?? 500 < 300 else { return nil }
        let env: OcsEnvelope<LinkConversation>? = try? decoder.decode(OcsEnvelope<LinkConversation>.self, from: data)
        return env?.ocs.data?.token
    }

    /// Creates a public group conversation with the given name (used for the
    /// calendar's "create Talk channel for this event" action). Returns the
    /// conversation token and display name.
    func createEventRoom(name: String) async -> (token: String, name: String)? {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let req = signed(url: "\(base)/api/v4/room?roomType=3&roomName=\(encoded)", method: "POST")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode ?? 500 < 300 else { return nil }
        let env: OcsEnvelope<LinkConversation>? = try? decoder.decode(OcsEnvelope<LinkConversation>.self, from: data)
        guard let token = env?.ocs.data?.token else { return nil }
        return (token, env?.ocs.data?.displayName ?? name)
    }

    /// Adds users (email/user ids) to a conversation.
    func addParticipants(token: String, userIds: [String]) async {
        for userId in userIds {
            let encoded = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? userId
            let req = signed(url: "\(base)/api/v4/room/\(token)/participants?source=users&newParticipant=\(encoded)", method: "POST")
            _ = try? await session.data(for: req)
        }
    }

    // MARK: - Calls / signaling

    func getSignalingSettings(token: String) async -> SignalingSettings? {
        let url = "\(root)/ocs/v2.php/apps/spreed/api/v3/signaling/settings?token=\(token)"
        guard let body = await get(url),
              let data = body.data(using: .utf8),
              let env = try? decoder.decode(OcsEnvelope<SignalingSettings>.self, from: data) else { return nil }
        return env.ocs.data
    }

    /// Joins the room as an active participant; returns the Nextcloud session id (for HPB room join).
    func joinRoom(token: String) async -> String? {
        let req = signed(url: "\(base)/api/v4/room/\(token)/participants/active", method: "POST")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode ?? 500 < 300 else { return nil }
        let env = try? decoder.decode(OcsEnvelope<JoinRoomData>.self, from: data)
        return env?.ocs.data?.sessionId
    }

    func joinCall(token: String, flags: Int) async {
        // Talk expects form-encoded fields; recordingConsent is mandatory
        // when the server enforces recording consent (otherwise 400
        // {"error":"consent"} and no call is opened).
        var req = signed(url: "\(base)/api/v4/call/\(token)", method: "POST")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "flags=\(flags)&silent=false&recordingConsent=true".data(using: .utf8)
        let result = try? await session.data(for: req)
        let status = (result?.1 as? HTTPURLResponse)?.statusCode ?? -1
        var bodySnippet = ""
        if let data = result?.0, let text = String(data: data, encoding: .utf8) {
            bodySnippet = String(text.prefix(200))
        }
        CallDebugLog.log("OcsApi", "joinCall http=\(status) body=\(bodySnippet)")
    }

    func leaveCall(token: String) async {
        let req = signed(url: "\(base)/api/v4/call/\(token)", method: "DELETE")
        _ = try? await session.data(for: req)
    }

    /// Uploads a local file into the chat (multipart POST to the v1 chat
    /// endpoint - the v4 chat route does not exist for uploads).
    func uploadFileToChat(token: String, data: Data, fileName: String, mimeType: String) async -> Bool {
        guard let url = URL(string: "\(base)/api/v1/chat/\(token)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(account.basicAuthHeader, forHTTPHeaderField: "Authorization")
        req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        let boundary = "SouveraBoundary\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ string: String) {
            if let chunk = string.data(using: .utf8) { body.append(chunk) }
        }
        // Talk requires a non-empty message field alongside the file
        // (an empty message part is rejected with 400).
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"message\"\r\n\r\n\(fileName)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        guard let (_, response) = try? await session.data(for: req) else { return false }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        CallDebugLog.log("OcsApi", "uploadFileToChat http=\(status)")
        return (200..<300).contains(status)
    }

    /// Shares a Souvera/Nextcloud file into the conversation via the
    /// files_sharing API (room share type 10), mirroring the Android client.
    /// The share itself creates the chat message.
    func shareFileToChat(token: String, relativePath: String) async -> Bool {
        var components = URLComponents(string: "\(root)/ocs/v2.php/apps/files_sharing/api/v1/shares")!
        components.queryItems = [
            URLQueryItem(name: "path", value: relativePath),
            URLQueryItem(name: "shareType", value: "10"),
            URLQueryItem(name: "shareWith", value: token)
        ]
        let req = signed(url: components.url?.absoluteString ?? "", method: "POST")
        guard let (data, response) = try? await session.data(for: req) else { return false }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        var bodySnippet = ""
        if let text = String(data: data, encoding: .utf8) {
            bodySnippet = String(text.prefix(200))
        }
        CallDebugLog.log("OcsApi", "shareFileToChat http=\(status) body=\(bodySnippet)")
        return (200..<300).contains(status)
    }

    private struct JoinRoomData: Decodable { let sessionId: String? }

    private struct CallParticipant: Decodable {
        let displayName: String?
        let inCall: Int?
    }

    /// Display names of the room participants currently in a call.
    func callParticipantNames(token: String) async -> [String] {
        guard let body = await get("\(base)/api/v4/room/\(token)/participants"),
              let data = body.data(using: .utf8),
              let env = try? decoder.decode(OcsEnvelope<[CallParticipant]>.self, from: data) else { return [] }
        return (env.ocs.data ?? [])
            .filter { ($0.inCall ?? 0) != 0 }
            .compactMap { $0.displayName }
            .filter { !$0.isEmpty }
    }

    // MARK: - HTTP plumbing

    private func get(_ url: String, longPoll: Bool = false) async -> String? {
        let req = signed(url: url, method: "GET")
        let used = longPoll ? longPollSession : session
        guard let (data, response) = try? await used.data(for: req),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == Self.notModified { return nil }
        guard (200..<300).contains(http.statusCode) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func signed(url: String, method: String) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.setValue(account.basicAuthHeader, forHTTPHeaderField: "Authorization")
        req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func decodeList<T: Decodable>(_ body: String) -> [T] {
        guard let data = body.data(using: .utf8),
              let env = try? decoder.decode(OcsEnvelope<[T]>.self, from: data) else { return [] }
        return env.ocs.data ?? []
    }

    private static let connectTimeout: TimeInterval = 15
    private static let readTimeout: TimeInterval = 40
    private static let longPollTimeout: TimeInterval = 60
    private static let pageLimit = 100
    private static let notModified = 304
    private static let searchLimit = 20
    static let shareTypeRoom = 10
}
