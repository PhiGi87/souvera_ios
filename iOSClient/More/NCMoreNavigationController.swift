// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2025 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import SwiftUI

class NCMoreNavigationController: NCMainNavigationController {
    /// Logo als direkte Subview der NavigationBar (kein Bar-Item, keine
    /// titleView - deshalb keine Glaskapsel und exakt positionierbar).
    private weak var souveraLogoView: UIImageView?

    override func viewDidLoad() {
        super.viewDidLoad()
    }

    override func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        super.navigationController(navigationController, willShow: viewController, animated: animated)

        if viewController === navigationController.viewControllers.first {
            // Nur die Mehr-Root bekommt den blauen Souvera-Header mit Logo.
            applySouveraHeader(viewController)
            showSouveraLogo(true)
            // Die Basisklasse setzt ihr Standard-Erscheinungsbild asynchron in
            // einem Task NACH diesem Aufruf wieder zurück. Deshalb hier
            // ebenfalls asynchron erneut anwenden - mein Task ist danach
            // eingereiht und gewinnt.
            Task { @MainActor in
                if viewController === navigationController.topViewController {
                    applySouveraHeader(viewController)
                    showSouveraLogo(true)
                    layoutSouveraLogo()
                }
            }
        } else {
            // Gepushte Module: Standard-Optik, kein blaues Header-Erbe.
            setNavigationBarAppearance()
            viewController.navigationItem.leftBarButtonItem = nil
            navigationBar.overrideUserInterfaceStyle = .unspecified
            showSouveraLogo(false)
            if viewController is NCCollectionViewCommon || viewController is NCActivity || viewController is NCTrash {
                return
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutSouveraLogo()
    }

    /// Positioniert das Logo: x = 16 pt (Flucht mit der Menüliste), vertikal
    /// zentriert im 44-pt-Inhaltsstreifen unter der Statusleiste.
    private func layoutSouveraLogo() {
        guard let logo = souveraLogoView else { return }
        let bar = navigationBar
        let contentHeight: CGFloat = 44
        let topInset = bar.bounds.height - contentHeight
        let logoHeight: CGFloat = 32
        let image = logo.image
        let ratio = (image?.size.height ?? logoHeight) > 0 ? (image?.size.width ?? 1) / (image?.size.height ?? 1) : 1
        let width = min(logoHeight * ratio, bar.bounds.width - 32)
        logo.frame = CGRect(
            x: 16,
            y: topInset + (contentHeight - logoHeight) / 2,
            width: width,
            height: logoHeight
        )
        logo.isHidden = false
    }

    /// Zeigt/versteckt das Logo (nur auf der Mehr-Root sichtbar).
    private func showSouveraLogo(_ show: Bool) {
        guard let logo = souveraLogoView else { return }
        logo.isHidden = !show
        if show { layoutSouveraLogo() }
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
        viewController.navigationItem.leftBarButtonItem = nil
        viewController.navigationItem.titleView = nil

        // Offizielles Souvera-Logo (weiße Wortmarke) frei auf dem blauen
        // Header: als direkte Subview der Bar - keine Button-Kapsel, exakte
        // Positionierung in viewDidLayoutSubviews.
        if souveraLogoView == nil {
            let logo = UIImageView(image: UIImage(named: "souveraLogo"))
            logo.contentMode = .scaleAspectFit
            navigationBar.addSubview(logo)
            souveraLogoView = logo
        }
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
