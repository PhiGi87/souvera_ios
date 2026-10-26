// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 25.10. (Fix "Tastatur nicht manuell ausblendbar"): Apple-Standard-
// Mechanismen, damit Textfeld-Benutzer die Tastatur jederzeit selbst
// schliessen koennen und darunterliegende Menues erreichbar bleiben:
// - "Fertig"-Knopf in der Tastatur-Zubehoerleiste
//   (ToolbarItemGroup(placement: .keyboard))
// - globales endEditing via resignFirstResponder (SwiftUI-TextField und
//   UIKit-Fields ohne eigenen Fokus-Handle)

import SwiftUI
import UIKit

enum SouveraKeyboard {
    /// Blendet die Tastatur aus (Apple-Standard: ersteresponder abgeben).
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

/// Haengt einen "Fertig"-Knopf rechts in die Tastatur-Zubehoerleiste.
struct SouveraKeyboardDoneButton: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(NSLocalizedString("_done_", comment: "")) {
                    SouveraKeyboard.dismiss()
                }
            }
        }
    }
}

extension View {
    /// Run 25.10.: "Fertig"-Knopf fuer alle Textfeld-Standorte
    /// (Link-Chat-Composer, Mail-Verfassen, Kalender-Termin-Editor).
    func souveraKeyboardDoneButton() -> some View {
        modifier(SouveraKeyboardDoneButton())
    }
}
