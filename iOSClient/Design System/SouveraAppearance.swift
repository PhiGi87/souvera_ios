// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

/// Zentraler Schalter und Bausteine für den blauen Souvera-Header.
///
/// `blueHeaderEnabled` ist ein UserDefaults-Schalter (Standard: an). Bei
/// `false` gilt überall wieder der alte Look - AUSSER im Mehr-Menü (Root
/// mit Logo bleibt immer blau). So lässt sich die globale blaue Optik ohne
/// neuen Build zurückdrehen.
enum SouveraAppearance {
    static let blueHeaderKey = "souvera_blue_header_enabled"

    static var blueHeaderEnabled: Bool {
        if UserDefaults.standard.object(forKey: blueHeaderKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: blueHeaderKey)
    }

    /// Vertikaler Souvera-Gradient (#4BBFEA → #496BBF) als SwiftUI-Farben.
    static let gradientColors: [Color] = [
        Color(red: 0x4B / 255.0, green: 0xBF / 255.0, blue: 0xEA / 255.0),
        Color(red: 0x49 / 255.0, green: 0x6B / 255.0, blue: 0xBF / 255.0)
    ]

    /// Gradient als Kachelbild (UIKit, Pattern-Hintergrund).
    static func gradientPatternImage() -> UIImage {
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
