// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 04.11.: Anbindung an die OFFIZIELLE Nextcloud Out-of-Office API
// (dav-App, OCS). Die bisherigen souvera_mail-Vacation-Endpunkte sind
// für native Clients durch den CSRF-Check (HTTP 412) blockiert; der
// souvera_mail-Cron übernimmt die NC-Abwesenheit stündlich in den
// Sieve-Responder. Die App pflegt die Abwesenheit daher ausschließlich
// über die dav-OCS-Schnittstelle:
//
//   GET    /ocs/v2.php/apps/dav/api/v1/outOfOffice/{userId}  → Datensatz (404 = keine Abwesenheit)
//   POST   /ocs/v2.php/apps/dav/api/v1/outOfOffice/{userId}  → setzen (Body form-urlencoded)
//   DELETE /ocs/v2.php/apps/dav/api/v1/outOfOffice/{userId}  → löschen (404 toleriert)
//
// Server-Vertrag (verifiziert):
//   - Header: OCS-APIRequest: true, Accept: application/json, HTTP Basic
//     (NC-Username + App-Passwort des Accounts, identisch zum bisherigen
//     Vacation-Schema in SouveraVacationResponder).
//   - GET-Antwort: OCS-Envelope {"ocs":{"meta":{...},"data":{id, userId,
//     firstDay:"YYYY-MM-DD", lastDay:"YYYY-MM-DD", status (≤100 Zeichen),
//     message, replacementUserId, replacementUserDisplayName}}}.
//   - POST: Parameter firstDay, lastDay, status, message, optional
//     replacementUserId. 400 mit {"error":"statusLength"|"firstDay"}
//     bei Validierungsfehlern (firstDay > lastDay).
//   - userId ist tblAccount.user des aktiven Accounts. Der Wert wird
//     NUR für den Pfadanteil percent-encoded (Usernamen können
//     Leerzeichen enthalten) - niemals die Basis-URL.
//
// Apple-Referenz: URLSession/URLRequest Standard-API, keine
// plattformspezifischen Besonderheiten.

import Foundation

/// Ein Out-of-Office-Datensatz der Nextcloud dav-App, wie er von der
/// OCS-API gelesen und geschrieben wird.
struct SouveraOutOfOffice: Equatable {
    /// Start des Zeitraums ("firstDay", device-local; nil = nicht gesetzt).
    var firstDay: Date?
    /// Ende des Zeitraums ("lastDay", device-local; nil = nicht gesetzt).
    var lastDay: Date?
    /// Kurztext (≤ 100 Zeichen) - entspricht dem bisherigen "Betreff".
    var status: String
    /// Langtext der Abwesenheitsnotiz.
    var message: String
    /// UserId der Vertretung (optional).
    var replacementUserId: String?
    /// Anzeigename der Vertretung (nur lesend, serverseitig aufgelöst).
    var replacementUserDisplayName: String?
}

/// Client für die offizielle Nextcloud Out-of-Office OCS-API (siehe Dateikopf).
enum SouveraOutOfOfficeOcsApi {

    private static let basePath = "/ocs/v2.php/apps/dav/api/v1/outOfOffice"

    // MARK: - Öffentliche API

    /// Liest die Abwesenheit des Accounts. `nil` = keine Abwesenheit
    /// vorhanden (HTTP 404 des Endpunkts - das ist der Normalfall, kein Fehler).
    static func get(account: String? = nil) async throws -> SouveraOutOfOffice? {
        let info = try accountInfo(account)
        var request = try request(baseUrl: info.baseUrl, userId: info.username, method: "GET")
        authorize(&request, username: info.username, password: info.password)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if code == 404 {
            SouveraLog.write("Vacation", "get status=404 -> keine Abwesenheit")
            return nil
        }
        guard (200..<300).contains(code) else {
            // Diagnose: NC-Antworten können Hinweise im Body enthalten -
            // die ersten 300 Zeichen mit in die Log-Zeile (escaped, einzeilig).
            SouveraLog.write("Vacation", "get status=\(code) message=\(errorMessage(from: data) ?? "-") body=\(bodySnippet(from: data))")
            throw SouveraVacationError.http(code, errorMessage(from: data))
        }
        let fields = try ocsDataFields(from: data)
        let record = SouveraOutOfOffice(
            firstDay: date(fields["firstDay"] as? String),
            lastDay: date(fields["lastDay"] as? String),
            status: (fields["status"] as? String) ?? "",
            message: (fields["message"] as? String) ?? "",
            replacementUserId: fields["replacementUserId"] as? String,
            replacementUserDisplayName: fields["replacementUserDisplayName"] as? String
        )
        SouveraLog.write("Vacation", "get status=200 firstDay=\(fields["firstDay"] as? String ?? "-")")
        return record
    }

    /// Setzt die Abwesenheit. Der Status wird serverkonform auf 100
    /// Zeichen gekappt; ein Zeitraum mit firstDay > lastDay wird lokal
    /// mit einem eigenen Validierungsfehler abgewiesen.
    static func set(account: String? = nil,
                    firstDay: Date,
                    lastDay: Date,
                    status: String,
                    message: String,
                    replacementUserId: String?) async throws {
        // Validierung: OCS duldet max. 100 Zeichen Status und einen
        // Zeitraum, dessen Start nicht nach dem Ende liegt.
        let cappedStatus = String(status.prefix(100))
        if lastDay < firstDay {
            SouveraLog.write("Vacation", "set validation: firstDay > lastDay")
            throw SouveraVacationError.validation
        }
        let info = try accountInfo(account)
        var pairs = [
            "firstDay=\(dateString(firstDay))",
            "lastDay=\(dateString(lastDay))",
            "status=\(formEncode(cappedStatus))",
            "message=\(formEncode(message))"
        ]
        if let replacementUserId, !replacementUserId.isEmpty {
            pairs.append("replacementUserId=\(formEncode(replacementUserId))")
        }
        var request = try request(baseUrl: info.baseUrl, userId: info.username, method: "POST")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(pairs.joined(separator: "&").utf8)
        authorize(&request, username: info.username, password: info.password)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            // 400 kann {"error":"statusLength"|"firstDay"} enthalten -
            // als Server-Message durchreichen (siehe errorMessage).
            let serverMessage = validationMessage(from: data) ?? errorMessage(from: data)
            SouveraLog.write("Vacation", "set status=\(code) message=\(serverMessage ?? "-") body=\(bodySnippet(from: data))")
            // Run 04.11.: Bei HTTP 500 (und nur dann) GENAU EINEN Retry
            // mit identischen Feldern als JSON-Body. NC bindet OCS-
            // Parameter auch aus JSON-Bodies; der Retry umgeht damit
            // Form-Body-Parsing-Probleme der konkreten Server-Instanz
            // (500 = uncaught Throw im Server, z. B. new DateTimeImmutable('')
            // wenn Params nicht ankommen). replacementUserId wird bei
            // leerem Wert weggelassen, nicht als null mitgeschickt.
            if code == 500 {
                SouveraLog.write("Vacation", "set form status=500 -> retry json")
                // Bei erneutem Fehler wirft setJson wie bisher.
                return try await setJson(account: account,
                                         firstDay: firstDay,
                                         lastDay: lastDay,
                                         status: cappedStatus,
                                         message: message,
                                         replacementUserId: replacementUserId)
            }
            throw SouveraVacationError.http(code, serverMessage)
        }
        SouveraLog.write("Vacation", "set status=\(code) ok")
    }

    /// Retry-Pfad von `set`: identische Felder als JSON-Body
    /// (Content-Type: application/json), nur bei Form-500 aufgerufen.
    /// Wirft den (letzten) Fehler, wenn auch der JSON-Versuch fehlschlägt.
    private static func setJson(account: String?,
                                firstDay: Date,
                                lastDay: Date,
                                status: String,
                                message: String,
                                replacementUserId: String?) async throws {
        let info = try accountInfo(account)
        var body: [String: String] = [
            "firstDay": dateString(firstDay),
            "lastDay": dateString(lastDay),
            "status": status,
            "message": message
        ]
        if let replacementUserId, !replacementUserId.isEmpty {
            body["replacementUserId"] = replacementUserId
        }
        var request = try request(baseUrl: info.baseUrl, userId: info.username, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        authorize(&request, username: info.username, password: info.password)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            let serverMessage = validationMessage(from: data) ?? errorMessage(from: data)
            SouveraLog.write("Vacation", "set json status=\(code) message=\(serverMessage ?? "-") body=\(bodySnippet(from: data))")
            throw SouveraVacationError.http(code, serverMessage)
        }
        SouveraLog.write("Vacation", "set json status=\(code) ok")
    }

    /// Löscht die Abwesenheit. 404 wird toleriert (schon gelöscht = ok).
    static func clear(account: String? = nil) async throws {
        let info = try accountInfo(account)
        var request = try request(baseUrl: info.baseUrl, userId: info.username, method: "DELETE")
        authorize(&request, username: info.username, password: info.password)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if code == 404 {
            SouveraLog.write("Vacation", "clear status=404 -> bereits gelöscht, ok")
            return
        }
        guard (200..<300).contains(code) else {
            SouveraLog.write("Vacation", "clear status=\(code) message=\(errorMessage(from: data) ?? "-") body=\(bodySnippet(from: data))")
            throw SouveraVacationError.http(code, errorMessage(from: data))
        }
        SouveraLog.write("Vacation", "clear status=\(code) ok")
    }

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

    /// Baut einen OCS-Request gegen den Out-of-Office-Endpunkt. Der
    /// userId-Pfadanteil wird percent-encoded (Usernamen dürfen
    /// Leerzeichen enthalten) - die Basis-URL bleibt unangetastet.
    private static func request(baseUrl: String, userId: String, method: String) throws -> URLRequest {
        let root = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedUser = userId.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        ) ?? userId
        guard let url = URL(string: "\(root)\(basePath)/\(encodedUser)") else {
            throw SouveraVacationError.noAccount
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        // OCS verlangt den Request-Header, sonst antwortet der Server
        // mit einer XML-/HTML-Fehlerseite statt JSON.
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// HTTP Basic mit NC-User + Account-App-Passwort (gleiche Quelle wie
    /// `SouveraMailCredentialManager.accountInfo`).
    private static func authorize(_ request: inout URLRequest, username: String, password: String) {
        let raw = "\(username):\(password)"
        request.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
    }

    /// Account-Infos (urlBase, NC-User, Account-App-Passwort) des aktiven
    /// oder expliziten Accounts.
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

    // MARK: - Antwort-Parsing

    /// Extrahiert die `data`-Fields aus dem OCS-Envelope
    /// {"ocs":{"meta":{...},"data":{...}}}. Fehlt der Envelope oder die
    /// data-Map, ist die Antwort ungültig.
    private static func ocsDataFields(from data: Data) throws -> [String: Any] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ocs = json["ocs"] as? [String: Any],
              let fields = ocs["data"] as? [String: Any] else {
            SouveraLog.write("Vacation", "response ohne OCS-Envelope/data -> invalidResponse")
            throw SouveraVacationError.invalidResponse
        }
        return fields
    }

    /// Zieht aus einem 400-Antwort-Body die {"error":...}-Kennung heraus
    /// (statusLength | firstDay) und macht sie lesbar.
    private static func validationMessage(from data: Data?) -> String? {
        guard let data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = json["error"] as? String, !error.isEmpty else {
            return nil
        }
        switch error {
        case "statusLength":
            return NSLocalizedString("_vacation_error_status_length_", value: "The status must not exceed 100 characters.", comment: "")
        case "firstDay":
            return NSLocalizedString("_vacation_error_period_", value: "The start date must not be after the end date.", comment: "")
        default:
            return error
        }
    }

    /// Zieht aus einem Antwort-Body eine {message:...} Server-Message
    /// heraus (für .http(code, message)).
    private static func errorMessage(from data: Data?) -> String? {
        guard let data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        // OCS-Envelope: Message steckt in ocs.meta.message, sonst direkt.
        if let ocs = json["ocs"] as? [String: Any],
           let meta = ocs["meta"] as? [String: Any],
           let message = meta["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    /// Encodiert einen FORM-Body-Wert (x-www-form-urlencoded).
    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    /// Diagnose: die ersten 300 Zeichen des Response-Bodies, escaped und
    /// einzeilig (NC-Fehlerseiten können Hinweise auf die Ursache tragen).
    /// Nimmt JSON- und HTML-Bodies gleichermaßen auf; "-" bei leerem Body.
    private static func bodySnippet(from data: Data?) -> String {
        guard let data, !data.isEmpty,
              let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              !raw.isEmpty else {
            return "-"
        }
        let snippet = String(raw.prefix(300))
        let escaped = snippet
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return escaped
    }
}
