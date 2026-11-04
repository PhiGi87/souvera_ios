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

    // MARK: - Öffentliche API

    /// Prüft die calendar-availability des Accounts und entfernt sie bei
    /// Korruption via PROPPATCH. Rückgabe `true` = repariert (Property
    /// entfernt), `false` = nichts zu reparieren oder PROPFIND/PROPPATCH
    /// fehlgeschlagen (dann fliegt der ursprüngliche Save-Fehler unverändert
    /// weiter; hier wird bewusst NICHT geworfen, damit die Selbstheilung
    /// niemals die eigentliche Fehlerdiagnose verschleiert).
    static func diagnoseAndRepair(account: String? = nil) async -> Bool {
        // Account-Daten (wie SouveraOutOfOfficeOcsApi.accountInfo).
        let tbl: tableAccount?
        if let account {
            tbl = NCManageDatabase.shared.getAllTableAccount().first(where: { $0.account == account })
        } else {
            tbl = NCManageDatabase.shared.getActiveTableAccount()
        }
        guard let tbl else {
            SouveraLog.write("Vacation", "repair skip: kein Account")
            return false
        }
        let password = NCPreferences().getPassword(account: tbl.account)
        guard !tbl.urlBase.isEmpty, !tbl.user.isEmpty, !password.isEmpty else {
            SouveraLog.write("Vacation", "repair skip: unvollständige Account-Daten")
            return false
        }

        // Scheduling-Inbox-URI: <baseUrl>/remote.php/dav/calendars/<uid>/inbox/
        // (uid percent-encoded, Usernamen dürfen Sonderzeichen enthalten).
        let root = tbl.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedUser = tbl.user.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        ) ?? tbl.user
        guard let inboxUrl = URL(string: "\(root)\(inboxPath)/\(encodedUser)/inbox/") else {
            SouveraLog.write("Vacation", "repair skip: Inbox-URL ungültig")
            return false
        }

        // (a) PROPFIND: nur die calendar-availability anfordern.
        guard let availability = await propfindAvailability(url: inboxUrl,
                                                            username: tbl.user,
                                                            password: password) else {
            // Fehlender Property-Wert ist auch der Normalfall (nie gesetzt):
            // nichts zu reparieren, der 500 hat hier eine andere Ursache.
            return false
        }

        // (b) Heuristik: gültig ist ein VCALENDAR mit VTIMEZONE (das sind
        // die Pflichtbestandteile, die getUserTimezone() unparsed bzw.
        // via ->VTIMEZONE erwartet). Fehlt eines → korrupt → Repair.
        let looksValid = availability.contains("BEGIN:VCALENDAR") && availability.contains("BEGIN:VTIMEZONE")
        if looksValid {
            SouveraLog.write("Vacation", "repair: availability gültig (\(availability.count) Zeichen), kein Repair nötig")
            return false
        }
        SouveraLog.write("Vacation", "repair: availability korrupt (\(availability.count) Zeichen, VCALENDAR=\(availability.contains("BEGIN:VCALENDAR")), VTIMEZONE=\(availability.contains("BEGIN:VTIMEZONE"))) -> entfernen")

        // (c) Repair: Property via PROPPATCH <remove> entfernen.
        let removed = await proppatchRemove(url: inboxUrl, username: tbl.user, password: password)
        return removed
    }

    // MARK: - PROPFIND

    /// PROPFIND (Depth 0) auf den Inbox-Node; liefert den Property-Wert
    /// als String oder nil (nicht gesetzt / Request-Fehler / Status != 207).
    private static func propfindAvailability(url: URL, username: String, password: String) async -> String? {
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
            SouveraLog.write("Vacation", "repair propfind error=\(error.localizedDescription)")
            return nil
        }
        guard code == 207 else {
            // 404 = Inbox existiert (selten) oder Property nicht gesetzt -
            // beides kein Repair-Kandidat.
            SouveraLog.write("Vacation", "repair propfind status=\(code) -> kein Repair")
            return nil
        }

        // (b) Multistatus-XML parsen und den Property-Wert extrahieren
        // (XMLParser dekodiert XML-Entities automatisch in foundCharacters).
        let parser = AvailabilityXMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        guard xmlParser.parse(), let value = parser.availability, !value.isEmpty else {
            // Kein Wert = Property nicht gesetzt (Normalfall).
            SouveraLog.write("Vacation", "repair propfind: kein availability-Wert -> kein Repair")
            return nil
        }
        SouveraLog.write("Vacation", "repair propfind status=207 value=\(value.count) Zeichen")
        return value
    }

    // MARK: - PROPPATCH

    /// PROPPATCH <remove> der calendar-availability (Sabre löscht beim
    /// Entfernen die Property-Zeile im DAV-Property-Store - identisch zum
    /// Web-Client, der beim "Availability löschen" genau denselben
    /// Request sendet). Erfolg = Multistatus 207 mit 200-Propstat.
    private static func proppatchRemove(url: URL, username: String, password: String) async -> Bool {
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
            SouveraLog.write("Vacation", "repair proppatch error=\(error.localizedDescription)")
            return false
        }
        // 207 Multistatus: eigentliche Results stehen in den propstats.
        let success = code == 207 && proppatchResponsesOk(body: data)
        SouveraLog.write("Vacation", "repair proppatch status=\(code) result=\(success ? "removed" : "failed")")
        return success
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
private final class AvailabilityXMLParser: NSObject, XMLParserDelegate {

    private var depthInProperty = 0
    private(set) var availability: String?

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard isAvailabilityElement(elementName, namespaceURI: namespaceURI) else { return }
        depthInProperty += 1
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard depthInProperty > 0 else { return }
        availability = (availability ?? "") + string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        guard isAvailabilityElement(elementName, namespaceURI: namespaceURI) else { return }
        depthInProperty = max(0, depthInProperty - 1)
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
