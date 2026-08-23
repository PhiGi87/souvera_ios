// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2022 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UIKit

extension UINavigationController {

    // https://stackoverflow.com/questions/6131205/how-to-find-topmost-view-controller-on-ios
    override func topMostViewController() -> UIViewController {
        return self.visibleViewController!.topMostViewController()
    }

    func setNavigationBarAppearance(textColor: UIColor = NCBrandColor.shared.iconImageColor, backgroundColor: UIColor? = .systemBackground) {
        let appearance: UINavigationBarAppearance
        if SouveraAppearance.blueHeaderEnabled {
            // Globaler blauer Souvera-Header (alle Bereiche; das Logo bleibt
            // exklusiv auf der Mehr-Root).
            appearance = SouveraAppearance.blueNavigationBarAppearance()
            navigationBar.isTranslucent = false
            navigationBar.tintColor = .white
            navigationBar.overrideUserInterfaceStyle = .light
        } else {
            if #available(iOS 26.0, *) {
                appearance = UINavigationBarAppearance()
                appearance.configureWithDefaultBackground()
            } else {
                appearance = UINavigationBarAppearance()
                appearance.configureWithTransparentBackground()
                if topViewController is NCMedia {
                    // transparent
                } else {
                    appearance.backgroundColor = backgroundColor
                }
                appearance.shadowColor = .clear
                appearance.shadowImage = UIImage()
            }
            appearance.titleTextAttributes = [.foregroundColor: textColor]
            navigationBar.tintColor = textColor
            navigationBar.overrideUserInterfaceStyle = .unspecified
        }

        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.compactScrollEdgeAppearance = appearance

        navigationBar.prefersLargeTitles = false
    }
}
