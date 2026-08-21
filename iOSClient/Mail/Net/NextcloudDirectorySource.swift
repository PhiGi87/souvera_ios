// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Directory lookup for known/shared users of the Souvera/Nextcloud instance.
// Uses the core autocomplete endpoint (the same one the share dialog and the
// Link module use) which returns user ids - on Souvera these are the users'
// email addresses, so they can be used directly as mail recipients and
// calendar attendees.

import Foundation

final class NextcloudDirectorySource {

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    /// Searches instance users, returning email (id) and display name (label).
    func searchUsers(_ query: String, limit: Int = 10) async -> [RecipientSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
              let tbl = NCManageDatabase.shared.getActiveTableAccount() else { return [] }

        let root = tbl.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        guard let url = URL(string: "\(root)/ocs/v2.php/core/autocomplete/get?search=\(encoded)&itemType=call&itemId=new&shareTypes%5B%5D=0&limit=\(limit)") else { return [] }

        var req = URLRequest(url: url)
        let davPassword = NCPreferences().getPassword(account: tbl.account)
        let raw = "\(tbl.user):\(davPassword)"
        req.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")

        guard let (data, response) = try? await urlSession.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: data, encoding: .utf8) else { return [] }
        return Self.parseUsers(from: xml, limit: limit)
    }

    static func parseUsers(from xml: String, limit: Int) -> [RecipientSuggestion] {
        var result: [RecipientSuggestion] = []
        let elementPattern = #"<element>(.*?)</element>"#
        guard let regex = try? NSRegularExpression(pattern: elementPattern, options: [.dotMatchesLineSeparators]) else { return [] }
        for match in regex.matches(in: xml, range: NSRange(location: 0, length: (xml as NSString).length)) {
            guard let blockRange = Range(match.range(at: 1), in: xml) else { continue }
            let block = String(xml[blockRange])
            guard let id = Self.firstMatch(pattern: #"<id>([^<]+)</id>"#, in: block),
                  let label = Self.firstMatch(pattern: #"<label>([^<]*)</label>"#, in: block) else { continue }
            let email = id
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .trimmingCharacters(in: .whitespaces)
            let name = label
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .trimmingCharacters(in: .whitespaces)
            guard email.contains("@") else { continue }
            if !result.contains(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) {
                result.append(RecipientSuggestion(displayName: name.isEmpty ? nil : name, email: email))
                if result.count >= limit { break }
            }
        }
        return result
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
