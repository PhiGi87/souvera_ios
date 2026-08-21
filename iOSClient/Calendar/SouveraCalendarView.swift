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
            // First tap selects the day (the events appear in the list
            // below); a second tap on the same day opens the day view.
            if viewMode == .month, calendar.isDate(day, inSameDayAs: selectedDay) {
                withAnimation { viewMode = .day }
            } else {
                selectedDay = day
                viewModel.ensureMonth(contains: day)
            }
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
            TimelineDayView(
                day: selectedDay,
                events: viewModel.events(on: selectedDay),
                showHourLabels: true,
                hourHeight: 56,
                onSelect: { detailEvent = $0 }
            )
            .refreshable { await viewModel.load() }
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
            ThreeDayTimelineView(
                days: threeDayRange,
                eventsProvider: { viewModel.events(on: $0) },
                onSelect: { detailEvent = $0 }
            )
        }
    }

    private var threeDayRange: [Date] {
        let calendar = Calendar.current
        guard let previous = calendar.date(byAdding: .day, value: -1, to: selectedDay),
              let next = calendar.date(byAdding: .day, value: 1, to: selectedDay) else { return [selectedDay] }
        return [previous, selectedDay, next]
    }

    // MARK: - Event rows

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

/// Hour-scale timeline for one day (Apple Calendar style): an all-day row
/// on top, an hour column on the left and events positioned by their time.
private struct TimelineDayView: View {
    let day: Date
    let events: [CalendarEventModel]
    let showHourLabels: Bool
    let hourHeight: CGFloat
    var compactHeader: Bool = false
    let onSelect: (CalendarEventModel) -> Void

    private let hours = Array(0..<24)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    allDaySection
                    HStack(alignment: .top, spacing: 0) {
                        hourScale
                        TimelineColumn(day: day, events: events, hourHeight: hourHeight, onSelect: onSelect)
                    }
                }
                .padding(.bottom, 40)
            }
            .onAppear {
                let currentHour = Calendar.current.component(.hour, from: Date())
                if Calendar.current.isDateInToday(day) {
                    proxy.scrollTo("hour_\(currentHour)", anchor: .top)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 1) {
            if compactHeader {
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(.headline)
            } else {
                Text(day.formatted(.dateTime.weekday(.wide)))
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var allDaySection: some View {
        let allDayEvents = events.filter { $0.allDay }
        if !allDayEvents.isEmpty {
            VStack(spacing: 4) {
                ForEach(allDayEvents) { event in
                    Button {
                        onSelect(event)
                    } label: {
                        Text(event.title)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color(NCBrandColor.shared.customer).opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                }
            }
            .padding(.bottom, 4)
        }
    }

    private var hourScale: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(hours, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(showHourLabels ? .caption2 : .system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: showHourLabels ? 46 : 34, height: hourHeight, alignment: .topTrailing)
                    .padding(.trailing, 4)
                    .id("hour_\(hour)")
            }
        }
    }
}

/// The event lane of a single day: hour grid lines plus time-positioned
/// event blocks. Shared between the day and 3-day views.
private struct TimelineColumn: View {
    let day: Date
    let events: [CalendarEventModel]
    let hourHeight: CGFloat
    let onSelect: (CalendarEventModel) -> Void

    private let hours = Array(0..<24)

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(hours, id: \.self) { hour in
                    Rectangle()
                        .fill(Color(.separator).opacity(0.35))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, hour == 0 ? 0 : hourHeight - 1)
                }
            }
            ForEach(timedEvents) { event in
                eventBlock(event)
            }
        }
    }

    private var timedEvents: [CalendarEventModel] {
        events.filter { !$0.allDay }.sorted { $0.start < $1.start }
    }

    @ViewBuilder
    private func eventBlock(_ event: CalendarEventModel) -> some View {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let start = max(event.start, dayStart)
        let end = min(event.end, calendar.date(byAdding: .day, value: 1, to: dayStart) ?? event.end)
        let startMinutes = max(0, calendar.dateComponents([.minute], from: dayStart, to: start).minute ?? 0)
        let durationMinutes = max(30, calendar.dateComponents([.minute], from: start, to: end).minute ?? 30)
        let offsetY = CGFloat(startMinutes) / 60.0 * hourHeight
        let height = CGFloat(durationMinutes) / 60.0 * hourHeight

        Button {
            onSelect(event)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.caption).fontWeight(.semibold)
                    .lineLimit(2)
                if height > 44 {
                    Text(timeText(event))
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(4)
            .background(Color(NCBrandColor.shared.customer).opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .offset(y: offsetY + 2)
        .frame(height: max(height - 4, 28), alignment: .top)
        .padding(.horizontal, 2)
        .zIndex(1)
    }

    private func timeText(_ event: CalendarEventModel) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: event.start)) – \(formatter.string(from: event.end))"
    }
}

/// The 3-day view: ONE shared hour scale on the left and three day columns
/// that scroll together in a single scroll view.
private struct ThreeDayTimelineView: View {
    let days: [Date]
    let eventsProvider: (Date) -> [CalendarEventModel]
    let onSelect: (CalendarEventModel) -> Void

    private let hours = Array(0..<24)
    private let hourHeight: CGFloat = 44

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        Color.clear.frame(width: 34, height: 44)
                        ForEach(days, id: \.self) { day in
                            VStack(spacing: 1) {
                                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                                    .font(.caption).fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                Text("\(Calendar.current.component(.day, from: day))")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                        }
                    }
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .trailing, spacing: 0) {
                            ForEach(hours, id: \.self) { hour in
                                Text(String(format: "%02d", hour))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, height: hourHeight, alignment: .topTrailing)
                                    .padding(.trailing, 2)
                                    .id("hour_\(hour)")
                            }
                        }
                        ForEach(days, id: \.self) { day in
                            TimelineColumn(
                                day: day,
                                events: eventsProvider(day),
                                hourHeight: hourHeight,
                                onSelect: onSelect
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.bottom, 40)
            }
            .onAppear {
                let currentHour = Calendar.current.component(.hour, from: Date())
                if days.contains(where: { Calendar.current.isDateInToday($0) }) {
                    proxy.scrollTo("hour_\(currentHour)", anchor: .top)
                }
            }
        }
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
    @State private var creatingTalkRoom = false

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
                Section(NSLocalizedString("_calendar_talk_channel_", comment: "")) {
                    if let roomName = draft.talkRoomName {
                        HStack {
                            Label(roomName, systemImage: "bubble.left.and.bubble.right")
                            Spacer()
                            Button {
                                draft.talkRoomToken = nil
                                draft.talkRoomName = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    } else if creatingTalkRoom {
                        HStack {
                            ProgressView()
                            Text(NSLocalizedString("_calendar_create_talk_", comment: "")).foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            creatingTalkRoom = true
                            Task {
                                if let room = await viewModel.createTalkRoomForDraft(
                                    name: draft.title.isEmpty ? NSLocalizedString("_calendar_new_event_", comment: "") : draft.title,
                                    attendees: draft.attendees
                                ) {
                                    draft.talkRoomToken = room.token
                                    draft.talkRoomName = room.name
                                } else {
                                    errorMessage = NSLocalizedString("_calendar_talk_error_", comment: "")
                                }
                                creatingTalkRoom = false
                            }
                        } label: {
                            Label(NSLocalizedString("_calendar_create_talk_", comment: ""), systemImage: "plus.bubble")
                        }
                    }
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
