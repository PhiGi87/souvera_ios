// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

/// Zentrale Bausteine für den blauen Souvera-Header des Mehr-Menüs
/// (Root mit Logo und alle gepushten Unterseiten ohne Logo).
enum SouveraAppearance {

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
                .frame(width: 48, height: 48)
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
        .frame(height: 48)
        .padding(.top, 6)
        .padding(.bottom, 10)
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

// MARK: - SouveraSwipeActionRow (Run 15.09.)
//
// Eigene Swipe-Geste statt List-swipeActions: volle Zeilenhöhe, flache
// Farffläche, Icon + Text INNERHALB der Fläche (iOS 26 rendert die
// System-Variante als Oval mit Text darunter). Die Farbe folgt der
// Funktion - Farbschema angelehnt an Apples Mail-App (blau = Aktionen
// wie Verschieben, grün = Annahme/Antworten, orange = Flaggen,
// rot = destruktiv, grau = neutral).

import SwiftUI

enum SouveraSwipeRole {
    case destructive   // rot - Entfernen/Löschen
    case positive      // grün - Zulassen/Accept
    case action        // blau - Verschieben/Weiterleiten
    case flag          // orange - Flaggen/Später
    case neutral       // grau - sonstiges

    var color: Color {
        switch self {
        case .destructive: return Color(red: 0.86, green: 0.16, blue: 0.16)   // #DB2929
        case .positive: return Color(red: 0.18, green: 0.72, blue: 0.27)     // #2EB845
        case .action: return Color(red: 0.20, green: 0.48, blue: 0.94)       // #337AEF
        case .flag: return Color(red: 0.96, green: 0.65, blue: 0.14)         // #F5A623
        case .neutral: return Color(red: 0.55, green: 0.57, blue: 0.60)      // grau
        }
    }
}

/// Zeile mit Swipe-Geste: der Inhalt bleibt fix, beim Ziehen nach links
/// deckt eine farbige Fläche (volle Zeilenhöhe) die Zeile ab; Icon + Text
/// stehen IN der Fläche. Überschreiten der Schwelle löst `onTrigger` aus
/// und die Zeile federt zurück.
/// Eine Swipe-Aktion: Rolle bestimmt die Farbe (Apple-Mail-Konvention).
struct SouveraSwipeAction: Identifiable {
    let role: SouveraSwipeRole
    let icon: String
    let label: String
    let handler: () -> Void
    var id: String { icon + label }
}

/// Zeile mit Custom-Swipe (Run 15.09.): volle Zeilenhöhe, Icon + Text
/// INNERHALB der Farffläche, mehrere Aktionen seitlich, tappbar wenn
/// aufgedeckt; horizontal-dominante Geste (vertikales Scrollen gewinnt).
/// Eine Swipe-Aktion: Rolle bestimmt die Farbe (Apple-Mail-Konvention).
struct SouveraSwipeAction: Identifiable {
    let role: SouveraSwipeRole
    let icon: String
    let label: String
    let handler: () -> Void
    var id: String { icon + label }
}

/// Zeile mit Custom-Swipe (Run 15.09., Neubau): Zwei Kanten (leading =
/// Swipe nach rechts, trailing = Swipe nach links), PROGRESSIVE Farb-/
/// Label-Logik - die aufgedeckte Fläche zeigt Farbe + Icon + Text des
/// Segments, das der aktuellen Swipe-Tiefe entspricht (Segmentbreite
/// ~90 pt). Loslassen löst die Aktion des aktuellen Segments aus
/// (Schwelle ~70 % Segmentbreite). Volle Zeilenhöhe, Label bis 2 Zeilen.
/// Eine Swipe-Aktion: Rolle bestimmt die Farbe (Apple-Mail-Konvention).
struct SouveraSwipeAction: Identifiable {
    let role: SouveraSwipeRole
    let icon: String
    let label: String
    let handler: () -> Void
    var id: String { icon + label }
}

/// Zeile mit Custom-Swipe (Run 15.09., Neubau): Zwei Kanten in EINER
/// Zeile - trailingActions (revealed durch Swipe nach LINKS) und
/// leadingActions (revealed durch Swipe nach RECHTS). PROGRESSIVE
/// Farb-/Label-Logik: die aufgedeckte Fläche zeigt Farbe + Icon + Text
/// des Segments, das der aktuellen Swipe-Tiefe entspricht (Segmentbreite
/// ~90 pt). Loslassen löst die Aktion des aktuellen Segments aus
/// (Schwelle ~70 % Segmentbreite). Volle Zeilenhöhe, Label bis 2 Zeilen.
struct SouveraSwipeActionRow<Content: View>: View {
    var leadingActions: [SouveraSwipeAction] = []
    var trailingActions: [SouveraSwipeAction] = []
    @ViewBuilder var content: Content

    @State private var offsetX: CGFloat = 0
    @State private var engaged = false

    private let segmentWidth: CGFloat = 90
    private var trailingTotal: CGFloat { CGFloat(trailingActions.count) * segmentWidth + 8 }
    private var leadingTotal: CGFloat { CGFloat(leadingActions.count) * segmentWidth + 8 }

    private var trailingReveal: CGFloat { max(0, -offsetX) }
    private var leadingReveal: CGFloat { max(0, offsetX) }

    private func currentAction(_ actions: [SouveraSwipeAction], _ reveal: CGFloat) -> SouveraSwipeAction? {
        guard !actions.isEmpty, reveal > 1 else { return nil }
        let depth = min(max(0, Int((reveal - 1) / segmentWidth)), actions.count - 1)
        return actions.indices.contains(depth) ? actions[depth] : nil
    }

    var body: some View {
        ZStack {
            // Trailing (Swipe nach links): rot "Löschen" -> tiefer blau ...
            if offsetX < -1, let action = currentAction(trailingActions, trailingReveal) {
                actionLayer(action)
                    .frame(width: trailingReveal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            // Leading (Swipe nach rechts): grün "Antworten" -> tiefer ...
            if offsetX > 1, let action = currentAction(leadingActions, leadingReveal) {
                actionLayer(action)
                    .frame(width: leadingReveal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }

            content
                .background(Color(.systemBackground))
                .offset(x: offsetX)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10, coordinateSpace: .local)
                        .onChanged { value in
                            if !engaged {
                                guard abs(value.translation.width) > 10,
                                      abs(value.translation.width) > abs(value.translation.height) else { return }
                                engaged = true
                            }
                            guard engaged else { return }
                            offsetX = min(max(value.translation.width,
                                              -trailingTotal - 40),
                                          leadingTotal + 40)
                        }
                        .onEnded { _ in
                            guard engaged else { return }
                            engaged = false
                            var handler: (() -> Void)?
                            if offsetX <= -segmentWidth * 0.7,
                               let action = currentAction(trailingActions, trailingReveal) {
                                handler = action.handler
                            } else if offsetX >= segmentWidth * 0.7,
                                      let action = currentAction(leadingActions, leadingReveal) {
                                handler = action.handler
                            }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                offsetX = 0
                            }
                            handler?()
                        }
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Farffläche des aktuellen Segments (volle Höhe, Text innen).
    private func actionLayer(_ action: SouveraSwipeAction) -> some View {
        VStack(spacing: 3) {
            Image(systemName: action.icon)
                .font(.system(size: 17, weight: .semibold))
            Text(action.label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(action.role.color)
    }
}
