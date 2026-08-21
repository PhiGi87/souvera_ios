// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// CardDAV source for the Souvera contacts module and the mail composer's
// recipient fields. Reads the user's address book via REPORT
// addressbook-query (vCards with href + etag) and supports create, update
// and delete through PUT/DELETE on the address book collection.

import Foundation

/// One address-book entry: the CardDAV href, the current etag (required for
/// updates and deletes) and the raw vCard text.
struct CardDavCard {
    let href: String
    let etag: String?
    let vcard: String
}

/// Parsed fields of a vCard shown in the contacts UI.
struct ParsedContact {
    let uid: String
    let name: String
    let emails: [String]
    let phones: [String]
    let organization: String?
}

final class CardDavContactSource {

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    // MARK: - Address book location

    private func addressBookURL() -> URL? {
        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else { return nil }
        let root = tbl.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // The DAV principal on Souvera is the full login (email), not the
        // short userId.
        let principal = tbl.user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tbl.user
        return URL(string: "\(root)/remote.php/dav/addressbooks/users/\(principal)/contacts/")
    }

    private func authorizedRequest(for url: URL, method: String, contentType: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let contentType {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let tbl = NCManageDatabase.shared.getActiveTableAccount() {
            let davPassword = NCPreferences().getPassword(account: tbl.account)
            let raw = "\(tbl.user):\(davPassword)"
            req.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    // MARK: - Reading

    func fetchCards(limit: Int = 500) async -> [CardDavCard] {
        guard let url = addressBookURL() else { return [] }
        var req = authorizedRequest(for: url, method: "REPORT", contentType: "application/xml; charset=utf-8")
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.httpBody = Self.reportBody.data(using: .utf8)

        guard let (data, response) = try? await urlSession.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 207 else { return [] }
        return Self.parseCards(from: data, limit: limit)
    }

    /// Lightweight lookup used by the mail composer's recipient suggestions.
    func fetchContacts(limit: Int = 200) async -> [RecipientSuggestion] {
        let cards = await fetchCards(limit: limit)
        var result: [RecipientSuggestion] = []
        for card in cards {
            let parsed = Self.parseVcard(card.vcard)
            for email in parsed.emails {
                guard email.contains("@") else { continue }
                if !result.contains(where: { $0.email == email.lowercased() }) {
                    result.append(RecipientSuggestion(
                        displayName: parsed.name.isEmpty ? nil : parsed.name,
                        email: email.lowercased()
                    ))
                    if result.count >= limit { return result }
                }
            }
        }
        return result
    }

    // MARK: - Writing

    @discardableResult
    func create(_ contact: ParsedContact) async -> CardDavCard? {
        guard let base = addressBookURL() else { return nil }
        let uid = contact.uid.isEmpty ? UUID().uuidString.lowercased() : contact.uid
        let href = "\(uid).vcf"
        guard let url = URL(string: href, relativeTo: base)?.absoluteURL else { return nil }
        var req = authorizedRequest(for: url, method: "PUT", contentType: "text/vcard; charset=utf-8")
        req.httpBody = Self.buildVcard(contact, uid: uid).data(using: .utf8)
        guard let (_, response) = try? await urlSession.data(for: req),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { return nil }
        let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
        return CardDavCard(href: href, etag: etag, vcard: Self.buildVcard(contact, uid: uid))
    }

    func update(_ card: CardDavCard, contact: ParsedContact) async -> Bool {
        guard let base = addressBookURL(),
              let url = URL(string: card.href, relativeTo: base)?.absoluteURL else { return false }
        var req = authorizedRequest(for: url, method: "PUT", contentType: "text/vcard; charset=utf-8")
        if let etag = card.etag {
            req.setValue(etag, forHTTPHeaderField: "If-Match")
        }
        req.httpBody = Self.buildVcard(contact, uid: contact.uid).data(using: .utf8)
        guard let (_, response) = try? await urlSession.data(for: req) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func delete(_ card: CardDavCard) async -> Bool {
        guard let base = addressBookURL(),
              let url = URL(string: card.href, relativeTo: base)?.absoluteURL else { return false }
        var req = authorizedRequest(for: url, method: "DELETE")
        if let etag = card.etag {
            req.setValue(etag, forHTTPHeaderField: "If-Match")
        }
        guard let (_, response) = try? await urlSession.data(for: req) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - vCard helpers

    static func buildVcard(_ contact: ParsedContact, uid: String) -> String {
        var lines = ["BEGIN:VCARD", "VERSION:3.0"]
        if !contact.name.isEmpty {
            lines.append("FN:\(escaped(contact.name))")
            let components = contact.name.split(separator: " ", maxSplits: 1).map(String.init)
            let lastName = components.count > 1 ? components[1] : contact.name
            let firstName = components.count > 1 ? components[0] : ""
            lines.append("N:\(escaped(lastName));\(escaped(firstName));;;")
        }
        for email in contact.emails where !email.isEmpty {
            lines.append("EMAIL;TYPE=INTERNET:\(escaped(email))")
        }
        for phone in contact.phones where !phone.isEmpty {
            lines.append("TEL;TYPE=CELL:\(escaped(phone))")
        }
        if let org = contact.organization, !org.isEmpty {
            lines.append("ORG:\(escaped(org))")
        }
        lines.append("UID:\(escaped(uid))")
        lines.append("END:VCARD")
        return lines.joined(separator: "\r\n")
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func parseVcard(_ vcard: String) -> ParsedContact {
        var uid = ""
        var name = ""
        var emails: [String] = []
        var phones: [String] = []
        var organization: String?

        func unescape(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\,", with: ",")
                .replacingOccurrences(of: "\\;", with: ";")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }

        for rawLine in vcard.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line != "BEGIN:VCARD", line != "END:VCARD" else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let keyPart = line[line.startIndex..<colon]
            let key = keyPart.split(separator: ";").first.map(String.init) ?? ""
            let value = unescape(String(line[line.index(after: colon)...]))
            switch key {
            case "UID": if uid.isEmpty { uid = value }
            case "FN": if name.isEmpty { name = value }
            case "EMAIL": emails.append(value)
            case "TEL": phones.append(value)
            case "ORG": organization = value
            default: break
            }
        }
        return ParsedContact(uid: uid, name: name, emails: emails, phones: phones, organization: organization)
    }

    private static var reportBody: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <c:addressbook-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:carddav">
          <d:prop>
            <d:getetag/>
            <c:address-data content-type="text/vcard" version="4.0"/>
          </d:prop>
        </c:addressbook-query>
        """
    }

    /// Parses the multistatus response into href/etag/vCard entries.
    static func parseCards(from data: Data, limit: Int) -> [CardDavCard] {
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        var cards: [CardDavCard] = []
        let responsePattern = #"<(?:[A-Za-z0-9_]+:)?response[^>]*>(.*?)</(?:[A-Za-z0-9_]+:)?response>"#
        guard let regex = try? NSRegularExpression(pattern: responsePattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = xml as NSString
        for match in regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            guard let blockRange = Range(match.range(at: 1), in: xml) else { continue }
            let block = String(xml[blockRange])
            let href = firstMatch(pattern: #"<(?:[A-Za-z0-9_]+:)?href>([^<]+)</(?:[A-Za-z0-9_]+:)?href>"#, in: block)
            let etag = firstMatch(pattern: #"<(?:[A-Za-z0-9_]+:)?getetag>([^<]+)</(?:[A-Za-z0-9_]+:)?getetag>"#, in: block)
            guard let addressData = firstMatch(
                pattern: #"<(?:[A-Za-z0-9_]+:)?address-data[^>]*>(.*?)</(?:[A-Za-z0-9_]+:)?address-data>"#,
                in: block
            ) else { continue }
            let vcard = addressData
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
            cards.append(CardDavCard(href: href ?? "", etag: etag, vcard: vcard))
            if cards.count >= limit { break }
        }
        return cards
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
