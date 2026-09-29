// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import Nextcloud

@Suite("Souvera share target limits")
struct SouveraShareTargetLimitsTests {

    private let mb: Int64 = 1024 * 1024

    @Test("Per-target limits match the product rules")
    func limits() {
        #expect(SouveraPendingShareStore.talkLimitBytes == 10 * mb)
        #expect(SouveraPendingShareStore.mailLimitBytes == 20 * mb)
        #expect(SouveraPendingShareStore.filesLimitBytes == 100 * mb)
    }

    @Test("File size is allowed per target")
    func allowsPerTarget() {
        #expect(SouveraPendingShareStore.allows(sizeBytes: 9 * mb, for: SouveraPendingShareStore.actionTalk))
        #expect(!SouveraPendingShareStore.allows(sizeBytes: 11 * mb, for: SouveraPendingShareStore.actionTalk))
        #expect(SouveraPendingShareStore.allows(sizeBytes: 19 * mb, for: SouveraPendingShareStore.actionMail))
        #expect(!SouveraPendingShareStore.allows(sizeBytes: 21 * mb, for: SouveraPendingShareStore.actionMail))
        #expect(SouveraPendingShareStore.allows(sizeBytes: 99 * mb, for: SouveraPendingShareStore.actionFiles))
        #expect(!SouveraPendingShareStore.allows(sizeBytes: 101 * mb, for: SouveraPendingShareStore.actionFiles))
        // Eine 15-MB-Datei: Mail und Dateien ja, Chat nein.
        #expect(SouveraPendingShareStore.allows(sizeBytes: 15 * mb, for: SouveraPendingShareStore.actionMail))
        #expect(SouveraPendingShareStore.allows(sizeBytes: 15 * mb, for: SouveraPendingShareStore.actionFiles))
        #expect(!SouveraPendingShareStore.allows(sizeBytes: 15 * mb, for: SouveraPendingShareStore.actionTalk))
    }

    @Test("allowsAll rejects shares where one file exceeds the target")
    func allowsAll() {
        let small = SouveraPendingShareStore.SharedFile(name: "a.txt", mimeType: "text/plain",
                                                        path: "/tmp/a", size: 1 * mb, tooLarge: false)
        let big = SouveraPendingShareStore.SharedFile(name: "b.mp4", mimeType: "video/mp4",
                                                      path: "", size: 38 * mb, tooLarge: false)
        #expect(SouveraPendingShareStore.allowsAll([small], for: SouveraPendingShareStore.actionTalk))
        #expect(!SouveraPendingShareStore.allowsAll([small, big], for: SouveraPendingShareStore.actionTalk))
        #expect(SouveraPendingShareStore.allowsAll([small, big], for: SouveraPendingShareStore.actionMail))
        #expect(SouveraPendingShareStore.firstOversize([small, big], for: SouveraPendingShareStore.actionTalk)?.name == "b.mp4")
        #expect(SouveraPendingShareStore.firstOversize([small], for: SouveraPendingShareStore.actionTalk) == nil)
    }

    @Test("Legacy tooLarge flag decodes from old payloads")
    func legacyDecode() throws {
        let json = #"{"name":"old.txt","mimeType":"text/plain","path":"","size":20971520}"#
        let file = try JSONDecoder().decode(SouveraPendingShareStore.SharedFile.self, from: Data(json.utf8))
        #expect(file.tooLarge == false)
    }
}
