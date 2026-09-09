/*
 SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
 SPDX-License-Identifier: GPL-2.0-or-later
*/

import Foundation
import WebKit

/// Run-Fix "eingebettete Bilder": löst `cid:`-Referenzen aus HTML-Mails auf.
/// Das WKWebView kann Content-IDs mit `loadHTMLString(baseURL: nil)` nicht
/// auflösen - der MailHtmlView schreibt `cid:…` daher auf das Custom-Scheme
/// `souvera-cid://inline/<percent-encoded cid>` um, das dieser Handler
/// bedient: Der zugehörige Blob wird über den Provider (JMAP-Download)
/// geladen, im NSCache gecacht und als Subresource ausgeliefert.
final class MailInlineImageSchemeHandler: NSObject, WKURLSchemeHandler {

    /// Liefert (Daten, MIME-Type) zu einer normalisierten Content-ID.
    typealias Provider = (String) async -> (data: Data, mimeType: String)?

    private let provider: Provider
    private let cache = NSCache<NSString, NSData>()

    init(provider: @escaping Provider) {
        self.provider = provider
        super.init()
        cache.totalCostLimit = 16 * 1024 * 1024
    }

    /// Normalisiert eine JMAP/RFC-2392-Content-ID: "cid:foo@bar",
    /// "<foo@bar>" und "foo@bar" laufen auf "foo@bar" zusammen.
    static func normalizedContentId(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("cid:"), value.index(after: value.startIndex) < value.endIndex {
            value.removeSubrange(value.startIndex..<value.index(value.startIndex, offsetBy: 4))
        }
        if value.hasPrefix("<"), value.hasSuffix(">"), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    static func url(forContentId raw: String) -> URL? {
        let encoded = normalizedContentId(raw)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
        return URL(string: "souvera-cid://inline/\(encoded)")
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let rawId = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let cid = Self.normalizedContentId(rawId.removingPercentEncoding ?? rawId)
        let cacheKey = cid as NSString
        if let cached = cache.object(forKey: cacheKey) {
            respond(to: task, data: cached as Data, mimeType: mime(for: cached as Data))
            return
        }
        Task { [weak self, weak task] in
            guard let self, let task else { return }
            guard let result = await self.provider(cid), !result.data.isEmpty else {
                await MainActor.run {
                    task.didFailWithError(URLError(.fileDoesNotExist))
                }
                return
            }
            self.cache.setObject(result.data as NSData, forKey: cacheKey, cost: result.data.count)
            // WebKit erwartet die Task-Antworten auf dem Main-Thread.
            let data = result.data
            let mimeType = result.mimeType
            await MainActor.run {
                self.respond(to: task, data: data, mimeType: mimeType)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Abgebrochene Loads ignorieren - die Task-Antworten unterbleiben
        // bewusst (WebKit toleriert keine Antworten nach stop).
    }

    private func respond(to task: WKURLSchemeTask, data: Data, mimeType: String) {
        let response = URLResponse(
            url: task.request.url ?? URL(string: "souvera-cid://inline/unknown")!,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func mime(for data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if data.count > 12, String(data: data.prefix(12), encoding: .ascii)?.contains("WEBP") == true { return "image/webp" }
        if data.starts(with: [0x42, 0x4D]) { return "image/bmp" }
        return "application/octet-stream"
    }
}
