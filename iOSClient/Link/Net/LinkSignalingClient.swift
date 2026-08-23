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

        guard let server = settings["server"] as? String,
              let ticket = settings["ticket"] as? String,
              !server.isEmpty else { return }
        let host = server
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "wss://\(host)") else { return }

        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        session = s
        webSocket = s.webSocketTask(with: url)
        webSocket?.resume()
        receiveLoop()

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

    func disconnect() {
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
        guard let type = event["type"] as? String,
              type.hasPrefix("signalingTyping") else { return }
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
