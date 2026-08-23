// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Unified loading / empty / error state, built on `ContentUnavailableView`
/// (iOS 17+). Replaces the ad-hoc `ProgressView` / `Text` state views that were
/// scattered across modules with a single consistent visual language.
struct SouveraStateView: View {

    enum State {
        case loading
        case empty(title: String, description: String? = nil, systemImage: String)
        case error(message: String)
    }

    let state: State
    var retry: (() -> Void)? = nil

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty(let title, let description, let systemImage):
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                if let description {
                    Text(description)
                }
            }

        case .error(let message):
            ContentUnavailableView {
                Label(NSLocalizedString("_error_", comment: ""),
                      systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if let retry {
                    Button(NSLocalizedString("_retry_", comment: ""), action: retry)
                        .buttonStyle(SouveraButtonStyle(kind: .secondary))
                }
            }
        }
    }
}
