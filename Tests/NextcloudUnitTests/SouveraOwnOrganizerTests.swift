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

    @Test("Own address matching tolerates a bare account user id")
    func ownAddressMatching() {
        // Account-User ist eine bare User-ID: die volle Adresse matcht
        // trotzdem (Local-Part-Abgleich).
        #expect(CalendarViewModel.isOwnAddress("a.raatz@host-on.de",
                                               ownAddresses: own,
                                               accountUser: "a.raatz"))
        #expect(CalendarViewModel.isOwnAddress("mailto:a.raatz@host-on.de",
                                               ownAddresses: own,
                                               accountUser: "a.raatz"))
        #expect(CalendarViewModel.isOwnAddress("admins@host-on.de",
                                               ownAddresses: own,
                                               accountUser: "a.raatz"))
        // Fremde Adresse matcht nicht - auch nicht per Local-Part.
        #expect(!CalendarViewModel.isOwnAddress("jan@host-on.de",
                                                ownAddresses: own,
                                                accountUser: "a.raatz"))
        #expect(!CalendarViewModel.isOwnAddress("not-an-email",
                                                ownAddresses: own,
                                                accountUser: "a.raatz"))
    }
}
