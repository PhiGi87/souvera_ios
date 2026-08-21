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
}

enum ICSParser {

    static func parseEvents(_ ics: String, calendarHref: String, href: String, etag: String?) -> [CalendarEventModel] {
        var events: [CalendarEventModel] = []
        let blocks = ics.components(separatedBy: "BEGIN:VEVENT")
        for block in blocks.dropFirst() {
            let body = block.components(separatedBy: "END:VEVENT").first ?? block
            var uid = ""
            var title = ""
            var location: String?
            var notes: String?
            var attendees: [String] = []
            var talkRoomToken: String?
            var talkRoomName: String?
            var start: Date?
            var end: Date?
            var allDay = false
            var startDay: Date?
            var endDay: Date?

            for rawLine in body.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let keyPart = String(line[line.startIndex..<colon]).uppercased()
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
                        start = parseDateTime(value)
                    }
                } else if keyPart.hasPrefix("DTEND") {
                    if keyPart.contains("VALUE=DATE") {
                        endDay = parseDateOnly(value)
                    } else {
                        end = parseDateTime(value)
                    }
                }
            }

            var resolvedStart = start ?? startDay ?? Date.distantPast
            var resolvedEnd = end ?? endDay ?? resolvedStart.addingTimeInterval(3600)
            if allDay, endDay == nil {
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
                etag: etag
            ))
        }
        return events
    }

    /// Serializes a draft into an iCalendar VEVENT (all UTC).
    static func buildICS(_ draft: EventDraft) -> String {
        let uid = draft.uid.isEmpty ? UUID().uuidString.lowercased() : draft.uid
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        let startLine: String
        let endLine: String
        if draft.allDay {
            startLine = "DTSTART;VALUE=DATE:\(dateFormatter.string(from: draft.start))"
            endLine = "DTEND;VALUE=DATE:\(dateFormatter.string(from: draft.end.addingTimeInterval(86400)))"
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
        for attendee in draft.attendees {
            lines.append("ATTENDEE:mailto:\(attendee)")
        }
        if let token = draft.talkRoomToken, !token.isEmpty {
            lines.append("X-SOUVERA-TALK-ROOM:\(escape(token))")
        }
        if let roomName = draft.talkRoomName, !roomName.isEmpty {
            lines.append("X-SOUVERA-TALK-ROOM-NAME:\(escape(roomName))")
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

    private static func parseDateTime(_ value: String) -> Date? {
        let cleaned = value.replacingOccurrences(of: "Z", with: "+00:00")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: cleaned) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: cleaned)
    }

    private static func parseDateOnly(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: String(value.prefix(8)))
    }
}
