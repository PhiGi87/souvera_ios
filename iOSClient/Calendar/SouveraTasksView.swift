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

    private let client = CalDavClient()
    /// Roh-Einträge nach href - Basis für die Toggle-PUTs (If-Match).
    private var entriesByHref: [String: CalDavEventEntry] = [:]

    /// Lädt alle Tasks aus allen Task-Kalendern neu (Pull-to-refresh und
    /// Refresh-Button).
    func load() async {
        isLoading = true
        defer { isLoading = false }
        let calendars = await client.fetchCalendars().filter { $0.supportsTasks }
        // Run 26.11.: Schreibbare Task-Kalender parallel mithalten (Picker
        // im Neuanlage-Sheet; Fallback dort: erster Eintrag).
        writableTaskCalendars = calendars.filter { $0.canWrite }
        guard !calendars.isEmpty else {
            apply([], [])
            return
        }
        // Run 25.11.: Task-Kalender parallel abfragen (Muster TaskGroup,
        // wie im revertierten CalendarViewModel-TaskGroup-Zweig).
        let results = await withTaskGroup(of: [CalDavEventEntry].self) { group in
            for calendar in calendars {
                group.addTask { [client] in
                    await client.fetchTodos(calendarHref: calendar.href)
                }
            }
            var all: [CalDavEventEntry] = []
            for await entries in group {
                all.append(contentsOf: entries)
            }
            return all
        }
        // Dedup nach href (ein Kalender kann theoretisch doppelt
        // auftauchen, z. B. bei mehreren Principal-Kandidaten).
        var byHref: [String: CalDavEventEntry] = [:]
        for entry in results where !entry.href.isEmpty {
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
        let wasCompleted = item.event.isCompleted
        let targetItem = flip(item)
        mutate(item: item, with: targetItem)
        errorMessage = nil

        // ICS auf dem aktuellen Stand umschreiben - bei einem veralteten
        // ETag (412) einmalig frisch laden und erneut versuchen (Muster
        // scheduleEventSync aus dem Kalender-Modul).
        var entry = targetItem.entry
        var newICS = wasCompleted
            ? ICSParser.uncompleteTodo(entry.ics)
            : ICSParser.completeTodo(entry.ics)
        var result = await client.performEventUpdate(entry, ics: newICS)
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
            }
        }
        guard result.ok else {
            // Rollback der optimistischen Änderung.
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

        // ICS patchen und PUT mit dem ETag des Eintrags versuchen - bei
        // Stale-ETag frisch nachladen und erneut versuchen.
        var entry = item.entry
        var newICS = ICSParser.updateTodoFields(entry.ics,
                                                summary: summary,
                                                notes: notes,
                                                due: due,
                                                hasDue: hasDue)
        var result = await client.performEventUpdate(entry, ics: newICS)
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
        }
        guard result.ok else {
            // Kein Rollback noetig - die UI wurde noch nicht gedreht.
            errorMessage = NSLocalizedString("_tasks_error_", value: "Tasks could not be updated.", comment: "")
            return false
        }

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

    var body: some View {
        List {
            if let message = viewModel.errorMessage {
                // Dezente Fehlermeldung statt Alert.
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if viewModel.openTasks.isEmpty && viewModel.completedTasks.isEmpty {
                    Text(NSLocalizedString("_tasks_empty_", value: "No tasks", comment: ""))
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.openTasks) { item in
                    taskRow(item)
                }
            } header: {
                Text(NSLocalizedString("_tasks_open_", value: "Open", comment: ""))
            }

            if !viewModel.completedTasks.isEmpty {
                Section {
                    if showCompleted {
                        ForEach(viewModel.completedTasks) { item in
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
        .sheet(item: $selectedItem) { item in
            SouveraCalendarTaskDetailView(viewModel: viewModel, item: item)
        }
        // Run 26.11.: Neuanlage-Sheet über Toolbar "+".
        .sheet(isPresented: $showNewTaskSheet) {
            SouveraTaskNewSheet(viewModel: viewModel)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNewTaskSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text(NSLocalizedString("_tasks_new_", value: "New task", comment: "")))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.load() }
                } label: {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    /// Zeile: Checkbox (Tap = Abhaken) + Titel; Tap auf die Zeile öffnet
    /// das Detail-Sheet.
    private func taskRow(_ item: SouveraTasksViewModel.TaskItem) -> some View {
        Button {
            selectedItem = item
        } label: {
            HStack(spacing: 12) {
                Button {
                    Task { await viewModel.toggle(item) }
                } label: {
                    Image(systemName: item.event.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(item.event.isCompleted
                            ? Color.Souvera.brandPrimaryDeep
                            : Color.secondary)
                }
                .buttonStyle(.plain)

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
                if viewModel.writableTaskCalendars.count > 1 {
                    Section(header: Text(NSLocalizedString("_calendar_tasks_", value: "Tasks", comment: ""))) {
                        Picker(NSLocalizedString("_calendar_tasks_", value: "Tasks", comment: ""),
                               selection: $calendarHref) {
                            ForEach(viewModel.writableTaskCalendars, id: \.href) { calendar in
                                Text(calendar.displayName).tag(calendar.href)
                            }
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
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(NSLocalizedString("_tasks_save_", value: "Save", comment: ""))
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                // Fallback: erster schreibbarer Task-Kalender; der Picker
                // erscheint nur bei mehreren Kalendern.
                if calendarHref.isEmpty {
                    calendarHref = viewModel.writableTaskCalendars.first?.href ?? ""
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
            if ok { dismiss() }
        }
    }
}
