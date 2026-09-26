
@Suite("Souvera calendar task duration")
struct SouveraCalendarTaskDurationTests {

    private func parseVTODO(_ due: String) -> [CalendarEventModel] {
        let ics = """
        BEGIN:VCALENDAR\r
        BEGIN:VTODO\r
        UID:deck-test-uid\r
        SUMMARY:Deck Aufgabe\r
        DUE:\(due)\r
        END:VTODO\r
        END:VCALENDAR
        """
        return ICSParser.parseEvents(ics, calendarHref: "/remote.php/dav/calendars/u/deck/", href: "deck-test", etag: nil)
    }

    @Test("Deck tasks (VTODO with due date only) last 15 minutes")
    func deckTaskFifteenMinutes() {
        let events = parseVTODO("20260917T130000Z")
        #expect(events.count == 1)
        guard let event = events.first else { return }
        let duration = event.end.timeIntervalSince(event.start)
        #expect(duration == 900)
    }

    @Test("Regular events without end keep one hour")
    func eventOneHour() {
        let ics = """
        BEGIN:VCALENDAR\r
        BEGIN:VEVENT\r
        UID:normal-event\r
        SUMMARY:Normaler Termin\r
        DTSTART:20260917T130000Z\r
        END:VEVENT\r
        END:VCALENDAR
        """
        let events = ICSParser.parseEvents(ics, calendarHref: "/x/personal/", href: "normal", etag: nil)
        #expect(events.count == 1)
        guard let event = events.first else { return }
        #expect(event.end.timeIntervalSince(event.start) == 3600)
    }
}
