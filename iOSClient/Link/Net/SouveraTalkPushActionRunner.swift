// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 27.09.: Führt die Long-Press-Aktionen auf Link/Talk-Push-Meldungen
// aus - "Antworten" (System-TextInput, auch bei Kaltstart) und "Als
// gelesen markieren". Run 01.10. (Feedback): Die raumweite Kaskade beim
// "Gelesen" greift NUR, wenn die getappte Meldung die NEUESTE des Raums
// ist. Eine ältere Meldung wird nur EINZELN entfernt - der Server-Marker
// bleibt unberührt (Talk kennt keinen Einzel-Lesestatus mitten in der
// Liste). "Antworten" räumt weiterhin raumweit auf (bei Erfolg).

import Foundation
import UIKit
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

    /// Reiner Helfer (unit-testbar): Ist die getappte Meldung die NEUESTE
    /// des Raums? Bevorzugt die Server-`nid`; fehlt sie (Altnachrichten),
    /// entscheidet die Zustellzeit.
    static func isNewestNotification(tappedNid: Int?, tappedDate: Date,
                                     roomNotifications: [(nid: Int?, date: Date)]) -> Bool {
        let nids = roomNotifications.compactMap { $0.nid }
        if let tappedNid, let maxNid = nids.max() {
            return tappedNid >= maxNid
        }
        let maxDate = roomNotifications.map { $0.date }.max() ?? tappedDate
        return tappedDate >= maxDate
    }

    /// `nid` aus der userInfo (Int/NSNumber/String).
    static func nidValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
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
        guard !token.isEmpty else { return }
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
    @MainActor
    static func markRoomRead(account: String, token: String) async {
        guard !token.isEmpty else { return }
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
        // Push-Empfang, entprellt). Run 27.09. (Crash 0xdead10cc): nur im
        // Vordergrund - die Observer machen Main-Thread-Realm-Reads, im
        // Hintergrund holt der nächste Foreground-Wechsel nach.
        if UIApplication.shared.applicationState == .active {
            NotificationCenter.default.post(name: .linkConversationsReloadRequested, object: nil)
        }
    }

    /// "Antworten": Text senden und bei Erfolg raumweit aufräumen.
    @MainActor
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
        // Dasselbe raumweite Aufräumen wie bei "Gelesen" (Feedback: so
        // belassen - Antworten räumt weiterhin raumweit auf).
        await markRoomRead(account: account, token: token)
        await cleanupRoomNotifications(token: token)
        return true
    }

    /// "Als gelesen markieren":
    ///  - getappte Meldung = NEUESTE des Raums -> raumweite Kaskade
    ///    (Read-Marker auf die neueste Nachricht + alle Meldungen des
    ///    Raums entfernen),
    ///  - getappte Meldung = ÄLTERE -> nur diese EINE Meldung entfernen;
    ///    der Server-Marker bleibt unberührt.
    @MainActor
    @discardableResult
    static func runMarkRead(account: String, token: String, notificationIdentifier: String = "") async -> Bool {
        guard !account.isEmpty, !token.isEmpty else {
            SouveraLog.write("TalkAction", "markRead: account/token fehlen")
            return false
        }
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let roomNotes = delivered.filter {
            $0.request.content.categoryIdentifier == AppDelegate.talkCategoryIdentifier
                && ($0.request.content.userInfo["token"] as? String) == token
        }
        let tapped = roomNotes.first { $0.request.identifier == notificationIdentifier }
        let tappedDate = tapped?.date ?? Date()
        let tappedNid = tapped.flatMap { nidValue($0.request.content.userInfo["nid"]) }
        let infos: [(nid: Int?, date: Date)] = roomNotes.map {
            (nidValue($0.request.content.userInfo["nid"]), $0.date)
        }
        let newest = isNewestNotification(tappedNid: tappedNid, tappedDate: tappedDate,
                                          roomNotifications: infos)
        if newest {
            await markRoomRead(account: account, token: token)
            await cleanupRoomNotifications(token: token)
        } else {
            if !notificationIdentifier.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
            }
            SouveraLog.write("TalkAction", "markRead single (older notification) token=\(token)")
        }
        return true
    }
}
