// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from souvera_android mail/net/jmap/JmapClient.kt.
//
// Low-level HTTP-based JMAP client. One instance per account. Handles:
// - Session discovery (GET /jmap/session, fallback .well-known/jmap)
// - Batch method-call encoding (RFC 8620 §3.3)
// - Authentication: Basic (mail app-password) with OIDC Bearer fallback
// - Blob upload/download

import Foundation
import NextcloudKit

actor JmapClient {
    private let baseUrl: String
    private let username: String
    private let password: String

    private var jmapSession: JmapSessionInfo?
    private var resolvedApiUrl: String?
    private var resolvedJson: [String: Any]?
    private var bearerToken: String?

    private nonisolated let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    init(baseUrl: String, username: String, password: String, bearerToken: String? = nil) {
        self.baseUrl = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.username = username
        self.password = password
        self.bearerToken = bearerToken
    }

    func getSessionJson() -> [String: Any]? { resolvedJson }

    func setBearerToken(_ token: String) { bearerToken = token }
    var needsBearerToken: Bool { bearerToken == nil }

    /// Short diagnostic summary (apiUrl + accountId) shown in the mail UI on errors.
    func diagnosticSummary() -> String {
        let accId = jmapSession?.primaryAccountId ?? "?"
        let api = resolvedApiUrl ?? "?"
        return "JMAP apiUrl: \(api)\naccountId: \(accId)"
    }

    // MARK: - Session

    @discardableResult
    func refreshSession() async throws -> JmapSessionInfo {
        let apiUrl = try await resolveApiUrl()
        guard let json = resolvedJson else {
            throw JmapException.protocolError("JMAP session not available at \(apiUrl). Check server connectivity and credentials.")
        }
        nkLog(debug: "[JMAP] session response: \(json)")
        let info = parseSession(json)
        resolvedApiUrl = apiUrl
        jmapSession = info
        nkLog(debug: "[JMAP] using apiUrl: \(apiUrl) accountId: \(info.primaryAccountId)")
        return info
    }

    // MARK: - Method calls (batch)

    func call(
        _ calls: [JmapMethodCall],
        using: [String] = [JmapCapabilities.core, JmapCapabilities.mail]
    ) async throws -> JmapBatchResult {
        let apiUrl: String
        if let resolved = resolvedApiUrl {
            apiUrl = resolved
        } else {
            apiUrl = try await resolveApiUrl()
        }

        let methodCalls: [Any] = calls.map {
            [$0.name, $0.args, $0.callId] as [Any]
        }
        let requestObj: [String: Any] = [
            "using": using,
            "methodCalls": methodCalls
        ]
        let response = try await httpPost(apiUrl, body: requestObj)

        guard let responses = response["methodResponses"] as? [Any] else {
            throw JmapException.protocolError("No methodResponses in JMAP response")
        }
        let sessionState = response["sessionState"] as? String

        var results: [JmapCallResult] = []
        for element in responses {
            guard let triple = element as? [Any], triple.count >= 2 else { continue }
            let name = triple[0] as? String ?? ""
            let args = (triple[1] as? [String: Any]) ?? [:]
            let callId = triple.count > 2 ? (triple[2] as? String ?? "") : ""

            if name == "error" || args["type"] != nil {
                results.append(.failure(JmapError.from(args, callId: callId)))
            } else {
                results.append(.success(JmapMethodResponse(name: name, args: args, callId: callId)))
            }
        }
        return JmapBatchResult(results: results, sessionState: sessionState)
    }

    func singleCall(
        _ name: String,
        args: [String: Any],
        using: [String]? = nil,
        callId: String = "S"
    ) async throws -> [String: Any] {
        let result = try await call(
            [JmapMethodCall(name: name, args: args, callId: callId)],
            using: using ?? [JmapCapabilities.core, JmapCapabilities.mail]
        )
        guard let single = result.results.first else {
            throw JmapException.protocolError("Empty batch result")
        }
        switch single {
        case .success(let resp):
            return resp.args
        case .failure(let err):
            throw JmapException.protocolError("JMAP \(err.type): \(err.description ?? "no description")")
        }
    }

    // MARK: - Blobs

    func uploadBlob(accountId: String, data: Data, contentType: String) async throws -> JmapBlobUploadResponse {
        let s = try await ensureSession()
        let urlStr = s.uploadUrl
            .replacingOccurrences(of: "{accountId}", with: accountId)
            .replacingOccurrences(of: "{account}", with: accountId)

        guard let url = URL(string: urlStr) else {
            throw JmapException.protocolError("Invalid upload URL: \(urlStr)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        req.httpBody = data

        let (body, resp) = try await urlSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw JmapException.httpError(code: code, body: String(data: body, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw JmapException.protocolError("Invalid blob upload response")
        }
        return JmapBlobUploadResponse(
            blobId: json.optString("blobId") ?? "",
            size: json.optInt64("size"),
            type: json.optString("type") ?? contentType
        )
    }

    func downloadBlob(accountId: String, blobId: String, mimeType: String) async throws -> Data {
        let s = try await ensureSession()
        let urlStr = s.downloadUrl
            .replacingOccurrences(of: "{accountId}", with: accountId)
            .replacingOccurrences(of: "{account}", with: accountId)
            .replacingOccurrences(of: "{blobId}", with: blobId)
            .replacingOccurrences(of: "{type}", with: mimeType)
            .replacingOccurrences(of: "{name}", with: blobId)

        guard let url = URL(string: urlStr) else {
            throw JmapException.protocolError("Invalid download URL: \(urlStr)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(mimeType, forHTTPHeaderField: "Accept")
        req.setValue(authHeader(), forHTTPHeaderField: "Authorization")

        let (body, resp) = try await urlSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw JmapException.httpError(code: code, body: String(data: body, encoding: .utf8) ?? "")
        }
        return body
    }

    // MARK: - Auth

    private func authHeader() -> String {
        if let bearer = bearerToken {
            return "Bearer \(bearer)"
        }
        let raw = "\(username):\(password)"
        return "Basic \(Data(raw.utf8).base64EncodedString())"
    }

    private func ensureSession() async throws -> JmapSessionInfo {
        if let s = jmapSession {
            return s
        }
        return try await refreshSession()
    }

    // MARK: - Internal

    private func resolveApiUrl() async throws -> String {
        let base = baseUrl

        if let json = try? await httpGet("\(base)/jmap/session") {
            resolvedJson = json
            if let apiUrl = json.optString("apiUrl"), !apiUrl.isEmpty {
                return apiUrl
            }
            return "\(base)/jmap"
        }

        if let json = try? await httpGet("\(base)/.well-known/jmap") {
            resolvedJson = json
            if let apiUrl = json.optString("apiUrl"), !apiUrl.isEmpty {
                return apiUrl
            }
        }

        let defaultUrl = "\(base)/jmap"
        if let json = try? await httpGet(defaultUrl) {
            resolvedJson = json
            if let apiUrl = json.optString("apiUrl"), !apiUrl.isEmpty {
                return apiUrl
            }
        }
        resolvedJson = nil
        return defaultUrl
    }

    private func parseSession(_ json: [String: Any]) -> JmapSessionInfo {
        var caps: [String: [String: Any]] = [:]
        (json["capabilities"] as? [String: Any])?.forEach { k, v in
            caps[k] = v as? [String: Any]
        }

        let primaryAccId = resolveAccountId(json: json, caps: caps)
        nkLog(debug: "[JMAP] resolved primary accountId: \(primaryAccId)")

        let apiUrl = json.optString("apiUrl") ?? resolvedApiUrl ?? "\(baseUrl)/jmap"

        return JmapSessionInfo(
            apiUrl: apiUrl,
            downloadUrl: json.optString("downloadUrl") ?? "\(apiUrl)download/{accountId}/{blobId}/{name}?accept={type}",
            uploadUrl: json.optString("uploadUrl") ?? "\(apiUrl)upload/{accountId}/",
            accountId: primaryAccId,
            primaryAccountId: primaryAccId,
            username: json.optString("username") ?? username,
            capabilities: caps,
            state: json.optString("state")
        )
    }

    /// Resolves the mail account id from the session resource.
    ///
    /// The value from `primaryAccounts` is validated against the session's
    /// `accounts` map: some deployments hand out truncated account ids (a
    /// single character) which Stalwart rejects with
    /// `urn:ietf:params:jmap:error:notRequest`. If the primary id is not a
    /// key of `accounts`, the personal account (or the first account) is
    /// used instead.
    private func resolveAccountId(json: [String: Any], caps: [String: [String: Any]]) -> String {
        let accounts = json["accounts"] as? [String: Any] ?? [:]

        func valid(_ candidate: String?) -> String? {
            guard let candidate, !candidate.isEmpty, accounts[candidate] != nil else { return nil }
            return candidate
        }

        if let primary = valid((json["primaryAccounts"] as? [String: Any])?.optString(JmapCapabilities.mail)) {
            return primary
        }
        if let fromCaps = valid(caps[JmapCapabilities.mail]?.optString("accountId")) {
            return fromCaps
        }
        if !accounts.isEmpty {
            for (id, value) in accounts {
                if let info = value as? [String: Any], info.optBool("isPersonal") {
                    return id
                }
            }
            return accounts.keys.sorted().first ?? ""
        }
        return username
    }

    private func httpGet(_ urlStr: String) async throws -> [String: Any]? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(authHeader(), forHTTPHeaderField: "Authorization")

        let (body, resp) = try await urlSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if code == 401 {
            throw JmapException.authNeedsBearer("JMAP auth rejected — needs Bearer token")
        }
        guard (200..<300).contains(code) else { return nil }

        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private func httpPost(_ urlStr: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: urlStr) else {
            throw JmapException.protocolError("Invalid URL: \(urlStr)")
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw JmapException.protocolError("Failed to serialize JSON body")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        req.httpBody = bodyData

        nkLog(debug: "[JMAP] POST \(urlStr) body: \(String(data: bodyData, encoding: .utf8) ?? "")")

        let (data, resp) = try await urlSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

        if code == 401 {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            nkLog(debug: "[JMAP] POST \(urlStr) -> 401: \(bodyStr)")
            throw JmapException.authNeedsBearer("JMAP auth rejected — needs Bearer token: \(bodyStr)")
        }
        guard (200..<300).contains(code) else {
            let bodyStr = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
            nkLog(debug: "[JMAP] POST \(urlStr) -> HTTP \(code): \(bodyStr)")
            throw JmapException.httpError(code: code, body: String(bodyStr))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw JmapException.protocolError("JMAP response not JSON (\(preview))")
        }
        return json
    }
}
