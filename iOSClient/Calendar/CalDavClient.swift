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

    private func calendarHomeURL() -> URL? {
        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else { return nil }
        let root = tbl.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // The DAV principal on Souvera is the full login (email), not the
        // short userId.
        let principal = tbl.user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tbl.user
        return URL(string: "\(root)/remote.php/dav/calendars/\(principal)/")
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
        guard let home = calendarHomeURL() else { return [] }
        var req = authorizedRequest(for: home, method: "PROPFIND")
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.httpBody = Self.propfindBody.data(using: .utf8)
        guard let (data, response) = try? await urlSession.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 207,
              let xml = String(data: data, encoding: .utf8) else { return [] }

        var calendars: [CalDavCalendar] = []
        let responsePattern = #"<(?:[A-Za-z0-9_]+:)?response[^>]*>(.*?)</(?:[A-Za-z0-9_]+:)?response>"#
        guard let regex = try? NSRegularExpression(pattern: responsePattern, options: [.dotMatchesLineSeparators]) else { return [] }
        for match in regex.matches(in: xml, range: NSRange(location: 0, length: (xml as NSString).length)) {
            guard let blockRange = Range(match.range(at: 1), in: xml) else { continue }
            let block = String(xml[blockRange])
            let isCalendar = block.range(of: "calendar", options: .caseInsensitive) != nil
            guard isCalendar,
                  let href = Self.firstMatch(pattern: #"<(?:[A-Za-z0-9_]+:)?href>([^<]+)</(?:[A-Za-z0-9_]+:)?href>"#, in: block),
                  !href.isEmpty else { continue }
            let name = Self.firstMatch(pattern: #"<(?:[A-Za-z0-9_]+:)?displayname>([^<]*)</(?:[A-Za-z0-9_]+:)?displayname>"#, in: block)
                ?? (href as NSString).lastPathComponent
            calendars.append(CalDavCalendar(href: href, displayName: name.isEmpty ? (href as NSString).lastPathComponent : name))
        }
        return calendars
    }

    // MARK: - Events for a time range

    func fetchEvents(calendarHref: String, start: Date, end: Date) async -> [CalDavEventEntry] {
        guard let home = calendarHomeURL(),
              let url = URL(string: calendarHref, relativeTo: home)?.absoluteURL else { return [] }
        var req = authorizedRequest(for: url, method: "REPORT", contentType: "application/xml; charset=utf-8")
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.httpBody = Self.reportBody(start: start, end: end).data(using: .utf8)
        guard let (data, response) = try? await urlSession.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 207,
              let xml = String(data: data, encoding: .utf8) else { return [] }

        var events: [CalDavEventEntry] = []
        let responsePattern = #"<(?:[A-Za-z0-9_]+:)?response[^>]*>(.*?)</(?:[A-Za-z0-9_]+:)?response>"#
        guard let regex = try? NSRegularExpression(pattern: responsePattern, options: [.dotMatchesLineSeparators]) else { return [] }
        for match in regex.matches(in: xml, range: NSRange(location: 0, length: (xml as NSString).length)) {
            guard let blockRange = Range(match.range(at: 1), in: xml) else { continue }
            let block = String(xml[blockRange])
            guard let ics = Self.firstMatch(
                pattern: #"<(?:[A-Za-z0-9_]+:)?calendar-data[^>]*>(.*?)</(?:[A-Za-z0-9_]+:)?calendar-data>"#,
                in: block
            ) else { continue }
            let href = Self.firstMatch(pattern: #"<(?:[A-Za-z0-9_]+:)?href>([^<]+)</(?:[A-Za-z0-9_]+:)?href>"#, in: block) ?? ""
            let etag = Self.firstMatch(pattern: #"<(?:[A-Za-z0-9_]+:)?getetag>([^<]+)</(?:[A-Za-z0-9_]+:)?getetag>"#, in: block)
            let vcalendar = ics
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
            events.append(CalDavEventEntry(calendarHref: calendarHref, href: href, etag: etag, ics: vcalendar))
        }
        return events
    }

    // MARK: - Writing

    @discardableResult
    func createEvent(calendarHref: String, ics: String, uid: String) async -> CalDavEventEntry? {
        guard let home = calendarHomeURL(),
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
        guard let home = calendarHomeURL(),
              let calendarURL = URL(string: entry.calendarHref, relativeTo: home)?.absoluteURL,
              let url = URL(string: entry.href, relativeTo: calendarURL)?.absoluteURL else { return false }
        var req = authorizedRequest(for: url, method: "PUT", contentType: "text/calendar; charset=utf-8")
        if let etag = entry.etag {
            req.setValue(etag, forHTTPHeaderField: "If-Match")
        }
        req.httpBody = ics.data(using: .utf8)
        guard let (_, response) = try? await urlSession.data(for: req) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func deleteEvent(_ entry: CalDavEventEntry) async -> Bool {
        guard let home = calendarHomeURL(),
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
            </c:comp-filter>
          </c:filter>
        </c:calendar-query>
        """
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
