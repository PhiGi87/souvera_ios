// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Minimaler, eigenständiger Mail-Sender für Einladungsantworten (iMIP).
// Der Kalender hat keine MailViewModel-Instanz - hier wird gezielt ein
// JMAP-Client aufgebaut, ein Entwurf erzeugt und submitted.
import Foundation

// Run 18.09. (Feedback: App-Hang): NICHT @MainActor - der komplette
// Einladungs-Netzwerkverkehr (Credential, JMAP, Blob-Download) lief
// sonst auf dem Main-Thread und blockierte die UI fuer Sekunden.
// Run 18.09. (Feedback: Abgelehnt/Vielleicht-Mails kommen nicht an):
// ACTOR-Serialisierung (keine konkurrierenden JMAP-Requests gegen den
// Server - Stalwart antwortete mit maxConcurrentRequests/Timeout) und
// Retry mit Backoff bei 429/5xx/Transportfehlern.
actor SouveraInviteMailSender {
    static let shared = SouveraInviteMailSender()

    /// Sendet eine Antwort-Mail (HTML + Text + optionaler ICS-Anhang)
    /// mit bis zu 2 Wiederholungen (Backoff 2s/5s) bei 429/5xx/Timeout.
    func send(to: String,
              subject: String,
              html: String,
              text: String,
              icsAttachmentURL: URL?) async -> Bool {
        guard to.contains("@") else { return false }
        for attempt in 0..<3 {
            if attempt > 0 {
                let backoff = attempt == 1 ? 2_000_000_000 : 5_000_000_000
                try? await Task.sleep(nanoseconds: backoff)
            }
            if await sendOnce(to: to, subject: subject, html: html,
                              text: text, icsAttachmentURL: icsAttachmentURL) {
                return true
            }
            SouveraLog.write("Invitations", "send attempt \(attempt + 1) failed (subject=\(subject))")
        }
        return false
    }

    private func sendOnce(to: String,
                          subject: String,
                          html: String,
                          text: String,
                          icsAttachmentURL: URL?) async -> Bool {
        do {
            let manager = SouveraMailCredentialManager()
            guard let account = await manager.renewCredential() else { return false }
            let login = account.saslUser
            let client = JmapClient(
                baseUrl: account.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                username: login,
                password: account.mailPassword
            )
            let api = JmapApi(client: client)
            let session = try await client.refreshSession()
            let accId = session.primaryAccountId

            let mailboxes = try await api.getMailboxes(accountId: accId)
            let draftsId = mailboxes.first(where: { ($0["role"] as? String) == "drafts" })?["id"] as? String
                ?? mailboxes.first?.optString("id") ?? ""

            var specs: [JmapAttachmentSpec] = []
            if let url = icsAttachmentURL, let data = try? Data(contentsOf: url),
               let uploaded = try? await client.uploadBlob(accountId: accId, data: data, contentType: "text/calendar") {
                specs.append(JmapAttachmentSpec(
                    blobId: uploaded.blobId,
                    name: "invite.ics",
                    mimeType: "text/calendar",
                    sizeBytes: Int64(data.count)
                ))
            }

            let identities = try await api.getIdentities(accountId: accId)
            let identityId = identities.first?.optString("id") ?? ""
            let draftResp = try await api.createDraft(
                accountId: accId,
                mailboxId: draftsId,
                fromAddress: login,
                toAddresses: [to],
                ccAddresses: [],
                bccAddresses: [],
                subject: subject,
                htmlBody: html,
                plainText: text,
                inReplyTo: nil,
                attachments: specs
            )
            let created = draftResp["created"] as? [String: Any]
            let emailId = (created?["new"] as? [String: Any])?.optString("id") ?? ""
            guard !emailId.isEmpty, !identityId.isEmpty else { return false }
            _ = try await api.submitEmail(accountId: accId, emailId: emailId, identityId: identityId)
            _ = try? await api.setEmailFlags(
                accountId: accId,
                emailIds: [emailId],
                keywordsToRemove: ["$draft"]
            )
            return true
        } catch {
            SouveraLog.write("Invitations", "reply mail failed: \(error)")
            return false
        }
    }
}


// MARK: - Run 16.09.: Lazy-Fetch der Einladungsdaten

extension SouveraInviteMailSender {

    struct InvitationDetails {
        let ics: String?
        let plainText: String?
    }

    /// Laedt die Einladungsmail VOLLstaendig (wie openMessage): alle
    /// Body-Parts mit Disposition/Type - der text/calendar-Part kommt
    /// je nach Sender als Attachment ODER Inline-Part.
    static func fetchInvitationDetails(messageId: String) async -> InvitationDetails? {
        do {
            let manager = SouveraMailCredentialManager()
            guard let account = await manager.renewCredential() else { return nil }
            let login = account.saslUser
            let client = JmapClient(
                baseUrl: account.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                username: login,
                password: account.mailPassword
            )
            let api = JmapApi(client: client)
            let session = try await client.refreshSession()
            let accId = session.primaryAccountId
            let emails = try await api.getEmails(
                accountId: accId,
                ids: [messageId],
                bodyProperties: ["partId", "blobId", "size", "type", "name", "disposition", "cid"],
                fetchAllBodyValues: true
            )
            guard let json = emails.first else { return nil }

            // 1) text/calendar-Part (Attachment ODER Inline).
            var ics: String?
            let parts = ((json["attachments"] as? [[String: Any]]) ?? [])
                + ((json["inlineAttachments"] as? [[String: Any]]) ?? [])
            if let calPart = parts.first(where: {
                ($0["type"] as? String)?.lowercased().contains("calendar") == true
                    || (($0["name"] as? String)?.lowercased().hasSuffix(".ics") == true)
            }), let blobId = calPart["blobId"] as? String {
                let data = try? await client.downloadBlob(accountId: accId, blobId: blobId, mimeType: "text/calendar")
                ics = String(data: data ?? Data(), encoding: .utf8)
            }

            // 2) Plain-Text (fuer den Text-Fallback ohne ICS).
            var plain: String?
            if let bodyValues = json["bodyValues"] as? [String: Any],
               let textParts = json["textBody"] as? [[String: Any]],
               let first = textParts.first,
               let partId = first.optString("partId"),
               let value = bodyValues[partId] as? [String: Any] {
                plain = value.optString("value")
            }
            SouveraLog.write("Invitations", "lazy fetch \(messageId): ics=\(ics != nil) text=\(plain != nil)")
            return InvitationDetails(ics: ics, plainText: plain)
        } catch {
            SouveraLog.write("Invitations", "lazy fetch failed: \(error)")
            return nil
        }
    }

    /// Text-Fallback ohne ICS: parst das Nextcloud/iTIP-Einladungsformat
    /// ("Wann: ... am Donnerstag, 17. September 2026 zwischen 14:00 -
    /// 14:30 (Europe/Berlin)" bzw. englisch "When: ... from 2:00 PM to
    /// 2:30 PM..."). Liefert Titel + Zeitraum oder nil - NIEMALS eine
    /// Jetzt-Zeit als Platzhalter.
    nonisolated static func parseTimeFromText(subject: String, plainText: String?) -> (title: String, start: Date, end: Date)? {
        guard let text = plainText, !text.isEmpty else { return nil }
        // Erst die Zeilen mit Wann/When, sonst der Textanfang.
        let lines = text.split(separator: "\n")
        let relevant = lines.filter { $0.lowercased().contains("wann:") || $0.lowercased().contains("when:") }
        let haystack = relevant.isEmpty ? String(text.prefix(1500)) : relevant.joined(separator: " ") + " " + String(text.prefix(1500))

        // Titel: "moegchte Sie zu "X" einladen" oder Betreff nach Praefix.
        var title = subject
        for prefix in ["Einladung: ", "Invitation: ", "Einladung ", "Invitation "] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        let enFormatter = DateFormatter()
        enFormatter.locale = Locale(identifier: "en_US_POSIX")

        // Datum: "17. September 2026" / "September 17, 2026" / "17.09.2026"
        var day: Date?
        let germanDate = "\\d{1,2}\\. (?:Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember) \\d{4}"
        let numericDate = "\\d{2}\\.\\d{2}\\.\\d{4}"
        let englishDate = "(?:January|February|March|April|May|June|July|August|September|October|November|December) \\d{1,2}, \\d{4}"
        for (pattern, fmt) in [(germanDate, "d. MMMM yyyy"), (englishDate, "MMMM d, yyyy"), (numericDate, "dd.MM.yyyy")] {
            if let range = haystack.range(of: pattern, options: [.regularExpression]) {
                let candidate = String(haystack[range])
                formatter.dateFormat = fmt
                enFormatter.dateFormat = fmt
                if let d = formatter.date(from: candidate) ?? enFormatter.date(from: candidate) {
                    day = Calendar.current.startOfDay(for: d)
                    break
                }
            }
        }
        guard let day else { return nil }

        // Zeiten: HH:MM - HH:MM (auch "zwischen 14:00 - 14:30").
        let timePattern = "\\d{1,2}:\\d{2}"
        let times = haystack.ranges(of: timePattern).compactMap { range -> (Int, Int)? in
            let parts = haystack[range].split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), h < 24, m < 60 else { return nil }
            return (h, m)
        }
        guard times.count >= 2 else { return nil }
        let calendar = Calendar.current
        var start = calendar.date(bySettingHour: times[0].0, minute: times[0].1, second: 0, of: day) ?? day
        var end = calendar.date(bySettingHour: times[1].0, minute: times[1].1, second: 0, of: day) ?? day
        if end <= start { end = start.addingTimeInterval(1800) }
        return (title, start, end)
    }
}
