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
    private var maintenanceDotActive = false
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
                self?.updateMailBadge(count)
            }
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

    /// Mail-Badge als System-Badge - identisch zum Link-Badge (einheitlich,
    /// deckend, korrekt in Portrait UND Landscape).
    private func updateMailBadge(_ count: Int) {
        mailTabBarItem?.badgeValue = count > 0 ? "\(count)" : nil
        JmapLog.write("Mail tab badge set -> \(count > 0 ? count : 0)")
    }

    /// Link-Badge als blauer System-Badge-Nachbau (gleiche Position/Form/Größe
    /// wie der rote Mail-Badge, nur blau gefüllt).
    private func updateLinkBadge(_ count: Int) {
        applyCountBadge(to: linkTabBarItem, baseName: "bubble.left.and.bubble.right.fill", count: count, color: .systemBlue)
    }

    private func updateMaintenanceDot(_ maintenance: Bool) {
        maintenanceDotActive = maintenance
        updateMoreTabItem()
    }

    /// Mehr-Tab-Badge: Summe aus Mail + Link. Blau, wenn Link-Ungelesen > 0,
    /// sonst rot (Mail). Ohne Ungelesen nur der Wartungs-Punkt.
    private func updateMoreBadge() {
        updateMoreTabItem()
    }

    private func updateMoreTabItem() {
        let store = SouveraBadgeStore.shared
        let total = store.totalMailUnread + store.totalLinkUnread
        if total > 0 {
            let color: UIColor = store.totalLinkUnread > 0 ? .systemBlue : .systemRed
            applyCountBadge(to: moreTabBarItem, baseName: "ellipsis.circle.fill", count: total, color: color)
        } else if maintenanceDotActive {
            applyBadge(to: moreTabBarItem, baseName: "ellipsis.circle.fill", count: nil, dot: true)
        } else {
            applyBadge(to: moreTabBarItem, baseName: "ellipsis.circle.fill", count: nil, dot: false)
        }
    }

    /// Setzt ein Zähler-Badge (Farbe wählbar) auf ein Tab-Icon. count <= 0
    /// entfernt das Badge und setzt das Original-Icon zurück.
    private func applyCountBadge(to item: UITabBarItem?, baseName: String, count: Int, color: UIColor) {
        guard let item else { return }
        if count > 0 {
            item.image = Self.countBadgedIcon(baseName: baseName, count: count, color: color, selected: false)
            item.selectedImage = Self.countBadgedIcon(baseName: baseName, count: count, color: color, selected: true)
        } else {
            item.image = UIImage(systemName: baseName)
            item.selectedImage = UIImage(systemName: baseName)
        }
        item.badgeValue = nil
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

    /// Zähler-Badge (System-Badge-Nachbau) auf einem Tab-Icon. Gleiche Position,
    /// Form und weiße fette Schrift wie das native rote Badge - nur die Füllung
    /// ist frei wählbar (z. B. blau für Link).
    private static func countBadgedIcon(baseName: String, count: Int, color: UIColor, selected: Bool) -> UIImage? {
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
            let text = count > 99 ? "99+" : "\(count)"
            let font = UIFont.systemFont(ofSize: 11, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white
            ]
            let textSize = (text as NSString).size(withAttributes: attrs)
            let badgeHeight: CGFloat = 14
            let badgeWidth = max(textSize.width + 8, badgeHeight)
            let badgeRect = CGRect(
                x: canvasSize.width - badgeWidth * 0.82,
                y: -badgeHeight * 0.12,
                width: badgeWidth,
                height: badgeHeight
            )
            let badgePath = UIBezierPath(roundedRect: badgeRect, cornerRadius: badgeHeight / 2)
            color.setFill()
            badgePath.fill()
            UIColor.white.setStroke()
            badgePath.lineWidth = 0.8
            badgePath.stroke()
            let textRect = CGRect(
                x: badgeRect.midX - textSize.width / 2,
                y: badgeRect.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attrs)
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
