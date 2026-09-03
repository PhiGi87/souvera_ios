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
import KeychainAccess

struct CombinedAppPassword: Decodable {
    let loginName: String
    let appPassword: String
    let stalwartId: String
}

enum SouveraMailLoginFlow {
    private static let uuidKey = "souvera_mail_app_password_uuid"
    private static let uuidKeychain = Keychain(service: "eu.souvera.workspace.mail")

    /// Eindeutige Mint-Beschreibung PRO GERÄT: Der Server ersetzt beim Mint
    /// das App-Passwort derselben Beschreibung. Ohne UUID würden sich mehrere
    /// Instanzen (Gerät + Simulator, 2. Gerät) gegenseitig entminten und eine
    /// Endlos-401-Schleife erzeugen. Die UUID liegt im KEYCHAIN, damit sie
    /// einen Reinstall überlebt (sonst verwaist der alte Token + dessen
    /// Push-Gerätezeile am Proxy bei jeder Neuinstallation).
    private static var description: String {
        if let existing = try? uuidKeychain.get(uuidKey), !existing.isEmpty {
            return "Souvera iOS \(existing)"
        }
        // Migration: früher lag die UUID in den UserDefaults.
        let defaults = UserDefaults.standard
        if let legacy = defaults.string(forKey: uuidKey), !legacy.isEmpty {
            try? uuidKeychain.set(legacy, key: uuidKey)
            return "Souvera iOS \(legacy)"
        }
        let uuid = UUID().uuidString
        try? uuidKeychain.set(uuid, key: uuidKey)
        defaults.set(uuid, forKey: uuidKey)
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

/// souvera_mail-Geräte-Registrierung für den DIREKTEN Mail-Push (Standard-
/// APNs, kein NC-Proxy): Registriert das APNs-Token nach dem Login und
/// meldet es beim Logout/Token-Wechsel wieder ab - so entstehen keine
/// Geräte-Leichen im System.
enum SouveraMailDeviceRegistrar {
    private static let deviceIdKey = "souvera_mail_device_id_"
    private static let deviceTokenKey = "souvera_mail_device_token_"

    static func storedDeviceId(account: String) -> String? {
        UserDefaults.standard.string(forKey: deviceIdKey + account)
    }

    static func storedToken(account: String) -> String? {
        UserDefaults.standard.string(forKey: deviceTokenKey + account)
    }

    /// true, wenn für diesen Token bereits eine Registrierung existiert -
    /// dann ist KEIN neuer POST nötig (kein Müll bei jedem App-Start).
    static func isCurrent(account: String, apnsToken: String) -> Bool {
        storedDeviceId(account: account) != nil && storedToken(account: account) == apnsToken
    }

    /// Registriert (bzw. re-registriert bei Token-Wechsel nach Abmeldung
    /// der alten Zeile). Liefert die gespeicherte Geräte-Id.
    @discardableResult
    static func register(baseUrl: String, username: String, ncPassword: String, apnsToken: String, account: String) async -> String? {
        // Token-Wechsel: alte Registrierung zuerst abmelden (keine Leichen).
        if let oldId = storedDeviceId(account: account),
           let oldToken = storedToken(account: account), oldToken != apnsToken {
            await unregister(baseUrl: baseUrl, username: username, ncPassword: ncPassword, deviceId: oldId, account: account)
        }
        let root = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(root)/apps/souvera_mail/devices") else {
            SouveraLog.write("MailDevice", "register failed: invalid URL")
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let raw = "\(username):\(ncPassword)"
        req.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["apnsToken": apnsToken, "platform": "ios"])
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                SouveraLog.write("MailDevice", "register -> http \(status)")
                return nil
            }
            let deviceId = (json["id"] as? String) ?? ((json["id"] as? NSNumber)?.stringValue ?? "")
            guard !deviceId.isEmpty else {
                SouveraLog.write("MailDevice", "register -> http \(status) without id")
                return nil
            }
            UserDefaults.standard.set(deviceId, forKey: deviceIdKey + account)
            UserDefaults.standard.set(apnsToken, forKey: deviceTokenKey + account)
            SouveraLog.write("MailDevice", "register ok id=\(deviceId.prefix(12))")
            return deviceId
        } catch {
            SouveraLog.write("MailDevice", "register failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Meldet das Gerät ab (Logout) und löscht die gespeicherten Werte.
    static func unregister(baseUrl: String, username: String, ncPassword: String, deviceId: String, account: String) async {
        let root = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(root)/apps/souvera_mail/devices/\(deviceId)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        let raw = "\(username):\(ncPassword)"
        req.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let result = try? await URLSession.shared.data(for: req)
        let status = (result?.1 as? HTTPURLResponse)?.statusCode ?? -1
        SouveraLog.write("MailDevice", "unregister id=\(deviceId.prefix(12)) -> http \(status)")
        UserDefaults.standard.removeObject(forKey: deviceIdKey + account)
        UserDefaults.standard.removeObject(forKey: deviceTokenKey + account)
    }
}
