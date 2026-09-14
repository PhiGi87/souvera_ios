// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// "Über die App" (Run 15.09.): 1:1 aus dem Android-Client übernommen
// (Struktur + Texte, Android-Pendant: AboutActivity.kt / souvera_about_*).
// Klärt die Herkunft der App: basiert auf Nextcloud iOS (Open Source),
// ist aber ein eigenständiges Produkt der Host-On Service Provider GmbH
// und kein Teil von Nextcloud. Repo-Links zeigen auf das Basisprojekt.

import SwiftUI

struct SouveraAboutView: View {

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return String(format: NSLocalizedString("_souvera_about_version_", comment: ""), version)
    }

    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String
            ?? "Souvera Workspace"
    }

    private let websiteURL = URL(string: "https://souvera.eu")!
    // Basisprojekt (wie im Android-Client: dort nextcloud/android).
    private let sourceCodeURL = URL(string: "https://github.com/nextcloud/ios")!

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 8)

                // App-Icon im Kreis (Android: 88dp Kreis, 64dp Icon,
                // Hintergrund #141E4666 = dunkelblau mit 8 % Alpha).
                ZStack {
                    Circle()
                        .fill(Color(red: 0x1E / 255.0, green: 0x46 / 255.0, blue: 0x66 / 255.0).opacity(0.08))
                    Image("souveraLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                }
                .frame(width: 88, height: 88)

                Text(appName)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)

                Text(versionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(NSLocalizedString("_souvera_about_text_", comment: ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)

                aboutSection(titleKey: "_souvera_about_based_on_",
                             bodyKey: "_souvera_about_based_on_text_",
                             bodyColor: .primary)

                aboutSection(titleKey: "_souvera_about_license_",
                             bodyKey: "_souvera_about_license_text_",
                             bodyColor: .secondary)

                // Pill-Buttons (Android: 44dp Höhe, Primärfarbe 10 %,
                // Kreisform, Label semibold-medium).
                HStack(spacing: 10) {
                    linkButton(NSLocalizedString("_souvera_about_open_website_", comment: ""), url: websiteURL)
                    linkButton(NSLocalizedString("_souvera_about_open_source_", comment: ""), url: sourceCodeURL)
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(NSLocalizedString("_settings_about_app_", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Abschnitt wie im Android-Client: fette Titelzeile, Text darunter.
    private func aboutSection(titleKey: String, bodyKey: String, bodyColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString(titleKey, comment: ""))
                .font(.headline)
            Text(NSLocalizedString(bodyKey, comment: ""))
                .font(.subheadline)
                .foregroundStyle(bodyColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Pill-Button wie der Android-LinkButton (Kreisform, Primärfarbe
    /// mit 10 % Alpha, Höhe 44).
    private func linkButton(_ label: String, url: URL) -> some View {
        Link(destination: url) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.Souvera.brandPrimaryDeep)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(
                    Capsule().fill(Color.Souvera.brandPrimaryDeep.opacity(0.10))
                )
        }
    }
}
