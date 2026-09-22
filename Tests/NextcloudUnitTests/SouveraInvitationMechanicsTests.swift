// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera invitation mechanics")
struct SouveraInvitationMechanicsTests {

    @Test("Exact UID match does not match a longer UID")
    func exactUIDMatchRejectsPrefix() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:abcd-1234
        SUMMARY:Test
        END:VEVENT
        END:VCALENDAR
        """

        #expect(SouveraInvitationCenter.icsHasUID(ics, "abcd-1234"))
        #expect(!SouveraInvitationCenter.icsHasUID(ics, "abc"))
    }

    @Test("UID match is case-insensitive and folding-tolerant")
    func uidMatchCaseAndFolding() {
        // RFC-5545-Folding: UID ist ueber zwei Zeilen gebrochen.
        let ics = "BEGIN:VEVENT\r\nUID:ab\r\n cd\r\nSUMMARY:x\r\nEND:VEVENT"

        #expect(SouveraInvitationCenter.icsHasUID(ics, "abcd"))
    }

    @Test("Cancellation subject prefixes are stripped")
    func cancelSubjectPrefixStripped() {
        #expect(SouveraMailInvitation.strippedSubjectPrefix("Abgesagt: Test-Termin") == "Test-Termin")
        #expect(SouveraMailInvitation.strippedSubjectPrefix("Cancelled: Meeting") == "Meeting")
        #expect(SouveraMailInvitation.strippedSubjectPrefix("Normal Subject") == "Normal Subject")
    }

    @Test("Pending removals persist and clear by UID")
    func pendingRemovalPersistence() {
        let uid = "unit-test-\(UUID().uuidString)"
        SouveraInvitationCenter.addPendingRemoval(uid)
        #expect(SouveraInvitationCenter.pendingRemovals().contains(uid.lowercased()))

        SouveraInvitationCenter.removePendingRemoval(uid)
        #expect(!SouveraInvitationCenter.pendingRemovals().contains(uid.lowercased()))
    }
}

@Suite("Souvera calendar categories")
struct SouveraCalendarCategoryTests {

    private func calendar(_ href: String) -> CalDavCalendar {
        CalDavCalendar(href: href, displayName: "Test", color: nil, canWrite: true)
    }

    @Test("Calendars are grouped into own, shared and deck")
    func categoryClassification() {
        #expect(calendar("/remote.php/dav/calendars/u/personal/").category == .own)
        #expect(calendar("/remote.php/dav/calendars/u/contact_birthdays/").category == .own)
        #expect(calendar("/remote.php/dav/calendars/u/shared_calendar_shared_by_other/").category == .shared)
        #expect(calendar("/remote.php/dav/calendars/u/app-generated--deck--board-5/").category == .deck)
        #expect(calendar("/remote.php/dav/calendars/u/DECK_Board/").category == .deck)
    }
}

@Suite("Souvera VALARM rewriting")
struct SouveraValarmRewriteTests {

    /// ICS mit RFC-5545-gefalteten Zeilen (so liefert der Server sie).
    private let foldedICS = """
    BEGIN:VCALENDAR\r
    BEGIN:VEVENT\r
    UID:A660C340-23FC-4DE9-91F2-58B825052A42\r
    SUMMARY:Test-Schulung Einladung\r
    DESCRIPTION:eine sehr lange Beschreibung die der Server nach 75 Oktetten umbricht und mit Leerzeichen fortsetzt damit sie gueltig bleibt\r
    ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:a.raatz@host-on.de\r
    BEGIN:VALARM\r
    TRIGGER:-PT15M\r
    ACTION:DISPLAY\r
    DESCRIPTION:Erinnerung\r
    END:VALARM\r
    END:VEVENT\r
    END:VCALENDAR
    """

    @Test("Rewriting keeps folded lines foldable (no orphan continuation)")
    func rewriteKeepsFoldingValid() {
        // Zuerst server-typisch falten, damit die Eingabe garantiert gefaltet ist.
        let lines = ICSParser.unfold(foldedICS).components(separatedBy: "\n")
        let folded = CalendarViewModel.foldICS(lines)
        #expect(folded.contains("\r\n "))

        let rewritten = CalendarViewModel.setValarms(ics: folded, minutes: [30])
        for line in rewritten.components(separatedBy: "\r\n") where !line.isEmpty {
            // Jede physische Zeile ist entweder eine Inhaltszeile (mit ':')
            // oder eine korrekte Fortsetzung (fuehrendes Leerzeichen).
            #expect(line.contains(":") || line.hasPrefix(" ") || line.hasPrefix("\t"))
        }
        // Langwert bleibt nach dem Entfalten vollstaendig erhalten.
        let unfoldedOut = ICSParser.unfold(rewritten)
        #expect(unfoldedOut.contains("fortsetzt damit sie gueltig bleibt"))
        #expect(unfoldedOut.contains("mailto:a.raatz@host-on.de"))
    }

    @Test("Old VALARMs removed, new ones inserted before END:VEVENT")
    func valarmsReplaced() {
        let rewritten = CalendarViewModel.setValarms(ics: foldedICS, minutes: [10, 60])
        let unfolded = ICSParser.unfold(rewritten)
        // Alte 15-Minuten-Erinnerung ist weg, neue sind da.
        #expect(!unfolded.contains("TRIGGER:-PT15M"))
        #expect(unfolded.contains("TRIGGER:-PT10M"))
        #expect(unfolded.contains("TRIGGER:-PT60M"))
        // Genau zwei VALARM-Bloecke und diese VOR END:VEVENT.
        let alarmCount = unfolded.components(separatedBy: "BEGIN:VALARM").count - 1
        #expect(alarmCount == 2)
        let endEvent = unfolded.range(of: "END:VEVENT")
        let lastAlarm = unfolded.range(of: "TRIGGER:-PT60M")
        #expect(endEvent != nil && lastAlarm != nil)
        if let endEvent, let lastAlarm {
            #expect(lastAlarm.lowerBound < endEvent.lowerBound)
        }
    }

    @Test("Empty reminder list strips all VALARMs")
    func emptyListStripsAlarms() {
        let rewritten = CalendarViewModel.setValarms(ics: foldedICS, minutes: [])
        #expect(!ICSParser.unfold(rewritten).contains("BEGIN:VALARM"))
        #expect(ICSParser.unfold(rewritten).contains("UID:A660C340-23FC-4DE9-91F2-58B825052A42"))
    }

    @Test("Concrete partstat detection")
    func concretePartstat() {
        #expect(CalendarViewModel.isConcretePartstat("ACCEPTED"))
        #expect(CalendarViewModel.isConcretePartstat("tentative"))
        #expect(CalendarViewModel.isConcretePartstat("declined"))
        #expect(!CalendarViewModel.isConcretePartstat("needs-action"))
        #expect(!CalendarViewModel.isConcretePartstat(""))
    }
}
