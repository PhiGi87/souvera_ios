// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// iOS equivalent of souvera_android DavAccount: the base URL + credentials used for every
// Talk ("Link") OCS request. Credentials come from the active Nextcloud account (app password
// in the keychain), so Link authenticates exactly like the rest of the app.

import Foundation

struct LinkAccount {
    let account: String
    let baseUrl: String
    let username: String
    let password: String

    /// HTTP Basic credential header value for this account.
    var basicAuthHeader: String {
        let raw = "\(username):\(password)"
        let encoded = Data(raw.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    /// Resolves the currently active account, or nil when signed out.
    static func active() -> LinkAccount? {
        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else { return nil }
        return from(account: tbl.account, urlBase: tbl.urlBase, user: tbl.user)
    }

    static func from(account: String, urlBase: String, user: String) -> LinkAccount? {
        let password = NCPreferences().getPassword(account: account)
        guard !urlBase.isEmpty, !user.isEmpty, !password.isEmpty else { return nil }
        return LinkAccount(account: account, baseUrl: urlBase, username: user, password: password)
    }
}
