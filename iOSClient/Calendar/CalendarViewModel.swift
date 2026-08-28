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

/// Kurzer Rückmelde-Hinweis für Kalender-Aktionen (Toast).
struct CalendarActionFeedback: Equatable {
    let success: Bool
    let message: String
}

@MainActor
final class CalendarViewModel: ObservableObject {
    @Published var events: CalendarUiState<[CalendarEventModel]> = .loading
    @Published var calendars: [CalDavCalendar] = []
    @Published var offlineNotice: String?
    private var eventsSignature = ""
    /// Transienter Trigger für den "Server-Error: Cache aktiv"-Banner.
    @Published var cacheBannerActive = false
    private let cacheBannerGate = SouveraCacheBannerGate()
    @Published var visibleMonth: Date = Date()
    /// Active calendars; defaults to ALL available calendars and persists
    /// across launches until the user changes the selection.
    @Published var selectedCalendarHrefs: Set<String> = []
    @Published var customCalendarColors: [String: String] = [:]
    @Published var actionFeedback: CalendarActionFeedback?

    private let client = CalDavClient()
    private var cachedEntries: [CalDavEventEntry] = []
    private var autoRefreshTask: Task<Void, Never>?
    private var lastAutoRefresh: Date = Date()

    /// Periodically reloads mail/calendar in the foreground according to the
    /// "Hintergrundaktualisierung" setting (30 s check granularity).
    func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard let interval = SouveraAutoRefresh.interval else { continue }
                if Date().timeIntervalSince(self.lastAutoRefresh) >= interval {
                    self.lastAutoRefresh = Date()
                    await self.load()
                }
            }
        }
    }

    /// In dieser Sitzung abgewählte Kalender: werden von restoreSelection
    /// nie wieder automatisch aktiviert.
    private var sessionDeselectedHrefs: Set<String> = []

    /// P68t: Stabiler Cache-/Selection-Key. getAllTableAccount().first
    /// ist ab App-Start gefüllt, während getActiveTableAccount() beim
    /// allerersten Load (vor dem Session-Setup) noch nil ist - das
    /// verursachte den Cache-Miss nach dem frischen App-Start.
    private static func stableAccountKey() -> String {
        NCManageDatabase.shared.getAllTableAccount().first?.account ?? "default"
    }

    private var accountKey: String {
        Self.stableAccountKey()
    }

    private var selectionDefaultsKey: String { "souveraCalendarSelection_\(accountKey)" }
    private var colorDefaultsKey: String { "souveraCalendarColors_\(accountKey)" }

    func isSelected(_ calendar: CalDavCalendar) -> Bool {
        selectedCalendarHrefs.contains(calendar.href)
    }

    func toggleCalendar(_ calendar: CalDavCalendar) {
        if selectedCalendarHrefs.contains(calendar.href) {
            selectedCalendarHrefs.remove(calendar.href)
            sessionDeselectedHrefs.insert(calendar.href)
        } else {
            selectedCalendarHrefs.insert(calendar.href)
            sessionDeselectedHrefs.remove(calendar.href)
        }
        persistSelection()
        let persisted = UserDefaults.standard.stringArray(forKey: selectionDefaultsKey)?.count ?? -1
        JmapLog.write("Calendar toggle: \(calendar.displayName) -> selected=\(selectedCalendarHrefs.count) persisted=\(persisted)")
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
        // Sitzungs-Schutz: in dieser Sitzung abgewählte Kalender bleiben aus.
        if !sessionDeselectedHrefs.isEmpty {
            selectedCalendarHrefs.subtract(sessionDeselectedHrefs)
        }
        JmapLog.write("Calendar restore: stored=\(stored?.count ?? -1) result=\(selectedCalendarHrefs.count)")
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

    /// Springt gezielt zu einem Monat (Monat/Jahr-Auswahl).
    func jumpToMonth(_ date: Date) {
        let calendar = Calendar.current
        if let start = calendar.dateInterval(of: .month, for: date)?.start {
            visibleMonth = start
        } else {
            visibleMonth = date
        }
        Task { await load() }
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
        offlineNotice = nil

        let calendar = Calendar.current
        guard let monthInterval = calendar.dateInterval(of: .month, for: visibleMonth) else { return }
        // Extend the range by one day on both sides so events at the month
        // edges are covered regardless of the device timezone.
        let start = calendar.date(byAdding: .day, value: -1, to: monthInterval.start) ?? monthInterval.start
        let end = calendar.date(byAdding: .day, value: 1, to: (calendar.date(byAdding: .month, value: 1, to: monthInterval.start) ?? monthInterval.start.addingTimeInterval(31 * 86400))) ?? Date.distantFuture

        // P68s: Sofortige Anzeige aus dem Monats-Cache (kein leerer
        // Lade-Screen) + gecachte Kalenderliste VOR dem Server-Abruf.
        if case .loading = events {
            if let cached = Self.loadCachedEntries(month: visibleMonth), !cached.isEmpty {
                let cachedSorted = Self.parseEntries(cached).sorted { $0.start < $1.start }
                if eventsSignature != "cached-\(cached.count)" {
                    eventsSignature = "cached-\(cached.count)"
                    events = .success(cachedSorted)
                }
                JmapLog.write("Calendar cache hit: \(cached.count) entries")
            } else {
                JmapLog.write("Calendar cache miss for visible month")
            }
        }
        if calendars.isEmpty, let cachedCalendars = Self.loadCachedCalendars(), !cachedCalendars.isEmpty {
            calendars = cachedCalendars
            restoreSelection(cachedCalendars)
        }

        let discovered = await client.fetchCalendars()
        if !discovered.isEmpty {
            calendars = discovered
            restoreSelection(discovered)
            Self.saveCachedCalendars(discovered)
        } else if calendars.isEmpty, let cachedCalendars = Self.loadCachedCalendars(), !cachedCalendars.isEmpty {
            // Server nicht erreichbar: Kalenderliste aus dem Cache.
            calendars = cachedCalendars
            restoreSelection(cachedCalendars)
            cacheBannerActive = cacheBannerGate.shouldTrigger()
        }

        var entries: [CalDavEventEntry] = []
        for cal in calendars where selectedCalendarHrefs.contains(cal.href) {
            entries += await client.fetchEvents(calendarHref: cal.href, start: start, end: end)
        }
        JmapLog.write("Calendar load: \(calendars.count) calendars, \(selectedCalendarHrefs.count) selected, \(entries.count) entries fetched")
        JmapLog.write("Calendar selection: \(selectedCalendarHrefs.sorted().joined(separator: ", "))")

        if entries.isEmpty, let cached = Self.loadCachedEntries(month: visibleMonth), !cached.isEmpty {
            entries = cached
            offlineNotice = NSLocalizedString("_mail_offline_", comment: "")
            cacheBannerActive = cacheBannerGate.shouldTrigger()
        }

        cachedEntries = entries
        Self.saveCachedEntries(entries, month: visibleMonth)
        loadedStart = start
        loadedEnd = end

        let all = Self.parseEntries(entries)
        let sortedAll = all.sorted { $0.start < $1.start }
        // Redundanz-Guard: identische Event-Stände nicht erneut setzen.
        let signature = entries.map { "\($0.href):\($0.etag)" }.joined(separator: ",")
        if signature != eventsSignature {
            eventsSignature = signature
            events = .success(sortedAll)
        }
        for event in all.prefix(12) {
            JmapLog.write("Calendar event parsed: \"\(event.title)\" start=\(event.start) uid=\(event.uid) attendees=[\(event.attendees.joined(separator: ","))] reminders=[\(event.reminders.map(String.init).joined(separator: ","))]")
        }
        if all.count > 12 {
            JmapLog.write("Calendar event parsed: ... \(all.count - 12) weitere")
        }
        SouveraReminderScheduler.schedule(for: all, account: NCManageDatabase.shared.getActiveTableAccount()?.account ?? "")
    }

    // MARK: - Mutations

    /// Geladenes Zeitfenster (aus dem letzten load()) - Tage außerhalb
    /// werden bei Bedarf gezielt nachgeladen.
    private var loadedStart: Date?
    private var loadedEnd: Date?

    /// Stellt sicher, dass der übergebene Tag vom geladenen Fenster
    /// abgedeckt ist; lädt sonst gezielt die Events genau dieses Tages nach
    /// (CalDAV-REPORT mit Tages-range). So zeigt die Tagesliste in der
    /// Monatsansicht IMMER alle Termine des ausgewählten Tags - egal wie
    /// weit er außerhalb des Monatsfensters liegt (keine Zeitbeschränkung).
    /// Deep-Link aus einer Termin-Erinnerung: lädt den Tag nach (falls noch
    /// nicht abgedeckt) und sucht den Termin anhand der uid.
    func findEvent(uid: String, on day: Date) async -> CalendarEventModel? {
        await ensureDayCovered(day)
        return events(on: day).first(where: { $0.uid == uid })
    }

    func ensureDayCovered(_ day: Date) async {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        if let loadedStart, let loadedEnd, dayStart >= loadedStart && dayStart <= loadedEnd {
            return
        }
        guard !selectedCalendarHrefs.isEmpty else { return }

        var entries = cachedEntries
        var known = Set(entries.map(\.href))
        let dayEnd = dayStart.addingTimeInterval(86400)
        for cal in calendars where selectedCalendarHrefs.contains(cal.href) {
            let fetched = await client.fetchEvents(calendarHref: cal.href, start: dayStart, end: dayEnd)
            for entry in fetched where !known.contains(entry.href) {
                entries.append(entry)
                known.insert(entry.href)
            }
        }
        cachedEntries = entries
        loadedStart = [loadedStart, dayStart].compactMap { $0 }.min()
        loadedEnd = [loadedEnd, dayEnd].compactMap { $0 }.max()
        Self.saveCachedEntries(entries, month: visibleMonth)

        let signature = entries.map { "\($0.href):\($0.etag)" }.joined(separator: ",")
        if signature != eventsSignature {
            eventsSignature = signature
            events = .success(Self.parseEntries(entries).sorted { $0.start < $1.start })
        }
        JmapLog.write("Calendar ensureDayCovered \(day): entries=\(entries.count)")
    }

    func saveEvent(_ draft: EventDraft, existing: CalendarEventModel?) async -> Bool {
        let account = NCManageDatabase.shared.getActiveTableAccount()
        let organizerEmail = account?.user ?? ""
        let organizerName = account?.displayName ?? ""
        var finalDraft = draft
        if existing != nil { finalDraft.sequence = max(finalDraft.sequence, 1) }
        let ics = ICSParser.buildICS(finalDraft, organizerEmail: organizerEmail, organizerName: organizerName)
        let interesting = ics.components(separatedBy: "\r\n")
            .filter {
                $0.hasPrefix("LOCATION") || $0.hasPrefix("X-SOUVERA") || $0.hasPrefix("DESCRIPTION")
                    || $0.hasPrefix("BEGIN:VALARM") || $0.hasPrefix("TRIGGER")
                    || $0.hasPrefix("ATTENDEE") || $0.hasPrefix("ORGANIZER")
            }
            .joined(separator: " | ")
        JmapLog.write("Calendar saveEvent existing=\(existing != nil) talk=\(draft.talkRoomToken ?? "-") \n\(interesting)")
        let ok: Bool
        if let existing {
            let entry = cachedEntries.first(where: { $0.href == existing.href })
                ?? CalDavEventEntry(calendarHref: existing.calendarHref, href: existing.href, etag: existing.etag, ics: ics)
            ok = await client.updateEvent(entry, ics: ics)
        } else {
            // Ziel-Kalender: gewählter (schreibbarer) Kalender, sonst der
            // eigene/persönliche, sonst bisheriger Fallback.
            let chosen: CalDavCalendar? =
                calendars.first(where: { $0.href == draft.calendarHref && $0.canWrite })
                ?? calendars.first(where: { $0.canWrite && $0.isPersonal })
                ?? calendars.first(where: { $0.canWrite && !$0.href.contains("deck") })
                ?? calendars.first(where: { !$0.href.contains("deck") })
            guard let targetCalendar = chosen else { return false }
            let uid = draft.uid.isEmpty ? UUID().uuidString.lowercased() : draft.uid
            ok = await client.createEvent(calendarHref: targetCalendar.href, ics: ics, uid: uid) != nil
        }
        if ok {
            await load()
            actionFeedback = CalendarActionFeedback(
                success: true,
                message: NSLocalizedString("_calendar_saved_", comment: "")
            )
        }
        return ok
    }

    func deleteEvent(_ event: CalendarEventModel) async -> Bool {
        let entry = cachedEntries.first(where: { $0.href == event.href })
            ?? CalDavEventEntry(calendarHref: event.calendarHref, href: event.href, etag: event.etag, ics: "")
        let ok = await client.deleteEvent(entry)
        if ok {
            await load()
            actionFeedback = CalendarActionFeedback(
                success: true,
                message: NSLocalizedString("_calendar_deleted_", comment: "")
            )
        }
        return ok
    }

    // MARK: - Talk channel for an event

    /// Creates a public Talk conversation named after the event, invites the
    /// attendees and stores the room on the event (X-SOUVERA-TALK-ROOM).
    func createTalkRoom(for event: CalendarEventModel) async -> Bool {
        guard let room = await createTalkRoomForDraft(
            name: event.title,
            attendees: event.attendees,
            eventUid: event.uid,
            notes: event.description ?? ""
        ) else { return false }
        var draft = draft(from: event)
        draft.talkRoomToken = room.token
        draft.talkRoomName = room.name
        // Link im Standardfeld ablegen (wie NC-Web-UI), damit er mit dem
        // Termin und den Einladungen mitwandert.
        if draft.location.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.location = room.url
        } else {
            draft.notes = draft.notes.isEmpty ? room.url : draft.notes + "\n\n" + room.url
        }
        let saved = await saveEvent(draft, existing: event)
        if saved {
            actionFeedback = CalendarActionFeedback(
                success: true,
                message: NSLocalizedString("_calendar_talk_created_", comment: "")
            )
        } else {
            actionFeedback = CalendarActionFeedback(
                success: false,
                message: NSLocalizedString("_calendar_talk_error_", comment: "")
            )
        }
        return saved
    }

    /// Creates the Talk room without touching the event (used by the edit
    /// sheet before the event is saved).
    func createTalkRoomForDraft(name: String, attendees: [String], eventUid: String, notes: String) async -> (token: String, name: String, url: String)? {
        guard let account = LinkAccount.active() else { return nil }
        let api = LinkOcsApi(account: account)
        let objectId = eventUid.isEmpty ? UUID().uuidString.lowercased() : eventUid
        guard let room = await api.createEventRoom(name: name, objectId: objectId, description: notes) else { return nil }

        // P67: KEINE addParticipants-Aufrufe mehr - die Teilnehmer werden
        // bereits über den Termin (iCal-ATTENDEE) eingeladen; eine zweite
        // Einladung über Talk würde doppelte Mails auslösen. Der Server
        // kann Teilnehmer über die Termin-Einladung mappen. Lobby bleibt
        // aktiv, damit Unbekannte erst freigegeben werden müssen.
        JmapLog.write("Calendar talk room \(room.token): created without addParticipants (\(attendees.count) attendees via calendar invite)")

        // Lobby immer aktivieren: Eingeladene warten auf die Freigabe,
        // Owner/Moderatoren sind davon ausgenommen.
        await api.setLobby(token: room.token, enabled: true)
        JmapLog.write("Calendar talk room \(room.token): lobby enabled")

        let root = account.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = "\(root)/index.php/call/\(room.token)"
        NotificationCenter.default.post(name: .linkRoomsChanged, object: nil)
        return (room.token, room.name, url)
    }

    /// Deletes a Talk conversation (used when the user removes the link from
    /// an event).
    func deleteTalkRoom(token: String) async {
        guard let account = LinkAccount.active() else { return }
        let api = LinkOcsApi(account: account)
        await api.deleteRoom(token: token)
        JmapLog.write("Calendar talk room deleted: \(token)")
        NotificationCenter.default.post(name: .linkRoomsChanged, object: nil)
        actionFeedback = CalendarActionFeedback(
            success: true,
            message: NSLocalizedString("_calendar_talk_deleted_", comment: "")
        )
    }

    func openTalkRoom(for event: CalendarEventModel) {
        guard let token = event.talkRoomToken else { return }
        NotificationCenter.default.post(
            name: .openLinkRoom,
            object: ["token": token, "title": event.talkRoomName ?? event.title]
        )
    }

    /// Schreibbare Kalender für neue Termine (kein Deck - das sind
    /// VTODO-Boards, keine VEVENT-Ziele).
    var writableCalendars: [CalDavCalendar] {
        calendars.filter { $0.canWrite && !$0.href.contains("deck") }
    }

    /// Standard-Zielkalender: der eigene/persönliche Kalender.
    var defaultCalendar: CalDavCalendar? {
        writableCalendars.first(where: { $0.isPersonal })
            ?? writableCalendars.first
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
        draft.sequence = event.sequence + 1
        draft.talkRoomToken = event.talkRoomToken
        draft.talkRoomName = event.talkRoomName
        draft.reminders = event.reminders
        draft.calendarHref = event.calendarHref
        return draft
    }

    // MARK: - Cache

    private static func cacheKey(for month: Date, account: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return "calendar_events_" + account + "_" + formatter.string(from: month)
    }

    private static func saveCachedEntries(_ entries: [CalDavEventEntry], month: Date) {
        // P68s: Einen guten Cache NIE mit einem leeren Ergebnis überschreiben
        // (ein fehlgeschlagener Fetch löschte sonst den Sofort-Start).
        guard !entries.isEmpty else {
            JmapLog.write("Calendar cache: skip empty save")
            return
        }
        let array: [[String: Any]] = entries.map { entry in
            var dict: [String: Any] = ["calendarHref": entry.calendarHref, "href": entry.href, "ics": entry.ics]
            dict["etag"] = entry.etag ?? ""
            return dict
        }
        MailCache.saveJSON(array, key: cacheKey(for: month, account: stableAccountKey()))
    }

    private static func loadCachedEntries(month: Date) -> [CalDavEventEntry]? {
        let key = cacheKey(for: month, account: stableAccountKey())
        if let array = MailCache.loadJSON(key: key) as? [[String: Any]] { return decodeEntries(array) }
        // Fallback: Alt-Cache unter dem "default"-Key (vor P68t).
        if let array = MailCache.loadJSON(key: cacheKey(for: month, account: "default")) as? [[String: Any]] { return decodeEntries(array) }
        return nil
    }

    private static func decodeEntries(_ array: [[String: Any]]) -> [CalDavEventEntry] {
        array.compactMap { dict in
            guard let href = dict["href"] as? String,
                  let calendarHref = dict["calendarHref"] as? String,
                  let ics = dict["ics"] as? String else { return nil }
            return CalDavEventEntry(calendarHref: calendarHref, href: href, etag: dict["etag"] as? String, ics: ics)
        }
    }

    private static func parseEntries(_ entries: [CalDavEventEntry]) -> [CalendarEventModel] {
        var all: [CalendarEventModel] = []
        for entry in entries {
            all += ICSParser.parseEvents(entry.ics, calendarHref: entry.calendarHref, href: entry.href, etag: entry.etag)
        }
        return all
    }

    private static var calendarListCacheKey: String { "calendar_list_" + stableAccountKey() }

    private static func saveCachedCalendars(_ calendars: [CalDavCalendar]) {
        let array: [[String: Any]] = calendars.map { ["href": $0.href, "displayName": $0.displayName, "color": $0.color ?? "", "canWrite": $0.canWrite] }
        MailCache.saveJSON(array, key: calendarListCacheKey)
    }

    private static func loadCachedCalendars() -> [CalDavCalendar]? {
        if let array = MailCache.loadJSON(key: calendarListCacheKey) as? [[String: Any]] {
            return array.compactMap { CalDavCalendar(dict: $0) }
        }
        // Fallback: Alt-Cache unter dem "default"-Key (vor P68t).
        if let array = MailCache.loadJSON(key: "calendar_list_default") as? [[String: Any]] {
            return array.compactMap { CalDavCalendar(dict: $0) }
        }
        return nil
    }
}
