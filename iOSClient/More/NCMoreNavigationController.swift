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
        // Run 01.10.: neutraler Hintergrund der gemeinsamen Ebene (kein
        // Durchscheinen eines hellblauen Streifens am Rand).
        view.backgroundColor = .systemGroupedBackground
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
            // Run 01.10. (Feedback: hellblauer Streifen am linken Rand auf
            // ALLEN Mehr-Unterseiten): die gemeinsame Ebene leuchtet durch,
            // wenn die gepushte View transparent ist. Nav-Controller-View
            // und klar/nil-Views der gepushten Controller auf den Standard-
            // Hintergrund setzen (eigene Backgrounds der Screens bleiben
            // unberuehrt).
            view.backgroundColor = .systemGroupedBackground
            if viewController.view.backgroundColor == nil
                || viewController.view.backgroundColor == .clear {
                viewController.view.backgroundColor = .systemGroupedBackground
            }
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
        // Run 19.09.: gemeinsamer Helper (alle vier Slots, deckend, hell).
        SouveraAppearance.applyBlueNavigationBar(to: navigationBar, tint: .white)
    }

    /// Run 19.09. (Feedback iPad-Header): Appearance bei jedem Erscheinen/
    /// Layout neu erzwingen (iOS 26 setzt sie sonst asynchron zurueck).
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        ensureHeaderVisible()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyBlueHeader()
        layoutSouveraLogo()
    }

    /// Run 24.10. (Feedback: Header in schmalen Fenstern abgeschnitten/
    /// durchscheinend): iOS 27 setzt die Appearance beim Erscheinen und
    /// Scrollen zurueck. Nach dem vollstaendigen Erscheinen erneut opak
    /// setzen und das Logo neu positionieren.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ensureHeaderVisible()
        // Run 24.10.: Nach Drehen/Fensterwechsel war die Bar teils 0 pt
        // hoch - im naechsten Run noch einmal erzwingen und layouten.
        DispatchQueue.main.async { [weak self] in
            self?.ensureHeaderVisible()
        }
    }

    /// Erzwingt die sichtbare, opake Bar (nur fuer die Mehr-Root). iOS 27
    /// blendet sie beim Uebergang/Drehen gelegentlich aus (bar=0) und
    /// laesst sie ausgeblendet.
    private func ensureHeaderVisible() {
        guard let root = viewControllers.first, root === topViewController else { return }
        if isNavigationBarHidden {
            setNavigationBarHidden(false, animated: false)
        }
        if navigationBar.isHidden {
            navigationBar.isHidden = false
        }
        applyBlueHeader()
        if navigationBar.bounds.height < 1 {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            applyBlueHeader()
        }
        layoutSouveraLogo()
        SouveraLog.write("More", "[MoreHeader] ensure hidden=\(isNavigationBarHidden) barHidden=\(navigationBar.isHidden) translucent=\(navigationBar.isTranslucent) bar=\(Int(navigationBar.bounds.width))x\(Int(navigationBar.bounds.height)) safeTop=\(Int(navigationBar.safeAreaInsets.top))")
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
        // Run 23.10. (Feedback: "Souvera" oben abgeschnitten, Screenshot
        // nicht beschnitten): Die Ableitung aus der Bar-Hoehe konnte in
        // Fenster-Szenen negativ werden und schob das Logo ueber die Kante.
        // Jetzt echte Safe-Area verwenden und y nie unter 0 klemmen.
        // Content-Bereich der Bar (unter der Status-/Fensterleiste). Nur
        // nach unten klemmen - ein negativer Wert schob das Logo aus dem
        // Bild.
        let topInset = max(0, bar.bounds.height - contentHeight)
        let logoHeight: CGFloat = 32
        let image = logo.image
        let ratio = (image?.size.height ?? logoHeight) > 0 ? (image?.size.width ?? 1) / (image?.size.height ?? 1) : 1
        let width = min(logoHeight * ratio, max(0, bar.bounds.width - 32))
        let y = max(0, topInset + (contentHeight - logoHeight) / 2 - 6)
        let frame = CGRect(
            x: 20,
            y: y,
            width: width,
            height: logoHeight
        )
        if logo.frame != frame {
            logo.frame = frame
            SouveraLog.write("More", "[MoreHeader] bar=\(Int(bar.bounds.width))x\(Int(bar.bounds.height)) safeTop=\(Int(bar.safeAreaInsets.top)) logoY=\(Int(y)) window=\(Int(view.window?.bounds.width ?? 0))x\(Int(view.window?.bounds.height ?? 0)) translucent=\(bar.isTranslucent)")
        }
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
