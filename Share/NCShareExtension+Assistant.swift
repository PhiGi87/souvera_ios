// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import UniformTypeIdentifiers
import NextcloudKit

extension NCShareExtension {
    func handleAssistantSharedTextIfNeeded(inputItems: [NSExtensionItem]) async -> Bool {
        guard let text = await loadText(from: inputItems),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        NCAssistantSharedTextStore.save(text)
        openMainAppForAssistantSharedText()

        return true
    }

    private func loadText(from inputItems: [NSExtensionItem]) async -> String? {
        for item in inputItems {
            guard let attachments = item.attachments else {
                continue
            }

            for provider in attachments {
                let plainTextIdentifier = UTType.plainText.identifier
                let textIdentifier = UTType.text.identifier

                if provider.hasItemConformingToTypeIdentifier(plainTextIdentifier) {
                    return await loadText(from: provider, typeIdentifier: plainTextIdentifier)
                }

                if provider.hasItemConformingToTypeIdentifier(textIdentifier) {
                    return await loadText(from: provider, typeIdentifier: textIdentifier)
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                    return await loadText(from: provider, typeIdentifier: UTType.text.identifier)
                }
            }
        }

        return nil
    }

    private func loadText(from provider: NSItemProvider, typeIdentifier: String) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                let text: String?

                if let string = item as? String {
                    text = string
                } else if let attributedString = item as? NSAttributedString {
                    text = attributedString.string
                } else if let data = item as? Data {
                    text = String(data: data, encoding: .utf8)
                } else if let url = item as? URL {
                    text = try? String(contentsOf: url, encoding: .utf8)
                } else {
                    text = nil
                }

                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: text)
            }
        }
    }

    /// Opens the main app using the Assistant shared-text deep link.
    private func openMainAppForAssistantSharedText() {
        guard let url = URL(string: "souvera://assistant/shared-text") else {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        openDeepLinkThroughResponderChain(url, label: "assistant shared text")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    /// Opens a deep link in the containing application from the Share
    /// extension.
    ///
    /// Share extensions cannot use `UIApplication.shared` directly because it is not
    /// extension-safe. This method walks the responder chain until it finds the hidden
    /// `UIApplication` responder and invokes the modern `open(_:options:completionHandler:)`
    /// Objective-C selector dynamically.
    ///
    /// This is intentionally isolated because it relies on Objective-C runtime dispatch.
    ///
    /// - Parameters:
    ///   - url: Deep link URL to open in the containing application.
    ///   - label: Diagnostic label for the log output.
    func openDeepLinkThroughResponderChain(_ url: URL, label: String) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        let applicationClass: AnyClass? = NSClassFromString("UIApplication")
        var responder: UIResponder? = self

        while let currentResponder = responder {
            guard let applicationClass,
                  currentResponder.isKind(of: applicationClass),
                  currentResponder.responds(to: selector),
                  let implementation = currentResponder.method(for: selector) else {
                responder = currentResponder.next
                continue
            }

            typealias CompletionBlock = @convention(block) (Bool) -> Void
            typealias OpenURLFunction = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, CompletionBlock?) -> Void

            let openURL = unsafeBitCast(implementation, to: OpenURLFunction.self)

            let completion: CompletionBlock = { success in
                if success {
                    nkLog(debug: "Share deep link (\(label)) performed through modern responder chain")
                } else {
                    nkLog(error: "Share deep link (\(label)) modern responder chain returned false")
                }
            }

            openURL(currentResponder, selector, url as NSURL, NSDictionary(), completion)
            return
        }

        nkLog(error: "Share deep link (\(label)) failed because no UIApplication responder can open URL")
    }
}
