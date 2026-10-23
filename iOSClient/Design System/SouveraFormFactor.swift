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
    static func kind(horizontalSizeClass: UIUserInterfaceSizeClass?,
                     idiom: UIUserInterfaceIdiom,
                     width: CGFloat) -> Kind {
        if horizontalSizeClass == .regular {
            return idiom == .pad ? .pad : .regularPhone
        }
        return .compactPhone
    }

    /// Regular-Breite der aktuellen Umgebung. Trait-basiert und damit
    /// auch in App-Extensions verfügbar (dort gibt es kein
    /// UIApplication.shared).
    static var isRegularWidth: Bool {
        UITraitCollection.current.horizontalSizeClass == .regular
    }

    /// Fenster-Bounds der aktiven Szene (statt UIScreen.main, das auf
    /// Zwei-Display-Geräten ambig ist). In App-Extensions liefert der
    /// Aufruf den Bildschirm, weil `view.window` dort bereits vorliegt.
    static var currentWindowBounds: CGRect {
        if let app = sharedApplication {
            let scenes = app.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
            let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
            if let bounds = window?.bounds { return bounds }
        }
        return UIScreen.main.bounds
    }

    /// `UIApplication.shared` ist in App-Extensions als nicht verfügbar
    /// markiert; der Selector greift zur Laufzeit darauf zu, ohne diese
    /// Einschränkung zu verletzen.
    private static var sharedApplication: UIApplication? {
        let selector = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: selector) else { return nil }
        return UIApplication.perform(selector)?.takeUnretainedValue() as? UIApplication
    }
}
