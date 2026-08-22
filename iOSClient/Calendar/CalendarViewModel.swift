// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// View model for the Souvera calendar module: discovers CalDAV calendars,
// loads the events of the visible month (cached and compressed for offline
// use) and performs create/update/delete.

import Combine
import Foundation
import SwiftUI

enum CalendarUiState<T> {
    case loading
    case success(T)
    case error(String)
}

@MainActor
final class CalendarViewModel: ObservableObject {
    @Published var events: CalendarUiState<[CalendarEventModel]> = .loading
    @Published var calendars: [CalDavCalendar] = []
    @Published var offlineNotice: String?
    @Published var visibleMonth: Date = Date()
    /// Active calendars; defaults to ALL available calendars and persists
    /// across launches until the user changes the selection.
    @Published var selectedCalendarHrefs: Set<String> = []
    @Published var customCalendarColors: [String: String] = [:]

    private let client = CalDavClient()
    private var cachedEntries: [CalDavEventEntry] = []

    private var accountKey: String {
        NCManageDatabase.shared.getActiveTableAccount()?.account ?? "default"
    }

    private var selectionDefaultsKey: String { "souveraCalendarSelection_\(accountKey)" }
    private var colorDefaultsKey: String { "souveraCalendarColors_\(accountKey)" }

    func isSelected(_ calendar: CalDavCalendar) -> Bool {
        selectedCalendarHrefs.contains(calendar.href)
    }

    func toggleCalendar(_ calendar: CalDavCalendar) {
        if selectedCalendarHrefs.contains(calendar.href) {
            selectedCalendarHrefs.remove(calendar.href)
        } else {
            selectedCalendarHrefs.insert(calendar.href)
        }
        persistSelection()
    }

    func color(for calendar: CalDavCalendar) -> Color? {
        let hex = customCalendarColors[calendar.href] ?? calendar.color ?? ""
        return Color(hex: hex)
    }

    func setCustomColor(_ hex: String, for calendar: CalDavCalendar) {
        if hex.isEmpty {
            customCalendarColors.removeValue(forKey: calendar.href)
        } else {
            customCalendarColors[calendar.href] = hex
        }
        UserDefaults.standard.set(customCalendarColors, forKey: colorDefaultsKey)
    }

    private func persistSelection() {
        UserDefaults.standard.set(Array(selectedCalendarHrefs), forKey: selectionDefaultsKey)
    }

    /// Restores the selection: previously stored choices are applied, newly
    /// discovered calendars start selected (all calendars visible by default).
    private func restoreSelection(_ discovered: [CalDavCalendar]) {
        customCalendarColors = UserDefaults.standard.dictionary(forKey: colorDefaultsKey) as? [String: String] ?? [:]
        let stored = UserDefaults.standard.stringArray(forKey: selectionDefaultsKey)
        if let stored, !stored.isEmpty {
            // Merge: keep stored selection for known calendars, select new ones.
            let known = Set(discovered.map(\.href))
            selectedCalendarHrefs = Set(stored).intersection(known)
            selectedCalendarHrefs.formUnion(known.subtracting(Set(stored)))
        } else {
            selectedCalendarHrefs = Set(discovered.map(\.href))
        }
    }

    var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: visibleMonth)
    }

    /// All days of the visible month (leading/trailing days included).
    var monthDays: [Date] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: visibleMonth) else { return [] }
        let firstDay = interval.start
        let weekday = calendar.component(.weekday, from: firstDay)
        let start = calendar.date(byAdding: .day, value: -(weekday - calendar.firstWeekday), to: firstDay) ?? firstDay
        var days: [Date] = []
        for offset in 0..<42 {
            if let day = calendar.date(byAdding: .day, value: offset, to: start) {
                days.append(day)
            }
        }
        return days
    }

    func events(on day: Date) -> [CalendarEventModel] {
        guard case let .success(all) = events else { return [] }
        let calendar = Calendar.current
        return all.filter {
            selectedCalendarHrefs.contains($0.calendarHref)
                && (calendar.isDate($0.start, inSameDayAs: day)
                    || ($0.allDay && day >= calendar.startOfDay(for: $0.start) && day < calendar.startOfDay(for: $0.end)))
        }.sorted { $0.start < $1.start }
    }

    func hasEvents(on day: Date) -> Bool {
        !events(on: day).isEmpty
    }

    /// The next upcoming events of the currently selected calendars (used
    /// below the month grid when the selected day has no events).
    func upcomingEvents(after date: Date = Date(), limit: Int = 3) -> [CalendarEventModel] {
        guard case let .success(all) = events else { return [] }
        return all.filter {
            selectedCalendarHrefs.contains($0.calendarHref) && $0.start >= date
        }.sorted { $0.start < $1.start }.prefix(limit).map { $0 }
    }

    /// Event color: the calendar's custom/server color, fallback brand.
    func color(for event: CalendarEventModel) -> Color {
        if let hex = customCalendarColors[event.calendarHref], !hex.isEmpty {
            return Color(hex: hex) ?? Color(NCBrandColor.shared.customer)
        }
        if let calendar = calendars.first(where: { $0.href == event.calendarHref }) {
            return Color(hex: calendar.color ?? "") ?? Color(NCBrandColor.shared.customer)
        }
        return Color(NCBrandColor.shared.customer)
    }

    func shiftMonth(by value: Int) {
        let calendar = Calendar.current
        if let shifted = calendar.date(byAdding: .month, value: value, to: visibleMonth) {
            visibleMonth = shifted
            Task { await load() }
        }
    }

    func ensureMonth(contains day: Date) {
        let calendar = Calendar.current
        guard !calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month) else { return }
        visibleMonth = day
        Task { await load() }
    }

    func load() async {
        events = .loading
        offlineNotice = nil

        let calendar = Calendar.current
        guard let monthInterval = calendar.dateInterval(of: .month, for: visibleMonth) else { return }
        // Extend the range by one day on both sides so events at the month
        // edges are covered regardless of the device timezone.
        let start = calendar.date(byAdding: .day, value: -1, to: monthInterval.start) ?? monthInterval.start
        let end = calendar.date(byAdding: .day, value: 1, to: (calendar.date(byAdding: .month, value: 1, to: monthInterval.start) ?? monthInterval.start.addingTimeInterval(31 * 86400))) ?? Date.distantFuture

        let discovered = await client.fetchCalendars()
        if !discovered.isEmpty {
            calendars = discovered
            restoreSelection(discovered)
        }

        var entries: [CalDavEventEntry] = []
        for cal in calendars where selectedCalendarHrefs.contains(cal.href) {
            entries += await client.fetchEvents(calendarHref: cal.href, start: start, end: end)
        }
        JmapLog.write("Calendar load: \(calendars.count) calendars, \(selectedCalendarHrefs.count) selected, \(entries.count) entries fetched")

        if entries.isEmpty, let cached = Self.loadCachedEntries(), !cached.isEmpty {
            entries = cached
            offlineNotice = NSLocalizedString("_mail_offline_", comment: "")
        }

        cachedEntries = entries
        Self.saveCachedEntries(entries)

        var all: [CalendarEventModel] = []
        for entry in entries {
            all += ICSParser.parseEvents(entry.ics, calendarHref: entry.calendarHref, href: entry.href, etag: entry.etag)
        }
        events = .success(all.sorted { $0.start < $1.start })
        SouveraReminderScheduler.schedule(for: all)
    }

    // MARK: - Mutations

    func saveEvent(_ draft: EventDraft, existing: CalendarEventModel?) async -> Bool {
        let ics = ICSParser.buildICS(draft)
        let ok: Bool
        if let existing {
            let entry = cachedEntries.first(where: { $0.href == existing.href })
                ?? CalDavEventEntry(calendarHref: existing.calendarHref, href: existing.href, etag: existing.etag, ics: ics)
            ok = await client.updateEvent(entry, ics: ics)
        } else {
            let targetCalendar = calendars.first?.href ?? ""
            guard !targetCalendar.isEmpty else { return false }
            let uid = draft.uid.isEmpty ? UUID().uuidString.lowercased() : draft.uid
            ok = await client.createEvent(calendarHref: targetCalendar, ics: ics, uid: uid) != nil
        }
        if ok {
            await load()
        }
        return ok
    }

    func deleteEvent(_ event: CalendarEventModel) async -> Bool {
        let entry = cachedEntries.first(where: { $0.href == event.href })
            ?? CalDavEventEntry(calendarHref: event.calendarHref, href: event.href, etag: event.etag, ics: "")
        let ok = await client.deleteEvent(entry)
        if ok {
            await load()
        }
        return ok
    }

    // MARK: - Talk channel for an event

    /// Creates a public Talk conversation named after the event, invites the
    /// attendees and stores the room on the event (X-SOUVERA-TALK-ROOM).
    func createTalkRoom(for event: CalendarEventModel) async -> Bool {
        guard let room = await createTalkRoomForDraft(name: event.title, attendees: event.attendees) else { return false }
        var draft = draft(from: event)
        draft.talkRoomToken = room.token
        draft.talkRoomName = room.name
        return await saveEvent(draft, existing: event)
    }

    /// Creates the Talk room without touching the event (used by the edit
    /// sheet before the event is saved).
    func createTalkRoomForDraft(name: String, attendees: [String]) async -> (token: String, name: String)? {
        guard let account = LinkAccount.active() else { return nil }
        let api = LinkOcsApi(account: account)
        guard let room = await api.createEventRoom(name: name) else { return nil }
        await api.addParticipants(token: room.token, userIds: attendees)
        return room
    }

    func openTalkRoom(for event: CalendarEventModel) {
        guard let token = event.talkRoomToken else { return }
        NotificationCenter.default.post(
            name: .openLinkRoom,
            object: ["token": token, "title": event.talkRoomName ?? event.title]
        )
    }

    func draft(from event: CalendarEventModel) -> EventDraft {
        var draft = EventDraft()
        draft.uid = event.uid
        draft.title = event.title
        draft.start = event.start
        draft.end = event.end
        draft.allDay = event.allDay
        draft.location = event.location ?? ""
        draft.notes = event.description ?? ""
        draft.attendees = event.attendees
        draft.talkRoomToken = event.talkRoomToken
        draft.talkRoomName = event.talkRoomName
        draft.reminders = event.reminders
        return draft
    }

    // MARK: - Cache

    private static var cacheKey: String { "calendar_events" }

    private static func saveCachedEntries(_ entries: [CalDavEventEntry]) {
        let array: [[String: Any]] = entries.map { entry in
            var dict: [String: Any] = ["calendarHref": entry.calendarHref, "href": entry.href, "ics": entry.ics]
            dict["etag"] = entry.etag ?? ""
            return dict
        }
        MailCache.saveJSON(array, key: cacheKey)
    }

    private static func loadCachedEntries() -> [CalDavEventEntry]? {
        guard let array = MailCache.loadJSON(key: cacheKey) as? [[String: Any]] else { return nil }
        return array.compactMap { dict in
            guard let href = dict["href"] as? String,
                  let calendarHref = dict["calendarHref"] as? String,
                  let ics = dict["ics"] as? String else { return nil }
            return CalDavEventEntry(calendarHref: calendarHref, href: href, etag: dict["etag"] as? String, ics: ics)
        }
    }
}
