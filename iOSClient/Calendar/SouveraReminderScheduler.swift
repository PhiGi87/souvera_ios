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

    /// Replaces all pending event reminders with notifications for the given
    /// events (limited to events starting within the next 7 days).
    static func schedule(for events: [CalendarEventModel]) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { existing in
            let stale = existing.filter { $0.identifier.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale.map(\.identifier))

            let now = Date()
            let horizon = now.addingTimeInterval(7 * 86400)
            var scheduled = 0
            for event in events {
                guard event.start > now, event.start <= horizon, !event.reminders.isEmpty else { continue }
                for minutes in event.reminders {
                    let fireDate = event.start.addingTimeInterval(-Double(minutes) * 60)
                    guard fireDate > now else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = event.title
                    content.body = DateFormatter.localizedString(from: event.start, dateStyle: .medium, timeStyle: .short)
                    content.sound = .default
                    let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                    let request = UNNotificationRequest(
                        identifier: "\(prefix)\(event.uid)_\(minutes)",
                        content: content,
                        trigger: trigger
                    )
                    center.add(request)
                    scheduled += 1
                }
            }
            if scheduled > 0 {
                JmapLog.write("Calendar reminders: scheduled \(scheduled) notifications")
            }
        }
    }
}
