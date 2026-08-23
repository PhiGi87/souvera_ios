// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Value types for the calendar module plus a compact iCalendar (RFC 5545)
// parser and serializer for VEVENTs.

import Foundation

struct CalendarEventModel: Identifiable {
    let id: String
    let uid: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String?
    let description: String?
    let attendees: [String]
    let talkRoomToken: String?
    let talkRoomName: String?
    let calendarHref: String
    let href: String
    let etag: String?
    let reminders: [Int]
    /// Deck-Kalender liefern VTODO-Aufgaben (Karten/Stacks): read-only.
    let isTask: Bool
}

struct EventDraft {
    var uid: String = ""
    var title: String = ""
    var start: Date = Date()
    var end: Date = Date().addingTimeInterval(3600)
    var allDay: Bool = false
    var location: String = ""
    var notes: String = ""
    var attendees: [String] = []
    var talkRoomToken: String?
    var talkRoomName: String?
    var reminders: [Int] = [15]
}

/// Localized labels for calendar reminders (shared between detail, edit
/// sheet and pickers).
enum CalendarReminderText {
    static let presets = [0, 5, 10, 15, 30, 60, 120, 1440]

    static func label(minutes: Int) -> String {
        if minutes <= 0 {
            return NSLocalizedString("_calendar_reminder_at_start_", comment: "")
        }
        if minutes % 1440 == 0 {
            let days = minutes / 1440
            let key = days == 1 ? "_calendar_reminder_day_before_" : "_calendar_reminder_days_before_"
            return String(format: NSLocalizedString(key, comment: ""), days)
        }
        if minutes % 60 == 0 {
            return String(format: NSLocalizedString("_calendar_reminder_hours_before_", comment: ""), minutes / 60)
        }
        return String(format: NSLocalizedString("_calendar_reminder_minutes_before_", comment: ""), minutes)
    }
}

enum ICSParser {

    static func parseEvents(_ ics: String, calendarHref: String, href: String, etag: String?) -> [CalendarEventModel] {
        var events: [CalendarEventModel] = []
        // Deck-Kalender speichern Karten/Stacks als VTODO - beide Objekttypen
        // einsammeln und VTODO als Aufgaben (read-only) markieren.
        var blocks: [(body: String, isTask: Bool)] = []
        for chunk in ics.components(separatedBy: "BEGIN:VEVENT").dropFirst() {
            blocks.append((chunk.components(separatedBy: "END:VEVENT").first ?? chunk, false))
        }
        for chunk in ics.components(separatedBy: "BEGIN:VTODO").dropFirst() {
            blocks.append((chunk.components(separatedBy: "END:VTODO").first ?? chunk, true))
        }
        for (body, isTask) in blocks {
            var uid = ""
            var title = ""
            var location: String?
            var notes: String?
            var attendees: [String] = []
            var talkRoomToken: String?
            var talkRoomName: String?
            var start: Date?
            var end: Date?
            var duration: TimeInterval?
            var allDay = false
            var startDay: Date?
            var endDay: Date?
            var inTimeZone = false
            var inAlarm = false
            var reminders: [Int] = []

            for rawLine in body.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                // VTIMEZONE blocks carry their own DTSTART/DST transitions
                // that must not overwrite the event's real start time.
                if line.hasPrefix("BEGIN:VTIMEZONE") {
                    inTimeZone = true
                    continue
                }
                if line.hasPrefix("END:VTIMEZONE") {
                    inTimeZone = false
                    continue
                }
                if inTimeZone { continue }
                // VALARM blocks carry their own DESCRIPTION/DESCRIPTION text
                // that must not overwrite the event fields - only TRIGGER
                // lines are of interest.
                if line.hasPrefix("BEGIN:VALARM") {
                    inAlarm = true
                    continue
                }
                if line.hasPrefix("END:VALARM") {
                    inAlarm = false
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else { continue }
                if inAlarm {
                    let alarmKey = String(line[line.startIndex..<colon]).uppercased()
                    if alarmKey.hasPrefix("TRIGGER") {
                        let alarmValue = String(line[line.index(after: colon)...])
                        if let minutes = parseTriggerMinutes(alarmValue) {
                            reminders.append(minutes)
                        }
                    }
                    continue
                }
                let rawKey = String(line[line.startIndex..<colon])
                let keyPart = rawKey.uppercased()
                let rawValue = String(line[line.index(after: colon)...])
                let value = unescape(rawValue)
                if keyPart == "UID" {
                    uid = value
                } else if keyPart == "SUMMARY" {
                    title = value
                } else if keyPart == "LOCATION" {
                    location = value
                } else if keyPart == "DESCRIPTION" {
                    notes = value
                } else if keyPart.hasPrefix("ATTENDEE") {
                    let email = value.replacingOccurrences(of: "mailto:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if email.contains("@") && !attendees.contains(email.lowercased()) {
                        attendees.append(email.lowercased())
                    }
                } else if keyPart == "X-SOUVERA-TALK-ROOM" {
                    talkRoomToken = value
                } else if keyPart == "X-SOUVERA-TALK-ROOM-NAME" {
                    talkRoomName = value
                } else if keyPart.hasPrefix("DTSTART") {
                    if keyPart.contains("VALUE=DATE") {
                        allDay = true
                        startDay = parseDateOnly(value)
                    } else {
                        start = parseDateTime(value, tzid: extractTzid(rawKey))
                    }
                } else if keyPart.hasPrefix("DTEND") {
                    if keyPart.contains("VALUE=DATE") {
                        endDay = parseDateOnly(value)
                    } else {
                        end = parseDateTime(value, tzid: extractTzid(rawKey))
                    }
                } else if keyPart.hasPrefix("DUE") {
                    if keyPart.contains("VALUE=DATE") {
                        allDay = true
                        endDay = parseDateOnly(value)
                    } else {
                        end = parseDateTime(value, tzid: extractTzid(rawKey))
                    }
                } else if keyPart == "DURATION" {
                    duration = parseDuration(value)
                }
            }

            // Talk room created by the Nextcloud Calendar web UI stores the
            // room URL in LOCATION/DESCRIPTION instead of a custom property:
            // extract the token from /call/<token>.
            if talkRoomToken == nil {
                let urlSource = [location, notes].compactMap { $0 }.joined(separator: "\n")
                if let callRange = urlSource.range(of: "/call/([a-z0-9]+)", options: .regularExpression) {
                    var raw = String(urlSource[callRange])
                    raw.removeFirst("/call/".count)
                    if !raw.isEmpty {
                        talkRoomToken = raw
                    }
                }
            }

            if isTask && start == nil && startDay == nil && end == nil && endDay == nil {
                // Stack ohne Datum: nicht im Kalender anzeigen
                continue
            }
            var resolvedStart = start ?? startDay ?? Date.distantPast
            var resolvedEnd = end ?? endDay
                ?? (duration.map { resolvedStart.addingTimeInterval($0) } ?? resolvedStart.addingTimeInterval(3600))
            if isTask && start == nil && startDay == nil {
                // Nur Fälligkeitsdatum vorhanden: Aufgabe zum Fälligkeitszeitpunkt zeigen
                resolvedStart = resolvedEnd
            }
            if allDay, endDay == nil, duration == nil {
                resolvedEnd = resolvedStart.addingTimeInterval(86400)
            }
            if resolvedEnd <= resolvedStart {
                resolvedEnd = resolvedStart.addingTimeInterval(allDay ? 86400 : 3600)
            }

            events.append(CalendarEventModel(
                id: href.isEmpty ? uid : href,
                uid: uid,
                title: title.isEmpty ? NSLocalizedString("_calendar_untitled_", comment: "") : title,
                start: resolvedStart,
                end: resolvedEnd,
                allDay: allDay,
                location: location,
                description: notes,
                attendees: attendees,
                talkRoomToken: talkRoomToken,
                talkRoomName: talkRoomName,
                calendarHref: calendarHref,
                href: href,
                etag: etag,
                reminders: reminders.sorted(),
                isTask: isTask
            ))
        }
        return events
    }

    /// Serializes a draft into an iCalendar VEVENT (all UTC).
    static func buildICS(_ draft: EventDraft, organizerEmail: String = "", organizerName: String = "") -> String {
        let uid = draft.uid.isEmpty ? UUID().uuidString.lowercased() : draft.uid
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let startLine: String
        let endLine: String
        if draft.allDay {
            // All-day dates are written as the device-local calendar day
            // (no GMT conversion, which could shift the date).
            let startComponents = Calendar.current.dateComponents([.year, .month, .day], from: draft.start)
            let startText = String(format: "%04d%02d%02d", startComponents.year ?? 0, startComponents.month ?? 0, startComponents.day ?? 0)
            let endDate = Calendar.current.date(byAdding: .day, value: 1, to: draft.start) ?? draft.end
            let endComponents = Calendar.current.dateComponents([.year, .month, .day], from: endDate)
            let endText = String(format: "%04d%02d%02d", endComponents.year ?? 0, endComponents.month ?? 0, endComponents.day ?? 0)
            startLine = "DTSTART;VALUE=DATE:\(startText)"
            endLine = "DTEND;VALUE=DATE:\(endText)"
        } else {
            startLine = "DTSTART:\(formatter.string(from: draft.start))"
            endLine = "DTEND:\(formatter.string(from: draft.end))"
        }

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Souvera//Souvera iOS//DE",
            "BEGIN:VEVENT",
            "UID:\(uid)",
            "DTSTAMP:\(formatter.string(from: Date()))",
            startLine,
            endLine,
            "SUMMARY:\(escape(draft.title))"
        ]
        if !draft.location.isEmpty {
            lines.append("LOCATION:\(escape(draft.location))")
        }
        if !draft.notes.isEmpty {
            lines.append("DESCRIPTION:\(escape(draft.notes))")
        }
        // Organizer setzen: ohne ORGANIZER verschickt Nextcloud Calendar
        // KEINE Einladungs-E-Mails und zeigt Teilnehmer nicht korrekt an.
        if !organizerEmail.isEmpty {
            lines.append("ORGANIZER;CN=\(escape(organizerName)):mailto:\(organizerEmail)")
        }
        for attendee in draft.attendees {
            // Volle Parameter wie Nextcloud Calendar Web, damit der Server
            // die iTIP-Einladung verschickt und der Teilnehmer mit Status
            // angezeigt wird.
            lines.append("ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(attendee)")
        }
        if let token = draft.talkRoomToken, !token.isEmpty {
            lines.append("X-SOUVERA-TALK-ROOM:\(escape(token))")
        }
        if let roomName = draft.talkRoomName, !roomName.isEmpty {
            lines.append("X-SOUVERA-TALK-ROOM-NAME:\(escape(roomName))")
        }
        for minutes in draft.reminders.sorted() {
            lines.append("BEGIN:VALARM")
            lines.append("ACTION:DISPLAY")
            lines.append("DESCRIPTION:\(escape(draft.title))")
            lines.append(minutes <= 0 ? "TRIGGER:PT0S" : "TRIGGER:-PT\(minutes)M")
            lines.append("END:VALARM")
        }
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseDateTime(_ value: String, tzid: String? = nil) -> Date? {
        // TZID-aware times (e.g. DTSTART;TZID=Europe/Berlin:20260822T110000).
        if let tzid, !value.hasSuffix("Z") {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = TimeZone(identifier: tzid) ?? .current
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let date = formatter.date(from: value) { return date }
        }
        // UTC times written with a trailing Z (basic format "20260824T080000Z"
        // as used by our own serializer and by sabre for some events):
        // parse explicitly, Foundation's ISO8601DateFormatter refuses the
        // basic (dash-less) format and the local fallback below would
        // otherwise misinterpret the value or return nil.
        if value.hasSuffix("Z") {
            let utc = DateFormatter()
            utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            utc.timeZone = TimeZone(secondsFromGMT: 0)
            utc.locale = Locale(identifier: "en_US_POSIX")
            if let date = utc.date(from: value) { return date }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: value) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: value) { return date }
        }
        let cleaned = value.replacingOccurrences(of: "Z", with: "+00:00")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: cleaned) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: cleaned) { return date }
        // Floating local time without zone information: interpret in the
        // device timezone.
        let local = DateFormatter()
        local.dateFormat = "yyyyMMdd'T'HHmmss"
        local.timeZone = .current
        local.locale = Locale(identifier: "en_US_POSIX")
        return local.date(from: value)
    }

    private static func extractTzid(_ rawKey: String) -> String? {
        guard let range = rawKey.range(of: "TZID=", options: .caseInsensitive) else { return nil }
        var tzid = String(rawKey[range.upperBound...])
        if tzid.hasPrefix("\""), tzid.hasSuffix("\"") {
            tzid = String(tzid.dropFirst().dropLast())
        }
        return tzid.isEmpty ? nil : tzid
    }

    /// Parses an RFC 5545 duration (e.g. PT30M, PT1H, P1D) into seconds.
    private static func parseDuration(_ value: String) -> TimeInterval? {
        let pattern = #"^([+-])?P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) else { return nil }
        func group(_ i: Int) -> Double {
            guard let r = Range(match.range(at: i), in: value) else { return 0 }
            return Double(value[r]) ?? 0
        }
        var sign: Double = 1
        if let r = Range(match.range(at: 1), in: value), value[r] == "-" {
            sign = -1
        }
        return sign * (group(2) * 86400 + group(3) * 3600 + group(4) * 60 + group(5))
    }

    /// Parses a VALARM TRIGGER like "-PT15M", "-PT1H" or "PT0S" into minutes.
    private static func parseTriggerMinutes(_ value: String) -> Int? {
        let text = value.trimmingCharacters(in: .whitespaces)
        let negative = text.hasPrefix("-")
        var body = text
        if body.hasPrefix("-") || body.hasPrefix("+") {
            body = String(body.dropFirst())
        }
        guard body.hasPrefix("P") else { return nil }
        var rest = String(body.dropFirst())
        var minutes = 0
        var inTimePart = false
        var current = ""
        func flush(_ token: String) {
            guard let number = Int(token.dropLast()) else { return }
            switch token.last {
            case "D": minutes += number * 24 * 60
            case "H": minutes += number * 60
            case "M": minutes += number
            case "S": minutes += number > 0 ? max(1, Int(ceil(Double(number) / 60.0))) : 0
            default: break
            }
        }
        for character in rest {
            if character == "T" {
                inTimePart = true
                continue
            }
            if character.isNumber {
                current.append(character)
            } else {
                current.append(character)
                flush(current)
                current = ""
            }
        }
        if !current.isEmpty { flush(current) }
        // "-PT15M" bedeutet 15 Minuten VOR dem Termin - unser Modell zählt
        // positive Minuten "vorher"; Nach-Termin-Trigger werden auf 0 geklemmt.
        let beforeMinutes = negative ? minutes : -minutes
        return max(0, beforeMinutes)
    }

    private static func parseDateOnly(_ value: String) -> Date? {
        // All-day dates have no timezone; keep them on that calendar day in
        // the DEVICE timezone (a GMT conversion could shift them to the
        // previous day on negative-offset timezones).
        let text = String(value.prefix(8))
        guard text.count == 8,
              let year = Int(text.prefix(4)),
              let month = Int(text.dropFirst(4).prefix(2)),
              let day = Int(text.suffix(2)) else { return nil }
        var components = DateComponents()
        components.calendar = Calendar.current
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        return Calendar.current.date(from: components)
    }
}
