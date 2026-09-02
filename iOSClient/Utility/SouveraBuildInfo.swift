// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Version / build / git-commit information shown in the UI so testers can
/// always tell which build they are running.
///
/// The git commit is injected by the CI build via
/// `INFOPLIST_KEY_SouveraGitCommit=$(git rev-parse --short HEAD)`.
struct SouveraBuildInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    static var gitCommit: String {
        Bundle.main.object(forInfoDictionaryKey: "SouveraGitCommit") as? String ?? ""
    }

    /// e.g. "Souvera 33.1.0 (Build 14) · 5538b1d"
    static var label: String {
        var parts = ["Souvera \(version) (Build \(buildNumber))"]
        if !gitCommit.isEmpty {
            parts.append(gitCommit)
        }
        return parts.joined(separator: " · ")
    }
}

/// In-App-Sprachwahl (System/Deutsch/English/Español/Français/Nederlands).
enum SouveraLanguage {
    static let defaultsKey = "AppleLanguages"
    static let supportedCodes = ["de", "en", "es", "fr", "nl"]

    static var currentCode: String {
        let languages = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        if let first = languages.first, supportedCodes.contains(first) {
            return first
        }
        return "system"
    }

    static func set(_ code: String) {
        if code == "system" {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set([code], forKey: defaultsKey)
        }
    }
}

/// Background refresh interval setting: while the app is active, the mail and
/// calendar modules re-sync automatically; the same interval is used as an
/// advisory value for BGAppRefresh. Werte in Sekunden; 0 = aus.
enum SouveraAutoRefresh {
    static let defaultsKey = "souvera_auto_refresh_seconds"
    static let legacyMinutesKey = "souvera_auto_refresh_minutes"
    /// Aus, 30 Sekunden, 2, 5 und 15 Minuten.
    static let presets: [Int] = [0, 30, 120, 300, 900]

    static var intervalSeconds: Int {
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            return UserDefaults.standard.integer(forKey: defaultsKey)
        }
        // Migration vom früheren Minuten-Wert.
        let legacy = UserDefaults.standard.integer(forKey: legacyMinutesKey)
        if legacy > 0 {
            let seconds = legacy * 60
            UserDefaults.standard.set(seconds, forKey: defaultsKey)
            UserDefaults.standard.removeObject(forKey: legacyMinutesKey)
            return seconds
        }
        // Standard: 5 Minuten.
        return 300
    }

    static var interval: TimeInterval? {
        let seconds = intervalSeconds
        return seconds > 0 ? TimeInterval(seconds) : nil
    }

    static func set(seconds: Int) {
        UserDefaults.standard.set(seconds, forKey: defaultsKey)
    }

    static func label(for seconds: Int) -> String {
        if seconds <= 0 {
            return NSLocalizedString("_settings_auto_refresh_off_", comment: "")
        }
        if seconds < 60 {
            return String(format: NSLocalizedString("_settings_auto_refresh_seconds_", comment: ""), seconds)
        }
        return String(format: NSLocalizedString("_settings_auto_refresh_minutes_", comment: ""), seconds / 60)
    }
}

/// Builds the combined "normal voip" push token string understood by the
/// Nextcloud push proxy (both halves separated by a single space).
enum SouveraPushRegistrar {
    static func combinedToken(normal: String, voip: String) -> String {
        let parts = [normal, voip].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    /// Meldet ein Gerät am Push-Proxy ab (DELETE /devices) - Talk-Muster
    /// (unsubscribeAccount), hält die Geräteliste sauber (keine toten
    /// Token-Zeilen mehr).
    static func unregisterAtProxy(proxyServerUrl: String,
                                  deviceIdentifier: String,
                                  signature: String,
                                  publicKey: String) async {
        let trimmed = proxyServerUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/devices?format=json") else {
            SouveraLog.write("PushProxy", "unregister invalid proxy URL \(proxyServerUrl)")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let params = [
            "deviceIdentifier": deviceIdentifier,
            "deviceIdentifierSignature": signature,
            "userPublicKey": publicKey
        ]
        let form = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
        req.httpBody = form.data(using: .utf8)
        let result = try? await URLSession.shared.data(for: req)
        let status = (result?.1 as? HTTPURLResponse)?.statusCode ?? -1
        SouveraLog.write("PushProxy", "unregister \(trimmed) -> http \(status)")
    }

    /// Registriert das Gerät direkt am Push-Proxy. Eigene Implementierung
    /// statt NextcloudKit: Der Souvera-Proxy antwortet mit HTTP 200 und
    /// LEEREM Body - Alamofire/NextcloudKit werten das als Fehler
    /// ("failed proxy 200") und das Gerät bleibt unregistriert. Hier zählt
    /// jeder 2xx-Status als Erfolg; der Body wird zu Diagnose-Zwecken
    /// geloggt.
    static func registerAtProxy(proxyServerUrl: String,
                                pushToken: String,
                                deviceIdentifier: String,
                                signature: String,
                                publicKey: String) async -> Bool {
        let trimmed = proxyServerUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/devices?format=json") else {
            SouveraLog.write("PushProxy", "invalid proxy URL \(proxyServerUrl)")
            return false
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Felder exakt wie der Nextcloud-Standard (Vertrag zum Proxy).
        let params = [
            "pushToken": pushToken,
            "deviceIdentifier": deviceIdentifier,
            "deviceIdentifierSignature": signature,
            "userPublicKey": publicKey
        ]
        // Form-Werte korrekt kodieren (wie Alamofire URLEncoding): nur
        // Alphanumerics + "-._~" erlauben. Base64-Felder (Signatur,
        // PublicKey) enthalten '+', '/', '=' - rohes '+' würde vom
        // Form-Parser als Leerzeichen interpretiert und die Signatur-
        // Prüfung am Proxy scheitert mit HTTP 400.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let form = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
        req.httpBody = form.data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            SouveraLog.write("PushProxy", "register \(trimmed) -> http \(status) body=\(body)")
            if (200..<300).contains(status) {
                return true
            }
            // 409 = Gerät/Token existiert am Proxy bereits unter einem ANDEREN
            // Schlüssel (anderer Account oder Alt-Registrierung). Ein DELETE
            // mit dem aktuellen (falschen) Schlüssel würde am Proxy mit 403
            // scheitern und nur Churn erzeugen -> bewusst NICHT löschen.
            // Die saubere Abmeldung übernimmt der Account-Wechsel-Flow
            // (unregister des ALTEN Accounts mit DESSEN gespeichertem Key),
            // bevor der neue Account registriert wird.
            if status == 409 {
                SouveraLog.write("PushProxy", "register \(trimmed) -> 409 conflict (device owned by another key); skipped destructive unregister")
            }
            return false
        } catch {
            SouveraLog.write("PushProxy", "register \(trimmed) failed: \(error.localizedDescription)")
            return false
        }
    }
}


/// Push-Deep-Links: Zielt beim Antippen einer Benachrichtigung direkt auf
/// die jeweilige Mail, den Termin oder den Chat-Raum. AppDelegate routet
/// (Tab-Wechsel) und postet das Ziel; die Module beobachten das Event.
enum SouveraPushDeepLink {
    /// Klasse statt Enum: NotificationCenter benötigt ein Objekt (Reference
    /// Type) als object-Payload.
    final class Target: NSObject {
        enum Kind {
            case mail, event, room
        }

        let kind: Kind
        let account: String
        let emailId: String
        /// JMAP-Mailbox-Name (z. B. "INBOX", "Archiv/2026") als Kontext für
        /// den Mail-Push - leer = INBOX-Fallback.
        let mailboxPath: String
        let uid: String
        let start: TimeInterval
        let token: String
        let title: String

        private init(kind: Kind, account: String, emailId: String, mailboxPath: String, uid: String, start: TimeInterval, token: String, title: String) {
            self.kind = kind
            self.account = account
            self.emailId = emailId
            self.mailboxPath = mailboxPath
            self.uid = uid
            self.start = start
            self.token = token
            self.title = title
        }

        static func mail(account: String, emailId: String, mailboxPath: String = "") -> Target {
            Target(kind: .mail, account: account, emailId: emailId, mailboxPath: mailboxPath, uid: "", start: 0, token: "", title: "")
        }

        static func event(uid: String, start: TimeInterval, account: String = "") -> Target {
            Target(kind: .event, account: account, emailId: "", mailboxPath: "", uid: uid, start: start, token: "", title: "")
        }

        static func room(token: String, title: String, account: String = "") -> Target {
            Target(kind: .room, account: account, emailId: "", mailboxPath: "", uid: "", start: 0, token: token, title: title)
        }
    }

    static let opened = Notification.Name("souveraPushDeepLinkOpened")

    static func deliver(_ target: Target) {
        NotificationCenter.default.post(name: opened, object: target)
    }
}



/// Text-Kürzung für Push-Notifications (Apple-Mail/WhatsApp-Stil):
/// Titelzeile (fett) auf ~1 Zeile, Body auf ~2-3 Zeilen begrenzt - iOS
/// zeigt beim Aufklappen mehr an.
enum SouveraNotificationText {
    static func title(_ raw: String) -> String {
        trim(raw, limit: 60)
    }

    static func body(_ raw: String) -> String {
        trim(raw, limit: 180)
    }

    private static func trim(_ raw: String, limit: Int) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        let cut = String(cleaned.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }
}
