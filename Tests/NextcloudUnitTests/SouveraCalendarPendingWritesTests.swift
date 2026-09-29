// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera calendar pending writes")
struct SouveraCalendarPendingWritesTests {

    private func makeWrite(kind: SouveraCalendarPendingWrites.Kind,
                           href: String) -> SouveraCalendarPendingWrites.PendingWrite {
        SouveraCalendarPendingWrites.PendingWrite(id: UUID().uuidString,
                                                  kind: kind,
                                                  calendarHref: "/cal/personal/",
                                                  href: href,
                                                  uid: "uid-1",
                                                  ics: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n",
                                                  attempts: 0,
                                                  createdAt: Date())
    }

    @Test("Backoff grows and is capped")
    func backoff() {
        #expect(SouveraCalendarPendingWrites.backoffSeconds(attempts: 0) == 2)
        #expect(SouveraCalendarPendingWrites.backoffSeconds(attempts: 1) == 5)
        #expect(SouveraCalendarPendingWrites.backoffSeconds(attempts: 2) == 10)
        #expect(SouveraCalendarPendingWrites.backoffSeconds(attempts: 9) == 10)
    }

    @Test("Queue round-trips through JSON")
    func roundTrip() throws {
        let writes = [makeWrite(kind: .update, href: "abc.ics"),
                      makeWrite(kind: .delete, href: "def.ics")]
        let data = try JSONEncoder().encode(writes)
        let decoded = try JSONDecoder().decode([SouveraCalendarPendingWrites.PendingWrite].self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded[0].kind == .update)
        #expect(decoded[1].kind == .delete)
        #expect(decoded[0].href == "abc.ics")
        #expect(decoded[1].ics.contains("VCALENDAR"))
    }
}
