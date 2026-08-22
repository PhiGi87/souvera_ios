// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// HTTP client for the Souvera Shield Nextcloud app: spam/file/virus
// quarantines plus whitelist/blacklist management. Uses HTTP Basic with the
// account app-password (the API lives under /apps/souvera_shield/api/...).

import Foundation

struct ShieldSpamEntry: Identifiable {
    let id: String
    let subject: String
    let from: String
    let sender: String
    let receiver: String
    let bytes: Int64
    let spamLevel: Int
    let time: Date
    let seen: Bool
    /// Mailbox (pmail) this entry belongs to - used for the mailbox filter.
    let mailbox: String?

    static func from(_ json: [String: Any]) -> ShieldSpamEntry? {
        guard let id = json["id"] as? String else { return nil }
        return ShieldSpamEntry(
            id: id,
            subject: json["subject"] as? String ?? "",
            from: json["from"] as? String ?? "",
            sender: json["sender"] as? String ?? (json["envelope_sender"] as? String ?? ""),
            receiver: json["receiver"] as? String ?? (json["pmail"] as? String ?? ""),
            bytes: (json["bytes"] as? NSNumber)?.int64Value ?? 0,
            spamLevel: (json["spamlevel"] as? NSNumber)?.intValue ?? 0,
            time: Date(timeIntervalSince1970: (json["time"] as? NSNumber)?.doubleValue ?? 0),
            seen: ((json["seen"] as? NSNumber)?.intValue ?? 0) != 0,
            mailbox: (json["_pmail"] as? String) ?? (json["pmail"] as? String)
        )
    }
}

/// Generic entry for the file/virus quarantines (fields vary per server
/// version; the UI renders whatever is present).
struct ShieldGenericEntry: Identifiable {
    let id: String
    let fields: [String: Any]

    var displayTitle: String {
        fields["name"] as? String
            ?? fields["filename"] as? String
            ?? fields["subject"] as? String
            ?? (fields["id"] as? String ?? "")
    }

    /// Mailbox (pmail) this entry belongs to - used for the mailbox filter.
    var mailbox: String? {
        (fields["_pmail"] as? String) ?? (fields["pmail"] as? String)
    }

    var displaySubtitle: String {
        var parts: [String] = []
        if let path = fields["path"] as? String, !path.isEmpty { parts.append(path) }
        if let sender = fields["sender"] as? String, !sender.isEmpty { parts.append(sender) }
        if let virus = fields["virus"] as? String, !virus.isEmpty { parts.append(virus) }
        if let size = fields["size"] as? NSNumber { parts.append(ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    static func from(_ json: [String: Any]) -> ShieldGenericEntry? {
        guard let id = json["id"] as? String else { return nil }
        return ShieldGenericEntry(id: id, fields: json)
    }
}

struct ShieldListResult {
    let data: [[String: Any]]
    let warnings: [String]
}

final class ShieldApi {

    enum QuarantineKind: String {
        case spam, file, virus
    }

    enum ListKind: String {
        case whitelist, blacklist
    }

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 40
        return URLSession(configuration: config)
    }()

    private var root: String? {
        NCManageDatabase.shared.getActiveTableAccount()?.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var authHeader: String? {
        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else { return nil }
        let davPassword = NCPreferences().getPassword(account: tbl.account)
        let raw = "\(tbl.user):\(davPassword)"
        return "Basic \(Data(raw.utf8).base64EncodedString())"
    }

    /// Session-bound CSRF token (the POST routes of the shield app reject
    /// requests without it with 412 even for Basic auth). Fetched once from
    /// the shield page; refreshed automatically after a 412.
    private var requestToken: String?

    private func ensureRequestToken() async -> String? {
        if let requestToken { return requestToken }
        guard let root, let url = URL(string: "\(root)/index.php/apps/souvera_shield/") else { return nil }
        var req = URLRequest(url: url)
        if let authHeader {
            req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        guard let (data, _) = try? await urlSession.data(for: req),
              let html = String(data: data, encoding: .utf8),
              let start = html.range(of: #"data-requesttoken=""#) else { return nil }
        let rest = html[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        requestToken = String(rest[..<end])
        return requestToken
    }

    private func perform(_ path: String, method: String, form: [String: String]) async -> (status: Int, json: [String: Any]?, body: String)? {
        guard let root, let url = URL(string: "\(root)/apps/souvera_shield/\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let authHeader {
            req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        if method == "POST", let token = await ensureRequestToken() {
            req.setValue(token, forHTTPHeaderField: "requesttoken")
        }
        if !form.isEmpty {
            var components = URLComponents()
            components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            req.httpBody = components.query?.data(using: .utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        guard let (data, response) = try? await urlSession.data(for: req) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
        if !(200..<300).contains(status) {
            JmapLog.write("ShieldApiLog \(method) \(path) -> \(status) \(body)")
        }
        return (status, json, body)
    }

    private func request(_ path: String, method: String = "GET", form: [String: String] = [:]) async -> (status: Int, json: [String: Any]?, body: String)? {
        let first = await perform(path, method: method, form: form)
        // CSRF token expired? Refresh once and retry POSTs.
        if method == "POST", let first, first.status == 412 {
            requestToken = nil
            return await perform(path, method: method, form: form)
        }
        return first
    }

    private func ok(_ result: (status: Int, json: [String: Any]?, body: String)?) -> Bool {
        guard let result else { return false }
        return (200..<300).contains(result.status)
    }

    // MARK: - Quarantines

    func quarantineList(_ kind: QuarantineKind) async -> ShieldListResult? {
        let path: String
        switch kind {
        case .spam: path = "api/quarantine"
        case .file: path = "api/file_quarantine"
        case .virus: path = "api/virus_quarantine"
        }
        guard let result = await request(path) else { return nil }
        let data = (result.json?["data"] as? [[String: Any]]) ?? []
        let warnings = (result.json?["warnings"] as? [String]) ?? []
        return ShieldListResult(data: data, warnings: warnings)
    }

    func spamMessageDetail(id: String, email: String? = nil) async -> [String: Any]? {
        var query = "id=\(id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id)"
        if let email {
            query += "&email=\(email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email)"
        }
        let result = await request("api/quarantine/view?\(query)")
        return result?.json
    }

    func release(_ kind: QuarantineKind, ids: [String], email: String? = nil) async -> Bool {
        let path: String
        switch kind {
        case .spam: path = "api/quarantine/release"
        case .file: path = "api/file_quarantine/release"
        case .virus: path = "api/virus_quarantine/release"
        }
        var form = ["ids": ids.joined(separator: ",")]
        if let email { form["email"] = email }
        return ok(await request(path, method: "POST", form: form))
    }

    /// Kombi-Aktion (souvera_shield >= 4.0.57): Nachricht freigeben UND den
    /// Absender in die Whitelist aller Identitäten aufnehmen. Benötigt die
    /// Absender-Adresse als Pflichtfeld "entry".
    func releaseWhitelist(ids: [String], email: String?, entry: String) async -> Bool {
        var form = ["ids": ids.joined(separator: ","), "entry": entry]
        if let email { form["email"] = email }
        return ok(await request("api/quarantine/release-whitelist", method: "POST", form: form))
    }

    func delete(_ kind: QuarantineKind, ids: [String], email: String? = nil) async -> Bool {
        let path: String
        switch kind {
        case .spam: path = "api/quarantine/delete"
        case .file: path = "api/file_quarantine/delete"
        case .virus: path = "api/virus_quarantine/delete"
        }
        var form = ["ids": ids.joined(separator: ",")]
        if let email { form["email"] = email }
        return ok(await request(path, method: "POST", form: form))
    }

    // MARK: - Whitelist / Blacklist

    func list(_ kind: ListKind) async -> ShieldListResult? {
        let path = kind == .whitelist ? "api/whitelist" : "api/blacklist"
        guard let result = await request(path) else { return nil }
        let data = (result.json?["data"] as? [String])?.map { ["value": $0] } ?? []
        let warnings = (result.json?["warnings"] as? [String]) ?? []
        return ShieldListResult(data: data, warnings: warnings)
    }

    func add(_ kind: ListKind, entry: String) async -> Bool {
        let path = kind == .whitelist ? "api/whitelist" : "api/blacklist"
        return ok(await request(path, method: "POST", form: ["entry": entry]))
    }

    func remove(_ kind: ListKind, entry: String) async -> Bool {
        let path = kind == .whitelist ? "api/whitelist/remove" : "api/blacklist/remove"
        return ok(await request(path, method: "POST", form: ["entry": entry]))
    }
}
