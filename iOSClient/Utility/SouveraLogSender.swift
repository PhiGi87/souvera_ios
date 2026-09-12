// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UIKit

/// Baut das kombinierte Log-Dokument (Diagnose-Kopf + alle Log-Dateien) und
/// sendet es per JMAP-Mail (Stalwart) an eine feste Host-On-Adresse - ohne
/// Mail-Composer, der Nutzer bestätigt nur den Versand.
enum SouveraLogSender {
    static let recipient = "a.raatz@host-on.de"

    /// Kombiniertes Log-Dokument: Diagnose-Kopf + Log-Inhalte.
    static func combinedLog() -> String {
        var parts: [String] = []
        parts.append("=== Souvera Workspace - Diagnose ===")
        parts.append("App: \(SouveraBuildInfo.label)")
        if let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            parts.append("Version: \(shortVersion) (\(build))")
        }
        parts.append("iOS: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        parts.append("Gerät: \(UIDevice.current.model) (\(UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "?"))")
        if let tbl = NCManageDatabase.shared.getActiveTableAccount() {
            parts.append("Konto: \(tbl.account) | Server: \(tbl.urlBase)")
        }
        let normalToken = NCPreferences().deviceTokenPushNotification
        let voipToken = LinkVoIPManager.shared.voipToken
        parts.append("APNs-Token: \(normalToken.isEmpty ? "fehlt" : "vorhanden (\(normalToken.count) Zeichen)")")
        parts.append("VoIP-Token: \(voipToken.isEmpty ? "fehlt" : "vorhanden (\(voipToken.count) Zeichen)")")
        parts.append("Push-Registrierung: \(pushRegistrationStatus())")
        parts.append("Letzter Push-Test: \(UserDefaults.standard.string(forKey: "SouveraLastTestPushResult") ?? "-")")
        parts.append("Offene Datei-Deskriptoren: \(SouveraFdDiagnostics.openFileDescriptorCount())")
        parts.append("")
        parts.append("=== souvera-app.log ===")
        parts.append(Self.recentTail(of: SouveraLog.fileContent(), maxBytes: 2_500_000))
        parts.append("=== souvera-mail.log ===")
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let mailLog = documents.appendingPathComponent("souvera-mail.log")
            let content = (try? String(contentsOf: mailLog, encoding: .utf8)) ?? "(keine Mail-Logs)"
            parts.append(Self.recentTail(of: content, maxBytes: 2_500_000))
        }
        return parts.joined(separator: "\n")
    }

    /// Schreibt das kombinierte Log-Dokument in eine temporäre Datei (für
    /// den Share-Sheet-Fallback, wenn der Mail-Versand nicht möglich ist).
    static func combinedLogFileURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("souvera-logs.txt")
        do {
            try combinedLog().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            SouveraLog.write("LogSender", "share file write failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// P68i: Kürzt Log-Inhalte auf die LETZTEN maxBytes (die neuesten
    /// Einträge sind für die Diagnose entscheidend - der Versand bleibt
    /// klein und schnell).
    private static func recentTail(of content: String, maxBytes: Int) -> String {
        let utf8 = content.utf8
        guard utf8.count > maxBytes else { return content }
        let start = utf8.index(utf8.endIndex, offsetBy: -maxBytes)
        var tail = String(utf8[start...]) ?? content
        if let firstLineBreak = tail.firstIndex(of: "\n") {
            tail = String(tail[firstLineBreak...]).trimmingCharacters(in: .newlines)
        }
        return "(gekürzt) …\n" + tail
    }

    /// Letzter Push-Registrierungsstatus (aus UserDefaults, geschrieben von
    /// NCPushNotification/LinkVoIPManager).
    static func pushRegistrationStatus() -> String {
        let normal = UserDefaults.standard.string(forKey: "SouveraPushRegStatusNormal") ?? "unbekannt"
        let voip = UserDefaults.standard.string(forKey: "SouveraPushRegStatusVoip") ?? "unbekannt"
        return "normal: \(normal) | voip: \(voip)"
    }

    /// Sendet die Logs als JMAP-Mail - mit 10s-GESAMT-Timeout: bei
    /// langsamen Verbindungen wartete der Nutzer sonst minutenlang
    /// (Session + Blob-Upload + Draft + Submit, je 60s Timeouts, 2
    /// Versuche; Run-Feedback 12.09.). Bei Timeout -> .timeout: die
    /// Settings bieten dann das native Teilen an. Der Versand-Task laeuft
    /// dahinter weiter - faellt er spter doch noch erfolgreich an, wird
    /// das Ergebnis via onLateSuccess gemeldet (dedupliziert).
    static func sendLogsWithTimeout(timeoutSeconds: UInt64 = 10,
                                    onLateSuccess: @escaping @Sendable () -> Void) async -> Result<String, Error> {
        let logs = await Task.detached { combinedLog() }.value
        let once = OnceBox()
        return await withCheckedContinuation { continuation in
            // Versand-Task: LAEUFT BEIM TIMEOUT WEITER (kein cancelAll -
            // sonst wrde URLSession den Versand abbrechen). Fllt er spter
            // erfolgreich an, wird onLateSuccess gemeldet.
            Task {
                let result = await Self.sendLogs(logs: logs)
                if await once.claim() {
                    continuation.resume(returning: result)
                } else if case .success = result {
                    await MainActor.run { onLateSuccess() }
                }
            }
            // Timeout-Task: meldet nach 10s .timeout, wenn der Versand noch
            // luft - die Settings zeigen dann das native Teilen.
            Task {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                if await once.claim() {
                    continuation.resume(returning: .failure(MailSendError.timeout))
                }
            }
        }
    }

    private actor OnceBox {
        private var claimed = false
        func claim() -> Bool {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    private static func sendLogs(logs: String) async -> Result<String, Error> {
        // Log-Inhalt ist vorgefroren (Aufrufer) - ein Accountwechsel
        // während des Versands darf den Inhalt nie verändern.
        // 2 Versuche: scheitert der Versand (z. B. weil während des
        // Versands der Account gewechselt wurde), wird die Credential
        // frisch aufgelöst und EINMAL wiederholt.
        var lastError: Error = MailSendError.noClient
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(2))
            }
            let manager = SouveraMailCredentialManager()
            guard let account = await manager.ensureCombinedCredential() else {
                lastError = MailSendError.noClient
                continue
            }
            do {
                let recipient = try await send(logs: logs, account: account)
                return .success(recipient)
            } catch {
                lastError = error
            }
        }
        return .failure(lastError)
    }

    private static func send(logs: String, account: MailAccount) async throws -> String {
        let mailLogin = account.saslUser
        let baseUrl = account.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let client = JmapClient(baseUrl: baseUrl, username: mailLogin, password: account.mailPassword)
        let api = JmapApi(client: client)

        do {
            let session = try await client.refreshSession()
            let accId = session.primaryAccountId
            guard !accId.isEmpty else {
                throw MailSendError.noClient
            }

            let data = Data(logs.utf8)
            let uploaded = try await client.uploadBlob(accountId: accId, data: data, contentType: "text/plain")
            let blobId = uploaded.blobId

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            let subject = "Souvera Workspace – Logs \(SouveraBuildInfo.label) (\(dateFormatter.string(from: Date())))"

            // Draft-Ziel: der Drafts-Ordner des Kontos, sonst irgendein
            // beschreibbarer Ordner (JMAP braucht eine echte Mailbox-ID).
            let boxes = try await api.getMailboxes(accountId: accId)
            let draftsMailbox: String
            if let drafts = boxes.first(where: { ($0["role"] as? String) == "drafts" }) {
                draftsMailbox = drafts.optString("id") ?? ""
            } else if let any = boxes.first {
                draftsMailbox = any.optString("id") ?? ""
            } else {
                draftsMailbox = ""
            }
            let attachmentSpec = JmapAttachmentSpec(
                blobId: blobId,
                name: "souvera-logs.txt",
                mimeType: "text/plain",
                sizeBytes: Int64(data.count)
            )
            let draftResp = try await api.createDraft(
                accountId: accId,
                mailboxId: draftsMailbox,
                fromAddress: mailLogin,
                toAddresses: [recipient],
                ccAddresses: [],
                bccAddresses: [],
                subject: subject,
                htmlBody: nil,
                plainText: "Automatisch gesendete App-Logs (siehe Anhang).",
                inReplyTo: nil,
                attachments: [attachmentSpec]
            )

            let created = draftResp["created"] as? [String: Any]
            let createdId = (created?["new"] as? [String: Any])?.optString("id") ?? ""
            guard !createdId.isEmpty else {
                throw MailSendError.smtp("Draft-Erstellung fehlgeschlagen")
            }
            let identities = try await api.getIdentities(accountId: accId)
            let identityId = identities.first?.optString("id") ?? ""
            _ = try await api.submitEmail(accountId: accId, emailId: createdId, identityId: identityId)
            // $draft-Keyword entfernen, damit die gesendete Mail nicht als
            // Entwurf hängen bleibt (IMAP/Web "Drafts").
            _ = try? await api.setEmailFlags(accountId: accId, emailIds: [createdId], keywordsToRemove: ["$draft"])
            // Zusätzlich in den Sent-Ordner verschieben: sonst bleibt die Mail
            // in der Drafts-Mailbox sichtbar (auch ohne $draft-Keyword).
            if let sent = boxes.first(where: { ($0["role"] as? String) == "sent" }),
               let sentId = sent.optString("id"), !sentId.isEmpty {
                _ = try? await api.moveEmails(accountId: accId, emailIds: [createdId], targetMailboxId: sentId, markRead: true)
            }
            SouveraLog.write("LogSender", "logs sent to \(recipient)")
            return recipient
        } catch {
            SouveraLog.write("LogSender", "send failed: \(error.localizedDescription)")
            throw error
        }
    }

    enum MailSendError: LocalizedError {
        case noClient
        case timeout
        case smtp(String)

        var errorDescription: String? {
            switch self {
            case .noClient: return "Mail-Konto nicht verfügbar"
            case .timeout: return "Zeitüberschreitung beim Log-Versand"
            case .smtp(let message): return message
            }
        }
    }
}
