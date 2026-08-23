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
    }

    // MARK: - Badges (voll deckend in die Tab-Icons gerendert)

    private weak var moreTabBarItem: UITabBarItem?

    private func updateMailBadge(_ count: Int) {
        applyBadge(to: mailTabBarItem, baseName: "envelope.fill", count: count, dot: false)
        JmapLog.write("Mail tab badge set -> \(count > 0 ? count : 0)")
    }

    private func updateLinkBadge(_ count: Int) {
        applyBadge(to: linkTabBarItem, baseName: "bubble.left.and.bubble.right.fill", count: count, dot: false)
    }

    private func updateMaintenanceDot(_ maintenance: Bool) {
        applyBadge(to: moreTabBarItem, baseName: "ellipsis.circle.fill", count: nil, dot: maintenance)
    }

    /// Zeichnet das Badge VOLL DECKEND direkt in das Tab-Icon - keine
    /// Subviews und keine Transparenz-Probleme auf iOS 26 (die TabBar
    /// kann nichts mehr überlagern oder durchscheinen lassen).
    private func applyBadge(to item: UITabBarItem?, baseName: String, count: Int?, dot: Bool) {
        guard let item else { return }
        let showCount = (count ?? 0) > 0
        if showCount || dot {
            item.image = Self.badgedIcon(baseName: baseName, count: showCount ? count : nil, dot: dot && !showCount, selected: false)
            item.selectedImage = Self.badgedIcon(baseName: baseName, count: showCount ? count : nil, dot: dot && !showCount, selected: true)
        } else {
            item.image = UIImage(systemName: baseName)
            item.selectedImage = UIImage(systemName: baseName)
        }
    }

    /// Badge-Icon: 32-pt-Canvas (3x-Skala) - Basis-Symbol unten links,
    /// rote Zahl-Kapsel bzw. oranger Punkt rechts überlappend am Icon.
    /// Inaktiv wird das Symbol weiß gezeichnet (wie die native TabBar-Optik),
    /// ausgewählt in Souvera-Blau. Das Badge ist pixeldeckend gerendert.
    private static func badgedIcon(baseName: String, count: Int?, dot: Bool, selected: Bool) -> UIImage? {
        let size = CGSize(width: 32, height: 32)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            let iconColor: UIColor = selected
                ? NCBrandColor.shared.customer
                : UIColor.white
            if let symbol = UIImage(systemName: baseName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)) {
                symbol.withTintColor(iconColor, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 4.5, y: 5, width: 23, height: 23))
            }
            if let count, count > 0 {
                let text = count > 99 ? "99+" : "\(count)"
                let font = UIFont.systemFont(ofSize: 9, weight: .bold)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
                let textSize = (text as NSString).size(withAttributes: attrs)
                let capsuleH: CGFloat = 11.5
                let capsuleW = max(textSize.width + 5, 12)
                let capsuleRect = CGRect(x: 32 - capsuleW - 0.5, y: 0.5, width: capsuleW, height: capsuleH)
                let path = UIBezierPath(roundedRect: capsuleRect, cornerRadius: capsuleH / 2)
                UIColor.systemRed.setFill()
                path.fill()
                UIColor.white.setStroke()
                path.lineWidth = 1
                path.stroke()
                (text as NSString).draw(
                    at: CGPoint(x: capsuleRect.midX - textSize.width / 2, y: capsuleRect.midY - textSize.height / 2),
                    withAttributes: attrs
                )
            } else if dot {
                let dotRect = CGRect(x: 24.5, y: 1, width: 7, height: 7)
                let path = UIBezierPath(ovalIn: dotRect)
                UIColor.systemOrange.setFill()
                path.fill()
                UIColor.white.setStroke()
                path.lineWidth = 1
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
