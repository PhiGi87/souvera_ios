// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Central design tokens for the Souvera iOS design system.
///
/// Single source of truth for spacing, corner radii, component metrics and
/// typography roles. Productive views must reference these tokens instead of
/// hardcoding magic numbers, so the whole workspace keeps one visual rhythm.
enum SouveraTokens {

    // MARK: - Spacing (8-pt base, iOS-aligned)

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Corner radius

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }

    // MARK: - Component metrics

    enum Metrics {
        static let minimumTouchTarget: CGFloat = 44
        static let listRowHeight: CGFloat = 54
        static let primaryButtonHeight: CGFloat = 50
        static let iconButtonSize: CGFloat = 44
        static let avatarSize: CGFloat = 44
    }
}
