// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 07.10. (iPhone Duo): Fähigkeits-Erkennung über Traits statt über
// Gerätenamen/Idiom. Der Idiom bleibt auf dem iPhone Duo `.phone`, obwohl
// das Innendisplay regular/regular ist - Layoutentscheidungen dürfen
// deshalb nicht am Idiom hängen. Die reine Ableitung ist unit-testbar.

import UIKit

enum SouveraFormFactor {

    /// Grobe Formfaktor-Klasse (nur für Styling/Verhalten, nie für
    /// Geräte-Erkennung anhand von Namen).
    enum Kind: String, Equatable {
        /// Kompakte Breite (iPhone außen, iPhone hochkant, Split-View-Hälfte).
        case compactPhone
        /// Regular-Breite auf einem iPhone - iPhone Duo Innendisplay/Tent.
        case regularPhone
        /// iPad (regular).
        case pad
    }

    /// Reine Ableitung (unit-testbar): Size Class + Idiom.
    /// Die Breite bleibt als Parameter für künftige Feinheiten erhalten.
    static func kind(horizontalSizeClass: UserInterfaceSizeClass?,
                     idiom: UIUserInterfaceIdiom,
                     width: CGFloat) -> Kind {
        if horizontalSizeClass == .regular {
            return idiom == .pad ? .pad : .regularPhone
        }
        return .compactPhone
    }

    /// Regular-Breite der aktuellen Szene (UI-Kontext ohne SwiftUI-
    /// Environment). Erste (verbundene) Szene, damit auch der Aufbau in
    /// scene(_:willConnectTo:) bereits korrekt antwortet.
    static var isRegularWidth: Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        return scene?.traitCollection.horizontalSizeClass == .regular
    }

    /// Fenster-Bounds der aktuellen Szene (statt UIScreen.main, das auf
    /// Zwei-Display-Geräten ambig ist).
    static var currentWindowBounds: CGRect {
        UIApplication.shared.mainAppWindow?.bounds ?? UIScreen.main.bounds
    }
}
