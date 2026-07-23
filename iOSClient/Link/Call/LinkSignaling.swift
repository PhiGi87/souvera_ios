// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from souvera_android link/call/SignalingSettings.kt.
//
// Talk `signaling/settings` response: the external (HPB) signaling server + auth ticket and the
// ICE (STUN/TURN) servers to feed WebRTC.

import Foundation
import WebRTC

struct SignalingSettings: Decodable {
    let signalingMode: String
    let server: String
    let ticket: String
    let userId: String
    let stunServers: [StunServer]
    let turnServers: [TurnServer]

    enum CodingKeys: String, CodingKey {
        case signalingMode, server, ticket, userId
        case stunServers = "stunservers"
        case turnServers = "turnservers"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        signalingMode = (try? c.decode(String.self, forKey: .signalingMode)) ?? ""
        server = (try? c.decode(String.self, forKey: .server)) ?? ""
        ticket = (try? c.decode(String.self, forKey: .ticket)) ?? ""
        userId = (try? c.decode(String.self, forKey: .userId)) ?? ""
        stunServers = (try? c.decode([StunServer].self, forKey: .stunServers)) ?? []
        turnServers = (try? c.decode([TurnServer].self, forKey: .turnServers)) ?? []
    }

    func iceServers() -> [RTCIceServer] {
        let stun = stunServers.map { RTCIceServer(urlStrings: $0.urls) }
        let turn = turnServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        return stun + turn
    }

    var hasExternalServer: Bool { !server.isEmpty }
}

struct StunServer: Decodable {
    let urls: [String]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        urls = (try? c.decode([String].self, forKey: .urls)) ?? []
    }
    enum CodingKeys: String, CodingKey { case urls }
}

struct TurnServer: Decodable {
    let urls: [String]
    let username: String
    let credential: String
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        urls = (try? c.decode([String].self, forKey: .urls)) ?? []
        username = (try? c.decode(String.self, forKey: .username)) ?? ""
        credential = (try? c.decode(String.self, forKey: .credential)) ?? ""
    }
    enum CodingKeys: String, CodingKey { case urls, username, credential }
}

/// Lightweight call-scoped logger; never logs SDP bodies or tickets.
enum CallDebugLog {
    static func log(_ tag: String, _ message: String) {
        nkLog(tag: "LINK-CALL", emoji: .debug, message: "[\(tag)] \(message)", consoleOnly: true)
    }
}
