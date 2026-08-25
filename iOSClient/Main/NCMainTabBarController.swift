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

        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            if !isAppInBackground {
                self.timerTask = Task { @MainActor [weak self = self] in
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

        let mailController = makeHostedTab(
            root: MailView(),
            titleKey: "_mail_",
            imageName: "envelope.fill",
            tag: 100
        )
        mailTabBarItem = mailController.tabBarItem
        NotificationCenter.default.addObserver(
            forName: .mailUnreadChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let count = notification.object as? Int ?? 0
            self?.updateMailBadge(count)
        }
        let calendarController = makeHostedTab(
            root: SouveraCalendarView(),
            titleKey: "_calendar_",
            imageName: "calendar",
            tag: 101
        )
        let linkController = makeHostedTab(
            root: LinkView(),
            titleKey: "_link_",
            imageName: "bubble.left.and.bubble.right.fill",
            tag: 102
        )
        linkTabBarItem = linkController.tabBarItem
        NotificationCenter.default.addObserver(
            forName: .linkUnreadChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let count = notification.object as? Int ?? 0
            self?.updateLinkBadge(count)
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
    }

    private var callBannerHost: UIHostingController<SouveraIncomingCallBannerView>?

    // MARK: - Badges

    private weak var moreTabBarItem: UITabBarItem?

    /// Mail-Badge als System-Badge - identisch zum Link-Badge (einheitlich,
    /// deckend, korrekt in Portrait UND Landscape).
    private func updateMailBadge(_ count: Int) {
        mailTabBarItem?.badgeValue = count > 0 ? "\(count)" : nil
        JmapLog.write("Mail tab badge set -> \(count > 0 ? count : 0)")
    }

    /// Link-Badge als System-Badge (identisch zum Mail-Badge).
    private func updateLinkBadge(_ count: Int) {
        linkTabBarItem?.badgeValue = count > 0 ? "\(count)" : nil
    }

    private func updateMaintenanceDot(_ maintenance: Bool) {
        applyBadge(to: moreTabBarItem, baseName: "ellipsis.circle.fill", count: nil, dot: maintenance)
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
    /// voll deckend rechts überlappend).
    private static func badgedIcon(baseName: String, count: Int?, dot: Bool, selected: Bool) -> UIImage? {
        let base = UIImage(systemName: baseName)
        var canvasSize = base?.size ?? CGSize(width: 25, height: 25)
        if canvasSize.width < 10 || canvasSize.height < 10 {
            canvasSize = CGSize(width: 25, height: 25)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { _ in
            let iconColor: UIColor = selected
                ? NCBrandColor.shared.customer
                : UIColor.white
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
