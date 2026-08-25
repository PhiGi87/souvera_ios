// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from souvera_android mail/SouveraMailLoginFlow.kt + CombinedAppPassword.kt.
//
// Wraps souvera_mail's `POST /apps/souvera_mail/app-passwords/login-flow` endpoint.
//
// Login Flow v2 hands the app a Nextcloud app-password `X` (kept as the account
// password for Files/CalDAV/CardDAV). This endpoint mints an ADDITIONAL combined
// password `Y` that Stalwart (JMAP/IMAP/SMTP/Sieve) also accepts, used ONLY for
// the mail client. Keeping `X` and `Y` separate means no invalidation and no
// broken sync. Auth is HTTP Basic with `X`.

import Foundation

struct CombinedAppPassword: Decodable {
    let loginName: String
    let appPassword: String
    let stalwartId: String
}

enum SouveraMailLoginFlow {
    /// Eindeutige Mint-Beschreibung PRO INSTALLATION: Der Server ersetzt
    /// beim Mint das App-Passwort derselben Beschreibung. Ohne UUID würden
    /// sich mehrere Instanzen (Gerät + Simulator, 2. Gerät) gegenseitig
    /// entminten und eine Endlos-401-Schleife erzeugen.
    private static var description: String {
        let key = "souvera_mail_app_password_uuid"
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return "Souvera iOS \(existing)"
        }
        let uuid = UUID().uuidString
        defaults.set(uuid, forKey: key)
        return "Souvera iOS \(uuid)"
    }

    private static let httpNotFound = 404

    static func fetchCombinedAppPassword(baseUrl: String, username: String, currentAppPassword: String) async throws -> CombinedAppPassword {
        do {
            return try await request(baseUrl: baseUrl, username: username, currentAppPassword: currentAppPassword, useIndexPhp: false)
        } catch let failure as HttpFailure where failure.code == httpNotFound {
            return try await request(baseUrl: baseUrl, username: username, currentAppPassword: currentAppPassword, useIndexPhp: true)
        }
    }

    struct HttpFailure: Error { let code: Int; let message: String }

    private static func request(baseUrl: String, username: String, currentAppPassword: String, useIndexPhp: Bool) async throws -> CombinedAppPassword {
        let root = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = useIndexPhp ? "/index.php/apps/souvera_mail" : "/apps/souvera_mail"
        guard let url = URL(string: "\(root)\(path)/app-passwords/login-flow") else {
            throw HttpFailure(code: -1, message: "Invalid URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let raw = "\(username):\(currentAppPassword)"
        req.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["description": description])

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw HttpFailure(code: code, message: "HTTP \(code) - \(String(data: data, encoding: .utf8) ?? "")")
        }
        return try JSONDecoder().decode(CombinedAppPassword.self, from: data)
    }
}
