// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Schedules local notifications for upcoming calendar events with reminders.
// Works from the offline cache, so reminders also fire without a server
// connection. Identifiers are prefixed so they can be replaced wholesale.

import Foundation
import UserNotifications

enum SouveraReminderScheduler {

    private static let prefix = "eventreminder_"

    /// Replaces pending event reminders for ONE account with notifications
    /// for the given events. iOS allows a maximum of 64 pending local
    /// notifications, so the soonest reminders win; every calendar load /
    /// background sync refills the queue (notifications fire even when the
    /// app is not running). PRO ACCOUNT: nur die eigenen Erinnerungen werden
    /// ersetzt (Multi-Account: A löscht nicht die Erinnerungen von B).
    static func schedule(for events: [CalendarEventModel], account: String = "") {
        let prefix = account.isEmpty ? Self.prefix : Self.prefix + account + "_"
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        center.getPendingNotificationRequests { existing in
            let stale = existing.filter { $0.identifier.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale.map(\.identifier))

            let now = Date()
            var pending: [(fireDate: Date, request: UNNotificationRequest)] = []
            for event in events {
                guard event.start > now, !event.reminders.isEmpty else { continue }
                for minutes in event.reminders {
                    let fireDate = event.start.addingTimeInterval(-Double(minutes) * 60)
                    guard fireDate > now else { continue }
                    let content = UNMutableNotificationContent()
                    // Kalender-Stil: "Termin: <Name>" FETT (Titelzeile),
                    // Datum + Uhrzeit darunter in normaler Schrift.
                    let name = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    content.title = SouveraNotificationText.title(
                        String(format: NSLocalizedString("_push_event_title_", comment: ""), name.isEmpty ? "—" : name)
                    )
                    content.body = SouveraNotificationText.body(
                        DateFormatter.localizedString(from: event.start, dateStyle: .medium, timeStyle: .short)
                    )
                    content.sound = SouveraCalendarReminderSound.stored.sound // Deep-Link-Payload: Tap öffnet direkt die Detail-Ansicht
                    // des Termins.
                    content.userInfo = [
                        "uid": event.uid,
                        "start": event.start.timeIntervalSince1970,
                        // Account für den Deep-Link (Multi-Account: Termin
                        // im richtigen Account öffnen).
                        "account": account
                    ]
                    let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                    let request = UNNotificationRequest(
                        identifier: "\(prefix)\(event.uid)_\(minutes)",
                        content: content,
                        trigger: trigger
                    )
                    pending.append((fireDate, request))
                }
            }
            pending.sort { $0.fireDate < $1.fireDate }
            let scheduled = min(pending.count, 64)
            for item in pending.prefix(64) {
                center.add(item.request)
            }
            JmapLog.write("Calendar reminders: scheduled \(scheduled) of \(pending.count) notifications (max 64)")
        }
    }
}
