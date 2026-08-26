// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// "Über die App": Version, Lizenz- und Quellcode-Informationen mit
// klickbaren Links. Erreichbar über die Einstellungen.

import SwiftUI

struct SouveraAboutView: View {

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return String(format: NSLocalizedString("_about_version_", comment: ""), version, build)
    }

    private let gplLink = URL(string: "https://github.com/nextcloud/ios/blob/master/LICENSE.txt")!
    private let appStoreExceptionLink = URL(string: "https://github.com/nextcloud/ios/blob/master/COPYING.iOS")!
    private let sourceCodeLink = URL(string: "https://github.com/PhiGi87/souvera_ios")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Souvera Workspace for iOS")
                        .font(.title3.bold())
                    Text(versionText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("© 2026 Host-On Service Provider GmbH")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("Souvera Workspace – Ihre Daten. Ihre Sicherheit. Ihr moderner Workspace.")
                    .font(.body)

                Text(NSLocalizedString("_about_based_on_", comment: ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(NSLocalizedString("_about_gpl_part_", comment: ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Text(NSLocalizedString("_about_licenses_", comment: ""))
                        .font(.headline)
                    Link("GPLv3", destination: gplLink)
                    Link("Nextcloud iOS – Apple App Store Exception", destination: appStoreExceptionLink)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(NSLocalizedString("_about_source_", comment: ""))
                        .font(.headline)
                    Link(sourceCodeLink.absoluteString, destination: sourceCodeLink)
                        .font(.footnote)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(NSLocalizedString("_settings_about_app_", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}
