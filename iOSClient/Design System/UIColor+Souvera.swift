// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

/// Souvera semantic color tokens (UIKit).
///
/// Adaptive light/dark values derived from the Souvera brand assets
/// (see `docs/souvera-ios-redesign/02-brand-analysis.md`). The brand accent
/// `brandPrimary` (#4BBFEA) is an accent/flächenfarbe only — it is never used
/// as text on a light background. `brandPrimaryDeep` carries AA contrast for
/// on-brand fills, buttons and links.
extension UIColor {

    enum Souvera {

        /// Brand accent (cyan). Tint / emphasis only.
        static let brandPrimary: UIColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(hex: "#5BC3EE") ?? .systemBlue
                : UIColor(hex: "#4BBFEA") ?? .systemBlue
        }

        /// Deeper brand blue for on-brand fills, buttons and links (AA contrast).
        static let brandPrimaryDeep: UIColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(hex: "#5A9FDB") ?? .systemBlue
                : UIColor(hex: "#3B86D0") ?? .systemBlue
        }

        /// Text placed on top of `brandPrimaryDeep` fills.
        static let brandOnPrimary: UIColor = .white

        /// Subtle brand-tinted surface.
        static let brandSurface: UIColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? (UIColor(hex: "#4BBFEA") ?? .systemBlue).withAlphaComponent(0.18)
                : (UIColor(hex: "#4BBFEA") ?? .systemBlue).withAlphaComponent(0.12)
        }

        /// Indigo accent from the logo gradient, used by the Link/Talk module.
        static let brandIndigo: UIColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(hex: "#7C8FD4") ?? .systemBlue
                : UIColor(hex: "#496BBF") ?? .systemBlue
        }
    }
}
