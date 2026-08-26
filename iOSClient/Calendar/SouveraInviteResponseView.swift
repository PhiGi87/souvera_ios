// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Overlay für Termin-Einladungs-Antworten (P63): Zusagen / Absagen /
/// Vielleicht direkt in der App, plus Browser-Fallback für den Fall, dass
/// der Server ein anderes Antwort-Format erwartet.
struct SouveraInviteResponseView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var sending: SouveraInviteResponse.Action?
    @State private var resultText: String?
    @State private var succeeded: Bool?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                Text(NSLocalizedString("_invite_response_title_", comment: ""))
                    .font(.headline)
                Text(NSLocalizedString("_invite_response_body_", comment: ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if let resultText {
                    Text(resultText)
                        .font(.footnote)
                        .foregroundStyle((succeeded ?? false) ? Color.green : Color.red)
                        .padding(.horizontal)
                }

                if sending == nil {
                    HStack(spacing: 12) {
                        actionButton(.accepted, color: .green)
                        actionButton(.tentative, color: .orange)
                        actionButton(.declined, color: .red)
                    }
                } else {
                    ProgressView(NSLocalizedString("_invite_sending_", comment: ""))
                        .font(.footnote)
                }

                Button {
                    UIApplication.shared.open(url)
                    dismiss()
                } label: {
                    Text(NSLocalizedString("_invite_open_browser_", comment: ""))
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
            }
        }
    }

    private func actionButton(_ action: SouveraInviteResponse.Action, color: Color) -> some View {
        Button {
            send(action)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: action == .accepted ? "checkmark.circle.fill"
                    : action == .declined ? "xmark.circle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 30))
                Text(actionTitle(action))
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func actionTitle(_ action: SouveraInviteResponse.Action) -> String {
        switch action {
        case .accepted: return NSLocalizedString("_invite_accepted_", comment: "")
        case .declined: return NSLocalizedString("_invite_declined_", comment: "")
        case .tentative: return NSLocalizedString("_invite_tentative_", comment: "")
        }
    }

    private func send(_ action: SouveraInviteResponse.Action) {
        sending = action
        resultText = nil
        Task {
            let ok = await SouveraInviteResponse.respond(to: url, action: action)
            await MainActor.run {
                sending = nil
                succeeded = ok
                resultText = ok ? actionTitle(action) : NSLocalizedString("_invite_failed_", comment: "")
                if ok {
                    // Kurz das Ergebnis zeigen, dann schließen.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        dismiss()
                    }
                }
            }
        }
    }
}
