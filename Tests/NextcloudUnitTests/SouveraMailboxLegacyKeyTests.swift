// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera mailbox legacy cache keys")
struct SouveraMailboxLegacyKeyTests {

    @Test("Mailbox ids without account prefix are legacy shadow keys")
    func legacyDetection() {
        #expect(MailViewModel.mailboxIdIsLegacyEmptyAccount("|Inbox"))
        #expect(MailViewModel.mailboxIdIsLegacyEmptyAccount("|Sent Items"))
        #expect(!MailViewModel.mailboxIdIsLegacyEmptyAccount("a.raatz@host-on.de https://host-on.souvera.work|Inbox"))
        #expect(!MailViewModel.mailboxIdIsLegacyEmptyAccount(""))
        #expect(!MailViewModel.mailboxIdIsLegacyEmptyAccount("Inbox"))
    }

    @Test("makeId always contains the account prefix for real accounts")
    func makeIdShape() {
        let id = Mailbox.makeId(account: "user@host", path: "Inbox")
        #expect(!MailViewModel.mailboxIdIsLegacyEmptyAccount(id))
        #expect(id == "user@host|Inbox")
    }
}
