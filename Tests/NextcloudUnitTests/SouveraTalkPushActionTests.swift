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

    @Test("Newest notification is decided by the highest nid")
    func newestByNid() {
        let now = Date()
        let notes: [(nid: Int?, date: Date)] = [(7146, now.addingTimeInterval(-60)),
                                                (7150, now.addingTimeInterval(-30)),
                                                (7154, now)]
        #expect(SouveraTalkPushActionRunner.isNewestNotification(tappedNid: 7154, tappedDate: now, roomNotifications: notes))
        #expect(!SouveraTalkPushActionRunner.isNewestNotification(tappedNid: 7150, tappedDate: now.addingTimeInterval(-30), roomNotifications: notes))
    }

    @Test("Without nids the delivery date decides")
    func newestByDate() {
        let now = Date()
        let notes: [(nid: Int?, date: Date)] = [(nil, now.addingTimeInterval(-60)),
                                                (nil, now)]
        #expect(SouveraTalkPushActionRunner.isNewestNotification(tappedNid: nil, tappedDate: now, roomNotifications: notes))
        #expect(!SouveraTalkPushActionRunner.isNewestNotification(tappedNid: nil, tappedDate: now.addingTimeInterval(-60), roomNotifications: notes))
    }

    @Test("nid values parse from Int, NSNumber and String")
    func nidParsing() {
        #expect(SouveraTalkPushActionRunner.nidValue(7154) == 7154)
        #expect(SouveraTalkPushActionRunner.nidValue(NSNumber(value: 42)) == 42)
        #expect(SouveraTalkPushActionRunner.nidValue("99") == 99)
        #expect(SouveraTalkPushActionRunner.nidValue(nil) == nil)
        #expect(SouveraTalkPushActionRunner.nidValue("abc") == nil)
    }
}
