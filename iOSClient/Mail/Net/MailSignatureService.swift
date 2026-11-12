// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 13.11.: Zentrale E-Mail-Signatur aus souvera_central. Der Server
// verwaltet die Signatur pro Nutzer (identisch zum souvera-Webmail);
// der native Composer holt sie beim Öffnen und hängt sie an den Body.
//
// Server-Vertrag (verifiziert in souvera_central):
//   GET {urlBase}/apps/souvera_central/api/mail-settings/signature
//   Auth: HTTP Basic (NC-User + App-Passwort aus NCPreferences) - das
//   GENAUE accountInfo/authorize-Muster aus SouveraOutOfOfficeOcsApi.
//   Header: Accept: application/json (KEIN OCS-APIRequest - der Endpunkt
//   ist kein OCS-Endpunkt; der Webmail-Fetch nutzt ihn ebenfalls nicht).
//   Response: {found: Bool, html: String?, text: String?, source: String?,
//              assetCidPrefix: String?, assets: [{cid, dataUrl}]?}
//   found:false = keine Signatur hinterlegt (Feature still weglassen).
//   assets.dataUrl sind Data-URLs ("data:image/png;base64,..."); die
//   cid:-Referenzen im HTML werden vor der Verwendung durch die passende
//   Data-URL ersetzt, damit das HTML direkt darstellbar ist.
//
// Cache: In-Memory + UserDefaults-JSON (Key "souvera_mail_signature_<accountKey>",
// mit Timestamp, TTL 5 Minuten) analog zum referenced-ids-Cache im
// MailViewModel. `cached(account:)` liefert synchron aus dem Cache -
// damit kann der Composer die Signatur schon beim Start einsetzen,
// bevor der Netz-Fetch durch ist.

import Foundation

/// Eine zentrale E-Mail-Signatur, wie sie im Composer angehängt wird.
/// `html` enthält bereits eingebettete Data-URL-Assets statt cid:-Verweisen.
struct MailSignature: Equatable {
    let html: String
    let text: String
}

/// Client für den Signatur-Endpunkt der souvera_central-App (siehe Dateikopf).
enum MailSignatureService {

    private static let basePath = "/apps/souvera_central/api/mail-settings/signature"
    private static let cacheKeyPrefix = "souvera_mail_signature_"
    private static let cacheTTL: TimeInterval = 300

    /// In-Memory-Cache (Account-Key -> Signatur + Fetch-Zeitpunkt).
    /// Vermeidet UserDefaults-Roundtrips bei jedem Composer-Öffnen.
    /// Zugriff ausschließlich unter cacheLock; nonisolated(unsafe) ist
    /// für Swift 6 Strict Concurrency nötig (Schutz über den Lock).
    private nonisolated(unsafe) static var memoryCache: [String: (signature: MailSignature, timestamp: Date)] = [:]
    private static let cacheLock = NSLock()

    // MARK: - Öffentliche API

    /// Holt die zentrale Signatur vom Server. `nil` = keine Signatur
    /// vorhanden (found:false, HTTP 404) oder Fehler - in beiden Fällen
    /// wird die Signatur still weggelassen, alles wird geloggt.
    static func fetch(account: String? = nil) async -> MailSignature? {
        let info: (baseUrl: String, username: String, password: String, accountKey: String)
        do {
            info = try accountInfoWithKey(account)
        } catch {
            SouveraLog.write("Signature", "fetch: kein Account (\(error))")
            return nil
        }
        guard let url = URL(string: "\(info.baseUrl)\(basePath)") else {
            SouveraLog.write("Signature", "fetch: ungültige URL (\(info.accountKey))")
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request, username: info.username, password: info.password)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                // 404 = keine Signatur konfiguriert (Normalfall, kein Fehler).
                SouveraLog.write("Signature", "fetch status=\(code) (\(info.accountKey))")
                return nil
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                SouveraLog.write("Signature", "fetch: Antwort kein JSON (\(info.accountKey))")
                return nil
            }
            guard json["found"] as? Bool == true else {
                SouveraLog.write("Signature", "fetch: found=false (\(info.accountKey))")
                return nil
            }
            guard let html = json["html"] as? String, !html.isEmpty,
                  let text = json["text"] as? String, !text.isEmpty else {
                SouveraLog.write("Signature", "fetch: html/text leer (\(info.accountKey))")
                return nil
            }
            let assetCidPrefix = json["assetCidPrefix"] as? String ?? ""
            let assets = parseAssets(json["assets"])
            let signature = MailSignature(
                html: embedAssets(in: html, assetCidPrefix: assetCidPrefix, assets: assets),
                text: text
            )
            storeInCache(signature, accountKey: info.accountKey)
            SouveraLog.write("Signature", "fetch status=\(code) ok (\(info.accountKey), assets=\(assets.count))")
            return signature
        } catch {
            SouveraLog.write("Signature", "fetch: Netzwerkfehler \(error) (\(info.accountKey))")
            return nil
        }
    }

    /// Synchron aus dem Cache (UserDefaults, TTL 5 Minuten) - für den
    /// Composer-Start, ohne Netz-Blockade. Kein Cache/TTL abgelaufen -> nil.
    static func cached(account: String?) -> MailSignature? {
        // 1. In-Memory-Cache (schnellster Pfad).
        if let key = account, !key.isEmpty {
            cacheLock.lock()
            let mem = memoryCache[key]
            cacheLock.unlock()
            if let mem, Date().timeIntervalSince(mem.timestamp) < cacheTTL {
                return mem.signature
            }
        }
        // 2. UserDefaults-Cache.
        guard let key = account, !key.isEmpty,
              let data = UserDefaults.standard.data(forKey: cacheKeyPrefix + key),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = json["ts"] as? Double,
              Date().timeIntervalSince1970 - ts < cacheTTL,
              let html = json["html"] as? String,
              let text = json["text"] as? String else {
            return nil
        }
        return MailSignature(html: html, text: text)
    }

    // MARK: - Asset-Einbettung

    /// Asset-Eintrag der Server-Antwort.
    private struct SignatureAsset {
        let cid: String
        let dataUrl: String
    }

    /// Liest das assets-Array der Antwort ({cid, dataUrl}-Paare).
    private static func parseAssets(_ raw: Any?) -> [SignatureAsset] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let cid = entry["cid"] as? String, !cid.isEmpty,
                  let dataUrl = entry["dataUrl"] as? String, !dataUrl.isEmpty else {
                return nil
            }
            return SignatureAsset(cid: cid, dataUrl: dataUrl)
        }
    }

    /// Ersetzt im HTML alle cid:-Referenzen durch die passenden Data-URLs.
    /// Der Server präfixt die cid mit assetCidPrefix (z. B. "sig-assets-"),
    /// referenziert wird also "cid:<assetCidPrefix><cid>".
    private static func embedAssets(in html: String, assetCidPrefix: String, assets: [SignatureAsset]) -> String {
        guard !assets.isEmpty else { return html }
        var result = html
        for asset in assets {
            result = result.replacingOccurrences(
                of: "cid:\(assetCidPrefix)\(asset.cid)",
                with: asset.dataUrl
            )
        }
        return result
    }

    // MARK: - Cache-Speicherung

    private static func storeInCache(_ signature: MailSignature, accountKey: String) {
        guard !accountKey.isEmpty else { return }
        cacheLock.lock()
        memoryCache[accountKey] = (signature, Date())
        cacheLock.unlock()
        let json: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "html": signature.html,
            "text": signature.text
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            UserDefaults.standard.set(data, forKey: cacheKeyPrefix + accountKey)
        }
    }

    // MARK: - Auth (Muster aus SouveraOutOfOfficeOcsApi)

    /// HTTP Basic mit NC-User + Account-App-Passwort.
    private static func authorize(_ request: inout URLRequest, username: String, password: String) {
        let raw = "\(username):\(password)"
        request.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
    }

    /// Account-Infos (urlBase, NC-User, App-Passwort, Account-Key) des
    /// aktiven oder expliziten Accounts - identisch zu
    /// `SouveraOutOfOfficeOcsApi.accountInfo`, zusätzlich der tbl.account
    /// Schlüssel für den Cache.
    private static func accountInfoWithKey(_ account: String?) throws -> (baseUrl: String, username: String, password: String, accountKey: String) {
        let tbl: tableAccount?
        if let account {
            tbl = NCManageDatabase.shared.getAllTableAccount().first(where: { $0.account == account })
        } else {
            tbl = NCManageDatabase.shared.getActiveTableAccount()
        }
        guard let tbl else { throw MailSignatureError.noAccount }
        let password = NCPreferences().getPassword(account: tbl.account)
        guard !tbl.urlBase.isEmpty, !tbl.user.isEmpty, !password.isEmpty else {
            throw MailSignatureError.noAccount
        }
        let baseUrl = tbl.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (baseUrl, tbl.user, password, tbl.account)
    }
}

/// Typisierte Fehler des Signatur-Services (nur intern geloggt, nie in die UI).
private enum MailSignatureError: Error {
    case noAccount
}
