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

    /// DAV principal candidates: the full login (email) is the principal on
    /// Souvera; some setups use the short userId instead. Both are tried.
    private func principalCandidates() -> [String] {
        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else { return [] }
        var candidates = [tbl.user]
        if !tbl.userId.isEmpty, tbl.userId != tbl.user {
            candidates.append(tbl.userId)
        }
        return candidates.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
    }

    private func addressBookURLs() -> [URL] {
        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else { return [] }
        let root = tbl.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return principalCandidates().compactMap {
            URL(string: "\(root)/remote.php/dav/addressbooks/users/\($0)/contacts/")
        }
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
        for url in addressBookURLs() {
            var req = authorizedRequest(for: url, method: "REPORT", contentType: "application/xml; charset=utf-8")
            req.setValue("1", forHTTPHeaderField: "Depth")
            req.httpBody = Self.reportBody.data(using: .utf8)

            guard let (data, response) = try? await urlSession.data(for: req) else { continue }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            JmapLog.write("CardDAV addressbook-query \(url.absoluteString) -> \(status)")
            guard status == 207 else { continue }
            return Self.parseCards(from: data, limit: limit)
        }
        return []
    }

    /// Fetches the cards of EVERY address book of the user (the personal
    /// book plus server-generated books like z-server-generated--system,
    /// where the directory contacts live).
    func fetchAllCards(limit: Int = 500) async -> [CardDavCard] {
        var all: [CardDavCard] = []
        var seenHrefs = Set<String>()
        for url in discoverAddressBookURLs() {
            let cards = await fetchCards(from: url, limit: limit)
            for card in cards where seenHrefs.insert(card.href).inserted {
                all.append(card)
            }
        }
        return all
    }

    private func fetchCards(from url: URL, limit: Int) async -> [CardDavCard] {
        var req = authorizedRequest(for: url, method: "REPORT", contentType: "application/xml; charset=utf-8")
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.httpBody = Self.reportBody.data(using: .utf8)
        guard let (data, response) = try? await urlSession.data(for: req) else { return [] }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        JmapLog.write("CardDAV addressbook-query \(url.absoluteString) -> \(status)")
        guard status == 207 else { return [] }
        return Self.parseCards(from: data, limit: limit)
    }

    /// PROPFIND on the address book home to discover every address book
    /// collection (the personal one plus server-generated ones).
    private func discoverAddressBookURLs() -> [URL] {
        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else { return [] }
        let root = tbl.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var result: [URL] = []
        for principal in principalCandidates() {
            guard let home = URL(string: "\(root)/remote.php/dav/addressbooks/users/\(principal)/") else { continue }
            var req = authorizedRequest(for: home, method: "PROPFIND")
            req.setValue("1", forHTTPHeaderField: "Depth")
            req.httpBody = Self.propfindBody.data(using: .utf8)
            guard let (data, response) = try? await urlSession.data(for: req) else { continue }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            JmapLog.write("CardDAV PROPFIND \(home.absoluteString) -> \(status)")
            guard status == 207, let xml = String(data: data, encoding: .utf8) else { continue }
            result += Self.parseAddressBookURLs(from: xml)
            if !result.isEmpty { break }
        }
        return result
    }

    static func parseAddressBookURLs(from xml: String) -> [URL] {
        var urls: [URL] = []
        let responsePattern = #"<(?:[A-Za-z0-9_]+:)?response[^>]*>(.*?)</(?:[A-Za-z0-9_]+:)?response>"#
        guard let regex = try? NSRegularExpression(pattern: responsePattern, options: [.dotMatchesLineSeparators]) else { return [] }
        for match in regex.matches(in: xml, range: NSRange(location: 0, length: (xml as NSString).length)) {
            guard let blockRange = Range(match.range(at: 1), in: xml) else { continue }
            let block = String(xml[blockRange])
            guard block.localizedCaseInsensitiveContains("addressbook"),
                  let href = Self.firstMatch(pattern: #"<(?:[A-Za-z0-9_]+:)?href>([^<]+)</(?:[A-Za-z0-9_]+:)?href>"#, in: block),
                  let url = URL(string: href) else { continue }
            urls.append(url)
        }
        return urls
    }

    private static var propfindBody: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:carddav">
          <d:prop>
            <d:displayname/>
            <d:resourcetype/>
          </d:prop>
        </d:propfind>
        """
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
        guard let base = addressBookURLs().first else { return nil }
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
        guard let base = addressBookURLs().first,
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
        guard let base = addressBookURLs().first,
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
                // Numeric character entities first - sabre encodes vCard
                // line endings as &#13; which would otherwise glue all
                // lines together into a single unparseable line.
                .replacingOccurrences(of: "&#13;", with: "\n")
                .replacingOccurrences(of: "&#10;", with: "\n")
                .replacingOccurrences(of: "&#x0D;", with: "\n")
                .replacingOccurrences(of: "&#x0A;", with: "\n")
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
