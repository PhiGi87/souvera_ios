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

    private var keychain: Keychain { Keychain(service: Self.service) }

    func ensureCombinedCredential() async -> MailAccount? {
        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else { return nil }
        let account = tbl.account
        let baseUrl = tbl.urlBase
        let username = tbl.user
        let davPassword = NCPreferences().getPassword(account: account)
        guard !baseUrl.isEmpty, !username.isEmpty, !davPassword.isEmpty else { return nil }

        if let stored = try? keychain.get(Self.keyPassword + account), !stored.isEmpty {
            let stalwartId = (try? keychain.get(Self.keyStalwartId + account)) ?? ""
            let loginName = (try? keychain.get(Self.keyLoginName + account)) ?? ""
            return MailAccount(account: account, baseUrl: baseUrl, username: username, loginName: loginName, mailPassword: stored, stalwartId: stalwartId)
        }

        return await mint(account: account, baseUrl: baseUrl, username: username, davPassword: davPassword)
    }

    /// Clears the stored mail credential and mints a fresh one via the server's
    /// login-flow. Used when the mail server rejects the stored password with 401
    /// (e.g. the credential was revoked server-side or became invalid after a
    /// server-side upgrade).
    func renewCredential() async -> MailAccount? {
        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else { return nil }
        let account = tbl.account
        let baseUrl = tbl.urlBase
        let username = tbl.user
        let davPassword = NCPreferences().getPassword(account: account)
        guard !baseUrl.isEmpty, !username.isEmpty, !davPassword.isEmpty else { return nil }

        clear(account: account)
        return await mint(account: account, baseUrl: baseUrl, username: username, davPassword: davPassword)
    }

    func clear(account: String) {
        try? keychain.remove(Self.keyPassword + account)
        try? keychain.remove(Self.keyStalwartId + account)
        try? keychain.remove(Self.keyLoginName + account)
    }

    private func mint(account: String, baseUrl: String, username: String, davPassword: String) async -> MailAccount? {
        do {
            let combined = try await SouveraMailLoginFlow.fetchCombinedAppPassword(baseUrl: baseUrl, username: username, currentAppPassword: davPassword)
            try? keychain.set(combined.appPassword, key: Self.keyPassword + account)
            try? keychain.set(combined.stalwartId, key: Self.keyStalwartId + account)
            try? keychain.set(combined.loginName, key: Self.keyLoginName + account)
            SouveraLog.write("MailCredential", "mint OK stalwart=\(combined.stalwartId)")
            return MailAccount(account: account, baseUrl: baseUrl, username: username, loginName: combined.loginName, mailPassword: combined.appPassword, stalwartId: combined.stalwartId)
        } catch {
            SouveraLog.write("MailCredential", "mint FAILED: \(error.localizedDescription)")
            return nil
        }
    }
}
