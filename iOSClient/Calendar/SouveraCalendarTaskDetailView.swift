// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 24.11. (Tasks): vereinfachtes Detail-Sheet für VTODO-Aufgaben -
// Titel, Fälligkeit, Notizen und Checkbox-Toggle (Abhaken via
// CalendarViewModel.toggleTask, optimistisch + CalDAV-PUT).

import SwiftUI

struct SouveraCalendarTaskDetailView: View {
    @ObservedObject var viewModel: CalendarViewModel
    let event: CalendarEventModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Checkbox-Toggle (NC-Konvention: STATUS:COMPLETED +
                    // COMPLETED:UTC + PERCENT-COMPLETE:100).
                    Button {
                        Task { await viewModel.toggleTask(event) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: event.isCompleted ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(event.isCompleted
                                    ? Color.Souvera.brandPrimaryDeep
                                    : Color.secondary)
                            Text(event.isCompleted
                                ? NSLocalizedString("_calendar_task_mark_open_", comment: "")
                                : NSLocalizedString("_calendar_task_mark_done_", comment: ""))
                                .font(.body)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.title)
                            .font(.title3).fontWeight(.semibold)
                            .strikethrough(event.isCompleted)
                            .foregroundStyle(event.isCompleted ? Color.secondary : Color.primary)
                        Text(dueLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let notes = event.description, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(NSLocalizedString("_calendar_notes_", comment: ""))
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
            .navigationTitle(NSLocalizedString("_calendar_tasks_", comment: ""))
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
        if calendar.isDate(event.start, equalTo: calendar.startOfDay(for: Date()), toGranularity: .day),
           event.start == calendar.startOfDay(for: Date()),
           event.end.timeIntervalSince(event.start) <= 900 {
            // Undatierte Tasks (Parser-Anker: Tagesanfang heute) - kein
            // echtes Fälligkeitsdatum vorhanden.
            return NSLocalizedString("_calendar_task_no_due_", comment: "")
        }
        let df = DateFormatter()
        if event.allDay {
            df.setLocalizedDateFormatFromTemplate("EdMMM")
            return NSLocalizedString("_calendar_task_due_", comment: "") + " " + df.string(from: event.start)
        }
        df.dateStyle = .medium
        df.timeStyle = .short
        return NSLocalizedString("_calendar_task_due_", comment: "") + " " + df.string(from: event.start)
    }
}
