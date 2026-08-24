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
import Network
import NextcloudKit

actor JmapClient {
    private let baseUrl: String
    private let username: String
    private let password: String

    private var jmapSession: JmapSessionInfo?
    private var resolvedApiUrl: String?
    private var resolvedJson: [String: Any]?
    private var bearerToken: String?
    private var lastPostBody: String?

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

    /// Short diagnostic summary (build info, apiUrl, accountId, session facts)
    /// shown in the mail UI on errors.
    func diagnosticSummary() -> String {
        let accId = jmapSession?.primaryAccountId ?? "?"
        let api = resolvedApiUrl ?? "?"
        var lines = [
            "JMAP apiUrl: \(api)",
            "accountId: \(accId)"
        ]
        if let json = resolvedJson {
            let primary = (json["primaryAccounts"] as? [String: Any])?.optString(JmapCapabilities.mail) ?? "?"
            let accounts = json["accounts"] as? [String: Any] ?? [:]
            let accountKeys = accounts.keys.sorted().prefix(3).joined(separator: ", ")
            lines.append("primaryAccounts[mail]: \(primary)")
            lines.append("accounts count: \(accounts.count) (first: \(accountKeys))")
            let caps = jmapSession?.capabilities.keys.sorted().joined(separator: ", ") ?? "?"
            lines.append("session capabilities: \(caps)")
            let sessionPreview = String(describing: json).prefix(2000)
            lines.append("session json: \(sessionPreview)")
        }
        if let body = lastPostBody {
            lines.append("last request body: \(body)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Session

    @discardableResult
    func refreshSession() async throws -> JmapSessionInfo {
        // The session is static per credential - fetch it once and reuse it.
        // Refetching on every sync caused transient GET failures to surface
        // as "JMAP session not available" (e.g. on pull-to-refresh).
        if let session = jmapSession {
            return session
        }
        let apiUrl = try await resolveApiUrl()
        guard let json = resolvedJson else {
            throw JmapException.protocolError("JMAP session not available at \(apiUrl). Check server connectivity and credentials.")
        }
        nkLog(debug: "[JMAP] session response: \(json)")
        JmapLog.write("session response: \(String(describing: json).prefix(4000))")
        let info = parseSession(json)
        resolvedApiUrl = apiUrl
        jmapSession = info
        nkLog(debug: "[JMAP] using apiUrl: \(apiUrl) accountId: \(info.primaryAccountId)")
        JmapLog.write("using apiUrl: \(apiUrl) accountId: \(info.primaryAccountId) capabilities: \(info.capabilities.keys.sorted().joined(separator: ", "))")
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

        // Parse the session first so the request only uses capabilities the
        // server actually advertised (RFC 8620: requests using unknown
        // capabilities are rejected with notRequest).
        if jmapSession == nil, let json = resolvedJson {
            jmapSession = parseSession(json)
        }
        if let session = jmapSession, !session.capabilities.isEmpty {
            let required = using.filter { $0 != JmapCapabilities.core }
            let missing = required.filter { session.capabilities[$0] == nil }
            if !missing.isEmpty {
                let offered = session.capabilities.keys.sorted().joined(separator: ", ")
                throw JmapException.protocolError("JMAP session does not offer required capabilities: \(missing.joined(separator: ", ")) (offered: \(offered))")
            }
        }

        let methodCalls: [Any] = calls.map {
            [$0.name, $0.args, $0.callId] as [Any]
        }
        let requestObj: [String: Any] = [
            "using": using,
            "methodCalls": methodCalls
        ]
        var response: [String: Any]
        do {
            response = try await httpPost(apiUrl, body: requestObj)
        } catch let error as JmapException {
            if case .authNeedsBearer = error {
                throw error
            }
            // Transienter Fehler (Server-Zucken/Verbindung): gecachte
            // Session verwerfen, Session neu laden und EINMAL retryen -
            // sonst hält eine zwischenzeitliche Störung die App offline.
            JmapLog.write("JMAP call failed (\(error)) - invalidating session and retrying once")
            jmapSession = nil
            resolvedApiUrl = nil
            resolvedJson = nil
            let retryUrl = try await resolveApiUrl()
            response = try await httpPost(retryUrl, body: requestObj)
        }

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

        // Once resolved, keep using the same api URL; a transient failure
        // of a later fetch must never discard a working session.
        if let cached = resolvedApiUrl {
            return cached
        }

        if let json = try? await httpGet("\(base)/jmap/session") {
            resolvedJson = json
            resolvedApiUrl = json.optString("apiUrl") ?? "\(base)/jmap"
            return resolvedApiUrl ?? "\(base)/jmap"
        }

        if let json = try? await httpGet("\(base)/.well-known/jmap") {
            resolvedJson = json
            resolvedApiUrl = json.optString("apiUrl") ?? "\(base)/jmap"
            return resolvedApiUrl ?? "\(base)/jmap"
        }

        let defaultUrl = "\(base)/jmap"
        if let json = try? await httpGet(defaultUrl) {
            resolvedJson = json
            resolvedApiUrl = json.optString("apiUrl") ?? defaultUrl
            return resolvedApiUrl ?? defaultUrl
        }
        return defaultUrl
    }

    private func parseSession(_ json: [String: Any]) -> JmapSessionInfo {
        var caps: [String: [String: Any]] = [:]
        (json["capabilities"] as? [String: Any])?.forEach { k, v in
            caps[k] = v as? [String: Any]
        }

        let primaryAccId = resolveAccountId(json: json, caps: caps)
        nkLog(debug: "[JMAP] resolved primary accountId: \(primaryAccId)")

        // Normalize the api URL: the souvera_mail server itself posts to
        // '/jmap' without a trailing slash. Some front proxies route '/jmap'
        // and '/jmap/' differently and reject the latter with notRequest.
        let apiUrl = (json.optString("apiUrl") ?? resolvedApiUrl ?? "\(baseUrl)/jmap")
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)

        var accounts: [String: JmapAccountInfo] = [:]
        (json["accounts"] as? [String: Any])?.forEach { key, value in
            guard let info = value as? [String: Any] else { return }
            accounts[key] = JmapAccountInfo(
                id: key,
                name: info.optString("name") ?? key,
                isPersonal: info.optBool("isPersonal")
            )
        }

        return JmapSessionInfo(
            apiUrl: apiUrl,
            downloadUrl: json.optString("downloadUrl") ?? "\(apiUrl)download/{accountId}/{blobId}/{name}?accept={type}",
            uploadUrl: json.optString("uploadUrl") ?? "\(apiUrl)upload/{accountId}/",
            accountId: primaryAccId,
            primaryAccountId: primaryAccId,
            username: json.optString("username") ?? username,
            capabilities: caps,
            state: json.optString("state"),
            accounts: accounts
        )
    }

    /// Resolves the mail account id from the session resource.
    ///
    /// The value from `primaryAccounts` is the server-provided account id and
    /// is used as-is (Stalwart ids can be short, e.g. "e"). It is only sanity
    /// checked against the session's `accounts` map; if it is missing there,
    /// the personal account (or the first account) is used. An empty result
    /// means the caller must NOT send the request and surface an error.
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
        return ""
    }

    private func httpGet(_ urlStr: String) async throws -> [String: Any]? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(authHeader(), forHTTPHeaderField: "Authorization")

        let (body, resp) = try await urlSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if code == 401 {
            throw JmapException.authNeedsBearer("JMAP auth rejected — needs Bearer token")
        }
        guard (200..<300).contains(code) else {
            JmapLog.write("session GET \(urlStr) -> HTTP \(code)")
            return nil
        }
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            return json
        }
        JmapLog.write("session GET \(urlStr) -> 2xx but body is not JSON")
        return nil
    }

    private func httpPost(_ urlStr: String, body: [String: Any]) async throws -> [String: Any] {
        let normalizedUrl = urlStr.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let url = URL(string: normalizedUrl) else {
            throw JmapException.protocolError("Invalid URL: \(urlStr)")
        }
        guard var bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw JmapException.protocolError("Failed to serialize JSON body")
        }

        // Stalwart v1.0.0 rejects JMAP requests whose JSON escapes forward
        // slashes as "\/" (it validates the raw body text). iOS 26's
        // Foundation (swift-foundation) escapes "/" that way, while Android's
        // JSONObject.toString() never does. Unescaping is lossless because
        // "\/" always decodes to "/" in JSON; the replacement also keeps
        // literal "\/" string content intact ("\\\/" -> "\\/").
        if let bodyString = String(data: bodyData, encoding: .utf8)?
            .replacingOccurrences(of: "\\/", with: "/")
            .data(using: .utf8) {
            bodyData = bodyString
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        req.httpBody = bodyData
        lastPostBody = String(data: bodyData, encoding: .utf8) ?? ""

        nkLog(debug: "[JMAP] POST \(normalizedUrl) body: \(lastPostBody ?? "")")
        JmapLog.write("POST \(normalizedUrl) (method=POST, Content-Type=application/json; charset=utf-8, Accept=application/json, Authorization=\(bearerToken != nil ? "Bearer" : "Basic") set)")
        JmapLog.write("body (\(bodyData.count) bytes): \(lastPostBody ?? "")")

        // The Android client talks to this endpoint over plain HTTP/1.1
        // (HttpURLConnection). URLSession negotiates HTTP/2, which some front
        // proxies reject for JMAP POSTs with a canned notRequest. Mirror the
        // Android transport: HTTP/1.1 over Network.framework.
        var requestHeaders = [
            "Content-Type": "application/json; charset=utf-8",
            "Accept": "application/json",
            "Authorization": authHeader(),
            "User-Agent": "Souvera-iOS/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")"
        ]
        let response = try await Http1Transport.post(url: url, headers: requestHeaders, body: bodyData)
        let code = response.status

        let headerSummary = response.headers.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " | ")
        JmapLog.write("-> HTTP \(code) headers: \(headerSummary)")

        let data = response.body
        let responsePreview = String(data: data, encoding: .utf8)?.prefix(1000) ?? ""
        JmapLog.write("response: \(responsePreview)")

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

/// Debug log written to <Documents>/souvera-mail.log in the app container,
/// independent of the NextcloudKit log level. Inspect with:
///   tail -100 "$(xcrun simctl get_app_container booted eu.souvera.app data)/Documents/souvera-mail.log"
enum JmapLog {
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent("souvera-mail.log")
        let line = "[\(timestampFormatter.string(from: Date()))] \(message)\n"
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8))
        } else if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }
}

/// Minimal HTTP/1.1 client over Network.framework for JMAP POSTs.
///
/// URLSession negotiates HTTP/2 via ALPN; the deployment's front proxy
/// rejects those POSTs with `urn:ietf:params:jmap:error:notRequest`. The
/// Android client uses HttpURLConnection (HTTP/1.1 only) and works, so this
/// transport mirrors that behaviour by advertising only "http/1.1" in ALPN.
private final class Http1Transport {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    static func post(url: URL, headers: [String: String], body: Data) async throws -> Response {
        guard let host = url.host, !host.isEmpty else {
            throw JmapException.protocolError("Invalid URL host: \(url)")
        }
        let port = UInt16(url.port ?? (url.scheme == "https" ? 443 : 80)) ?? 443
        let path = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?\($0)" } ?? "")

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: NWParameters(tls: tls)
        )

        var request = "POST \(path) HTTP/1.1\r\n"
        request += "Host: \(host)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            request += "\(key): \(value)\r\n"
        }
        request += "Content-Length: \(body.count)\r\n"
        request += "Connection: close\r\n\r\n"
        var payload = Data(request.utf8)
        payload.append(body)

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var done = false
            var received = Data()

            func finish(_ result: Result<Response, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !done else { return }
                done = true
                connection.cancel()
                continuation.resume(with: result)
            }

            func parseAndFinish() {
                guard let separator = received.firstRange(of: Data("\r\n\r\n".utf8)) else {
                    finish(.failure(JmapException.protocolError("Invalid HTTP/1.1 response (no header separator)")))
                    return
                }
                let headData = received[received.startIndex..<separator.lowerBound]
                let bodyData = Data(received[separator.upperBound...])
                guard let head = String(data: headData, encoding: .utf8) else {
                    finish(.failure(JmapException.protocolError("Invalid HTTP/1.1 response (headers not UTF-8)")))
                    return
                }
                let lines = head.components(separatedBy: "\r\n")
                guard let statusLine = lines.first,
                      statusLine.hasPrefix("HTTP/1.1 ") || statusLine.hasPrefix("HTTP/1.0 ") else {
                    finish(.failure(JmapException.protocolError("Invalid HTTP/1.1 status line: \(lines.first ?? "")")))
                    return
                }
                let parts = statusLine.components(separatedBy: " ")
                let status = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
                var responseHeaders: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    responseHeaders[key] = value
                }
                finish(.success(Response(status: status, headers: responseHeaders, body: bodyData)))
            }

            func readChunk() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                    if let data {
                        received.append(data)
                    }
                    if error != nil || isComplete {
                        parseAndFinish()
                    } else {
                        readChunk()
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { sendError in
                        if let sendError {
                            finish(.failure(sendError))
                        } else {
                            readChunk()
                        }
                    })
                case .failed(let error):
                    finish(.failure(error))
                default:
                    break
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                finish(.failure(JmapException.protocolError("HTTP/1.1 POST timed out")))
            }

            connection.start(queue: .global())
        }
    }
}
