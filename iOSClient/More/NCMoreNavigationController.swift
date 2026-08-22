// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2025 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import SwiftUI

class NCMoreNavigationController: NCMainNavigationController {
    override func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        super.navigationController(navigationController, willShow: viewController, animated: animated)

        if viewController === navigationController.viewControllers.first {
            // Nur die Mehr-Root bekommt den blauen Souvera-Header mit Logo.
            applySouveraHeader(viewController)
        } else {
            // Gepushte Module: Standard-Optik, kein blaues Header-Erbe.
            setNavigationBarAppearance()
            viewController.navigationItem.leftBarButtonItem = nil
            if viewController is NCCollectionViewCommon || viewController is NCActivity || viewController is NCTrash {
                return
            }
        }
    }

    /// Blauer Gradient-Header mit Souvera-Logo links (hell/dunkel identisch).
    private func applySouveraHeader(_ viewController: UIViewController) {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundImage = Self.souveraGradientImage()
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.compactScrollEdgeAppearance = appearance
        navigationBar.tintColor = .white

        viewController.navigationItem.title = ""
        let lockup = UIHostingController(rootView: SouveraBrandLockup())
        lockup.view.backgroundColor = .clear
        viewController.navigationItem.leftBarButtonItem = UIBarButtonItem(customView: lockup.view)
    }

    /// Vertikaler Souvera-Gradient (#4BBFEA → #496BBF) als Balkenbild.
    private static func souveraGradientImage() -> UIImage? {
        let size = CGSize(width: 1, height: 120)
        let layer = CAGradientLayer()
        layer.frame = CGRect(origin: .zero, size: size)
        layer.colors = [
            UIColor(red: 0x4B / 255.0, green: 0xBF / 255.0, blue: 0xEA / 255.0, alpha: 1).cgColor,
            UIColor(red: 0x49 / 255.0, green: 0x6B / 255.0, blue: 0xBF / 255.0, alpha: 1).cgColor
        ]
        layer.startPoint = CGPoint(x: 0, y: 0)
        layer.endPoint = CGPoint(x: 0, y: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            layer.render(in: context.cgContext)
        }
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

/// Marken-Lockup für den blauen Header: kleines App-Icon + weißer Name.
struct SouveraBrandLockup: View {
    var body: some View {
        HStack(spacing: 6) {
            Image("souveraMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text("Souvera")
                .font(.headline)
                .foregroundStyle(.white)
        }
        .fixedSize()
    }
}
