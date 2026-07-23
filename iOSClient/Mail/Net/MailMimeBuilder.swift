// SPDX-FileCopyrightText: 2026 Host-On Service Provider GmbH (Souvera)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Builds an RFC 5322 / MIME message string for outgoing mail. Plain text + HTML alternative, with
// optional attachments as a mixed multipart. UTF-8, base64 for attachments and non-ASCII headers.

import Foundation

enum MailMimeBuilder {
    static func build(fromAddress: String, fromName: String, outgoing: OutgoingMessage) -> String {
        let boundaryAlt = "alt-\(UUID().uuidString)"
        let boundaryMixed = "mixed-\(UUID().uuidString)"
        let date = rfc2822Date(Date())

        var headers = ""
        headers += "From: \(encodeAddress(name: fromName, address: fromAddress))\r\n"
        headers += "To: \(outgoing.to.joined(separator: ", "))\r\n"
        if !outgoing.cc.isEmpty { headers += "Cc: \(outgoing.cc.joined(separator: ", "))\r\n" }
        headers += "Subject: \(encodeHeader(outgoing.subject))\r\n"
        headers += "Date: \(date)\r\n"
        headers += "MIME-Version: 1.0\r\n"

        let html = outgoing.bodyHtml.isEmpty ? htmlEscape(outgoing.body) : outgoing.bodyHtml
        let alternative = """
        --\(boundaryAlt)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: 8bit\r
        \r
        \(outgoing.body)\r
        --\(boundaryAlt)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Transfer-Encoding: 8bit\r
        \r
        \(html)\r
        --\(boundaryAlt)--\r
        """

        if outgoing.attachments.isEmpty {
            return headers + "Content-Type: multipart/alternative; boundary=\"\(boundaryAlt)\"\r\n\r\n" + alternative + "\r\n"
        }

        var body = "Content-Type: multipart/mixed; boundary=\"\(boundaryMixed)\"\r\n\r\n"
        body += "--\(boundaryMixed)\r\n"
        body += "Content-Type: multipart/alternative; boundary=\"\(boundaryAlt)\"\r\n\r\n"
        body += alternative + "\r\n"
        for attachment in outgoing.attachments {
            guard let data = try? Data(contentsOf: attachment.fileURL) else { continue }
            body += "--\(boundaryMixed)\r\n"
            body += "Content-Type: \(attachment.mimeType); name=\"\(attachment.name)\"\r\n"
            body += "Content-Transfer-Encoding: base64\r\n"
            body += "Content-Disposition: attachment; filename=\"\(attachment.name)\"\r\n\r\n"
            body += data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn]) + "\r\n"
        }
        body += "--\(boundaryMixed)--\r\n"
        return headers + body
    }

    private static func encodeAddress(name: String, address: String) -> String {
        name.isEmpty ? address : "\(encodeHeader(name)) <\(address)>"
    }

    /// RFC 2047 encoded-word for non-ASCII header values.
    private static func encodeHeader(_ value: String) -> String {
        if value.allSatisfy({ $0.isASCII }) { return value }
        let b64 = Data(value.utf8).base64EncodedString()
        return "=?utf-8?B?\(b64)?="
    }

    private static func htmlEscape(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        return "<html><body>\(escaped)</body></html>"
    }

    private static func rfc2822Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
