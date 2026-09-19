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
