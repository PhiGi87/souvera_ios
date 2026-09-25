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

    /// Run 25.09.: Roher Filter (z. B. JMAP-FilterOperator OR fuer die
    /// Mail-Suche ueber text/from/to/cc/bcc).
    func queryEmailsRaw(
        accountId: String,
        filter: [String: Any],
        limit: Int = 50,
        position: Int = 0
    ) async throws -> [String: Any] {
        var args: [String: Any] = [:]
        args["accountId"] = try resolveAccountArg(accountId)
        args["filter"] = filter
        args["collapseThreads"] = false
        args["sort"] = [["property": "receivedAt", "isAscending": false]]
        args["position"] = position
        args["limit"] = limit
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
        properties: [String]? = nil,
        fetchAllBodyValues: Bool = false
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
        // Run-Fix "leerer Mail-Body": Ohne dieses Flag liefern Server das
        // bodyValues-Feld LEER (Log 08.09.: keys=...,bodyValues,... aber
        // plain=false html=false) - der Body blieb unwiederbringlich leer.
        if fetchAllBodyValues {
            args["fetchAllBodyValues"] = true
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
        identityId: String,
        sentMailboxId: String? = nil
    ) async throws -> [String: Any] {
        var args: [String: Any] = [:]
        args["accountId"] = try resolveAccountArg(accountId)
        args["create"] = ["sendme": ["emailId": emailId, "identityId": identityId]]
        // Run 21.09. (Feedback: Entwuerfe gesendeter Mails blieben liegen):
        // serverseitig ATOMAR nach Gesendet verschieben und $draft entfernen
        // (RFC 8621 onSuccessUpdateEmail, Key = Submission-Creation-Id).
        let patchKey = "#sendme"
        if let sentMailboxId, !sentMailboxId.isEmpty {
            args["onSuccessUpdateEmail"] = [
                patchKey: [
                    "mailboxIds": [sentMailboxId: true],
                    "keywords/$draft": false,
                    "keywords/$seen": true
                ]
            ]
        }
        let using: [String] = [JmapCapabilities.core, JmapCapabilities.mail, JmapCapabilities.submission]
        let resp = try await client.singleCall("EmailSubmission/set", args: args, using: using)
        // Defensiv: unterstuetzt der Server onSuccessUpdateEmail nicht
        // (notCreated), OHNE Patch erneut submitten - kein Doppelversand,
        // weil nur auf die notCreated-Antwort reagiert wird (nicht auf
        // Netzfehler).
        if sentMailboxId != nil,
           let notCreated = resp["notCreated"] as? [String: Any],
           notCreated["sendme"] != nil {
            var plainArgs = args
            plainArgs.removeValue(forKey: "onSuccessUpdateEmail")
            JmapLog.write("submit: onSuccessUpdateEmail abgelehnt - Retry ohne Patch")
            return try await client.singleCall("EmailSubmission/set", args: plainArgs, using: using)
        }
        return resp
    }

    /// Run 25.09. (Feedback: Shared-Versand landete nicht im Shared-Sent):
    /// Kopiert eine Mail zwischen JMAP-Accounts (Cross-Account, z. B.
    /// Primaer -> Shared-Postfach) und entfernt optional das Original
    /// (RFC 8621 Email/copy; `accountId` = Ziel-Account).
    func copyEmail(fromAccountId: String,
                   toAccountId: String,
                   emailId: String,
                   mailboxId: String,
                   destroyOriginal: Bool) async throws -> String {
        let creationId = "copy\(UUID().uuidString.prefix(8))"
        var args: [String: Any] = [:]
        args["fromAccountId"] = try resolveAccountArg(fromAccountId)
        args["accountId"] = try resolveAccountArg(toAccountId)
        args["create"] = [creationId: ["id": emailId, "mailboxIds": [mailboxId: true]]]
        if destroyOriginal {
            args["onSuccessDestroyOriginal"] = true
        }
        let resp = try await client.singleCall("Email/copy", args: args)
        return resp.optString("newState") ?? ""
    }

    /// Run 19.09. (Feedback: Antwort-Mail kam nicht an): Die Einreichung
    /// nach dem Submit auf "final" setzen (Undo-Fenster beenden) und den
    /// Zustand pruefen - Stalwart akzeptierte sie sonst nur als "pending".
    func finalizeSubmission(accountId: String, submissionId: String) async throws -> [String: Any] {
        var args: [String: Any] = [:]
        args["accountId"] = try resolveAccountArg(accountId)
        args["update"] = [submissionId: ["undoStatus": "final"]]
        return try await client.singleCall(
            "EmailSubmission/set",
            args: args,
            using: [JmapCapabilities.core, JmapCapabilities.mail, JmapCapabilities.submission]
        )
    }

    /// Zustand einer Einreichung abfragen (sent/failed/pending).
    func getSubmission(accountId: String, submissionId: String) async throws -> [String: Any] {
        var args: [String: Any] = [:]
        args["accountId"] = try resolveAccountArg(accountId)
        args["ids"] = [submissionId]
        return try await client.singleCall(
            "EmailSubmission/get",
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
