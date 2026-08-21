// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// File browser for attaching files from the user's Souvera/Nextcloud account
// to a mail. Lists the WebDAV folder tree (readFolderAsync), lets the user
// drill into folders and downloads the picked file into a temporary location.

import SwiftUI

struct NextcloudFilePickerView: View {
    let onSelect: (URL?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var path = ""
    @State private var entries: [PickerEntry] = []
    @State private var loading = true
    @State private var downloading = false
    @State private var errorMessage: String?

    struct PickerEntry: Identifiable {
        let id: String
        let name: String
        let isDirectory: Bool
        let metadata: tableMetadata?
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Text(errorMessage).foregroundStyle(.secondary)
                        Button(NSLocalizedString("_mail_retry_", comment: "")) {
                            Task { await load() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                } else {
                    List(entries) { entry in
                        Button {
                            if entry.isDirectory {
                                path = entry.id
                                Task { await load() }
                            } else {
                                Task { await pick(entry) }
                            }
                        } label: {
                            HStack {
                                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                                    .foregroundStyle(Color(NCBrandColor.shared.customer))
                                Text(entry.name).lineLimit(1)
                                Spacer()
                                if downloading, entry.metadata != nil {
                                    ProgressView()
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(path.isEmpty ? NSLocalizedString("_mail_souvera_files_", comment: "") : (path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !path.isEmpty {
                        Button {
                            path = (path as NSString).deletingLastPathComponent
                            Task { await load() }
                        } label: {
                            Image(systemName: "chevron.backward")
                        }
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        defer { loading = false }

        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else {
            errorMessage = NSLocalizedString("_mail_credential_failed_", comment: "")
            return
        }
        let account = tbl.account
        let session = NCSession.shared.getSession(account: account)
        let home = NCUtilityFileSystem().getHomeServer(session: session)
        let serverUrl = path.isEmpty ? home : path

        let result = await NCNetworking.shared.readFolderAsync(serverUrl: serverUrl, account: account)
        guard result.error == .success, let metadatas = result.metadatas else {
            errorMessage = result.error.errorDescription
            return
        }
        entries = metadatas
            .filter { !$0.fileName.isEmpty }
            .sorted { $0.fileName.lowercased() < $1.fileName.lowercased() }
            .map { metadata in
                PickerEntry(
                    id: metadata.serverUrlFileName,
                    name: metadata.fileName,
                    isDirectory: metadata.directory,
                    metadata: metadata
                )
            }
    }

    private func pick(_ entry: PickerEntry) async {
        guard let metadata = entry.metadata else { return }
        downloading = true
        defer { downloading = false }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)_\(metadata.fileName)")
        let results = await NextcloudKit.shared.downloadAsync(
            serverUrlFileName: metadata.serverUrlFileName,
            fileNameLocalPath: tmp.path,
            account: metadata.account
        ) { _ in
        } taskHandler: { _ in
        } progressHandler: { _ in
        }
        if results.nkError == .success {
            onSelect(tmp)
            dismiss()
        } else {
            errorMessage = results.nkError.errorDescription
        }
    }
}
