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
// Run 10.11.: Das Aufräumen ist SELEKTIV - es werden nur Meldungen mit
// nid <= getappter nid entfernt. Der Payload enthält `nid` (NC-
// Notification-Id, vom NSE geschrieben), NICHT die Talk-Message-Id -
// eine Direktabbildung "Read-Marker bis getappte Meldung" ist deshalb
// nicht möglich; der Marker bleibt beim neuesten Stand der Seite. Eine
// getapte (ältere) Meldung berührt die anderen Meldungen des Stapels
// nicht mehr.

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

    /// Run 10.11. (selektiv): Entfernt Meldungen des Raums aus der
    /// Mitteilungszentrale. Mit `tappedNid` werden nur Meldungen mit
    /// nid <= tappedNid entfernt (die getapte Meldung und ältere) -
    /// neuere Meldungen des Stapels bleiben bestehen. Ohne `tappedNid`
    /// (z. B. Kaltstart ohne Identifier) gilt weiterhin das raumweite
    /// Aufräumen. Der NSE schreibt das Raum-Token in jede Talk-Meldung;
    /// Meldungen anderer Räume bleiben unberührt.
    static func cleanupRoomNotifications(token: String, tappedNid: Int? = nil) async {
        guard !token.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let matching = delivered.filter {
            $0.request.content.categoryIdentifier == AppDelegate.talkCategoryIdentifier
                && ($0.request.content.userInfo["token"] as? String) == token
        }
        guard !matching.isEmpty else { return }
        let toRemove: [UNNotification]
        if let tappedNid {
            // Selektiv: nur die getapte Meldung und ältere. Meldungen
            // ohne nid lassen sich nicht einordnen und bleiben stehen.
            toRemove = matching.filter {
                guard let nid = nidValue($0.request.content.userInfo["nid"]) else {
                    return false
                }
                return nid <= tappedNid
            }
        } else {
            toRemove = matching
        }
        guard !toRemove.isEmpty else {
            SouveraLog.write("TalkAction", "selective cleanup: nichts zu entfernen (tappedNid=\(tappedNid.map(String.init) ?? "-"))")
            return
        }
        center.removeDeliveredNotifications(withIdentifiers: toRemove.map { $0.request.identifier })
        if let tappedNid {
            SouveraLog.write("TalkAction", "selective cleanup: \(toRemove.count) von \(matching.count) Meldungen entfernt (nid<=\(tappedNid), token=\(token))")
        } else {
            SouveraLog.write("TalkAction", "room cleanup: \(matching.count) Meldungen entfernt (token=\(token))")
        }
    }

    /// Read-Marker raumweit auf die neueste Nachricht setzen.
    /// Run 10.11.: Der Payload liefert nur die NC-`nid`, nicht die Talk-
    /// Message-Id - der Marker bleibt deshalb auf dem neuesten Stand der
    /// Seite; das selektive Cleanup (nid <= tappedNid) stellt sicher,
    /// dass eine getapte Meldung nicht die anderen des Stapels entfernt.
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

    /// "Antworten": Text senden und bei Erfolg aufräumen. Run 10.11.:
    /// Das Aufräumen ist selektiv (nur Meldungen mit nid <= der getappten
    /// Meldung) - ohne Identifier fällt es auf das raumweite Verhalten
    /// zurück. Der Read-Marker bleibt auf dem neuesten Stand.
    @MainActor
    @discardableResult
    static func runReply(account: String, token: String, userText: String,
                         notificationIdentifier: String = "") async -> Bool {
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
        // Run 10.11.: Selektives Aufräumen wie bei "Gelesen" - die nid der
        // getapten Meldung begrenzt das Entfernen auf sie und ältere.
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let tappedNid = delivered
            .first { $0.request.identifier == notificationIdentifier }
            .flatMap { nidValue($0.request.content.userInfo["nid"]) }
        await markRoomRead(account: account, token: token)
        await cleanupRoomNotifications(token: token, tappedNid: tappedNid)
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
            // Run 10.11.: Selektiv aufräumen - bei der neuesten Meldung
            // sind das alle (nid <= tappedNid), ohne den Marker ändern zu
            // müssen; ohne tappedNid greift das raumweite Verhalten.
            await cleanupRoomNotifications(token: token, tappedNid: tappedNid)
        } else {
            if !notificationIdentifier.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
            }
            SouveraLog.write("TalkAction", "markRead single (older notification) token=\(token)")
        }
        return true
    }
}
