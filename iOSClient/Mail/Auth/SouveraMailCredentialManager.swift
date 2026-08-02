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

import Foundation
import KeychainAccess

struct MailAccount {
    let account: String
    let baseUrl: String
    let username: String
    let mailPassword: String
    let stalwartId: String
}

struct SouveraMailCredentialManager {
    private static let service = "eu.souvera.workspace.mail"
    private static let keyPassword = "souvera_mail_password"
    private static let keyStalwartId = "souvera_stalwart_id"

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
            return MailAccount(account: account, baseUrl: baseUrl, username: username, mailPassword: stored, stalwartId: stalwartId)
        }

        guard let combined = try? await SouveraMailLoginFlow.fetchCombinedAppPassword(baseUrl: baseUrl, username: username, currentAppPassword: davPassword) else {
            return nil
        }
        try? keychain.set(combined.appPassword, key: Self.keyPassword + account)
        try? keychain.set(combined.stalwartId, key: Self.keyStalwartId + account)
        return MailAccount(account: account, baseUrl: baseUrl, username: username, mailPassword: combined.appPassword, stalwartId: combined.stalwartId)
    }

    func clear(account: String) {
        try? keychain.remove(Self.keyPassword + account)
        try? keychain.remove(Self.keyStalwartId + account)
    }
}
