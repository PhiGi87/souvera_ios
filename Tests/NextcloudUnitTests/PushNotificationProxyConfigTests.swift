// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import Nextcloud

@Suite("Souvera push proxy configuration")
struct PushNotificationProxyConfigTests {

    @Test("Production push proxy URL is hard-fixed to the Souvera proxy")
    func productionProxyURLIsHardFixed() {
        #expect(NCBrandOptions.SOUVERA_PUSH_PROXY_URL == "https://push.souvera.eu")
    }

    @Test("Resolved push proxy is set and never falls back to the official Nextcloud proxy")
    func resolvedProxyNeverFallsBackToOfficialProxy() {
        let proxy = NCBrandOptions.shared.pushNotificationServerProxy

        #expect(!proxy.isEmpty)
        #expect(proxy == NCBrandOptions.SOUVERA_PUSH_PROXY_URL)
        #expect(proxy != "https://push-notifications.nextcloud.com")
    }
}
