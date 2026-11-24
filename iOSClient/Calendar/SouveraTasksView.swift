// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 25.11. (Tasks, standalone): eigenständiger Aufgaben-Screen im
// Mehr-Menü. Lädt VTODOs aus ALLEN Kalendern mit supportsTasks (PROPFIND
// via fetchCalendars, REPORT via CalDavClient.fetchTodos), zeigt offene
// Tasks zuerst (nach Fälligkeit, undatierte zuletzt) und erledigte
// eingeklappt. Abhaken via ICSParser.completeTodo/uncompleteTodo + PUT
// mit If-Match (Muster performEventUpdate), optimistische UI.
// Basis der Netzwerk-/Parsing-Logik: Commit 230e7585fd (Kalender-UI-
// Integration bleibt revertiert - hier nur das standalone Modul).

import SwiftUI

@MainActor
final class SouveraTasksViewModel: ObservableObject {
    /// Ein dargestellter Task: Roh-ICS-Eintrag (für den PUT) + geparstes
    /// Model (Titel, Status, Fälligkeit).
    struct TaskItem: Identifiable {
        let entry: CalDavEventEntry
        let event: CalendarEventModel
        /// Undatierte Tasks (Parser-Anker: Tagesanfang heute) - sortieren
        /// sie ans Ende der offenen Liste, Detail zeigt "ohne Fälligkeit".
        let isUndated: Bool

        var id: String { entry.href }
    }

    @Published var openTasks: [TaskItem] = []
    @Published var completedTasks: [TaskItem] = []
    @Published var isLoading = false
    /// Dezente Fehlermeldung (Banner unter der Liste), z. B. nach
    /// fehlgeschlagenem Abhaken oder Ladefehler.
    @Published var errorMessage: String?
    /// Run 26.11.: Task-Kalender mit Schreibrecht (canWrite && supportsTasks)
    /// - Grundlage für die Kalender-Auswahl im Neuanlage-Sheet.
    @Published var writableTaskCalendars: [CalDavCalendar] = []
    /// Run 25.11.: ALLE Task-Kalender (supportsTasks, auch ohne Schreib-
    /// recht) für die Listen-Sidebar.
    @Published var taskLists: [CalDavCalendar] = []
    /// Run 25.11.: Todo-Anzahl je Listen-href - wird in der Sidebar neben
    /// dem Listennamen angezeigt.
    @Published var todoCounts: [String: Int] = [:]

    private let client = CalDavClient()
    /// Roh-Einträge nach href - Basis für die Toggle-PUTs (If-Match).
    private var entriesByHref: [String: CalDavEventEntry] = [:]

    /// Lädt alle Tasks aus allen Task-Kalendern neu (Pull-to-refresh und
    /// Refresh-Button).
    func load() async {
        isLoading = true
        defer { isLoading = false }
        // Run 26.11. (Feedback "Banner obwohl Queries ok"): veraltete
        // Fehlermeldung beim Neuladen zurücksetzen - sie hing sonst als
        // Banner in der Liste, obwohl alle todo-Queries erfolgreich waren.
        errorMessage = nil
        let calendars = await client.fetchCalendars().filter { $0.supportsTasks }
        // Run 26.11.: Schreibbare Task-Kalender parallel mithalten (Picker
        // im Neuanlage-Sheet; Fallback dort: erster Eintrag).
        writableTaskCalendars = calendars.filter { $0.canWrite }
        // Run 25.11.: Alle Listen für die Sidebar mithalten.
        taskLists = calendars
        todoCounts = [:]
        guard !calendars.isEmpty else {
            SouveraLog.write("Tasks", "load: keine Task-Kalender (supportsTasks) gefunden")
            apply([], [])
            return
        }
        // Run 25.11.: Task-Kalender parallel abfragen (Muster TaskGroup,
        // wie im revertierten CalendarViewModel-TaskGroup-Zweig).
        // Run 26.11. (Feedback): Ergebnis je Kalender zählen - ein
        // Teilfehler (z. B. ein Kalender, der auf den VTODO-REPORT leer
        // oder fehlerhaft reagiert) setzt KEINEN Gesamt-Fehler mehr;
        // die erfolgreichen Daten werden angezeigt. Der Banner erscheint
        // nur, wenn ALLE Task-Kalender nichts liefern.
        let results = await withTaskGroup(of: (String, [CalDavEventEntry]).self) { group in
            for calendar in calendars {
                group.addTask { [client] in
                    let entries = await client.fetchTodos(calendarHref: calendar.href)
                    return (calendar.href, entries)
                }
            }
            var all: [(String, [CalDavEventEntry])] = []
            for await result in group {
                all.append(result)
            }
            return all
        }
        var all: [CalDavEventEntry] = []
        var emptyCalendars: [String] = []
        for (href, entries) in results {
            SouveraLog.write("Tasks", "load: \(href) -> \(entries.count) Todos")
            if entries.isEmpty { emptyCalendars.append(href) }
            all.append(contentsOf: entries)
            // Run 25.11.: Todo-Anzahl je Liste für die Sidebar.
            todoCounts[href] = entries.count
        }
        if all.isEmpty {
            SouveraLog.write("Tasks", "load: ALLE \(calendars.count) Task-Kalender lieferten 0 Todos -> Banner")
            errorMessage = NSLocalizedString("_tasks_error_", value: "Tasks could not be updated.", comment: "")
        } else if !emptyCalendars.isEmpty {
            SouveraLog.write("Tasks", "load: Teilfehler/leer bei \(emptyCalendars.count)/\(calendars.count) Kalendern (\(emptyCalendars.joined(separator: ", "))) - erfolgreiche Daten werden angezeigt")
        }
        // Dedup nach href (ein Kalender kann theoretisch doppelt
        // auftauchen, z. B. bei mehreren Principal-Kandidaten).
        var byHref: [String: CalDavEventEntry] = [:]
        for entry in all where !entry.href.isEmpty {
            byHref[entry.href] = entry
        }
        entriesByHref = byHref

        var open: [TaskItem] = []
        var completed: [TaskItem] = []
        for entry in byHref.values {
            let parsed = ICSParser.parseEvents(entry.ics,
                                               calendarHref: entry.calendarHref,
                                               href: entry.href,
                                               etag: entry.etag)
            guard let event = parsed.first else { continue }
            let item = TaskItem(entry: entry, event: event, isUndated: Self.isUndated(event))
            if event.isCompleted {
                completed.append(item)
            } else {
                open.append(item)
            }
        }
        apply(open, completed)
    }

    /// Offene Tasks nach Fälligkeit aufsteigend, undatierte zuletzt;
    /// erledigte nach COMPLETED/Start absteigend (zuletzt erledigt oben).
    private func apply(_ open: [TaskItem], _ completed: [TaskItem]) {
        openTasks = open.sorted { lhs, rhs in
            if lhs.isUndated != rhs.isUndated { return rhs.isUndated }
            return lhs.event.start < rhs.event.start
        }
        completedTasks = completed.sorted { $0.event.start > $1.event.start }
    }

    /// Heuristik wie im Detail-View: Parser-Anker für undatierte Tasks ist
    /// der Tagesanfang von heute mit kurzer Dauer.
    static func isUndated(_ event: CalendarEventModel) -> Bool {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        return event.start == dayStart
            && event.end.timeIntervalSince(event.start) <= 900
    }

    /// Abhaken / Zurücknehmen: optimistisch die UI drehen, die ICS
    /// umschreiben (REPORT calendar-data; bei Stale-ETag frisch nachladen)
    /// und per PUT mit If-Match zurückschreiben. Bei endgültigem
    /// Fehlschlag: UI zurückdrehen + dezente Fehlermeldung.
    func toggle(_ item: TaskItem) async {
        // Run 26.11. (Feedback "Speichern geht nicht"): Diagnose-Logging
        // am Start - ohne ICS-Laenge/ETag/calendarHref war der Fehler
        // nicht auffindbar.
        SouveraLog.write("Tasks", "toggle: '\(item.event.title)' href=\(item.entry.href), ics=\(item.entry.ics.count)B, etag=\(item.entry.etag != nil ? "vorhanden" : "FEHLT"), calendar=\(item.entry.calendarHref)")
        let wasCompleted = item.event.isCompleted
        let targetItem = flip(item)
        mutate(item: item, with: targetItem)
        errorMessage = nil

        // ICS auf dem aktuellen Stand umschreiben - bei einem veralteten
        // ETag (412) einmalig frisch laden und erneut versuchen (Muster
        // scheduleEventSync aus dem Kalender-Modul).
        var entry = targetItem.entry
        // Run 26.11. (Härtung): Wenn der REPORT keinen ICS-Body lieferte,
        // vor dem Patch frisch nachladen - auf einem leeren String patchen
        // erzeugt eine invalide ICS und der PUT scheitert.
        if entry.ics.isEmpty {
            SouveraLog.write("Tasks", "toggle: ICS leer -> frisch nachladen")
            if let fresh = await client.fetchEventICS(entry) {
                entry = CalDavEventEntry(calendarHref: entry.calendarHref,
                                         href: entry.href,
                                         etag: entry.etag,
                                         ics: fresh)
            } else {
                SouveraLog.write("Tasks", "toggle: ICS leer und Nachladen fehlgeschlagen -> Abbruch")
                mutate(item: targetItem, with: item)
                errorMessage = NSLocalizedString("_tasks_error_", value: "Tasks could not be updated.", comment: "")
                return
            }
        }
        var newICS = wasCompleted
            ? ICSParser.uncompleteTodo(entry.ics)
            : ICSParser.completeTodo(entry.ics)
        SouveraLog.write("Tasks", "toggle: gepatchte ICS \(newICS.count)B (etag \(entry.etag != nil ? "mit" : "OHNE") If-Match)")
        var result = await client.performEventUpdate(entry, ics: newICS)
        SouveraLog.write("Tasks", "toggle: PUT -> \(result.ok ? "ok" : "FEHLER"), etag=\(result.etag ?? "-")")
        if !result.ok {
            if let fresh = await client.fetchEventICS(entry) {
                newICS = wasCompleted
                    ? ICSParser.uncompleteTodo(fresh)
                    : ICSParser.completeTodo(fresh)
                entry = CalDavEventEntry(calendarHref: entry.calendarHref,
                                         href: entry.href,
                                         etag: nil,
                                         ics: fresh)
                result = await client.performEventUpdate(entry, ics: newICS)
                SouveraLog.write("Tasks", "toggle: Retry-PUT (frisch geladen) -> \(result.ok ? "ok" : "FEHLER"), etag=\(result.etag ?? "-")")
            }
        }
        guard result.ok else {
            // Rollback der optimistischen Änderung.
            SouveraLog.write("Tasks", "toggle: endgültig fehlgeschlagen -> Rollback")
            mutate(item: targetItem, with: item)
            errorMessage = NSLocalizedString("_tasks_error_", value: "Tasks could not be updated.", comment: "")
            return
        }
        // Neuen Server-ETag übernehmen (nächster Toggle trifft den
        // aktuellen Stand); die ICS vom Server nachziehen, damit der
        // naechste Toggle auf dem echten Stand aufsetzt. CalDavEventEntry
        // hat let-Felder - daher neu konstruieren statt mutieren.
        var updatedEntry = CalDavEventEntry(calendarHref: targetItem.entry.calendarHref,
                                            href: targetItem.entry.href,
                                            etag: result.etag ?? targetItem.entry.etag,
                                            ics: targetItem.entry.ics)
        if let ics = await client.fetchEventICS(updatedEntry) {
            updatedEntry = CalDavEventEntry(calendarHref: updatedEntry.calendarHref,
                                            href: updatedEntry.href,
                                            etag: updatedEntry.etag,
                                            ics: ics)
        }
        entriesByHref[updatedEntry.href] = updatedEntry
        mutate(item: targetItem, with: TaskItem(entry: updatedEntry,
                                                event: targetItem.event,
                                                isUndated: targetItem.isUndated))
    }

    /// Run 26.11.: Bearbeiteten Task speichern - die ICS wird via
    /// ICSParser.updateTodoFields gepatcht (SUMMARY/DESCRIPTION/DUE/
    /// DTSTAMP) und per PUT mit If-Match (Muster performEventUpdate)
    /// zurueckgeschrieben; bei Stale-ETag (412) einmalig frisch nachladen
    /// und erneut versuchen (Muster toggle). Optimistische lokale
    /// Aktualisierung der Listen statt Refresh der ganzen Liste.
    /// Rueckgabe true = PUT erfolgreich.
    func saveEdit(_ item: TaskItem,
                  summary: String,
                  notes: String?,
                  due: Date?,
                  hasDue: Bool) async -> Bool {
        errorMessage = nil
        // Run 26.11. (Feedback "Speichern geht nicht"): Diagnose-Logging
        // am Start - Entry-Zustand vor dem PATCH sichtbar machen.
        SouveraLog.write("Tasks", "saveEdit: '\(summary)' href=\(item.entry.href), ics=\(item.entry.ics.count)B, etag=\(item.entry.etag != nil ? "vorhanden" : "FEHLT -> PUT ohne If-Match"), calendar=\(item.entry.calendarHref), hasDue=\(hasDue)")

        // ICS patchen und PUT mit dem ETag des Eintrags versuchen - bei
        // Stale-ETag frisch nachladen und erneut versuchen.
        var entry = item.entry
        // Run 26.11. (Härtung): Wenn der REPORT keinen ICS-Body lieferte,
        // vor dem Patch frisch nachladen - auf einem leeren String patchen
        // erzeugt eine invalide ICS und der PUT scheitert.
        if entry.ics.isEmpty {
            SouveraLog.write("Tasks", "saveEdit: ICS leer -> frisch nachladen")
            if let fresh = await client.fetchEventICS(entry) {
                entry = CalDavEventEntry(calendarHref: entry.calendarHref,
                                         href: entry.href,
                                         etag: entry.etag,
                                         ics: fresh)
            } else {
                SouveraLog.write("Tasks", "saveEdit: ICS leer und Nachladen fehlgeschlagen -> Abbruch")
                errorMessage = NSLocalizedString("_tasks_error_", value: "Tasks could not be updated.", comment: "")
                return false
            }
        }
        // Diagnose: enthält die ICS überhaupt einen VTODO-Block? Sonst
        // liefert updateTodoFields die ICS unverändert zurück und der
        // PUT schreibt den alten Stand zurück (Speichern "wirkt tot").
        if !entry.ics.uppercased().contains("BEGIN:VTODO") {
            SouveraLog.write("Tasks", "saveEdit: WARNUNG - ICS enthält keinen VTODO-Block, Patch wird keine Wirkung haben")
        }
        var newICS = ICSParser.updateTodoFields(entry.ics,
                                                summary: summary,
                                                notes: notes,
                                                due: due,
                                                hasDue: hasDue)
        SouveraLog.write("Tasks", "saveEdit: gepatchte ICS \(newICS.count)B")
        var result = await client.performEventUpdate(entry, ics: newICS)
        SouveraLog.write("Tasks", "saveEdit: PUT -> \(result.ok ? "ok" : "FEHLER"), etag=\(result.etag ?? "-")")
        if !result.ok, let fresh = await client.fetchEventICS(entry) {
            newICS = ICSParser.updateTodoFields(fresh,
                                                summary: summary,
                                                notes: notes,
                                                due: due,
                                                hasDue: hasDue)
            entry = CalDavEventEntry(calendarHref: entry.calendarHref,
                                     href: entry.href,
                                     etag: nil,
                                     ics: fresh)
            result = await client.performEventUpdate(entry, ics: newICS)
            SouveraLog.write("Tasks", "saveEdit: Retry-PUT (frisch geladen) -> \(result.ok ? "ok" : "FEHLER"), etag=\(result.etag ?? "-")")
        }
        guard result.ok else {
            // Kein Rollback noetig - die UI wurde noch nicht gedreht.
            SouveraLog.write("Tasks", "saveEdit: endgültig fehlgeschlagen")
            errorMessage = NSLocalizedString("_tasks_error_", value: "Tasks could not be updated.", comment: "")
            return false
        }
        SouveraLog.write("Tasks", "saveEdit: erfolgreich")

        // Lokale Aktualisierung: CalendarEventModel hat let-Felder -
        // daher komplett neu konstruieren (Muster toggle). Die Fälligkeit
        // wird als ganztägiges Datum dargestellt (entspricht
        // DUE;VALUE=DATE); ohne Fälligkeit Parser-Anker wie bei
        // undatierten Tasks (Tagesanfang heute, 15 Minuten).
        let calendar = Calendar.current
        let newStart: Date
        let newEnd: Date
        let newAllDay: Bool
        if hasDue {
            let day = calendar.startOfDay(for: due ?? Date())
            newStart = day
            newEnd = day.addingTimeInterval(86400)
            newAllDay = true
        } else {
            let dayStart = calendar.startOfDay(for: Date())
            newStart = dayStart
            newEnd = dayStart.addingTimeInterval(900)
            newAllDay = false
        }
        let newEvent = CalendarEventModel(
            id: item.event.id,
            uid: item.event.uid,
            sequence: item.event.sequence,
            title: summary,
            start: newStart,
            end: newEnd,
            allDay: newAllDay,
            location: item.event.location,
            description: (notes?.isEmpty == false) ? notes : nil,
            attendees: item.event.attendees,
            talkRoomToken: item.event.talkRoomToken,
            talkRoomName: item.event.talkRoomName,
            calendarHref: item.event.calendarHref,
            href: item.event.href,
            etag: result.etag ?? item.entry.etag,
            reminders: item.event.reminders,
            isTask: item.event.isTask,
            organizerName: item.event.organizerName,
            organizerEmail: item.event.organizerEmail,
            ownPartstat: item.event.ownPartstat,
            taskStatus: item.event.taskStatus,
            isCompleted: item.event.isCompleted
        )
        var updatedEntry = CalDavEventEntry(calendarHref: entry.calendarHref,
                                            href: entry.href,
                                            etag: result.etag ?? entry.etag,
                                            ics: newICS)
        // Server-ICS nachziehen, damit der naechste PUT/Toggle auf dem
        // echten Serverstand aufsetzt (Muster toggle).
        if let fresh = await client.fetchEventICS(updatedEntry) {
            updatedEntry = CalDavEventEntry(calendarHref: updatedEntry.calendarHref,
                                            href: updatedEntry.href,
                                            etag: updatedEntry.etag,
                                            ics: fresh)
        }
        mutate(item: item, with: TaskItem(entry: updatedEntry,
                                          event: newEvent,
                                          isUndated: Self.isUndated(newEvent)))
        return true
    }

    /// Run 26.11.: Neue Aufgabe anlegen - minimalen VTODO via
    /// ICSParser.buildVTODO bauen und als neue Ressource PUTen (Muster
    /// createEvent: PUT ohne If-Match, Dateiname aus der bereinigten UID).
    /// Zielkalender: der uebergebene canWrite && supportsTasks-Kalender.
    /// Danach die Liste neu laden (der Server ordnet href/ETag selbst).
    func createTask(summary: String,
                    notes: String?,
                    due: Date?,
                    hasDue: Bool,
                    calendar: CalDavCalendar) async -> Bool {
        errorMessage = nil
        let uid = UUID().uuidString.lowercased()
        let ics = ICSParser.buildVTODO(uid: uid,
                                       summary: summary,
                                       notes: notes,
                                       due: due,
                                       hasDue: hasDue)
        guard await client.createEvent(calendarHref: calendar.href, ics: ics, uid: uid) != nil else {
            errorMessage = NSLocalizedString("_tasks_error_", value: "Tasks could not be updated.", comment: "")
            return false
        }
        await load()
        return true
    }

    // MARK: - Run 25.11.: Read-only-Listen (Deck / ohne Schreibrecht)

    /// Account-Schlüssel für die Settings-Ablage (Muster
    /// CalendarViewModel.stableAccountKey).
    static func stableAccountKey() -> String {
        NCManageDatabase.shared.getActiveTableAccount()?.account
            ?? NCManageDatabase.shared.getAllTableAccount().first?.account
            ?? "default"
    }

    /// Run 25.11.: Deck-Listen (Board-Karten als VTODO) und Listen ohne
    /// Schreibrecht sind read-only - Checkbox und Bearbeitung gesperrt.
    /// Bekannter Kalender: canWrite/Deck-Kategorie; unbekannter href:
    /// Deck-Heuristik wie in CalDavCalendar.supportsTasks.
    func isReadOnlyList(href: String) -> Bool {
        if let calendar = taskLists.first(where: { $0.href == href }) {
            return !calendar.canWrite || calendar.category == .deck
        }
        return href.range(of: "deck", options: .caseInsensitive) != nil
    }

    /// Ersetzt ein Item in beiden Listen durch ein aktualisiertes (gleiche
    /// id) und verschiebt es ggf. in die andere Sektion.
    private func mutate(item: TaskItem, with updated: TaskItem) {
        openTasks.removeAll { $0.id == item.id }
        completedTasks.removeAll { $0.id == item.id }
        if updated.event.isCompleted {
            completedTasks.append(updated)
            completedTasks.sort { $0.event.start > $1.event.start }
        } else {
            openTasks.append(updated)
            openTasks.sort { lhs, rhs in
                if lhs.isUndated != rhs.isUndated { return rhs.isUndated }
                return lhs.event.start < rhs.event.start
            }
        }
        entriesByHref[updated.id] = updated.entry
    }

    private func flip(_ item: TaskItem) -> TaskItem {
        var event = item.event
        event.taskStatus = event.isCompleted ? "NEEDS-ACTION" : "COMPLETED"
        event.isCompleted.toggle()
        return TaskItem(entry: item.entry, event: event, isUndated: item.isUndated)
    }
}

/// Standalone-Aufgabenliste im Mehr-Menü (gepusht via pushHosted - der
/// Header kommt vom System-UINavigationBar, siehe Header Rule).
struct SouveraTasksView: View {
    @StateObject private var viewModel = SouveraTasksViewModel()
    /// Ausgewählter Task für das Detail-Sheet.
    @State private var selectedItem: SouveraTasksViewModel.TaskItem?
    @State private var showCompleted = false
    /// Run 26.11.: Neuanlage-Sheet.
    @State private var showNewTaskSheet = false
    // Run 25.11.: Listen-Sidebar - Listen-Spalte eingeklappt und aktive
    // Listen. Beides bewusst NICHT persistiert (wie
    // roomsCollapsed im Link-Modul); die Spalte existiert nur bei breitem
    // Layout (Fensterbreite >= 720pt, wie Kalender).
    // Run 25.11. (Multiselect, wie CalendarPickerSheet): Mehrere Listen
    // gleichzeitig sichtbar - leeres Set = alle Listen. Tap toggelt die
    // Liste im Set statt sie zu ersetzen.
    @State private var listsCollapsed = false
    @State private var selectedLists: Set<String> = []
    @State private var isWideLayout = false

    var body: some View {
        // Run 25.11.: Listen-Sidebar (Muster LinkView/Raumliste) - nur bei
        // breitem Layout (>= 720pt) gibt es die linke Spalte; der Toggle
        // im Header blendet sie mit snappy-Animation ein/aus.
        GeometryReader { bounds in
            let wide = bounds.size.width >= 720
            HStack(spacing: 0) {
                if wide && !listsCollapsed {
                    taskListSidebar
                        .frame(width: 260)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider()
                }
                taskListView
            }
            .onAppear { isWideLayout = wide }
            .onChange(of: bounds.size.width) { _, width in
                isWideLayout = width >= 720
            }
        }
        .toolbar {
            // Run 25.11.: Sidebar-Toggle (Muster LinkView sidebar.left),
            // nur bei breitem Layout - schmal hat keine Spalte zum Blenden.
            ToolbarItem(placement: .topBarLeading) {
                if isWideLayout {
                    Button {
                        withAnimation(.snappy(duration: 0.3)) {
                            listsCollapsed.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .accessibilityLabel(Text(NSLocalizedString("_tasks_lists_toggle_",
                                                               value: "Show or hide lists",
                                                               comment: "")))
                }
            }
            // Run 26.11.: Listen-Auswahl im schmalen Layout (iPhone/
            // Außendisplay) - dort gibt es keine Sidebar. Menu über
            // alle Task-Listen ("Alle Listen" oben); Tap toggelt die
            // Liste im Set (Multiselect, wie Kalender).
            ToolbarItem(placement: .topBarLeading) {
                if !isWideLayout {
                    Menu {
                        Button {
                            selectedLists = []
                        } label: {
                            if selectedLists.isEmpty {
                                Label(NSLocalizedString("_tasks_lists_all_",
                                                        value: "All lists", comment: ""),
                                      systemImage: "checkmark")
                            } else {
                                Text(NSLocalizedString("_tasks_lists_all_",
                                                       value: "All lists", comment: ""))
                            }
                        }
                        // Run 25.11. (Gruppierung): gleiche Sections wie
                        // die Sidebar, dieselbe Datenquelle (ownLists/
                        // deckLists) - nur nicht-leere Sections zeigen.
                        if !ownLists.isEmpty {
                            Section(NSLocalizedString("_tasks_lists_own_",
                                                      value: "Own lists", comment: "")) {
                                ForEach(ownLists, id: \.href) { list in
                                    menuListRow(list)
                                }
                            }
                        }
                        if !deckLists.isEmpty {
                            Section(NSLocalizedString("_tasks_lists_deck_",
                                                      value: "Deck lists", comment: "")) {
                                ForEach(deckLists, id: \.href) { list in
                                    menuListRow(list)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel(Text(NSLocalizedString("_tasks_lists_all_",
                                                               value: "All lists", comment: "")))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNewTaskSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text(NSLocalizedString("_tasks_new_", value: "New task", comment: "")))
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Run 26.11. (Layout-Fix): ProgressView und Icon stapeln
                // sich in einem ZStack mit fester Größe - der Wechsel
                // isLoading löst keinen Toolbar-Layout-Sprung mehr aus.
                Button {
                    Task { await viewModel.load() }
                } label: {
                    ZStack {
                        Image(systemName: "arrow.clockwise")
                            .opacity(viewModel.isLoading ? 0 : 1)
                        ProgressView()
                            .frame(width: 20, height: 20)
                            .opacity(viewModel.isLoading ? 1 : 0)
                    }
                }
            }
        }
        .sheet(item: $selectedItem) { item in
            SouveraCalendarTaskDetailView(viewModel: viewModel, item: item)
        }
        // Run 26.11.: Neuanlage-Sheet über Toolbar "+".
        .sheet(isPresented: $showNewTaskSheet) {
            SouveraTaskNewSheet(viewModel: viewModel)
        }
    }

    // MARK: - Run 25.11.: Listen-Sidebar (Deck/Eigene, wie Kalender)

    /// Eigene Listen (persönlich, kein Deck).
    private var ownLists: [CalDavCalendar] {
        viewModel.taskLists.filter { $0.isPersonal && $0.category != .deck }
    }

    /// Deck-Listen (Board-Karten als VTODO).
    private var deckLists: [CalDavCalendar] {
        viewModel.taskLists.filter { $0.category == .deck }
    }

    /// Run 25.11. (Gruppierung): Zeile im schmalen Toolbar-Menu -
    /// identische Auswahl-Logik/Datenquelle wie die Sidebar-Zeile.
    private func menuListRow(_ list: CalDavCalendar) -> some View {
        Button {
            toggleList(list.href)
        } label: {
            if selectedLists.contains(list.href) {
                Label(list.displayName, systemImage: "checkmark")
            } else {
                Text(list.displayName)
            }
        }
    }

    /// Zeile in der Sidebar: Listenname + Todo-Anzahl, aktive Listen
    /// hervorgehoben. Tap toggelt die Liste im Set (Multiselect).
    private func listRow(_ list: CalDavCalendar) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                toggleList(list.href)
            }
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(hex: list.color ?? "") ?? Color(NCBrandColor.shared.customer))
                    .frame(width: 10, height: 10)
                Text(list.displayName)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                Text("\(viewModel.todoCounts[list.href] ?? 0)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if selectedLists.contains(list.href) {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(Color.Souvera.brandPrimaryDeep)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Run 25.11. (Multiselect): Toggle einer Liste im Auswahl-Set -
    /// gemeinsam von Sidebar und schmalem Menu genutzt (wie
    /// viewModel.toggleCalendar im Kalender).
    /// Run 25.11. (Audit): Diagnose-Logging beim Toggle - ohne dieses Log
    /// war nicht nachvollziehbar, ob ein Tap die Auswahl wirklich aendert
    /// (Nutzer-Feedback "Multiauswahl geht nicht" auf Build 202611242250).
    private func toggleList(_ href: String) {
        let key = normalizedHref(href)
        if selectedLists.contains(key) {
            selectedLists.remove(key)
        } else {
            selectedLists.insert(key)
        }
        SouveraLog.write("Tasks", "list toggle: \(href) -> selected=\(selectedLists.sorted().joined(separator: ", "))")
    }

    /// Run 25.11. (Audit): href-Normalisierung fuer den Listen-Vergleich.
    /// Die Task-Eintraege tragen event.calendarHref aus dem REPORT und die
    /// Sidebar list.href aus dem PROPFIND - beide stammen aus derselben
    /// Multistatus-Antwort und matchen exakt, aber Collection-hrefs koennen
    /// je nach Server mit/ohne trailing slash geliefert werden. Damit ein
    /// Tap nicht "ins Leere" laeuft, wird beim Vergleich der Slash
    /// entfernt (Beide Seiten werden normalisiert - Set-Schluessel UND
    /// Filter-Vergleich).
    private func normalizedHref(_ href: String) -> String {
        var trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private var taskListSidebar: some View {
        List {
            // "Alle" - Auswahl leeren (= alle Listen sichtbar).
            Section {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        selectedLists = []
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "tray.full")
                            .font(.body)
                            .foregroundStyle(Color.Souvera.brandPrimaryDeep)
                        Text(NSLocalizedString("_tasks_lists_all_", value: "All", comment: ""))
                            .font(.body)
                        Spacer()
                        if selectedLists.isEmpty {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(Color.Souvera.brandPrimaryDeep)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            if !ownLists.isEmpty {
                Section(header: Text(NSLocalizedString("_tasks_lists_own_",
                                                       value: "Own lists",
                                                       comment: ""))) {
                    ForEach(ownLists, id: \.href) { list in
                        listRow(list)
                    }
                }
            }

            if !deckLists.isEmpty {
                Section(header: Text(NSLocalizedString("_tasks_lists_deck_",
                                                       value: "Deck lists",
                                                       comment: ""))) {
                    ForEach(deckLists, id: \.href) { list in
                        listRow(list)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Die Aufgaben-Liste - gefiltert nach den ausgewählten Listen
    /// (leeres Set = alle). Run 25.11. (Audit): der Filter vergleicht
    /// normalisierte hrefs (siehe normalizedHref) - event.calendarHref
    /// der Tasks stammt aus fetchTodos und ist genau das calendar.href
    /// derselben Liste, aber ein abweichender trailing slash haette den
    /// Filter stumm gemacht (wahrgenommen als "Multiselect geht nicht").
    private var taskListView: some View {
        let filteredOpen = selectedLists.isEmpty
            ? viewModel.openTasks
            : viewModel.openTasks.filter { selectedLists.contains(normalizedHref($0.event.calendarHref)) }
        let filteredCompleted = selectedLists.isEmpty
            ? viewModel.completedTasks
            : viewModel.completedTasks.filter { selectedLists.contains(normalizedHref($0.event.calendarHref)) }

        return List {
            if let message = viewModel.errorMessage {
                // Run 26.11. (Layout-Fix): dezente Fehlermeldung als
                // kompakte Zeile innerhalb der Liste - ohne feste Höhen-
                // angaben/Overlays, damit kein unbeschränkter Hintergrund
                // ("Blob") über die Liste wachsen kann.
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                if filteredOpen.isEmpty && filteredCompleted.isEmpty {
                    Text(NSLocalizedString("_tasks_empty_", value: "No tasks", comment: ""))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(filteredOpen) { item in
                    taskRow(item)
                }
            } header: {
                // Run 25.11. (Audit): dezenter Hinweis auf die aktive
                // Listen-Auswahl - ohne Feedback war nicht sichtbar, dass
                // der Filter überhaupt greift ("N Listen ausgewählt").
                VStack(alignment: .leading, spacing: 2) {
                    if !selectedLists.isEmpty {
                        Text(String(format: NSLocalizedString("_tasks_lists_selected_",
                                                              value: "%d lists selected",
                                                              comment: ""),
                                    selectedLists.count))
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                    Text(NSLocalizedString("_tasks_open_", value: "Open", comment: ""))
                }
            }

            if !filteredCompleted.isEmpty {
                Section {
                    if showCompleted {
                        ForEach(filteredCompleted) { item in
                            taskRow(item)
                        }
                    }
                } header: {
                    // Erledigte eingeklappt (secondary, aufklappbar).
                    Button {
                        withAnimation { showCompleted.toggle() }
                    } label: {
                        HStack {
                            Text(NSLocalizedString("_tasks_completed_", value: "Completed", comment: ""))
                            Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                                .font(.caption)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await viewModel.load()
        }
        .task {
            guard viewModel.openTasks.isEmpty, viewModel.completedTasks.isEmpty else { return }
            await viewModel.load()
        }
    }

    /// Zeile: Checkbox (Tap = Abhaken) + Titel; Tap auf die Zeile öffnet
    /// das Detail-Sheet.
    private func taskRow(_ item: SouveraTasksViewModel.TaskItem) -> some View {
        // Run 25.11.: Deck-/schreibgeschützte Listen - Checkbox gesperrt
        // (grau), Abhaken nur in schreibbaren Listen.
        let readOnly = viewModel.isReadOnlyList(href: item.event.calendarHref)
        return Button {
            selectedItem = item
        } label: {
            HStack(spacing: 12) {
                Button {
                    Task { await viewModel.toggle(item) }
                } label: {
                    Image(systemName: item.event.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(readOnly
                            ? Color.secondary.opacity(0.4)
                            : (item.event.isCompleted
                                ? Color.Souvera.brandPrimaryDeep
                                : Color.secondary))
                }
                .buttonStyle(.plain)
                .disabled(readOnly)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.event.title)
                        .font(.body)
                        .strikethrough(item.event.isCompleted)
                        .foregroundStyle(item.event.isCompleted ? Color.secondary : Color.primary)
                    Text(item.isUndated
                        ? NSLocalizedString("_calendar_task_no_due_", value: "No due date", comment: "")
                        : dueText(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func dueText(_ item: SouveraTasksViewModel.TaskItem) -> String {
        let df = DateFormatter()
        if item.event.allDay {
            df.setLocalizedDateFormatFromTemplate("EdMMM")
        } else {
            df.dateStyle = .medium
            df.timeStyle = .short
        }
        return df.string(from: item.event.start)
    }
}

// MARK: - Run 26.11. (Tasks, standalone): Neue Aufgabe anlegen

/// Run 26.11.: Sheet zur Neuanlage einer VTODO-Aufgabe. Titel (Pflicht),
/// Notizen, optionale Fälligkeit (date-only, Vacation-Pattern mit Toggle)
/// und Kalender-Auswahl über die canWrite && supportsTasks-Kalender;
/// bei nur einem Kalender entfaellt der Picker (Fallback: erster).
struct SouveraTaskNewSheet: View {
    @ObservedObject var viewModel: SouveraTasksViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var notes = ""
    @State private var hasDue = false
    /// Vorauswahl: übermorgen (startOfDay) - bewusst nicht "heute", damit
    /// eine schnell angelegte Aufgabe nicht sofort faellig wirkt.
    @State private var due = Calendar.current.startOfDay(for: Date()).addingTimeInterval(2 * 86400)
    @State private var calendarHref = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(NSLocalizedString("_tasks_summary_", value: "Title", comment: ""))) {
                    TextField(NSLocalizedString("_tasks_summary_", value: "Title", comment: ""), text: $title)
                }
                Section(header: Text(NSLocalizedString("_tasks_notes_", value: "Notes", comment: ""))) {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }
                // Fälligkeit: date-only und optional (Toggle wie im
                // Vacation-Pattern).
                Section(header: Text(NSLocalizedString("_tasks_due_", value: "Due date", comment: ""))) {
                    Toggle(NSLocalizedString("_tasks_due_", value: "Due date", comment: ""), isOn: $hasDue)
                    if hasDue {
                        DatePicker(NSLocalizedString("_tasks_due_", value: "Due date", comment: ""),
                                   selection: $due,
                                   displayedComponents: [.date])
                    }
                }
                // Run 25.11.: Kalender-Picker IMMER zeigen (auch bei nur
                // einer Liste) - der Nutzer soll die Zielliste sehen und
                // die Standard-Liste (Ablage beim Speichern) ableiten
                // können.
                Section(header: Text(NSLocalizedString("_calendar_tasks_", value: "Tasks", comment: ""))) {
                    Picker(NSLocalizedString("_calendar_tasks_", value: "Tasks", comment: ""),
                           selection: $calendarHref) {
                        ForEach(viewModel.writableTaskCalendars, id: \.href) { calendar in
                            Text(calendar.displayName).tag(calendar.href)
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("_tasks_new_", value: "New task", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Run 26.11. (Layout-Fix): Label bleibt stehen, der
                    // ProgressView (feste 20x20) stapelt sich daneben -
                    // kein Layout-Sprung beim Drücken.
                    Button {
                        save()
                    } label: {
                        HStack(spacing: 8) {
                            Text(NSLocalizedString("_tasks_save_", value: "Save", comment: ""))
                            ProgressView()
                                .frame(width: 20, height: 20)
                                .opacity(isSaving ? 1 : 0)
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                // Run 26.11.: Vorauswahl = Standard-Liste aus den
                // Einstellungen (souvera_tasks_default_setting_), sonst
                // Fallback: erster schreibbarer Task-Kalender. Die alte
                // "last used"-Ablage (defaultTaskListId) wird bewusst
                // NICHT mehr gelesen - die Settings-Option ist die Quelle.
                if calendarHref.isEmpty {
                    let saved = SouveraMailDisplaySettings.defaultTaskListSetting(
                        account: SouveraTasksViewModel.stableAccountKey())
                    if let match = viewModel.writableTaskCalendars.first(where: { $0.href == saved }) {
                        calendarHref = match.href
                    } else {
                        calendarHref = viewModel.writableTaskCalendars.first?.href ?? ""
                    }
                }
            }
        }
    }

    /// Speichern nur mit Titel und gültiger Kalender-Auswahl.
    private var canSave: Bool {
        !isSaving
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedCalendar != nil
    }

    private var selectedCalendar: CalDavCalendar? {
        if let explicit = viewModel.writableTaskCalendars.first(where: { $0.href == calendarHref }) {
            return explicit
        }
        // Fallback: erster schreibbarer Task-Kalender.
        return viewModel.writableTaskCalendars.first
    }

    private func save() {
        guard let calendar = selectedCalendar else { return }
        isSaving = true
        Task {
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = await viewModel.createTask(summary: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                               notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                                               due: due,
                                               hasDue: hasDue,
                                               calendar: calendar)
            isSaving = false
            if ok {
                // Run 26.11.: Die gewaehlte Liste wird NICHT als
                // Standard-Liste ueberschrieben - die Einstellungen
                // ("Standard-Liste") sind die alleinige Quelle; ein
                // einmaliges Abweichen im Sheet aendert den Default nicht.
                dismiss()
            }
        }
    }
}
