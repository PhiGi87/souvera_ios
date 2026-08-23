// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// A single transient feedback toast shown at the bottom of the screen.
struct SouveraToast: Equatable, Identifiable {

    enum Style {
        case success
        case error
        case neutral

        var symbol: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error: return "xmark.circle.fill"
            case .neutral: return "info.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .success: return .green
            case .error: return .red
            case .neutral: return Color.Souvera.brandPrimary
            }
        }
    }

    let id: UUID = UUID()
    let message: String
    let style: Style
}

/// Central toast queue. Use `SouveraToastCenter.shared.show(...)` from anywhere
/// and attach the `souveraToast()` modifier once per screen to render the
/// result. This replaces the ad-hoc per-module toast overlays.
final class SouveraToastCenter: ObservableObject {
    static let shared = SouveraToastCenter()

    @Published private(set) var current: SouveraToast?
    private var task: Task<Void, Never>?

    func show(_ toast: SouveraToast, duration: TimeInterval = 2) {
        task?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            current = toast
        }
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.18)) {
                current = nil
            }
        }
    }
}

/// Attaches the shared toast overlay to a screen.
struct SouveraToastOverlay: ViewModifier {
    @ObservedObject private var center = SouveraToastCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = center.current {
                HStack(spacing: SouveraTokens.Spacing.xs) {
                    Image(systemName: toast.style.symbol)
                        .foregroundStyle(toast.style.color)
                    Text(toast.message)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, SouveraTokens.Spacing.md)
                .padding(.vertical, SouveraTokens.Spacing.sm)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.bottom, SouveraTokens.Spacing.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

extension View {
    func souveraToast() -> some View {
        modifier(SouveraToastOverlay())
    }
}
