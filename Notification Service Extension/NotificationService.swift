//
//  NotificationService.swift
//  Notification Service Extension
//
//  Created by Ivan Sein on 30.01.20.
//  Author Ivan Sein <ivan@nextcloud.com>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import UIKit
import UserNotifications
import NextcloudKit

class NotificationService: UNNotificationServiceExtension {
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?
    var request: UNNotificationRequest?

    /// Run 22.09. (Push-Diagnose): Zeitstempel + verstrichene Millisekunden
    /// in die App-Group-Logs schreiben, damit der App-Log die NSE-Eingangs-
    /// und Auslieferungszeit zeigt (bisher wurde nur der Kopierzeitpunkt
    /// geloggt, nicht die Push-Ankunft).
    static let nseStart = Date()

    static func nseStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    static func nseMs(since: Date) -> Int {
        Int(Date().timeIntervalSince(since) * 1000)
    }

    static func nseAppend(_ text: String, key: String, limit: Int = 12000) {
        guard let d = UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup) else { return }
        var logText = d.string(forKey: key) ?? ""
        logText += text + "|"
        if logText.count > limit { logText = String(logText.suffix(limit)) }
        d.set(logText, forKey: key)
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.request = request
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        NextcloudKit.configureLogger(logLevel: .verbose)

        let nseStart = Self.nseStart
        let arrivalKeys = (bestAttemptContent?.userInfo ?? [:]).keys.map { String(describing: $0) }.sorted().joined(separator: ",")
        Self.nseAppend("t=\(Self.nseStamp()) phase=arrival keys=[\(arrivalKeys)]",
                       key: "souvera_mail_push_timing_log")

        // P66d: Roh-Payload JEDES Pushs loggen (Keys + Werte, gekürzt) -
        // die Mail-Push-Feldstruktur ist serverseitig unbekannt; dieser
        // Log deckt sie auf.
        if let groupDefaults = UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup) {
            let userInfo = bestAttemptContent?.userInfo ?? [:]
            let alert = userInfo["aps"] as? [String: Any]
            let alertDict = alert?["alert"] as? [String: Any]
            var raw = "keys=[\(userInfo.keys.map { String(describing: $0) }.sorted().joined(separator: ","))]"
            raw += " alertTitle=\((alertDict?["title"] as? String) ?? "")"
            raw += " alertBody=\((alertDict?["body"] as? String) ?? "")"
            raw += " apsSound=\((alert?["sound"] as? String) ?? (alert?["sound"] != nil ? "<dict>" : "-"))"
            for key in ["emailId", "mailId", "objectId", "id", "nid", "type", "app"] {
                if let value = userInfo[key] {
                    let text = String(describing: value).prefix(40)
                    raw += " \(key)=\(text)"
                }
            }
            let key = "souvera_mail_push_raw_log"
            var logText = (groupDefaults.string(forKey: key)) ?? ""
            logText += raw + "|"
            if logText.count > 20000 {
                logText = String(logText.suffix(20000))
            }
            groupDefaults.set(logText, forKey: key)
        }
        if let bestAttemptContent = bestAttemptContent {
            bestAttemptContent.title = ""
            bestAttemptContent.body = "Souvera notification"
            do {
                if let message = bestAttemptContent.userInfo["subject"] as? String {
                    for tableAccount in NCManageDatabase.shared.getAllTableAccount() {
                        guard let privateKey = NCPreferences().getPushNotificationPrivateKey(account: tableAccount.account) else {
                            bestAttemptContent.body = "Error retrieving private key for \(tableAccount.account)"
                            continue
                        }

                        guard let decryptedMessage = NCPushNotificationEncryption.shared().decryptPushNotification(message, withDevicePrivateKey: privateKey) else {
                            bestAttemptContent.body = "Error decryption for \(tableAccount.account)"
                            nkLog(tag: NCGlobal.shared.logTagPN, emoji: .error, message: "Failed to decrypt push payload for \(tableAccount.account)")
                            continue
                        }
                        guard let data = decryptedMessage.data(using: .utf8) else {
                            bestAttemptContent.body = "Error decryption data utf8 for \(tableAccount.account)"
                            continue
                        }

                        if var json = try JSONSerialization.jsonObject(with: data) as? [String: AnyObject],
                           let subject = json["subject"] as? String {
                            // P70-Filter (Sicherheitsnetz): Gruppe abgeschaltet
                            // -> Push ohne Inhalt unterdrücken, bis die
                            // Server-Zeile entfernt ist.
                            let pushDefaults = UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup)
                            let appName = json["app"] as? String ?? ""
                            let objectType = json["objectType"] as? String ?? ""
                            var suppressed = false
                            if appName == "souvera_mail" || objectType == "souvera_mail" {
                                // Multi-Account: Toggle pro Account (Key + Account).
                                if pushDefaults?.object(forKey: "souvera_push_mail_calendar_enabled_" + tableAccount.account) as? Bool == false {
                                    suppressed = true
                                    nkLog(tag: NCGlobal.shared.logTagPN, emoji: .info, message: "Mail push suppressed by user toggle")
                                }
                            }
                            if appName == "spreed" || appName == "talk" {
                                if pushDefaults?.object(forKey: "souvera_push_link_talk_enabled_" + tableAccount.account) as? Bool == false {
                                    suppressed = true
                                    nkLog(tag: NCGlobal.shared.logTagPN, emoji: .info, message: "Talk push suppressed by user toggle")
                                } else {
                                    // App im Hintergrund: der Prozess sieht den
                                    // Push nicht selbst - Flag für den nächsten
                                    // Vordergrund (Liste/Badge auffrischen).
                                    pushDefaults?.set(true, forKey: "souvera_link_refresh_needed")
                                }
                            }
                            if suppressed {
                                // Übergang bis die Server-Zeile entfernt ist:
                                // ohne Inhalt anzeigen.
                                bestAttemptContent.title = ""
                                bestAttemptContent.body = ""
                            } else {
                                // P66d: Payload-Diagnose + Anreicherung.
                                let groupDefaults = UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup)
                                if let jsonData = try? JSONSerialization.data(withJSONObject: json),
                                   let jsonText = String(data: jsonData, encoding: .utf8) {
                                    let key = "souvera_mail_push_payload_log"
                                    var logText = (groupDefaults?.string(forKey: key)) ?? ""
                                    logText += jsonText + "|"
                                    if logText.count > 20000 {
                                        logText = String(logText.suffix(20000))
                                    }
                                    groupDefaults?.set(logText, forKey: key)
                                }
                                let objectId = (json["objectId"] as? String)
                                    ?? (json["emailId"] as? String)
                                    ?? (json["mailId"] as? String)
                                    ?? (json["id"] as? String)
                                    ?? ""
                                let isMailPush = (appName == "souvera_mail" || objectType == "souvera_mail")
                                // Run 19.09.: Kalender-Pushes fuer die
                                // timeSensitive-Markierung erkennen.
                                let isCalendarPush = (appName == "souvera_calendar" || objectType == "souvera_calendar")
                                // P62g: Mail-Push -> Flag für den nächsten
                                // Modul-Eintritt setzen (Refresh auch ohne
                                // Tap auf die Notification).
                                if isMailPush {
                                    UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup)?.set(true, forKey: "souvera_mail_refresh_needed")
                                }
                                // Titel (fett) = subject (z. B. Absender bei
                                // Mail-Pushes), Body = message (z. B. Betreff).
                                var title = subject
                                let message = json["message"] as? String
                                var body = (message != nil && !message!.isEmpty) ? message! : subject
                                // P68y: NUR bei generischen/leeren Server-Texten
                                // Absender/Betreff selbst laden. Vorher wurde die
                                // Anreicherung immer vom title=subject überschrieben
                                // (toter Code) - der Fallback griff nie.
                                if isMailPush, !objectId.isEmpty,
                                   (title.isEmpty || title == "Neue E-Mail" || body.isEmpty || body == "Du hast eine neue Nachricht erhalten") {
                                    let semaphore = DispatchSemaphore(value: 0)
                                    var enrichResult = "skipped"
                                    Task {
                                        let enriched = await MailPushEnricher.shared.enrich(
                                            root: tableAccount.urlBase,
                                            ncUser: tableAccount.user,
                                            ncPassword: NCPreferences().getPassword(account: tableAccount.account),
                                            objectId: objectId
                                        )
                                        if let enriched {
                                            title = enriched.title
                                            body = enriched.body
                                            enrichResult = "ok"
                                        } else {
                                            enrichResult = "fallback"
                                        }
                                        semaphore.signal()
                                    }
                                    // Run 22.09. (Push-Verzoegerung): Kurzes
                                    // Budget statt 8 s - der Banner soll
                                    // sofort erscheinen; laeuft die Anreicherung
                                    // nicht in 1,5 s durch, wird der vorhandene
                                    // (generische) Text sofort ausgeliefert.
                                    let enrichStart = Date()
                                    let waited = semaphore.wait(timeout: .now() + 1.5)
                                    let enrichMs = Self.nseMs(since: enrichStart)
                                    Self.nseAppend("t=\(Self.nseStamp()) phase=enrich objectId=\(objectId.prefix(12)) result=\(enrichResult) completed=\(waited == .success) wait_ms=\(enrichMs)",
                                                   key: "souvera_mail_push_timing_log")
                                }
                                bestAttemptContent.title = title
                                bestAttemptContent.body = body
                                // Sound explizit setzen: Der Proxy-Payload
                                // enthält keinen sound-Eintrag - ohne diesen
                                // Wert bleibt die Benachrichtigung stumm
                                // (Feedback 05.09.). Nur bei echtem Inhalt.
                                bestAttemptContent.sound = UNNotificationSound.default
                                // Run 26.09. (Feedback: Mail-Aktionen + keine
                                // Doppel-Meldungen): Kategorie fuer die
                                // Long-Press-Aktionen + E-Mail-Id/Konto in die
                                // userInfo (Tap-Route, Dedupe gegen lokale
                                // Hintergrund-Meldungen).
                                if isMailPush {
                                    bestAttemptContent.categoryIdentifier = "souvera_mail_actions"
                                    bestAttemptContent.userInfo["emailId"] = objectId
                                    bestAttemptContent.userInfo["account"] = tableAccount.account
                                }
                                // Run 19.09.: Mail-/Kalender-Pushes NICHT von
                                // Fokus/Mitteilungszusammenfassung verzögern
                                // lassen (Talk/Admin/Deck unverändert).
                                if isMailPush || isCalendarPush {
                                    bestAttemptContent.interruptionLevel = .timeSensitive
                                }
                                // Link-Push: Raum-Token (json["id"] = Raum-
                                // token) + Konto in die userInfo - die App
                                // unterdrückt damit Banner für den AKTUELL
                                // geöffneten Raum (Run-Feedback 12.09.).
                                if appName == "spreed" || appName == "talk", !objectId.isEmpty {
                                    bestAttemptContent.userInfo["token"] = objectId
                                    bestAttemptContent.userInfo["account"] = tableAccount.account
                                }
                                if let pref = UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup) {
                                    json["account"] = tableAccount.account as AnyObject
                                    pref.set(json, forKey: "NOTIFICATION_DATA")
                                    pref.synchronize()
                                }
                            }
                        } else {
                            bestAttemptContent.body = "Error JSON Serialization for  \(tableAccount.account)"
                        }
                        break
                    }
                }
            } catch let error as NSError {
                nkLog(error: "Failed : \(error.localizedDescription)")
            }

            // P66d: Legacy-Direktpfad (unverschlüsselt, emailId im Payload) -
            // ebenfalls anreichern (Absender/Betreff) statt generischer Texte.
            let legacyEmailId = (bestAttemptContent.userInfo["emailId"] as? String)
                ?? (bestAttemptContent.userInfo["mailId"] as? String)
                ?? (bestAttemptContent.userInfo["objectId"] as? String)
                ?? (bestAttemptContent.userInfo["id"] as? String)
                ?? ""
            if bestAttemptContent.userInfo["subject"] as? String == nil,
               !legacyEmailId.isEmpty,
               let tableAccount = NCManageDatabase.shared.getActiveTableAccount() {
                let semaphore = DispatchSemaphore(value: 0)
                var enrichResult = "skipped"
                Task {
                    let enriched = await MailPushEnricher.shared.enrich(
                        root: tableAccount.urlBase,
                        ncUser: tableAccount.user,
                        ncPassword: NCPreferences().getPassword(account: tableAccount.account),
                        objectId: legacyEmailId
                    )
                    if let enriched {
                        bestAttemptContent.title = enriched.title
                        bestAttemptContent.body = enriched.body
                        enrichResult = "ok"
                    } else {
                        enrichResult = "fallback"
                    }
                    semaphore.signal()
                }
                let enrichStart = Date()
                let waited = semaphore.wait(timeout: .now() + 1.5)
                let enrichMs = Self.nseMs(since: enrichStart)
                Self.nseAppend("t=\(Self.nseStamp()) phase=enrich-legacy emailId=\(legacyEmailId.prefix(12)) result=\(enrichResult) completed=\(waited == .success) wait_ms=\(enrichMs)",
                               key: "souvera_mail_push_timing_log")
            }

            Self.nseAppend("t=\(Self.nseStamp()) phase=deliver total_ms=\(Self.nseMs(since: nseStart))",
                           key: "souvera_mail_push_timing_log")
            contentHandler(bestAttemptContent)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // iOS beendet die Extension (~30 s). Statt einer englischen
        // Fehlermeldung den BESTEN vorhandenen Inhalt ausliefern (Run 22.09.
        // - der Banner ist wichtiger als ein Technik-Text; mit dem neuen
        // 1,5-s-Budget wird dieser Pfad praktisch nie erreicht).
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            Self.nseAppend("t=\(Self.nseStamp()) phase=expire total_ms=\(Self.nseMs(since: Self.nseStart))",
                           key: "souvera_mail_push_timing_log")
            contentHandler(bestAttemptContent)
        }
    }
}
