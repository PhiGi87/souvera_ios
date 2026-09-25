// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera link ringing watcher")
struct LinkRingingWatcherTests {

    private func participant(actorId: String, inCall: Int, type: String = "users") -> LinkParticipant {
        LinkParticipant(attendeeId: 1, actorType: type, actorId: actorId,
                        displayName: actorId, participantType: 1,
                        inCall: inCall, lastPing: 0, status: nil)
    }

    @Test("Own user in call on another device is detected")
    func answeredElsewhere() {
        // Beim Klingeln hat dieses Geraet NICHT gejoint - ein inCall des
        // eigenen Actors kann nur vom anderen Geraet stammen.
        let participants = [
            participant(actorId: "caller@x", inCall: 5),
            participant(actorId: "a.raatz", inCall: 5),
        ]
        #expect(LinkRingingWatcher.evaluate(participants: participants, ownUserId: "a.raatz").answeredElsewhere)
    }

    @Test("Still ringing is not detected as answered")
    func stillRinging() {
        let participants = [
            participant(actorId: "caller@x", inCall: 5),
            participant(actorId: "a.raatz", inCall: 0),
        ]
        #expect(!LinkRingingWatcher.evaluate(participants: participants, ownUserId: "a.raatz").answeredElsewhere)
    }

    @Test("Other users in call do not trigger the detection")
    func otherUsers() {
        let participants = [
            participant(actorId: "caller@x", inCall: 5),
            participant(actorId: "someone.else", inCall: 5),
        ]
        #expect(!LinkRingingWatcher.evaluate(participants: participants, ownUserId: "a.raatz").answeredElsewhere)
    }

    @Test("Guests and deleted actors are ignored")
    func guestsIgnored() {
        let participants = [
            participant(actorId: "a.raatz", inCall: 5, type: "guests"),
            participant(actorId: "a.raatz", inCall: 5, type: "deleted_users"),
        ]
        #expect(!LinkRingingWatcher.evaluate(participants: participants, ownUserId: "a.raatz").answeredElsewhere)
    }

    @Test("Empty own user never matches")
    func emptyOwnUser() {
        let participants = [participant(actorId: "", inCall: 5)]
        #expect(!LinkRingingWatcher.evaluate(participants: participants, ownUserId: "").answeredElsewhere)
    }
}
