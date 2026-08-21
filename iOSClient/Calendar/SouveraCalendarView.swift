// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Souvera calendar: CalDAV-backed month grid, day and 3-day views (Apple
// Calendar style toggle), event search, event detail and create/edit with
// attendees and an optional Talk channel per event.

import SwiftUI

struct SouveraCalendarView: View {
    @StateObject private var viewModel = CalendarViewModel()
    @State private var selectedDay = Date()
    @State private var viewMode: CalendarViewMode = .month
    @State private var searchQuery = ""
    @State private var detailEvent: CalendarEventModel?
    @State private var editState: EditSheetState?

    enum CalendarViewMode: String, CaseIterable, Identifiable {
        case day, threeDay, month
        var id: String { rawValue }

        var title: String {
            switch self {
            case .day: return NSLocalizedString("_calendar_day_", comment: "")
            case .threeDay: return NSLocalizedString("_calendar_three_day_", comment: "")
            case .month: return NSLocalizedString("_calendar_month_", comment: "")
            }
        }
    }

    struct EditSheetState: Identifiable {
        let draft: EventDraft
        let existing: CalendarEventModel?
        var id: String { existing?.id ?? "new" }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $viewMode) {
                    ForEach(CalendarViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

                if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    content
                } else {
                    searchResults
                }
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
        .searchable(text: $searchQuery, prompt: Text(NSLocalizedString("_mail_search_", comment: "")))
        .sheet(item: $detailEvent) { event in
            CalendarEventDetailSheet(viewModel: viewModel, event: event) { draft in
                editState = EditSheetState(draft: draft, existing: event)
            }
        }
        .sheet(item: $editState) { state in
            CalendarEventEditSheet(viewModel: viewModel, draft: state.draft, existing: state.existing)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewMode {
        case .month:
            monthView
        case .day:
            dayView
        case .threeDay:
            threeDayView
        }
    }

    // MARK: - Month

    private var monthView: some View {
        VStack(spacing: 0) {
            monthSwitcher
            monthGrid
            Divider()
            dayEventList
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
            viewModel.ensureMonth(contains: day)
            withAnimation { viewMode = .day }
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

    // MARK: - Day

    private var dayView: some View {
        VStack(spacing: 0) {
            daySwitcher(day: selectedDay)
            Divider()
            eventsOfDay(selectedDay, showAllDay: true)
        }
    }

    private func daySwitcher(day: Date) -> some View {
        HStack {
            Button {
                shiftSelectedDay(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            VStack(spacing: 1) {
                Text(day, style: .date).font(.headline)
                Text(day.formatted(.dateTime.weekday(.wide))).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                shiftSelectedDay(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func shiftSelectedDay(by days: Int) {
        let calendar = Calendar.current
        if let shifted = calendar.date(byAdding: .day, value: days, to: selectedDay) {
            selectedDay = shifted
            viewModel.ensureMonth(contains: shifted)
        }
    }

    // MARK: - 3 days

    private var threeDayView: some View {
        VStack(spacing: 0) {
            daySwitcher(day: selectedDay)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ForEach(threeDayRange, id: \.self) { day in
                    VStack(spacing: 0) {
                        eventsOfDay(day, showAllDay: false, compact: true)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var threeDayRange: [Date] {
        let calendar = Calendar.current
        guard let previous = calendar.date(byAdding: .day, value: -1, to: selectedDay),
              let next = calendar.date(byAdding: .day, value: 1, to: selectedDay) else { return [selectedDay] }
        return [previous, selectedDay, next]
    }

    // MARK: - Event lists

    @ViewBuilder
    private func eventsOfDay(_ day: Date, showAllDay: Bool, compact: Bool = false) -> some View {
        let dayEvents = viewModel.events(on: day)
        VStack(spacing: 0) {
            if let notice = viewModel.offlineNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            if !compact {
                Text(day, style: .date)
                    .font(.subheadline).fontWeight(.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 6)
            } else {
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 6)
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if dayEvents.isEmpty {
                Spacer()
                Text(NSLocalizedString("_calendar_no_events_", comment: "")).foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    if showAllDay {
                        ForEach(dayEvents.filter { $0.allDay }) { event in
                            eventRow(event)
                        }
                        if dayEvents.contains(where: { $0.allDay }) {
                            Divider()
                        }
                    }
                    ForEach(dayEvents.filter { !$0.allDay }) { event in
                        eventRow(event)
                    }
                }
                .listStyle(.plain)
            }
        }
        .refreshable { await viewModel.load() }
    }

    @ViewBuilder
    private func eventRow(_ event: CalendarEventModel) -> some View {
        Button {
            detailEvent = event
        } label: {
            CalendarEventRow(event: event)
        }
        .buttonStyle(.plain)
    }

    private var dayEventList: some View {
        VStack(spacing: 0) {
            Text(selectedDay, style: .date)
                .font(.subheadline).fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 6)
            let dayEvents = viewModel.events(on: selectedDay)
            if dayEvents.isEmpty {
                Spacer()
                Text(NSLocalizedString("_calendar_no_events_", comment: "")).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(dayEvents) { event in
                    eventRow(event)
                }
                .listStyle(.plain)
            }
        }
        .refreshable { await viewModel.load() }
    }

    // MARK: - Search

    @ViewBuilder
    private var searchResults: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        let results = matchingEvents(query)
        VStack(spacing: 0) {
            if results.isEmpty {
                Spacer()
                Text(NSLocalizedString("_mail_search_no_results_", comment: "")).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(results) { event in
                    eventRow(event)
                }
                .listStyle(.plain)
            }
        }
    }

    private func matchingEvents(_ query: String) -> [CalendarEventModel] {
        guard case let .success(all) = viewModel.events else { return [] }
        guard !query.isEmpty else { return [] }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.location ?? "").localizedCaseInsensitiveContains(query)
                || ($0.description ?? "").localizedCaseInsensitiveContains(query)
        }.sorted { $0.start < $1.start }
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
                if event.talkRoomToken != nil {
                    Label(NSLocalizedString("_calendar_talk_channel_", comment: ""), systemImage: "bubble.left.and.bubble.right")
                        .font(.caption).foregroundStyle(Color(NCBrandColor.shared.customer))
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

/// Detail view of one event with edit, delete and Talk-channel actions.
private struct CalendarEventDetailSheet: View {
    @ObservedObject var viewModel: CalendarViewModel
    let event: CalendarEventModel
    let onEdit: (EventDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var creatingRoom = false

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
                if !event.attendees.isEmpty {
                    Section(NSLocalizedString("_calendar_attendees_", comment: "")) {
                        ForEach(event.attendees, id: \.self) { attendee in
                            Text(attendee)
                        }
                    }
                }
                if let notes = event.description, !notes.isEmpty {
                    Section(NSLocalizedString("_calendar_notes_", comment: "")) {
                        Text(notes).textSelection(.enabled)
                    }
                }
                Section(NSLocalizedString("_calendar_talk_channel_", comment: "")) {
                    if let roomName = event.talkRoomName {
                        HStack {
                            Label(roomName, systemImage: "bubble.left.and.bubble.right")
                            Spacer()
                            Button(NSLocalizedString("_calendar_open_talk_", comment: "")) {
                                viewModel.openTalkRoom(for: event)
                                dismiss()
                            }
                        }
                    } else if creatingRoom {
                        HStack {
                            ProgressView()
                            Text(NSLocalizedString("_calendar_create_talk_", comment: "")).foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            creatingRoom = true
                            Task {
                                _ = await viewModel.createTalkRoom(for: event)
                                dismiss()
                            }
                        } label: {
                            Label(NSLocalizedString("_calendar_create_talk_", comment: ""), systemImage: "plus.bubble")
                        }
                    }
                }
                Section {
                    Button {
                        onEdit(viewModel.draft(from: event))
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

/// Create/edit form for one event, including attendees.
private struct CalendarEventEditSheet: View {
    @ObservedObject var viewModel: CalendarViewModel
    @State var draft: EventDraft
    let existing: CalendarEventModel?
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var attendeeInput = ""
    @State private var attendeeSuggestions: [RecipientSuggestion] = []
    @State private var suggestionTask: Task<Void, Never>?
    @State private var showContactPicker = false

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
                Section(NSLocalizedString("_calendar_attendees_", comment: "")) {
                    ForEach(draft.attendees, id: \.self) { attendee in
                        HStack {
                            Text(attendee).font(.subheadline)
                            Spacer()
                            Button {
                                draft.attendees.removeAll { $0 == attendee }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        TextField(NSLocalizedString("_calendar_add_attendee_", comment: ""), text: $attendeeInput)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .onChange(of: attendeeInput) { _, newValue in
                                suggestionTask?.cancel()
                                suggestionTask = Task {
                                    try? await Task.sleep(nanoseconds: 150_000_000)
                                    guard !Task.isCancelled else { return }
                                    let found = await ContactSuggestionSource().search(newValue)
                                    if !Task.isCancelled {
                                        attendeeSuggestions = found.filter { !draft.attendees.contains($0.email) }
                                    }
                                }
                            }
                        Button {
                            showContactPicker = true
                        } label: {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .foregroundStyle(Color(NCBrandColor.shared.customer))
                        }
                    }
                    ForEach(attendeeSuggestions) { suggestion in
                        Button {
                            addAttendee(suggestion.email)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.displayName ?? suggestion.email).font(.subheadline)
                                if suggestion.displayName != nil {
                                    Text(suggestion.email).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
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
            .sheet(isPresented: $showContactPicker) {
                ContactPickerSheet { email in
                    addAttendee(email)
                }
            }
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

    private func addAttendee(_ email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.contains("@"), !draft.attendees.contains(trimmed) else { return }
        draft.attendees.append(trimmed)
        attendeeInput = ""
        attendeeSuggestions = []
    }
}
