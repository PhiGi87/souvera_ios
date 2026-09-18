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
    private var accountChangeObserver: NSObjectProtocol?
    /// Multi-Account-Generation: erhöht sich bei jedem Account-Wechsel.
    private var generation = 0

    init() {
        // Multi-Account: beim Account-Wechsel den Kalender-Zustand auf den
        // neuen Account umstellen (Cache-/Selektions-Keys + Client lösen den
        // Account pro Request auf).
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(NCGlobal.shared.notificationCenterChangeUser),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetForAccountChange()
            }
        }
    }

    deinit {
        if let accountChangeObserver {
            NotificationCenter.default.removeObserver(accountChangeObserver)
        }
    }

    private func resetForAccountChange() {
        generation += 1
        events = .loading
        eventsSignature = ""
        calendars = []
        cachedEntries = []
        selectedCalendarHrefs = []
        customCalendarColors = [:]
        sessionDeselectedHrefs = []
        offlineNotice = nil
        Task { await self.load() }
    }

    /// Periodically reloads mail/calendar in the foreground according to the
    /// "Hintergrundaktualisierung" setting (30 s check granularity).
    func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                // R2: 1-s-Prüfrhythmus (wie Mail) - kurze Intervalle
                // (15/30 s) werden exakt eingehalten.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
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

    /// Stabiler Cache-/Selection-Key. Priorität: AKTIVER Account; nur als
    /// Fallback (vor dem Session-Setup beim ersten Load) das erste Konto.
    /// Multi-Account: niemals die Daten eines anderen Accounts verwenden.
    private static func stableAccountKey() -> String {
        NCManageDatabase.shared.getActiveTableAccount()?.account
            ?? NCManageDatabase.shared.getAllTableAccount().first?.account
            ?? "default"
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
        let gen = generation
        offlineNotice = nil

        let calendar = Calendar.current
        guard let monthInterval = calendar.dateInterval(of: .month, for: visibleMonth) else { return }
        // Extend the range by one day on both sides so events at the month
        // edges are covered regardless of the device timezone.
        let start = calendar.date(byAdding: .day, value: -1, to: monthInterval.start) ?? monthInterval.start
        let end = calendar.date(byAdding: .day, value: 1, to: (calendar.date(byAdding: .month, value: 1, to: monthInterval.start) ?? monthInterval.start.addingTimeInterval(31 * 86400))) ?? Date.distantFuture

        // P68s + Run 15.09.: Sofortige Anzeige aus dem Monats-Cache —
        // JETZT IMMER (auch bei .success: Monatswechsel/Re-Entry zeigen
        // den Cache ad hoc, der Netz-Fetch aktualisiert danach).
        if let cached = Self.loadCachedEntries(month: visibleMonth), !cached.isEmpty {
            let cachedSorted = Self.parseEntries(cached, ownEmail: Self.ownAttendeeEmail()).sorted { $0.start < $1.start }
            let cachedSignature = cached.map { "\($0.href):\($0.etag)" }.joined(separator: ",")
            if eventsSignature != "cached-\(cachedSignature)" {
                eventsSignature = "cached-\(cachedSignature)"
                events = .success(cachedSorted)
                JmapLog.write("Calendar cache hit: \(cached.count) entries (ad hoc)")
            }
        } else {
            JmapLog.write("Calendar cache miss for visible month")
        }
        if calendars.isEmpty, let cachedCalendars = Self.loadCachedCalendars(), !cachedCalendars.isEmpty {
            calendars = cachedCalendars
            restoreSelection(cachedCalendars)
        }

        let discovered = await client.fetchCalendars()
        guard gen == self.generation else { return }
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

        // Vorheriger Stand je Kalender (Run 15.09.): der Server lieferte
        // im Log (d0gmaaa3ju) sekundenversetzt mal 13163-Byte-Antworten
        // (10 Events) und mal 239-Byte-LEER-Antworten fuer DENSELBEN
        // calendar-query - die Monatsansicht verlor dadurch kurzzeitig
        // alle Termine. Ein leeres Ergebnis fuer einen Kalender, der
        // vorher Events hatte, wird darum VERWORFEN (der vorherige Stand
        // bleibt; der naechste 30-s-Sync korrigiert).
        var previousByHref: [String: Int] = [:]
        for entry in cachedEntries {
            previousByHref[entry.calendarHref, default: 0] += 1
        }

        // Run 15.09.: Queries PARALLEL (TaskGroup) statt sequenziell —
        // die Gesamtladezeit ist jetzt die langsamste Einzelquery statt
        // der Summe aller Kalender.
        let selectedCalendars = calendars.filter { selectedCalendarHrefs.contains($0.href) }
        let calClient = client
        let results: [(String, [CalDavEventEntry])] = await withTaskGroup(of: (String, [CalDavEventEntry]).self) { group in
            for cal in selectedCalendars {
                group.addTask {
                    let fetched = await calClient.fetchEvents(calendarHref: cal.href, start: start, end: end)
                    return (cal.href, fetched)
                }
            }
            var collected: [(String, [CalDavEventEntry])] = []
            for await result in group { collected.append(result) }
            return collected
        }

        var entries: [CalDavEventEntry] = []
        var suspiciousEmpty: [String] = []
        for (href, fetched) in results {
            if fetched.isEmpty, let previous = previousByHref[href], previous > 0 {
                suspiciousEmpty.append(href)
                // Diagnose: Request-Body des Queries mitschreiben, um die
                // 239-Byte-207er-Anomalie (time-range?) zu verifizieren.
                if let body = await client.lastCalendarQueryBody(href: href) {
                    JmapLog.write("Calendar SUSPICIOUS empty result for \(href) (previous=\(previous)) query=\(String(body.prefix(300)))")
                } else {
                    JmapLog.write("Calendar SUSPICIOUS empty result for \(href) (previous=\(previous))")
                }
                continue
            }
            entries += fetched
        }
        JmapLog.write("Calendar load: \(calendars.count) calendars, \(selectedCalendarHrefs.count) selected, \(entries.count) entries fetched\(suspiciousEmpty.isEmpty ? "" : ", SUSPICIOUS-EMPTY: \(suspiciousEmpty.count)")")
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

        let all = Self.parseEntries(entries, ownEmail: Self.ownAttendeeEmail())
        let sortedAll = all.sorted { $0.start < $1.start }
        // Run 16.09.: offene Einladungen (ownPartstat = needs-action) an
        // den zentralen InvitationCenter melden (FAB-Badge + Sheet).
        let pending = sortedAll.filter { $0.ownPartstat == "needs-action" }
        await SouveraInvitationCenter.shared.setCalendarInvites(pending, accountKey: Self.stableAccountKey())
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
        // Run 15.09.: nie mit einer "verdächtig leeren" Liste planen -
        // schedule() ersetzt geplante Erinnerungen und wuerde sie sonst
        // löschen.
        if !all.isEmpty || previousByHref.values.allSatisfy({ $0 == 0 }) {
            SouveraReminderScheduler.schedule(for: all, account: NCManageDatabase.shared.getActiveTableAccount()?.account ?? "")
        } else {
            JmapLog.write("Calendar reminders: skipped suspicious-empty schedule (all=\(all.count))")
        }
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
            events = .success(Self.parseEntries(entries, ownEmail: Self.ownAttendeeEmail()).sorted { $0.start < $1.start })
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

    /// Run 19.09. (Feedback): Erinnerungen eines bestehenden Termins
    /// sofort speichern (setValarms + PUT) - einheitlich mit den
    /// Einladungen, auch nach dem Antworten.
    @discardableResult
    func updateReminders(_ event: CalendarEventModel, minutes: [Int]) async -> Bool {
        // Run 19.09. (Feedback: Erinnerungen kommen nicht am Server an):
        // UID-Fallback wie in respondToInvitation - bei per UID eingepflegten
        // Einladungen (href = Mail-ID) findet die href-Suche den Eintrag
        // nicht und der PUT wurde still ausgelassen.
        var entry = cachedEntries.first(where: { $0.href == event.href })
        if entry == nil, !event.uid.isEmpty {
            entry = cachedEntries.first(where: {
                $0.ics.uppercased().contains("UID:\(event.uid.uppercased())")
            })
        }
        guard var entryUnwrapped = entry, !entryUnwrapped.ics.isEmpty else {
            JmapLog.write("updateReminders: kein Eintrag (href=\(event.href) uid=\(event.uid))")
            actionFeedback = CalendarActionFeedback(
                success: false,
                message: NSLocalizedString("_calendar_reminder_save_failed_", comment: ""))
            return false
        }
        let updated = Self.setValarms(ics: entryUnwrapped.ics, minutes: minutes)
        var ok = await client.updateEvent(entryUnwrapped, ics: updated)
        if !ok {
            // 412 (stale ETag): ohne If-Match wiederholen.
            JmapLog.write("updateReminders: PUT fehlgeschlagen - Retry ohne If-Match")
            let retryEntry = CalDavEventEntry(calendarHref: entryUnwrapped.calendarHref,
                                              href: entryUnwrapped.href, etag: nil, ics: entryUnwrapped.ics)
            ok = await client.updateEvent(retryEntry, ics: updated)
        }
        let entryFinal = ok
            ? CalDavEventEntry(calendarHref: entryUnwrapped.calendarHref, href: entryUnwrapped.href,
                               etag: entryUnwrapped.etag, ics: updated)
            : entryUnwrapped
        if ok, let idx = cachedEntries.firstIndex(where: { $0.href == entryUnwrapped.href }) {
            cachedEntries[idx] = CalDavEventEntry(calendarHref: entryUnwrapped.calendarHref,
                                                  href: entryUnwrapped.href, etag: entryUnwrapped.etag, ics: updated)
            if case var .success(list) = events {
                let refreshed = Self.parseEntries([CalDavEventEntry(
                    calendarHref: entryFinal.calendarHref, href: entryFinal.href,
                    etag: entryFinal.etag, ics: updated)], ownEmail: Self.ownAttendeeEmail())
                list.removeAll { $0.href == event.href || (!event.uid.isEmpty && $0.uid == event.uid) }
                list.append(contentsOf: refreshed)
                events = .success(list.sorted { $0.start < $1.start })
            }
            actionFeedback = CalendarActionFeedback(
                success: true,
                message: NSLocalizedString("_calendar_reminder_saved_", comment: ""))
        } else {
            actionFeedback = CalendarActionFeedback(
                success: false,
                message: NSLocalizedString("_calendar_reminder_save_failed_", comment: ""))
        }
        return ok
    }

    // MARK: - Einladungen (Run 16.09.)

    enum CalendarRSVP: String, CaseIterable {
        case accepted = "ACCEPTED"
        case tentative = "TENTATIVE"
        case declined = "DECLINED"

        var titleKey: String {
            switch self {
            case .accepted: return "_invitations_accept_"
            case .tentative: return "_invitations_tentative_"
            case .declined: return "_invitations_decline_"
            }
        }
        var icon: String {
            switch self {
            case .accepted: return "checkmark.circle.fill"
            case .tentative: return "questionmark.circle"
            case .declined: return "xmark.circle.fill"
            }
        }
        var color: Color {
            switch self {
            case .accepted: return .green
            case .tentative: return .orange
            case .declined: return .red
            }
        }
    }

    /// Beantwortet eine Kalender-Einladung: PARTSTAT des eigenen
    /// ATTENDEE in der originalen ICS umschreiben und per PUT (If-Match)
    /// zurueckschreiben. Der Server verschickt die iTIP-Antwort selbst.
    func respondToInvitation(_ event: CalendarEventModel, status: CalendarRSVP,
                             reminderMinutes: [Int]? = nil) async -> Bool {
        var entry = cachedEntries.first(where: { $0.href == event.href })
        if entry == nil, !event.uid.isEmpty {
            // Run 16.09.: Mail-Einladung - der Server-Sync hat den Termin
            // vielleicht bereits unter anderer href eingespielt (UID-Match).
            entry = cachedEntries.first(where: {
                $0.ics.uppercased().contains("UID:\(event.uid.uppercased())")
            })
        }
        guard let entry, !entry.ics.isEmpty else {
            JmapLog.write("Invitation RSVP: no ics for \(event.href) uid=\(event.uid)")
            return false
        }
        let me = Self.ownAttendeeEmail()
        guard !me.isEmpty,
              var updated = Self.updatePartstat(ics: entry.ics, attendeeEmail: me, status: status.rawValue) else {
            JmapLog.write("Invitation RSVP: own attendee \(me) not found in \(event.href)")
            return false
        }
        // B4: Erinnerungen uebernehmen (Editor) bzw. 15-min-Default.
        if let reminderMinutes {
            updated = Self.setValarms(ics: updated, minutes: reminderMinutes)
        } else {
            updated = Self.ensureDefaultReminder(ics: updated, status: status.rawValue)
        }
        let ok = await client.updateEvent(entry, ics: updated)
        if ok {
            JmapLog.write("Invitation RSVP \(status.rawValue) ok for \(event.uid)")
            // Run 19.09. (Feedback): Eine ABLEHNUNG entfernt den Termin
            // komplett aus dem Kalender (nach dem PARTSTAT-PUT, damit der
            // Organisator die iTIP-Absage erhaelt).
            if status == .declined, Self.isForeignOrganizer(event) {
                let removed = await Self.deleteEventEntry(entry, client: client)
                JmapLog.write("Invitation RSVP DECLINED -> removed from calendar: \(removed)")
                cachedEntries.removeAll { $0.href == entry.href }
                if case var .success(list) = events {
                    list.removeAll { $0.href == event.href || (!event.uid.isEmpty && $0.uid == event.uid) }
                    events = .success(list)
                }
                if !event.uid.isEmpty {
                    SouveraInvitationCenter.markAnsweredUid(event.uid, end: event.end)
                }
                let remaining: [CalendarEventModel] = {
                    if case let .success(list) = events {
                        return list.filter { $0.ownPartstat == "needs-action" }
                    }
                    return []
                }()
                await SouveraInvitationCenter.shared.setCalendarInvites(
                    remaining, accountKey: Self.stableAccountKey())
                actionFeedback = CalendarActionFeedback(
                    success: true,
                    message: NSLocalizedString("_invitations_declined_removed_", comment: ""))
                if Self.organizerIsExternal(event.organizerEmail) {
                    _ = await SouveraInvitationCenter.sendReply(
                        event: event, statusWord: NSLocalizedString(status.titleKey, comment: ""),
                        altProposal: nil)
                }
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await self?.load()
                }
                return true
            }
            // B2: SOFORT-Feedback - betroffenen Eintrag lokal ersetzen und
            // neu parsen statt vollen Reload abzuwarten.
            if let idx = cachedEntries.firstIndex(where: { $0.href == entry.href }) {
                cachedEntries[idx] = CalDavEventEntry(calendarHref: entry.calendarHref,
                                                      href: entry.href, etag: entry.etag, ics: updated)
            }
            let refreshed = Self.parseEntries([CalDavEventEntry(
                calendarHref: entry.calendarHref, href: entry.href,
                etag: entry.etag, ics: updated)], ownEmail: me)
            if case var .success(list) = events {
                list.removeAll { $0.href == event.href || (!event.uid.isEmpty && $0.uid == event.uid) }
                list.append(contentsOf: refreshed)
                events = .success(list.sorted { $0.start < $1.start })
            }
            await SouveraInvitationCenter.shared.setCalendarInvites(
                refreshed.filter { $0.ownPartstat == "needs-action" },
                accountKey: Self.stableAccountKey())
            actionFeedback = CalendarActionFeedback(
                success: true,
                message: "\(NSLocalizedString(status.titleKey, comment: "")): \(event.title)")
            // Run 19.09.: Antwort lokal markieren (Uebersicht-Filter +
            // Schraffur sind sofort korrekt, unabhaengig vom Serverstand).
            if !event.uid.isEmpty {
                SouveraInvitationCenter.markAnsweredUid(event.uid, end: event.end,
                                                        status: status.rawValue)
            }
            // B6: Externer Organisator - Server-iTIP erreicht ihn nicht,
            // deshalb zusaetzlich die normale Antwort-Mail.
            if Self.organizerIsExternal(event.organizerEmail) {
                _ = await SouveraInvitationCenter.sendReply(
                    event: event, statusWord: NSLocalizedString(status.titleKey, comment: ""),
                    altProposal: nil)
            }
            // Stiller Hintergrund-Reload (Badges, weitere Foldes).
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.load()
            }
        }
        return ok
    }

    /// Run 16.09. (B4): Ersetzt alle VALARM-Blöcke durch die gegebenen
    /// Erinnerungen (Minuten vor Beginn). Leere Liste = keine Erinnerung.
    static func setValarms(ics: String, minutes: [Int]) -> String {
        var cleaned: [String] = []
        var inAlarm = false
        for raw in ics
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "BEGIN:VALARM" { inAlarm = true; continue }
            if line == "END:VALARM" { inAlarm = false; continue }
            if inAlarm { continue }
            cleaned.append(line)
        }
        guard !minutes.isEmpty,
              let endIdx = cleaned.firstIndex(where: { $0 == "END:VEVENT" }) else {
            return cleaned.joined(separator: "\r\n")
        }
        var alarms: [String] = []
        for m in minutes.sorted() {
            alarms += ["BEGIN:VALARM", "TRIGGER:-PT\(m)M", "ACTION:DISPLAY",
                       "DESCRIPTION:Erinnerung", "END:VALARM"]
        }
        cleaned.insert(contentsOf: alarms, at: endIdx)
        return cleaned.joined(separator: "\r\n")
    }

    /// Run 16.09. (B4): Standard-Erinnerung 15 min - nur wenn die ICS
    /// noch KEINEN VALARM enthält und die Antwort nicht "Abgelehnt" ist.
    static func ensureDefaultReminder(ics: String, status: String) -> String {
        if status == "DECLINED" { return ics }
        if ics.uppercased().contains("BEGIN:VALARM") { return ics }
        return setValarms(ics: ics, minutes: [15])
    }

    /// B6: Termin eines FREMD-Organisators (interne oder externe
    /// Einladung) - RSVP-Sektion im Detail anzeigen.
    static func isForeignOrganizer(_ event: CalendarEventModel) -> Bool {
        let me = ownAttendeeEmail()
        guard !me.isEmpty else { return false }
        let orga = event.organizerEmail.lowercased()
        guard !orga.isEmpty else { return false }
        return orga != me
    }

    /// Eigene Kalender-ORGANISATOR-Domain vs. Organisator des Termins -
    /// externe Organisatoren bekommen zusaetzlich eine normale Antwort-
    /// Mail (der Server-iTIP erreicht sie nicht).
    static func organizerIsExternal(_ organizerEmail: String) -> Bool {
        let me = ownAttendeeEmail()
        guard !me.isEmpty, organizerEmail.contains("@") else { return false }
        let myDomain = me.components(separatedBy: "@").last?.lowercased() ?? ""
        let orgaDomain = organizerEmail.components(separatedBy: "@").last?.lowercased() ?? ""
        return !myDomain.isEmpty && myDomain != orgaDomain
    }

    /// Run 19.09.: Event löschen - bei 412 (stale ETag) ohne If-Match
    /// wiederholen, 404/410 gilt als bereits entfernt.
    static func deleteEventEntry(_ entry: CalDavEventEntry,
                                 client: CalDavClient) async -> Bool {
        if await client.deleteEvent(entry) { return true }
        let withoutEtag = CalDavEventEntry(calendarHref: entry.calendarHref,
                                           href: entry.href, etag: nil, ics: entry.ics)
        return await client.deleteEvent(withoutEtag)
    }

    /// Schreibt PARTSTAT im eigenen ATTENDEE um (Case-insensitiver
    /// mailto:-Match, bestehenden PARTSTAT-Parameter ersetzen).
    static func updatePartstat(ics: String, attendeeEmail: String, status: String) -> String? {
        let target = attendeeEmail.lowercased()
        var found = false
        var lines: [String] = []
        // Run 16.09. (Feedback: "own attendee not found"): ICS ZUERST
        // entfalten - lange ATTENDEE-Zeilen sind RFC-5545-gefoldet
        // (Fortsetzung mit Leerzeichen/Tab), ohne Entfalten schlaegt der
        // mailto-Match fehl.
        var unfolded: [String] = []
        for raw in ics
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n") {
            if (raw.hasPrefix(" ") || raw.hasPrefix("\t")), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += String(raw.dropFirst())
            } else {
                unfolded.append(raw)
            }
        }
        for raw in unfolded {
            var line = raw
            if line.uppercased().hasPrefix("ATTENDEE"),
               line.lowercased().contains("mailto:\(target)") {
                found = true
                // Bestehenden PARTSTAT-Parameter entfernen
                if let range = line.range(of: "PARTSTAT=[A-Z-]+;", options: [.regularExpression, .caseInsensitive]) {
                    line = line.replacingCharacters(in: range, with: "")
                } else if let range = line.range(of: ";PARTSTAT=[A-Z-]+", options: [.regularExpression, .caseInsensitive]) {
                    line = line.replacingCharacters(in: range, with: "")
                }
                // Neuen PARTSTAT direkt nach ATTENDEE einfuegen
                if line.uppercased().hasPrefix("ATTENDEE;") {
                    line = "ATTENDEE;PARTSTAT=\(status);" + line.dropFirst("ATTENDEE;".count)
                } else {
                    line = "ATTENDEE;PARTSTAT=\(status):" + (line.split(separator: ":").dropFirst().joined(separator: ":"))
                }
            }
            lines.append(line)
        }
        guard found else {
            // Run 19.09. (Diagnose): Attendee-Zeilen loggen, wenn der
            // eigene Match fehlschlaegt - Erkennung von Format-Abweichungen.
            let attendees = unfolded.filter { $0.uppercased().hasPrefix("ATTENDEE") }
            JmapLog.write("updatePartstat: own attendee \(target) NOT found; attendees=\(attendees.joined(separator: " | "))")
            return nil
        }
        return lines.joined(separator: "\r\n")
    }

    private static func parseEntries(_ entries: [CalDavEventEntry],
                                     ownEmail: String? = nil) -> [CalendarEventModel] {
        var all: [CalendarEventModel] = []
        for entry in entries {
            all += ICSParser.parseEvents(entry.ics, calendarHref: entry.calendarHref, href: entry.href,
                                         etag: entry.etag, ownEmail: ownEmail)
        }
        return all
    }

    /// Eigene Adresse (Account-User) - Match fuer den eigenen ATTENDEE.
    static func ownAttendeeEmail() -> String {
        NCManageDatabase.shared.getActiveTableAccount()?.user.lowercased() ?? ""
    }

    private static var calendarListCacheKey: String { "calendar_list_" + stableAccountKey() }

    private static func saveCachedCalendars(_ calendars: [CalDavCalendar]) {
        let array: [[String: Any]] = calendars.map { ["href": $0.href, "displayName": $0.displayName, "color": $0.color ?? "", "canWrite": $0.canWrite] }
        MailCache.saveJSON(array, key: calendarListCacheKey)
    }

    private static func loadCachedCalendars() -> [CalDavCalendar]? {
        if let array = MailCache.loadJSON(key: calendarListCacheKey) as? [[String: Any]] {
            return decodeCalendars(array)
        }
        // Fallback: Alt-Cache unter dem "default"-Key (vor P68t).
        if let array = MailCache.loadJSON(key: "calendar_list_default") as? [[String: Any]] {
            return decodeCalendars(array)
        }
        return nil
    }

    private static func decodeCalendars(_ array: [[String: Any]]) -> [CalDavCalendar] {
        array.compactMap { dict in
            guard let href = dict["href"] as? String,
                  let displayName = dict["displayName"] as? String else { return nil }
            return CalDavCalendar(
                href: href,
                displayName: displayName,
                color: dict["color"] as? String,
                canWrite: (dict["canWrite"] as? Bool) ?? true
            )
        }
    }
}
