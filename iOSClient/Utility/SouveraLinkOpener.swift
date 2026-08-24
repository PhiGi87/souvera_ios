// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit

/// Öffnet URLs einheitlich in der App: interne App-Links (Talk-Räume,
/// `/call/<token>`) öffnen das Link-Modul, eigene Schemes laufen über das
/// Deep-Link-Handling der App, alles andere öffnet der Standard-Browser.
enum SouveraLinkOpener {
    static func open(_ url: URL) {
        if let token = talkRoomToken(in: url) {
            NotificationCenter.default.post(
                name: .openLinkRoom,
                object: ["token": token, "title": ""]
            )
            return
        }
        UIApplication.shared.open(url)
    }

    /// Erkennt URLs in Plaintext und liefert ein AttributedString, in dem
    /// sie als tappbare Links markiert sind (unterstrichen).
    static func linkified(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }
        let nsText = text as NSString
        for match in detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) {
            guard let url = match.url,
                  let start = AttributedString.Index(match.range.location, within: attributed),
                  let end = AttributedString.Index(match.range.location + match.range.length, within: attributed) else { continue }
            attributed[start..<end].link = url
            attributed[start..<end].underlineStyle = .single
        }
        return attributed
    }

    private static func talkRoomToken(in url: URL) -> String? {
        let text = url.absoluteString
        guard let range = text.range(of: "/call/([a-z0-9]+)", options: .regularExpression) else { return nil }
        var raw = String(text[range])
        raw.removeFirst("/call/".count)
        return raw.isEmpty ? nil : raw
    }
}
