// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

/// Zentrale Bausteine für den blauen Souvera-Header des Mehr-Menüs
/// (Root mit Logo und alle gepushten Unterseiten ohne Logo).
import Combine

enum SouveraAppearance {

    /// Obere Verlauffarbe - wird auch fuer den Füller oberhalb der
    /// UIKit-Bar verwendet (nahtloser Uebergang).
    static let gradientTopColor = UIColor(
        red: 0x2E / 255.0,
        green: 0x9B / 255.0,
        blue: 0xD8 / 255.0,
        alpha: 1
    )

    /// Vertikaler Souvera-Gradient als SwiftUI-Farben.
    /// P68w: deutlich dunkleres Blau als der frühere Verlauf
    /// (#4BBFEA → #496BBF war oben fast identisch zur alten Flachfarbe).
    static let gradientColors: [Color] = [
        Color(red: 0x2E / 255.0, green: 0x9B / 255.0, blue: 0xD8 / 255.0),
        Color(red: 0x2A / 255.0, green: 0x4F / 255.0, blue: 0x9F / 255.0)
    ]

    /// Run 22.09.: Primaerfarbe fuer Aktionen (oberer Gradient-Ton, #2E9BD8).
    static let accentColor = Color(red: 0x2E / 255.0, green: 0x9B / 255.0, blue: 0xD8 / 255.0)

    /// Gradient als Kachelbild (UIKit, Pattern-Hintergrund).
    static func gradientPatternImage() -> UIImage {
        let size = CGSize(width: 1, height: 120)
        let layer = CAGradientLayer()
        layer.frame = CGRect(origin: .zero, size: size)
        layer.colors = [
            UIColor(red: 0x2E / 255.0, green: 0x9B / 255.0, blue: 0xD8 / 255.0, alpha: 1).cgColor,
            UIColor(red: 0x2A / 255.0, green: 0x4F / 255.0, blue: 0x9F / 255.0, alpha: 1).cgColor
        ]
        layer.startPoint = CGPoint(x: 0, y: 0)
        layer.endPoint = CGPoint(x: 0, y: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            layer.render(in: context.cgContext)
        }
    }

    /// P68x: Verlauf über die GESAMTE Höhe eines Views (kein Kacheln).
    static func gradientLayer(frame: CGRect) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.colors = [
            UIColor(red: 0x2E / 255.0, green: 0x9B / 255.0, blue: 0xD8 / 255.0, alpha: 1).cgColor,
            UIColor(red: 0x2A / 255.0, green: 0x4F / 255.0, blue: 0x9F / 255.0, alpha: 1).cgColor
        ]
        layer.startPoint = CGPoint(x: 0, y: 0)
        layer.endPoint = CGPoint(x: 0, y: 1)
        layer.frame = frame
        return layer
    }

    /// Installiert den Verlauf hinter allen Subviews und gibt den Layer
    /// zurück (Frame bei Rotation/Resize über superlayer.bounds anpassen).
    static func applyGradientBackground(to view: UIView) -> CAGradientLayer {
        let layer = gradientLayer(frame: view.bounds)
        view.layer.insertSublayer(layer, at: 0)
        return layer
    }

    /// UIKit: blaue, deckende NavigationBar-Appearance (kein Glass-Effekt).
    static func blueNavigationBarAppearance() -> UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        // Run 04.10. (Fix: schmaler hellblauer Streifen am linken Rand auf
        // dem iPad): UIColor(patternImage:) KACHELT das nur 1x120 pt grosse
        // Gradientbild - in einer schmalen Spalte (iOS-26-Leading-Edge)
        // entstand daraus ein voll-hoher hellblauer Streifen. Als
        // backgroundImage wird der Verlauf von iOS auf die Bar-Groesse
        // GESTRECKT (nicht gekachelt); zusaetzlich eine solide
        // Fallback-Farbe in Verlaufsrichtung oben.
        appearance.backgroundImage = gradientPatternImage()
        appearance.backgroundImageContentMode = .scaleToFill
        appearance.backgroundColor = UIColor(red: 0x2E / 255.0, green: 0x9B / 255.0, blue: 0xD8 / 255.0, alpha: 1)
        appearance.backgroundEffect = nil
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        return appearance
    }

    /// Run 19.09. (Feedback iPad-Header: Farben verfaelscht): Wendet die
    /// blaue Appearance auf ALLE vier Appearance-Slots an und erzwingt
    /// deckend + hell. Als gemeinsamer Helper fuer Dateien, Mehr und die
    /// gebrueckten Module, damit die Bar ueber alle iOS-Versionen gleich
    /// aussieht. `tint` ist standardmaessig dunkel (Liquid-Glass-Items);
    /// Dateien/Mehr setzen weiss.
    static func applyBlueNavigationBar(to navigationBar: UINavigationBar,
                                       tint: UIColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)) {
        let appearance = blueNavigationBarAppearance()
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.compactScrollEdgeAppearance = appearance
        navigationBar.isTranslucent = false
        navigationBar.tintColor = tint
        navigationBar.overrideUserInterfaceStyle = .light
    }
}

/// Liquid-Glass-Effekt mit Fallback fuer iOS 17/18 (Inhalts-Bausteine,
/// z. B. SouveraInvitationFAB). Header verwenden ihn nicht mehr - dort
/// rendert die System-Bar.
struct SouveraHeaderGlass<S: Shape>: ViewModifier {
    let shape: S
    var active: Bool = true

    func body(content: Content) -> some View {
        if !active {
            content
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

// MARK: - SouveraHeaderBridge (Run 16.09.)
//
// Landscape/iPad: Mail, Kalender und Link nutzen statt der SwiftUI-Kopfzeile
// die SICHTBARE UIKit-Bar ihres Hosting-NavigationControllers (1:1 mit
// Mehr/Dateien: blauer Verlauf, Items flankieren die zentrierte Tab-Pill).
// Die SwiftUI-Module befüllen die Brücke (leading/trailing), der


final class SouveraHeaderBridge: ObservableObject {
    struct Item: Identifiable {
        let id: String
        let icon: String
        /// Titel fuer Overflow/Menues. Apple: Items mit Icon UND Titel
        /// passen sich am besten an (vertikale Bars nutzen das Icon, der
        /// Overflow den Titel).
        let text: String?
        let accessibilityLabel: String
        let isGreen: Bool
        let isDestructive: Bool
        /// Run 25.10.: Immer sichtbar (UINavigationItem.pinnedTrailingGroup)
        /// - fuer die Hauptaktion eines Moduls (Verfassen, Termin, Anruf).
        let isPinned: Bool
        let handler: () -> Void

        init(id: String, icon: String, text: String? = nil,
             accessibilityLabel: String = "",
             isGreen: Bool = false, isDestructive: Bool = false,
             isPinned: Bool = false,
             handler: @escaping () -> Void) {
            self.id = id
            self.icon = icon
            self.text = text
            self.accessibilityLabel = accessibilityLabel
            self.isGreen = isGreen
            self.isDestructive = isDestructive
            self.isPinned = isPinned
            self.handler = handler
        }
    }
    /// Menü-Eintrag (UIMenu) als kompakter Deskriptor.
    struct MenuEntry: Identifiable {
        let id: String
        let title: String
        let icon: String?
        let isChecked: Bool
        let isDestructive: Bool
        /// Run 23.10.: Untermenue (z. B. Sortierung) - wird als UIMenu
        /// gerendert und im Overflow mit Titel angezeigt.
        let children: [MenuEntry]?
        let handler: () -> Void

        init(id: String, title: String, icon: String? = nil,
             isChecked: Bool = false, isDestructive: Bool = false,
             children: [MenuEntry]? = nil,
             handler: @escaping () -> Void) {
            self.id = id
            self.title = title
            self.icon = icon
            self.isChecked = isChecked
            self.isDestructive = isDestructive
            self.children = children
            self.handler = handler
        }
    }
    struct MenuGroup: Identifiable {
        let id: String
        let icon: String
        /// Run 19.09.: Text-Button (z. B. "Woche") statt Icon - 1:1 iPhone.
        let title: String?
        /// Run 23.10.: Beschriftung im Overflow (kollabierte Gruppe).
        /// Getrennt von `title`, damit Icon-Buttons im Balken ihr Icon
        /// behalten und nur im Overflow Text zeigen.
        let overflowTitle: String?
        let accessibilityLabel: String
        let entries: [MenuEntry]
        let isPinned: Bool

        init(id: String, icon: String, title: String? = nil,
             overflowTitle: String? = nil,
             accessibilityLabel: String = "", entries: [MenuEntry],
             isPinned: Bool = false) {
            self.id = id
            self.icon = icon
            self.title = title
            self.overflowTitle = overflowTitle
            self.accessibilityLabel = accessibilityLabel
            self.entries = entries
            self.isPinned = isPinned
        }
    }
    @Published var leadingItems: [Item] = []
    @Published var leadingMenus: [MenuGroup] = []
    @Published var trailingItems: [Item] = []
    @Published var trailingMenus: [MenuGroup] = []
    @Published var title: String = ""

}

/// Beobachtet die Brücke und baut die Bar-Items des Host-Controllers.
@MainActor

// Run 16.09. (Feedback Landscape): Das Bridge-Rendering laeuft ueber die
// AEUSSERE UIKit-Bar - mit der blauen Mehr/Dateien-Appearance (volle
// Breite, Standard-Insets/Hoehe). Items werden als UIBarButtonItemGroups
// gesetzt (plain Items) - iOS 26 rendert sie damit als Liquid-Glass-
// Kreise, exakt wie bei Mehr/Dateien. Die innere SwiftUI-Bar bleibt in
// den Modul-Views versteckt.

final class SouveraBarCoordinator {
    private weak var navigationController: UINavigationController?
    private let bridge: SouveraHeaderBridge
    private var cancellables = Set<AnyCancellable>()
    private var lastSignature: String?

    init(navigationController: UINavigationController, bridge: SouveraHeaderBridge) {
        self.navigationController = navigationController
        self.bridge = bridge
        bridge.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        // Run 23.10.: Auch der Layout-Modus muss neu bauen - sonst bleibt
        // der Header nach Hoch-/Querformat- oder Fensterwechsel stehen.
        if let provider = navigationController as? SouveraLayoutModeProviding {
            provider.layoutMode.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.rebuild() }
                .store(in: &cancellables)
        }
        rebuild()
    }

    func rebuild() {
        // Run 25.10. (Header-Standard): Es gibt nur noch die System-Bar -
        // die Bridge befuellt sie auf JEDEM Geraet und in jeder Lage.
        guard let nav = navigationController, let item = nav.topViewController?.navigationItem else { return }
        // Run 19.09. (Feedback: Header-Rebuild-Sturm): Die Bridge published
        // sieben Einzelwerte -> siebenmal objectWillChange pro Befüllung.
        // Nur bei echter Inhaltsaenderung neu bauen/loggen.
        let signature = Self.signature(bridge)
        if signature == lastSignature { return }
        lastSignature = signature
        item.title = bridge.title.isEmpty ? nil : bridge.title
        // Run 24.10.: Was in der Bar steht, entscheiden die Module selbst
        // (der Kalender traegt im Band-Modus Leading/Trailing direkt um).
        let leading = Self.bars(bridge.leadingItems, bridge.leadingMenus)
        let trailing = Self.bars(bridge.trailingItems, bridge.trailingMenus)
        let pinned = trailing.filter { $0.isPinned }
        let regular = trailing.filter { !$0.isPinned }
        // Run 25.10.: Hauptaktion immer sichtbar - Apple: pinnedTrailingGroup
        // (iOS 26+), sonst als erstes rechtes Item.
        if #available(iOS 26.0, *) {
            item.pinnedTrailingGroup = nil
            if let firstPinned = pinned.first {
                item.pinnedTrailingGroup = UIBarButtonItemGroup(
                    barButtonItems: [firstPinned.bar],
                    representativeItem: firstPinned.representative
                )
            }
        }
        // Run 21.09. (Feedback iPadOS 17: Buttons fehlten): iPadOS 26
        // rendert left/rightBarButtonItems in der zentrierten Tab-Pill-Bar
        // NICHT (nur Item-Groups); iOS 17 rendert Plain-Image-Items in
        // UIBarButtonItemGroups nicht (Titel/Menues/Custom-Views schon).
        // Deshalb pro OS der passende Pfad.
        let useGroups: Bool
        if #available(iOS 26.0, *) {
            useGroups = true
        } else {
            useGroups = false
        }
        var trailingGroups = regular
        if #unavailable(iOS 26.0) {
            // Vor iOS 26 gibt es kein pinnedTrailingGroup - gepinnte Items
            // zuerst rechts anhaengen.
            trailingGroups = pinned + regular
        }
        if useGroups {
            item.leftBarButtonItems = nil
            item.rightBarButtonItems = nil
            item.leadingItemGroups = leading.map {
                UIBarButtonItemGroup(barButtonItems: [$0.bar], representativeItem: $0.representative)
            }
            item.trailingItemGroups = trailingGroups.map {
                UIBarButtonItemGroup(barButtonItems: [$0.bar], representativeItem: $0.representative)
            }
        } else {
            item.leadingItemGroups = []
            item.trailingItemGroups = []
            item.leftBarButtonItems = leading.isEmpty ? nil : leading.map(\.bar)
            item.rightBarButtonItems = trailingGroups.isEmpty ? nil : trailingGroups.map(\.bar)
        }
        #if !EXTENSION
        SouveraLog.write("Header", "[Header] \(bridge.title.isEmpty ? "-" : bridge.title) leading=\(leading.count) trailing=\(trailing.count) api=\(useGroups ? "groups" : "buttons")")
        #endif
    }

    /// Inhaltssignatur der Bridge (IDs + Icons/Titel/Texte) - erkennt echte
    /// Aenderungen, ignoriert die sieben Einzel-Publishes.
    private static func signature(_ bridge: SouveraHeaderBridge) -> String {
        func item(_ i: SouveraHeaderBridge.Item) -> String { "\(i.id):\(i.icon):\(i.text ?? ""):\(i.isGreen):\(i.isDestructive)" }
        func entry(_ e: SouveraHeaderBridge.MenuEntry) -> String {
            let kids = (e.children ?? []).map(entry).joined(separator: ",")
            return "\(e.id):\(e.title):\(e.isChecked):\(e.isDestructive):[\(kids)]"
        }
        func menu(_ m: SouveraHeaderBridge.MenuGroup) -> String {
            "\(m.id):\(m.icon):\(m.title ?? ""):\(m.overflowTitle ?? ""):" + m.entries.map(entry).joined(separator: ";")
        }
        let parts = [bridge.title]
            + bridge.leadingItems.map(item) + bridge.leadingMenus.map(menu)
            + bridge.trailingItems.map(item) + bridge.trailingMenus.map(menu)
        return parts.joined(separator: "|")
    }

    /// Run 19.09.: Baut die einzelnen Bar-Items (Items, Menues, Custom-
    /// Views). Custom-Views zuerst (Ring/Status), damit sie innen liegen.
    /// Ein Bar-Item plus optionales Repraesentativ-Item.
    private struct BarEntry {
        let bar: UIBarButtonItem
        let representative: UIBarButtonItem?
        var isPinned: Bool = false
    }

    private static func menuElement(_ entry: SouveraHeaderBridge.MenuEntry) -> UIMenuElement {
        let image = entry.icon.flatMap { UIImage(systemName: $0) }
        if let children = entry.children, !children.isEmpty {
            return UIMenu(title: entry.title,
                          image: image,
                          children: children.map(menuElement))
        }
        return UIAction(title: entry.title,
                        image: image,
                        attributes: entry.isDestructive ? .destructive : [],
                        state: entry.isChecked ? .on : .off) { _ in
            entry.handler()
        }
    }

    /// Baut Standard-Bar-Items (Apple-Standard) ausschliesslich aus Items
    /// und Menues. Es gibt keine Custom-View-Items mehr: Apple praesentiert
    /// Custom-Views weder in vertikalen Bars noch sinnvoll im Overflow.
    private static func bars(_ items: [SouveraHeaderBridge.Item],
                             _ menus: [SouveraHeaderBridge.MenuGroup]) -> [BarEntry] {
        var bars: [BarEntry] = []
        // Run 19.09. (Feedback iPad-Header): DUNKLE Icons - 1:1 mit dem
        // iPhone-Glas-Header und dem Mehr-Menue (die hellen Icons passten
        // nicht zur Bar). Gruen (Telefon) / rot (destruktiv) bleiben.
        let itemTint = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        for item in items where !item.icon.isEmpty || !(item.text ?? "").isEmpty {
            let bar: UIBarButtonItem
            if let text = item.text, !text.isEmpty {
                // Text-Items behalten ihr Icon (Apple: Icon UND Titel).
                let img = item.icon.isEmpty ? nil : UIImage(systemName: item.icon)
                bar = UIBarButtonItem(
                    title: text,
                    image: img,
                    primaryAction: UIAction(title: text, image: img) { _ in item.handler() }
                )
            } else {
                let img = UIImage(systemName: item.icon)
                bar = UIBarButtonItem(image: img, primaryAction: UIAction(image: img) { _ in item.handler() })
            }
            bar.tintColor = item.isGreen ? .systemGreen : (item.isDestructive ? .systemRed : itemTint)
            bar.accessibilityLabel = item.accessibilityLabel
            bars.append(BarEntry(bar: bar, representative: nil, isPinned: item.isPinned))
        }
        for menu in menus where !menu.icon.isEmpty || !(menu.title ?? "").isEmpty {
            let displayTitle = menu.overflowTitle?.isEmpty == false
                ? menu.overflowTitle!
                : (menu.title?.isEmpty == false ? menu.title! : menu.accessibilityLabel)
            let image = UIImage(systemName: menu.icon)
            let uiMenu = UIMenu(title: displayTitle,
                                children: menu.entries.map(menuElement))
            let bar: UIBarButtonItem
            if let title = menu.title, !title.isEmpty {
                bar = UIBarButtonItem(title: title, style: .plain, target: nil, action: nil)
            } else {
                bar = UIBarButtonItem(image: image)
            }
            bar.menu = uiMenu
            bar.tintColor = itemTint
            bar.accessibilityLabel = menu.accessibilityLabel
            let representative = UIBarButtonItem(title: displayTitle,
                                                 image: image,
                                                 primaryAction: nil,
                                                 menu: uiMenu)
            representative.tintColor = itemTint
            bars.append(BarEntry(bar: bar, representative: representative, isPinned: menu.isPinned))
        }
        return bars
    }
}

private extension UIBarButtonItem {
    func then(_ configure: (UIBarButtonItem) -> Void) -> UIBarButtonItem {
        configure(self)
        return self
    }
}
