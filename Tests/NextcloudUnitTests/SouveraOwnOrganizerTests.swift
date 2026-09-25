// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera own organizer detection")
struct SouveraOwnOrganizerTests {

    private let own: Set<String> = ["a.raatz@host-on.de", "admins@host-on.de", "andre.raatz@raatz-net.de"]

    @Test("Organizer matching an own address is an own appointment")
    func ownAddresses() {
        #expect(CalendarViewModel.isOwnOrganizer(organizerEmail: "a.raatz@host-on.de", ownAddresses: own))
        // Alias/andere eigene Identitaet.
        #expect(CalendarViewModel.isOwnOrganizer(organizerEmail: "admins@host-on.de", ownAddresses: own))
        #expect(CalendarViewModel.isOwnOrganizer(organizerEmail: "andre.raatz@raatz-net.de", ownAddresses: own))
        // Gross-/Kleinschreibung + Leerzeichen.
        #expect(CalendarViewModel.isOwnOrganizer(organizerEmail: " A.Raatz@Host-On.DE ", ownAddresses: own))
    }

    @Test("Empty organizer counts as own (locally created appointment)")
    func emptyOrganizer() {
        #expect(CalendarViewModel.isOwnOrganizer(organizerEmail: "", ownAddresses: own))
        #expect(CalendarViewModel.isOwnOrganizer(organizerEmail: "   ", ownAddresses: own))
    }

    @Test("Foreign organizer is not an own appointment")
    func foreignOrganizer() {
        #expect(!CalendarViewModel.isOwnOrganizer(organizerEmail: "p.grassegger@host-on.de", ownAddresses: own))
        #expect(!CalendarViewModel.isOwnOrganizer(organizerEmail: "someone@example.com", ownAddresses: own))
    }
}
