// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 03.11.: Abwesenheitsassistent (Vacation Responder) gegen die
// souvera_mail-Server-Endpunkte:
//   - GET  /apps/souvera_mail/vacation        → Status lesen
//   - POST /apps/souvera_mail/vacation        → Status setzen
//   - POST /apps/souvera_mail/vacation/sync   → sofortiger NC→Sieve-Sync
//
// Auth: identisch zu den bestehenden souvera_mail-Requests in der App
// (Login-Flow `SouveraMailLoginFlow`, Geräte-Registrierung
// `SouveraMailDeviceRegistrar`): HTTP Basic mit dem Nextcloud-User und
// dem App-Passwort des aktiven Accounts (tblAccount + NCPreferences-
// Passwort). Das Mail-Modul minted dafür KEIN zweites Passwort - der
// Vacation-Endpunkt ist ein Nextcloud-App-Endpunkt, kein Stalwart-
// Endpunkt, daher ist das Account-App-Passwort der richtige Schlüssel.
//
// Datum-Format: Der Server erwartet "YYYY-MM-DD" bzw. null. Wir
// formatieren device-local über DateComponents (kein UTC-Shift) und
// parsen die Antworten symmetrisch zurück.

import Foundation

/// Zustand des Abwesenheitsassistenten, wie er vom Server gelesen und
/// an ihn geschrieben wird.
struct SouveraVacationState: Equatable {
    /// Assistent aktiv (serverseitig gespeicherter Zustand).
    var enabled: Bool
    /// Betreff der automatischen Antwort.
    var subject: String
    /// Text der automatischen Antwort.
    var message: String
    /// Start des Zeitraums (nil = ab sofort).
    var from: Date?
    /// Ende des Zeitraums (nil = unbefristet).
    var to: Date?
    /// Unterstützt der Mail-Server überhaupt Abwesenheitsnotizen?
    /// false → UI zeigt den Hinweistext und deaktiviert die Bearbeitung.
    var available: Bool

    static func unavailable() -> SouveraVacationState {
        SouveraVacationState(enabled: false, subject: "", message: "", from: nil, to: nil, available: false)
    }
}

/// Typisierte Fehler für die UI-Anzeige (NSLocalizedDescriptionKey).
enum SouveraVacationError: Error, LocalizedError {
    /// Kein aktiver Account bzw. unvollständige Account-Daten.
    case noAccount
    /// Ungültige Server-Antwort (unerwartetes JSON).
    case invalidResponse
    /// HTTP-Fehler mit Statuscode.
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .noAccount:
            return NSLocalizedString("_vacation_error_", comment: "")
        case .invalidResponse:
            return NSLocalizedString("_vacation_error_", comment: "")
        case .http(let code):
            return "\(NSLocalizedString("_vacation_error_", comment: "")) (HTTP \(code))"
        }
    }
}

/// Client für die Vacation-Endpunkte von souvera_mail (siehe Dateikopf).
enum SouveraVacationResponder {

    private static let path = "/apps/souvera_mail/vacation"

    // MARK: - Datum-Konvertierung (device-local "yyyy-MM-dd")

    /// Date → "yyyy-MM-dd" über DateComponents (device-local, kein UTC-Shift:
    /// ein Date um Mitternacht lokaler Zeit darf nicht auf den Vortag rutschen).
    static func dateString(_ date: Date) -> String {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "yyyy-MM-dd" → Date (Start des Tages, device-local). nil bei
    /// fehlendem/ungültigem Wert.
    static func date(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return nil
        }
        return date
    }

    // MARK: - Request-Bau

    /// Baut einen Vacation-Request mit demselben Auth-Schema wie die
    /// bestehenden souvera_mail-Calls (Basic: NC-User + Account-App-Passwort).
    private static func request(baseUrl: String, suffix: String, method: String, body: [String: Any]? = nil) throws -> URLRequest {
        let root = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(root)\(path)\(suffix)") else {
            throw SouveraVacationError.noAccount
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// Account-Infos (urlBase, NC-User, Account-App-Passwort) des aktiven
    /// oder expliziten Accounts - gleiche Quelle wie
    /// `SouveraMailCredentialManager.accountInfo`.
    private static func accountInfo(_ account: String?) throws -> (baseUrl: String, username: String, password: String) {
        let tbl: tableAccount?
        if let account {
            tbl = NCManageDatabase.shared.getAllTableAccount().first(where: { $0.account == account })
        } else {
            tbl = NCManageDatabase.shared.getActiveTableAccount()
        }
        guard let tbl else { throw SouveraVacationError.noAccount }
        let password = NCPreferences().getPassword(account: tbl.account)
        guard !tbl.urlBase.isEmpty, !tbl.user.isEmpty, !password.isEmpty else {
            throw SouveraVacationError.noAccount
        }
        return (tbl.urlBase, tbl.user, password)
    }

    /// Signiert den Request per HTTP Basic (wie Login-Flow/Devices).
    private static func authorize(_ request: inout URLRequest, username: String, password: String) {
        let raw = "\(username):\(password)"
        request.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
    }

    // MARK: - API

    /// Liest den Vacation-Zustand. Fehlende Felder → Defaults;
    /// `available == false` wird sauber als "nicht verfügbar" abgebildet.
    static func load(account: String? = nil) async throws -> SouveraVacationState {
        let info = try accountInfo(account)
        var req = try request(baseUrl: info.baseUrl, suffix: "", method: "GET")
        authorize(&req, username: info.username, password: info.password)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw SouveraVacationError.http(code)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SouveraVacationError.invalidResponse
        }
        // Robustes Parsing: fehlende Felder → Defaults. Manche Server-
        // Varianten liefern das Objekt unter "vacation", andere flach.
        let vacation = (json["vacation"] as? [String: Any]) ?? json
        let available = (json["available"] as? Bool) ?? true
        guard available else { return .unavailable() }
        return SouveraVacationState(
            enabled: (vacation["enabled"] as? Bool) ?? false,
            subject: (vacation["subject"] as? String) ?? "",
            message: (vacation["message"] as? String) ?? "",
            from: date(vacation["from"] as? String),
            to: date(vacation["to"] as? String),
            available: true
        )
    }

    /// Speichert den Vacation-Zustand und stößt danach fire-and-forget
    /// den sofortigen NC→Sieve-Sync an (Fehler des Syncs werden nur
    /// geloggt - der Server synct sonst regelmäßig selbst).
    static func save(account: String? = nil, _ state: SouveraVacationState) async throws {
        let info = try accountInfo(account)
        var body: [String: Any] = [
            "enabled": state.enabled,
            "subject": state.subject,
            "message": state.message
        ]
        if let from = state.from {
            body["from"] = dateString(from)
        }
        if let to = state.to {
            body["to"] = dateString(to)
        }
        var req = try request(baseUrl: info.baseUrl, suffix: "", method: "POST", body: body)
        authorize(&req, username: info.username, password: info.password)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw SouveraVacationError.http(code)
        }
        // Antwort format prüfen ({status:"ok"}), aber tolerant bleiben.
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let status = json["status"] as? String, status != "ok" {
            throw SouveraVacationError.invalidResponse
        }
        triggerSync(baseUrl: info.baseUrl, username: info.username, password: info.password)
    }

    /// Fire-and-forget: sofortiger NC→Sieve-Sync nach erfolgreichem POST.
    static func triggerSync(account: String? = nil) async {
        guard let info = try? accountInfo(account) else { return }
        triggerSync(baseUrl: info.baseUrl, username: info.username, password: info.password)
    }

    private static func triggerSync(baseUrl: String, username: String, password: String) {
        Task {
            guard var req = try? request(baseUrl: baseUrl, suffix: "/sync", method: "POST") else { return }
            authorize(&req, username: username, password: password)
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                SouveraLog.write("Vacation", "sync -> http \(code)")
            } catch {
                // Fire-and-forget: Sync-Fehler nur loggen, der Server
                // synchronisiert sonst periodisch selbst.
                SouveraLog.write("Vacation", "sync failed: \(error.localizedDescription)")
            }
        }
    }
}
