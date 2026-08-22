// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2025 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import SwiftUI

class NCMoreNavigationController: NCMainNavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()
        // Klassische UIKit-Optik statt Liquid Glass: verhindert die
        // Glaskapseln um Bar-Items und lässt das Logo linksbündig als
        // plain CustomView auf dem blauen Header sitzen.
        if #available(iOS 26.0, *) {
            navigationBar.preferredBehavioralStyle = .pad
        }
    }

    override func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        super.navigationController(navigationController, willShow: viewController, animated: animated)

        if viewController === navigationController.viewControllers.first {
            // Nur die Mehr-Root bekommt den blauen Souvera-Header mit Logo.
            applySouveraHeader(viewController)
            // Die Basisklasse setzt ihr Standard-Erscheinungsbild asynchron in
            // einem Task NACH diesem Aufruf wieder zurück. Deshalb hier
            // ebenfalls asynchron erneut anwenden - mein Task ist danach
            // eingereiht und gewinnt.
            Task { @MainActor in
                if viewController === navigationController.topViewController {
                    applySouveraHeader(viewController)
                }
            }
        } else {
            // Gepushte Module: Standard-Optik, kein blaues Header-Erbe.
            setNavigationBarAppearance()
            viewController.navigationItem.leftBarButtonItem = nil
            navigationBar.overrideUserInterfaceStyle = .unspecified
            if viewController is NCCollectionViewCommon || viewController is NCActivity || viewController is NCTrash {
                return
            }
        }
    }

    /// Blauer Gradient-Header mit Souvera-Logo links (hell/dunkel identisch,
    /// deckend - kein Liquid-Glass-Effekt auf iOS 26).
    private func applySouveraHeader(_ viewController: UIViewController) {
        guard let gradient = Self.souveraGradientImage() else { return }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        // Nur die Pattern-Hintergrundfarbe - backgroundImage kollidiert auf
        // iOS 26 mit dem Liquid-Glass-Effekt und wird ignoriert/geglast.
        appearance.backgroundColor = UIColor(patternImage: gradient)
        appearance.backgroundEffect = nil
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.compactScrollEdgeAppearance = appearance
        navigationBar.isTranslucent = false
        navigationBar.tintColor = .white
        navigationBar.overrideUserInterfaceStyle = .light

        viewController.navigationItem.title = ""
        // Offizielles Souvera-Logo (weiße Wortmarke) frei auf dem blauen
        // Header - links an der nativen Leading-Kante (bündig mit der
        // Menüliste darunter). Dank preferredBehavioralStyle = .pad gibt es
        // keine Glaskapsel um das CustomView.
        let imageView = UIImageView(image: UIImage(named: "souveraLogo"))
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView()
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            imageView.heightAnchor.constraint(equalToConstant: 32)
        ])
        viewController.navigationItem.leftBarButtonItem = UIBarButtonItem(customView: container)
    }

    /// Vertikaler Souvera-Gradient (#4BBFEA → #496BBF) als Kachelbild.
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
