// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera mail mutation rollback")
struct SouveraMailMutationTests {

    @Test("Email/set failures are extracted from notDestroyed/notUpdated")
    func failuresParsing() {
        // Log-Beweis (nur-lesender freigegebener Ordner):
        // {"notDestroyed":{"lv2iaac0pc":{"type":"forbidden","description":"You are not allowed to delete this message."}}}
        let resp: [String: Any] = [
            "oldState": "s2ptqm",
            "newState": "s2ptqm",
            "notDestroyed": [
                "lv2iaac0pc": ["type": "forbidden", "description": "You are not allowed to delete this message."]
            ] as [String: Any]
        ]
        let failures = JmapApi.emailSetFailures(resp)
        #expect(failures.count == 1)
        #expect(failures["lv2iaac0pc"] == "forbidden")
    }

    @Test("notUpdated entries are extracted as well")
    func notUpdatedParsing() {
        let resp: [String: Any] = [
            "notUpdated": [
                "abc123": ["type": "forbidden"]
            ] as [String: Any]
        ]
        let failures = JmapApi.emailSetFailures(resp)
        #expect(failures["abc123"] == "forbidden")
    }

    @Test("A clean response has no failures")
    func cleanResponse() {
        let resp: [String: Any] = [
            "oldState": "a", "newState": "b",
            "destroyed": ["lv2qaac0pe"],
            "updated": ["x": [:]]
        ]
        #expect(JmapApi.emailSetFailures(resp).isEmpty)
    }
}
