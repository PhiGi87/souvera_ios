// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from souvera_android mail/SouveraMailCredentialManager.kt.
//
// Provides the combined Nextcloud+Stalwart credential the JMAP mail client needs,
// WITHOUT touching the account password used for Files/CalDAV/CardDAV.
//
// The Nextcloud app-password `X` (in the app keychain via NCPreferences) stays the
// secret WebDAV/DAV authenticate with. On first entry to the mail client this mints
// a SEPARATE combined password `Y` (via `/login-flow`, which does not revoke `X`)
// and stores it under a mail-only keychain key; the returned MailAccount carries `Y`
// so only the mail layer uses it.
//
// Per the souvera_mail server contract (docs/LOGIN_FLOW_CLIENT_INTEGRATION.txt),
// `loginName` is the SASL username for mail authentication and may differ from the
// Nextcloud user id. It is stored alongside `Y` and used by the JMAP client.

import Foundation
import KeychainAccess

struct MailAccount {
    let account: String
    let baseUrl: String
    let username: String
    let loginName: String
    let mailPassword: String
    let stalwartId: String

    /// The SASL username for IMAP/SMTP (per the souvera_mail server contract
    /// this is `loginName`, which may differ from the Nextcloud user id).
    var saslUser: String {
        loginName.isEmpty ? username : loginName
    }

    /// IMAP/SMTP host: base URL minus scheme, path and port.
    var host: String {
        var h = baseUrl
        for prefix in ["https://", "http://"] where h.hasPrefix(prefix) {
            h.removeFirst(prefix.count)
        }
        h = h.components(separatedBy: "/").first ?? h
        h = h.components(separatedBy: ":").first ?? h
        return h
    }
}

struct SouveraMailCredentialManager {
    private static let service = "eu.souvera.workspace.mail"
    private static let keyPassword = "souvera_mail_password"
    private static let keyStalwartId = "souvera_stalwart_id"
    private static let keyLoginName = "souvera_mail_login_name"
    private static let keyLastMint = "souvera_mail_last_mint_"
    /// Mindestabstand zwischen zwei Mints: Jeder Mint ersetzt serverseitig
    /// das App-Passwort dieser Beschreibung - zu schnelle Mints (Ping-Pong
    /// zwischen Komponenten/Geräten) erzeugen Endlos-401-Schleifen.
    private static let mintIntervalSeconds: TimeInterval = 120

    private var keychain: Keychain { Keychain(service: Self.service) }

    func ensureCombinedCredential(account explicitAccount: String? = nil) async -> MailAccount? {
        guard let info = Self.accountInfo(explicitAccount) else { return nil }
        let account = info.account
        let baseUrl = info.baseUrl
        let username = info.username
        let davPassword = info.davPassword
        guard !baseUrl.isEmpty, !username.isEmpty, !davPassword.isEmpty else { return nil }

        if let stored = storedAccount(account: account, baseUrl: baseUrl, username: username) {
            return stored
        }

        // Ohne gespeicherte Credential: erst nach Ablauf des Rate-Limits
        // minten (verhindert Mint-Stürme mehrerer Instanzen).
        if let last = lastMintDate(account: account),
           Date().timeIntervalSince(last) < Self.mintIntervalSeconds {
            SouveraLog.write("MailCredential", "mint throttled (no stored credential, last mint < 120s)")
            return nil
        }
        return await mint(account: account, baseUrl: baseUrl, username: username, davPassword: davPassword)
    }

    /// Erneuert die Mail-Credential. WICHTIG: Vor dem Mint wird die
    /// GESPEICHERTE Credential live validiert - ist sie noch gültig, stammte
    /// der auslösende 401 von einem veralteten Client und es wird NICHT
    /// neu gemintzt (jeder Mint entwertet serverseitig das vorherige
    /// Passwort derselben Beschreibung).
    func renewCredential(account explicitAccount: String? = nil) async -> MailAccount? {
        guard let info = Self.accountInfo(explicitAccount) else { return nil }
        let account = info.account
        let baseUrl = info.baseUrl
        let username = info.username
        let davPassword = info.davPassword
        guard !baseUrl.isEmpty, !username.isEmpty, !davPassword.isEmpty else { return nil }

        let stored = storedAccount(account: account, baseUrl: baseUrl, username: username)
        if let last = lastMintDate(account: account),
           Date().timeIntervalSince(last) < Self.mintIntervalSeconds {
            SouveraLog.write("MailCredential", "mint throttled (last mint < 120s) - returning stored credential")
            return stored
        }
        if let stored, await validate(stored) {
            SouveraLog.write("MailCredential", "stored credential still valid - no mint needed")
            return stored
        }
        clear(account: account)
        return await mint(account: account, baseUrl: baseUrl, username: username, davPassword: davPassword)
    }

    func clear(account: String) {
        try? keychain.remove(Self.keyPassword + account)
        try? keychain.remove(Self.keyStalwartId + account)
        try? keychain.remove(Self.keyLoginName + account)
    }

    /// Letzte 4 Zeichen eines Passworts für die Diagnose-Logs: macht
    /// sichtbar, OB ein 401-Passwort vom letzten Mint stammt oder nicht.
    static func suffix(_ password: String) -> String {
        guard password.count > 4 else { return password }
        return String(password.suffix(4))
    }

    private func storedAccount(account: String, baseUrl: String, username: String) -> MailAccount? {
        guard let stored = try? keychain.get(Self.keyPassword + account), !stored.isEmpty else { return nil }
        let stalwartId = (try? keychain.get(Self.keyStalwartId + account)) ?? ""
        let loginName = (try? keychain.get(Self.keyLoginName + account)) ?? ""
        return MailAccount(account: account, baseUrl: baseUrl, username: username, loginName: loginName, mailPassword: stored, stalwartId: stalwartId)
    }

    /// Account-Infos (expliziter Account oder der aktive).
    private static func accountInfo(_ explicit: String?) -> (account: String, baseUrl: String, username: String, davPassword: String)? {
        if let explicit {
            guard let tbl = NCManageDatabase.shared.getAllTableAccount().first(where: { $0.account == explicit }) else { return nil }
            let davPassword = NCPreferences().getPassword(account: explicit)
            return (explicit, tbl.urlBase, tbl.user, davPassword)
        }
        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else { return nil }
        let davPassword = NCPreferences().getPassword(account: tbl.account)
        return (tbl.account, tbl.urlBase, tbl.user, davPassword)
    }

    private func lastMintDate(account: String) -> Date? {
        let interval = UserDefaults.standard.double(forKey: Self.keyLastMint + account)
        guard interval > 0 else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    private func markMinted(account: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.keyLastMint + account)
    }

    /// Live-Validierung: Liefert die gespeicherte Credential eine
    /// JMAP-Session MIT Accounts? Nur ein echter 401 gilt als "ungültig" -
    /// Netzfehler/offline melden "gültig", damit ein kurzer Ausfall nicht
    /// eine gültige Credential löscht und unnötig neu mintet (neuer
    /// Auth-Token -> neuer Push-deviceIdentifier -> stale Proxy-Zeile).
    private func validate(_ account: MailAccount) async -> Bool {
        let client = JmapClient(
            baseUrl: account.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            username: account.saslUser,
            password: account.mailPassword
        )
        return await client.credentialLooksValid()
    }

    private func mint(account: String, baseUrl: String, username: String, davPassword: String) async -> MailAccount? {
        do {
            let combined = try await SouveraMailLoginFlow.fetchCombinedAppPassword(baseUrl: baseUrl, username: username, currentAppPassword: davPassword)
            try? keychain.set(combined.appPassword, key: Self.keyPassword + account)
            try? keychain.set(combined.stalwartId, key: Self.keyStalwartId + account)
            try? keychain.set(combined.loginName, key: Self.keyLoginName + account)
            markMinted(account: account)
            SouveraLog.write("MailCredential", "mint OK stalwart=\(combined.stalwartId) pwd=…\(Self.suffix(combined.appPassword))")
            return MailAccount(account: account, baseUrl: baseUrl, username: username, loginName: combined.loginName, mailPassword: combined.appPassword, stalwartId: combined.stalwartId)
        } catch {
            SouveraLog.write("MailCredential", "mint FAILED: \(error.localizedDescription)")
            return nil
        }
    }
}
