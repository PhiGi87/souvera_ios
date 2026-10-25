// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2025 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import SwiftUI

class NCMoreNavigationController: NCMainNavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        // Run 25.10. (Header-Standard): Auch die Mehr-Root nutzt die
        // System-Bar - gleiche Appearance wie Dateien und alle Module.
        SouveraAppearance.applyBlueNavigationBar(to: navigationBar, tint: .white)
    }

    override func navigationController(_ navigationController: UINavigationController,
                                       willShow viewController: UIViewController,
                                       animated: Bool) {
        super.navigationController(navigationController, willShow: viewController, animated: animated)

        let isRoot = viewController === navigationController.viewControllers.first
        if isRoot {
            viewController.navigationItem.leftBarButtonItem = nil
            viewController.navigationItem.titleView = nil
        } else {
            viewController.navigationItem.leftBarButtonItem = nil
            // Run 01.10.: hellblauer Streifen am linken Rand auf gepushten
            // Mehr-Seiten verhindern.
            view.backgroundColor = .systemGroupedBackground
            if viewController.view.backgroundColor == nil
                || viewController.view.backgroundColor == .clear {
                viewController.view.backgroundColor = .systemGroupedBackground
            }
        }
        applyBlueHeader()
        Task { @MainActor in
            if viewController === navigationController.topViewController {
                self.applyBlueHeader()
            }
        }
        SouveraLog.write("More", "[MoreHeader] willShow root=\(isRoot) bar=\(Int(navigationBar.bounds.width))x\(Int(navigationBar.bounds.height))")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyBlueHeader()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyBlueHeader()
    }

    /// Blauer Header ohne Logo (gepushte Mehr-Unterseiten).
    private func applyBlueHeader() {
        SouveraAppearance.applyBlueNavigationBar(to: navigationBar, tint: .white)
    }

    // MARK: - Right

    override func createOptionMenu() async -> UIMenu? {
        // TRASH MENU
        //
        if trashViewController != nil {
            if let items = await NCContextMenuNavigation().viewMenuOption(
                trashViewController: trashViewController,
                mainNavigationController: self,
                session: self.session
            ) {
                return UIMenu(children: items)
            } else {
                return nil
            }
        }

        // COLLECTION VIEW COMMON MENU
        //
        let items = await NCContextMenuNavigation().viewMenuOption(
            collectionViewCommon: collectionViewCommon,
            mainNavigationController: self,
            session: self.session
        )

        if collectionViewCommon?.layoutKey == global.layoutViewRecent, let items {
            return UIMenu(children: [items.select, items.viewStyleSubmenu])
        } else if collectionViewCommon?.layoutKey == global.layoutViewOffline, let items {
            return UIMenu(children: [items.select, items.viewStyleSubmenu, items.sortSubmenu])
        } else if collectionViewCommon?.layoutKey == global.layoutViewShares, let items {
            return UIMenu(children: [items.select, items.viewStyleSubmenu, items.sortSubmenu])
        } else if collectionViewCommon?.layoutKey == global.layoutViewGroupfolders, let items {
            return UIMenu(children: [items.select, items.viewStyleSubmenu, items.sortSubmenu])
        } else if collectionViewCommon?.layoutKey == global.layoutViewFiles, let items {
            let additionalSettings = UIMenu(title: "", options: .displayInline, children: [items.showDescription])
            return UIMenu(children: [items.select, items.viewStyleSubmenu, items.sortSubmenu, additionalSettings])
        } else {
            return nil
        }
    }
}
