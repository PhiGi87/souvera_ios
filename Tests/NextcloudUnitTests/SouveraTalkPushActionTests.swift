// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera talk push actions")
struct SouveraTalkPushActionTests {

    @Test("Latest message id is the maximum id of the page")
    func latestMessageId() {
        let messages = [
            linkMessage(id: 41),
            linkMessage(id: 7),
            linkMessage(id: 128)
        ]
        #expect(SouveraTalkPushActionRunner.latestMessageId(in: messages) == 128)
    }

    @Test("Latest message id of an empty page is nil")
    func latestMessageIdEmpty() {
        #expect(SouveraTalkPushActionRunner.latestMessageId(in: []) == nil)
    }

    @Test("Latest message id handles negative offline queue ids")
    func latestMessageIdOfflineQueue() {
        // Offline-Warteschlange nutzt NEGATIVE Ids (kollisionsfrei zu
        // Server-Ids); der Server-Teil muss trotzdem die höchste liefern.
        let messages = [
            linkMessage(id: -3),
            linkMessage(id: 12)
        ]
        #expect(SouveraTalkPushActionRunner.latestMessageId(in: messages) == 12)
    }

    private func linkMessage(id: Int64) -> LinkChatMessage {
        LinkChatMessage.makePending(id: id,
                                    token: "testroom",
                                    actorId: "actor-1",
                                    displayName: "Tester",
                                    timestamp: 0,
                                    text: "Hallo",
                                    replyParent: nil)
    }
}
