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
                .modifier(SouveraHeaderGlass(shape: Circle()))
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
        if #available(iOS 26.0, *) {
            // EINE gemeinsame Glass-Capsule fuer die ganze Gruppe - so
            // entstehen die zusammengefassten Doppel-Pills wie in
            // Dateien/Mehr (Einzel-Kreise verschmelzen im Container nicht).
            HStack(spacing: 2) { content }
                .padding(.horizontal, 4)
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            HStack(spacing: 2) { content }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
        }
    }
}

/// Liquid-Glass-Effekt mit Fallback für iOS 17/18.
struct SouveraHeaderGlass<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
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
        .frame(height: 44)
        .padding(.vertical, 6)
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
struct SouveraSwipeActionRow<Content: View>: View {
    let role: SouveraSwipeRole
    let icon: String
    let label: String
    let onTrigger: () -> Void
    @ViewBuilder var content: Content

    @State private var offsetX: CGFloat = 0
    @State private var triggered = false

    private let revealWidth: CGFloat = 132
    private let triggerThreshold: CGFloat = 100

    var body: some View {
        ZStack(alignment: .trailing) {
            // Farbfläche in voller Zeilenhöhe.
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                VStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.trailing, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(role.color)
            .opacity(offsetX > 0 ? 1 : 0)

            content
                .background(Color(.systemBackground))
                .offset(x: offsetX)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20, coordinateSpace: .local)
                        .onChanged { value in
                            guard value.translation.width < 0 else {
                                offsetX = 0
                                return
                            }
                            offsetX = max(value.translation.width, -revealWidth - 40)
                        }
                        .onEnded { value in
                            if value.translation.width < -triggerThreshold, !triggered {
                                triggered = true
                                onTrigger()
                                // Kurzes Feedback, dann zurückfedern.
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 350_000_000)
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        offsetX = 0
                                    }
                                    triggered = false
                                }
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    offsetX = 0
                                }
                            }
                        }
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
