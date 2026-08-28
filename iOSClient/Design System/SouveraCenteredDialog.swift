// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// P68t: Zentrales, ovales Bestätigungs-Popup (ersetzt die zuvor oben
/// verankerten Sprechblasen-Dialoge). Abgedunkelter Hintergrund,
/// zentrierte, stark abgerundete Karte mit Titel, Text und Aktionen.
struct SouveraCenteredDialog: View {
    struct DialogAction: Identifiable {
        enum Role {
            case primary
            case destructive
            case cancel
        }

        let id = UUID()
        let label: String
        let role: Role
        let action: () -> Void

        init(label: String, role: Role, action: @escaping () -> Void) {
            self.label = label
            self.role = role
            self.action = action
        }
    }

    let title: String
    let message: String?
    let actions: [DialogAction]

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture {
                    actions.first(where: { $0.role == .cancel })?.action()
                }
            VStack(spacing: 14) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 8) {
                    ForEach(actions) { action in
                        Button {
                            action.action()
                        } label: {
                            Text(action.label)
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .foregroundStyle(action.role == .cancel ? Color.primary : (action.role == .destructive ? Color.white : Color.white))
                                .background(
                                    Capsule().fill(action.role == .destructive
                                        ? Color.red.opacity(0.9)
                                        : (action.role == .cancel
                                            ? Color(.tertiarySystemFill)
                                            : Color(NCBrandColor.shared.customer)))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 30)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .shadow(color: .black.opacity(0.2), radius: 18, x: 0, y: 6)
        }
    }
}

/// Overlay-Modifier für das zentrale Dialog-Popup.
private struct SouveraCenteredDialogModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String?
    let actions: [SouveraCenteredDialog.DialogAction]

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                SouveraCenteredDialog(title: title, message: message, actions: actions.map { action in
                    SouveraCenteredDialog.DialogAction(label: action.label, role: action.role) {
                        isPresented = false
                        action.action()
                    }
                })
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isPresented)
    }
}

extension View {
    /// Zentrales ovales Popup (P68t).
    func souveraCenteredDialog(
        isPresented: Binding<Bool>,
        title: String,
        message: String? = nil,
        actions: [SouveraCenteredDialog.DialogAction]
    ) -> some View {
        modifier(SouveraCenteredDialogModifier(isPresented: isPresented, title: title, message: message, actions: actions))
    }
}
