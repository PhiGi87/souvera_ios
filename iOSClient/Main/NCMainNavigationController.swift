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

    /// Run 24.10. (Duo-Außendisplay): Aktionen fuer die rechte Pille. Wird
    /// Run 24.10.: Füllfläche zwischen Fensteroberkante und Navigationsbar.
    /// iOS 27.1 reserviert im Seitenband-Modus oben Platz fuer die
    /// Status-Kapsel - opake UIKit-Bars ruecken dann herunter und der
    /// weisse View-Hintergrund blitzt auf. Die Fläche fuellt diese Lücke
    /// mit der oberen Verlaufsfarbe (nahtlos zur Bar).
    private lazy var headerFillerView: UIView = {
        let view = UIView()
        view.backgroundColor = SouveraAppearance.gradientTopColor
        view.isHidden = true
        return view
    }()

    /// Hoehe des Füllers oberhalb der Bar (fuer Diagnose in Subclasses).
    var headerFillerHeight: CGFloat {
        headerFillerView.isHidden ? -1 : headerFillerView.frame.height
    }

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

    // MARK: - View Life Cycle

    /// Run 25.10.: Liest die Occlusion-Regionen nach Apples Muster in
    /// updateConstraints (UIKit trackt die Lesung und ruft bei
    /// Regionswechseln erneut auf) und stoesst die Header-Geometrie an.
    private lazy var headerRegionObserver: SouveraReservedRegionObserver = {
        let observer = SouveraReservedRegionObserver(frame: .zero)
        observer.onOcclusionsChanged = { [weak self] occlusions in
            guard let self else { return }
            (self as? SouveraLayoutModeProviding)?.layoutMode
                .updateHeaderRegions(occlusions.map(\.frame),
                                     windowWidth: self.view.bounds.width)
            self.applyHeaderGeometry(occlusions: occlusions)
        }
        return observer
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        self.delegate = self

        setNavigationBarAppearance()
        setNavigationBarHidden(false, animated: false)
        view.insertSubview(headerFillerView, belowSubview: navigationBar)
        headerRegionObserver.install(in: view)

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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyHeaderGeometry()
        layoutHeaderFiller()
    }

    private var lastHeaderGeometryLog: String?

    /// Run 25.10.: Erzwingt die zentrale Header-Regel (SouveraHeaderGeometry)
    /// fuer ALLE UIKit-Bars: Dateien, Medien, Favoriten, Aktivitaeten und
    /// alle Mehr-Unterseiten (z. B. Einstellungen). Die Systemhoehe wird
    /// dabei bewusst ueberschrieben - sie liefert auf dem Duo je nach
    /// Zustand 0/24/46/58/82/140 pt.
    func applyHeaderGeometry(occlusions: [SouveraHeaderGeometry.Occlusion]? = nil) {
        guard !isNavigationBarHidden, !navigationBar.isHidden else { return }
        let window = view.window
        let bounds = window?.bounds.size ?? view.bounds.size
        let traits = window?.traitCollection ?? traitCollection
        // Run 25.10. (Apple-konform): Regionen kommen vom positionierenden
        // View (Observer, Lesung in updateConstraints) - niemals global.
        let regions = occlusions ?? headerRegionObserver.readOcclusions()
        (self as? SouveraLayoutModeProviding)?.layoutMode
            .updateHeaderRegions(regions.map(\.frame), windowWidth: bounds.width)
        let spec = SouveraHeaderGeometry.spec(
            windowSize: bounds,
            horizontalSizeClass: traits.horizontalSizeClass,
            idiom: traits.userInterfaceIdiom,
            safeAreaInsets: window?.safeAreaInsets ?? .zero,
            occlusions: regions
        )
        var frame = navigationBar.frame
        // Run 25.10. (1b): Die SwiftUI-Modul-Header halten rechts Platz
        // fuer die Kapsel frei (extraTrailing) - die UIKit-Bar gleiches
        // Recht ueber die Layout-Margins der Bar (die Bar-Items liegen
        // innerhalb der Margins).
        let frameChanged = abs(frame.minY - spec.bandTop) > 0.5
            || abs(frame.height - spec.height) > 0.5
        let marginsChanged = abs(navigationBar.directionalLayoutMargins.trailing - spec.trailingReserve) > 0.5
        guard frameChanged || marginsChanged else { return }
        if frameChanged {
            frame.origin.y = spec.bandTop
            frame.size.height = spec.height
            navigationBar.frame = frame
        }
        if marginsChanged {
            navigationBar.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: 0, leading: 0, bottom: 0, trailing: spec.trailingReserve)
        }
        // Inhalt (Titel/Buttons) im neuen Band neu zentrieren.
        navigationBar.layoutIfNeeded()
        let stamp = "\(Int(spec.bandTop))x\(Int(spec.height))r\(Int(spec.trailingReserve))"
        if stamp != lastHeaderGeometryLog {
            lastHeaderGeometryLog = stamp
            SouveraLog.write("SidebarActions",
                             "[SidebarActions] navBarSpec y=\(Int(spec.bandTop)) h=\(Int(spec.height)) reserve=\(Int(spec.trailingReserve))")
        }
    }

    /// Run 24.10.: Fuellt den Streifen oberhalb der Navigationsbar, falls
    /// das System ihn herunterrueckt (Safe-Area der Status-Kapsel).
    func layoutHeaderFiller() {
        guard !isNavigationBarHidden, !navigationBar.isHidden else {
            if !headerFillerView.isHidden { headerFillerView.isHidden = true }
            return
        }
        let height = max(0, min(navigationBar.frame.minY, view.bounds.height))
        let frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
        headerFillerView.isHidden = height <= 0.5
        if headerFillerView.frame != frame {
            headerFillerView.frame = frame
        }
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
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
