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
        // Mail-/Kalender-/Files-/Admin-Benachrichtigungen. Talk (Chat UND
        // Calls) läuft serverseitig über das TALK-Gerät (apptype=talk,
        // kombiniertes Token) - das übernimmt LinkVoIPManager.
        // Registrierung tolerant: 2xx = Erfolg (der Proxy antwortet mit
        // leerem Body, was NextcloudKit als Fehler wertet).
        let normalToken = preferences.deviceTokenPushNotification
        let proxyOk = await SouveraPushRegistrar.registerAtProxy(proxyServerUrl: proxyServerUrl,
                                                                 pushToken: normalToken,
                                                                 deviceIdentifier: deviceIdentifier,
                                                                 signature: signature,
                                                                 publicKey: subscribingPublicKey,
                                                                 account: account,
                                                                 channel: "normal")
        guard proxyOk else {
            nkLog(tag: self.global.logTagPN, emoji: .error, message: "Push proxy registration FAILED at \(proxyServerUrl)")
            UserDefaults.standard.set("failed proxy \(Date())", forKey: "SouveraPushRegStatusNormal")
            SouveraLog.write("Push", "proxy registration FAILED \(proxyServerUrl)")
            return
        }

        nkLog(tag: self.global.logTagPN, emoji: .success, message: "Push proxy registration OK at \(proxyServerUrl)")
        UserDefaults.standard.set("ok \(Date())", forKey: "SouveraPushRegStatusNormal")
        // Churn-Merker: komplette Re-Registrierung nur bei Zustandsänderung.
        UserDefaults.standard.set(NCPreferences().deviceTokenPushNotification,
                                  forKey: Self.pushRegStateKey(account))
        SouveraLog.write("Push", "proxy registration OK \(proxyServerUrl)")

        preferences.setPushNotificationDeviceIdentifier(account: account, deviceIdentifier: deviceIdentifier)
        preferences.setPushNotificationDeviceIdentifierSignature(account: account, deviceIdentifierSignature: signature)
        preferences.setPushNotificationSubscribingPublicKey(account: account, publicKey: subscribingPublicKey)
    }

    /// Multi-Account (Variante 1): Ein APNs-Token kann am Push-Proxy nur
    /// EINEM Account gehören. Deshalb bekommt NUR der AKTIVE Account Push -
    /// alle anderen Accounts werden sauber abgemeldet (Server + Proxy, mit
    /// deren gespeichertem Key), bevor der aktive Account registriert wird.
    /// Das verhindert die 409-Konflikte und verspätete/verlorene Pushs für
    /// den aktiven Account.
    func reconcilePushForActiveAccount() async {
        guard let activeTbl = await NCManageDatabase.shared.getActiveTableAccountAsync() else { return }
        let active = activeTbl.account
        let accounts = await NCManageDatabase.shared.getAllTableAccountAsync()
        // 1. Inaktive Accounts abmelden (nur wenn eine Registrierung existiert).
        var unregisteredAny = false
        for tbl in accounts where tbl.account != active {
            if NCPreferences().getPushNotificationDeviceIdentifier(account: tbl.account) != nil {
                await unsubscribingNextcloudServerPushNotification(account: tbl.account, urlBase: tbl.urlBase)
                unregisteredAny = true
            }
        }
        // 2. Kurz warten, damit der Proxy das DELETE verarbeitet hat - sonst
        //    kollidiert der neue POST mit dem noch nicht entfernten alten
        //    Gerät (409).
        if unregisteredAny {
            try? await Task.sleep(for: .seconds(1))
        }
        // 3. Aktiven Account registrieren - aber NUR bei Zustandsänderung
        //    (Account neu, APNs-Token gewechselt oder vorheriger Lauf
        //    fehlgeschlagen). Sonst läuft bei jedem App-Start die komplette
        //    Server+Proxy-Registrierung (Churn -> Stale-Zeilen-Gefahr).
        let apnsToken = NCPreferences().deviceTokenPushNotification
        if !apnsToken.isEmpty,
           UserDefaults.standard.string(forKey: Self.pushRegStateKey(active)) == apnsToken {
            SouveraLog.write("Push", "reconcile skipped for \(active): already registered (state unchanged)")
            return
        }
        await subscribingNextcloudServerPushNotification(account: activeTbl.account, urlBase: activeTbl.urlBase)
    }

    /// Merker "erfolgreich registriert": Account + gültiger APNs-Token.
    private static func pushRegStateKey(_ account: String) -> String {
        "souvera_push_reg_state_" + account
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
        // Churn-Merker ungültig machen: nach Abmeldung muss der Account
        // beim nächsten Mal vollständig neu registriert werden.
        UserDefaults.standard.removeObject(forKey: Self.pushRegStateKey(account))
        guard let deviceIdentifier = preferences.getPushNotificationDeviceIdentifier(account: account),
              let signature = preferences.getPushNotificationDeviceIdentifierSignature(account: account),
              let subscribingPublicKey = preferences.getPushNotificationSubscribingPublicKey(account: account) else {
            nkLog(tag: self.global.logTagPN, emoji: .debug, message: "Push deregistration skipped for \(urlBase): no active push subscription found")
            // Keine gespeicherte Subscription - trotzdem Vault-Einträge
            // dieses Accounts räumen (z. B. nach DB-Reset/Reinstall), damit
            // am Proxy keine Leichen des Geräts zurückbleiben.
            let proxyServerUrl = NCBrandOptions.shared.pushNotificationServerProxy
            for entry in SouveraPushCredentialVault.all() where entry.account == account {
                _ = await SouveraPushRegistrar.unregisterAtProxy(
                    proxyServerUrl: proxyServerUrl,
                    deviceIdentifier: entry.deviceIdentifier,
                    signature: entry.signature,
                    publicKey: entry.publicKey,
                    channel: entry.channel
                )
            }
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
            SouveraPushCredentialVault.remove(deviceIdentifier: deviceIdentifier, channel: "normal")
        } else {
            nkLog(tag: self.global.logTagPN, emoji: .error, message: "Push proxy deregistration FAILED at \(proxyServerUrl), status \(responseProxy.error.errorCode): \(responseProxy.error.errorDescription)")
            // NCK-DELETE fehlgeschlagen: best-effort über den eigenen
            // Registrar + historische Vault-Keys (dieselben Endpunkte),
            // damit beim Logout keine stale Zeilen zurückbleiben.
            _ = await SouveraPushRegistrar.unregisterAtProxy(proxyServerUrl: proxyServerUrl,
                                                             deviceIdentifier: deviceIdentifier,
                                                             signature: signature,
                                                             publicKey: subscribingPublicKey,
                                                             channel: "normal")
            for entry in SouveraPushCredentialVault.all() where entry.deviceIdentifier == deviceIdentifier {
                _ = await SouveraPushRegistrar.unregisterAtProxy(proxyServerUrl: proxyServerUrl,
                                                                 deviceIdentifier: entry.deviceIdentifier,
                                                                 signature: entry.signature,
                                                                 publicKey: entry.publicKey,
                                                                 channel: entry.channel)
            }
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
                            } else {
                                // Talk-Push im laufenden Prozess empfangen:
                                // Link-Übersicht + Badge sofort auffrischen
                                // (Realtime ohne 20s-Poll-Wartezeit).
                                let app = jsonObject["app"] as? String ?? ""
                                if app == "spreed" || app == "talk" || app == "admin_notification_talk" {
                                    SouveraLog.write("Push", "link push received (fg/bg) app=\(app) nid=\(nid ?? -1) - refreshing conversations")
                                    NotificationCenter.default.post(name: .linkConversationsReloadRequested, object: nil)
                                }
                                // Vordergrund: iOS spielt keinen System-Sound -
                                // dezenter In-App-Hinweiston (.ambient, respektiert
                                // den Klingelschalter).
                                SouveraForegroundTone.shared.playIfForeground()
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
