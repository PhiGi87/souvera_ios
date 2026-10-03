// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 27.09.: Führt die Long-Press-Aktionen auf Mail-Push-Meldungen aus
// ("gelesen", "markiert", "löschen") - auch bei Kaltstart, ohne geöffnete
// Mail-Liste. Der Push-`emailId` ist serverseitig eine KURZFORM (P62e):
// `Email/set` wirkt mit ihr NICHT (Server-No-Op) - deshalb wird vor jeder
// Aktion die kanonische (volle) Id per blobId ermittelt.

import Foundation
import UIKit

enum SouveraMailPushActionRunner {

    /// Reiner Helfer (Regression gegen Mail-Kaskaden): eine Mail-Aktion
    /// betrifft IMMER genau eine Mail (anders als die raumweite
    /// Talk-Kaskade) - leere Eingabe ergibt keine Aktion.
    nonisolated static func targetEmailIds(canonicalId: String) -> [String] {
        canonicalId.isEmpty ? [] : [canonicalId]
    }

    /// Reiner Helfer (unit-testbar): wählt aus den Kandidaten die Zeile
    /// mit passender blobId und liefert deren (kanonische) Id.
    static func canonicalEmailId(blobId: String, in candidates: [(id: String, blobId: String?)]) -> String? {
        guard !blobId.isEmpty else { return nil }
        return candidates.first(where: { $0.blobId == blobId })?.id
    }

    /// Ermittelt die kanonische E-Mail-Id zur (kurzen) Push-Id:
    /// Email/get -> blobId -> Email/query (Fenster im Ordner der Mail)
    /// -> Email/get der Treffer -> blobId-Match (Muster von P62e,
    /// dort gegen die Live-Liste; hier eigenständig per Abfrage).
    static func resolveCanonicalEmailId(api: JmapApi, accountId: String, emailId: String) async -> String? {
        do {
            let fetched = try await api.getEmails(accountId: accountId,
                                                  ids: [emailId],
                                                  properties: ["id", "blobId", "mailboxIds"])
            guard let json = fetched.first,
                  let blobId = json["blobId"] as? String, !blobId.isEmpty else {
                SouveraLog.write("MailAction", "canonical lookup: keine blobId für \(emailId)")
                return nil
            }
            var mailboxId = ""
            if let boxes = json["mailboxIds"] as? [String: Any], let first = boxes.keys.first {
                mailboxId = first
            }
            let query = try await api.queryEmails(accountId: accountId,
                                                  inMailboxId: mailboxId,
                                                  limit: 50)
            let ids = (query["ids"] as? [String]) ?? []
            guard !ids.isEmpty else { return nil }
            let rows = try await api.getEmails(accountId: accountId, ids: ids,
                                               properties: ["id", "blobId"])
            let candidates: [(id: String, blobId: String?)] = rows.map {
                ($0["id"] as? String ?? "", $0["blobId"] as? String)
            }
            guard let canonical = canonicalEmailId(blobId: blobId, in: candidates) else {
                SouveraLog.write("MailAction", "canonical lookup: kein Treffer für \(emailId) (blobId=\(blobId))")
                return nil
            }
            SouveraLog.write("MailAction", "canonical id \(emailId) -> \(canonical)")
            return canonical
        } catch {
            SouveraLog.write("MailAction", "canonical lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Run 30.09. (Feedback: Lesestatus sofort sichtbar): spiegelt den
    /// Server-erfolgreichen Flag-Change in die OFFENE App (Zeile, Badge,
    /// Pills, persistierter Cache). App nicht offen/hintergrund: nichts zu
    /// tun - der Server-Stand stimmt bereits, der Foreground-Sync zeigt ihn.
    private static func mirrorLocally(emailId: String, keyword: String, value: Bool) async {
        NotificationCenter.default.post(
            name: .souveraMailFlagsChangedLocally,
            object: nil,
            userInfo: ["emailId": emailId, "keyword": keyword, "value": value]
        )
    }

    /// Führt die Aktion aus; true = erfolgreich.
    @MainActor
    static func run(actionIdentifier: String, account: String, emailId: String) async -> Bool {
        guard !account.isEmpty, !emailId.isEmpty else {
            SouveraLog.write("MailAction", "action \(actionIdentifier): account/emailId fehlen")
            return false
        }
        // Credential sicherstellen (Kaltstart aus der Meldung heraus).
        guard let credential = await SouveraMailCredentialManager().ensureCombinedCredential(account: account) else {
            SouveraLog.write("MailAction", "action \(actionIdentifier): kein Credential")
            return false
        }
        let client = JmapClient(baseUrl: credential.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                                username: credential.saslUser,
                                password: credential.mailPassword)
        let api = JmapApi(client: client)
        do {
            let session = try await client.refreshSession()
            let accId = session.primaryAccountId
            // Kanonische Id (Push-Id = Kurzform, P62e); ohne Auflösung
            // Fallback auf die Push-Id, damit die Aktion versucht wird.
            let canonical = await resolveCanonicalEmailId(api: api, accountId: accId, emailId: emailId) ?? emailId
            // Run 01.10. (Regression gegen Mail-Kaskaden): eine Mail-Aktion
            // betrifft IMMER genau eine Mail - anders als die raumweite
            // Talk-Kaskade. Der Helper dokumentiert/absichert das.
            let targetIds = Self.targetEmailIds(canonicalId: canonical)
            switch actionIdentifier {
            case AppDelegate.mailMarkReadAction:
                _ = try await api.setEmailFlags(accountId: accId, emailIds: targetIds,
                                                keywordsToAdd: ["$seen": true])
                await mirrorLocally(emailId: canonical, keyword: "$seen", value: true)
            case AppDelegate.mailMarkFlaggedAction:
                _ = try await api.setEmailFlags(accountId: accId, emailIds: targetIds,
                                                keywordsToAdd: ["$seen": true, "$flagged": true])
                await mirrorLocally(emailId: canonical, keyword: "$seen", value: true)
                await mirrorLocally(emailId: canonical, keyword: "$flagged", value: true)
            case AppDelegate.mailDeleteAction:
                // Wie die Swipe-Löschung (performDelete): in den Papierkorb
                // des Accounts verschieben (wiederherstellbar); nur ohne
                // Trash-Ordner endgültig löschen.
                let boxes = try await api.getMailboxes(accountId: accId)
                let trashJmapId = boxes
                    .map { JmapMapper.mapMailbox(account: account, accountId: accId, json: $0) }
                    .first(where: { $0.kind == .trash })?.jmapId
                if let trashJmapId, !trashJmapId.isEmpty {
                    _ = try await api.moveEmails(accountId: accId, emailIds: targetIds,
                                                 targetMailboxId: trashJmapId)
                } else {
                    _ = try await api.deleteEmails(accountId: accId, emailIds: targetIds)
                }
            default:
                return false
            }
            SouveraLog.write("MailAction", "action \(actionIdentifier) ok emailId=\(canonical)")
            // Run 27.09. (Crash 0xdead10cc): Der Badge-Refresh postet
            // synchron Notifications, deren Observer Main-Thread-Realm-
            // Reads ausführen - im Hintergrund kann iOS die App genau
            // dabei suspendieren (Realm-File-Lock) und killen. Der Badge
            // wird beim nächsten Foreground-Wechsel ohnehin nachgezogen.
            if UIApplication.shared.applicationState == .active {
                await SouveraBackgroundSync.shared.refreshMailBadge()
            }
            return true
        } catch {
            SouveraLog.write("MailAction", "action \(actionIdentifier) FAILED: \(error.localizedDescription)")
            return false
        }
    }
}

extension Notification.Name {
    /// Push-Aktion hat den Flag serverseitig gesetzt - die offene App
    /// spiegelt den Stand sofort lokal (Zeile/Badge/Cache).
    static let souveraMailFlagsChangedLocally = Notification.Name("souveraMailFlagsChangedLocally")
}
