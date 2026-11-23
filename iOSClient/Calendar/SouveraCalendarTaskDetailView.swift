// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 25.11. (Tasks, standalone): vereinfachtes Detail-Sheet für VTODO-
// Aufgaben - Titel, Fälligkeit, Notizen und Checkbox-Toggle (Abhaken via
// SouveraTasksViewModel.toggle, optimistisch + CalDAV-PUT). Basis: die
// Detail-View aus dem Revert-Commit 230e7585fd, entkoppelt vom
// CalendarViewModel (die Kalender-UI-Integration bleibt revertiert).

import SwiftUI

struct SouveraCalendarTaskDetailView: View {
    @ObservedObject var viewModel: SouveraTasksViewModel
    let item: SouveraTasksViewModel.TaskItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Checkbox-Toggle (NC-Konvention: STATUS:COMPLETED +
                    // COMPLETED:UTC + PERCENT-COMPLETE:100).
                    Button {
                        Task { await viewModel.toggle(item) }
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.event.isCompleted ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(item.event.isCompleted
                                    ? Color.Souvera.brandPrimaryDeep
                                    : Color.secondary)
                            Text(item.event.isCompleted
                                ? NSLocalizedString("_calendar_task_mark_open_", value: "Mark as open", comment: "")
                                : NSLocalizedString("_calendar_task_mark_done_", value: "Mark as done", comment: ""))
                                .font(.body)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.event.title)
                            .font(.title3).fontWeight(.semibold)
                            .strikethrough(item.event.isCompleted)
                            .foregroundStyle(item.event.isCompleted ? Color.secondary : Color.primary)
                        Text(dueLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let notes = item.event.description, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(NSLocalizedString("_calendar_notes_", value: "Notes", comment: ""))
                                .font(.caption).fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            Text(notes)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(NSLocalizedString("_calendar_tasks_", value: "Tasks", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }

    /// Fälligkeit formatiert (Ganztag = nur Datum, sonst Datum + Uhrzeit);
    /// undatierte Tasks zeigen "ohne Fälligkeit".
    private var dueLabel: String {
        let calendar = Calendar.current
        if item.isUndated {
            // Undatierte Tasks (Parser-Anker: Tagesanfang heute) - kein
            // echtes Fälligkeitsdatum vorhanden.
            return NSLocalizedString("_calendar_task_no_due_", value: "No due date", comment: "")
        }
        let df = DateFormatter()
        if item.event.allDay {
            df.setLocalizedDateFormatFromTemplate("EdMMM")
            return NSLocalizedString("_calendar_task_due_", value: "Due:", comment: "") + " " + df.string(from: item.event.start)
        }
        df.dateStyle = .medium
        df.timeStyle = .short
        return NSLocalizedString("_calendar_task_due_", value: "Due:", comment: "") + " " + df.string(from: item.event.start)
    }
}
