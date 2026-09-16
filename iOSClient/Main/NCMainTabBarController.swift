// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2024 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import SwiftUI
import NextcloudKit

struct NavigationCollectionViewCommon {
    var serverUrl: String
    var navigationController: UINavigationController?
    var viewController: NCCollectionViewCommon
}

class NCMainTabBarController: UITabBarController {
    var sceneIdentifier: String = UUID().uuidString
    var account: String = "" {
        didSet {
            // NCImageCache.shared.controller = self
        }
    }
    var availableNotifications: Bool = false
    private weak var mailTabBarItem: UITabBarItem?
    /// Run 16.09.: Coordinator der Mail/Kalender/Link-Bridges (Retention).
    private weak var linkTabBarItem: UITabBarItem?
    var documentPickerViewController: NCDocumentPickerViewController?
    let navigationCollectionViewCommon = ThreadSafeArray<NavigationCollectionViewCommon>()
    private var previousIndex: Int?
    private var checkUserDelaultErrorInProgress: Bool = false
    private var timerTask: Task<Void, Never>?
    private let global = NCGlobal.shared

    var window: UIWindow? {
        return SceneManager.shared.getWindow(controller: self)
    }

    var barHeightBottom: CGFloat {
        return tabBar.frame.height - tabBar.safeAreaInsets.bottom
    }

    var barHeightTop: CGFloat {
        return tabBar.frame.height - tabBar.safeAreaInsets.top
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self

        NCNetworking.shared.setupScene(sceneIdentifier: sceneIdentifier, controller: self)

        tabBar.tintColor = NCBrandColor.shared.getElement(account: account)

        configureTabControllers()
        configureTabBarAppearance()

        NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: self.global.notificationCenterChangeTheming), object: nil, queue: .main) { [weak self] notification in
            if let userInfo = notification.userInfo as? NSDictionary,
               let account = userInfo["account"] as? String,
               self?.account == account {
                self?.tabBar.tintColor = NCBrandColor.shared.getElement(account: account)
            }
        }

        NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: self.global.notificationCenterCheckUserDelaultErrorDone), object: nil, queue: nil) { notification in
            if let userInfo = notification.userInfo,
               let account = userInfo["account"] as? String,
               let controller = userInfo["controller"] as? NCMainTabBarController,
               account == self.account,
               controller == self {
                self.checkUserDelaultErrorInProgress = false
            }
        }

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            self.timerTask?.cancel()
        }

        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // Run 15.09. (Crash-Fix): im Hintergrund übersprungene
            // Badge-Updates hier nachholen (Realm-Zugriff nur bei active).
            if UIApplication.shared.applicationState == .active {
                updateLinkBadge(SouveraBadgeStore.shared.unreadLink(account: NCManageDatabase.shared.getActiveTableAccount()?.account ?? ""))
            }
            if !isAppInBackground {
                timerTask = Task { @MainActor [weak self] in
                    await self?.timerCheck()
                }
            }
        }

        // The calendar module can ask the app to switch to the Link tab and
        // open a specific Talk conversation (e.g. the channel of an event).
        NotificationCenter.default.addObserver(forName: .openLinkRoom, object: nil, queue: .main) { [weak self] notification in
            guard let self,
                  let info = notification.object as? [String: String] else { return }
            Task { @MainActor in
                LinkViewModel.pendingOpenRoom = (info["token"] ?? "", info["title"] ?? "")
                self.selectedIndex = 2
            }
        }

        // The Link chat can ask the app to show a chat file's folder in the
        // Files tab (shared files are stored under "Souvera/Link/<room>/…";
        // files at the user root pass an empty path and open the home folder).
        NotificationCenter.default.addObserver(forName: .openFileInFiles, object: nil, queue: .main) { [weak self] notification in
            guard let self, let folderPath = notification.object as? String else { return }
            Task { @MainActor in
                self.openFilesFolder(folderPath)
            }
        }

        // Termin-Einladungs-Links: Antwort-Overlay präsentieren (P63).
        NotificationCenter.default.addObserver(forName: .openInviteResponse, object: nil, queue: .main) { [weak self] notification in
            guard let self, let url = notification.object as? URL else { return }
            let host = UIHostingController(rootView: SouveraInviteResponseView(url: url))
            if let sheet = host.sheetPresentationController {
                sheet.detents = [.medium()]
            }
            self.topViewController()?.present(host, animated: true)
        }
    }

    private func topViewController() -> UIViewController? {
        var top: UIViewController? = self
        while let presented = top?.presentedViewController {
            top = presented
        }
        if let nav = top as? UINavigationController {
            top = nav.visibleViewController ?? nav
        }
        return top
    }

    /// Wechselt in den Dateien-Tab und navigiert in den Ordner mit dem
    /// relativen Pfad (ohne führenden Slash, relativ zur Nutzer-Wurzel;
    /// leer = Nutzer-Root/Home). Wiederverwendung bestehender Navigation oder
    /// Push einer neuen Ordner-Ansicht - identisch zum internen
    /// pushMetadata-Fluss.
    private func openFilesFolder(_ relativeFolderPath: String) {
        guard let filesNav = viewControllers?.first(where: { $0 is NCFilesNavigationController }) as? NCFilesNavigationController else { return }
        let session = NCSession.shared.getSession(controller: self)
        let home = NCUtilityFileSystem().getHomeServer(session: session)
        let serverUrl = relativeFolderPath.isEmpty
            ? home
            : NCUtilityFileSystem().createServerUrl(serverUrl: home, fileName: relativeFolderPath)

        selectedIndex = ControllerConstants.filesIndex

        if serverUrl == home {
            filesNav.popToRootViewController(animated: false)
            return
        }

        if let existing = navigationCollectionViewCommon.first(where: {
            $0.navigationController === filesNav && $0.serverUrl == serverUrl
        }) {
            filesNav.popToViewController(existing.viewController, animated: true)
            return
        }
        guard let viewController = UIStoryboard(name: "NCFiles", bundle: nil).instantiateInitialViewController() as? NCFiles else { return }
        viewController.serverUrl = serverUrl
        viewController.titlePreviusFolder = filesNav.topViewController?.navigationItem.title
        viewController.titleCurrentFolder = (serverUrl as NSString).lastPathComponent
        filesNav.popToRootViewController(animated: false)
        navigationCollectionViewCommon.append(
            NavigationCollectionViewCommon(
                serverUrl: serverUrl,
                navigationController: filesNav,
                viewController: viewController
            )
        )
        filesNav.pushViewController(viewController, animated: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        previousIndex = selectedIndex

        if NCBrandOptions.shared.enforce_passcode_lock && NCPreferences().passcode.isEmptyOrNil {
            let vc = UIHostingController(rootView: SetupPasscodeView(isLockActive: .constant(false), controller: self))
            vc.isModalInPresentation = true

            present(vc, animated: true)
        }
    }

    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        // Inaktive Tab-Icons im hellen Modus immer schwarz (nicht grau);
        // im dunklen Modus das Systemgrau beibehalten.
        appearance.stackedLayoutAppearance.normal.iconColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? .secondaryLabel : .black
        }
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? .secondaryLabel : .black
        }]
        appearance.inlineLayoutAppearance.normal.iconColor = appearance.stackedLayoutAppearance.normal.iconColor
        appearance.inlineLayoutAppearance.normal.titleTextAttributes = appearance.stackedLayoutAppearance.normal.titleTextAttributes

        // Run 16.09.: Badge leicht nach rechts oben versetzen - im
        // iOS-26-Glass-Pill ueberlappte das Badge sonst das Tab-Label
        // (Feedback-Screenshot "Mail 31").
        appearance.stackedLayoutAppearance.normal.badgePositionAdjustment = UIOffset(horizontal: 6, vertical: -2)
        appearance.stackedLayoutAppearance.selected.badgePositionAdjustment = UIOffset(horizontal: 6, vertical: -2)

        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
    }

    /// Builds the tab bar: Mail, Calendar, Link, Files, More.
    ///
    /// The storyboard supplies the Files/Favorites/Media/Activity navigation
    /// controllers. Favorites, Media and Activity no longer have their own
    /// tabs; they are available inside the More tab instead. Mail, Calendar
    /// and Link are SwiftUI roots hosted in navigation controllers whose
    /// UIKit bar stays hidden - the SwiftUI views render their own bars
    /// (avoids stacked navigation bars and double back arrows). The app
    /// starts on the Mail tab (index 0).
    private func configureTabControllers() {
        let storyboardControllers = viewControllers ?? []
        let filesController = storyboardControllers.first(where: { $0 is NCFilesNavigationController })
            ?? storyboardControllers.first
            ?? UINavigationController()
        let moreController = makeMoreNavigationController()

        // Run 16.09.: Bridges für Mail/Kalender/Link — die Module befüllen
        // sie, der Host-Controller rendert die Bar-Items (1:1 Files/More).
        let mailBridge = SouveraHeaderBridge()
        let calendarBridge = SouveraHeaderBridge()
        let linkBridge = SouveraHeaderBridge()
        let mailController = makeHostedTab(
            root: MailView(headerBridge: mailBridge),
            bridge: mailBridge,
            tag: 100,
            imageName: "envelope.fill",
            titleKey: "_mail_"
        )
        mailTabBarItem = mailController.tabBarItem
        // App-Icon-Badge (nur ungelesene Mails, Summe aller Accounts) zentral
        // über den Badge-Store - respektiert den iOS-Schalter "Badges".
        _ = SouveraBadgeStore.shared
        NotificationCenter.default.addObserver(
            forName: .mailUnreadChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Nur der AKTIVE Account steuert den Mail-Tab-Badge.
            guard let userInfo = notification.userInfo,
                  let account = userInfo["account"] as? String,
                  let count = userInfo["count"] as? Int else { return }
            let active = NCManageDatabase.shared.getActiveTableAccount()?.account ?? ""
            if account == active {
                // Run-Fix "Badge flattert auf 0": Abgeleitete 0-Posts
                // (Hintergrund-Sync-Zwischenstände, Cache-Fallback) löschen
                // das Tab-Badge nicht, solange der Badge-Store einen echten
                // Zähler hält - die Korrektur auf 0 kommt über die
                // autoritative Email/query-Zählung (Vordergrund).
                if count == 0, SouveraBadgeStore.shared.unreadMail(account: active) > 0 {
                    JmapLog.write("Mail tab badge: skip derived 0 (store holds a real count)")
                    return
                }
                self?.updateMailBadge(count)
            }
        }
        // Run-Fix "Badge Account-Wechsel": Bei jedem Account-Wechsel
        // ALLE Tab-Badges SOFORT aus dem Badge-Store setzen (letzter
        // bekannter Stand je Account) - null Wartezeit auf Sync/Netzwerk.
        // Der BackgroundSync korrigiert die Werte danach autoritativ.
        NotificationCenter.default.addObserver(
            forName: Notification.Name(NCGlobal.shared.notificationCenterChangeUser),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let active = NCManageDatabase.shared.getActiveTableAccount()?.account ?? ""
            let store = SouveraBadgeStore.shared
            self.updateMailBadge(store.unreadMail(account: active))
            self.updateLinkBadge(store.unreadLink(account: active))
            self.updateMoreBadge()
            JmapLog.write("Tab badges refreshed on account switch (active=\(active))")
        }
        let calendarController = makeHostedTab(
            root: SouveraCalendarView(headerBridge: calendarBridge),
            bridge: calendarBridge,
            tag: 101,
            imageName: "calendar",
            titleKey: "_calendar_"
        )
        let linkController = makeHostedTab(
            root: LinkView(headerBridge: linkBridge),
            bridge: linkBridge,
            tag: 102,
            imageName: "bubble.left.and.bubble.right.fill",
            titleKey: "_link_"
        )
        linkTabBarItem = linkController.tabBarItem
        NotificationCenter.default.addObserver(
            forName: .linkUnreadChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Run 15.09. (Crash 0xdead10cc): KEIN synchroner Realm-Zugriff,
            // wenn die App im Hintergrund ist — der Observer blockierte auf
            // dem Realm-File-Lock (Hintergrund-Sync hielt ihn) und das OS
            // killte die App (SIGKILL). Badge beim Foreground aktualisieren.
            guard UIApplication.shared.applicationState == .active else { return }
            let count = notification.object as? Int ?? 0
            let account = (notification.userInfo?["account"] as? String) ?? ""
            let active = NCManageDatabase.shared.getActiveTableAccount()?.account ?? ""
            // Nur der AKTIVE Account steuert den Link-Tab-Badge; Accounts ohne
            // Angabe (Alt-Pfade) werden weiterhin akzeptiert.
            if account.isEmpty || account == active {
                self?.updateLinkBadge(count)
            }
        }
        // Mehr-Tab-Badge (Summe Mail+Link, farbcodiert) bei jeder
        // Totals-Änderung neu rendern.
        NotificationCenter.default.addObserver(
            forName: .souveraBadgeTotalsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateMoreBadge()
            // Run-Fix "Mail-Badge spinnt": Der Push-Pfad füttert den
            // Badge-Store sofort (App-Icon 31 -> 32 im Log 10.09.), der
            // Mail-Tab-Badge aktualisierte sich aber erst beim Öffnen des
            // Mail-Tabs (stand 12:53-12:58 auf "1"). Der Tab spiegelt jetzt
            // den Store für den AKTIVEN Account bei jeder Totals-Änderung.
            let active = NCManageDatabase.shared.getActiveTableAccount()?.account ?? ""
            self?.updateMailBadge(SouveraBadgeStore.shared.unreadMail(account: active))
        }
        // Hintergrund-Poller für ungelesene Talk-Nachrichten (Badge).
        LinkBadgeMonitor.shared.start()
        // Wartungsmodus-Erkennung: Info-Punkt am Mehr-Tab + Hinweis im
        // Mehr-Menü, während die Module mit ihrem Cache weiterarbeiten.
        SouveraMaintenanceMonitor.shared.start()
        NotificationCenter.default.addObserver(
            forName: .maintenanceChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.updateMaintenanceDot(notification.object as? Bool ?? false)
        }

        filesController.tabBarItem = UITabBarItem(
            title: NSLocalizedString("_home_", comment: ""),
            image: UIImage(systemName: "folder.fill"),
            selectedImage: UIImage(systemName: "folder.fill")
        )
        filesController.tabBarItem.tag = 103

        viewControllers = [mailController, calendarController, linkController, filesController, moreController]
        selectedIndex = 0

        // App-weite Leiste für minimierte (klingelnde) Calls: oben über dem
        // Tab-Inhalt, in allen Tabs sichtbar - Annehmen/Ablehnen, während
        // man in der App weiterarbeitet.
        let bannerHost = UIHostingController(rootView: SouveraIncomingCallBannerView())
        bannerHost.view.backgroundColor = .clear
        bannerHost.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bannerHost.view)
        NSLayoutConstraint.activate([
            bannerHost.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bannerHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bannerHost.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        callBannerHost = bannerHost

        // Annehmen/Ablehnen funktionieren unabhängig von der LinkView:
        // Session starten und die Call-UI direkt modal präsentieren.
        let bannerModel = SouveraCallBannerModel.shared
        bannerModel.onAccept = { [weak self] room in
            guard let account = LinkAccount.active() else { return }
            let session = LinkVoIPManager.shared.startIncomingCall(
                account: account,
                token: room.token,
                title: room.displayName,
                withVideo: false
            )
            if let session {
                let callVC = LinkCallViewController(
                    account: account,
                    token: room.token,
                    title: room.displayName,
                    withVideo: false,
                    session: session
                )
                callVC.modalPresentationStyle = .fullScreen
                self?.present(callVC, animated: true)
            }
        }
        bannerModel.onDecline = { _ in
            // Raum bleibt für diese Call-Episode stumm (previousCallState
            // verhindert einen erneuten Fullscreen).
        }
    }

    /// Die Call-Leiste muss IMMER über dem Tab-Inhalt liegen - Tab-Views
    /// werden später hinzugefügt und würden sie sonst verdecken (Buttons
    /// reagieren dann nicht).
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let bannerView = callBannerHost?.view {
            view.bringSubviewToFront(bannerView)
        }
    }

    private var callBannerHost: UIHostingController<SouveraIncomingCallBannerView>?

    // MARK: - Badges

    private weak var moreTabBarItem: UITabBarItem?
    /// Run 16.09.: Coordinator der Bridge-Bars (Mail/Kalender/Link).
    private var headerCoordinators: [SouveraBarCoordinator] = []

    /// Mail-Badge als System-Badge - identisch zum Link-Badge (einheitlich,
    /// deckend, korrekt in Portrait UND Landscape).
    private func updateMailBadge(_ count: Int) {
        // Run 15.09.: Badge nur bei Wertänderung setzen — Re-Setzen bei
        // identischem Wert liess die Top-Pill auf dem iPad flackern.
        let value = count > 0 ? "\(count)" : nil
        guard mailTabBarItem?.badgeValue != value else { return }
        mailTabBarItem?.badgeValue = value
        JmapLog.write("Mail tab badge set -> \(count)")
    }

    /// Link-Badge als nativer System-Badge (identisch zum Mail-Badge, rot).
    private func updateLinkBadge(_ count: Int) {
        let value = count > 0 ? "\(count)" : nil
        guard linkTabBarItem?.badgeValue != value else { return }
        linkTabBarItem?.badgeValue = value
    }

    private func updateMaintenanceDot(_ maintenance: Bool) {
        applyBadge(to: moreTabBarItem, baseName: "ellipsis.circle.fill", count: nil, dot: maintenance)
    }

    /// Mehr-Tab-Badge: nativer roter Badge mit der Summe aus Mail + Link der
    /// NICHT ausgewählten Accounts. Der aktive Account wird bewusst nicht
    /// mitgezählt (seine Ungelesen stehen im jeweiligen Tab selbst).
    private func updateMoreBadge() {
        let store = SouveraBadgeStore.shared
        let active = NCManageDatabase.shared.getActiveTableAccount()?.account ?? ""
        let total = store.unreadExcluding(account: active)
        moreTabBarItem?.badgeValue = total > 0 ? "\(total)" : nil
    }

    /// Rendert den Wartungs-Punkt in das Mehr-Icon (nur Punkt-Variante).
    private func applyBadge(to item: UITabBarItem?, baseName: String, count: Int?, dot: Bool) {
        guard let item else { return }
        if dot {
            item.image = Self.badgedIcon(baseName: baseName, count: nil, dot: true, selected: false)
            item.selectedImage = Self.badgedIcon(baseName: baseName, count: nil, dot: true, selected: true)
        } else {
            item.image = UIImage(systemName: baseName)
            item.selectedImage = UIImage(systemName: baseName)
        }
    }

    /// Punkt-Icon für den Mehr-Tab (Canvas = Original-Symbolgröße, Punkt
    /// voll deckend rechts überlappend). Trait-bewusst (Run 15.09.): das
    /// bisher fest weiß vorgerenderte, unselektierte Icon war im Light-
    /// Mode unsichtbar bzw. falsch getönt - jetzt werden Light- und
    /// Dark-Variante über ein UIImageAsset registriert, damit das Icon
    /// wie die System-Icons dem Erscheinungsbild folgt.
    private static func badgedIcon(baseName: String, count: Int?, dot: Bool, selected: Bool) -> UIImage? {
        let light = renderBadgedIcon(baseName: baseName, dot: dot, selected: selected, dark: false)
        let dark = renderBadgedIcon(baseName: baseName, dot: dot, selected: selected, dark: true)
        guard light != nil || dark != nil else { return nil }
        let asset = UIImageAsset()
        if let light {
            asset.register(light, with: UITraitCollection(userInterfaceStyle: .light))
        }
        if let dark {
            asset.register(dark, with: UITraitCollection(userInterfaceStyle: .dark))
        }
        // Das asset-getragene Image liefert pro Trait-Collection die
        // passende Variante (gleiches Verhalten wie SF Symbols).
        return asset.image(with: UITraitCollection(userInterfaceStyle: .light))
    }

    private static func renderBadgedIcon(baseName: String, dot: Bool, selected: Bool, dark: Bool) -> UIImage? {
        let base = UIImage(systemName: baseName)
        var canvasSize = base?.size ?? CGSize(width: 25, height: 25)
        if canvasSize.width < 10 || canvasSize.height < 10 {
            canvasSize = CGSize(width: 25, height: 25)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { _ in
            // Wie die normalen Tabs (configureTabBarAppearance):
            // unselektiert schwarz/secondaryLabel, selektiert Markenfarbe.
            let iconColor: UIColor = selected
                ? NCBrandColor.shared.customer
                : (dark ? .secondaryLabel : .black)
            if let base {
                base.withTintColor(iconColor, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(origin: .zero, size: canvasSize))
            }
            if dot {
                let dotSide = canvasSize.height * 0.24
                let dotRect = CGRect(
                    x: canvasSize.width - dotSide * 1.1,
                    y: dotSide * 0.08,
                    width: dotSide,
                    height: dotSide
                )
                let path = UIBezierPath(ovalIn: dotRect)
                UIColor.systemOrange.setFill()
                path.fill()
                UIColor.white.setStroke()
                path.lineWidth = max(0.5, dotSide * 0.14)
                path.stroke()
            }
        }.withRenderingMode(.alwaysOriginal)
    }

    private func makeHostedTab<Content: View>(root: Content, titleKey: String, imageName: String, tag: Int) -> UIViewController {
        let hostingController = UIHostingController(rootView: root)
        let navigationController = UINavigationController(rootViewController: hostingController)
        navigationController.setNavigationBarHidden(true, animated: false)
        navigationController.tabBarItem = UITabBarItem(
            title: NSLocalizedString(titleKey, comment: ""),
            image: UIImage(systemName: imageName),
            selectedImage: UIImage(systemName: imageName)
        )
        navigationController.tabBarItem.tag = tag
        return navigationController
    }

    /// Run 16.09.: Variante mit SICHTBARER blauer UIKit-Bar + Bridge-Items
    /// (1:1 wie Mehr/Dateien — auf dem iPad flankieren die Items die
    /// zentrierte Tab-Pill automatisch). Für Mail/Kalender/Link.
    private func makeHostedTab<Content: View>(root: Content, bridge: SouveraHeaderBridge, tag: Int, imageName: String, titleKey: String) -> UIViewController {
        let hostingController = UIHostingController(rootView: root)
        let navigationController = UINavigationController(rootViewController: hostingController)
        // Run 16.09.: Die aeussere UIKit-Bar bleibt HIDDEN - die Bridge-
        // Items rendern in der inneren SwiftUI-System-Bar
        // (SouveraBridgeBarModifier), die den Liquid-Glass-Look wie
        // Mehr/Dateien liefert. Sichtbar+hidden gleichzeitig = doppelter
        // Header mit Gap (Feedback 16.09.).
        navigationController.setNavigationBarHidden(true, animated: false)
        navigationController.tabBarItem = UITabBarItem(
            title: NSLocalizedString(titleKey, comment: ""),
            image: UIImage(systemName: imageName),
            selectedImage: UIImage(systemName: imageName)
        )
        navigationController.tabBarItem.tag = tag
        return navigationController
    }

    private func makeMoreNavigationController() -> UIViewController {
        let moreView = NCMoreView(account: account, controller: self)
        let hostingController = UIHostingController(rootView: moreView)

        hostingController.navigationItem.title = NSLocalizedString("_more_", comment: "")

        let navigationController = NCMoreNavigationController(rootViewController: hostingController)

        navigationController.tabBarItem = UITabBarItem(
            title: NSLocalizedString("_more_", comment: ""),
            image: UIImage(systemName: "ellipsis.circle.fill"),
            selectedImage: UIImage(systemName: "ellipsis.circle.fill")
        )
        navigationController.tabBarItem.tag = 104
        moreTabBarItem = navigationController.tabBarItem

        return navigationController
    }

    @MainActor
    private func timerCheck() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))

            guard isViewLoaded, view.window != nil else {
                continue
            }

            // Check error
            await NCNetworking.shared.checkServerError(account: self.account, controller: self)
        }
    }

    func currentViewController() -> UIViewController? {
        return (selectedViewController as? UINavigationController)?.topViewController
    }

    func currentNavigationController() -> UINavigationController? {
        return selectedViewController as? UINavigationController
    }

    func currentServerUrl() -> String {
        let session = NCSession.shared.getSession(account: account)
        var serverUrl = NCUtilityFileSystem().getHomeServer(session: session)
        let viewController = currentViewController()
        if let collectionViewCommon = viewController as? NCCollectionViewCommon {
            if !collectionViewCommon.serverUrl.isEmpty {
                serverUrl = collectionViewCommon.serverUrl
            }
        }
        return serverUrl
    }

    func hide() {
        if #available(iOS 18.0, *) {
            setTabBarHidden(true, animated: true)
        } else {
            tabBar.isHidden = true
        }
    }

    func show() {
        if #available(iOS 18.0, *) {
            setTabBarHidden(false, animated: true)
        } else {
            tabBar.isHidden = false
        }
    }
}

extension NCMainTabBarController: UITabBarControllerDelegate {
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        if previousIndex == tabBarController.selectedIndex {
            scrollToTop(viewController: viewController)
        }
        previousIndex = tabBarController.selectedIndex
    }

    private func scrollToTop(viewController: UIViewController) {
        guard let navigationController = viewController as? UINavigationController,
              let topViewController = navigationController.topViewController else { return }

        if let scrollView = topViewController.view.subviews.compactMap({ $0 as? UIScrollView }).first {
            scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: true)
        }
    }
}
