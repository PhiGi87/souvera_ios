// SPDX-FileCopyrightText: 2026 Host-On Service Provider GmbH (Souvera)
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

struct SouveraServerUrl {

    private static let httpsPrefix = "https://"
    private static let slugRegex = try? NSRegularExpression(pattern: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")

    static func extractSlug(rawInput: String, domain: String) -> String {
        var value = rawInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return "" }
        if value.hasPrefix(httpsPrefix) { value = String(value.dropFirst(httpsPrefix.count)) }
        if value.hasPrefix("http://") { value = String(value.dropFirst(7)) }
        if let slashIndex = value.firstIndex(of: "/") { value = String(value[..<slashIndex]) }
        if let qIndex = value.firstIndex(of: "?") { value = String(value[..<qIndex]) }
        let dotDomain = ".\(domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        if value.hasSuffix(dotDomain) {
            value = String(value.dropLast(dotDomain.count))
        }
        guard let regex = Self.slugRegex else { return "" }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil ? value : ""
    }

    static func buildUrl(slug: String, domain: String) -> String {
        return "\(httpsPrefix)\(slug).\(domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
}
