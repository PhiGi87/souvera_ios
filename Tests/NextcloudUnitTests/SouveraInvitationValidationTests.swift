// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera invitation validation")
struct SouveraInvitationValidationTests {

    @Test("Only REQUEST and CANCEL iTIP methods are invitations")
    func acceptableMethods() {
        #expect(SouveraInvitationCenter.isAcceptableInvitationMethod("REQUEST"))
        #expect(SouveraInvitationCenter.isAcceptableInvitationMethod("request"))
        #expect(SouveraInvitationCenter.isAcceptableInvitationMethod("CANCEL"))
        #expect(SouveraInvitationCenter.isAcceptableInvitationMethod(""))
        // REPLY war die Ursache der „Fake-Einladungen" (kein Titel/Datum).
        #expect(!SouveraInvitationCenter.isAcceptableInvitationMethod("REPLY"))
        #expect(!SouveraInvitationCenter.isAcceptableInvitationMethod("COUNTER"))
        #expect(!SouveraInvitationCenter.isAcceptableInvitationMethod("REFRESH"))
        #expect(!SouveraInvitationCenter.isAcceptableInvitationMethod("DECLINECOUNTER"))
    }

    @Test("Unusable parsed events are rejected (fake invitation guards)")
    func usableEvents() {
        let real = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SouveraInvitationCenter.isUsableInvitationEvent(uid: "abc", start: real, title: "Termin"))
        // Leerer Titel (iTIP-REPLY-VEVENT): nicht brauchbar.
        #expect(!SouveraInvitationCenter.isUsableInvitationEvent(uid: "abc", start: real, title: "   "))
        // Fehlender/epoch Start (01.01.1): nicht brauchbar.
        #expect(!SouveraInvitationCenter.isUsableInvitationEvent(uid: "abc", start: Date.distantPast, title: "Termin"))
        #expect(!SouveraInvitationCenter.isUsableInvitationEvent(uid: "abc", start: nil, title: "Termin"))
        // Leere UID: nicht brauchbar.
        #expect(!SouveraInvitationCenter.isUsableInvitationEvent(uid: "", start: real, title: "Termin"))
    }
}
