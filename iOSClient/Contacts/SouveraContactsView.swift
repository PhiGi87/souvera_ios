// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Placeholder screen for the upcoming contacts module. Will connect to the
// Souvera/Nextcloud address books via CardDAV.

import SwiftUI

struct SouveraContactsView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(Color(NCBrandColor.shared.customer))
                Text(NSLocalizedString("_contacts_coming_soon_", comment: ""))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(NSLocalizedString("_contacts_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
