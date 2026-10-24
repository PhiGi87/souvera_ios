// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

/// Zentrale Bausteine für den blauen Souvera-Header des Mehr-Menüs
/// (Root mit Logo und alle gepushten Unterseiten ohne Logo).
import Combine

enum SouveraAppearance {

    /// Run 16.09.: Header-Modus pro Geraet — das iPad rendert die blaue
    /// UIKit-Bar via SouveraHeaderBridge (1:1 Dateien/Mehr, Portrait und
    /// Landscape); iPhone (Portrait + Landscape) behalt den Glas-Header
    /// (SouveraModuleHeader) der SwiftUI-Views.
    static var useBridgeHeader: Bool {
        // Run 07.10. (iPhone Duo): regular width statt Idiom - das
        // Innendisplay ist regular/regular, der Idiom bleibt aber .phone.
        if UIDevice.current.userInterfaceIdiom == .pad { return true }
        return SouveraFormFactor.isRegularWidth
    }

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

// MARK: - Souvera-Modul-Header (Run 15.09.)
//
// Die SwiftUI-Module Mail/Kalender/Link nutzen statt der System-Navigationbar
// einen eigenen Header: iOS 26 "Liquid Glass" ersetzt den per
// toolbarBackground gesetzten Verlauf durch eine Glas-Fläche (einheitliches
// Hellblau statt Verlauf) und rendert Buttons als getönte Glas-Pills. Der
// eigene Header ist pixel-exakt 1:1 mit den UIKit-Bars von Mehr/Dateien:
// blauer Verlauf (unten dunkel -> oben hell, hinter der Statusbar), weiße
// opake Pills mit dunklen Icons, weiße Titel.

import SwiftUI

/// Einzelner Header-Button: Liquid-Glass-Kreis mit adaptivem Icon
/// (hell = dunkles Icon, dunkel = helles Icon) - 1:1 die Optik der
/// System-Bar-Buttons im Mehr-Menü/Dateien (Run 15.09., Apple-Doku:
/// glassEffect(_:in:) + GlassEffectContainer, iOS 26).
struct SouveraHeaderButton: View {
    let icon: String
    var iconColor: Color? = nil
    /// false = ohne eigenen Glass-Effekt (innerhalb einer Header-Pill -
    /// die Pill traegt DIE einzige Glass-Capsule, sonst verschachtelte
    /// Kreise, Run 15.09.).
    var glass: Bool = true
    var accessibilityLabel: String = ""
    let action: () -> Void

    /// Fest dunkel - der Header erzwingt das Light-Schema (1:1 mit
    /// Mehr-Menue, das overrideUserInterfaceStyle = .light setzt).
    private var resolvedIconColor: Color {
        iconColor ?? Color(red: 0.1, green: 0.1, blue: 0.1)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(resolvedIconColor)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .modifier(SouveraHeaderGlass(shape: Circle(), active: glass))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Mehrere Header-Buttons in einem GlassEffectContainer: iOS 26 verschmilzt
/// die Kreise automatisch zu einer gemeinsamen Pill (wie die Doppel-Pills
/// in Dateien/Mehr). Fallback < iOS 26: eine Material-Capsule.
struct SouveraHeaderPill<Content: View>: View {
    /// Run 24.10.: In der UIKit-Bridge traegt die System-Gruppe bereits
    /// eine Glas-Kapsel - dann hier KEIN eigenes Glas (sonst Doppelring).
    var glass: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        // Die Gruppe traegt DIE einzige Glass-Capsule - die Buttons darin
        // sind reine Icons (keine verschachtelten Kreise).
        HStack(spacing: 2) { content }
            .padding(.horizontal, 4)
            .modifier(SouveraHeaderGlass(shape: Capsule(), active: glass))
    }
}

/// Liquid-Glass-Effekt mit Fallback für iOS 17/18.
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

/// Modul-Header: blauer Souvera-Verlauf hinter der Statusbar, Titel weiß,
/// Leading-/Trailing-Inhalte frei (Pills/Button-Ringe). Der Inhalt der
/// Screens wird per safeAreaInset unter den Header gesetzt (opak, Inhalt
/// läuft nicht dahinter durch - wie bei Mehr/Dateien).
struct SouveraModuleHeader<Leading: View, Trailing: View>: View {
    /// Run 24.10. (Feedback: Header-Hoehe je nach Tab/Lage verschieden):
    /// Feste Inhaltshoehe wie die UIKit-Bar - auf iOS 26/27 58 pt, auf
    /// aelteren Systemen das bisherige Mass (46 pt).
    private var contentHeight: CGFloat {
        if let heightOverride, heightOverride > 1 { return heightOverride }
        if #available(iOS 26.0, *) { return 58 }
        return 46
    }

    /// Zentrierter Titel (leer = kein Titel, z. B. Kalender-Root).
    var title: String = ""
    /// Titel links neben dem Leading-Block (Chat-Raum-Stil: "< Test Termin").
    var titleAfterLeading: Bool = false
    /// Run 24.10.: Zusaetzlicher Abstand, wenn die Statusleiste den Header
    /// ueberlappt (gemessen, nicht geraten).
    var extraTop: CGFloat = 0
    var extraTrailing: CGFloat = 0
    /// Run 24.10. (Duo-Außendisplay): Im Rail-Modus wandern die rechten
    /// Aktionen in die separate Pille; der Header zeigt dann nur noch
    /// Leading/Titel.
    /// Run 24.10.: Optionale Hohe (z. B. gemessene Systembar-Hoehe), damit
    /// der Mehr-Header exakt so hoch wie die Bridge-Bars ist.
    var heightOverride: CGFloat? = nil
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) { leading }
                .fixedSize(horizontal: true, vertical: false)

            if titleAfterLeading, !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                if !title.isEmpty {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) { trailing }
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12 + extraTrailing)
        .frame(height: contentHeight)
        .padding(.top, extraTop)
        .frame(maxWidth: .infinity)
        .environment(\.colorScheme, .light)
        .background(
            // Wie der Mehr-Verlauf: oben hell, unten dunkel
            // (Run 15.09., Feedback: Richtung war falsch herum).
            LinearGradient(colors: SouveraAppearance.gradientColors,
                           startPoint: .top, endPoint: .bottom)
                // Run 18.09. (iPhone Landscape): Verlauf MUSS auch in die
                // horizontalen Safe Areas laufen (dort ~59pt Insets) -
                // sonst wirkt der Header abgeschnitten (1:1 Mehr/Dateien).
                .ignoresSafeArea()
        )
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
        /// Run 19.09. (Feedback iPad-Header): Text-Item (z. B. "Heute",
        /// Ansichts-Modus) statt Icon - 1:1 wie der iPhone-Glas-Header.
        let text: String?
        let accessibilityLabel: String
        let isGreen: Bool
        let isDestructive: Bool
        let handler: () -> Void

        init(id: String, icon: String, text: String? = nil,
             accessibilityLabel: String = "",
             isGreen: Bool = false, isDestructive: Bool = false,
             handler: @escaping () -> Void) {
            self.id = id
            self.icon = icon
            self.text = text
            self.accessibilityLabel = accessibilityLabel
            self.isGreen = isGreen
            self.isDestructive = isDestructive
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

        init(id: String, icon: String, title: String? = nil,
             overflowTitle: String? = nil,
             accessibilityLabel: String = "", entries: [MenuEntry]) {
            self.id = id
            self.icon = icon
            self.title = title
            self.overflowTitle = overflowTitle
            self.accessibilityLabel = accessibilityLabel
            self.entries = entries
        }
    }
    struct Custom: Identifiable {
        let id: String
        let view: UIView
        /// Run 24.10.: Optionaler Halter (z. B. UIHostingController), damit
        /// interaktive SwiftUI-Pills im Balken nicht freigegeben werden.
        let retained: AnyObject?

        init(id: String, view: UIView, retained: AnyObject? = nil) {
            self.id = id
            self.view = view
            self.retained = retained
        }
    }

    @Published var leadingItems: [Item] = []
    @Published var leadingMenus: [MenuGroup] = []
    @Published var leadingCustoms: [Custom] = []
    @Published var trailingItems: [Item] = []
    @Published var trailingMenus: [MenuGroup] = []
    @Published var trailingCustoms: [Custom] = []
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

    /// Bridge-Modus dieses Tabs (nicht mehr global).
    private var usesBridgeHeader: Bool {
        (navigationController as? SouveraLayoutModeProviding)?.layoutMode.usesBridgeHeader ?? false
    }

    func rebuild() {
        // Run 25.09. (Feedback: doppelter Header auf iOS 17/18-iPhones):
        // Die Bridge gehoert NUR zur iPad-Bridge-Bar - auf dem iPhone
        // bleibt die aeussere Bar versteckt (Glas-Header), hier keine
        // Items setzen und nicht loggen.
        guard usesBridgeHeader else { return }
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
        let leading = Self.bars(bridge.leadingItems, bridge.leadingMenus, bridge.leadingCustoms)
        let trailing = Self.bars(bridge.trailingItems, bridge.trailingMenus, bridge.trailingCustoms)
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
        if useGroups {
            item.leftBarButtonItems = nil
            item.rightBarButtonItems = nil
            item.leadingItemGroups = leading.map {
                UIBarButtonItemGroup(barButtonItems: [$0.bar], representativeItem: $0.representative)
            }
            item.trailingItemGroups = trailing.map {
                UIBarButtonItemGroup(barButtonItems: [$0.bar], representativeItem: $0.representative)
            }
        } else {
            item.leadingItemGroups = []
            item.trailingItemGroups = []
            item.leftBarButtonItems = leading.isEmpty ? nil : leading.map(\.bar)
            item.rightBarButtonItems = trailing.isEmpty ? nil : trailing.map(\.bar)
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
            + bridge.leadingItems.map(item) + bridge.leadingMenus.map(menu) + bridge.leadingCustoms.map(\.id)
            + bridge.trailingItems.map(item) + bridge.trailingMenus.map(menu) + bridge.trailingCustoms.map(\.id)
        return parts.joined(separator: "|")
    }

    /// Run 19.09.: Baut die einzelnen Bar-Items (Items, Menues, Custom-
    /// Views). Custom-Views zuerst (Ring/Status), damit sie innen liegen.
    /// Ein Bar-Item plus optionales Repraesentativ-Item. iOS zeigt beim
    /// Kollabieren einer Gruppe das Repraesentativ-Item im Overflow an -
    /// ohne Titel blieben dort nur Icon + Chevron sichtbar (Feedback 23.10.).
    private struct BarEntry {
        let bar: UIBarButtonItem
        let representative: UIBarButtonItem?
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

    private static func bars(_ items: [SouveraHeaderBridge.Item],
                             _ menus: [SouveraHeaderBridge.MenuGroup],
                             _ customs: [SouveraHeaderBridge.Custom]) -> [BarEntry] {
        var bars: [BarEntry] = []
        for custom in customs {
            bars.append(BarEntry(bar: UIBarButtonItem(customView: custom.view), representative: nil))
        }
        // Run 19.09. (Feedback iPad-Header): DUNKLE Icons - 1:1 mit dem
        // iPhone-Glas-Header und dem Mehr-Menue (die hellen Icons passten
        // nicht zur Bar). Gruen (Telefon) / rot (destruktiv) bleiben.
        let itemTint = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        for item in items where !item.icon.isEmpty || !(item.text ?? "").isEmpty {
            let bar: UIBarButtonItem
            if let text = item.text, !text.isEmpty {
                // Run 24.10. (Feedback: Kalender-Header ohne Icons): Text-
                // Items muessen ihr Icon behalten - sonst zeigt die Bridge
                // nur "Heute"/"Monat", der Glas-Header aber Text+Icon.
                let img = item.icon.isEmpty ? nil : UIImage(systemName: item.icon)
                bar = UIBarButtonItem(
                    title: text,
                    image: img,
                    primaryAction: UIAction(title: text, image: img) { _ in item.handler() }
                )
            } else {
                // Run 21.09. (Feedback iPadOS 17: Button sichtbar, Icon nicht):
                // iOS 17 rendert den Inhalt der primaryAction - eine leere
                // UIAction lieferte weder Titel noch Bild. Das Bild muss in
                // die Aktion (und zusaetzlich ins Item fuer iOS 26).
                let img = UIImage(systemName: item.icon)
                bar = UIBarButtonItem(image: img, primaryAction: UIAction(image: img) { _ in item.handler() })
            }
            bar.tintColor = item.isGreen ? .systemGreen : (item.isDestructive ? .systemRed : itemTint)
            bar.accessibilityLabel = item.accessibilityLabel
            bars.append(BarEntry(bar: bar, representative: nil))
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
            bars.append(BarEntry(bar: bar, representative: representative))
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
