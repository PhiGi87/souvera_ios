// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Souvera semantic color tokens (SwiftUI), backed by the adaptive
/// `UIColor.Souvera` palette.
extension Color {

    enum Souvera {
        static let brandPrimary: Color = Color(uiColor: UIColor.Souvera.brandPrimary)
        static let brandPrimaryDeep: Color = Color(uiColor: UIColor.Souvera.brandPrimaryDeep)
        static let brandOnPrimary: Color = Color(uiColor: UIColor.Souvera.brandOnPrimary)
        static let brandSurface: Color = Color(uiColor: UIColor.Souvera.brandSurface)
        static let brandIndigo: Color = Color(uiColor: UIColor.Souvera.brandIndigo)
    }
}
