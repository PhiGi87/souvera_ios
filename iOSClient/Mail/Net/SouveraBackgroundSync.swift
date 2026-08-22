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
    }

    // MARK: - Mail

    private func syncMail() async {
        guard let credential = await SouveraMailCredentialManager().ensureCombinedCredential() else { return }
        let client = JmapClient(
            baseUrl: credential.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            username: credential.saslUser,
            password: credential.mailPassword
        )
        let api = JmapApi(client: client)
        guard let session = try? await client.refreshSession() else { return }
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
}
