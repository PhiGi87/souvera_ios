// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit

extension Notification.Name {
    /// Posted when another module (e.g. the calendar) wants the Link tab to
    /// open a specific conversation.
    static let openLinkRoom = Notification.Name("SouveraOpenLinkRoom")
    /// Posted when the Link chat wants the Files tab to show a specific
    /// folder; object = folder path relative to the user root (no leading
    /// slash, e.g. "Souvera/Link/Intern-36icekye").
    static let openFileInFiles = Notification.Name("SouveraOpenFileInFiles")
}

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
        #if !EXTENSION
        // Termin-Einladungs-Links: Antwort-Overlay statt Browser (P63).
        if SouveraInviteResponse.isResponseLink(url) {
            NotificationCenter.default.post(name: .openInviteResponse, object: url)
            return
        }
        UIApplication.shared.open(url)
        #endif
    }

    /// Erkennt URLs in Plaintext und liefert ein AttributedString, in dem
    /// sie als tappbare Links markiert sind (unterstrichen). Zusätzlich zur
    /// NSDataDetector-Erkennung werden Talk-Raum-Links ("/call/<token>",
    /// auch ohne Schema) markiert - die kommen z. B. in Kalender-Orten vor.
    static func linkified(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)

        var ranges: [NSRange] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let nsText = text as NSString
            let length = nsText.length
            for match in detector.matches(in: text, options: [], range: NSRange(location: 0, length: length)) {
                if let url = match.url {
                    ranges.append(match.range)
                    applyLink(url, range: match.range, to: &attributed, text: text)
                }
            }
        }
        // Talk-Raum-Links ohne Schema: "/call/<token>" oder "/index.php/call/<token>"
        if let callRegex = try? NSRegularExpression(pattern: #"(?:https?://[^\s"'<>]+)?(?:/index\.php)?/call/([a-z0-9]{4,30})"#),
           let rootUrl = currentRootUrl() {
            let nsText = text as NSString
            for match in callRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) {
                let tokenRange = match.range(at: 1)
                guard tokenRange.location != NSNotFound,
                      let swiftRange = Range(tokenRange, in: text) else { continue }
                // Bereich nur markieren, wenn nicht schon Teil eines
                // detector-markierten Links (Vermeidung von Doppel-Links).
                let overlapped = ranges.contains { nsRange in
                    NSIntersectionRange(nsRange, match.range).length > 0
                }
                if overlapped { continue }
                let token = String(text[swiftRange])
                guard let full = URL(string: "\(rootUrl)/call/\(token)") else { continue }
                applyLink(full, range: match.range, to: &attributed, text: text)
            }
        }
        return attributed
    }

    /// Markiert einen NSRange (UTF-16) als Link im AttributedString - mit
    /// sicherer Index-Konvertierung über Swift-Ranges (Emoji-/UTF-16-fest).
    private static func applyLink(_ url: URL, range: NSRange, to attributed: inout AttributedString, text: String) {
        guard let swiftRange = Range(range, in: text),
              let lower = AttributedString.Index(swiftRange.lowerBound, within: attributed),
              let upper = AttributedString.Index(swiftRange.upperBound, within: attributed) else { return }
        attributed[lower..<upper].link = url
        attributed[lower..<upper].underlineStyle = .single
    }

    /// Server-Root des aktiven Kontos (für Schema-lose /call/-Links).
    private static func currentRootUrl() -> String? {
        #if !EXTENSION
        if let tbl = NCManageDatabase.shared.getActiveTableAccount() {
            return tbl.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        #endif
        return nil
    }

    /// Talk-Raum-Token aus einer beliebigen URL/Textform (/call/<token>).
    static func talkRoomToken(in url: URL) -> String? {
        let text = url.absoluteString
        guard let range = text.range(of: "/call/([a-z0-9]+)", options: .regularExpression) else { return nil }
        var raw = String(text[range])
        raw.removeFirst("/call/".count)
        return raw.isEmpty ? nil : raw
    }

    /// Talk-Raum-Token aus einem Freitext (z. B. Kalender-Location).
    static func talkRoomToken(in text: String) -> String? {
        guard let range = text.range(of: "/call/([a-z0-9]{4,30})", options: .regularExpression) else { return nil }
        var raw = String(text[range])
        raw.removeFirst("/call/".count)
        return raw.isEmpty ? nil : raw
    }
}
