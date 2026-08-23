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

    /// Avatar-URL des Raums (1:1-Räume liefern den Avatar des Gegenübers).
    func roomAvatarURL(token: String) -> String {
        "\(base)/api/v4/room/\(token)/avatar"
    }

    /// Avatar-URL eines Nextcloud-Benutzers (öffentliche Avatar-Route).
    func userAvatarURL(actorId: String, size: Int = 64) -> String {
        let encoded = actorId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? actorId
        return "\(root)/index.php/avatar/\(encoded)/\(size)"
    }

    /// Lädt ein Binärbild (Avatar) mit den Konto-Zugangsdaten.
    func fetchImage(url: String) async -> Data? {
        guard let url = URL(string: url) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(account.basicAuthHeader, forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
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

    func sendMessage(token: String, message: String, replyTo: Int64? = nil) async {
        var body: [String: Any] = ["message": message]
        if let replyTo { body["replyTo"] = replyTo }
        let payload = try? JSONSerialization.data(withJSONObject: body)
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

    /// Creates a public group conversation for a calendar event (mirrors the
    /// Nextcloud Calendar web app): room name = event title, the conversation
    /// is linked to the event via Talk's object reference (objectType=event,
    /// objectId=event UID) and the event notes become the room description.
    /// Returns the conversation token and display name.
    func createEventRoom(name: String, objectId: String, description: String) async -> (token: String, name: String)? {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "roomType", value: "3"),
            URLQueryItem(name: "roomName", value: name),
            URLQueryItem(name: "objectType", value: "event"),
            URLQueryItem(name: "objectId", value: objectId),
            URLQueryItem(name: "description", value: description)
        ]
        guard let query = components.query else { return nil }
        let url = "\(base)/api/v4/room?\(query)"
        // Server kann kurz 503 liefern - mit kleinem Abstand wiederholen.
        for attempt in 1...3 {
            let req = signed(url: url, method: "POST")
            guard let (data, response) = try? await session.data(for: req) else {
                JmapLog.write("createEventRoom attempt \(attempt): transport failure")
                if attempt < 3 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                continue
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            JmapLog.write("createEventRoom attempt \(attempt): HTTP \(status) \(body)")
            if status < 300 {
                let env: OcsEnvelope<LinkConversation>? = try? decoder.decode(OcsEnvelope<LinkConversation>.self, from: data)
                guard let token = env?.ocs.data?.token else { return nil }
                return (token, env?.ocs.data?.displayName ?? name)
            }
            if status == 503 || status >= 500 {
                if attempt < 3 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                continue
            }
            return nil
        }
        return nil
    }

    /// Adds participants: internal Souvera users by user id (`source=users`),
    /// external guests by email (`source=emails`, Talk sends the invite).
    func addParticipants(token: String, userIds: [String], emails: [String], federatedIds: [String] = []) async {
        for userId in userIds {
            let encoded = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? userId
            let req = signed(url: "\(base)/api/v4/room/\(token)/participants?source=users&newParticipant=\(encoded)", method: "POST")
            _ = try? await session.data(for: req)
        }
        for email in emails {
            let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
            let req = signed(url: "\(base)/api/v4/room/\(token)/participants?source=emails&newParticipant=\(encoded)", method: "POST")
            _ = try? await session.data(for: req)
        }
        for federatedId in federatedIds {
            let encoded = federatedId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? federatedId
            let req = signed(url: "\(base)/api/v4/room/\(token)/participants?source=federated_users&newParticipant=\(encoded)", method: "POST")
            _ = try? await session.data(for: req)
        }
    }

    /// Deletes a conversation completely (used when the Talk link is removed
    /// from a calendar event).
    @discardableResult
    func deleteRoom(token: String) async -> Int {
        let req = signed(url: "\(base)/api/v4/room/\(token)", method: "DELETE")
        let result = try? await session.data(for: req)
        let status = (result?.1 as? HTTPURLResponse)?.statusCode ?? -1
        CallDebugLog.log("OcsApi", "deleteRoom \(token) -> \(status)")
        return status
    }

    /// Enables or disables the lobby for non-moderators (Talk stores this as
    /// lobbyState). Used when external guests join an event room.
    func setLobby(token: String, enabled: Bool) async {
        let req = signed(url: "\(base)/api/v4/room/\(token)/webinar/lobby?state=\(enabled ? 1 : 0)", method: "PUT")
        _ = try? await session.data(for: req)
    }

    // MARK: - Federation / externe Teilnehmer

    /// Talk-Federation für ausgehende Einladungen aktiv? (einmalig gecacht)
    private var federationEnabledCache: Bool?

    func isFederationOutgoingEnabled() async -> Bool {
        if let federationEnabledCache { return federationEnabledCache }
        guard let body = await get("\(root)/ocs/v2.php/cloud/capabilities?format=json"),
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = json["ocs"] as? [String: Any],
              let capsData = ocs["data"] as? [String: Any],
              let capabilities = capsData["capabilities"] as? [String: Any],
              let spreed = capabilities["spreed"] as? [String: Any],
              let config = spreed["config"] as? [String: Any],
              let federation = config["federation"] as? [String: Any] else {
            return false
        }
        federationEnabledCache = (federation["outgoing-enabled"] as? Bool) ?? false
        return federationEnabledCache ?? false
    }

    /// Emoji-Reaktion auf eine Nachricht setzen.
    func addReaction(token: String, messageId: Int64, emoji: String) async -> Bool {
        var req = signed(url: "\(base)/api/v1/reaction/\(token)/\(messageId)", method: "POST")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encoded = emoji.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? emoji
        req.httpBody = "reaction=\(encoded)".data(using: .utf8)
        guard let (_, response) = try? await session.data(for: req) else { return false }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        CallDebugLog.log("OcsApi", "addReaction \(messageId) \(emoji) -> \(status)")
        return (200..<300).contains(status)
    }

    /// Emoji-Reaktion entfernen.
    func removeReaction(token: String, messageId: Int64, emoji: String) async -> Bool {
        var req = signed(url: "\(base)/api/v1/reaction/\(token)/\(messageId)", method: "DELETE")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encoded = emoji.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? emoji
        req.httpBody = "reaction=\(encoded)".data(using: .utf8)
        guard let (_, response) = try? await session.data(for: req) else { return false }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        CallDebugLog.log("OcsApi", "removeReaction \(messageId) \(emoji) -> \(status)")
        return (200..<300).contains(status)
    }

    /// Teilnehmer einer Konversation auflisten.
    func listParticipants(token: String) async -> [LinkParticipant] {
        guard let body = await get("\(base)/api/v4/room/\(token)/participants") else { return [] }
        return decodeList(body)
    }

    /// Teilnehmer entfernen (erfordert Moderator-Recht; attendeeId aus der
    /// Teilnehmerliste).
    func removeParticipant(token: String, attendeeId: Int) async -> Bool {
        var req = signed(url: "\(base)/api/v4/room/\(token)/participants", method: "DELETE")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "attendeeId=\(attendeeId)".data(using: .utf8)
        guard let (_, response) = try? await session.data(for: req) else { return false }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        CallDebugLog.log("OcsApi", "removeParticipant \(token) attendee=\(attendeeId) -> \(status)")
        return (200..<300).contains(status)
    }

    /// Erstellt eine (öffentliche) Gruppenkonversation für externe Teilnehmer.
    func createGroupRoom(name: String) async -> String? {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let req = signed(url: "\(base)/api/v4/room?roomType=3&roomName=\(encoded)", method: "POST")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode ?? 500 < 300 else { return nil }
        let env: OcsEnvelope<LinkConversation>? = try? decoder.decode(OcsEnvelope<LinkConversation>.self, from: data)
        return env?.ocs.data?.token
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

    func joinCall(token: String, flags: Int, silent: Bool = false) async {
        // Talk expects form-encoded fields; recordingConsent is mandatory
        // when the server enforces recording consent (otherwise 400
        // {"error":"consent"} and no call is opened). A silent join does not
        // ring the other participants.
        var req = signed(url: "\(base)/api/v4/call/\(token)", method: "POST")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "flags=\(flags)&silent=\(silent ? "true" : "false")&recordingConsent=true".data(using: .utf8)
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
        // (an empty message part is rejected with 400). The Content-
        // Disposition header must stay ASCII - non-ASCII file names would
        // break the multipart parsing server-side (the file part gets
        // dropped and only the name is shown).
        let headerName = fileName
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"message\"\r\n\r\n\(fileName)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(headerName.isEmpty ? "file" : headerName)\"\r\n")
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
    /// Deletes a chat message (own messages).
    func deleteMessage(token: String, messageId: Int64) async -> Bool {
        let req = signed(url: "\(base)/api/v1/chat/\(token)/\(messageId)", method: "DELETE")
        guard let (_, response) = try? await session.data(for: req) else { return false }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        CallDebugLog.log("OcsApi", "deleteMessage \(messageId) http=\(status)")
        return (200..<300).contains(status)
    }

    /// Edits a chat message (own messages).
    func editMessage(token: String, messageId: Int64, text: String) async -> Bool {
        var req = signed(url: "\(base)/api/v1/chat/\(token)/\(messageId)", method: "PUT")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "message=\(text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text)".data(using: .utf8)
        guard let (_, response) = try? await session.data(for: req) else { return false }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        CallDebugLog.log("OcsApi", "editMessage \(messageId) http=\(status)")
        return (200..<300).contains(status)
    }

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
