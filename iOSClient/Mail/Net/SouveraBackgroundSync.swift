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
        guard NCManageDatabase.shared.getActiveTableAccount() != nil else { return }
        await syncMail()
        await syncCalendar()
        await syncLink()
    }

    // MARK: - Mail

    private func syncMail() async {
        guard var credential = await SouveraMailCredentialManager().ensureCombinedCredential() else { return }
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
        let accId = session.primaryAccountId
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
            content.title = NSLocalizedString("_mail_", comment: "")
            content.body = fromName.isEmpty ? subject : "\(fromName): \(subject)"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "mail_\(email.optString("id") ?? UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await notificationCenter.add(request)
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

    private func syncCalendar() async {
        let client = CalDavClient()
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

        // Erinnerungen anhand der VALARM-Daten der Termine planen (bis zu 64
        // kommende Notifications); Termine ohne Erinnerung bleiben still.
        SouveraReminderScheduler.schedule(for: upcoming)
    }

    // MARK: - Link

    /// Pollt die Talk-Konversationsliste, meldet neue ungelesene Nachrichten
    /// als lokale Benachrichtigungen und aktualisiert die Badge-Basis
    /// (Unread-Summe). Der LinkCache wird dabei mit dem frischen Stand
    /// gesichert (offline-fähig).
    private func syncLink() async {
        guard let account = LinkAccount.active() else { return }
        let api = LinkOcsApi(account: account)
        guard let list = await api.listConversations() else { return }

        let previous = LinkCache.loadConversations() ?? []
        let previousUnread = Dictionary(uniqueKeysWithValues: previous.map { ($0.token, $0.unreadMessages) })

        for room in list {
            let before = previousUnread[room.token] ?? 0
            let newCount = max(0, room.unreadMessages - before)
            guard newCount > 0, let last = room.lastMessage, !last.isSystemMessage else { continue }
            let sender = last.actorDisplayName.isEmpty ? room.displayName : last.actorDisplayName
            let preview = last.displayText()
            let content = UNMutableNotificationContent()
            content.title = room.displayName
            content.body = preview.isEmpty ? sender : "\(sender): \(preview)"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "talk_\(room.token)_\(last.id)",
                content: content,
                trigger: nil
            )
            try? await notificationCenter.add(request)
        }

        // Badge-Basis: Summe aller ungelesenen Nachrichten melden.
        LinkViewModel.postUnreadTotal(list)
    }
}
