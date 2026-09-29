// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera invitation candidate filter")
struct SouveraInvitationCandidateTests {

    @Test("Subject prefixes mark a candidate")
    func subjectHints() {
        #expect(SouveraInvitationCenter.isInvitationCandidate(subject: "Einladung: Testtermin", attachments: []))
        #expect(SouveraInvitationCenter.isInvitationCandidate(subject: "Invitation: Weekly", attachments: []))
        #expect(SouveraInvitationCenter.isInvitationCandidate(subject: "Invitation : Weekly", attachments: []))
        #expect(SouveraInvitationCenter.isInvitationCandidate(subject: "Abgesagt: Testtermin", attachments: []))
        #expect(SouveraInvitationCenter.isInvitationCandidate(subject: "Cancelled: Meeting", attachments: []))
        #expect(!SouveraInvitationCenter.isInvitationCandidate(subject: "Einladung zum Geburtstag", attachments: []))
        #expect(!SouveraInvitationCenter.isInvitationCandidate(subject: "Re: Einladung: Testtermin", attachments: []))
    }

    @Test("Calendar or ics attachments mark a candidate")
    func attachmentHints() {
        #expect(SouveraInvitationCenter.isInvitationCandidate(
            subject: "Termin",
            attachments: [["type": "text/calendar", "blobId": "b1"]]))
        #expect(SouveraInvitationCenter.isInvitationCandidate(
            subject: "Termin",
            attachments: [["type": "application/ics", "name": "invite.ics"]]))
        #expect(!SouveraInvitationCenter.isInvitationCandidate(
            subject: "Termin",
            attachments: [["type": "application/pdf", "name": "doc.pdf"]]))
        #expect(!SouveraInvitationCenter.isInvitationCandidate(subject: "Termin", attachments: []))
    }

    @Test("Case-insensitive matching")
    func caseInsensitive() {
        #expect(SouveraInvitationCenter.isInvitationCandidate(
            subject: "EINLADUNG: Termin",
            attachments: [["type": "TEXT/CALENDAR"]]))
    }
}
