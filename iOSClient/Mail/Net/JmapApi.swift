// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from souvera_android mail/net/jmap/JmapApi.kt.
//
// High-level JMAP API that builds method-call arguments and delegates to
// JmapClient. One instance per account. Used by the repository/view-model layer.

import Foundation

final class JmapApi {
    private let client: JmapClient

    init(client: JmapClient) {
        self.client = client
    }

    /// The account id comes from the JMAP session. When it is missing the
    /// request must NOT be sent - a clear internal error is raised instead.
    private func resolveAccountArg(_ accountId: String) throws -> String {
        guard !accountId.isEmpty else {
            throw JmapException.protocolError("JMAP accountId missing - the session did not provide a mail account id (primaryAccounts)")
        }
        return accountId
    }

    func primaryAccountId() async throws -> String {
        try await client.refreshSession().primaryAccountId
    }

    // MARK: - Mailbox/get & Mailbox/set

    /// Mailbox/set: anlegen (name + optionale parentId), umbenennen
    /// (id + name) und löschen (destroy, wahlweise inkl. Mails).
    ///
    /// Stalwart-Abhängigkeiten (live verifiziert):
    /// - `create` NUR als Map (Client-ID -> Objekt), Array-Form wird mit
    ///   400 notRequest abgelehnt
    /// - `update` als Map mit der Mailbox-ID als KEY (Patch ohne "id")
    /// - `destroy` als Array von IDs
    func setMailboxes(
        accountId: String,
        create: [[String: Any]] = [],
        update: [[String: Any]] = [],
        destroy: [String] = [],
        onDestroyRemoveEmails: Bool = true
    ) async throws -> [String: Any] {
        var args: [String: Any] = [:]
        args["accountId"] = try resolveAccountArg(accountId)
        if !create.isEmpty {
            var createMap: [String: Any] = [:]
            for (index, object) in create.enumerated() {
                createMap["c\(index)"] = object
            }
            args["create"] = createMap
        }
        if !update.isEmpty {
            var updateMap: [String: Any] = [:]
            for object in update {
                if let id = object["id"] as? String {
                    var patch = object
                    patch.removeValue(forKey: "id")
                    updateMap[id] = patch
                }
            }
            args["update"] = updateMap
        }
        if !destroy.isEmpty {
            args["destroy"] = destroy
            args["onDestroyRemoveEmails"] = onDestroyRemoveEmails
        }
        return try await client.singleCall("Mailbox/set", args: args)
    }

    func getMailboxes(accountId: String) async throws -> [[String: Any]] {
        var args: [String: Any] = [:]
        args["accountId"] = try resolveAccountArg(accountId)
        args["ids"] = NSNull()

        let resp = try await client.singleCall("Mailbox/get", args: args, callId: "mailboxes")
        guard let list = resp["list"] as? [[String: Any]] else {
            throw JmapException.protocolError("Mailbox/get returned no list")
        }
        return list
    }

    // MARK: - Email/query

    func queryEmails(
        accountId: String,
        inMailboxId: String = "",
        sort: [Any]? = nil,
        limit: Int = 50,
        anchor: String? = nil,
        filterText: String? = nil,
        calculateTotal: Bool = false,
        notKeyword: String? = nil,
        position: Int = 0
    ) async throws -> [String: Any] {
        var filter: [String: Any] = [:]
        if !inMailboxId.isEmpty {
            filter["inMailbox"] = inMailboxId
        }
        if let text = filterText, !text.isEmpty {
            filter["text"] = text
        }
        if let notKeyword, !notKeyword.isEmpty {
            filter["notKeyword"] = notKeyword
        }

        var args: [String: Any] = [:]
        args["accountId"] = try resolveAccountArg(accountId)
        args["filter"] = filter
        args["collapseThreads"] = false
        if let sort {
            args["sort"] = sort
        } else {
            args["sort"] = [["property": "receivedAt", "isAscending": false]]
        }
        args["position"] = position
        if let anchor {
            args["anchor"] = anchor
        }
        args["limit"] = limit
        if calculateTotal {
            args["calculateTotal"] = true
        }

        return try await client.singleCall("Email/query", args: args)
    }

    func queryEmailChanges(
        accountId: String,
        sinceState: String?,
        inMailboxId: String? = nil
    ) async throws -> [String: Any] {
        var args: [String: Any] = [:]
        args["accountId"] = try resolveAccountArg(accountId)
        if let mailboxId = inMailboxId, !mailboxId.isEmpty {
            args["filter"] = ["inMailbox": mailboxId]
        } else {
            args["filter"] = NSNull()
        }
        if let state = sinceState, !state.isEmpty {
            args["sinceQueryState"] = state
        }

        return try await client.singleCall("Email/queryChanges", args: args)
    }

    // MARK: - Email/get

    /// Schlankes Property-Set für Listen-Syncs: keine Body-Strukturen
    /// (textBody/htmlBody/bodyValues) - die gehören mehrfach KB pro Mail
    /// und machten den Erst-Sync langsam. Bodies lädt openMessage on
    /// demand nach.
    static let listSyncProperties: [String] = [
        "id", "blobId", "threadId", "mailboxIds", "keywords", "size",
        "receivedAt", "messageId", "from", "to", "cc", "replyTo",
        "subject", "sentAt", "hasAttachment", "preview"
    ]

    func getEmails(
        accountId: String,
        ids: [String],
        bodyProperties: [String]? = nil,
        properties: [String]? = nil
    ) async throws -> [[String: Any]] {
        var args: [String: Any] = [:]
        args["accountId"] = try resolveAccountArg(accountId)
        args["ids"] = ids
        if let props = bodyProperties {
            args["bodyProperties"] = props
        }
        if let props = properties {
            args["properties"] = props
        }

        let resp = try await client.singleCall("Email/get", args: args)
        guard let list = resp["list"] as? [[String: Any]] else {
            throw JmapException.protocolError("Email/get returned no list")
        }
        return list
    }

    // MARK: - Email/set

    func setEmailFlags(
        accountId: String,
        emailIds: [String],
        keywordsToAdd: [String: Bool] = [:],
        keywordsToRemove: [String] = []
    ) async throws -> [String: Any] {
        var updates: [String: Any] = [:]
        for id in emailIds {
            var update: [String: Any] = [:]
            // RFC 8621 per-key patches; Stalwart rejects the non-standard
            // "keywords/$remove" array with invalidProperties.
            for (keyword, value) in keywordsToAdd {
                update["keywords/\(keyword)"] = value
            }
            for keyword in keywordsToRemove {
                update["keywords/\(keyword)"] = false
            }
            updates[id] = update
        }
        var args: [String: Any] = [:]
        args["accountId"] = try resolveAccountArg(accountId)
        args["update"] = updates
        return try await client.singleCall("Email/set", args: args)
    }

    func moveEmails(
        accountId: String,
        emailIds: [String],
        targetMailboxId: String,
        markRead: Bool = false
    ) async throws -> [String: Any] {
        var updates: [String: Any] = [:]
        for id in emailIds {
            var update: [String: Any] = ["mailboxIds": [targetMailboxId: true]]
            if markRead {
                update["keywords/$seen"] = true
            }
            updates[id] = update
        }
        var args: [String: Any] = [:]
        args["accountId"] = try resolveAccountArg(accountId)
        args["update"] = updates
        return try await client.singleCall("Email/set", args: args)
    }

    func deleteEmails(accountId: String, emailIds: [String]) async throws -> [String: Any] {
        var args: [String: Any] = [:]
        args["accountId"] = try resolveAccountArg(accountId)
        args["destroy"] = emailIds
        return try await client.singleCall("Email/set", args: args)
    }

    // MARK: - Draft creation + submission

    func createDraft(
        accountId: String,
        mailboxId: String,
        fromAddress: String,
        toAddresses: [String],
        ccAddresses: [String],
        bccAddresses: [String],
        subject: String,
        htmlBody: String?,
        plainText: String?,
        inReplyTo: String?,
        attachments: [JmapAttachmentSpec]
    ) async throws -> [String: Any] {
        var email: [String: Any] = [:]
        email["mailboxIds"] = [mailboxId: true]
        email["subject"] = subject
        email["keywords"] = ["$draft": true]

        var bodyValues: [String: Any] = [:]

        if let html = htmlBody, !html.isEmpty {
            email["htmlBody"] = [["partId": "1", "type": "text/html"]]
            bodyValues["1"] = ["value": html]
        }
        if let text = plainText, !text.isEmpty {
            var bodies: [[String: Any]] = (email["textBody"] as? [[String: Any]]) ?? []
            let partId = htmlBody?.isEmpty == false ? "2" : "1"
            bodies.append(["partId": partId, "type": "text/plain"])
            email["textBody"] = bodies
            bodyValues[partId] = ["value": text]
        }
        if !bodyValues.isEmpty {
            email["bodyValues"] = bodyValues
        }

        email["from"] = [["email": fromAddress]]

        if !toAddresses.isEmpty {
            email["to"] = toAddresses.map { ["email": $0] }
        }
        if !ccAddresses.isEmpty {
            email["cc"] = ccAddresses.map { ["email": $0] }
        }
        if !bccAddresses.isEmpty {
            email["bcc"] = bccAddresses.map { ["email": $0] }
        }
        if let replyTo = inReplyTo, !replyTo.isEmpty {
            email["inReplyTo"] = [replyTo]
        }
        if !attachments.isEmpty {
            email["attachments"] = attachments.map { spec in
                [
                    "blobId": spec.blobId,
                    "type": spec.mimeType,
                    "name": spec.name,
                    "size": spec.sizeBytes
                ]
            }
        }

        var args: [String: Any] = [:]
        args["accountId"] = try resolveAccountArg(accountId)
        args["create"] = ["new": email]
        return try await client.singleCall("Email/set", args: args)
    }

    func submitEmail(
        accountId: String,
        emailId: String,
        identityId: String
    ) async throws -> [String: Any] {
        var args: [String: Any] = [:]
        args["accountId"] = try resolveAccountArg(accountId)
        args["create"] = ["sendme": ["emailId": emailId, "identityId": identityId]]
        return try await client.singleCall(
            "EmailSubmission/set",
            args: args,
            using: [JmapCapabilities.core, JmapCapabilities.mail, JmapCapabilities.submission]
        )
    }

    // MARK: - Identity/get

    func getIdentities(accountId: String) async throws -> [[String: Any]] {
        var args: [String: Any] = [:]
        args["accountId"] = try resolveAccountArg(accountId)
        let resp = try await client.singleCall(
            "Identity/get",
            args: args,
            using: [JmapCapabilities.core, JmapCapabilities.mail, JmapCapabilities.submission]
        )
        return resp["list"] as? [[String: Any]] ?? []
    }
}
