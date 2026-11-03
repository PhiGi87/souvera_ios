// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UserNotifications

/// Run 03.11. (Feature 1): Einmalige Orphan-Migration - räumt lokale
/// Reste von Accounts weg, die in früheren Versionen beim Abmelden nicht
/// vollständig entfernt wurden (UserDefaults-Einträge, Push-Toggles in
/// der App-Gruppe, Kalender-Erinnerungen, Mail-/Link-/Empfänger-Caches).
///
/// Der Lauf ist durch den Guard-Key "souvera_orphan_account_cleanup_v1"
/// auf GENAU EINMAL pro Installation begrenzt (gleiches Muster wie
/// "invitations_local_state_cleared_v1" in SouveraInvitationCenter und
/// "souvera_mail_cache_schema_v4_cleared" in MailCache).
///
/// Bewusst ÜBERSPRUNGEN: SouveraPushCredentialVault. Dessen
/// 409-Selbstheilung löscht verwaiste Server-Zeilen über die historisch
/// gespeicherten Credentials selbst - ein vorzeitiges Leeren würde diese
/// Selbstheilung brechen.
enum SouveraOrphanAccountCleanup {

    private static let guardKey = "souvera_orphan_account_cleanup_v1"

    /// Identische Sanitierung wie MailCache / LinkCache /
    /// UsedRecipientStore: alle Zeichen außerhalb [A-Za-z0-9._-] werden
    /// zu "_" (Account-Keys enthalten "user https://host" - ohne
    /// Sanitierung würde der "/" den Pfad zerlegen).
    private static func sanitized(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
    }

    static func runOnce() async {
        guard !UserDefaults.standard.bool(forKey: guardKey) else { return }

        // Konto-Liste erst NACH dem Realm-Warm-up lesen - ist sie leer
        // (DB noch nicht bereit oder bewusst keine Konten), brechen wir
        // OHNE Guard-Key ab, damit der Lauf später wiederholt werden kann.
        // Sonst würde ein Leer-Lauf ALLE gecachten Daten als "orphan"
        // einstufen und löschen.
        let accounts = await NCManageDatabase.shared.getAllTableAccountAsync().map { $0.account }
        guard !accounts.isEmpty else {
            SouveraLog.write("OrphanCleanup", "skipped: no accounts loaded (will retry on next launch)")
            return
        }
        var knownAll = Set(accounts)
        var knownSanitized = Set<String>()
        for account in accounts {
            let safe = sanitized(account)
            if safe.isEmpty {
                // Sanitierung eines Kontos leer -> Grenz-Logik nicht
                // verlässlich; diesen Lauf überspringen (ohne Guard-Key).
                SouveraLog.write("OrphanCleanup", "skipped: account sanitizes to empty string")
                return
            }
            knownSanitized.insert(safe)
            knownAll.insert(safe)
        }
        // Legitimer Fallback-Suffix (CalendarViewModel, leeres Konto).
        knownAll.insert("default")

        // a) Standard-UserDefaults: Account-bezogene Keys mit unbekanntem
        //    Suffix entfernen. Suffix "default" bleibt (legitimer
        //    Fallback, CalendarViewModel Zeile ~134).
        let standardPrefixes = [
            "souveraCalendarSelection_",
            "souveraCalendarColors_",
            "souvera_push_reg_state_",
            "souvera_push_nc_429_",
            "souvera_mail_device_id_",
            "souvera_mail_device_token_"
        ]
        var removedDefaults = 0
        for (key, _) in UserDefaults.standard.dictionaryRepresentation() {
            guard let prefix = standardPrefixes.first(where: { key.hasPrefix($0) }) else { continue }
            let suffix = String(key.dropFirst(prefix.count))
            guard !suffix.isEmpty, suffix != "default", !knownAll.contains(suffix) else { continue }
            UserDefaults.standard.removeObject(forKey: key)
            removedDefaults += 1
        }

        // b) App-Gruppe: Push-Toggles (NSE liest dieselben Keys).
        let groupStore = SouveraPushToggles.store
        let groupPrefixes = [SouveraPushToggles.mailCalendarKey, SouveraPushToggles.linkTalkKey]
        var removedGroupDefaults = 0
        for (key, _) in groupStore.dictionaryRepresentation() {
            guard let prefix = groupPrefixes.first(where: { key.hasPrefix($0) }) else { continue }
            let suffix = String(key.dropFirst(prefix.count))
            guard !suffix.isEmpty, suffix != "default", !knownAll.contains(suffix) else { continue }
            groupStore.removeObject(forKey: key)
            removedGroupDefaults += 1
        }

        // c) UNUserNotificationCenter: Kalender-Erinnerungen verwaister
        //    Kontos entfernen (pending + delivered). Robust gegen
        //    Accounts mit Leerzeichen: der Identifier wird NICHT über den
        //    Account-Teil bis zum nächsten "_" zerlegt, sondern es gilt:
        //    Orphan = KEIN bekannter Account erfüllt das Präfix
        //    "eventreminder_<account>_".
        let reminderPrefix = "eventreminder_"
        let knownReminderAccounts = knownAll.filter { !$0.isEmpty }
        func isOrphanReminder(_ identifier: String) -> Bool {
            guard identifier.hasPrefix(reminderPrefix) else { return false }
            return !knownReminderAccounts.contains { identifier.hasPrefix(reminderPrefix + $0 + "_") }
        }
        let center = UNUserNotificationCenter.current()
        let pendingRequests = await center.pendingNotificationRequests()
        let orphanPendingIds = pendingRequests.map(\.identifier).filter(isOrphanReminder)
        if !orphanPendingIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: orphanPendingIds)
        }
        let deliveredNotifications = await center.deliveredNotifications()
        let orphanDeliveredIds = deliveredNotifications.map { $0.request.identifier }.filter(isOrphanReminder)
        if !orphanDeliveredIds.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: orphanDeliveredIds)
        }

        // d) MailCache-Verzeichnis-Scan (Mail-Snapshots, Mailboxlisten,
        //    Bodies-Ordner, Kalender-Blobs). Die Grenz-Logik steckt in
        //    MailCache (dieselbe wie beim normalen Account-Löschen).
        let removedMailCache = MailCache.removeOrphanAccountFiles(knownSanitized: knownSanitized)

        // e) LinkCache ("conversations_<account>.json") und
        //    UsedRecipientStore ("<safeAccount>.json") per Scan.
        let removedLink = removeOrphanLinkCacheFiles(knownSanitized: knownSanitized)
        let removedRecipients = removeOrphanUsedRecipientFiles(knownSanitized: knownSanitized)

        // f) SouveraPushCredentialVault: bewusst ÜBERSPRUNGEN - die
        //    409-Selbstheilung braucht die historischen Credentials.

        UserDefaults.standard.set(true, forKey: guardKey)
        SouveraLog.write("OrphanCleanup", "v1 completed (defaults=\(removedDefaults), groupDefaults=\(removedGroupDefaults), reminders=\(orphanPendingIds.count + orphanDeliveredIds.count), mailCache=\(removedMailCache), linkCache=\(removedLink), recipients=\(removedRecipients))")
    }

    /// LinkCache-Scan: nur Dateien mit dem Präfix "conversations_"
    /// (Chat-Blobs "chat-<token>.json" sind nicht account-bezogen und
    /// bleiben unberührt). Bekannt = Dateiname entspricht EXAKT der
    /// sanitisierten Form "conversations_<safeAccount>.json" eines
    /// bekannten Kontos.
    private static func removeOrphanLinkCacheFiles(knownSanitized: Set<String>) -> Int {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("link-cache", isDirectory: true),
            let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return 0 }
        var removed = 0
        for url in files {
            let name = url.lastPathComponent
            guard name.hasPrefix("conversations_"), name.hasSuffix(".json") else { continue }
            let isKnown = knownSanitized.contains { account in
                name == sanitized("conversations_" + account + ".json")
            }
            if !isKnown {
                try? FileManager.default.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }

    /// UsedRecipientStore-Scan: "<safeAccount>.json" im
    /// Caches/SouveraUsedRecipients-Ordner. Bekannt = exakter Dateiname
    /// eines bekannten (sanitisierten) Kontos.
    private static func removeOrphanUsedRecipientFiles(knownSanitized: Set<String>) -> Int {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SouveraUsedRecipients", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for url in files {
            let name = url.lastPathComponent
            guard name.hasSuffix(".json") else { continue }
            let isKnown = knownSanitized.contains { account in
                name == account + ".json"
            }
            if !isKnown {
                try? FileManager.default.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }
}
