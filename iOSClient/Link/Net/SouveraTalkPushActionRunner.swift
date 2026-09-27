// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 27.09.: Führt die Long-Press-Aktionen auf Link/Talk-Push-Meldungen
// aus - "Antworten" (System-TextInput, auch bei Kaltstart) und "Als
// gelesen markieren". Beide räumen raumweit auf: der Read-Marker wird
// auf die NEUESTE Nachricht des Raums gesetzt (alle vorigen ungelesenen
// sind damit serverseitig gelesen) und ALLE Meldungen des Raums
// verschwinden aus der Mitteilungszentrale.

import Foundation
import UserNotifications

enum SouveraTalkPushActionRunner {

    /// Anchor für den Live-Fetch der neuesten Seite (wie LinkViewModel).
    private static let historyAnchor: Int64 = 2_000_000_000

    /// Reiner Helfer (unit-testbar): höchste messageId der Seite - der
    /// Read-Marker wird auf sie gesetzt, damit alle vorigen Nachrichten
    /// des Raums mitgelesen werden.
    static func latestMessageId(in messages: [LinkChatMessage]) -> Int64? {
        messages.map(\.id).max()
    }

    /// Account aus der Push-Meldung auflösen (auch im Kaltstart).
    static func resolveAccount(_ account: String) -> LinkAccount? {
        guard let tbl = NCManageDatabase.shared.getTableAccount(predicate: NSPredicate(format: "account == %@", account)) else {
            return nil
        }
        return LinkAccount.from(account: tbl.account, urlBase: tbl.urlBase, user: tbl.user)
    }

    /// Entfernt ALLE Meldungen des Raums aus der Mitteilungszentrale
    /// (der NSE schreibt das Raum-Token in jede Talk-Meldung; Meldungen
    /// anderer Räume bleiben unberührt).
    static func cleanupRoomNotifications(token: String) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let matching = delivered.filter {
            $0.request.content.categoryIdentifier == AppDelegate.talkCategoryIdentifier
                && ($0.request.content.userInfo["token"] as? String) == token
        }
        guard !matching.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: matching.map { $0.request.identifier })
        SouveraLog.write("TalkAction", "room cleanup: \(matching.count) Meldungen entfernt (token=\(token))")
    }

    /// Read-Marker raumweit auf die neueste Nachricht setzen.
    static func markRoomRead(account: String, token: String) async {
        guard let link = resolveAccount(account) else {
            SouveraLog.write("TalkAction", "markRoomRead: kein Account \(account)")
            return
        }
        let api = LinkOcsApi(account: link)
        let messages = await api.getMessages(token: token, lastKnownId: historyAnchor,
                                             future: false, timeoutSeconds: 10,
                                             saveCache: false) ?? []
        guard let latest = latestMessageId(in: messages) else {
            SouveraLog.write("TalkAction", "markRoomRead: keine Nachrichten in \(token)")
            return
        }
        await api.markRoomRead(token: token, lastReadMessage: latest)
        SouveraLog.write("TalkAction", "markRoomRead \(token) -> \(latest)")
        // Raum-Liste und Badge nachziehen (gleicher Mechanismus wie beim
        // Push-Empfang, entprellt).
        NotificationCenter.default.post(name: .linkConversationsReloadRequested, object: nil)
    }

    /// "Antworten": Text senden und bei Erfolg raumweit aufräumen.
    @discardableResult
    static func runReply(account: String, token: String, userText: String) async -> Bool {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !token.isEmpty, !text.isEmpty else {
            SouveraLog.write("TalkAction", "reply: account/token/text fehlen")
            return false
        }
        guard let link = resolveAccount(account) else {
            SouveraLog.write("TalkAction", "reply: kein Account \(account)")
            return false
        }
        let api = LinkOcsApi(account: link)
        let result = await api.sendMessage(token: token, message: text)
        guard result.ok || result.likelyCreated else {
            SouveraLog.write("TalkAction", "reply FAILED: http=\(result.httpCode)")
            return false
        }
        SouveraLog.write("TalkAction", "reply ok (http=\(result.httpCode)) token=\(token)")
        // Dasselbe raumweite Aufräumen wie bei "Gelesen".
        await markRoomRead(account: account, token: token)
        await cleanupRoomNotifications(token: token)
        return true
    }

    /// "Als gelesen markieren": raumweit lesen + aufräumen.
    @discardableResult
    static func runMarkRead(account: String, token: String) async -> Bool {
        guard !account.isEmpty, !token.isEmpty else {
            SouveraLog.write("TalkAction", "markRead: account/token fehlen")
            return false
        }
        await markRoomRead(account: account, token: token)
        await cleanupRoomNotifications(token: token)
        return true
    }
}
