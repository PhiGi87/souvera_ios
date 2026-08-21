// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Offline cache for the mail module: compressed JSON snapshots of the
// mailbox list and the latest message list per folder, stored in Application
// Support so the system does not purge them. Snapshots are small (raw JMAP
// JSON, gzip-compressed, capped at the latest 100 messages per folder).

import Compression
import Foundation

enum MailCache {
    private static let rootDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("souvera-mail-cache", isDirectory: true)
    }()

    private static func fileURL(account: String, mailboxId: String) -> URL {
        let safeAccount = account.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let safeMailbox = mailboxId.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return rootDirectory.appendingPathComponent("\(safeAccount)_\(safeMailbox).json.gz")
    }

    struct MessageSnapshot {
        let emails: [[String: Any]]
        let queryState: String?
    }

    static func saveMessages(account: String, mailboxId: String, emails: [[String: Any]], queryState: String?) {
        let payload: [String: Any] = [
            "emails": emails,
            "queryState": queryState ?? NSNull()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let compressed = compress(data) else { return }
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? compressed.write(to: fileURL(account: account, mailboxId: mailboxId), options: .atomic)
    }

    static func loadMessages(account: String, mailboxId: String) -> MessageSnapshot? {
        guard let compressed = try? Data(contentsOf: fileURL(account: account, mailboxId: mailboxId)),
              let data = decompress(compressed),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let emails = json["emails"] as? [[String: Any]] else { return nil }
        return MessageSnapshot(emails: emails, queryState: json["queryState"] as? String)
    }

    static func remove(account: String, mailboxId: String) {
        try? FileManager.default.removeItem(at: fileURL(account: account, mailboxId: mailboxId))
    }

    // MARK: - Mailbox list snapshot

    private static func mailboxesURL(account: String) -> URL {
        let safeAccount = account.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return rootDirectory.appendingPathComponent("\(safeAccount)_mailboxes.json.gz")
    }

    static func saveMailboxes(account: String, boxes: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: boxes),
              let compressed = compress(data) else { return }
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? compressed.write(to: mailboxesURL(account: account), options: .atomic)
    }

    static func loadMailboxes(account: String) -> [[String: Any]]? {
        guard let compressed = try? Data(contentsOf: mailboxesURL(account: account)),
              let data = decompress(compressed),
              let boxes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return boxes
    }

    // MARK: - zlib compression (Compression framework)

    private static func compress(_ data: Data) -> Data? {
        let sourceSize = data.count
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: sourceSize + 128)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                destination, sourceSize + 128,
                base, sourceSize,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }

    private static func decompress(_ data: Data) -> Data? {
        var capacity = max(data.count * 8, 64 * 1024)
        for _ in 0..<5 {
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { destination.deallocate() }
            let written = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destination, capacity,
                    base, data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
            if written > 0 && written < capacity {
                return Data(bytes: destination, count: written)
            }
            capacity *= 4
        }
        return nil
    }
}
