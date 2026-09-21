// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zwei-Schritt-Flow fuer geteilte Inhalte im Link-Bereich:
//   1) Raum waehlen (`SouveraShareRoomPicker`)
//   2) Inhalt + optionale Nachricht pruefen und senden (`SouveraShareSendView`)
// Feedback 22.09.: Das Nachrichtenfeld erscheint erst nach der Raumwahl und
// der geteilte Inhalt steht als Vorschau ueber dem Textfeld.

import SwiftUI
import UIKit

// MARK: - Schritt 1: Raum waehlen

struct SouveraShareRoomPicker: View {
    @ObservedObject var viewModel: LinkViewModel
    var onSelect: (LinkConversation) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.conversations {
                case .loading:
                    ProgressView().controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .error(let message):
                    ContentUnavailableView {
                        Label(NSLocalizedString("_error_", comment: ""), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button(NSLocalizedString("_retry_", comment: "")) { viewModel.loadConversations() }
                    }
                case .success(let rooms):
                    if rooms.isEmpty {
                        ContentUnavailableView(NSLocalizedString("_no_rooms_", comment: ""),
                                               systemImage: "bubble.left.and.bubble.right")
                    } else {
                        List(rooms) { room in
                            Button {
                                onSelect(room)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: room.type == 2 ? "bubble.left.and.bubble.right.fill" : "person.2.fill")
                                        .foregroundStyle(SouveraAppearance.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(room.displayName).font(.body).fontWeight(.medium).lineLimit(1)
                                        if room.lastActivity > 0 {
                                            Text(Self.relativeDate(room.lastActivity))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .tint(.primary)
                        }
                        .listStyle(.insetGrouped)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("_share_pick_room_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
            }
        }
        .onAppear { viewModel.loadConversations() }
    }

    private static func relativeDate(_ timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Schritt 2: Inhalt + optionale Nachricht senden

struct SouveraShareSendView: View {
    @ObservedObject var viewModel: LinkViewModel
    let room: LinkConversation
    var onClose: () -> Void

    @State private var message: String
    @State private var sending = false
    @State private var failed = false

    init(viewModel: LinkViewModel, room: LinkConversation, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.room = room
        self.onClose = onClose
        _message = State(initialValue: viewModel.shareHandoff?.text ?? "")
    }

    private var files: [SouveraPendingShareStore.SharedFile] {
        viewModel.shareHandoff?.files ?? []
    }

    var body: some View {
        NavigationStack {
            Form {
                if !files.isEmpty {
                    Section(NSLocalizedString("_share_", comment: "")) {
                        ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                            SouveraShareContentRow(file: file)
                        }
                    }
                }
                Section {
                    TextField(NSLocalizedString("_share_message_hint_", comment: ""), text: $message, axis: .vertical)
                        .lineLimit(1...6)
                } footer: {
                    Text(NSLocalizedString("_share_optional_message_", comment: ""))
                }
            }
            .navigationTitle(room.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { onClose() }
                        .disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button(NSLocalizedString("_send_", comment: "")) { send() }
                            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty)
                    }
                }
            }
            .alert(NSLocalizedString("_error_", comment: ""), isPresented: $failed) {
                Button(NSLocalizedString("_ok_", comment: ""), role: .cancel) {}
            } message: {
                Text(NSLocalizedString("_share_send_failed_", comment: ""))
            }
        }
    }

    private func send() {
        sending = true
        Task {
            let ok = await viewModel.sendSharedToRoom(token: room.token, title: room.displayName, message: message)
            sending = false
            if ok { onClose() } else { failed = true }
        }
    }
}

// MARK: - Content-Vorschau (Bild wenn moeglich, sonst Platzhalter + Name)

struct SouveraShareContentRow: View {
    let file: SouveraPendingShareStore.SharedFile

    var body: some View {
        HStack(spacing: 12) {
            preview
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.body).lineLimit(1)
                Text(Self.sizeText(file.size))
                    .font(.caption)
                    .foregroundStyle(file.tooLarge ? .red : .secondary)
            }
            Spacer()
            if file.tooLarge {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var preview: some View {
        if let image = UIImage(contentsOfFile: file.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                SouveraAppearance.accentColor.opacity(0.12)
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(SouveraAppearance.accentColor)
            }
        }
    }

    private var iconName: String {
        if file.mimeType.hasPrefix("image/") { return "photo" }
        if file.mimeType.hasPrefix("video/") { return "video" }
        if file.mimeType.hasPrefix("audio/") { return "waveform" }
        if file.mimeType.contains("pdf") { return "doc.richtext" }
        return "doc"
    }

    private static func sizeText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
