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
        // KANAL-GUARD: Die Normal-Zeile darf NIEMALS mit einem kombinierten
        // Token ("raw voip") geschrieben werden - sonst ist der Mail-Kanal
        // am APNs tot (Talk hätte die Zeile übernommen). Im Fehlerfall
        // abbrechen und diagnostizieren statt die Zeile zu vergiften.
        let normalToken = preferences.deviceTokenPushNotification
        if normalToken.contains(" ") {
            SouveraLog.write("Push", "NORMAL registration ABORTED: deviceTokenPushNotification contains a COMBINED token (len=\(normalToken.count), prefix=\(normalToken.prefix(10))…)")
            UserDefaults.standard.set("failed combined-token guard \(Date())", forKey: "SouveraPushRegStatusNormal")
            return
        }
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
        // Merker = "<apnsToken>|<build>": nach jedem APP-UPDATE läuft EINMAL
        // die vollständige Registrierung - der NC-Server kann Gerätezeilen
        // zwischendurch löschen ("unknown by the push server"); ohne die
        // Build-Prüfung bliebe die Lücke unbemerkt ( iPad: Mail-Push tot,
        // Talk lebendig).
        UserDefaults.standard.set(
            "\(NCPreferences().deviceTokenPushNotification)|\(SouveraBuildInfo.buildNumber)",
            forKey: Self.pushRegStateKey(account))
        // Erfolgreiche Registrierung: 429-Cooldown aufheben.
        UserDefaults.standard.removeObject(forKey: Self.throttledKey + account)
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
        // In-Flight-Dedupe: didRegisterForRemoteNotifications und
        // changeAccount können fast gleichzeitig feuern - NUR EIN Durchlauf
        // je Zeit (sonst doppelte NC-Subscriptions -> Rate-Limit-429).
        guard await RegistrationFlight.shared.tryEnter("normal") else {
            SouveraLog.write("Push", "reconcile skipped: already running")
            return
        }
        await reconcilePushForActiveAccountLocked()
        await RegistrationFlight.shared.exit("normal")
    }

    /// Serialisiert Reconcile-Läufe (normal/voip) app-weit.
    private actor RegistrationFlight {
        static let shared = RegistrationFlight()
        private var running: Set<String> = []

        func tryEnter(_ key: String) -> Bool {
            guard !running.contains(key) else { return false }
            running.insert(key)
            return true
        }

        func exit(_ key: String) {
            running.remove(key)
        }
    }

    /// Flug-Guard für den VoIP-Reconcile (Aufruf aus LinkVoIPManager).
    func tryEnterVoipFlight() async -> Bool {
        await RegistrationFlight.shared.tryEnter("voip")
    }

    func exitVoipFlight() async {
        await RegistrationFlight.shared.exit("voip")
    }

    // MARK: 429-Cooldown (NC-Server-Rate-Limit)

    private static let throttledKey = "souvera_push_nc_429_"
    /// Wartezeit nach einer 429-Ablehnung, bevor wieder registriert wird.
    private static let throttleInterval: TimeInterval = 15 * 60

    static func markRegistrationThrottled(_ account: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970,
                                  forKey: throttledKey + account)
        SouveraLog.write("Push", "registration throttled for \(account): cooldown \(Int(throttleInterval / 60)) min")
    }

    static func registrationThrottleActive(_ account: String) -> Bool {
        guard let last = UserDefaults.standard.object(forKey: throttledKey + account) as? TimeInterval else {
            return false
        }
        let active = Date().timeIntervalSince1970 - last < throttleInterval
        if !active {
            UserDefaults.standard.removeObject(forKey: throttledKey + account)
        }
        return active
    }

    private func reconcilePushForActiveAccountLocked() async {
        guard let activeTbl = await NCManageDatabase.shared.getActiveTableAccountAsync() else { return }
        let active = activeTbl.account
        // Vault-Seeding: Registrierungen aus Builds OHNE Credential-Vault
        // nachtragen. Nur so kann die 409-Selbstheilung auch Alt-Zeilen
        // löschen (DELETE mit deren historischem Key).
        Self.seedVaultFromStoredCredentials()
        // MULTI-ACCOUNT: Inaktive Accounts werden NICHT mehr abgemeldet -
        // der Proxy erlaubt mehrere Zeilen pro Push-Token (cloudId-Cleanup
        // wirkt nur noch auf denselben Account). Beide Accounts behalten
        // Mail- und Talk-Push dauerhaft.
        // Aktiven Account registrieren - aber NUR bei Zustandsänderung
        // (Account neu, APNs-Token gewechselt oder vorheriger Lauf
        // fehlgeschlagen). Sonst läuft bei jedem App-Start die komplette
        // Server+Proxy-Registrierung (Churn -> Stale-Zeilen-Gefahr).
        let apnsToken = NCPreferences().deviceTokenPushNotification
        let regMarker = UserDefaults.standard.string(forKey: Self.pushRegStateKey(active))
        // Skip nur, wenn Token UND App-Build unverändert sind - nach einem
        // Update wird einmal vollständig neu registriert (heilt vom Server
        // gelöschte Gerätezeilen).
        if !apnsToken.isEmpty,
           regMarker == "\(apnsToken)|\(SouveraBuildInfo.buildNumber)" {
            SouveraLog.write("Push", "reconcile skipped for \(active): already registered (state unchanged)")
            return
        }
        // 429-Cooldown: nach einer Rate-Limit-Ablehnung erst wieder
        // registrieren, wenn das Fenster verstrichen ist.
        if Self.registrationThrottleActive(active) {
            SouveraLog.write("Push", "reconcile skipped for \(active): rate-limit cooldown active")
            return
        }
        await subscribingNextcloudServerPushNotification(account: activeTbl.account, urlBase: activeTbl.urlBase)
    }

    /// Merker "erfolgreich registriert": Account + gültiger APNs-Token.
    private static func pushRegStateKey(_ account: String) -> String {
        "souvera_push_reg_state_" + account
    }

    /// Übernimmt die pro Account gespeicherten Geräte-Credentials in den
    /// Keychain-Vault (idempotent) - macht Registrierungen aus Builds ohne
    /// Vault für die 409-Selbstheilung nutzbar.
    private static func seedVaultFromStoredCredentials() {
        let preferences = NCPreferences()
        for tbl in NCManageDatabase.shared.getAllTableAccount() {
            guard let id = preferences.getPushNotificationDeviceIdentifier(account: tbl.account),
                  let sig = preferences.getPushNotificationDeviceIdentifierSignature(account: tbl.account),
                  let pk = preferences.getPushNotificationSubscribingPublicKey(account: tbl.account) else { continue }
            SouveraPushCredentialVault.record(deviceIdentifier: id,
                                              signature: sig,
                                              publicKey: pk,
                                              account: tbl.account,
                                              channel: "normal")
        }
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
            // 429 = NC-Server-Rate-Limit: Cooldown-Merker setzen, damit
            // folgende Starts nicht weiter in das Limit laufen (sonst
            // bleibt Push dauerhaft tot).
            if response.error.errorCode == 429 {
                Self.markRegistrationThrottled(account)
            }
            // 5xx/Netz: kurz warten und erneut versuchen (bis zu 3 Anläufe) -
            // Wartungsfenster/Drosselung sind meist transient.
            let transient = response.error.errorCode == NSURLErrorBadURL
                || (500...599).contains(response.error.errorCode)
                || response.error.errorCode == -1009 // notConnected
                || response.error.errorCode == -1001 // timedOut
            if transient, attempt < 2 {
                try? await Task.sleep(for: .seconds(3))
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
