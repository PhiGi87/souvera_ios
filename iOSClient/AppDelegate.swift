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
        NotificationCenter.default.addObserver(forName: .linkAnswerCall, object: nil, queue: .main) { notification in
            guard let token = notification.userInfo?["token"] as? String, !token.isEmpty,
                  let account = LinkAccount.active(),
                  let root = UIApplication.shared.mainAppWindow?.rootViewController else { return }
            let title = (notification.userInfo?["title"] as? String) ?? NSLocalizedString("_link_incoming_call_", comment: "")
            let hasVideo = (notification.userInfo?["hasVideo"] as? Bool) ?? false
            // Session zentral anlegen (wie beim ausgehenden Anruf), damit das
            // "Zurück zum Anruf"-Banner und CallKit-Zustand funktionieren.
            let session = LinkVoIPManager.shared.startIncomingCall(account: account, token: token, title: title, withVideo: hasVideo)
            let callVC = LinkCallViewController(account: account, token: token, title: title, withVideo: hasVideo, session: session)
            root.present(callVC, animated: true)
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
        if identifier.hasPrefix("mail_"), let emailId = info["emailId"] as? String, !emailId.isEmpty {
            let account = info["account"] as? String ?? NCManageDatabase.shared.getActiveTableAccount()?.account ?? ""
            souveraOpenDeepLink(target: .mail(account: account, emailId: emailId), tabIndex: 0)
        } else if identifier.hasPrefix("eventreminder_"), let uid = info["uid"] as? String, !uid.isEmpty {
            let start = (info["start"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
            souveraOpenDeepLink(target: .event(uid: uid, start: start), tabIndex: 1)
        } else if identifier.hasPrefix("talk_"), let token = info["token"] as? String, !token.isEmpty {
            souveraOpenDeepLink(target: .room(token: token, title: info["title"] as? String ?? ""), tabIndex: 2)
        } else if let pref = UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup),
                  let data = pref.object(forKey: "NOTIFICATION_DATA") as? [String: AnyObject] {
            nextcloudPushNotificationAction(data: data)
            pref.set(nil, forKey: "NOTIFICATION_DATA")
        }

        completionHandler()
    }

    /// Wechselt auf den Ziel-Tab und liefert den Deep-Link an das Modul
    /// (mit kurzem Verzug, damit die SwiftUI-Roots bereit sind).
    private func souveraOpenDeepLink(target: SouveraPushDeepLink.Target, tabIndex: Int) {
        func apply(controller: NCMainTabBarController) {
            controller.selectedIndex = tabIndex
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SouveraPushDeepLink.deliver(target)
            }
        }
        let activeAccount = NCManageDatabase.shared.getActiveTableAccount()?.account ?? ""
        if let controller = SceneManager.shared.getControllers().first(where: { $0.account == activeAccount }) {
            apply(controller: controller)
        } else if let controller = UIApplication.shared.mainAppWindow?.rootViewController as? NCMainTabBarController {
            apply(controller: controller)
        } else {
            SouveraPushDeepLink.deliver(target)
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard !isXcodeRunningForPreviews,
              application.applicationState != .background else {
            return
        }

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
                }
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        nkLog(tag: global.logTagPN, emoji: .error, message: "APNs registration FAILED: \(error.localizedDescription)")
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        NCPushNotification.shared.applicationdidReceiveRemoteNotification(userInfo: userInfo) { result in
            completionHandler(result)
        }
    }

    func nextcloudPushNotificationAction(data: [String: AnyObject]) {
        let account = data["account"] as? String ?? "unavailable"
        let app = data["app"] as? String

        func openNotification(controller: NCMainTabBarController) {
            if app == "souvera_mail" || app == "souvera_mail_notifications" {
                // Mail-Benachrichtigung: direkt ins Mail-Modul springen.
                controller.selectedIndex = 0
            } else if app == "spreed" || app == "talk" {
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
