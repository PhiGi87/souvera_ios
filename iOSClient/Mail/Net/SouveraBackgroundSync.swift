// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Background notification sync for mail and calendar. Runs inside the app's
// BGAppRefresh task: it polls the JMAP inbox for new mail (queryChanges-like
// dedup against the cached snapshot) and looks ahead into the CalDAV
// calendars for upcoming events, then schedules local notifications - so new
// mail and event reminders arrive even when the app is not in the foreground.

import Foundation
import UserNotifications

final class SouveraBackgroundSync {
    static let shared = SouveraBackgroundSync()
    private init() {}

    private let notificationCenter = UNUserNotificationCenter.current()

    func syncNotifications() async {
        let accounts = NCManageDatabase.shared.getAllTableAccount()
        guard !accounts.isEmpty else { return }
        // ALLE Accounts synchronisieren (auch nicht-aktive): Jeder Account
        // erhält seine lokalen Notifications + Reminder (per-Account-
        // Ersetzung im Scheduler - A löscht nicht die Erinnerungen von B).
        for tbl in accounts {
            await syncMail(account: tbl.account)
            await syncCalendar(account: tbl.account)
            await syncLink(account: tbl.account)
        }
    }

    /// Zählt die ungelesenen Mails ALLER Accounts und aktualisiert das
    /// System-Badge (Summe) + die per-Account-Badges.
    func refreshMailBadge() async {
        var grandTotal = 0
        var anySucceeded = false
        for tbl in NCManageDatabase.shared.getAllTableAccount() {
            guard let total = await unreadCount(account: tbl.account) else {
                // Tolerant (P66): Ein Account, der gerade nicht antwortet
                // (Netz/Server), wirft den Zähler der anderen nicht weg.
                SouveraLog.write("BackgroundSync", "mail badge refresh: account \(tbl.account) skipped")
                continue
            }
            anySucceeded = true
            grandTotal += total
            NotificationCenter.default.post(
                name: .mailUnreadChanged,
                object: nil,
                userInfo: ["account": tbl.account, "count": total]
            )
        }
        // Nur bei mindestens einem erfolgreichen Zähler das System-Badge
        // setzen - sonst würde ein Netzfehler das Badge auf 0 löschen.
        if anySucceeded || NCManageDatabase.shared.getAllTableAccount().isEmpty {
            NotificationCenter.default.post(name: .mailTotalUnreadChanged, object: grandTotal)
            SouveraLog.write("BackgroundSync", "mail badge refresh -> total \(grandTotal) unread")
        }
    }

    private func unreadCount(account: String) -> Int? {
        guard let credential = await SouveraMailCredentialManager().ensureCombinedCredential(account: account) else { return nil }
        let client = JmapClient(
            baseUrl: credential.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            username: credential.saslUser,
            password: credential.mailPassword
        )
        let api = JmapApi(client: client)
        guard let session = try? await client.refreshSession(),
              !session.primaryAccountId.isEmpty else { return nil }
        let accId = session.primaryAccountId
        guard let inbox = (try? await api.getMailboxes(accountId: accId))?.first(where: { $0.optString("role") == "inbox" }),
              let inboxId = inbox.optString("id") else { return nil }
        guard let resp = try? await api.queryEmails(accountId: accId, inMailboxId: inboxId, limit: 0, calculateTotal: true, notKeyword: "$seen"),
              let total = resp["total"] as? Int else { return nil }
        return total
    }

    // MARK: - Mail

    private func syncMail(account: String) async {
        guard var credential = await SouveraMailCredentialManager().ensureCombinedCredential(account: account) else { return }
        // Push-Gruppe Mail & Kalender aus: KEINE lokalen Mail-Benachrichtigungen
        // (Sicherheitsnetz parallel zur Server-Abmeldung). Der Badge-Zähler
        // (refreshMailBadge) bleibt unabhängig.
        let mailNotificationsEnabled = SouveraPushToggles.mailCalendarEnabled
        var client = JmapClient(
            baseUrl: credential.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            username: credential.saslUser,
            password: credential.mailPassword
        )
        var api = JmapApi(client: client)
        var session: JmapSessionInfo?
        do {
            session = try await client.refreshSession()
        } catch {
            // Nur bei Auth-Fehlern erneuern; Netzfehler sauber überspringen.
            var isAuthError = false
            if let jmapError = error as? JmapException {
                switch jmapError {
                case .authNeedsBearer: isAuthError = true
                case .httpError(let code, _): isAuthError = (code == 401)
                default: break
                }
            }
            guard isAuthError else {
                SouveraLog.write("BackgroundSync", "mail session failed (non-auth): \(error.localizedDescription)")
                return
            }
            SouveraLog.write("BackgroundSync", "mail session 401 - renewing credential")
            if let renewed = await SouveraMailCredentialManager().renewCredential() {
                credential = renewed
                client = JmapClient(
                    baseUrl: renewed.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                    username: renewed.saslUser,
                    password: renewed.mailPassword
                )
                api = JmapApi(client: client)
                session = try? await client.refreshSession()
            }
        }
        var usableSession: JmapSessionInfo? = session
        if usableSession == nil
            || usableSession!.primaryAccountId.isEmpty
            || usableSession!.accounts.isEmpty {
            // Leere Accounts = tote Credential: einmal erneuern und neu
            // aufsetzen (best effort im Hintergrund).
            SouveraLog.write("BackgroundSync", "session with empty accounts - renewing credential")
            if let renewed = await SouveraMailCredentialManager().renewCredential() {
                credential = renewed
                client = JmapClient(
                    baseUrl: renewed.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                    username: renewed.saslUser,
                    password: renewed.mailPassword
                )
                api = JmapApi(client: client)
                usableSession = try? await client.refreshSession()
            }
        }
        guard let usableSession, !usableSession.primaryAccountId.isEmpty else { return }
        let accId = usableSession.primaryAccountId
        guard let inbox = (try? await api.getMailboxes(accountId: accId))?.first(where: { $0.optString("role") == "inbox" }),
              let inboxId = inbox.optString("id") else { return }

        let accountName = credential.account
        let cacheKey = Mailbox.makeId(account: accountName, path: inbox.optString("name") ?? "Inbox")
        var knownEmails: [[String: Any]] = []
        var knownIds = Set<String>()
        var knownState: String?
        if let snapshot = MailCache.loadMessages(account: accountName, mailboxId: cacheKey) {
            knownEmails = snapshot.emails
            knownIds = Set(snapshot.emails.compactMap { $0.optString("id") })
            knownState = snapshot.queryState
        }

        guard let resp = try? await api.queryEmails(accountId: accId, inMailboxId: inboxId, limit: 25),
              let ids = resp["ids"] as? [String] else { return }
        let newIds = ids.filter { !knownIds.contains($0) }
        guard !newIds.isEmpty,
              let newEmails = try? await api.getEmails(accountId: accId, ids: Array(newIds.prefix(10))) else { return }

        for email in newEmails {
            let fromName = ((email["from"] as? [[String: Any]])?.first?.optString("name"))
                ?? ((email["from"] as? [[String: Any]])?.first?.optString("email"))
                ?? ""
            let subject = email.optString("subject") ?? ""
            let content = UNMutableNotificationContent()
            // Apple-Mail-Stil: Absender FETT (Titelzeile), Betreff darunter
            // in normaler Schrift.
            let sender = SouveraNotificationText.title(fromName.isEmpty ? NSLocalizedString("_mail_", comment: "") : fromName)
            content.title = sender
            content.body = SouveraNotificationText.body(subject)
            content.sound = .default
            // Gruppierung pro E-Mail-Thread im Sperrbildschirm (wie Talk
            // pro Raum) - fehlt die threadId, bleibt das Feld leer.
            if let threadId = email.optString("threadId"), !threadId.isEmpty {
                content.threadIdentifier = "mail_\(accountName)/\(threadId)"
            }
            // Deep-Link-Payload: Tap öffnet direkt die jeweilige Mail.
            content.userInfo = [
                "account": accountName,
                "emailId": email.optString("id") ?? "",
                "baseUrl": credential.baseUrl
            ]
            if mailNotificationsEnabled {
                let request = UNNotificationRequest(
                    identifier: "mail_\(email.optString("id") ?? UUID().uuidString)",
                    content: content,
                    trigger: nil
                )
                try? await notificationCenter.add(request)
            }
        }

        // Merge the new mails into the cached snapshot so they are not
        // notified again on the next run (cap at the latest 100).
        var merged = newEmails
        merged += knownEmails
        var seen = Set<String>()
        merged = merged.filter { seen.insert($0.optString("id") ?? UUID().uuidString).inserted }
        if merged.count > 100 { merged = Array(merged.prefix(100)) }
        MailCache.saveMessages(account: accountName, mailboxId: cacheKey, emails: merged, queryState: resp.optString("queryState") ?? knownState)
    }

    // MARK: - Calendar

    private func syncCalendar(account: String) async {
        let client = CalDavClient(account: account)
        let calendars = await client.fetchCalendars()
        guard !calendars.isEmpty else { return }

        let now = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: 2, to: now) else { return }
        var upcoming: [CalendarEventModel] = []
        for calendar in calendars {
            let entries = await client.fetchEvents(calendarHref: calendar.href, start: now, end: end)
            for entry in entries {
                upcoming += ICSParser.parseEvents(entry.ics, calendarHref: entry.calendarHref, href: entry.href, etag: entry.etag)
            }
        }

        // Erinnerungen für DIESEN Account planen (per-Account-Ersetzung).
        SouveraReminderScheduler.schedule(for: upcoming, account: account)
    }

    // MARK: - Link

    /// Pollt die Talk-Konversationsliste, meldet neue ungelesene Nachrichten
    /// als lokale Benachrichtigungen und aktualisiert die Badge-Basis
    /// (Unread-Summe). Der LinkCache wird dabei mit dem frischen Stand
    /// gesichert (offline-fähig).
    private func syncLink(account: String) async {
        guard let tbl = NCManageDatabase.shared.getAllTableAccount().first(where: { $0.account == account }),
              let linkAccount = LinkAccount.from(account: tbl.account, urlBase: tbl.urlBase, user: tbl.user) else { return }
        // Push-Gruppe Link/Talk aus: keine lokalen Chat-Benachrichtigungen
        // (Sicherheitsnetz parallel zur Server-Abmeldung).
        guard SouveraPushToggles.linkTalkEnabled else { return }
        let api = LinkOcsApi(account: linkAccount)
        guard let list = await api.listConversations() else { return }

        let previous = LinkCache.loadConversations(account: account) ?? []
        let previousUnread = Dictionary(uniqueKeysWithValues: previous.map { ($0.token, $0.unreadMessages) })

        for room in list {
            let before = previousUnread[room.token] ?? 0
            let newCount = max(0, room.unreadMessages - before)
            guard newCount > 0, let last = room.lastMessage, !last.isSystemMessage else { continue }
            let sender = last.actorDisplayName.isEmpty ? room.displayName : last.actorDisplayName
            let preview = last.displayText()
            let content = UNMutableNotificationContent()
            // iOS-Push-Standard: Titel (fett) = Raumname, Subtitle (fett) =
            // Absender, Body (normal) = Nachrichtentext.
            content.title = SouveraNotificationText.title(room.displayName)
            content.subtitle = SouveraNotificationText.title(sender)
            content.body = SouveraNotificationText.body(preview)
            content.sound = .default
            // Gruppierung pro Raum im Sperrbildschirm (Talk-Standard).
            content.threadIdentifier = room.token
            // Deep-Link-Payload: Tap öffnet direkt den Raum-Chat.
            content.userInfo = [
                "token": room.token,
                "title": room.displayName,
                // Account für den Deep-Link (Multi-Account: Raum im
                // richtigen Account öffnen).
                "account": account
            ]
            let request = UNNotificationRequest(
                identifier: "talk_\(room.token)_\(last.id)",
                content: content,
                trigger: nil
            )
            try? await notificationCenter.add(request)
        }

        // Badge-Basis: nur der AKTIVE Account steuert den Link-Tab-Badge
        // (der Badge-Monitor pollt ohnehin nur den aktiven Account - ein
        // Sync des Hintergrund-Accounts darf den Badge nicht überschreiben).
        if account == NCManageDatabase.shared.getActiveTableAccount()?.account {
            LinkViewModel.postUnreadTotal(list)
        }
    }
}
