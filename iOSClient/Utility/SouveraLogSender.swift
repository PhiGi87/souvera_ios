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
        parts.append("")
        parts.append("=== souvera-app.log ===")
        parts.append(SouveraLog.fileContent())
        parts.append("=== souvera-mail.log ===")
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let mailLog = documents.appendingPathComponent("souvera-mail.log")
            parts.append((try? String(contentsOf: mailLog, encoding: .utf8)) ?? "(keine Mail-Logs)")
        }
        return parts.joined(separator: "\n")
    }

    /// Letzter Push-Registrierungsstatus (aus UserDefaults, geschrieben von
    /// NCPushNotification/LinkVoIPManager).
    static func pushRegistrationStatus() -> String {
        let normal = UserDefaults.standard.string(forKey: "SouveraPushRegStatusNormal") ?? "unbekannt"
        let voip = UserDefaults.standard.string(forKey: "SouveraPushRegStatusVoip") ?? "unbekannt"
        return "normal: \(normal) | voip: \(voip)"
    }

    /// Sendet die Logs als JMAP-Mail an die feste Host-On-Adresse.
    static func sendLogs() async -> Result<String, Error> {
        let manager = SouveraMailCredentialManager()
        guard let account = await manager.ensureCombinedCredential() else {
            return .failure(MailSendError.noClient)
        }
        let mailLogin = account.saslUser
        let baseUrl = account.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let client = JmapClient(baseUrl: baseUrl, username: mailLogin, password: account.mailPassword)
        let api = JmapApi(client: client)

        do {
            let session = try await client.refreshSession()
            let accId = session?.primaryAccountId ?? ""
            guard !accId.isEmpty else {
                return .failure(MailSendError.noClient)
            }

            let logs = combinedLog()
            let data = Data(logs.utf8)
            guard let uploaded = try await client.uploadBlob(accountId: accId, data: data, contentType: "text/plain") else {
                return .failure(MailSendError.smtp("Log-Upload fehlgeschlagen"))
            }

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            let subject = "Souvera Workspace – Logs \(SouveraBuildInfo.label) (\(dateFormatter.string(from: Date())))"

            // Draft-Ziel: der Drafts-Ordner des Kontos, sonst irgendein
            // beschreibbarer Ordner (JMAP braucht eine echte Mailbox-ID).
            let boxes = try await api.getMailboxes(accountId: accId)
            let draftsMailbox = boxes.first(where: { ($0["role"] as? String) == "drafts" })?.optString("id")
                ?? boxes.first(where: { $0.optString("id") != nil })?.optString("id")
                ?? ""
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
                attachments: [JmapAttachmentSpec(
                    blobId: uploaded.blobId,
                    name: "souvera-logs.txt",
                    mimeType: "text/plain",
                    sizeBytes: Int64(data.count)
                )]
            )

            let created = draftResp["created"] as? [String: Any]
            let createdId = (created?["new"] as? [String: Any])?.optString("id") ?? ""
            guard !createdId.isEmpty else {
                return .failure(MailSendError.smtp("Draft-Erstellung fehlgeschlagen"))
            }
            let identityId = try await api.getIdentities(accountId: accId).first?.optString("id") ?? ""
            _ = try await api.submitEmail(accountId: accId, emailId: createdId, identityId: identityId)
            SouveraLog.write("LogSender", "logs sent to \(recipient)")
            return .success(recipient)
        } catch {
            SouveraLog.write("LogSender", "send failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    enum MailSendError: LocalizedError {
        case noClient
        case smtp(String)

        var errorDescription: String? {
            switch self {
            case .noClient: return "Mail-Konto nicht verfügbar"
            case .smtp(let message): return message
            }
        }
    }
}
