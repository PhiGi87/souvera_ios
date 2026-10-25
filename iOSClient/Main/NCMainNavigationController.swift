// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2025 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import SwiftUI
import NextcloudKit

class NCMainNavigationController: UINavigationController, UINavigationControllerDelegate {
    let database = NCManageDatabase.shared
    let global = NCGlobal.shared
    let utility = NCUtility()
    let utilityFileSystem = NCUtilityFileSystem()
    let appDelegate = (UIApplication.shared.delegate as? AppDelegate)!
    let menuToolbar = UIToolbar()

    /// Run 25.10.: Hintergrund des Streifens OBERHALB der System-Bar
    /// (Duo-Aussendisplay hochkant: Bar auf y = 24, darueber Fenster-
    /// hintergrund -> weisser Streifen). Rein dekorativ, keine Geometrie.
    private let headerBackdrop = SouveraHeaderBackdropView(frame: .zero)

    /// Run 24.10. (Duo-Außendisplay): Aktionen fuer die rechte Pille. Wird
    var controller: NCMainTabBarController? {
        self.tabBarController as? NCMainTabBarController
    }

    var collectionViewCommon: NCCollectionViewCommon? {
        topViewController as? NCCollectionViewCommon
    }

    var trashViewController: NCTrash? {
        topViewController as? NCTrash
    }

    var mediaViewController: NCMedia? {
        topViewController as? NCMedia
    }

    @MainActor
    var session: NCSession.Session {
        NCSession.shared.getSession(controller: controller)
    }

    let menuNavigation = NCContextMenuNavigation()
    var menuPlus: NCContextMenuPlus?

    let optionButtonTag = 100
    let assistantButtonTag = 101
    let notificationsButtonTag = 102
    let transfersButtonTag = 103

    lazy var optionButtonItem: UIBarButtonItem = {
        let item = UIBarButtonItem()
        item.tag = optionButtonTag
        return item
    }()
    lazy var assistantButtonItem: UIBarButtonItem = {
        let item = UIBarButtonItem()
        item.tag = assistantButtonTag
        return item
    }()
    lazy var notificationsButtonItem: UIBarButtonItem = {
        let item = UIBarButtonItem()
        item.tag = notificationsButtonTag
        return item
    }()
    lazy var transfersButtonItem: UIBarButtonItem = {
        let item = UIBarButtonItem()
        item.tag = transfersButtonTag
        return item
    }()

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        headerBackdrop.update(barMinY: navigationBar.frame.minY,
                              width: view.bounds.width)
    }

    // MARK: - View Life Cycle

    override func viewDidLoad() {
        super.viewDidLoad()
        self.delegate = self

        setNavigationBarAppearance()
        setNavigationBarHidden(false, animated: false)
        // Run 25.10.: UNTER der Bar, aber UEBER der Inhalts-View -
        // sonst deckt der weisse Listen-Hintergrund den Streifen ab.
        if navigationBar.superview === view {
            view.insertSubview(headerBackdrop, belowSubview: navigationBar)
        } else {
            view.addSubview(headerBackdrop)
        }

        Task {
            optionButtonItem.image = UIImage(systemName: "ellipsis")
            optionButtonItem.tintColor = NCBrandColor.shared.iconImageColor
            optionButtonItem.menu = await createOptionMenu()
        }

        assistantButtonItem.image = UIImage(systemName: "sparkles")
        assistantButtonItem.title = NSLocalizedString("_assistant_", comment: "")
        assistantButtonItem.tintColor = NCBrandColor.shared.iconImageColor
        assistantButtonItem.primaryAction = UIAction { [weak self] _ in
            self?.presentAssistant()
        }

        notificationsButtonItem.image = UIImage(systemName: "bell.fill")
        notificationsButtonItem.title = NSLocalizedString("_notifications_", comment: "")
        notificationsButtonItem.tintColor = NCBrandColor.shared.iconImageColor
        notificationsButtonItem.primaryAction = UIAction { [weak self] _ in
            self?.presentNotifications()
        }

        transfersButtonItem.image = UIImage(systemName: "arrow.left.arrow.right.circle.fill")
        transfersButtonItem.title = NSLocalizedString("_transfers_", comment: "")
        transfersButtonItem.tintColor = NCBrandColor.shared.iconImageColor
        transfersButtonItem.primaryAction = UIAction { [weak self] _ in
            self?.presentTransfers()
        }

        // PLUS BUTTON MENU
        let widthAnchor: CGFloat
        let trailingAnchor: CGFloat
        let trailingAnchorPad: CGFloat

        if #available(iOS 26.0, *) {
            widthAnchor = 44
            trailingAnchor = -15
            trailingAnchorPad = -20
        } else {
            let appearance = UIToolbarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = .clear
            appearance.backgroundEffect = nil
            appearance.shadowColor = .clear

            menuToolbar.standardAppearance = appearance
            menuToolbar.compactAppearance  = appearance
            menuToolbar.scrollEdgeAppearance = appearance
            menuToolbar.isTranslucent = true

            widthAnchor = 100
            trailingAnchor = 28
            trailingAnchorPad = -10
        }

        view.addSubview(menuToolbar)
        menuToolbar.translatesAutoresizingMaskIntoConstraints = false

        if UIDevice.current.userInterfaceIdiom == .pad {
            NSLayoutConstraint.activate([
                menuToolbar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: trailingAnchorPad),
                menuToolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
                menuToolbar.widthAnchor.constraint(equalToConstant: widthAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                menuToolbar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: trailingAnchor),
                menuToolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
                menuToolbar.widthAnchor.constraint(equalToConstant: widthAnchor)
            ])
        }

        menuPlus = NCContextMenuPlus(menuToolbar: menuToolbar, controller: controller)

        // CAPABILITIES UPDATE
        //
        NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: self.global.notificationCenterServerDidUpdate), object: nil, queue: nil) { notification in
            guard let userInfo = notification.userInfo,
                  let account = userInfo["account"] as? String else {
                return
            }

            Task { @MainActor in
                let capabilities = await NKCapabilities.shared.getCapabilities(for: account)
                let session = NCSession.shared.getSession(account: account)

                // Notification: die Glocke zeigen, wenn die Instanz die
                // Notifications-App aktiviert hat ODER ein APNs-Token
                // registriert ist (Push ist dann auf jeden Fall sinnvoll).
                let hasApnsToken = !NCPreferences().deviceTokenPushNotification.isEmpty
                if capabilities.notification.count == 0 && !hasApnsToken {
                    self.controller?.availableNotifications = false
                } else {
                    _ = await NextcloudKit.shared.getNotificationsAsync(account: account) { task in
                        Task {
                            let identifier = await NCNetworking.shared.networkingTasks.createIdentifier(
                                account: account,
                                name: "getNotifications"
                            )
                            await NCNetworking.shared.networkingTasks.track(identifier: identifier, task: task)
                        }
                    }
                    self.controller?.availableNotifications = true
                }
                await self.collectionViewCommonTrailingItemGroups()
                await self.menuPlus?.create(session: session)
            }
        }

        // REACHABILITY
        //
        NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: self.global.notificationCenterNetworkReachability), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Menu Plus
                await self.menuPlus?.create(session: session)
            }
        }
    }

    /// Run 24.10.: Gemeinsame Handler - auch vom SwiftUI-Mehr-Header genutzt.
    @MainActor
    func presentAssistant() {
        let inputModel = NCAssistantInputModel()
        let assistant = NCAssistant(
            assistantModel: NCAssistantModel(controller: controller, inputModel: inputModel),
            chatModel: NCAssistantChatModel(controller: controller, inputModel: inputModel),
            conversationsModel: NCAssistantChatConversationsModel(controller: controller)
        )
        let hostingController = UIHostingController(rootView: assistant)
        present(hostingController, animated: true, completion: nil)
    }

    @MainActor
    func presentNotifications() {
        if let navigationController = UIStoryboard(name: "NCNotification", bundle: nil).instantiateInitialViewController() as? UINavigationController,
           let viewController = navigationController.topViewController as? NCNotification {
            viewController.modalPresentationStyle = .pageSheet
            viewController.session = session
            present(navigationController, animated: true, completion: nil)
        }
    }

    @MainActor
    func presentTransfers() {
        let rootView = TransfersView(session: session, onClose: { [weak self] in
            self?.dismiss(animated: true)
        })
        let hosting = UIHostingController(rootView: rootView)
        hosting.modalPresentationStyle = .pageSheet
        present(hosting, animated: true)
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        // Run 25.10.: Header-Standard auf JEDER Seite (Dateien, Media,
        // Favoriten, Aktivitaeten, Mehr-Root und alle gepushten
        // Unterseiten wie Einstellungen): Bar minimiert nicht.
        viewController.navigationItem.souveraApplyHeaderStandard()
        Task { @MainActor in
            // PLUS BUTTON ONLY IN FILES
            if viewController is NCFiles {
                self.menuPlus?.hiddenPlusButton(false)
            } else {
                self.menuPlus?.hiddenPlusButton(true, animation: false)
            }
            // MENU
            setNavigationBarAppearance()
            await collectionViewCommonTrailingItemGroups()
        }
    }

    // MARK: - Right

    @MainActor
    func setNavigationRightItems() async {

        // COLLECTION EDIT MODE
        if let collectionViewCommon, collectionViewCommon.isEditMode {

            collectionViewCommon.tabBarSelect?.update(
                fileSelect: collectionViewCommon.fileSelect,
                metadatas: collectionViewCommon.getSelectedMetadatas(),
                userId: session.userId
            )
            collectionViewCommon.tabBarSelect?.show()
            // SEARCH (OFF)
            collectionViewCommon.navigationItem.searchController = nil

            let cancel = UIBarButtonItem(
                title: NSLocalizedString("_cancel_", comment: ""),
                style: .plain
            ) {
                Task {
                    await collectionViewCommon.setEditMode(false)
                }
            }

            let group = UIBarButtonItemGroup(
                barButtonItems: [cancel],
                representativeItem: nil
            )

            collectionViewCommon.navigationItem.trailingItemGroups = [group]
            return
        }

        // TRASH EDIT MODE
        if let trashViewController, trashViewController.isEditMode {

            trashViewController.tabBarSelect.update(selectOcId: [])
            trashViewController.tabBarSelect.show()

            let cancel = UIBarButtonItem(
                title: NSLocalizedString("_cancel_", comment: ""),
                style: .plain
            ) {
                trashViewController.setEditMode(false)
            }

            let group = UIBarButtonItemGroup(
                barButtonItems: [cancel],
                representativeItem: nil
            )

            trashViewController.navigationItem.trailingItemGroups = [group]
            return
        }

        // NORMAL MODE
        trashViewController?.tabBarSelect?.hide()
        collectionViewCommon?.tabBarSelect?.hide()
        // SEARCH (ON)
        collectionViewCommon?.navigationItem.searchController = collectionViewCommon?.searchController
        await collectionViewCommonTrailingItemGroups()
    }

    @MainActor
    private func collectionViewCommonTrailingItemGroups() async {
        guard let topViewController else {
            return
        }

        guard !(collectionViewCommon?.isEditMode ?? false),
              !(trashViewController?.isEditMode ?? false),
              !(mediaViewController?.isEditMode ?? false),
              !(topViewController is NCViewerPDF),
              !(topViewController is NCViewerRichDocument),
              !(topViewController is NCViewerDirectEditing)
        else {
            return
        }

        let capabilities = await NKCapabilities.shared.getCapabilities(for: session.account)

        // ---------------------------------------------------------
        // Build desired items
        // ---------------------------------------------------------

        var desiredItems: [UIBarButtonItem] = []

        // Benachrichtigungen + Übertragungen bleiben erhalten - AUSSER im
        // Dateien-Modul (NCFilesNavigationController): dort führt nur das
        // "..."-Menü (+ Assistent). Das Mehr-Menü behält beide Buttons.
        if !(self is NCFilesNavigationController) {
            if controller?.availableNotifications ?? false {
                desiredItems.append(notificationsButtonItem)
            }
            desiredItems.append(transfersButtonItem)
        }

        if capabilities.assistantEnabled {
            desiredItems.append(assistantButtonItem)
        }

        if let optionMenu = await createOptionMenu() {
            optionButtonItem.menu = optionMenu
            desiredItems.append(optionButtonItem)
        }

        // ---------------------------------------------------------
        // Read current items from trailingItemGroups
        // ---------------------------------------------------------

        // SwiftUI screens pushed from the More tab (contacts, shield, ...)
        // manage their own trailing items - keep the default
        // bell/assistant/transfers buttons off them.
        if topViewController is NCHostedScreen {
            return
        }

        let currentItems: [UIBarButtonItem] = topViewController.navigationItem.trailingItemGroups.flatMap { $0.barButtonItems }

        let currentTags = currentItems.map { $0.tag }
        let desiredTags = desiredItems.map { $0.tag }

        // If nothing changed → exit
        guard currentTags != desiredTags else {
            return
        }

        let group = UIBarButtonItemGroup(
            barButtonItems: desiredItems,
            representativeItem: nil
        )

        topViewController.navigationItem.trailingItemGroups = [group]
    }

    func createOptionMenu() async -> UIMenu? { return nil }

    func updateMenuOption() async {
        guard let topViewController else {
            return
        }
        let hasOptionButton = topViewController.navigationItem.trailingItemGroups
            .flatMap { $0.barButtonItems }
            .contains(where: { $0.tag == optionButtonTag })

        guard hasOptionButton else {
            return
        }

        optionButtonItem.menu = await createOptionMenu()

        // Force refresh of the bar button group if the menu instance changed.
        let currentGroups = topViewController.navigationItem.trailingItemGroups
        if !currentGroups.isEmpty {
            topViewController.navigationItem.trailingItemGroups = currentGroups
        }
    }

    // MARK: - Left

    func setNavigationLeftItems() async { }

    /// Changes the tint color of a specific left bar button item identified by tag.
    /// - Parameters:
    ///   - tag: The tag used to identify the UIBarButtonItem.
    ///   - color: The UIColor to be applied.
    @MainActor
    func setLeftItemColor(tag: Int, to color: UIColor) {
        guard
            let items = topViewController?.navigationItem.leftBarButtonItems,
            let item = items.first(where: { $0.tag == tag })
        else { return }

        applyTint(item, color: color)
    }

    /// Changes the tint color of all left bar button items currently visible
    /// in the topViewController's navigation item.
    /// - Parameter color: The UIColor to be applied.
    @MainActor
    func setAllLeftItemsColor(_ color: UIColor) {
        guard let items = topViewController?.navigationItem.leftBarButtonItems else { return }

        for item in items {
            applyTint(item, color: color)
        }
    }

    // MARK: - Tint helpers

    /// Applies a tint color to a given UIButton, handling both UIButton.Configuration
    /// and legacy setup with SF Symbols or titles.
    /// - Parameters:
    ///   - button: The UIButton to apply the color.
    ///   - color: The UIColor to be applied.
    @MainActor
    private func applyTint(_ button: UIButton, color: UIColor) {
        if var cfg = button.configuration {
            // Se in futuro userai UIButton.Configuration, tieni il colore allineato qui
            cfg.baseForegroundColor = color
            button.configuration = cfg
        } else {
            // Config attuale (nessuna configuration): SF Symbols sono template, quindi basta tintColor
            button.tintColor = color
            button.setTitleColor(color, for: .normal)
        }
    }

    @MainActor
    private func applyTint(_ item: UIBarButtonItem, color: UIColor) {
        if let button = item.customView as? UIButton {
            applyTint(button, color: color)
        } else {
            item.tintColor = color
        }
    }

    /// Updates the tint color of all preloaded and currently visible right bar buttons.
    /// - Parameter color: The UIColor to be applied to all right bar button items.
    @MainActor
    func updateRightBarButtonsTint(to color: UIColor) {
        let rightItems: [UIBarButtonItem] = [
            optionButtonItem,
            assistantButtonItem,
            notificationsButtonItem,
            transfersButtonItem
        ]

        for item in rightItems {
            applyTint(item, color: color)
        }

        if let visibleItems = topViewController?.navigationItem.rightBarButtonItems {
            for item in visibleItems {
                applyTint(item, color: color)
            }
        }
    }
}
