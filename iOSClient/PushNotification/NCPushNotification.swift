// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2024 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UIKit
import UserNotifications
import NextcloudKit

class NCPushNotification {
    static let shared = NCPushNotification()
    let global = NCGlobal.shared

    func subscribingNextcloudServerPushNotification(account: String, urlBase: String) async {
        let preferences = NCPreferences()
        let proxyServerUrl = NCBrandOptions.shared.pushNotificationServerProxy
        // P68z: NIE mit leerem APNs-Token registrieren - sonst entsteht am
        // NC-Server/Proxy eine Gerätezeile mit SHA512("") und Mail/Chat-Push
        // kommt nie an (nach Reinstall kommt der Token teils verspätet).
        guard !preferences.deviceTokenPushNotification.isEmpty else {
            nkLog(tag: self.global.logTagPN, emoji: .error, message: "Push subscription skipped for \(urlBase): no APNs token available yet")
            SouveraLog.write("Push", "NC registration skipped \(urlBase): no APNs token")
            return
        }
        guard !proxyServerUrl.isEmpty,
              let pushTokenHash = NCEndToEndEncryption.shared().createSHA512(preferences.deviceTokenPushNotification) else {
            nkLog(tag: self.global.logTagPN, emoji: .error, message: "Push proxy registration skipped for \(urlBase): no push proxy URL configured or no APNs token available")
            return
        }

        nkLog(tag: self.global.logTagPN, emoji: .start, message: "Registering push notifications for \(urlBase) using proxy \(proxyServerUrl)")

        var privateKey = preferences.getPushNotificationPrivateKey(account: account)
        var publicKey = preferences.getPushNotificationPublicKey(account: account)

        if privateKey == nil || publicKey == nil {
            guard let keyPair = NCPushNotificationEncryption.shared().generatePushNotificationsKeyPair() else {
                return
            }
            privateKey = keyPair.privateKey
            publicKey = keyPair.publicKey

            preferences.setPushNotificationPrivateKey(account: account, data: privateKey)
            preferences.setPushNotificationPublicKey(account: account, data: publicKey)
        }

        guard privateKey != nil,
              let publicKey,
              let devicePublicKey = String(data: publicKey, encoding: .utf8) else {
            return
        }

        let responsePN = await subscribePushNotification(serverUrl: urlBase,
                                                         pushTokenHash: pushTokenHash,
                                                         devicePublicKey: devicePublicKey,
                                                         proxyServerUrl: proxyServerUrl,
                                                         account: account)

        guard let responsePN else {
            nkLog(tag: self.global.logTagPN, emoji: .error, message: "Nextcloud instance push registration FAILED for \(urlBase)")
            UserDefaults.standard.set("failed NC \(Date())", forKey: "SouveraPushRegStatusNormal")
            SouveraLog.write("Push", "NC registration FAILED \(urlBase)")
            return
        }
        let deviceIdentifier = responsePN.deviceIdentifier
        let signature = responsePN.signature
        let subscribingPublicKey = responsePN.publicKey

        nkLog(tag: self.global.logTagPN, emoji: .success, message: "Nextcloud instance push registration OK for \(urlBase) (proxyServer=\(proxyServerUrl))")
        SouveraLog.write("Push", "NC registration OK \(urlBase)")

        // KANAL-TRENNUNG: Diese Registrierung läuft als Nextcloud-Client
        // (apptype=nextcloud) mit dem REINEN Normal-Token - sie bekommt
        // Mail-/Chat-/Admin-Benachrichtigungen. Die Talk-Registrierung
        // (kombiniertes Token, VoIP) übernimmt LinkVoIPManager.
        // Registrierung tolerant: 2xx = Erfolg (der Proxy antwortet mit
        // leerem Body, was NextcloudKit als Fehler wertet).
        let normalToken = preferences.deviceTokenPushNotification
        let proxyOk = await SouveraPushRegistrar.registerAtProxy(proxyServerUrl: proxyServerUrl,
                                                                 pushToken: normalToken,
                                                                 deviceIdentifier: deviceIdentifier,
                                                                 signature: signature,
                                                                 publicKey: subscribingPublicKey)
        guard proxyOk else {
            nkLog(tag: self.global.logTagPN, emoji: .error, message: "Push proxy registration FAILED at \(proxyServerUrl)")
            UserDefaults.standard.set("failed proxy \(Date())", forKey: "SouveraPushRegStatusNormal")
            SouveraLog.write("Push", "proxy registration FAILED \(proxyServerUrl)")
            return
        }

        nkLog(tag: self.global.logTagPN, emoji: .success, message: "Push proxy registration OK at \(proxyServerUrl)")
        UserDefaults.standard.set("ok \(Date())", forKey: "SouveraPushRegStatusNormal")
        SouveraLog.write("Push", "proxy registration OK \(proxyServerUrl)")

        preferences.setPushNotificationDeviceIdentifier(account: account, deviceIdentifier: deviceIdentifier)
        preferences.setPushNotificationDeviceIdentifierSignature(account: account, deviceIdentifierSignature: signature)
        preferences.setPushNotificationSubscribingPublicKey(account: account, publicKey: subscribingPublicKey)
    }

    /// P68y: Abonniert Push am NC-Server und wiederholt bei -1000
    /// (NSURLErrorBadURL = NextcloudKit .urlError). Der NCK-Call baut seine
    /// Request-URL aus der INTERNEN Session (nksessions.session(forAccount:)),
    /// nicht aus dem übergebenen serverUrl - rennt das Abo dem Session-Setup
    /// (App-Start/Sync) voraus, ist die Session noch nil -> -1000 und die
    /// Normal-Registrierung (Mail/Chat) fällt aus. Kurz warten + retry.
    private func subscribePushNotification(serverUrl: String,
                                           pushTokenHash: String,
                                           devicePublicKey: String,
                                           proxyServerUrl: String,
                                           account: String) async -> (deviceIdentifier: String, signature: String, publicKey: String)? {
        for attempt in 0..<3 {
            let response = await NextcloudKit.shared.subscribingPushNotificationAsync(
                serverUrl: serverUrl,
                pushTokenHash: pushTokenHash,
                devicePublicKey: devicePublicKey,
                proxyServerUrl: proxyServerUrl,
                account: account
            ) { task in
                Task {
                    let identifier = await NCNetworking.shared.networkingTasks.createIdentifier(account: account,
                                                                                                path: serverUrl,
                                                                                                name: "subscribingPushNotification")
                    await NCNetworking.shared.networkingTasks.track(identifier: identifier, task: task)
                }
            }

            if response.error == .success,
               let deviceIdentifier = response.deviceIdentifier,
               let signature = response.signature,
               let publicKey = response.publicKey {
                return (deviceIdentifier, signature, publicKey)
            }

            SouveraLog.write("Push", "NC registration attempt \(attempt + 1) failed \(serverUrl) status \(response.error.errorCode): \(response.error.errorDescription)")
            if response.error.errorCode == NSURLErrorBadURL, attempt < 2 {
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            return nil
        }
        return nil
    }

    func unsubscribingNextcloudServerPushNotification(account: String, urlBase: String) async {
        let preferences = NCPreferences()
        guard let deviceIdentifier = preferences.getPushNotificationDeviceIdentifier(account: account),
              let signature = preferences.getPushNotificationDeviceIdentifierSignature(account: account),
              let subscribingPublicKey = preferences.getPushNotificationSubscribingPublicKey(account: account) else {
            nkLog(tag: self.global.logTagPN, emoji: .debug, message: "Push deregistration skipped for \(urlBase): no active push subscription found")
            return
        }

        let responsePN = await NextcloudKit.shared.unsubscribingPushNotificationAsync(serverUrl: urlBase,
                                                                                      account: account) { task in
            Task {
                let identifier = await NCNetworking.shared.networkingTasks.createIdentifier(account: account,
                                                                                            path: urlBase,
                                                                                            name: "unsubscribingPushNotification")
                await NCNetworking.shared.networkingTasks.track(identifier: identifier, task: task)
            }
        }

        let userAgent = String(format: "%@  (Strict VoIP)", NCBrandOptions.shared.getUserAgent())
        let options = NKRequestOptions(customUserAgent: userAgent)
        let proxyServerUrl = NCBrandOptions.shared.pushNotificationServerProxy
        let responseProxy = await NextcloudKit.shared.unsubscribingPushProxyAsync(proxyServerUrl: proxyServerUrl,
                                                                                  deviceIdentifier: deviceIdentifier,
                                                                                  signature: signature,
                                                                                  publicKey: subscribingPublicKey,
                                                                                  account: account,
                                                                                  options: options) { task in
            Task {
                let identifier = await NCNetworking.shared.networkingTasks.createIdentifier(account: account,
                                                                                            path: NCBrandOptions.shared.pushNotificationServerProxy,
                                                                                            name: "unsubscribingPushProxy")
                await NCNetworking.shared.networkingTasks.track(identifier: identifier, task: task)
            }
        }

        if responsePN.error == .success {
            nkLog(tag: self.global.logTagPN, emoji: .success, message: "Nextcloud instance push deregistration OK for \(urlBase)")
        } else {
            nkLog(tag: self.global.logTagPN, emoji: .error, message: "Nextcloud instance push deregistration FAILED for \(urlBase), status \(responsePN.error.errorCode): \(responsePN.error.errorDescription)")
        }

        if responseProxy.error == .success {
            nkLog(tag: self.global.logTagPN, emoji: .success, message: "Push proxy deregistration OK at \(proxyServerUrl)")
        } else {
            nkLog(tag: self.global.logTagPN, emoji: .error, message: "Push proxy deregistration FAILED at \(proxyServerUrl), status \(responseProxy.error.errorCode): \(responseProxy.error.errorDescription)")
        }
    }

    func applicationdidReceiveRemoteNotification(userInfo: [AnyHashable: Any], completion: @escaping (_ result: UIBackgroundFetchResult) -> Void) {
        if let message = userInfo["subject"] as? String {
            for tblAccount in NCManageDatabase.shared.getAllTableAccount() {
                if let privateKey = NCPreferences().getPushNotificationPrivateKey(account: tblAccount.account),
                   let decryptedMessage = NCPushNotificationEncryption.shared().decryptPushNotification(message, withDevicePrivateKey: privateKey),
                   let jsonData = decryptedMessage.data(using: .utf8) {
                    do {
                        if let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                            let nid = jsonObject["nid"] as? Int
                            let delete = jsonObject["delete"] as? Bool
                            let deleteAll = jsonObject["delete-all"] as? Bool
                            if let delete, delete, let nid {
                                removeNotificationWithNotificationId(nid, usingDecryptionKey: privateKey)
                            } else if let deleteAll, deleteAll {
                                cleanAllNotifications()
                            }
                        } else {
                            nkLog(tag: self.global.logTagPN, emoji: .error, message: "Failed to convert JSON data dictionary.")
                        }
                    } catch {
                        nkLog(tag: self.global.logTagPN, emoji: .error, message: "Failed to parsing JSON data dictionary.")
                    }
                }
            }
        }
        completion(UIBackgroundFetchResult.noData)
    }

    func removeNotificationWithNotificationId(_ notificationId: Int, usingDecryptionKey key: Data) {
        // Check in pending notifications
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            for request in requests {
                if let message = request.content.userInfo["subject"] as? String,
                   let decryptedMessage = NCPushNotificationEncryption.shared().decryptPushNotification(message, withDevicePrivateKey: key),
                   let jsonData = decryptedMessage.data(using: .utf8) {
                    do {
                        if let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                            let nid = jsonObject["nid"] as? Int
                            if nid == notificationId {
                                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [request.identifier])
                            }
                        } else {
                            nkLog(tag: self.global.logTagPN, emoji: .error, message: "Failed to convert JSON data dictionary.")
                        }
                    } catch {
                        nkLog(tag: self.global.logTagPN, emoji: .error, message: "Failed to parsing JSON data dictionary.")
                    }
                }
            }
        }
        // Check in delivered notifications
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            for notification in notifications {
                if let message = notification.request.content.userInfo["subject"] as? String,
                   let decryptedMessage = NCPushNotificationEncryption.shared().decryptPushNotification(message, withDevicePrivateKey: key),
                   let jsonData = decryptedMessage.data(using: .utf8) {
                    do {
                        if let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                            let nid = jsonObject["nid"] as? Int
                            if nid == notificationId {
                                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notification.request.identifier])
                            }
                        } else {
                            nkLog(tag: self.global.logTagPN, emoji: .error, message: "Failed to convert JSON data dictionary.")
                        }
                    } catch {
                        nkLog(tag: self.global.logTagPN, emoji: .error, message: "Failed to parsing JSON data dictionary.")
                    }
                }
            }
        }
    }

    func cleanAllNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
