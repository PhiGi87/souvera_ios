// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 04.11.: In-App-Selbstheilung für Vacation-500-Fehler.
//
// Diagnose (nextcloud/server stable34, apps/dav/lib/CalDAV/TimezoneService.php):
// Der OCS-Out-of-Office-Endpunkt liest beim Schreiben die Zeitzone über
// `TimezoneService.getUserTimezone(userId)`. Dort wird die DAV-Eigenschaft
//   {urn:ietf:params:xml:ns:caldav}calendar-availability
// aus dem Sabre-Property-Store gelesen - Node/URI ist NICHT der Principal,
// sondern der Scheduling-Inbox des Nutzers:
//   DAV-Pfad:  calendars/<uid>/inbox
//   HTTP-URI:  <baseUrl>/remote.php/dav/calendars/<uid>/inbox/
//   Quelle:    $propertyMapper->findPropertyByPathAndName($userId, 'calendars/'.$userId.'/inbox', ...);
// Der Wert wird UNGESCHÜTZT mit Sabre VObject Reader::read() geparst und
// danach $vCalendar->VTIMEZONE->getTimeZone() aufgerufen. Ein korrupter,
// leerer oder VTIMEZONE-loser Wert wirft daher einen uncaught Throw
// → HTTP 500 beim Vacation-POST (der GET-Pfad nutzt das nicht, daher
// liefert GET sauber 404).
//
// Web-Client-Referenz (gleiches Node, gleiche Property):
//   apps/dav/src/service/CalendarService.ts (findScheduleInboxAvailability /
//   saveScheduleInboxAvailability): PROPFIND/PROPPATCH auf 'inbox'
//   unterhalb des Kalender-Roots; Entfernen via PROPPATCH <remove> mit
//   leere Property - genau diese Semantik wird hier übernommen.
//
// Repair-Strategie: Korrupte/kaputte calendar-availability per PROPPATCH
// <remove> vom Inbox-Node entfernen. Ohne Property liefert
// getUserTimezone() null (bzw. fällt auf die persönliche Kalender-Zeitzone
// und zuletzt auf die Server-Default-Timezone zurück) - die
// Verfügbarkeits-/Abwesenheitsfunktion bleibt vollständig funktionsfähig;
// der Nutzer kann die Verfügbarkeit im Web jederzeit neu setzen.

import Foundation

/// Selbstheilung der CalDAV-Eigenschaft `{urn:ietf:params:xml:ns:caldav}
/// calendar-availability` auf dem Scheduling-Inbox-Node (siehe Dateikopf).
enum SouveraCalendarAvailabilityRepair {

    private static let inboxPath = "/remote.php/dav/calendars"
    static let caldavNamespace = "urn:ietf:params:xml:ns:caldav"

    // MARK: - Ergebnis-Typen

    /// Strukturiertes Ergebnis des Repair-Laufs (Run 05.11.): Bisher lieferte
    /// `diagnoseAndRepair` nur ein Bool - "kein availability-Wert -> kein
    /// Repair" war dabei nicht unterscheidbar von PROPFIND-Fehler oder
    /// Parsing-Versagen. Die Outcomes erlauben dem Aufrufer (Vacation-Save)
    /// gezielt zu entscheiden, ob ein Retry Sinn hat.
    enum RepairOutcome {
        /// Property gefunden und via PROPPATCH entfernt -> Save-Retry sinnvoll.
        case removed
        /// Property existiert nicht (404-Propstat bzw. nicht in der
        /// 207-Antwort): der 500 hat eine andere Ursache, kein Retry.
        case propertyMissing
        /// PROPFIND schlug fehl (HTTP-Statuscode bzw. -1 bei Transportfehler).
        case propfindFailed(status: Int)
        /// PROPPATCH schlug fehl (HTTP-Statuscode bzw. -1 bei Transportfehler).
        case patchFailed(status: Int)
        /// Multistatus-XML konnte nicht geparst werden.
        case parseError
        /// Repair gar nicht erst möglich (Account-Daten unvollständig).
        case skipped(String)
    }

    /// Zwischenergebnis des PROPFIND auf calendar-availability.
    private enum PropfindResult {
        /// Property war in der 207-Antwort vorhanden (Wert darf leer sein -
        /// auch das ist korrupt und wird entfernt).
        case available(String)
        /// Property wurde explizit nicht geliefert (404-Propstat oder gar
        /// nicht in der Antwort enthalten).
        case propertyMissing
        case httpFailed(status: Int)
        case parseError
    }

    // MARK: - Öffentliche API

    /// Prüft die calendar-availability des Accounts und entfernt sie.
    ///
    /// Run 05.11.: Bei einem 500 auf dem Vacation-POST ist das Entfernen der
    /// Property DIE Therapie - sobald die Property überhaupt vorhanden ist,
    /// wird sie unabhängig von unserer Korrupt-Heuristik via PROPPATCH
    /// entfernt. Die Heuristik (VCALENDAR/VTIMEZONE) dient nur noch der
    /// Diagnose-Logzeile, nicht mehr der Repair-Entscheidung: Ein
    /// syntaktisch "gültig" aussehender Wert kann trotzdem genau den
    /// Sabre-Throw auslösen, der den 500 verursacht. Ohne Property fällt
    /// `TimezoneService.getUserTimezone()` sauber auf Default-Zonen zurück.
    static func diagnoseAndRepair(account: String? = nil) async -> RepairOutcome {
        // Account-Daten (wie SouveraOutOfOfficeOcsApi.accountInfo).
        let tbl: tableAccount?
        if let account {
            tbl = NCManageDatabase.shared.getAllTableAccount().first(where: { $0.account == account })
        } else {
            tbl = NCManageDatabase.shared.getActiveTableAccount()
        }
        guard let tbl else {
            SouveraLog.write("Vacation", "repair skip: kein Account")
            return .skipped("kein Account")
        }
        let password = NCPreferences().getPassword(account: tbl.account)
        guard !tbl.urlBase.isEmpty, !tbl.user.isEmpty, !password.isEmpty else {
            SouveraLog.write("Vacation", "repair skip: unvollständige Account-Daten")
            return .skipped("unvollständige Account-Daten")
        }

        // Scheduling-Inbox-URI: <baseUrl>/remote.php/dav/calendars/<uid>/inbox/
        // (uid percent-encoded, Usernamen dürfen Sonderzeichen enthalten).
        let root = tbl.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedUser = tbl.user.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        ) ?? tbl.user
        guard let inboxUrl = URL(string: "\(root)\(inboxPath)/\(encodedUser)/inbox/") else {
            SouveraLog.write("Vacation", "repair skip: Inbox-URL ungültig")
            return .skipped("Inbox-URL ungültig")
        }

        // (a) PROPFIND: nur die calendar-availability anfordern.
        let availability: String
        switch await propfindAvailability(url: inboxUrl,
                                          username: tbl.user,
                                          password: password) {
        case .available(let value):
            availability = value
        case .propertyMissing:
            // Nie gesetzt = Normalfall: nichts zu reparieren, der 500 hat
            // hier eine andere Ursache.
            return .propertyMissing
        case .httpFailed(let status):
            return .propfindFailed(status: status)
        case .parseError:
            return .parseError
        }

        // (b) Diagnose-Log: die Heuristik entscheidet NICHT mehr über den
        // Repair (siehe Doc-Kommentar oben), sie dient nur der Einordnung.
        let looksValid = availability.contains("BEGIN:VCALENDAR") && availability.contains("BEGIN:VTIMEZONE")
        SouveraLog.write("Vacation", "repair: availability vorhanden (\(availability.count) Zeichen, heuristisch \(looksValid ? "gültig" : "korrupt"), VCALENDAR=\(availability.contains("BEGIN:VCALENDAR")), VTIMEZONE=\(availability.contains("BEGIN:VTIMEZONE"))) -> entfernen (500-Therapie)")

        // (c) Repair: Property via PROPPATCH <remove> entfernen.
        let patch = await proppatchRemove(url: inboxUrl, username: tbl.user, password: password)
        guard patch.removed else {
            return .patchFailed(status: patch.status)
        }
        return .removed
    }

    // MARK: - PROPFIND

    /// PROPFIND (Depth 0) auf den Inbox-Node mit differenzierter Auswertung:
    /// HTTP-Status wird geloggt, und ob die Property in der Antwort
    /// vorhanden (200-Propstat), explizit nicht gefunden (404-Propstat) war
    /// oder das XML-Parsing versagte.
    private static func propfindAvailability(url: URL, username: String, password: String) async -> PropfindResult {
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        // Identischer Body wie im Web-Client (CalendarService.ts).
        request.httpBody = Data("""
        <?xml version="1.0"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="\(caldavNamespace)">
          <d:prop>
            <c:calendar-availability/>
          </d:prop>
        </d:propfind>
        """.utf8)
        authorize(&request, username: username, password: password)

        let data: Data
        let code: Int
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            data = body
            code = (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch {
            SouveraLog.write("Vacation", "repair propfind transport-error=\(error.localizedDescription)")
            return .httpFailed(status: -1)
        }
        guard code == 207 else {
            // 404 auf dem Node = Inbox existiert (selten); alles andere
            // (401/403/5xx) ebenfalls kein Repair-Kandidat.
            SouveraLog.write("Vacation", "repair propfind status=\(code) (erwartet 207) -> kein Repair")
            return .httpFailed(status: code)
        }
        SouveraLog.write("Vacation", "repair propfind status=207 ok")

        // Multistatus-XML parsen: Property vorhanden? Welcher Propstat-Status?
        let parser = AvailabilityXMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        guard xmlParser.parse(), parser.propstatStatuses.count > 0 || parser.sawAvailability else {
            SouveraLog.write("Vacation", "repair propfind: XML-Parsing fehlgeschlagen (\(xmlParser.parserError?.localizedDescription ?? "unbekannt"))")
            return .parseError
        }

        guard parser.sawAvailability else {
            // Property nicht in der Antwort: bei 207 heißt das "nicht
            // gesetzt" (Sabre liefert entweder einen 404-Propstat oder
            // lässt die Property komplett weg).
            let propstat = parser.availabilityPropstatStatus.map(String.init) ?? "?"
            SouveraLog.write("Vacation", "repair propfind: Property nicht gefunden (propstat=\(propstat)) -> propertyMissing")
            return .propertyMissing
        }

        let value = parser.availability ?? ""
        let propstat = parser.availabilityPropstatStatus.map(String.init) ?? "?"
        SouveraLog.write("Vacation", "repair propfind: Property vorhanden (propstat=\(propstat), \(value.count) Zeichen)")
        // Erste 200 Zeichen des rohen Werts - escaped (Zeilenenden/Steuer-
        // zeichen), damit wir den tatsächlichen Inhalt im Log sehen.
        let preview = escapedPreview(of: value)
        SouveraLog.write("Vacation", "repair propfind: value[0..<200]='\(preview)'")
        return .available(value)
    }

    /// Kürzt einen Property-Wert auf 200 Zeichen und escapet Zeilenenden
    /// sowie Steuerzeichen (base64-safe: reiner ASCII-Ausgabe-Text).
    private static func escapedPreview(of value: String, limit: Int = 200) -> String {
        let truncated = String(value.prefix(limit))
        let escaped = truncated
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        let controlChars = CharacterSet.controlCharacters
        guard !escaped.unicodeScalars.contains(where: { controlChars.contains($0) }) else {
            // Verbleibende Steuerzeichen: als Unicode-Escapes darstellen.
            return escaped.unicodeScalars.map { scalar -> String in
                controlChars.contains(scalar) ? "\\u{\(String(scalar.value, radix: 16))}" : String(scalar)
            }.joined()
        }
        return escaped
    }

    // MARK: - PROPPATCH

    /// PROPPATCH <remove> der calendar-availability (Sabre löscht beim
    /// Entfernen die Property-Zeile im DAV-Property-Store - identisch zum
    /// Web-Client, der beim "Availability löschen" genau denselben
    /// Request sendet). Erfolg = Multistatus 207 mit 200-Propstat.
    /// Rückgabe: `(removed, status)` - der Statuscode wird für das
    /// strukturierte Ergebnis (`RepairOutcome.patchFailed`) mitgeliefert.
    private static func proppatchRemove(url: URL, username: String, password: String) async -> (removed: Bool, status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "PROPPATCH"
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0"?>
        <d:propertyupdate xmlns:d="DAV:" xmlns:c="\(caldavNamespace)">
          <d:remove>
            <d:prop>
              <c:calendar-availability/>
            </d:prop>
          </d:remove>
        </d:propertyupdate>
        """.utf8)
        authorize(&request, username: username, password: password)

        let code: Int
        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            data = body
            code = (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch {
            SouveraLog.write("Vacation", "repair proppatch transport-error=\(error.localizedDescription)")
            return (false, -1)
        }
        // 207 Multistatus: eigentliche Results stehen in den propstats.
        let success = code == 207 && proppatchResponsesOk(body: data)
        SouveraLog.write("Vacation", "repair proppatch status=\(code) result=\(success ? "removed" : "failed")")
        return (success, code)
    }

    /// Prüft im 207-Body, dass jeder propstat einen 2xx-Status meldet.
    private static func proppatchResponsesOk(body: Data) -> Bool {
        let parser = PropstatXMLParser()
        let xmlParser = XMLParser(data: body)
        xmlParser.delegate = parser
        guard xmlParser.parse() else { return false }
        return parser.statuses.allSatisfy { (200..<300).contains($0) } && !parser.statuses.isEmpty
    }

    // MARK: - Auth

    /// HTTP Basic mit NC-User + App-Passwort (identisch zum OCS-Client).
    private static func authorize(_ request: inout URLRequest, username: String, password: String) {
        let raw = "\(username):\(password)"
        request.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
    }
}

// MARK: - XML-Parsing

/// XMLParser-Delegate: sammelt den Textinhalt des
/// `{urn:ietf:params:xml:ns:caldav}calendar-availability`-Elements
/// (innerhalb der multistatus/propstat-Struktur; Namespace- und
/// Tiefe-unabhängig, da die Property-Elemente exakt benannt sind).
/// Run 05.11.: Trackt zusätzlich, OB das Property-Element überhaupt in der
/// Antwort war (auch leer!) und welchen HTTP-Status der zugehörige
/// Propstat meldet - damit sind 200-Propstat ("vorhanden") und
/// 404-Propstat ("nicht gefunden") unterscheidbar.
private final class AvailabilityXMLParser: NSObject, XMLParserDelegate {

    private var depthInProperty = 0
    private var propstatIndex = -1
    private var insideStatus = false
    private var statusBuffer = ""
    /// Das calendar-availability-Element war in der Antwort vorhanden
    /// (unabhängig davon, ob es Text enthielt).
    private(set) var sawAvailability = false
    private(set) var availability: String?
    /// Propstat-Index, in dem das Property-Element lag (-1 wenn keins).
    private var availabilityPropstatIndex = -1
    /// Alle Propstat-Status der Antwort (Reihenfolge des Dokuments).
    private(set) var propstatStatuses: [Int] = []
    /// HTTP-Status des Propstats, der die Property enthielt (nil bei
    /// fehlender Property oder fehlendem <status>-Element).
    private(set) var availabilityPropstatStatus: Int?

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch localName(of: elementName) {
        case "propstat":
            propstatIndex += 1
        case "status":
            insideStatus = true
            statusBuffer = ""
        default:
            break
        }
        guard isAvailabilityElement(elementName, namespaceURI: namespaceURI) else { return }
        depthInProperty += 1
        sawAvailability = true
        availabilityPropstatIndex = propstatIndex
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideStatus {
            statusBuffer += string
        } else if depthInProperty > 0 {
            availability = (availability ?? "") + string
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        switch localName(of: elementName) {
        case "status":
            insideStatus = false
            let status = Self.parseHTTPStatus(statusBuffer)
            propstatStatuses.append(status)
            if propstatIndex == availabilityPropstatIndex {
                availabilityPropstatStatus = status
            }
        case "propstat":
            propstatIndex -= 1
        default:
            break
        }
        guard isAvailabilityElement(elementName, namespaceURI: namespaceURI) else { return }
        depthInProperty = max(0, depthInProperty - 1)
    }

    /// "HTTP/1.1 200 OK" -> 200 (graceful: -1 bei unparsbarem Text).
    private static func parseHTTPStatus(_ text: String) -> Int {
        let parts = text.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return -1 }
        return code
    }

    private func localName(of elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init) ?? elementName
    }

    /// Elementname kann "calendar-availability" (Default-NS) oder mit
    /// Präfix "c:calendar-availability" o. ä. sein.
    private func isAvailabilityElement(_ elementName: String, namespaceURI: String?) -> Bool {
        let localName = elementName.split(separator: ":").last.map(String.init) ?? elementName
        guard localName == "calendar-availability" else { return false }
        // Namespaceprüfung, falls geliefert; sonst Struktur-Namensgenauigkeit.
        return namespaceURI == nil || namespaceURI == SouveraCalendarAvailabilityRepair.caldavNamespace
    }
}

/// XMLParser-Delegate: sammelt alle <d:status>-Texte (z. B. "HTTP/1.1 200 OK")
/// eines 207-Multistatus, um PROPPATCH-Ergebnisse zu bewerten.
private final class PropstatXMLParser: NSObject, XMLParserDelegate {

    private var insideStatus = false
    private(set) var statuses: [Int] = []

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let localName = elementName.split(separator: ":").last.map(String.init) ?? elementName
        insideStatus = localName == "status"
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideStatus else { return }
        // "HTTP/1.1 200 OK" → Statuscode extrahieren (Zweitbestandteil).
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        if parts.count >= 2, let code = Int(parts[1]) {
            statuses.append(code)
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        insideStatus = false
    }
}
