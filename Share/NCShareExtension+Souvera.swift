// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Souvera-Teilen: liest Text/URL und Dateien aus den Extension-Items,
// kopiert Dateien in den App-Group-Container (10-MB-Cap) und uebergibt sie
// per Deep-Link an die App (Mail-Anhang / Link-Raum).

import UIKit
import SwiftUI
import UniformTypeIdentifiers
import NextcloudKit

/// Ein geteilter Inhalt aus dem Apple-Teilen-Menue.
struct SouveraSharedPayload {
    var text: String = ""
    var files: [SouveraPendingShareStore.SharedFile] = []

    var usableFiles: [SouveraPendingShareStore.SharedFile] { files.filter { !$0.tooLarge } }
    var hasUsableContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !usableFiles.isEmpty
    }
}

extension NCShareExtension {

    /// Laedt Text/URL und Dateien aus den Teilen-Items. Dateien werden in den
    /// App-Group-Container kopiert und auf 10 MB begrenzt (Android-Paritaet);
    /// zu grosse Dateien bleiben als Eintrag sichtbar, werden aber nicht
    /// versendet.
    func loadSouveraSharedPayload(from inputItems: [NSExtensionItem]) async -> SouveraSharedPayload {
        var payload = SouveraSharedPayload()
        SouveraPendingShareStore.cleanupOldFiles()
        guard let directory = SouveraPendingShareStore.filesDirectory() else { return payload }

        let providers = inputItems.compactMap { $0.attachments }.flatMap { $0 }
        var usedNames = Set<String>()
        var index = 0

        for provider in providers {
            // 1) Text oder URL (Safari teilt URLs als public.url).
            if payload.text.isEmpty,
               let url = await loadURL(from: provider) {
                payload.text = url.absoluteString
                continue
            }
            if payload.text.isEmpty,
               let text = await loadPlainText(from: provider) {
                payload.text = text
                continue
            }
            // 2) Datei.
            if let identifier = fileTypeIdentifier(for: provider) {
                index += 1
                if let file = await copyFile(from: provider,
                                             typeIdentifier: identifier,
                                             index: index,
                                             directory: directory,
                                             usedNames: &usedNames) {
                    payload.files.append(file)
                }
            }
        }
        return payload
    }

    /// Zeigt den Souvera-Auswahlschirm ueber der bestehenden Extension-UI.
    func presentSouveraShareChooser(payload: SouveraSharedPayload, inputItems: [NSExtensionItem]) {
        let chooser = SouveraShareView(
            files: payload.files,
            initialText: payload.text,
            onMail: { [weak self] text in
                var updated = payload
                updated.text = text
                self?.handOffSouveraShare(action: "mail", payload: updated)
            },
            onUpload: { [weak self] in
                guard let self else { return }
                self.dismiss(animated: true) {
                    self.startFilesFlow(inputItems: inputItems)
                }
            },
            onTalk: { [weak self] text in
                var updated = payload
                updated.text = text
                self?.handOffSouveraShare(action: "talk", payload: updated)
            },
            onAssistant: { [weak self] text in
                self?.handOffToAssistant(text: text)
            },
            onCancel: { [weak self] in
                self?.cancel()
            }
        )
        let host = UIHostingController(rootView: chooser)
        host.modalPresentationStyle = .fullScreen
        host.view.backgroundColor = .systemGroupedBackground
        present(host, animated: true)
    }

    /// Uebergibt Text an den Assistant (bestehender App-Group-Weg).
    func handOffToAssistant(text: String) {
        NCAssistantSharedTextStore.save(text)
        guard let url = URL(string: "souvera://assistant/shared-text") else {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }
        openDeepLinkThroughResponderChain(url, label: "assistant shared text")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    /// Uebergibt den geteilten Inhalt an die App und schliesst die Extension.
    func handOffSouveraShare(action: String, payload: SouveraSharedPayload) {
        let share = SouveraPendingShareStore.Share(action: action,
                                                   text: payload.text,
                                                   files: payload.files,
                                                   createdAt: Date())
        SouveraPendingShareStore.save(share)
        guard let url = URL(string: "souvera://share?action=\(action)") else {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }
        openDeepLinkThroughResponderChain(url, label: "share \(action)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    // MARK: - Laden

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data,
                          let string = String(data: data, encoding: .utf8),
                          let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadPlainText(from provider: NSItemProvider) async -> String? {
        for identifier in [UTType.plainText.identifier, UTType.text.identifier] {
            guard provider.hasItemConformingToTypeIdentifier(identifier) else { continue }
            let text: String? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                    if let string = item as? String {
                        continuation.resume(returning: string)
                    } else if let attributed = item as? NSAttributedString {
                        continuation.resume(returning: attributed.string)
                    } else if let data = item as? Data {
                        continuation.resume(returning: String(data: data, encoding: .utf8))
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    /// Datei-Typ des Providers (public.data, aber keine URL).
    private func fileTypeIdentifier(for provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            if type.conforms(to: .url) { return false }
            return type.conforms(to: .data) || type.conforms(to: .content)
        }
    }

    private func copyFile(from provider: NSItemProvider,
                          typeIdentifier: String,
                          index: Int,
                          directory: URL,
                          usedNames: inout Set<String>) async -> SouveraPendingShareStore.SharedFile? {
        let loaded: (url: URL, name: String, mimeType: String)? = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                // Die gelieferte Datei existiert nur waehrend des Callbacks -
                // sofort in ein eigenes Temp-Verzeichnis kopieren.
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                let name = provider.suggestedName?.isEmpty == false
                    ? provider.suggestedName!
                    : url.lastPathComponent
                let mime = UTType(typeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
                do {
                    try FileManager.default.copyItem(at: url, to: temp)
                    continuation.resume(returning: (temp, name, mime))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let loaded else { return nil }

        let safeName = uniqueName(loaded.name, usedNames: &usedNames, index: index)
        let size = (try? FileManager.default.attributesOfItem(atPath: loaded.url.path)[.size] as? Int64) ?? 0
        if size > SouveraPendingShareStore.maxFileBytes {
            try? FileManager.default.removeItem(at: loaded.url)
            return SouveraPendingShareStore.SharedFile(name: safeName,
                                                       mimeType: loaded.mimeType,
                                                       path: "",
                                                       size: size,
                                                       tooLarge: true)
        }
        let target = directory.appendingPathComponent(safeName)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: loaded.url, to: target)
        } catch {
            try? FileManager.default.removeItem(at: loaded.url)
            return nil
        }
        try? FileManager.default.removeItem(at: loaded.url)
        return SouveraPendingShareStore.SharedFile(name: safeName,
                                                   mimeType: loaded.mimeType,
                                                   path: target.path,
                                                   size: size,
                                                   tooLarge: false)
    }

    private func uniqueName(_ name: String, usedNames: inout Set<String>, index: Int) -> String {
        let fallback = "attachment-\(index)"
        let sanitized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
        var candidate = sanitized.isEmpty ? fallback : sanitized
        if usedNames.contains(candidate) {
            let url = URL(fileURLWithPath: candidate)
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var counter = 1
            repeat {
                candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
                counter += 1
            } while usedNames.contains(candidate)
        }
        usedNames.insert(candidate)
        return candidate
    }
}
