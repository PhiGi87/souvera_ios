// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 25.11. (Tasks, standalone): vereinfachtes Detail-Sheet für VTODO-
// Aufgaben - Titel, Fälligkeit, Notizen und Checkbox-Toggle (Abhaken via
// SouveraTasksViewModel.toggle, optimistisch + CalDAV-PUT). Basis: die
// Detail-View aus dem Revert-Commit 230e7585fd, entkoppelt vom
// CalendarViewModel (die Kalender-UI-Integration bleibt revertiert).
// Run 26.11. (Tasks, standalone): Bearbeitung - Titel (TextField),
// Notizen (TextEditor) und Fälligkeit (date-only, optional, Vacation-
// Pattern mit Toggle) sind editierbar; Speichern via
// SouveraTasksViewModel.saveEdit (ICS-Patch updateTodoFields + PUT mit
// If-Match, optimistische lokale Aktualisierung).

import SwiftUI

struct SouveraCalendarTaskDetailView: View {
    @ObservedObject var viewModel: SouveraTasksViewModel
    let item: SouveraTasksViewModel.TaskItem
    @Environment(\.dismiss) private var dismiss

    // Run 26.11.: Editierbare Felder - Vorbelegung in onAppear aus dem
    // geparsten Model. Notizen sind im Model noch RFC-5545-maskiert,
    // daher unescapeTodoText (die Rueckschreibung maskiert erneut).
    @State private var title = ""
    @State private var notes = ""
    @State private var hasDue = false
    @State private var due = Date()
    @State private var isSaving = false
    @State private var didPrefill = false

    /// Run 25.11.: Deck-Listen (Board-Karten als VTODO) und Listen ohne
    /// Schreibrecht sind read-only - Checkbox und Bearbeitung gesperrt,
    /// Hinweis-Footer unten. Quelle: taskLists des ViewModels (canWrite /
    /// Deck-Kategorie aus dem PROPFIND).
    private var isReadOnly: Bool {
        viewModel.isReadOnlyList(href: item.event.calendarHref)
    }

    // Run 25.11.: Listenwechsel - die aktuelle Liste wird angezeigt (auch
    // bei read-only), bei editierbaren Aufgaben kann sie über einen Picker
    // (writableTaskCalendars) geändert werden; beim Speichern wird der
    // Move via viewModel.moveTask ausgeführt.
    @State private var selectedListHref = ""

    /// Aktuelle Liste (Farbpunkt + Name) aus dem PROPFIND-Bestand.
    private var currentList: CalDavCalendar? {
        viewModel.taskLists.first(where: { $0.href == item.event.calendarHref })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Checkbox-Toggle (NC-Konvention: STATUS:COMPLETED +
                    // COMPLETED:UTC + PERCENT-COMPLETE:100). Run 25.11.:
                    // Bei read-only Listen nicht antippbar (grau).
                    Button {
                        Task { await viewModel.toggle(item) }
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.event.isCompleted ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(isReadOnly
                                    ? Color.secondary.opacity(0.4)
                                    : (item.event.isCompleted
                                        ? Color.Souvera.brandPrimaryDeep
                                        : Color.secondary))
                                Text(item.event.isCompleted
                                    ? NSLocalizedString("_calendar_task_mark_open_", value: "Mark as open", comment: "")
                                    : NSLocalizedString("_calendar_task_mark_done_", value: "Mark as done", comment: ""))
                                    .font(.body)
                                    .foregroundStyle(isReadOnly ? Color.secondary : Color.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isReadOnly)
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        // Run 26.11.: Titel editierbar.
                        TextField(NSLocalizedString("_tasks_summary_", value: "Title", comment: ""),
                                  text: $title)
                            .font(.title3).fontWeight(.semibold)
                            .strikethrough(item.event.isCompleted)
                            .foregroundStyle(item.event.isCompleted ? Color.secondary : Color.primary)
                        if hasDue {
                            // Run 26.11.: Fälligkeit date-only und optional
                            // (Toggle wie im Vacation-Pattern).
                            DatePicker(NSLocalizedString("_tasks_due_", value: "Due date", comment: ""),
                                       selection: $due,
                                       displayedComponents: [.date])
                                .font(.subheadline)
                        } else {
                            Text(NSLocalizedString("_calendar_task_no_due_", value: "No due date", comment: ""))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(NSLocalizedString("_tasks_notes_", value: "Notes", comment: ""))
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        // Run 26.11.: Notizen editierbar.
                        TextEditor(text: $notes)
                            .font(.body)
                            .frame(minHeight: 100)
                            .scrollContentBackground(.hidden)
                    }

                    // Run 25.11.: Liste anzeigen/ändern - Farbpunkt +
                    // Name aus dem PROPFIND; editierbar via Picker über
                    // writableTaskCalendars, read-only nur Anzeige.
                    VStack(alignment: .leading, spacing: 6) {
                        if !isReadOnly {
                            Picker(NSLocalizedString("_tasks_section_list_",
                                                     value: "List",
                                                     comment: ""),
                                   selection: $selectedListHref) {
                                ForEach(viewModel.writableTaskCalendars, id: \.href) { calendar in
                                    Text(calendar.displayName).tag(calendar.href)
                                }
                            }
                        } else {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color(hex: currentList?.color ?? "") ?? Color(NCBrandColor.shared.customer))
                                    .frame(width: 10, height: 10)
                                Text(listLabel(currentList))
                                    .font(.body)
                            }
                        }
                    }

                    // Run 26.11.: Fälligkeit an/aus (Vacation-Pattern).
                    // Run 25.11.: Bei read-only Listen aus (nur Anzeige).
                    if !isReadOnly {
                        Toggle(NSLocalizedString("_tasks_due_", value: "Due date", comment: ""), isOn: $hasDue)
                            .font(.body)
                    }

                    // Run 25.11.: Hinweis-Footer für read-only Listen
                    // (Deck / ohne Schreibrecht).
                    if isReadOnly {
                        Label(NSLocalizedString("_tasks_readonly_",
                                                value: "Read-only list",
                                                comment: ""),
                              systemImage: "lock")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(NSLocalizedString("_calendar_tasks_", value: "Tasks", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                // Run 26.11.: Speichern - ICS patchen (updateTodoFields)
                // und per PUT mit If-Match zurueckschreiben.
                ToolbarItem(placement: .topBarTrailing) {
                    // Run 26.11. (Feedback "komische optische Änderungen"):
                    // Das Label wechselte beim Drücken zwischen Text und
                    // ProgressView (Größensprung in der Toolbar). Jetzt
                    // bleibt das Label stehen und der ProgressView mit
                    // fester 20x20-Größe erscheint daneben (opacity-
                    // gesteuert, kein Layout-Umbau).
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
                    .disabled(!canSave || isReadOnly)
                }
            }
            .onAppear { prefill() }
        }
    }

    /// Speichern nur mit Titel (Pflichtfeld) und nicht laufendem PUT.
    private var canSave: Bool {
        !isSaving
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Run 25.11.: Listenname - aus dem PROPFIND-Bestand, mit Fallback
    /// auf den href-Pfad, wenn die Liste (noch) nicht bekannt ist.
    private func listLabel(_ calendar: CalDavCalendar?) -> String {
        calendar?.displayName
            ?? NSLocalizedString("_tasks_section_list_", value: "List", comment: "")
    }

    /// Run 26.11.: Felder aus dem Eintrag vorbelegen. Undatierte Tasks
    /// (Parser-Anker: Tagesanfang heute) starten ohne Fälligkeit.
    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        title = item.event.title
        notes = ICSParser.unescapeTodoText(item.event.description ?? "")
        selectedListHref = item.event.calendarHref
        if item.isUndated {
            hasDue = false
        } else {
            hasDue = true
            due = item.event.start
        }
    }

    private func save() {
        // Run 26.11. (Feedback "Speichern geht nicht"): Start-Diagnose -
        // Closure-Kette DetailView -> saveEdit -> PUT nachvollziehbar
        // machen (Titel leer => Button disabled, hier gar kein Aufruf).
        SouveraLog.write("Tasks", "DetailView.save: '\(title.trimmingCharacters(in: .whitespacesAndNewlines))' hasDue=\(hasDue), disabled=\(!canSave)")
        // Run 25.11.: gewählte Zielliste für den Move (nil = unverändert).
        let targetList = viewModel.writableTaskCalendars.first(where: { $0.href == selectedListHref })
        isSaving = true
        Task {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = await viewModel.saveEdit(item,
                                              summary: trimmed,
                                              notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                                              due: due,
                                              hasDue: hasDue)
            // Run 25.11.: Listenwechsel nach dem Feld-Save ausführen -
            // saveEdit hat die ICS/ETags im Cache aktualisiert, moveTask
            // liest von dort (gleicher href-Schlüssel).
            var moved = true
            if ok, let target = targetList, target.href != item.event.calendarHref {
                moved = await viewModel.moveTask(item, to: target)
            }
            isSaving = false
            SouveraLog.write("Tasks", "DetailView.save: Ergebnis \(ok ? "ok" : "fehlgeschlagen")\(ok ? ", move \(moved ? "ok" : "fehlgeschlagen")" : "")")
            if ok, moved { dismiss() }
        }
    }
}
