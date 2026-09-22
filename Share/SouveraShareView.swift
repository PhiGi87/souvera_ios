// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Souvera-Auswahlschirm im Apple-Teilen-Menue (Paritaet zur Android-App):
// geteilte Dateien + Text anzeigen und als Mail-Anhang, in die Dateien oder
// in einen Link-Raum uebergeben.

import SwiftUI
import UIKit

struct SouveraShareView: View {

    let files: [SouveraPendingShareStore.SharedFile]
    let sharedText: String
    let onMail: () -> Void
    let onUpload: () -> Void
    let onTalk: () -> Void
    let onCancel: () -> Void

    private static var brandPrimary: Color { SouveraAppearance.accentColor }

    private var usableFiles: [SouveraPendingShareStore.SharedFile] { files.filter { !$0.tooLarge } }
    private var trimmedText: String { sharedText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAct: Bool { !trimmedText.isEmpty || !usableFiles.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !files.isEmpty { fileList }
                    if !trimmedText.isEmpty { textRow }
                    if !canAct {
                        Text(NSLocalizedString("_share_empty_", comment: ""))
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                    actions
                }
                .padding(20)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private var header: some View {
        HStack {
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.white.opacity(0.22)))
            }
            .buttonStyle(.plain)
            Spacer()
            Text(NSLocalizedString("_share_", comment: ""))
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .background(
            LinearGradient(colors: SouveraAppearance.gradientColors,
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                HStack(spacing: 12) {
                    preview(for: file)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(.subheadline)
                            .lineLimit(2)
                        Text(file.tooLarge ? "> 10 MB" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(file.tooLarge ? Color.red : Color.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if index < files.count - 1 {
                    Divider().padding(.leading, 50)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Vorschau: Bild wenn moeglich, sonst Platzhalter-Symbol zum Dateityp.
    @ViewBuilder private func preview(for file: SouveraPendingShareStore.SharedFile) -> some View {
        if let image = UIImage(contentsOfFile: file.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                (file.tooLarge ? Color.red : Self.brandPrimary).opacity(0.12)
                Image(systemName: iconName(for: file))
                    .font(.title3)
                    .foregroundStyle(file.tooLarge ? Color.red : Self.brandPrimary)
            }
        }
    }

    private func iconName(for file: SouveraPendingShareStore.SharedFile) -> String {
        if file.mimeType.hasPrefix("image/") { return "photo" }
        if file.mimeType.hasPrefix("video/") { return "video" }
        if file.mimeType.hasPrefix("audio/") { return "waveform" }
        if file.mimeType.contains("pdf") { return "doc.richtext" }
        return "doc"
    }

    /// Run 22.09. (Feedback): Geteilter Text/URL als reine Inhaltszeile -
    /// das Nachrichtenfeld gibt es nur noch nach der Raumwahl im Link-Weg.
    private var textRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(trimmedText)
                .font(.subheadline)
                .lineLimit(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                onMail()
            } label: {
                Text(NSLocalizedString("_share_mail_", comment: ""))
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Self.brandPrimary))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!canAct)

            if !usableFiles.isEmpty {
                outlinedButton(NSLocalizedString("_share_upload_", comment: "")) { onUpload() }
            }
            outlinedButton(NSLocalizedString("_share_talk_", comment: "")) { onTalk() }
                .disabled(!canAct)
        }
    }

    private func outlinedButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 12).stroke(Self.brandPrimary, lineWidth: 1.5))
                .foregroundStyle(Self.brandPrimary)
        }
        .buttonStyle(.plain)
        .disabled(!canAct)
    }
}
