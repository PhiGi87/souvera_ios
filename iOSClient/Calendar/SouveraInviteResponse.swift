// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit

extension Notification.Name {
    /// Termin-Einladungs-Link: object = URL. Der Listener zeigt das
    /// Antwort-Overlay (Zusagen/Absagen/Vielleicht).
    static let openInviteResponse = Notification.Name("SouveraOpenInviteResponse")
}

/// Termin-Antworten direkt in der App (P63): Links aus Einladungs-Mails
/// oder Kalendertexten, die auf die Antwort-Endpoints des Servers zeigen,
/// werden abgefangen und als Overlay angeboten (Zusagen/Absagen/
/// Vielleicht) - statt die Antwortseite im Browser zu öffnen.
///
/// Die Server-URL-Formate sind bewusst TOLERANT erkannt, damit die App
/// mit Formatänderungen klarkommt; die tatsächliche Antwort-Übertragung
/// verifiziert der Nutzer gegen seinen Server (Log-Einträge).
enum SouveraInviteResponse {

    enum Action: String, CaseIterable {
        case accepted
        case declined
        case tentative
    }

    /// Tolerante Erkennung: eigener Host + Response-/RSVP-Marker im Pfad
    /// oder in den Query-Parametern. Alles andere öffnet der Browser.
    static func isResponseLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        // Nur Links des EIGENEN Servers abfangen - keine fremden Links.
        let root = currentRootUrl()?.lowercased() ?? ""
        guard root.isEmpty || root.contains(host) else { return false }
        let path = url.path.lowercased()
        let query = url.query?.lowercased() ?? ""
        let pathMarker = path.contains("response") || path.contains("rsvp")
        let queryMarker = query.contains("response") || query.contains("rsvp") || query.contains("respond")
        let contextMarker = path.contains("calendar") || path.contains("invite") || path.contains("event") || path.contains("term")
            || query.contains("calendar") || query.contains("invite") || query.contains("event") || query.contains("term")
        return (pathMarker || queryMarker) && contextMarker
    }

    /// Antwort an den Server senden: POST mit Form-Parameter `action`
    /// (accepted/declined/tentative) - das Muster ist tolerant, das
    /// tatsächliche Server-Format verifiziert der Nutzer über die Logs.
    static func respond(to url: URL, action: Action) async -> Bool {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "action", value: action.rawValue))
        components.queryItems = queryItems
        guard let target = components.url else { return false }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        SouveraLog.write("InviteResponse", "\(action.rawValue) -> \(target.absoluteString)")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        SouveraLog.write("InviteResponse", "\(action.rawValue) http \(http.statusCode)")
        return (200..<300).contains(http.statusCode)
    }

    private static func currentRootUrl() -> String? {
        if let tbl = NCManageDatabase.shared.getActiveTableAccount() {
            return tbl.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return nil
    }
}
