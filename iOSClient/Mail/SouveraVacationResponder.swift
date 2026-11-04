// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 04.11.: Abwesenheitsassistent (Vacation Responder) gegen die
// souvera_mail-Server-Endpunkte:
//   - GET  /apps/souvera_mail/vacation        → Status lesen
//   - POST /apps/souvera_mail/vacation        → Status setzen (FORM-URLENCODED!)
//   - GET  /apps/souvera_mail/vacation/state  → kombinierter NC+Sieve-Zustand
//   - POST /apps/souvera_mail/vacation/sync   → sofortiger NC→Sieve-Sync
//
// WICHTIG (Server-Vertrag): Der POST liest die Parameter per
// request->getParam() — das ist Nextcloud-seitig der FORM-Body
// (application/x-www-form-urlencoded), NICHT JSON. Wir senden daher
// enabled/subject/message/from/to als urlencodete Key-Value-Paare.
//
// Auth: identisch zu den bestehenden souvera_mail-Requests in der App
// (Login-Flow `SouveraMailLoginFlow`, Geräte-Registrierung
// `SouveraMailDeviceRegistrar`): HTTP Basic mit dem Nextcloud-User und
// dem App-Passwort des aktiven Accounts (tblAccount + NCPreferences-
// Passwort). Das Mail-Modul minted dafür KEIN zweites Passwort - der
// Vacation-Endpunkt ist ein Nextcloud-App-Endpunkt, kein Stalwart-
// Endpunkt, daher ist das Account-App-Passwort der richtige Schlüssel.
//
// Datum-Format: Der Server erwartet "YYYY-MM-DD" bzw. leer/fehlend. Wir
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

/// Kombinierter Zustand aus `GET /vacation/state`
/// (`VacationSyncService::getState`): die in Nextcloud gepflegte
/// Abwesenheit (dav_absence / persönliche Verfügbarkeit) plus
/// Diagnose-Informationen. Die View zeigt daraus eine read-only
/// Sektion "In Nextcloud gepflegte Abwesenheit" - genau wie die
/// Webmail-"Von Nextcloud übernehmen"-Anzeige.
struct SouveraVacationCombinedState: Equatable {
    /// NC-Abwesenheits-Feature überhaupt vorhanden (NC 28+ / dav_absence).
    var supported: Bool
    /// NC→Sieve-Sync vom Nutzer aktiviert?
    var syncEnabled: Bool
    /// Es existiert eine (laufende ODER geplante) NC-Abwesenheit.
    var ncActive: Bool
    /// true = Zeitraum läuft aktuell, false = erst geplant.
    var inEffect: Bool
    /// Start "yyyy-MM-dd" (kann leer sein, z. B. Availability-Fallback).
    var start: String
    /// Ende "yyyy-MM-dd".
    var end: String
    /// Kurztext (Betreff) der NC-Abwesenheit.
    var short: String
    /// Langtext (Nachricht) der NC-Abwesenheit.
    var long: String
    /// Vertretung (display name), optional.
    var replacement: String

    /// Tolerantes Parsen aus einem untypisierten State-Dictionary
    /// (fehlende Felder → Defaults, wie beim Vacation-Parsing).
    static func parse(_ json: [String: Any]) -> SouveraVacationCombinedState {
        SouveraVacationCombinedState(
            supported: (json["supported"] as? Bool) ?? true,
            syncEnabled: (json["syncEnabled"] as? Bool) ?? true,
            ncActive: (json["ncActive"] as? Bool) ?? false,
            inEffect: (json["inEffect"] as? Bool) ?? false,
            start: (json["start"] as? String) ?? "",
            end: (json["end"] as? String) ?? "",
            short: (json["short"] as? String) ?? "",
            long: (json["long"] as? String) ?? "",
            replacement: (json["replacement"] as? String) ?? ""
        )
    }
}

/// Typisierte Fehler für die UI-Anzeige (NSLocalizedDescriptionKey).
enum SouveraVacationError: Error, LocalizedError {
    /// Kein aktiver Account bzw. unvollständige Account-Daten.
    case noAccount
    /// Ungültige Server-Antwort (unerwartetes JSON).
    case invalidResponse
    /// HTTP-Fehler mit Statuscode und optionaler Server-Message
    /// (aus {status:'error', message:...} des Antwort-Bodys).
    case http(Int, String?)

    var errorDescription: String? {
        switch self {
        // Run 04.11.: Fallback-Value deckt alle Sprachen ohne eigene
        // lproj-Einträge ab (Transifex liefert spätere Übersetzungen).
        case .noAccount:
            return NSLocalizedString("_vacation_error_", value: "The vacation responder could not be saved.", comment: "")
        case .invalidResponse:
            return NSLocalizedString("_vacation_error_", value: "The vacation responder could not be saved.", comment: "")
        case .http(let code, let message):
            // Run 04.11.: Statuscode + Server-Message präzise anzeigen
            // statt alles als "nicht verfügbar" zu werfen. Bsp.:
            // "Anfrage fehlgeschlagen (412)" + Server-Hinweis.
            let status = NSLocalizedString("_vacation_error_status_", value: "Request failed (%@)", comment: "")
            let base = String(format: status, "\(code)")
            if let message, !message.isEmpty {
                return "\(base): \(message)"
            }
            return base
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
    private static func request(baseUrl: String, suffix: String, method: String, formBody: String? = nil) throws -> URLRequest {
        let root = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(root)\(path)\(suffix)") else {
            throw SouveraVacationError.noAccount
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let formBody {
            // Run 04.11.: Server liest per request->getParam() → FORM-Body
            // (application/x-www-form-urlencoded), NICHT JSON.
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(formBody.utf8)
        }
        return req
    }

    /// Encodiert einen FORM-Body-Wert (x-www-form-urlencoded). %20 statt
    /// '+' für Leerzeichen ist beides gültig und serverseitig äquivalent.
    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    /// Baut den urlencodeten Body für den save-POST: enabled="1"/"0",
    /// subject, message, from/to als "yyyy-MM-dd" oder (nil) weggelassen.
    private static func saveFormBody(_ state: SouveraVacationState) -> String {
        var pairs = ["enabled=\(state.enabled ? "1" : "0")"]
        pairs.append("subject=\(formEncode(state.subject))")
        pairs.append("message=\(formEncode(state.message))")
        if let from = state.from {
            pairs.append("from=\(dateString(from))")
        }
        if let to = state.to {
            pairs.append("to=\(dateString(to))")
        }
        return pairs.joined(separator: "&")
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

    /// Zieht aus einem Antwort-Body eine {status:'error', message:...}
    /// Server-Message heraus (für .http(code, message)).
    private static func errorMessage(from data: Data?) -> String? {
        guard let data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = json["message"] as? String, !message.isEmpty else {
            return nil
        }
        return message
    }

    // MARK: - API

    /// Liest den Vacation-Zustand. Fehlende Felder → Defaults;
    /// `available == false` wird sauber als "nicht verfügbar" abgebildet.
    static func load(account: String? = nil) async throws -> SouveraVacationState {
        let info: (baseUrl: String, username: String, password: String)
        do {
            info = try accountInfo(account)
        } catch {
            SouveraLog.write("Vacation", "load noAccount")
            throw error
        }
        var req = try request(baseUrl: info.baseUrl, suffix: "", method: "GET")
        authorize(&req, username: info.username, password: info.password)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        // Run 03.11. (Härtung): 404 = ältere souvera_mail-Version ohne
        // Vacation-Endpunkte -> "nicht verfügbar" statt Fehler-Alert.
        if code == 404 {
            // Run 03.11. (Diagnose): alter Server ohne Vacation-Endpunkt.
            SouveraLog.write("Vacation", "load status=404 -> unavailable")
            return .unavailable()
        }
        guard (200..<300).contains(code) else {
            SouveraLog.write("Vacation", "load status=\(code) message=\(errorMessage(from: data) ?? "-")")
            throw SouveraVacationError.http(code, errorMessage(from: data))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            SouveraLog.write("Vacation", "load status=\(code) -> invalidResponse")
            throw SouveraVacationError.invalidResponse
        }
        // Robustes Parsing: fehlende Felder → Defaults. Manche Server-
        // Varianten liefern das Objekt unter "vacation", andere flach.
        let vacation = (json["vacation"] as? [String: Any]) ?? json
        let available = (json["available"] as? Bool) ?? true
        guard available else {
            SouveraLog.write("Vacation", "load status=\(code) available=false")
            return .unavailable()
        }
        return SouveraVacationState(
            enabled: (vacation["enabled"] as? Bool) ?? false,
            subject: (vacation["subject"] as? String) ?? "",
            message: (vacation["message"] as? String) ?? "",
            from: date(vacation["from"] as? String),
            to: date(vacation["to"] as? String),
            available: true
        )
    }

    /// Liest den kombinierten Zustand aus `GET /vacation/state`
    /// (NC-Abwesenheit + Sieve + Diagnose, siehe
    /// `VacationSyncService::getState`). Tolerantes Best-Effort-Parsing:
    /// fehlende Felder → Defaults. Nur für die read-only Anzeige der
    /// "In Nextcloud gepflegte Abwesenheit"-Sektion.
    static func loadState(account: String? = nil) async throws -> SouveraVacationCombinedState {
        let info: (baseUrl: String, username: String, password: String)
        do {
            info = try accountInfo(account)
        } catch {
            SouveraLog.write("Vacation", "loadState noAccount")
            throw error
        }
        var req = try request(baseUrl: info.baseUrl, suffix: "/state", method: "GET")
        authorize(&req, username: info.username, password: info.password)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            SouveraLog.write("Vacation", "loadState status=\(code) message=\(errorMessage(from: data) ?? "-")")
            throw SouveraVacationError.http(code, errorMessage(from: data))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            SouveraLog.write("Vacation", "loadState status=\(code) -> invalidResponse")
            throw SouveraVacationError.invalidResponse
        }
        // {status:'ok', state:{...}} — state tolerant als Grabbing lesen.
        let state = (json["state"] as? [String: Any]) ?? json
        let parsed = SouveraVacationCombinedState.parse(state)
        SouveraLog.write("Vacation", "loadState status=\(code) ncActive=\(parsed.ncActive) inEffect=\(parsed.inEffect)")
        return parsed
    }

    /// Speichert den Vacation-Zustand und stößt danach fire-and-forget
    /// den sofortigen NC→Sieve-Sync an (Fehler des Syncs werden nur
    /// geloggt - der Server synct sonst regelmäßig selbst).
    static func save(account: String? = nil, _ state: SouveraVacationState) async throws {
        let info: (baseUrl: String, username: String, password: String)
        do {
            info = try accountInfo(account)
        } catch {
            SouveraLog.write("Vacation", "save noAccount")
            throw error
        }
        var req = try request(
            baseUrl: info.baseUrl,
            suffix: "",
            method: "POST",
            formBody: saveFormBody(state)
        )
        authorize(&req, username: info.username, password: info.password)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            // Run 04.11.: Präzise Fehler mit Server-Message, z. B.
            // 412 (CSRF-Check des Servers, solange der NoCSRFRequired-
            // Patch fehlt), 400 (Validierung), 502/503 (Sieve weg).
            SouveraLog.write("Vacation", "save failed status=\(code) message=\(errorMessage(from: data) ?? "-")")
            throw SouveraVacationError.http(code, errorMessage(from: data))
        }
        // Antwort-Format prüfen ({status:'ok'}), aber tolerant bleiben;
        // ein {status:'error', message:...} bei 2xx wird ebenfalls
        // als präziser Fehler mit Server-Message geworfen.
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let status = json["status"] as? String, status != "ok" {
            let message = json["message"] as? String
            SouveraLog.write("Vacation", "save status=\(code) response-status=\(status) message=\(message ?? "-")")
            throw SouveraVacationError.http(code, message)
        }
        SouveraLog.write("Vacation", "save status=\(code) ok")
        // Fire-and-forget Sync - Fehler nur loggen.
        Task {
            try? await syncNow(
                baseUrl: info.baseUrl,
                username: info.username,
                password: info.password
            )
        }
    }

    /// Sofortiger NC→Sieve-Sync (`POST /vacation/sync`). Wirft bei
    /// Fehlerstatus präzise (Statuscode + Server-Message) - analog save.
    static func syncNow(account: String? = nil) async throws {
        let info = try accountInfo(account)
        try await syncNow(baseUrl: info.baseUrl, username: info.username, password: info.password)
    }

    private static func syncNow(baseUrl: String, username: String, password: String) async throws {
        var req = try request(baseUrl: baseUrl, suffix: "/sync", method: "POST")
        authorize(&req, username: username, password: password)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            SouveraLog.write("Vacation", "sync failed status=\(code) message=\(errorMessage(from: data) ?? "-")")
            throw SouveraVacationError.http(code, errorMessage(from: data))
        }
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let status = json["status"] as? String, status != "ok" {
            let message = json["message"] as? String
            SouveraLog.write("Vacation", "sync status=\(code) response-status=\(status) message=\(message ?? "-")")
            throw SouveraVacationError.http(code, message)
        }
        SouveraLog.write("Vacation", "sync status=\(code) ok")
    }
}
