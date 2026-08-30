// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Kaltstart-Splash: vollflächiger Souvera-Verlauf mit großem Logo.
/// Wird beim App-Start für ~2 s über das Hauptfenster gelegt, damit der
/// Boot-Screen unabhängig vom (hartnäckig gecachten) statischen
/// Launch-Screen sauber sichtbar ist.
struct SouveraSplashView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: SouveraAppearance.gradientColors,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            Image("souveraLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 220)
        }
    }
}
