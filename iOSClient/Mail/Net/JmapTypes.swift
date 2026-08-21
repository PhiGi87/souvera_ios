// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from souvera_android mail/net/jmap/JmapTypes.kt.
// JMAP RFC 8620/8621 capability constants, method-call/response types,
// session info and error types.

import Foundation


enum JmapCapabilities {
    static let core = "urn:ietf:params:jmap:core"
    static let mail = "urn:ietf:params:jmap:mail"
    static let submission = "urn:ietf:params:jmap:submission"
    static let blob = "urn:ietf:params:jmap:blob"
}

struct JmapMethodCall {
    let name: String
    let args: [String: Any]
    let callId: String
}

struct JmapMethodResponse {
    let name: String
    let args: [String: Any]
    let callId: String
}

struct JmapError {
    let type: String
    let description: String?
    let callId: String?

    static func from(_ args: [String: Any], callId: String?) -> JmapError {
        JmapError(
            type: args["type"] as? String ?? "unknown",
            description: args["description"] as? String,
            callId: callId
        )
    }
}

enum JmapCallResult {
    case success(JmapMethodResponse)
    case failure(JmapError)
}

struct JmapBatchResult {
    let results: [JmapCallResult]
    let sessionState: String?
}

struct JmapAccountInfo {
    let id: String
    let name: String
    let isPersonal: Bool
}

struct JmapSessionInfo {
    let apiUrl: String
    let downloadUrl: String
    let uploadUrl: String
    let accountId: String
    let primaryAccountId: String
    let username: String
    let capabilities: [String: [String: Any]]
    let state: String?
    /// All accounts the user can access: the personal one plus shared
    /// mailboxes (isPersonal=false), keyed by account id.
    let accounts: [String: JmapAccountInfo]
}

struct JmapBlobUploadResponse {
    let blobId: String
    let size: Int64
    let type: String
}

enum JmapException: LocalizedError {
    case httpError(code: Int, body: String)
    case protocolError(String)
    case authNeedsBearer(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        case .protocolError(let msg):
            return msg
        case .authNeedsBearer(let msg):
            return msg
        }
    }
}




extension Dictionary where Key == String, Value == Any {
    func optString(_ key: String) -> String? { self[key] as? String }
    func optInt(_ key: String) -> Int { self[key] as? Int ?? 0 }
    func optInt64(_ key: String) -> Int64 {
        if let v = self[key] as? Int64 { return v }
        if let v = self[key] as? Int { return Int64(v) }
        return 0
    }
    func optBool(_ key: String) -> Bool { self[key] as? Bool ?? false }
    func optDict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func optArray(_ key: String) -> [Any]? { self[key] as? [Any] }
}
