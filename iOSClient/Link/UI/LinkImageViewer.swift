// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// P68k: Vollbild-Viewer für Chat-Bilder (Tap aufs Inline-Thumbnail).
/// Schwarzes Overlay, Pinch-Zoom, Tap schließt, X-Button, Teilen-Sheet.
struct LinkImageViewer: View {
    let title: String
    let imageData: Data?

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var showShare = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let imageData, let ui = UIImage(data: imageData) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(max(lastScale * value, 1.0), 5.0)
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1.01 {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        scale = 1.0
                                        offset = .zero
                                    }
                                    lastScale = 1.0
                                    lastOffset = .zero
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1.0 else { return }
                                offset = CGSize(width: lastOffset.width + value.translation.width,
                                                height: lastOffset.height + value.translation.height)
                            }
                            .onEnded { _ in
                                lastOffset = offset
                                if scale <= 1.01 {
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            if scale > 1.0 {
                                scale = 1.0
                                offset = .zero
                                lastScale = 1.0
                                lastOffset = .zero
                            } else {
                                scale = 2.0
                                lastScale = 2.0
                            }
                        }
                    }
                    .onTapGesture(count: 1) {
                        dismiss()
                    }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text(NSLocalizedString("_link_image_loading_", comment: ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(16)
        }
        .overlay(alignment: .top) {
            if !title.isEmpty {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if imageData != nil {
                Button {
                    showShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(16)
            }
        }
        .sheet(isPresented: $showShare) {
            if let imageData, let ui = UIImage(data: imageData) {
                ActivityView(activityItems: [ui])
            }
        }
        .statusBarHidden()
    }
}

/// UIActivityViewController-Wrapper für das Teilen-Sheet im Viewer.
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
