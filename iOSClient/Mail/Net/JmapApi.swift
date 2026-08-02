// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from souvera_android mail/net/jmap/JmapApi.kt.
//
// High-level JMAP API that builds method-call arguments and delegates to
// JmapClient. One instance per account. Used by the repository/view-model layer.

import Foundation

final class JmapApi: @unchecked Sendable {
    private let client: JmapClient

    init(client: JmapClient) {
        self.client = client
    }

    func primaryAccountId() async throws -> String {
        try await client.refreshSession().primaryAccountId
    }

    // MARK: - Mailbox/get

    func getMailboxes(accountId: String) async throws -> [JSONDictionary] {
        var args: JSONDictionary = [:]
        if !accountId.isEmpty {
            args["accountId"] = accountId
        }
        args["ids"] = NSNull()

        let resp = try await client.singleCall("Mailbox/get", args: args)
        guard let list = resp["list"] as? [JSONDictionary] else {
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
        anchor: Int64? = nil,
        filterText: String? = nil
    ) async throws -> JSONDictionary {
        var filter: JSONDictionary = [:]
        if !inMailboxId.isEmpty {
            filter["inMailbox"] = inMailboxId
        }
        if let text = filterText, !text.isEmpty {
            filter["text"] = text
        }

        var args: JSONDictionary = [:]
        if !accountId.isEmpty {
            args["accountId"] = accountId
        }
        args["filter"] = filter
        args["collapseThreads"] = false
        if let sort {
            args["sort"] = sort
        } else {
            args["sort"] = [["property": "receivedAt", "isAscending": false]]
        }
        args["position"] = 0
        if let anchor {
            args["anchor"] = anchor
        }
        args["limit"] = limit

        return try await client.singleCall("Email/query", args: args)
    }

    func queryEmailChanges(
        accountId: String,
        sinceState: String?,
        inMailboxId: String? = nil
    ) async throws -> JSONDictionary {
        var args: JSONDictionary = [:]
        if !accountId.isEmpty {
            args["accountId"] = accountId
        }
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

    func getEmails(
        accountId: String,
        ids: [String],
        bodyProperties: [String]? = nil
    ) async throws -> [JSONDictionary] {
        var args: JSONDictionary = [:]
        if !accountId.isEmpty {
            args["accountId"] = accountId
        }
        args["ids"] = ids
        if let props = bodyProperties {
            args["bodyProperties"] = props
        }

        let resp = try await client.singleCall("Email/get", args: args)
        guard let list = resp["list"] as? [JSONDictionary] else {
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
    ) async throws -> JSONDictionary {
        var updates: JSONDictionary = [:]
        for id in emailIds {
            var update: JSONDictionary = [:]
            if !keywordsToAdd.isEmpty {
                update["keywords/$add"] = keywordsToAdd
            }
            if !keywordsToRemove.isEmpty {
                update["keywords/$remove"] = keywordsToRemove
            }
            updates[id] = update
        }
        var args: JSONDictionary = [:]
        if !accountId.isEmpty {
            args["accountId"] = accountId
        }
        args["update"] = updates
        return try await client.singleCall("Email/set", args: args)
    }

    func moveEmails(
        accountId: String,
        emailIds: [String],
        targetMailboxId: String
    ) async throws -> JSONDictionary {
        var updates: JSONDictionary = [:]
        for id in emailIds {
            updates[id] = ["mailboxIds": [targetMailboxId: true]]
        }
        var args: JSONDictionary = [:]
        if !accountId.isEmpty {
            args["accountId"] = accountId
        }
        args["update"] = updates
        return try await client.singleCall("Email/set", args: args)
    }

    func deleteEmails(accountId: String, emailIds: [String]) async throws -> JSONDictionary {
        var args: JSONDictionary = [:]
        if !accountId.isEmpty {
            args["accountId"] = accountId
        }
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
        blobIds: [String]
    ) async throws -> JSONDictionary {
        var email: JSONDictionary = [:]
        email["mailboxIds"] = [mailboxId: true]
        email["subject"] = subject
        email["keywords"] = ["$draft": true]

        var bodyValues: JSONDictionary = [:]

        if let html = htmlBody, !html.isEmpty {
            email["htmlBody"] = [["partId": "1", "type": "text/html"]]
            bodyValues["1"] = ["value": html]
        }
        if let text = plainText, !text.isEmpty {
            var bodies: [JSONDictionary] = (email["textBody"] as? [JSONDictionary]) ?? []
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
        if !blobIds.isEmpty {
            email["attachments"] = blobIds.map { ["blobId": $0, "type": "application/octet-stream"] }
        }

        var args: JSONDictionary = [:]
        if !accountId.isEmpty {
            args["accountId"] = accountId
        }
        args["create"] = ["new": email]
        return try await client.singleCall("Email/set", args: args)
    }

    func submitEmail(
        accountId: String,
        emailId: String,
        identityId: String
    ) async throws -> JSONDictionary {
        var args: JSONDictionary = [:]
        if !accountId.isEmpty {
            args["accountId"] = accountId
        }
        args["create"] = ["sendme": ["emailId": emailId, "identityId": identityId]]
        return try await client.singleCall(
            "EmailSubmission/set",
            args: args,
            using: [JmapCapabilities.core, JmapCapabilities.mail, JmapCapabilities.submission]
        )
    }

    // MARK: - Identity/get

    func getIdentities(accountId: String) async throws -> [JSONDictionary] {
        var args: JSONDictionary = [:]
        if !accountId.isEmpty {
            args["accountId"] = accountId
        }
        let resp = try await client.singleCall(
            "Identity/get",
            args: args,
            using: [JmapCapabilities.core, JmapCapabilities.mail, JmapCapabilities.submission]
        )
        return resp["list"] as? [JSONDictionary] ?? []
    }
}
