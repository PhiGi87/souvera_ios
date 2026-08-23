// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Native Notes client for Souvera Workspace.
// Ported from souvera_android notes/SouveraNotesActivity.kt / NoteEditorScreen.kt.

import SwiftUI

struct SouveraNotesView: View {
    var body: some View {
        SouveraStateView(state: .empty(
            title: NSLocalizedString("_souvera_notes_", comment: ""),
            systemImage: "note.text"
        ))
        .navigationTitle(NSLocalizedString("_souvera_notes_", comment: ""))
    }
}
