// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// CalDAV client for the Souvera calendar module. Discovers the user's
// calendars via PROPFIND, loads VEVENTs for a time range via REPORT
// calendar-query, and creates/updates/deletes events via PUT/DELETE.

import Foundation

struct CalDavCalendar {
    let href: String
    let displayName: String
    /// Server-side calendar color as a hex string (#RRGGBB), if set.
    let color: String?
}

struct CalDavEventEntry {
    let calendarHref: String
    let href: String
    let etag: String?
    let ics: String
}

final class CalDavClient {

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config)
    }()

    // MARK: - Calendar discovery

    /// DAV principal candidates: the full login (email) is the principal on
    /// Souvera; some setups use the short userId instead. Both are tried.
    private func principalCandidates() -> [String] {
        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else { return [] }
        var candidates = [tbl.user]
        if !tbl.userId.isEmpty, tbl.userId != tbl.user {
            candidates.append(tbl.userId)
        }
        return candidates.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
    }

    private func calendarHomeURLs() -> [URL] {
        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else { return [] }
        let root = tbl.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return principalCandidates().compactMap {
            URL(string: "\(root)/remote.php/dav/calendars/\($0)/")
        }
    }

    private func authorizedRequest(for url: URL, method: String, contentType: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let contentType {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let tbl = NCManageDatabase.shared.getActiveTableAccount() {
            let davPassword = NCPreferences().getPassword(account: tbl.account)
            let raw = "\(tbl.user):\(davPassword)"
            req.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    func fetchCalendars() async -> [CalDavCalendar] {
        for home in calendarHomeURLs() {
            var req = authorizedRequest(for: home, method: "PROPFIND")
            req.setValue("1", forHTTPHeaderField: "Depth")
            req.httpBody = Self.propfindBody.data(using: .utf8)
            guard let (data, response) = try? await urlSession.data(for: req) else { continue }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            JmapLog.write("CalDAV PROPFIND \(home.absoluteString) -> \(status)")
            guard status == 207,
                  let xml = String(data: data, encoding: .utf8) else { continue }
            return Self.parseCalendars(from: xml)
        }
        return []
    }

    static func parseCalendars(from xml: String) -> [CalDavCalendar] {
        var calendars: [CalDavCalendar] = []
        for response in DavMultistatusParser().parse(xml) {
            // Only collections whose resourcetype contains <calendar/> are
            // real VEVENT calendars (skips the home, scheduling inbox/outbox,
            // trashbin and Deck boards).
            let resourcetype = response["resourcetype"] ?? ""
            guard resourcetype.localizedCaseInsensitiveContains("calendar") else { continue }
            guard let href = response["href"], !href.isEmpty else { continue }
            let name = response["displayname"]
            calendars.append(CalDavCalendar(
                href: href,
                displayName: (name?.isEmpty == false) ? name! : (href as NSString).lastPathComponent,
                color: response["color"]
            ))
        }
        return calendars
    }

    // MARK: - Events for a time range

    func fetchEvents(calendarHref: String, start: Date, end: Date) async -> [CalDavEventEntry] {
        guard let home = calendarHomeURLs().first,
              let url = URL(string: calendarHref, relativeTo: home)?.absoluteURL else { return [] }
        var req = authorizedRequest(for: url, method: "REPORT", contentType: "application/xml; charset=utf-8")
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.httpBody = Self.reportBody(start: start, end: end).data(using: .utf8)
        guard let (data, response) = try? await urlSession.data(for: req) else { return [] }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 207,
              let xml = String(data: data, encoding: .utf8) else {
            JmapLog.write("CalDAV calendar-query \(url.absoluteString) -> \(status)")
            return []
        }
        JmapLog.write("CalDAV calendar-query \(url.absoluteString) -> \(status), \(data.count) bytes")

        var events: [CalDavEventEntry] = []
        for response in DavMultistatusParser().parse(xml) {
            // XMLParser already decoded the entities (&#13;, &amp;, ...).
            guard let vcalendar = response["calendar-data"], !vcalendar.isEmpty else { continue }
            events.append(CalDavEventEntry(
                calendarHref: calendarHref,
                href: response["href"] ?? "",
                etag: response["etag"],
                ics: vcalendar
            ))
        }
        if events.isEmpty, !xml.isEmpty {
            JmapLog.write("CalDAV calendar-query \(url.absoluteString) -> 0 events; response prefix: \(xml.prefix(300))")
        }
        JmapLog.write("CalDAV calendar-query \(url.absoluteString) -> \(events.count) events parsed")
        return events
    }

    // MARK: - Writing

    @discardableResult
    func createEvent(calendarHref: String, ics: String, uid: String) async -> CalDavEventEntry? {
        guard let home = calendarHomeURLs().first,
              let calendarURL = URL(string: calendarHref, relativeTo: home)?.absoluteURL,
              let url = URL(string: "\(uid).ics", relativeTo: calendarURL)?.absoluteURL else { return nil }
        var req = authorizedRequest(for: url, method: "PUT", contentType: "text/calendar; charset=utf-8")
        req.httpBody = ics.data(using: .utf8)
        guard let (_, response) = try? await urlSession.data(for: req),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { return nil }
        let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
        return CalDavEventEntry(calendarHref: calendarHref, href: "\(uid).ics", etag: etag, ics: ics)
    }

    func updateEvent(_ entry: CalDavEventEntry, ics: String) async -> Bool {
        guard let home = calendarHomeURLs().first,
              let calendarURL = URL(string: entry.calendarHref, relativeTo: home)?.absoluteURL,
              let url = URL(string: entry.href, relativeTo: calendarURL)?.absoluteURL else { return false }
        var req = authorizedRequest(for: url, method: "PUT", contentType: "text/calendar; charset=utf-8")
        if let etag = entry.etag {
            req.setValue(etag, forHTTPHeaderField: "If-Match")
        }
        req.httpBody = ics.data(using: .utf8)
        guard let (data, response) = try? await urlSession.data(for: req) else {
            JmapLog.write("CalDAV updateEvent \(url.absoluteString) -> Transportfehler")
            return false
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if !(200..<300).contains(status) {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            JmapLog.write("CalDAV updateEvent \(url.absoluteString) -> \(status) \(body)")
        }
        return (200..<300).contains(status)
    }

    func deleteEvent(_ entry: CalDavEventEntry) async -> Bool {
        guard let home = calendarHomeURLs().first,
              let calendarURL = URL(string: entry.calendarHref, relativeTo: home)?.absoluteURL,
              let url = URL(string: entry.href, relativeTo: calendarURL)?.absoluteURL else { return false }
        var req = authorizedRequest(for: url, method: "DELETE")
        if let etag = entry.etag {
            req.setValue(etag, forHTTPHeaderField: "If-Match")
        }
        guard let (_, response) = try? await urlSession.data(for: req) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - XML bodies

    private static var propfindBody: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <d:displayname/>
            <d:resourcetype/>
            <c:calendar-color/>
          </d:prop>
        </d:propfind>
        """
    }

    private static func reportBody(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let startText = formatter.string(from: start)
        let endText = formatter.string(from: end)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <d:getetag/>
            <c:calendar-data/>
          </d:prop>
          <c:filter>
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT">
                <c:time-range start="\(startText)" end="\(endText)"/>
              </c:comp-filter>
              <c:comp-filter name="VTODO">
                <c:time-range start="\(startText)" end="\(endText)"/>
              </c:comp-filter>
            </c:comp-filter>
          </c:filter>
        </c:calendar-query>
        """
    }

}

// MARK: - Shared multistatus parser (Foundation XMLParser)

// Parses DAV multistatus responses with XMLParser (deterministic, decodes
// XML entities like &#13; automatically). Each `<response>` block becomes a
// dictionary with href, etag, displayname, color, address-data/calendar-data
// and a resourcetype marker string. Regular comments only: doc comments on
// NSObject subclasses are emitted into the generated ObjC header.
final class DavMultistatusParser: NSObject, XMLParserDelegate {
    private var responses: [[String: String]] = []
    private var currentResponse: [String: String]?
    private var currentElement = ""
    private var currentValue = ""

    func parse(_ xml: String) -> [[String: String]] {
        responses = []
        currentResponse = nil
        currentElement = ""
        currentValue = ""
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return responses
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = Self.localName(elementName)
        if local == "response" {
            currentResponse = [:]
        }
        currentElement = local
        currentValue = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = Self.localName(elementName)
        defer { currentValue = "" }
        guard var response = currentResponse else { return }
        let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local {
        case "href": if !value.isEmpty { response["href"] = value }
        case "getetag": if !value.isEmpty { response["etag"] = value }
        case "displayname": response["displayname"] = value
        case "calendar-color": if !value.isEmpty { response["color"] = value }
        case "address-data": response["address-data"] = value
        case "calendar-data": response["calendar-data"] = value
        case "collection", "calendar", "schedule-inbox", "schedule-outbox", "trash-bin", "addressbook":
            response["resourcetype"] = (response["resourcetype"] ?? "") + local + ";"
        default: break
        }
        if local == "response" {
            responses.append(response)
            currentResponse = nil
        } else {
            currentResponse = response
        }
    }

    private static func localName(_ elementName: String) -> String {
        (elementName as NSString).components(separatedBy: ":").last ?? elementName
    }
}
