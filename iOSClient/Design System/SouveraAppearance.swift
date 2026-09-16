// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

/// Zentrale Bausteine für den blauen Souvera-Header des Mehr-Menüs
/// (Root mit Logo und alle gepushten Unterseiten ohne Logo).
enum SouveraAppearance {

    /// Run 16.09.: Header-Modus pro Geraet — das iPad rendert die blaue
    /// UIKit-Bar via SouveraHeaderBridge (1:1 Dateien/Mehr, Portrait und
    /// Landscape); iPhone (Portrait + Landscape) behalt den Glas-Header
    /// (SouveraModuleHeader) der SwiftUI-Views.
    static var useBridgeHeader: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// Vertikaler Souvera-Gradient als SwiftUI-Farben.
    /// P68w: deutlich dunkleres Blau als der frühere Verlauf
    /// (#4BBFEA → #496BBF war oben fast identisch zur alten Flachfarbe).
    static let gradientColors: [Color] = [
        Color(red: 0x2E / 255.0, green: 0x9B / 255.0, blue: 0xD8 / 255.0),
        Color(red: 0x2A / 255.0, green: 0x4F / 255.0, blue: 0x9F / 255.0)
    ]

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
        appearance.backgroundColor = UIColor(patternImage: gradientPatternImage())
        appearance.backgroundEffect = nil
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        return appearance
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
    @ViewBuilder var content: Content

    var body: some View {
        // Die Gruppe traegt DIE einzige Glass-Capsule - die Buttons darin
        // sind reine Icons (keine verschachtelten Kreise).
        HStack(spacing: 2) { content }
            .padding(.horizontal, 4)
            .modifier(SouveraHeaderGlass(shape: Capsule()))
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
    /// Zentrierter Titel (leer = kein Titel, z. B. Kalender-Root).
    var title: String = ""
    /// Titel links neben dem Leading-Block (Chat-Raum-Stil: "< Test Termin").
    var titleAfterLeading: Bool = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) { leading }

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
        }
        .padding(.horizontal, 12)
        .frame(height: 44, alignment: .top)
        // Run 15.09.: Gradient läuft unter den Buttons weiter; Höhe an
        // die Mehr/Dateien-Bar angepasst (Feedback: "2-4pt fehlen unten"
        // — nur die Unterkante, Button-Position unverändert).
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .environment(\.colorScheme, .light)
        .background(
            // Wie der Mehr-Verlauf: oben hell, unten dunkel
            // (Run 15.09., Feedback: Richtung war falsch herum).
            LinearGradient(colors: SouveraAppearance.gradientColors,
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
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
        let accessibilityLabel: String
        let isGreen: Bool
        let isDestructive: Bool
        let handler: () -> Void

        init(id: String, icon: String, accessibilityLabel: String = "",
             isGreen: Bool = false, isDestructive: Bool = false,
             handler: @escaping () -> Void) {
            self.id = id
            self.icon = icon
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
        let isDestructive: Bool
        let handler: () -> Void

        init(id: String, title: String, icon: String? = nil,
             isDestructive: Bool = false, handler: @escaping () -> Void) {
            self.id = id
            self.title = title
            self.icon = icon
            self.isDestructive = isDestructive
            self.handler = handler
        }
    }
    struct MenuGroup: Identifiable {
        let id: String
        let icon: String
        let accessibilityLabel: String
        let entries: [MenuEntry]

        init(id: String, icon: String, accessibilityLabel: String = "", entries: [MenuEntry]) {
            self.id = id
            self.icon = icon
            self.accessibilityLabel = accessibilityLabel
            self.entries = entries
        }
    }
    struct Custom: Identifiable {
        let id: String
        let view: UIView
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

// Run 16.09.: Das Bridge-Rendering laeuft jetzt ueber die INNERE
// SwiftUI-System-Bar (ToolbarItems) - dieselbe Pipeline, die auch
// Mehr/Dateien ihre Liquid-Glass-Kreise liefert. Die fruehere
// UIKit-Bar (SouveraBarCoordinator) produzierte eine flache Kapsel
// ohne Glass-Effekt und einen doppelten Header (Gap).

/// ViewModifier: rendert die Bridge-Items als individuelle
/// ToolbarItems in der inneren System-Navigationbar (nur iPad).
struct SouveraBridgeBarModifier: ViewModifier {
    let bridge: SouveraHeaderBridge?

    func body(content: Content) -> some View {
        if let bridge {
            content.modifier(SouveraBridgeBarActive(bridge: bridge))
        } else {
            content
        }
    }
}

private struct SouveraBridgeBarActive: ViewModifier {
    @ObservedObject var bridge: SouveraHeaderBridge

    func body(content: Content) -> some View {
        content
            .navigationTitle(SouveraAppearance.useBridgeHeader ? bridge.title : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(SouveraAppearance.useBridgeHeader ? .visible : .hidden,
                               for: .navigationBar)
            .toolbarBackground(
                LinearGradient(colors: SouveraAppearance.gradientColors,
                               startPoint: .top, endPoint: .bottom),
                for: .navigationBar)
            .toolbar {
                if SouveraAppearance.useBridgeHeader {
                    ForEach(bridge.leadingItems) { item in
                        ToolbarItem(placement: .topBarLeading) {
                            SouveraBridgeBarButton(item: item)
                        }
                    }
                    ForEach(bridge.leadingMenus) { group in
                        ToolbarItem(placement: .topBarLeading) {
                            SouveraBridgeMenuButton(group: group)
                        }
                    }
                    ForEach(bridge.leadingCustoms) { custom in
                        ToolbarItem(placement: .topBarLeading) {
                            UIKitViewWrapper(view: custom.view)
                        }
                    }
                    ForEach(bridge.trailingCustoms) { custom in
                        ToolbarItem(placement: .topBarTrailing) {
                            UIKitViewWrapper(view: custom.view)
                        }
                    }
                    ForEach(bridge.trailingItems) { item in
                        ToolbarItem(placement: .topBarTrailing) {
                            SouveraBridgeBarButton(item: item)
                        }
                    }
                    ForEach(bridge.trailingMenus) { group in
                        ToolbarItem(placement: .topBarTrailing) {
                            SouveraBridgeMenuButton(group: group)
                        }
                    }
                }
            }
    }
}

/// Einzelner Glas-Kreis-Button in der System-Bar (iOS 26 rendert
/// ToolbarItems automatisch als Liquid Glass - wie bei Mehr/Dateien).
struct SouveraBridgeBarButton: View {
    let item: SouveraHeaderBridge.Item

    var body: some View {
        Button {
            item.handler()
        } label: {
            Image(systemName: item.icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(item.isGreen ? Color.green : (item.isDestructive ? Color.red : .white))
        }
        .accessibilityLabel(Text(item.accessibilityLabel.isEmpty ? item.icon : item.accessibilityLabel))
    }
}

/// Menue-Button in der System-Bar.
struct SouveraBridgeMenuButton: View {
    let group: SouveraHeaderBridge.MenuGroup

    var body: some View {
        Menu {
            ForEach(group.entries) { entry in
                Button {
                    entry.handler()
                } label: {
                    Label(entry.title, systemImage: entry.icon)
                }
            }
        } label: {
            Image(systemName: group.icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
        }
        .accessibilityLabel(Text(group.accessibilityLabel.isEmpty ? group.icon : group.accessibilityLabel))
    }
}

/// Wrapper fuer UIKit-Custom-Views (Mail-Ring, Link Status-+) in der
/// SwiftUI-Toolbar.
struct UIKitViewWrapper: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private extension UIBarButtonItem {
    func then(_ configure: (UIBarButtonItem) -> Void) -> UIBarButtonItem {
        configure(self)
        return self
    }
}
