// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// CardDAV contact source for the composer's recipient fields. Queries the
// user's Souvera/Nextcloud address book via REPORT addressbook-query and
// parses the returned vCards. Falls back silently to an empty result when
// the address book is unavailable.

import Foundation

final class CardDavContactSource {

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    func fetchContacts(limit: Int = 200) async -> [RecipientSuggestion] {
        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else { return [] }
        let root = tbl.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let userId = tbl.userId.isEmpty ? tbl.user : tbl.userId
        let addressBook = "\(root)/remote.php/dav/addressbooks/users/\(userId)/contacts/"
        guard let url = URL(string: addressBook) else { return [] }

        var req = URLRequest(url: url)
        req.httpMethod = "REPORT"
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let davPassword = NCPreferences().getPassword(account: tbl.account)
        let raw = "\(tbl.user):\(davPassword)"
        req.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        req.httpBody = Self.reportBody.data(using: .utf8)

        guard let (data, response) = try? await urlSession.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 207 else { return [] }
        return Self.parseVcards(from: data, limit: limit)
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

    static func parseVcards(from data: Data, limit: Int) -> [RecipientSuggestion] {
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        var result: [RecipientSuggestion] = []
        for cardBlock in xml.components(separatedBy: "BEGIN:VCARD") {
            guard cardBlock.contains("END:VCARD") else { continue }
            let vcard = cardBlock.components(separatedBy: "END:VCARD").first ?? cardBlock

            var name: String?
            if let fnMatch = vcard.range(of: #"(?m)^FN(?:;[^:]*)?:([^\r\n]+)"#, options: .regularExpression) {
                name = String(vcard[fnMatch]).components(separatedBy: ":").dropFirst().joined(separator: ":")
                    .trimmingCharacters(in: .whitespaces)
            }
            if name?.isEmpty == true { name = nil }

            let emailPattern = try? NSRegularExpression(pattern: #"(?m)^EMAIL(?:;[^:]*)?:([^\r\n]+)"#)
            let ns = vcard as NSString
            guard let matches = emailPattern?.matches(in: vcard, range: NSRange(location: 0, length: ns.length)) else { continue }
            for match in matches {
                guard let range = Range(match.range(at: 1), in: vcard) else { continue }
                let email = String(vcard[range]).trimmingCharacters(in: .whitespaces).lowercased()
                guard email.contains("@"), !email.isEmpty else { continue }
                if !result.contains(where: { $0.email == email }) {
                    result.append(RecipientSuggestion(displayName: name, email: email))
                    if result.count >= limit { return result }
                }
            }
        }
        return result
    }
}
