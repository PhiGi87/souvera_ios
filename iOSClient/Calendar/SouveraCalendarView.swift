// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Souvera calendar: CalDAV-backed month grid with a day event list, event
// detail and create/edit sheets. Mirrors the look of the Android calendar
// module (month selector + day list).

import SwiftUI

struct SouveraCalendarView: View {
    @StateObject private var viewModel = CalendarViewModel()
    @State private var selectedDay = Date()
    @State private var detailEvent: CalendarEventModel?
    @State private var editState: EditSheetState?

    struct EditSheetState: Identifiable {
        let draft: EventDraft
        let existing: CalendarEventModel?
        var id: String { existing?.id ?? "new" }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                monthSwitcher
                monthGrid
                Divider()
                dayEventList
            }
            .navigationTitle(NSLocalizedString("_calendar_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editState = EditSheetState(draft: EventDraft(start: selectedDay, end: selectedDay.addingTimeInterval(3600)), existing: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .onAppear {
            selectedDay = Date()
            Task { await viewModel.load() }
        }
        .sheet(item: $detailEvent) { event in
            CalendarEventDetailSheet(viewModel: viewModel, event: event) { draft in
                editState = EditSheetState(draft: draft, existing: event)
            }
        }
        .sheet(item: $editState) { state in
            CalendarEventEditSheet(viewModel: viewModel, draft: state.draft, existing: state.existing)
        }
    }

    private var monthSwitcher: some View {
        HStack {
            Button {
                viewModel.shiftMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Text(viewModel.monthTitle).font(.headline)
            Spacer()
            Button {
                viewModel.shiftMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var weekdaySymbols: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var monthGrid: some View {
        let days = viewModel.monthDays
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
            ForEach(weekdaySymbols, id: \.self) { label in
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(days, id: \.self) { day in
                dayCell(day)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        let calendar = Calendar.current
        let inMonth = calendar.isDate(day, equalTo: viewModel.visibleMonth, toGranularity: .month)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(day)
        Button {
            selectedDay = day
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline)
                    .fontWeight(isToday ? .bold : .regular)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle()
                            .fill(isSelected ? Color(NCBrandColor.shared.customer) : .clear)
                    )
                    .foregroundStyle(isSelected ? Color.white : (inMonth ? (isToday ? Color(NCBrandColor.shared.customer) : Color.primary) : Color.secondary))
                Circle()
                    .fill(viewModel.hasEvents(on: day) ? Color(NCBrandColor.shared.customer) : .clear)
                    .frame(width: 5, height: 5)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var dayEventList: some View {
        VStack(spacing: 0) {
            if let notice = viewModel.offlineNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            Text(selectedDay, style: .date).font(.subheadline).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.top, 6)
            let dayEvents = viewModel.events(on: selectedDay)
            if dayEvents.isEmpty {
                Spacer()
                Text(NSLocalizedString("_calendar_no_events_", comment: "")).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(dayEvents) { event in
                    Button {
                        detailEvent = event
                    } label: {
                        CalendarEventRow(event: event)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .refreshable { await viewModel.load() }
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEventModel

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(NCBrandColor.shared.customer))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.subheadline).fontWeight(.medium).lineLimit(1)
                Text(timeLabel).font(.caption).foregroundStyle(.secondary)
                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var timeLabel: String {
        if event.allDay {
            return NSLocalizedString("_calendar_all_day_", comment: "")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: event.start)) – \(formatter.string(from: event.end))"
    }
}

/// Detail view of one event with edit and delete actions.
private struct CalendarEventDetailSheet: View {
    @ObservedObject var viewModel: CalendarViewModel
    let event: CalendarEventModel
    let onEdit: (EventDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(event.title).font(.title3).fontWeight(.semibold)
                }
                Section {
                    Label(dateLabel, systemImage: "clock")
                    if let location = event.location, !location.isEmpty {
                        Label(location, systemImage: "mappin")
                    }
                }
                if let notes = event.description, !notes.isEmpty {
                    Section(NSLocalizedString("_calendar_notes_", comment: "")) {
                        Text(notes).textSelection(.enabled)
                    }
                }
                Section {
                    Button {
                        var draft = EventDraft()
                        draft.uid = event.uid
                        draft.title = event.title
                        draft.start = event.start
                        draft.end = event.end
                        draft.allDay = event.allDay
                        draft.location = event.location ?? ""
                        draft.notes = event.description ?? ""
                        onEdit(draft)
                        dismiss()
                    } label: {
                        Label(NSLocalizedString("_contact_edit_", comment: ""), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        Task { _ = await viewModel.deleteEvent(event) }
                        dismiss()
                    } label: {
                        Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash")
                    }
                }
            }
            .navigationTitle(NSLocalizedString("_calendar_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
            }
        }
    }

    private var dateLabel: String {
        let formatter = DateFormatter()
        if event.allDay {
            formatter.dateStyle = .long
            formatter.timeStyle = .none
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }
        return formatter.string(from: event.start)
    }
}

/// Create/edit form for one event.
private struct CalendarEventEditSheet: View {
    @ObservedObject var viewModel: CalendarViewModel
    @State var draft: EventDraft
    let existing: CalendarEventModel?
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("_calendar_title_", comment: ""), text: $draft.title)
                    Toggle(NSLocalizedString("_calendar_all_day_", comment: ""), isOn: $draft.allDay)
                }
                Section {
                    DatePicker(NSLocalizedString("_calendar_start_", comment: ""), selection: $draft.start, displayedComponents: draft.allDay ? .date : [.date, .hourAndMinute])
                    DatePicker(NSLocalizedString("_calendar_end_", comment: ""), selection: $draft.end, displayedComponents: draft.allDay ? .date : [.date, .hourAndMinute])
                }
                Section {
                    TextField(NSLocalizedString("_calendar_location_", comment: ""), text: $draft.location)
                }
                Section(NSLocalizedString("_calendar_notes_", comment: "")) {
                    TextField(NSLocalizedString("_calendar_notes_", comment: ""), text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle(existing == nil
                             ? NSLocalizedString("_calendar_new_event_", comment: "")
                             : NSLocalizedString("_contact_edit_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(NSLocalizedString("_contact_save_", comment: "")) {
                            saving = true
                            Task {
                                let ok = await viewModel.saveEvent(draft, existing: existing)
                                if ok {
                                    dismiss()
                                } else {
                                    saving = false
                                    errorMessage = NSLocalizedString("_calendar_save_error_", comment: "")
                                }
                            }
                        }
                        .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }
}
