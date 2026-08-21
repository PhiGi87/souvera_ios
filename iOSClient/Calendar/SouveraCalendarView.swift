// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Placeholder screen for the upcoming calendar module (second tab).
// Shows a friendly "coming soon" notice until the calendar lands.

import SwiftUI

struct SouveraCalendarView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 48))
                    .foregroundStyle(Color(NCBrandColor.shared.customer))
                Text(NSLocalizedString("_calendar_coming_soon_", comment: ""))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(NSLocalizedString("_calendar_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
