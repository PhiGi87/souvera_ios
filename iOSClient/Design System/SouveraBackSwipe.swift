// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Apple-like Kanten-Swipe-Back für SwiftUI-Route-Switches ohne Navigation-
/// Push: Beim Ziehen von der linken Bildschirmkante erscheint die vorherige
/// Ansicht als Preview dahinter (Parallax), die aktuelle Ansicht folgt dem
/// Finger mit Schatten. Über der Schwelle losgelassen: animierter Übergang
/// zurück (onBack), sonst Federrückstellung.
struct SouveraBackSwipe<Content: View, Preview: View>: View {
    let onBack: () -> Void
    let preview: Preview
    let content: Content

    @State private var dragOffset: CGFloat = 0

    init(onBack: @escaping () -> Void, @ViewBuilder preview: () -> Preview, @ViewBuilder content: () -> Content) {
        self.onBack = onBack
        self.preview = preview()
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                // Preview ist IMMER gemountet (Scrollposition bleibt
                // erhalten) und liegt links außerhalb; beim Kanten-Zug
                // gleitet sie herein.
                preview
                    .frame(width: width, height: geometry.size.height)
                    .offset(x: -width * 0.3 + dragOffset * 0.3)
                content
                    .frame(width: width, height: geometry.size.height)
                    .offset(x: dragOffset)
                    .shadow(color: dragOffset > 0 ? .black.opacity(0.25) : .clear, radius: 12, x: dragOffset > 0 ? -6 : 0, y: 0)
            }
            .contentShape(Rectangle())
            .gesture(backGesture(width: width))
        }
    }

    private func backGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard value.startLocation.x < 40,
                      value.translation.width > 0,
                      abs(value.translation.height) < abs(value.translation.width) else { return }
                dragOffset = min(value.translation.width, width * 0.9)
            }
            .onEnded { value in
                let qualifies = value.startLocation.x < 40
                    && value.translation.width > 80
                    && abs(value.translation.height) < abs(value.translation.width)
                if qualifies {
                    withAnimation(.easeOut(duration: 0.25)) {
                        dragOffset = width
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        dragOffset = 0
                        onBack()
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = 0
                    }
                }
            }
    }
}
