// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from souvera_android link/call/HpbSignalingClient.kt.
//
// Minimal client for the Nextcloud "High Performance Backend" signaling server
// (nextcloud-spreed-signaling protocol) used by Talk/"Link" calls. Handles the hello/welcome
// handshake (ticket auth), joining the call's room, and relaying WebRTC offer/answer/candidate
// messages between participant sessions. Wire-protocol correctness is validated on-device against
// the live HPB.

import Foundation

protocol HpbSignalingListener: AnyObject {
    func onConnected(ownSessionId: String, mcuActive: Bool)
    /// The signaling room join was confirmed - only now may joinCall run.
    func onRoomJoined()
    /// The server confirmed via participants/update that our own session is
    /// in-call; only now may we publish to the MCU (Janus rejects earlier
    /// publishers).
    func onSelfInCall()
    func onParticipants(sessionIds: [String])
    func onOffer(fromSession: String, sdp: String, roomType: String)
    func onAnswer(fromSession: String, sdp: String)
    func onCandidate(fromSession: String, candidate: [String: Any])
    func onClosed()
}

final class HpbSignalingClient: NSObject, URLSessionWebSocketDelegate {
    private let settings: SignalingSettings
    private let backendUrl: String
    private let roomToken: String
    private weak var listener: HpbSignalingListener?

    private var session: URLSession!
    private var socket: URLSessionWebSocketTask?
    private var ownSessionId = ""
    /// P68q: nil = Room-Join erfolgt später per joinRoom(sessionId:)
    /// (frische Session, kein Ghost). Bei gesetzter Session (Reconnect-
    /// Fallback) wird der Room-Join automatisch nach dem Hello gesendet.
    private var ncSessionId: String?
    private var roomJoinSent = false
    /// P68h: Zähler für kollabierte Candidate-Logs.
    private var candidateSendCount = 0
    private var recvCandidateCount = 0

    private let roomTypeVideo = "video"

    init(settings: SignalingSettings, backendUrl: String, roomToken: String, ncSessionId: String?, listener: HpbSignalingListener) {
        self.settings = settings
        self.backendUrl = backendUrl
        self.roomToken = roomToken
        self.ncSessionId = ncSessionId
        self.listener = listener
        super.init()
    }

    /// P68q: Raum mit der FRISCHEN Session joinen (über die bestehende
    /// Verbindung). Der Aufrufer sorgt dafür, dass die Session frisch ist -
    /// eine einzige Session bedeutet keine "Gelöschter Benutzer"-Geister
    /// für den Call-Partner.
    func joinRoom(sessionId: String) {
        guard socket != nil else { return }
        ncSessionId = sessionId
        CallDebugLog.log("HpbSignaling", "join room with fresh session id")
        sendRoomJoin()
    }

    func connect() {
        guard let url = Self.websocketURL(for: settings.server) else {
            CallDebugLog.log("HpbSignaling", "invalid signaling server URL: \(settings.server)")
            listener?.onClosed()
            return
        }
        CallDebugLog.log("HpbSignaling", "connect \(url.absoluteString)")
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        socket = session.webSocketTask(with: url)
        socket?.resume()
        receiveLoop()
    }

    /// Builds the WebSocket URL for the external signaling server. Talk
    /// returns the HPB address with an https:// scheme (e.g.
    /// https://talk-sig-….oncloud.zone); URLSession requires ws/wss for
    /// WebSocket tasks, so the scheme is normalized. Missing schemes
    /// default to wss.
    static func websocketURL(for server: String) -> URL? {
        let trimmed = server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: trimmed) else {
            if trimmed.isEmpty { return nil }
            return URL(string: "wss://\(trimmed)/spreed")
        }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        case "wss", "ws": break
        default: components.scheme = "wss"
        }
        guard let host = components.host, !host.isEmpty else { return nil }
        if !(components.path).hasSuffix("/spreed") {
            components.path = "/spreed"
        }
        return components.url
    }

    func close() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    // MARK: - Sending

    func sendOffer(toSession: String, sdp: String) { sendPayload(to: toSession, type: "offer", sdp: sdp) }
    func sendAnswer(toSession: String, sdp: String) { sendPayload(to: toSession, type: "answer", sdp: sdp) }

    func sendRequestOffer(toSession: String) {
        sendMessage(to: toSession, data: ["to": toSession, "type": "requestoffer", "roomType": roomTypeVideo])
    }

    func sendCandidate(toSession: String, candidate: [String: Any], roomType: String = "video") {
        let data: [String: Any] = [
            "to": toSession, "type": "candidate", "roomType": roomType,
            "payload": ["type": "candidate", "candidate": candidate]
        ]
        sendMessage(to: toSession, data: data)
    }

    private func sendPayload(to toSession: String, type: String, sdp: String) {
        let data: [String: Any] = [
            "to": toSession, "type": type, "roomType": roomTypeVideo,
            "payload": ["type": type, "sdp": sdp]
        ]
        sendMessage(to: toSession, data: data)
    }

    private func sendMessage(to toSession: String, data: [String: Any]) {
        let envelope: [String: Any] = [
            "type": "message",
            "message": [
                "recipient": ["type": "session", "sessionid": toSession],
                "data": data
            ]
        ]
        // P68h: Candidate-Flut kollabieren (nur jede 15. Zeile loggen) -
        // entlastet das Log massiv und den Aufbau-Pfad.
        let msgType = data["type"] as? String ?? ""
        if msgType == "candidate" {
            candidateSendCount += 1
            if candidateSendCount % 15 == 1 {
                CallDebugLog.log("HpbSignaling", "send candidate #\(candidateSendCount) to=\(toSession)")
            }
        } else {
            CallDebugLog.log("HpbSignaling", "send to=\(toSession) type=\(msgType)")
        }
        send(envelope)
    }

    private func sendHello() {
        let hello: [String: Any] = [
            "version": "1.0",
            "features": ["chat-relay"],
            "auth": [
                "url": backendUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/ocs/v2.php/apps/spreed/api/v3/signaling/backend",
                "params": ["userid": settings.userId, "ticket": settings.ticket]
            ]
        ]
        send(["type": "hello", "hello": hello])
    }

    private func sendRoomJoin() {
        guard !roomJoinSent, let ncSessionId else { return }
        roomJoinSent = true
        send(["type": "room", "room": ["roomid": roomToken, "sessionid": ncSessionId]])
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    // MARK: - Receiving

    private func receiveLoop() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case let .string(text) = message { self.handle(text) }
                self.receiveLoop()
            case .failure(let error):
                CallDebugLog.log("HpbSignaling", "socket failure: \(error.localizedDescription)")
                self.listener?.onClosed()
            }
        }
    }

    private var roomJoinedNotified = false

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = root["type"] as? String
        CallDebugLog.log("HpbSignaling", "recv \(type ?? "?")")
        switch type {
        case "welcome": sendHello()
        case "hello": handleHello(root)
        case "room":
            // The signaling room join is confirmed - only now may the call
            // be opened via the OCS API.
            if !roomJoinedNotified {
                roomJoinedNotified = true
                listener?.onRoomJoined()
            }
        case "event": handleEvent(root)
        case "message": handleMessage(root)
        case "error":
            // Fehler-Details loggen (MCU/HPB-Ablehnungen sind sonst unsichtbar).
            CallDebugLog.log("HpbSignaling", "recv error body: \(String(text.prefix(600)))")
        default: break
        }
    }

    private func handleHello(_ root: [String: Any]) {
        let hello = root["hello"] as? [String: Any]
        ownSessionId = hello?["sessionid"] as? String ?? ""
        let features = ((hello?["server"] as? [String: Any])?["features"] as? [String]) ?? []
        let mcuActive = features.contains("mcu")
        CallDebugLog.log("HpbSignaling", "hello mcu=\(mcuActive)")
        listener?.onConnected(ownSessionId: ownSessionId, mcuActive: mcuActive)
        // P68q: Automatischer Room-Join nur, wenn die Session bereits beim
        // Init übergeben wurde (Reconnect-Fallback). Der Normalfall joint
        // später per joinRoom(sessionId:) mit der frischen Session.
        if ncSessionId != nil {
            sendRoomJoin()
        }
    }

    /// Only "participants/update" carries the in-call participant list (with
    /// the inCall flag). "room/join" is mere presence and must NOT trigger
    /// peer connections (mirrors the Android client).
    private func handleEvent(_ root: [String: Any]) {
        guard let event = root["event"] as? [String: Any] else { return }
        let target = event["target"] as? String
        let type = event["type"] as? String
        guard target == "participants", type == "update",
              let users = (event["update"] as? [String: Any])?["users"] as? [[String: Any]] else {
            CallDebugLog.log("HpbSignaling", "event target=\(target ?? "?") type=\(type ?? "?") (ignored)")
            return
        }

        var selfInCall = false
        var remotes: [String] = []
        for user in users {
            let inCall = (user["inCall"] as? Int ?? 0) != 0
            let session = (user["sessionId"] as? String) ?? (user["sessionid"] as? String) ?? ""
            guard inCall, !session.isEmpty else { continue }
            if session == ownSessionId {
                selfInCall = true
            } else {
                remotes.append(session)
            }
        }
        CallDebugLog.log("HpbSignaling", "participants/update self=\(selfInCall) remotes=\(remotes.count)")
        if selfInCall {
            listener?.onSelfInCall()
        }
        if !remotes.isEmpty {
            listener?.onParticipants(sessionIds: remotes)
        }
    }

    private func handleMessage(_ root: [String: Any]) {
        guard let message = root["message"] as? [String: Any],
              let from = (message["sender"] as? [String: Any])?["sessionid"] as? String,
              let data = message["data"] as? [String: Any] else { return }
        let payload = data["payload"] as? [String: Any]
        let roomType = data["roomType"] as? String ?? "video"
        // P68h: empfangene Candidate-Flut kollabieren (nur jede 15.).
        let recvType = data["type"] as? String ?? "?"
        if recvType == "candidate" {
            recvCandidateCount += 1
            if recvCandidateCount % 15 == 1 {
                CallDebugLog.log("HpbSignaling", "recv candidate #\(recvCandidateCount) from=\(from.prefix(8))")
            }
        } else {
            CallDebugLog.log("HpbSignaling", "recv msg from=\(from.prefix(8)) type=\(recvType) roomType=\(roomType)")
        }
        switch data["type"] as? String {
        case "offer": if let sdp = payload?["sdp"] as? String { listener?.onOffer(fromSession: from, sdp: sdp, roomType: roomType) }
        case "answer": if let sdp = payload?["sdp"] as? String { listener?.onAnswer(fromSession: from, sdp: sdp) }
        case "candidate": if let cand = payload?["candidate"] as? [String: Any] { listener?.onCandidate(fromSession: from, candidate: cand) }
        default: break
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        sendHello()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        listener?.onClosed()
    }
}
