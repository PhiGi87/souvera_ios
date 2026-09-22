// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import UniformTypeIdentifiers
import NextcloudKit

extension NCShareExtension {
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
