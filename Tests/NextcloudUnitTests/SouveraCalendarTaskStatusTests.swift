// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 24.11. (Tasks): Unit-Tests fuer VTODO-Parsing (STATUS/COMPLETED/
// PERCENT-COMPLETE) und die Abhaken-Helfer completeTodo/uncompleteTodo.

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera calendar task status")
struct SouveraCalendarTaskStatusTests {

    private func parseVTODO(_ extraLines: String) -> [CalendarEventModel] {
        let ics = """
        BEGIN:VCALENDAR\r
        BEGIN:VTODO\r
        UID:task-uid\r
        SUMMARY:Testaufgabe\r
        \(extraLines)\r
        END:VTODO\r
        END:VCALENDAR
        """
        return ICSParser.parseEvents(ics, calendarHref: "/remote.php/dav/calendars/u/tasks/",
                                     href: "task.ics", etag: nil)
    }

    @Test("Open task (STATUS:NEEDS-ACTION) is not completed")
    func openTaskNotCompleted() {
        let events = parseVTODO("DUE:20260917T130000Z\rSTATUS:NEEDS-ACTION")
        #expect(events.count == 1)
        #expect(events.first?.isCompleted == false)
        #expect(events.first?.taskStatus == "NEEDS-ACTION")
    }

    @Test("STATUS:COMPLETED marks the task completed")
    func completedByStatus() {
        let events = parseVTODO("DUE:20260917T130000Z\rSTATUS:COMPLETED")
        #expect(events.first?.isCompleted == true)
    }

    @Test("COMPLETED timestamp marks the task completed")
    func completedByStamp() {
        let events = parseVTODO("DUE:20260917T130000Z\rCOMPLETED:20260917T120000Z")
        #expect(events.first?.isCompleted == true)
    }

    @Test("PERCENT-COMPLETE:100 marks the task completed")
    func completedByPercent() {
        let events = parseVTODO("DUE:20260917T130000Z\rPERCENT-COMPLETE:100")
        #expect(events.first?.isCompleted == true)
    }

    @Test("Undated tasks are kept and anchored to today")
    func undatedTaskKept() {
        let events = parseVTODO("STATUS:NEEDS-ACTION")
        #expect(events.count == 1)
        let start = events.first?.start ?? Date.distantPast
        #expect(Calendar.current.isDateInToday(start))
    }

    @Test("completeTodo writes STATUS/COMPLETED/PERCENT-COMPLETE")
    func completeWritesStatusLines() {
        let entry = ICSParser.completeTodo(rawICS)
        let parsed = ICSParser.parseEvents(entry, calendarHref: "/x/tasks/", href: "task.ics", etag: nil)
        #expect(parsed.first?.isCompleted == true)
        let lines = entry.components(separatedBy: "\r\n")
        #expect(lines.contains { $0.uppercased().hasPrefix("STATUS:COMPLETED") })
        #expect(lines.contains { $0.uppercased().hasPrefix("COMPLETED:") })
        #expect(lines.contains { $0.uppercased().hasPrefix("PERCENT-COMPLETE:100") })
    }

    @Test("uncompleteTodo restores NEEDS-ACTION and drops COMPLETED")
    func uncompleteRestoresNeedsAction() {
        let completed = ICSParser.completeTodo(rawICS)
        let reopened = ICSParser.uncompleteTodo(completed)
        let parsed = ICSParser.parseEvents(reopened, calendarHref: "/x/tasks/", href: "task.ics", etag: nil)
        #expect(parsed.first?.isCompleted == false)
        let lines = reopened.components(separatedBy: "\r\n")
        #expect(lines.contains { $0.uppercased().hasPrefix("STATUS:NEEDS-ACTION") })
        #expect(!lines.contains { $0.uppercased().hasPrefix("COMPLETED:") })
        #expect(!lines.contains { $0.uppercased().hasPrefix("PERCENT-COMPLETE") })
    }

    /// Minimaler VTODO-Rohstand (wie vom NC-Server).
    private var rawICS: String {
        """
        BEGIN:VCALENDAR\r
        BEGIN:VTODO\r
        UID:task-uid\r
        SUMMARY:Testaufgabe\r
        DUE:20260917T130000Z\r
        STATUS:NEEDS-ACTION\r
        END:VTODO\r
        END:VCALENDAR
        """
    }
}
