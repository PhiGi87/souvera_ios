// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Network
import NextcloudKit

/// P66d: Reichert souvera_mail-Push-Benachrichtigungen in der Notification
/// Service Extension an: Titel = Absender, Body = Betreff. Der Server
/// liefert für viele Mails nur generische Texte ("Neue E-Mail"/"Du hast
/// eine neue Nachricht erhalten") - die Extension lädt die Mail-Metadaten
/// deshalb selbst per JMAP (nur from + subject).
///
/// Eigenständig (kein App-Code): HTTP/1.1 über Network.framework (der
/// JMAP-Endpoint lehnt HTTP/2-POSTs ab) + eigene Mail-Credential mit
/// eigenem Login-Flow. Die Credential wird max. 1x pro Tag gemintzt und
/// in der App-Gruppe gecacht; jeder Fehler fällt graziös auf den
/// Server-Text zurück (kein Mint-Ping-Pong mit der App).
final class MailPushEnricher {

    static let shared = MailPushEnricher()

    private let defaults = UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup)
    private let credentialDescription = "souvera-mail-push-extension"
    private let mintIntervalSeconds: TimeInterval = 86400 // 1 Tag

    private var groupDefaults: UserDefaults {
        defaults ?? .standard
    }

    /// Liefert (title, body) für einen Mail-Push oder nil (Fallback).
    func enrich(root: String, ncUser: String, ncPassword: String, objectId: String) async -> (title: String, body: String)? {
        guard !objectId.isEmpty else { return nil }
        let rootTrimmed = root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let credential = await credential(root: rootTrimmed, ncUser: ncUser, ncPassword: ncPassword),
              let session = await jmapSession(root: rootTrimmed, user: credential.loginName, password: credential.appPassword),
              let accId = session.primaryAccountId,
              let apiUrl = session.apiUrl,
              let mail = await fetchMail(apiUrl: apiUrl, accountId: accId, user: credential.loginName, password: credential.appPassword, objectId: objectId) else { return nil }
        return mail
    }

    // MARK: - Credential (Login-Flow, max. 1x pro Tag)

    private struct PushCredential {
        let loginName: String
        let appPassword: String
    }

    private func credential(root: String, ncUser: String, ncPassword: String) async -> PushCredential? {
        let loginKey = "souvera_mail_push_ext_login"
        let passwordKey = "souvera_mail_push_ext_password"
        let mintedKey = "souvera_mail_push_ext_minted_at"
        if let cachedLogin = groupDefaults.string(forKey: loginKey),
           let cachedPassword = groupDefaults.string(forKey: passwordKey),
           !cachedLogin.isEmpty, !cachedPassword.isEmpty {
            return PushCredential(loginName: cachedLogin, appPassword: cachedPassword)
        }
        // Mint-Limit: höchstens 1x pro Tag (schützt vor Mint-Stürmen und
        // vor Ping-Pong mit der App-Credential).
        if let lastMint = groupDefaults.object(forKey: mintedKey) as? Date,
           Date().timeIntervalSince(lastMint) < mintIntervalSeconds {
            return nil
        }
        guard let url = URL(string: "\(root)/apps/souvera_mail/app-passwords/login-flow") else { return nil }
        let auth = "\(ncUser):\(ncPassword)"
        let basic = "Basic \(Data(auth.utf8).base64EncodedString())"
        let requestBody: [String: Any] = ["description": credentialDescription]
        let body = try? JSONSerialization.data(withJSONObject: requestBody)
        guard let body,
              let result = await httpRequest(url: url, method: "POST", headers: ["Authorization": basic, "Content-Type": "application/json", "Accept": "application/json"], body: body),
              result.status == 200,
              let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
              let loginName = json["loginName"] as? String,
              let appPassword = json["appPassword"] as? String,
              !loginName.isEmpty, !appPassword.isEmpty else {
            groupDefaults.set(Date(), forKey: mintedKey)
            return nil
        }
        groupDefaults.set(loginName, forKey: loginKey)
        groupDefaults.set(appPassword, forKey: passwordKey)
        groupDefaults.set(Date(), forKey: mintedKey)
        return PushCredential(loginName: loginName, appPassword: appPassword)
    }

    // MARK: - JMAP Session

    private struct SessionInfo {
        let apiUrl: String?
        let primaryAccountId: String?
    }

    private func jmapSession(root: String, user: String, password: String) async -> SessionInfo? {
        let auth = "\(user):\(password)"
        let basic = "Basic \(Data(auth.utf8).base64EncodedString())"
        // Session-Discovery: /.well-known/jmap, sonst /jmap/session.
        for path in ["/.well-known/jmap", "/jmap/session"] {
            guard let url = URL(string: "\(root)\(path)"),
                  let result = await httpRequest(url: url, method: "GET", headers: ["Authorization": basic, "Accept": "application/json"], body: nil),
                  result.status == 200,
                  let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else { continue }
            let apiUrl = json["apiUrl"] as? String
            let accId = json["primaryAccounts"] as? [String: String]
            return SessionInfo(apiUrl: apiUrl, primaryAccountId: accId?.values.first)
        }
        return nil
    }

    // MARK: - Email/get (nur Metadaten)

    private func fetchMail(apiUrl: String, accountId: String, user: String, password: String, objectId: String) async -> (title: String, body: String)? {
        guard let url = URL(string: apiUrl) else { return nil }
        let auth = "\(user):\(password)"
        let basic = "Basic \(Data(auth.utf8).base64EncodedString())"
        let payload: [String: Any] = [
            "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
            "methodCalls": [["Email/get", ["accountId": accountId, "ids": [objectId]], "S"]]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let result = await httpRequest(url: url, method: "POST", headers: ["Authorization": basic, "Content-Type": "application/json", "Accept": "application/json"], body: body),
              result.status == 200,
              let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
              let responses = json["methodResponses"] as? [[Any]],
              let first = responses.first,
              first.count >= 2,
              let response = first[1] as? [String: Any],
              let list = response["list"] as? [[String: Any]],
              let mail = list.first else { return nil }
        let from = (mail["from"] as? [[String: Any]])?.first
        let senderName = from?["name"] as? String ?? ""
        let senderMail = from?["email"] as? String ?? ""
        let sender = senderName.isEmpty ? senderMail : senderName
        let subject = mail["subject"] as? String ?? ""
        guard !sender.isEmpty, !subject.isEmpty else { return nil }
        return (sender, subject)
    }

    // MARK: - HTTP/1.1 (Network.framework)

    private func httpRequest(url: URL, method: String, headers: [String: String], body: Data?) async -> (status: Int, data: Data)? {
        await withCheckedContinuation { cont in
            guard let scheme = url.scheme, let host = url.host else {
                cont.resume(returning: nil)
                return
            }
            let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (scheme == "http" ? 80 : 443))) ?? NWEndpoint.Port(443)
            let tlsOptions = scheme == "https" ? NWProtocolTLS.Options() : nil
            let params: NWParameters
            if let tlsOptions {
                params = NWParameters(tls: tlsOptions)
            } else {
                params = NWParameters()
            }
            params.allowLocalEndpointReuse = true
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)

            var pathAndQuery = url.path
            if !pathAndQuery.isEmpty { /* already has leading slash */ } else { pathAndQuery = "/" }
            if let query = url.query, !query.isEmpty {
                pathAndQuery += "?\(query)"
            }
            var request = "\(method) \(pathAndQuery) HTTP/1.1\r\n"
            request += "Host: \(host)\r\n"
            for (key, value) in headers {
                request += "\(key): \(value)\r\n"
            }
            if let body {
                request += "Content-Length: \(body.count)\r\n"
            }
            request += "Connection: close\r\n\r\n"

            func receiveAll(accumulated: Data) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    var total = accumulated
                    if let data { total.append(data) }
                    if isComplete || error != nil {
                        connection.cancel()
                        let result = parseHttpResponse(total)
                        cont.resume(returning: result)
                    } else {
                        receiveAll(accumulated: total)
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                if case .failed = state {
                    connection.cancel()
                    cont.resume(returning: nil)
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in
                if let body {
                    connection.send(content: body, completion: .contentProcessed { _ in
                        receiveAll(accumulated: Data())
                    })
                } else {
                    receiveAll(accumulated: Data())
                }
            })
        }
    }

    private func parseHttpResponse(_ data: Data) -> (status: Int, data: Data)? {
        guard let text = String(data: data, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n") else { return nil }
        let headerPart = String(text[..<headerEnd.lowerBound])
        let lines = headerPart.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        // Byte-Offset des Body-Anfangs (Header ist ASCII, UTF-8 == Bytes).
        let bodyStart = Data(String(text[...headerEnd.upperBound]).utf8).count
        guard bodyStart <= data.count else { return nil }
        let body = data.subdata(in: bodyStart..<data.count)
        return (status, body)
    }
}
