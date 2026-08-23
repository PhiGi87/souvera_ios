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
            // Gepushte Module: blauer Header wie die Root (Logo bleibt
            // exklusiv auf der Root) - inkl. Async-Re-Apply gegen den
            // asynchronen Reset der Basisklasse.
            applyBlueHeader()
            viewController.navigationItem.leftBarButtonItem = nil
            showSouveraLogo(false)
            Task { @MainActor in
                if viewController === navigationController.topViewController {
                    applyBlueHeader()
                    showSouveraLogo(false)
                }
            }
            if viewController is NCCollectionViewCommon || viewController is NCActivity || viewController is NCTrash {
                return
            }
        }
    }

    /// Blauer Header ohne Logo (alle aus dem Mehr-Menü gepushten Screens).
    private func applyBlueHeader() {
        let appearance = SouveraAppearance.blueNavigationBarAppearance()
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.compactScrollEdgeAppearance = appearance
        navigationBar.isTranslucent = false
        navigationBar.tintColor = .white
        navigationBar.overrideUserInterfaceStyle = .light
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutSouveraLogo()
    }

    /// Positioniert das Logo: 20 pt von links (Flucht mit der Menüliste plus
    /// kleiner Korrektur), vertikal an der Höhe der rechten Buttons (6 pt
    /// über der Streifenmitte - Ausgleich der Wortmarken-Padding im PNG).
    /// Setzt bewusst KEIN isHidden - die Sichtbarkeit steuert allein
    /// showSouveraLogo aus willShow (nur auf der Mehr-Root sichtbar).
    private func layoutSouveraLogo() {
        guard let logo = souveraLogoView else { return }
        guard let root = viewControllers.first, root === topViewController else { return }
        let bar = navigationBar
        let contentHeight: CGFloat = 44
        let topInset = bar.bounds.height - contentHeight
        let logoHeight: CGFloat = 32
        let image = logo.image
        let ratio = (image?.size.height ?? logoHeight) > 0 ? (image?.size.width ?? 1) / (image?.size.height ?? 1) : 1
        let width = min(logoHeight * ratio, bar.bounds.width - 32)
        let y = max(topInset, topInset + (contentHeight - logoHeight) / 2 - 6)
        logo.frame = CGRect(
            x: 20,
            y: y,
            width: width,
            height: logoHeight
        )
    }

    /// Zeigt/versteckt das Logo (nur auf der Mehr-Root sichtbar).
    private func showSouveraLogo(_ show: Bool) {
        guard let logo = souveraLogoView else { return }
        logo.isHidden = !show
        if show { layoutSouveraLogo() }
    }

    /// Blauer Gradient-Header mit Souvera-Logo links (hell/dunkel identisch,
    /// deckend - kein Liquid-Glass-Effekt auf iOS 26). Nutzt die zentralen
    /// Bausteine aus SouveraAppearance.
    private func applySouveraHeader(_ viewController: UIViewController) {
        applyBlueHeader()

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
