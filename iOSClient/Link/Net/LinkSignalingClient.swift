// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Typing-Indikatoren über das Talk-Signaling (externer Modus, wie Talk Web):
/// verbindet per WebSocket zum Signaling-Server, tritt dem Raum bei und
/// tauscht `signalingTypingStart`/`signalingTypingStop`-Events aus.
@MainActor
final class LinkSignalingClient: NSObject, URLSessionWebSocketDelegate {
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var account: LinkAccount?
    private var token = ""
    private var roomId = ""
    private var sessionId = ""
    private var ownUserId = ""
    private var connected = false
    private var lastSettings: [String: Any]?
    private var lastRoomIdInt = 0

    /// Anzeigename -> Zeitpunkt des letzten TypingStart (Expiry ~8 s).
    private var activeTypers: [String: Date] = [:]
    private var expiryTask: Task<Void, Never>?
    private var localTypingActive = false
    private var localIdleTask: Task<Void, Never>?
    private var lastLocalSent = Date.distantPast

    /// Wird mit der aktuellen Liste tippender Anzeigenamen aufgerufen.
    var onTypingChanged: (([String]) -> Void)?
    /// Teilnehmer-Events (Join/Leave/usersInRoom, Run 15.09.) - triggert
    /// den Sofort-Refresh der Lobby-Verwaltung/Teilnehmerliste.
    var onParticipantsChanged: (() -> Void)?
    /// Signaling-User-Daten (Run 15.09.): sessionId -> (Name, E-Mail) aus
    /// dem Backend-`user`-Objekt. Talk-Web bezieht die Klartext-E-Mail
    /// von Gaesten genau hierher (die OCS-Teilnehmerliste liefert nur den
    /// SHA-256-Hash der E-Mail als actorId).
    var onUserInfoChanged: (([String: LinkSignalingUserInfo]) -> Void)?
    private var userInfoBySessionId: [String: LinkSignalingUserInfo] = [:]
    /// Interner Signaling-Long-Poll (Run 15.09.): ohne HPB liefert
    /// `signaling/settings` keinen WS-Server - dann zieht der OCS-Pull
    /// die Teilnehmer-/User-Nachrichten (usersInRoom/join).
    private var internalPollTask: Task<Void, Never>?

    // MARK: - Verbindung

    func connect(account: LinkAccount, token: String, roomId: Int, settings: [String: Any]) {
        disconnect()
        self.account = account
        self.token = token
        self.roomId = String(roomId)
        self.lastRoomIdInt = roomId
        self.lastSettings = settings
        sessionId = UUID().uuidString
        ownUserId = settings["userId"] as? String ?? ""

        guard let ticket = settings["ticket"] as? String, !ticket.isEmpty else { return }
        if let server = settings["server"] as? String, !server.isEmpty {
            startWebSocket(server: server)
        } else {
            // Kein HPB: interner Signaling-Long-Poll (OCS-Auth).
            startInternalPolling()
            return
        }
        receiveLoop()
        sendHello(ticket: ticket)
    }

    private func startWebSocket(server: String) {
        let host = server
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "wss://\(host)") else { return }

        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        session = s
        webSocket = s.webSocketTask(with: url)
        webSocket?.resume()
    }

    /// Hello ueber den WS (HPB-Pfad).
    private func sendHello(ticket: String) {
        guard let account else { return }
        let authUrl = "\(account.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/ocs/v2.php/apps/spreed/api/v3/signaling/\(token)"
        let hello: [String: Any] = [
            "type": "hello",
            "hello": [
                "version": "1.0",
                "auth": [
                    "url": authUrl,
                    "params": ["userid": account.username, "ticket": ticket]
                ]
            ]
        ]
        send(json: hello)
    }

    /// Interner Signaling-Long-Poll (ohne HPB): POST /signaling/{token}
    /// mit messages=[] - die Antwort enthaelt JSON-Nachrichten
    /// (usersInRoom/join) mit den Backend-User-Daten.
    private func startInternalPolling() {
        internalPollTask?.cancel()
        guard let accountValue = account else { return }
        let tokenValue = token
        internalPollTask = Task { [weak self] in
            let base = accountValue.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(base)/ocs/v2.php/apps/spreed/api/v3/signaling/\(tokenValue)") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(accountValue.basicAuthHeader, forHTTPHeaderField: "Authorization")
            req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            while !Task.isCancelled {
                req.httpBody = "messages=[]".data(using: .utf8)
                if let (data, response) = try? await URLSession.shared.data(for: req),
                   let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    await self?.parseInternalSignaling(data: data)
                    // Bei sofort-leeren Antworten nicht schleifen.
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    /// Interne Signaling-Nachrichten: ocs.data = [ { "message": "<json>" } ]
    /// (oder direkt Objekte) - sessions extrahieren und melden.
    private func parseInternalSignaling(data: Data) {
        guard let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = env["ocs"] as? [String: Any],
              let payload = ocs["data"] as? [Any] else { return }
        var sessionObjects: [[String: Any]] = []
        var hadMessages = false
        for entry in payload {
            let messageDict: [String: Any]?
            if let dict = entry as? [String: Any] {
                if let messageString = dict["message"] as? String,
                   let inner = try? JSONSerialization.jsonObject(with: Data(messageString.utf8)) as? [String: Any] {
                    messageDict = inner
                } else {
                    messageDict = dict
                }
            } else {
                messageDict = nil
            }
            guard let msg = messageDict else { continue }
            hadMessages = true
            let type = msg["type"] as? String ?? ""
            if type == "usersInRoom", let users = msg["usersInRoom"] as? [[String: Any]] {
                sessionObjects.append(contentsOf: users)
            }
            if type == "join", let join = msg["join"] as? [[String: Any]] {
                sessionObjects.append(contentsOf: join)
            }
            if type == "participantsUpdate", let update = msg["update"] as? [[String: Any]] {
                sessionObjects.append(contentsOf: update)
            }
        }
        guard hadMessages, !sessionObjects.isEmpty else { return }
        let extracted = extractSessionObjects(from: sessionObjects)
        applyUserInfo(extracted)
        onParticipantsChanged?()
    }

    /// Session-Objekte (WS oder intern) -> User-Infos.
    private func extractSessionObjects(from sessionObjects: [[String: Any]]) -> [String: LinkSignalingUserInfo] {
        var result: [String: LinkSignalingUserInfo] = [:]
        for session in sessionObjects {
            let key = session["roomsessionid"] as? String
                ?? session["sessionId"] as? String
                ?? session["sessionid"] as? String
                ?? ""
            guard !key.isEmpty else { continue }
            let user = session["user"] as? [String: Any] ?? session
            let name = (user["displayName"] as? String)
                ?? (user["displayname"] as? String)
            let email = (user["email"] as? String)
                ?? (user["emailAddress"] as? String)
                ?? (user["emailaddress"] as? String)
            result[key] = LinkSignalingUserInfo(sessionId: key, displayName: name, email: email)
        }
        return result
    }

    private func applyUserInfo(_ infos: [String: LinkSignalingUserInfo]) {
        for (key, info) in infos {
            userInfoBySessionId[key] = info
            if let name = info.displayName, !name.isEmpty {
                CallDebugLog.log("Signaling", "user info session=\(key.prefix(10))... name=\(name) email=\(info.email ?? "-")")
            }
        }
        if !infos.isEmpty {
            onUserInfoChanged?(userInfoBySessionId)
        }
    }

    func disconnect() {
        internalPollTask?.cancel()
        internalPollTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        session = nil
        connected = false
        expiryTask?.cancel()
        expiryTask = nil
        localIdleTask?.cancel()
        localIdleTask = nil
        localTypingActive = false
        if !activeTypers.isEmpty {
            activeTypers = [:]
            onTypingChanged?([])
        }
    }

    private func scheduleReconnect() {
        guard let account, let settings = lastSettings, !token.isEmpty else { return }
        let roomIdInt = lastRoomIdInt
        let tokenValue = token
        let accountValue = account
        let settingsValue = settings
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.connected { return }
            self.connect(account: accountValue, token: tokenValue, roomId: roomIdInt, settings: settingsValue)
        }
    }

    // MARK: - Nachrichten

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(text)) { _ in }
    }

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handle(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handle(text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveLoop()
                case .failure:
                    self.connected = false
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch json["type"] as? String {
        case "hello":
            connected = true
            joinRoom()
        case "event":
            handleEvent((json["event"] as? [String: Any]) ?? [:])
        default:
            break
        }
    }

    private func joinRoom() {
        guard connected, !roomId.isEmpty else { return }
        let room: [String: Any] = [
            "type": "room",
            "room": ["roomid": roomId, "sessionid": sessionId]
        ]
        send(json: room)
    }

    private func handleEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        // Teilnehmer-Events (Run 15.09.): sofortiger Refresh, damit Namen
        // (auch nachgeruestete externe) und Anwesenheit ohne Poll-Delay
        // in der Lobby-Verwaltung ankommen.
        if type.contains("participants") || type.contains("usersInRoom")
            || type == "join" || type == "leave" {
            parseUserInfos(event: event)
            onParticipantsChanged?()
        }
        guard type.hasPrefix("signalingTyping") else { return }
        let typing = event["typing"] as? [String: Any]
        let user = typing?["user"] as? [String: Any]
        let name = user?["displayName"] as? String
        let actorId = user?["id"] as? String ?? user?["sessionId"] as? String ?? ""
        guard let name, !name.isEmpty, actorId != ownUserId else { return }

        if type == "signalingTypingStop" {
            activeTypers.removeValue(forKey: actorId)
        } else {
            activeTypers[actorId] = Date()
            startExpiryLoop()
        }
        publishTypers()
    }

    /// Session-Objekte aus den Signaling-Events ziehen und die User-Daten
    /// (Name/E-Mail des Backends) nach sessionid ablegen.
    private func parseUserInfos(event: [String: Any]) {
        var sessionObjects: [[String: Any]] = []
        if let target = event["target"] as? String, target == "room",
           let join = event["join"] as? [[String: Any]] {
            sessionObjects.append(contentsOf: join)
        }
        if let target = event["target"] as? String, target == "participants",
           let update = event["update"] as? [[String: Any]] {
            sessionObjects.append(contentsOf: update)
        }
        guard !sessionObjects.isEmpty else { return }
        // Diagnose (Run 15.09.): Roh-Struktur der Backend-User-Daten
        // loggen, damit Name/E-Mail-Feldnamen verifizierbar sind.
        if let first = sessionObjects.first,
           let data = try? JSONSerialization.data(withJSONObject: first, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            CallDebugLog.log("Signaling", "session object (\(sessionObjects.count)): \(String(text.prefix(400)))")
        }
        applyUserInfo(extractSessionObjects(from: sessionObjects))
    }



    private func publishTypers() {
        let names = activeTypers.sorted { $0.value < $1.value }.map(\.key)
        onTypingChanged?(names)
    }

    /// Sicherheits-Timeout: Tippende ohne Stop-Event nach ~8 s entfernen.
    private func startExpiryLoop() {
        guard expiryTask == nil else { return }
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                let cutoff = Date().addingTimeInterval(-8)
                let removed = self.activeTypers.filter { $0.value < cutoff }.map(\.key)
                if !removed.isEmpty {
                    for key in removed { self.activeTypers.removeValue(forKey: key) }
                    self.publishTypers()
                }
                if self.activeTypers.isEmpty {
                    self.expiryTask?.cancel()
                    self.expiryTask = nil
                    return
                }
            }
        }
    }

    // MARK: - Eigener Typing-Status

    /// Beim Tippen aufrufen: sendet Start (debounced) und nach 3 s
    /// Inaktivität automatisch Stop.
    func notifyTyping() {
        guard connected else { return }
        if !localTypingActive {
            localTypingActive = true
            sendTypingEvent(start: true)
            lastLocalSent = Date()
        } else if Date().timeIntervalSince(lastLocalSent) > 4 {
            // Lebenszeichen gegen Timeouts auf der Gegenseite.
            sendTypingEvent(start: true)
            lastLocalSent = Date()
        }
        localIdleTask?.cancel()
        localIdleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.stopLocalTyping()
        }
    }

    func stopLocalTyping() {
        guard localTypingActive else { return }
        localTypingActive = false
        sendTypingEvent(start: false)
    }

    private func sendTypingEvent(start: Bool) {
        guard connected, !roomId.isEmpty else { return }
        let event: [String: Any] = [
            "type": "message",
            "message": [
                "recipient": ["type": "room", "roomid": roomId],
                "data": [
                    "type": "event",
                    "event": ["type": start ? "signalingTypingStart" : "signalingTypingStop"]
                ]
            ]
        ]
        send(json: event)
    }
}
