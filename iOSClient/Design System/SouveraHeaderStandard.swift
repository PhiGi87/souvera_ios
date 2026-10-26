// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 25.10. (Header-Standard): SwiftUI-Seite der Minimierungs-Abschaltung.
// Die UIKit-Konfigurationen (UINavigationItem.navigationBarMinimization,
// UITabBarController.tabBarMinimizeBehavior) greifen nicht fuer
// SwiftUI-Scroll-Inhalte in Hosting-Controllern. Apple-Doku:
// "toolbarMinimizationBehavior(_:for:) ... .never: The toolbar cannot be
// minimized." (iOS 27+, Placement .navigationBar).

import SwiftUI

/// Unterbindet die Bar-Minimierung beim Scrollen fuer SwiftUI-Inhalte
/// (Listen/ScrollViews in Hosting-Controllern unter der System-NavigationBar).
struct SouveraFixedNavigationBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content
                .toolbarMinimizationBehavior(.never, for: .navigationBar)
        } else {
            content
        }
    }
}

extension View {
    /// Header-Standard: die NavigationBar minimiert nicht beim Scrollen.
    func souveraFixedNavigationBar() -> some View {
        modifier(SouveraFixedNavigationBarModifier())
    }
}
