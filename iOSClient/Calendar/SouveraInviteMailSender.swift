// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Minimaler, eigenständiger Mail-Sender für Einladungsantworten (iMIP).
// Der Kalender hat keine MailViewModel-Instanz - hier wird gezielt ein
// JMAP-Client aufgebaut, ein Entwurf erzeugt und submitted.
import Foundation

@MainActor
final class SouveraInviteMailSender {
    static let shared = SouveraInviteMailSender()

    /// Sendet eine Antwort-Mail (HTML + Text + optionaler ICS-Anhang).
    func send(to: String,
              subject: String,
              html: String,
              text: String,
              icsAttachmentURL: URL?) async -> Bool {
        guard to.contains("@") else { return false }
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
