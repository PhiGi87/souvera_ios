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

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.request = request
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        NextcloudKit.configureLogger(logLevel: .verbose)

        // P66d: Roh-Payload JEDES Pushs loggen (Keys + Werte, gekürzt) -
        // die Mail-Push-Feldstruktur ist serverseitig unbekannt; dieser
        // Log deckt sie auf.
        if let groupDefaults = UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup) {
            let userInfo = bestAttemptContent?.userInfo ?? [:]
            let alert = userInfo["aps"] as? [String: Any]
            let alertDict = alert?["alert"] as? [String: Any]
            var raw = "keys=[\(userInfo.keys.sorted().joined(separator: ","))]"
            raw += " alertTitle=\((alertDict?["title"] as? String) ?? "")"
            raw += " alertBody=\((alertDict?["body"] as? String) ?? "")"
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
                                if pushDefaults?.object(forKey: "souvera_push_mail_calendar_enabled") as? Bool == false {
                                    suppressed = true
                                    nkLog(tag: NCGlobal.shared.logTagPN, emoji: .info, message: "Mail push suppressed by user toggle")
                                }
                            }
                            if appName == "spreed" || appName == "talk" {
                                if pushDefaults?.object(forKey: "souvera_push_link_talk_enabled") as? Bool == false {
                                    suppressed = true
                                    nkLog(tag: NCGlobal.shared.logTagPN, emoji: .info, message: "Talk push suppressed by user toggle")
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
                                if appName == "souvera_mail" || objectType == "souvera_mail",
                                   !objectId.isEmpty {
                                    // Absender + Betreff selbst laden (der Server
                                    // liefert oft nur generische Texte).
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
                                            bestAttemptContent.title = enriched.title
                                            bestAttemptContent.body = enriched.body
                                            enrichResult = "ok"
                                        } else {
                                            enrichResult = "fallback"
                                        }
                                        semaphore.signal()
                                    }
                                    _ = semaphore.wait(timeout: .now() + 8)
                                    if let groupDefaults = UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup) {
                                        let key = "souvera_mail_push_enrich_log"
                                        var logText = (groupDefaults.string(forKey: key)) ?? ""
                                        logText += "objectId=\(objectId.prefix(12)) result=\(enrichResult)|"
                                        if logText.count > 10000 {
                                            logText = String(logText.suffix(10000))
                                        }
                                        groupDefaults.set(logText, forKey: key)
                                    }
                                }
                                // P62g: Mail-Push -> Flag für den nächsten
                                // Modul-Eintritt setzen (Refresh auch ohne
                                // Tap auf die Notification).
                                if appName == "souvera_mail" || objectType == "souvera_mail" {
                                    UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup)?.set(true, forKey: "souvera_mail_refresh_needed")
                                }
                                // Titel (fett) = subject (z. B. Absender bei
                                // Mail-Pushes), Body = message (z. B. Betreff).
                                bestAttemptContent.title = subject
                                if let message = json["message"] as? String, !message.isEmpty {
                                    bestAttemptContent.body = message
                                } else {
                                    bestAttemptContent.body = subject
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
                _ = semaphore.wait(timeout: .now() + 8)
                if let groupDefaults = UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup) {
                    let key = "souvera_mail_push_enrich_log"
                    var logText = (groupDefaults.string(forKey: key)) ?? ""
                    logText += "legacy emailId=\(legacyEmailId.prefix(12)) result=\(enrichResult)|"
                    if logText.count > 10000 {
                        logText = String(logText.suffix(10000))
                    }
                    groupDefaults.set(logText, forKey: key)
                }
            }

            contentHandler(bestAttemptContent)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            bestAttemptContent.title = ""
            bestAttemptContent.body = "Souvera Notification Time Will Expire"
            contentHandler(bestAttemptContent)
        }
    }
}
