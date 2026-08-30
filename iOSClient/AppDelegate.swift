// SPDX-FileCopyrightText: 2026 Host-On Service Provider GmbH (Souvera)
// SPDX-FileCopyrightText: 2014 Marino Faggiana [Start 04/09/14]
// SPDX-FileCopyrightText: 2021 Marino Faggiana [Swift 19/02/21]
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import BackgroundTasks
import NextcloudKit
import LocalAuthentication
import Firebase
import WidgetKit
import Queuer
import EasyTipView
import SwiftUI
import RealmSwift

class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var backgroundSessionCompletionHandler: (() -> Void)?
    var isUiTestingEnabled: Bool {
        return ProcessInfo.processInfo.arguments.contains("UI_TESTING")
    }
    var notificationSettings: UNNotificationSettings?

    var loginFlowV2Token = ""
    var loginFlowV2Endpoint = ""
    var loginFlowV2Login = ""

    let backgroundQueue = DispatchQueue(label: "eu.souvera.app.bgTaskQueue")
    let global = NCGlobal.shared

    var bgTask: UIBackgroundTaskIdentifier = .invalid
    var pushSubscriptionTask: Task<Void, Never>?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if isUiTestingEnabled {
            Task {
                await NCAccount().deleteAllAccounts()
            }
        }
        let utilityFileSystem = NCUtilityFileSystem()
        let utility = NCUtility()

        utilityFileSystem.createDirectoryStandard()
        utilityFileSystem.emptyTemporaryDirectory()
        utilityFileSystem.clearCacheDirectory("com.limit-point.LivePhoto")

        let versionSouveraiOS = String(format: NCBrandOptions.shared.textCopyrightNextcloudiOS, utility.getVersionBuild())

        NCAppVersionManager.shared.checkAndUpdateInstallState()
        NCSettingsBundleHelper.checkAndExecuteSettings(delay: 0)

        UserDefaults.standard.register(defaults: ["UserAgent": userAgent])

        if !NCPreferences().disableCrashservice, !NCBrandOptions.shared.disable_crash_service {
            FirebaseApp.configure()
        }

        NCBrandColor.shared.createUserColors()

        // Setup Networking
        //
        NextcloudKit.shared.setup(groupIdentifier: NCBrandOptions.shared.capabilitiesGroup,
                                  delegate: NCNetworking.shared)
        NCNetworking.shared.setupTransferDelegate()

        NextcloudKit.configureLogger(logLevel: (NCBrandOptions.shared.disable_log ? .disabled : NCPreferences().log))

        #if DEBUG
//      For the tags look NCGlobal LOG TAG

//      var black: [String] = []
//      black.append("NETWORKING TASKS")
//      NextcloudKit.configureLoggerBlacklist(blacklist: black)

//      var white: [String] = []
//      white.append("SYNC METADATA")
//      NextcloudKit.configureLoggerWhitelist(whitelist: white)
        #endif

        nkLog(start: "Start session with level \(NCPreferences().log) " + versionSouveraiOS)

        // Übergroße Log-Dateien einmalig aufs Limit trimmen (älteste zuerst).
        SouveraLog.trimStartupLogs()
        // Startup-Marker mit Build-Nummer in die Log-Datei (für alle
        // "Logs teilen"-Sendungen nachvollziehbar).
        SouveraLog.write("App-Start: \(SouveraBuildInfo.label) \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") | iOS \(UIDevice.current.systemVersion) | \(UIDevice.current.model)")

        // Push Notification & display notification
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            self.notificationSettings = settings
        }
        application.registerForRemoteNotifications()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }

        // Link (Talk) VoIP: register the PushKit token and present incoming calls via CallKit.
        LinkVoIPManager.shared.register()
        // Kalender-Erinnerungs-Töne einmalig generieren (Library/Sounds).
        SouveraToneSynthesizer.ensureAllGenerated()
        // P68y: FD-Diagnose periodisch loggen (0xdead10cc-FD-Leck sichtbar machen).
        SouveraFdDiagnostics.startPeriodicLogging()
        // P66d: In der Extension gesammelte Mail-Push-Payloads aus der
        // App-Gruppe loggen (Diagnose der Server-Feldstruktur).
        if let groupDefaults = UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup),
           let payloadLog = groupDefaults.string(forKey: "souvera_mail_push_payload_log"),
           !payloadLog.isEmpty {
            for entry in payloadLog.split(separator: "|") where !entry.isEmpty {
                SouveraLog.write("PushPayloadNSE", String(entry))
            }
            groupDefaults.removeObject(forKey: "souvera_mail_push_payload_log")
        }
        // P66d: Anreicherungs-Ergebnisse der Extension loggen.
        if let groupDefaults = UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup),
           let enrichLog = groupDefaults.string(forKey: "souvera_mail_push_enrich_log"),
           !enrichLog.isEmpty {
            for entry in enrichLog.split(separator: "|") where !entry.isEmpty {
                SouveraLog.write("PushEnrich", String(entry))
            }
            groupDefaults.removeObject(forKey: "souvera_mail_push_enrich_log")
        }
        NotificationCenter.default.addObserver(forName: .linkAnswerCall, object: nil, queue: .main) { notification in
            // Die Session startet LinkVoIPManager selbst (auch bei
            // gesperrtem Gerät); die Call-UI übernimmt der zentrale
            // Presenter (P68e) - nur im aktiven Vordergrund. Sonst
            // übernimmt der "In Souvera öffnen"-Flow nach dem Entsperren.
            guard UIApplication.shared.applicationState == .active else { return }
            LinkVoIPManager.shared.presentCallUIIfNeeded()
        }

#if !targetEnvironment(simulator)
        let review = NCStoreReview()
        review.incrementAppRuns()
        review.showStoreReview()
#endif

        BGTaskScheduler.shared.register(forTaskWithIdentifier: global.refreshTask, using: backgroundQueue) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleAppRefresh(appRefreshTask)
        }
        scheduleAppRefresh()

        BGTaskScheduler.shared.register(forTaskWithIdentifier: global.processingTask, using: backgroundQueue) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleProcessingTask(processingTask)
        }
        scheduleAppProcessing()

        if NCBrandOptions.shared.enforce_passcode_lock {
            NCPreferences().requestPasscodeAtStart = true
        }

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Frische BGTask-Planung beim Verlassen der App, damit der
        // Refresh-Rhythmus (Mail/Kalender/Link) im Hintergrund läuft.
        scheduleAppRefresh()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Laufenden Call sauber beenden (leaveCall), damit keine Geister-
        // Session im Raum zurückbleibt.
        LinkVoIPManager.shared.endActiveCall()
        // Hinweis "App laufen lassen" nur EINMAL zeigen (beim ersten Beenden
        // nach der Installation), danach nie wieder. Das Flag überlebt
        // App-Neustarts und wird bei einer Deinstallation automatisch
        // gelöscht - nach Neuinstallation erscheint der Hinweis wieder genau
        // einmal.
        if self.notificationSettings?.authorizationStatus != .denied && UIApplication.shared.backgroundRefreshStatus == .available,
           !UserDefaults.standard.bool(forKey: Self.keepRunningNotificationShownKey) {
            UserDefaults.standard.set(true, forKey: Self.keepRunningNotificationShownKey)
            let content = UNMutableNotificationContent()
            content.title = NCBrandOptions.shared.brand
            content.body = NSLocalizedString("_keep_running_", comment: "")
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            let notificationCenter = UNUserNotificationCenter.current()
            notificationCenter.add(req)
        }

        nkLog(debug: "App is terminating")
    }

    private static let keepRunningNotificationShownKey = "SouveraKeepRunningNotificationShown"

    // MARK: - UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }

    // MARK: - Background Networking Session

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        nkLog(debug: "Handle events For background URLSession: \(identifier)")

        NCManageDatabase.shared.openRealmBackground()

        backgroundSessionCompletionHandler = completionHandler
    }

    // MARK: - Push Notifications

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.list, .banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // Lokale Souvera-Notifications: Deep-Link direkt ans Ziel (Mail,
        // Termin-Detail, Chat-Raum) statt Notification-Übersicht.
        let request = response.notification.request
        let info = request.content.userInfo
        let identifier = request.identifier
        // souvera_mail-Standard-Push (direkte APNs, unverschlüsselt):
        // emailId + mailboxPath direkt in die Mail-Detailansicht führen.
        if let emailId = info["emailId"] as? String, !emailId.isEmpty {
            let account = NCManageDatabase.shared.getActiveTableAccount()?.account ?? ""
            souveraOpenDeepLink(
                target: .mail(account: account, emailId: emailId, mailboxPath: info["mailboxPath"] as? String ?? ""),
                tabIndex: 0
            )
        } else if identifier.hasPrefix("mail_"), let emailId = info["emailId"] as? String, !emailId.isEmpty {
            let account = info["account"] as? String ?? NCManageDatabase.shared.getActiveTableAccount()?.account ?? ""
            souveraOpenDeepLink(target: .mail(account: account, emailId: emailId), tabIndex: 0)
        } else if identifier.hasPrefix("eventreminder_"), let uid = info["uid"] as? String, !uid.isEmpty {
            let start = (info["start"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
            souveraOpenDeepLink(target: .event(uid: uid, start: start), tabIndex: 1,
                                account: info["account"] as? String ?? "")
        } else if identifier.hasPrefix("talk_"), let token = info["token"] as? String, !token.isEmpty {
            souveraOpenDeepLink(target: .room(token: token, title: info["title"] as? String ?? ""), tabIndex: 2,
                                account: info["account"] as? String ?? "")
        } else if let pref = UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup),
                  let data = pref.object(forKey: "NOTIFICATION_DATA") as? [String: AnyObject] {
            nextcloudPushNotificationAction(data: data)
            pref.set(nil, forKey: "NOTIFICATION_DATA")
        }

        completionHandler()
    }

    /// Wechselt auf den Ziel-Tab und liefert den Deep-Link an das Modul
    /// (mit kurzem Verzug, damit die SwiftUI-Roots bereit sind). Ist ein
    /// Account angegeben und nicht aktiv, wird zuerst gewechselt
    /// (Multi-Account: Mail/Termin/Raum im richtigen Account öffnen).
    private func souveraOpenDeepLink(target: SouveraPushDeepLink.Target, tabIndex: Int, account: String = "") {
        func apply(controller: NCMainTabBarController) {
            controller.selectedIndex = tabIndex
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SouveraPushDeepLink.deliver(target)
            }
        }
        let activeAccount = NCManageDatabase.shared.getActiveTableAccount()?.account ?? ""
        if !account.isEmpty, account != activeAccount {
            // Account-Wechsel, dann Ziel öffnen (Muster aus
            // nextcloudPushNotificationAction).
            if let tblAccount = NCManageDatabase.shared.getAllTableAccount().first(where: { $0.account == account }),
               let controller = UIApplication.shared.mainAppWindow?.rootViewController as? NCMainTabBarController {
                Task { @MainActor in
                    await NCAccount().changeAccount(tblAccount.account, userProfile: nil, controller: controller)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        SouveraPushDeepLink.deliver(target)
                    }
                }
                return
            }
        }
        if let controller = SceneManager.shared.getControllers().first(where: { $0.account == activeAccount }) {
            apply(controller: controller)
        } else if let controller = UIApplication.shared.mainAppWindow?.rootViewController as? NCMainTabBarController {
            apply(controller: controller)
        } else {
            SouveraPushDeepLink.deliver(target)
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // P68x: Token IMMER speichern - auch im Background/inactive. Der
        // frühere Background-Guard verwarf den Token nach einem Reinstall
        // (Callback kam, während die App noch startete) und ohne Retry
        // blieb der APNs-Token dauerhaft leer -> Push komplett tot.
        guard !isXcodeRunningForPreviews else { return }

        if let deviceToken = NCPushNotificationEncryption.shared().string(withDeviceToken: deviceToken) {
            NCPreferences().deviceTokenPushNotification = deviceToken
            nkLog(tag: global.logTagPN, emoji: .success, message: "APNs registration OK, token length \(deviceToken.count)")
            pushSubscriptionTask = Task.detached {
                // Wait bounded time for maintenance to be OFF
                let canProceed = await NCAppStateManager.shared.waitForMaintenanceOffAsync()
                guard canProceed else {
                    nkLog(error: "[PUSH] Skipping subscription: maintenance mode still ON after timeout")
                    return
                }

                try? await Task.sleep(for: .seconds(1))

                let tblAccounts = await NCManageDatabase.shared.getAllTableAccountAsync()
                for tblAccount in tblAccounts {
                    await NCPushNotification.shared.subscribingNextcloudServerPushNotification(account: tblAccount.account, urlBase: tblAccount.urlBase)
                    // Mail-Push läuft im Zielzustand über die NC-Push-Kette
                    // (keine eigene Registrierung). One-Time-Cleanup: eine
                    // frühere Direkt-Registrierung (Legacy push_mode=direct)
                    // einmalig abmelden - keine Leichen.
                    if let legacyId = SouveraMailDeviceRegistrar.storedDeviceId(account: tblAccount.account) {
                        let davPassword = NCPreferences().getPassword(account: tblAccount.account)
                        if !davPassword.isEmpty {
                            await SouveraMailDeviceRegistrar.unregister(
                                baseUrl: tblAccount.urlBase,
                                username: tblAccount.user,
                                ncPassword: davPassword,
                                deviceId: legacyId,
                                account: tblAccount.account
                            )
                        }
                    }
                }
            }
        }
    }

    /// Nach "In Souvera öffnen" (CallKit) bzw. beim Entsperren: läuft ein
    /// Call ohne eigene UI, wird die Call-UI automatisch präsentiert.
    /// P68e: zentraler Presenter mit Retries statt fragiler Guards - der
    /// Nutzer landet IMMER direkt im App-Call-Vollscreen (kein Banner-
    /// Zwischenzustand mit "Zum Anruf wechseln").
    func applicationDidBecomeActive(_ application: UIApplication) {
        LinkVoIPManager.shared.presentCallUIIfNeeded()
        // P68x: APNs-Token-Retry - nach einem Reinstall kam der erste
        // registerForRemoteNotifications()-Callback teils nicht an (kein
        // "APNs registration OK" im Log). Ohne Token registriert sich das
        // Gerät mit SHA512("") -> Push unzustellbar. Bei leerem Token also
        // erneut anfordern.
        if NCPreferences().deviceTokenPushNotification.isEmpty {
            application.registerForRemoteNotifications()
        }
    }

    /// P66d: Mail-Metadaten für den Vordergrund-Banner laden (Absender/Betreff).
    private static func enrichMailPush(account: tableAccount, objectId: String) async -> (String, String)? {
        guard !objectId.isEmpty,
              let credential = await SouveraMailCredentialManager().ensureCombinedCredential(account: account.account) else { return nil }
        let client = JmapClient(
            baseUrl: credential.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            username: credential.saslUser,
            password: credential.mailPassword
        )
        let api = JmapApi(client: client)
        guard let session = try? await client.refreshSession(),
              let list = try? await api.getEmails(accountId: session.primaryAccountId, ids: [objectId]),
              let mail = list.first else { return nil }
        let from = (mail["from"] as? [[String: Any]])?.first
        let senderName = from?["name"] as? String ?? ""
        let senderMail = from?["email"] as? String ?? ""
        let sender = senderName.isEmpty ? senderMail : senderName
        let subject = mail["subject"] as? String ?? ""
        guard !sender.isEmpty, !subject.isEmpty else { return nil }
        return (sender, subject)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        nkLog(tag: global.logTagPN, emoji: .error, message: "APNs registration FAILED: \(error.localizedDescription)")
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        NCPushNotification.shared.applicationdidReceiveRemoteNotification(userInfo: userInfo) { result in
            completionHandler(result)
        }
        // P66d: Vordergrund-Pushes (besonders Mail-Legacy-Pfad) roh loggen.
        let alert = (userInfo["aps"] as? [String: Any])?["alert"] as? [String: Any]
        var rawLog = "keys=[\(userInfo.keys.map { String(describing: $0) }.sorted().joined(separator: ","))]"
        rawLog += " alertTitle=\((alert?["title"] as? String) ?? "")"
        rawLog += " alertBody=\((alert?["body"] as? String) ?? "")"
        for key in ["emailId", "mailId", "objectId", "id", "nid", "type", "app"] {
            if let value = userInfo[key] {
                rawLog += " \(key)=\(String(describing: value).prefix(40))"
            }
        }
        SouveraLog.write("PushRawFg", rawLog)
        // souvera_mail-Push (NC-Kette): Im VORDERGRUND erscheint kein
        // System-Banner - hier als lokale Notification präsentieren und
        // das Mail-Badge sofort nachziehen.
        if let message = userInfo["subject"] as? String,
           SouveraPushToggles.mailCalendarEnabled {
            for tblAccount in NCManageDatabase.shared.getAllTableAccount() {
                guard let privateKey = NCPreferences().getPushNotificationPrivateKey(account: tblAccount.account),
                      let decrypted = NCPushNotificationEncryption.shared().decryptPushNotification(message, withDevicePrivateKey: privateKey),
                      let data = decrypted.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let app = json["app"] as? String ?? ""
                let objectType = json["objectType"] as? String ?? ""
                // P66: Payload-Logging - Verifikation der Push-Felder gegen
                // die Spec (subject=Absender, message=Betreff). P66c: das
                // KOMPLETTE entschlüsselte JSON loggen (keine Secrets),
                // damit die echte Feldstruktur des Servers sichtbar wird.
                SouveraLog.write("PushPayload", "account=\(tblAccount.account) app=\(app) objectType=\(objectType) objectId=\(json["objectId"] as? String ?? "-") subject=\(json["subject"] as? String ?? "-") message=\(json["message"] as? String ?? "-")")
                SouveraLog.write("PushPayloadJSON", decrypted)
                guard app == "souvera_mail" || objectType == "souvera_mail" else { break }
                let title = (json["subject"] as? String) ?? NSLocalizedString("_mail_", comment: "")
                let body = (json["message"] as? String) ?? title
                let mailId = (json["objectId"] as? String)
                    ?? (json["emailId"] as? String)
                    ?? (json["mailId"] as? String)
                    ?? (json["id"] as? String)
                    ?? ""
                if UIApplication.shared.applicationState == .active {
                    // P66d: Bei generischen Server-Texten Absender/Betreff
                    // selbst laden (Vordergrund-Banner).
                    let finalMailId = mailId
                    let tblCopy = tblAccount
                    Task {
                        var finalTitle = title
                        var finalBody = body
                        if title.isEmpty || title == "Neue E-Mail" || body.isEmpty || body == "Du hast eine neue Nachricht erhalten" {
                            if let enriched = await Self.enrichMailPush(account: tblCopy, objectId: finalMailId) {
                                finalTitle = enriched.0
                                finalBody = enriched.1
                            }
                        }
                        let content = UNMutableNotificationContent()
                        content.title = finalTitle
                        content.body = finalBody
                        content.sound = .default
                        content.userInfo = ["emailId": finalMailId, "mailboxPath": "INBOX", "account": tblCopy.account]
                        let request = UNNotificationRequest(identifier: "nc_mail_\(finalMailId)", content: content, trigger: nil)
                        try? await UNUserNotificationCenter.current().add(request)
                    }
                }
                // Badge an den Push koppeln: INBOX-Zählung sofort.
                Task { await SouveraBackgroundSync.shared.refreshMailBadge() }
                // P62g: Auch die OFFENE Mailbox sofort nachziehen lassen.
                NotificationCenter.default.post(
                    name: .mailPushReceived,
                    object: nil,
                    userInfo: ["account": tblAccount.account]
                )
                break
            }
        }
    }

    func nextcloudPushNotificationAction(data: [String: AnyObject]) {
        let account = data["account"] as? String ?? "unavailable"
        let app = data["app"] as? String

        func openNotification(controller: NCMainTabBarController) {
            let objectType = data["objectType"] as? String ?? ""
            if app == "souvera_mail" || app == "souvera_mail_notifications" || objectType == "souvera_mail" {
                // Mail-Benachrichtigung (NC-Push): Mail-Tab + direkt die
                // Mail öffnen - objectId = JMAP-E-Mail-Id, Kontext INBOX.
                controller.selectedIndex = 0
                if let mailId = data["objectId"] as? String, !mailId.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        SouveraPushDeepLink.deliver(.mail(account: account, emailId: mailId))
                    }
                }
            } else if app == "spreed" || app == "talk" {
                // Push-Gruppe Link/Talk aus: nicht navigieren
                // (Sicherheitsnetz parallel zur Server-Abmeldung).
                guard SouveraPushToggles.linkTalkEnabled else { return }
                // Talk-Benachrichtigung (Chat/Call): Link-Tab + Raum öffnen.
                controller.selectedIndex = 2
                if let token = data["id"] as? String, !token.isEmpty {
                    let title = data["subject"] as? String ?? ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        SouveraPushDeepLink.deliver(.room(token: token, title: title))
                    }
                }
            } else if app == NCGlobal.shared.termsOfServiceName {
                Task {
                    await NCNetworking.shared.transferDispatcher.notifyAllDelegatesAsync { delegate in
                        try? await Task.sleep(for: .seconds(0.5))
                        delegate.transferReloadDataSource(serverUrl: nil, requestData: true, status: nil)
                    }
                }
            } else if let navigationController = UIStoryboard(name: "NCNotification", bundle: nil).instantiateInitialViewController() as? UINavigationController,
                      let viewController = navigationController.topViewController as? NCNotification {
                viewController.modalPresentationStyle = .pageSheet
                viewController.session = NCSession.shared.getSession(account: account)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    controller.present(navigationController, animated: true, completion: nil)
                }
            }
        }

        if let controller = SceneManager.shared.getControllers().first(where: { $0.account == account }) {
            openNotification(controller: controller)
        } else if let tblAccount = NCManageDatabase.shared.getAllTableAccount().first(where: { $0.account == account }),
                  let controller = UIApplication.shared.mainAppWindow?.rootViewController as? NCMainTabBarController {
            Task { @MainActor in
                await NCAccount().changeAccount(tblAccount.account, userProfile: nil, controller: controller)
                openNotification(controller: controller)
            }
        } else {
            let message = String(
                format: NSLocalizedString("account_does_not_exist", comment: ""),
                account
            )

            let alertController = UIAlertController(title: NSLocalizedString("_info_", comment: ""), message: message, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: NSLocalizedString("_ok_", comment: ""), style: .default, handler: { _ in }))
            UIApplication.shared.mainAppWindow?.rootViewController?.present(alertController, animated: true, completion: { })
        }
    }

    // MARK: -

    func trustCertificateError(host: String) {
        guard let activeTblAccount = NCManageDatabase.shared.getActiveTableAccount(),
              let currentHost = URL(string: activeTblAccount.urlBase)?.host,
              let pushNotificationServerProxyHost = URL(string: NCBrandOptions.shared.pushNotificationServerProxy)?.host,
              host != pushNotificationServerProxyHost,
              host == currentHost
        else { return }
        let certificateHostSavedPath = NCUtilityFileSystem().directoryCertificates + "/" + host + ".der"
        var title = NSLocalizedString("_ssl_certificate_changed_", comment: "")

        if !FileManager.default.fileExists(atPath: certificateHostSavedPath) {
            title = NSLocalizedString("_connect_server_anyway_", comment: "")
        }

        let alertController = UIAlertController(title: title, message: NSLocalizedString("_server_is_trusted_", comment: ""), preferredStyle: .alert)

        alertController.addAction(UIAlertAction(title: NSLocalizedString("_yes_", comment: ""), style: .default, handler: { _ in
            NCNetworking.shared.writeCertificate(host: host)
        }))

        alertController.addAction(UIAlertAction(title: NSLocalizedString("_no_", comment: ""), style: .default, handler: { _ in }))

        alertController.addAction(UIAlertAction(title: NSLocalizedString("_certificate_details_", comment: ""), style: .default, handler: { _ in
            if let navigationController = UIStoryboard(name: "NCViewCertificateDetails", bundle: nil).instantiateInitialViewController() as? UINavigationController,
               let viewController = navigationController.topViewController as? NCViewCertificateDetails {
                viewController.delegate = self
                viewController.host = host
                UIApplication.shared.mainAppWindow?.rootViewController?.present(navigationController, animated: true)
            }
        }))

        UIApplication.shared.mainAppWindow?.rootViewController?.present(alertController, animated: true)
    }

    // MARK: - Reset Application

    func resetApplication() {
        let utilityFileSystem = NCUtilityFileSystem()

        NCNetworking.shared.cancelAllTask()

        URLCache.shared.removeAllCachedResponses()

        utilityFileSystem.removeGroupDirectoryProviderStorage()
        utilityFileSystem.removeGroupApplicationSupport()
        utilityFileSystem.removeDocumentsDirectory()
        utilityFileSystem.removeTemporaryDirectory()

        NCPreferences().removeAll()

        exit(0)
    }

    // MARK: - Universal Links

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        return false
    }
}

// MARK: - Extension

extension AppDelegate: NCViewCertificateDetailsDelegate {
    func viewCertificateDetailsDismiss(host: String) {
        trustCertificateError(host: host)
    }
}

extension AppDelegate: NCCreateFormUploadConflictDelegate {
    func dismissCreateFormUploadConflict(metadatas: [tableMetadata]?) {
        if let metadatas {
            Task {
                await NCManageDatabase.shared.addMetadatasAsync(metadatas)
            }
        }
    }
}
