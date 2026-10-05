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
        // Run 05.10. (Fix: keine Erinnerung für "Domains umziehen"):
        // Ein LEERER Lauf (leere Event-Liste, z. B. zweite View-Instanz /
        // leerer Sync) hat bisher ALLE Erinnerungen des Accounts gelöscht -
        // direkt nach jedem vollen Lauf ("6 of 6" -> "0 of 0" im Log), so
        // dass die 13:45-Erinnerung nie feuerte. Jetzt: gar nicht erst
        // anfassen.
        guard !events.isEmpty else {
            JmapLog.write("Calendar reminders: skipped empty schedule (kept pending)")
            return
        }
        let prefix = account.isEmpty ? Self.prefix : Self.prefix + account + "_"
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        center.getPendingNotificationRequests { existing in
            let prefixed = existing.filter { $0.identifier.hasPrefix(prefix) }

            let now = Date()
            var pending: [(fireDate: Date, request: UNNotificationRequest)] = []
            // Run 05.10.: Kandidaten-IDs ALLER übergebenen Termine (auch
            // vergangener) - nur diese werden ersetzt/entfernt; Erinnerungen
            // anderer Termine (anderes Monatsfenster) bleiben erhalten.
            var candidateIds = Set<String>()
            for event in events {
                guard !event.uid.isEmpty else { continue }
                for minutes in event.reminders {
                    let id = "\(prefix)\(event.uid)_\(minutes)"
                    candidateIds.insert(id)
                    candidateIds.insert("\(prefix)catchup_\(event.uid)_\(minutes)")
                    guard event.start > now else { continue }
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
                    content.sound = SouveraCalendarReminderSound.sound(account: account).sound // Deep-Link-Payload: Tap öffnet direkt die Detail-Ansicht
                    // des Termins.
                    // Run 19.09. (Feedback: Banner teils erst spät): Fokus/
                    // Mitteilungszusammenfassung dürfen Kalender-Erinnerungen
                    // NICHT verzögern.
                    content.interruptionLevel = .timeSensitive
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
                        identifier: id,
                        content: content,
                        trigger: trigger
                    )
                    pending.append((fireDate, request))
                }
            }
            pending.sort { $0.fireDate < $1.fireDate }
            let wanted = Array(pending.prefix(64))
            let wantedIds = Set(wanted.map { $0.request.identifier })
            // Run 05.10.: per-UID-Merge statt Prefix-Wipe - nur Erinnerungen
            // der übergebenen Termine, die nicht mehr gebraucht werden
            // (vergangen/entfernte Erinnerung), werden entfernt.
            let stale = prefixed.filter { candidateIds.contains($0.identifier) && !wantedIds.contains($0.identifier) }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale.map(\.identifier))
            }
            for item in wanted {
                center.add(item.request)
            }
            JmapLog.write("Calendar reminders: scheduled \(wanted.count) of \(pending.count) notifications (max 64, kept \(prefixed.count - stale.count + wanted.count) total, replaced/removed \(stale.count))")
            for item in wanted {
                let uid = (item.request.content.userInfo["uid"] as? String) ?? "?"
                JmapLog.write("Calendar reminder: '\(item.request.content.title.prefix(40))' uid=\(uid.prefix(10)) fire=\(item.fireDate)")
            }

            // Catch-up (Run 15.09., Log d29maaa3g2): Termine, die BEI
            // geschlossener App angelegt wurden, haben keine geplante
            // lokale Erinnerung - ihr Erinnerungszeitpunkt kann waehrend
            // des App-Downloads gerade verpasst worden sein. Bei diesem
            // Foreground-Laden sofort nachliefern (Fenster: letzte 10 min,
            // Termin muss noch in der Zukunft liegen).
            // Run 19.09. (Feedback: "Beginnt in 10 min" DOPPELT zur
            // 15-Min-Erinnerung, Log d13eaaa3x7): Der Catch-up darf nur
            // nachliefern, wenn die EIGENTLICHE Erinnerung NICHT bereits
            // zugestellt (delivered) oder noch geplant (pending) ist -
            // sonst dupliziert jeder Sync im 10-min-Fenster die Erinnerung.
            center.getDeliveredNotifications { delivered in
                let deliveredIds = Set(delivered.map { $0.request.identifier })
                let pendingIds = Set(existing.map(\.identifier))
                var missed: [(event: CalendarEventModel, minutes: Int)] = []
                for event in events {
                    guard event.start > now, !event.reminders.isEmpty else { continue }
                    for minutes in event.reminders {
                        let fire = event.start.addingTimeInterval(-Double(minutes) * 60)
                        guard fire <= now, now.timeIntervalSince(fire) <= 600 else { continue }
                        let standardId = "\(prefix)\(event.uid)_\(minutes)"
                        let catchupId = "\(prefix)catchup_\(event.uid)_\(minutes)"
                        // Stabile Catch-up-ID (statt Zeitstempel) - der
                        // Delivered-Check erkennt damit auch wiederholte
                        // Catch-ups desselben Ereignisses.
                        if pendingIds.contains(standardId) || pendingIds.contains(catchupId) { continue }
                        if deliveredIds.contains(standardId) || deliveredIds.contains(catchupId) { continue }
                        missed.append((event, minutes))
                    }
                }
                for miss in missed {
                    let event = miss.event
                    let minutes = miss.minutes
                    let content = UNMutableNotificationContent()
                let name = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
                content.title = SouveraNotificationText.title(
                    String(format: NSLocalizedString("_push_event_title_", comment: ""), name.isEmpty ? "—" : name)
                )
                let minutesLeft = max(1, Int(event.start.timeIntervalSince(now) / 60))
                content.body = SouveraNotificationText.body(
                    String(format: NSLocalizedString("_push_event_catchup_", comment: ""), minutesLeft)
                )
                content.sound = SouveraCalendarReminderSound.sound(account: account).sound
                content.interruptionLevel = .timeSensitive
                content.userInfo = [
                    "uid": event.uid,
                    "start": event.start.timeIntervalSince1970,
                    "account": account
                ]
                    let request = UNNotificationRequest(
                        identifier: "\(prefix)catchup_\(event.uid)_\(minutes)",
                        content: content,
                        trigger: nil // sofort
                    )
                    center.add(request)
                }
                if !missed.isEmpty {
                    JmapLog.write("Calendar reminders: catch-up delivered for \(missed.count) event(s)")
                }
            }
        }
    }
}
