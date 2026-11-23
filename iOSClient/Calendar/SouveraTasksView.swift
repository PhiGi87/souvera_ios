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

    private let client = CalDavClient()
    /// Roh-Einträge nach href - Basis für die Toggle-PUTs (If-Match).
    private var entriesByHref: [String: CalDavEventEntry] = [:]

    /// Lädt alle Tasks aus allen Task-Kalendern neu (Pull-to-refresh und
    /// Refresh-Button).
    func load() async {
        isLoading = true
        defer { isLoading = false }
        let calendars = await client.fetchCalendars().filter { $0.supportsTasks }
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
        .toolbar {
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
