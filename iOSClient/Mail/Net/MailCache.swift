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

    // MARK: - Body-Cache (IMAP-artig: Inhalte aller geladenen Mails)

    private static func bodyDirectory(account: String) -> URL {
        let safeAccount = account.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return rootDirectory.appendingPathComponent("bodies-\(safeAccount)", isDirectory: true)
    }

    private static func bodyURL(account: String, emailId: String) -> URL {
        let safeId = emailId.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return bodyDirectory(account: account).appendingPathComponent("\(safeId).json")
    }

    /// Speichert den aufbereiteten Body einer Mail (Text/HTML/Anhänge).
    static func saveBody(account: String, emailId: String, body: MessageBody) {
        let attachments: [[String: Any]] = body.attachments.map {
            [
                "name": $0.name,
                "sizeBytes": $0.sizeBytes,
                "mimeType": $0.mimeType,
                "blobId": $0.blobId ?? NSNull(),
                "partId": $0.partId ?? NSNull()
            ]
        }
        let payload: [String: Any] = [
            "plainText": body.plainText ?? NSNull(),
            "html": body.html ?? NSNull(),
            "attachments": attachments
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? FileManager.default.createDirectory(at: bodyDirectory(account: account), withIntermediateDirectories: true)
        try? data.write(to: bodyURL(account: account, emailId: emailId), options: .atomic)
    }

    /// Liefert den gecachten Body einer Mail (Offline-Lesen).
    static func loadBody(account: String, emailId: String) -> MessageBody? {
        guard let data = try? Data(contentsOf: bodyURL(account: account, emailId: emailId)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let attachments = (json["attachments"] as? [[String: Any]])?.compactMap { att -> AttachmentMeta? in
            guard let name = att["name"] as? String else { return nil }
            return AttachmentMeta(
                name: name,
                sizeBytes: att["sizeBytes"] as? Int64 ?? 0,
                mimeType: att["mimeType"] as? String ?? "application/octet-stream",
                blobId: att["blobId"] as? String,
                partId: att["partId"] as? String
            )
        } ?? []
        return MessageBody(
            plainText: json["plainText"] as? String,
            html: json["html"] as? String,
            attachments: attachments
        )
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

    // MARK: - Generic compressed JSON blobs (contacts, calendar, ...)

    static func saveJSON(_ object: Any, key: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let compressed = compress(data) else { return }
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? compressed.write(to: rootDirectory.appendingPathComponent("\(key).json.gz"), options: .atomic)
    }

    static func loadJSON(key: String) -> Any? {
        guard let compressed = try? Data(contentsOf: rootDirectory.appendingPathComponent("\(key).json.gz")),
              let data = decompress(compressed),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return json
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
