// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Souvera calendar: CalDAV-backed month grid, day and 3-day views (Apple
// Calendar style toggle), event search, event detail and create/edit with
// attendees and an optional Talk channel per event.

import SwiftUI

/// Persistente Kalender-Einstellungen (Standard-Ansicht).
enum SouveraCalendarSettings {
    static let defaultViewKey = "souvera_calendar_default_view"

    /// Standard-Ansicht; Tagesansicht, solange der User nichts gewählt hat.
    static var defaultView: String {
        UserDefaults.standard.string(forKey: defaultViewKey) ?? "day"
    }

    static func setDefaultView(_ value: String) {
        UserDefaults.standard.set(value, forKey: defaultViewKey)
    }
}

struct SouveraCalendarView: View {
    @StateObject private var viewModel = CalendarViewModel()
    @State private var selectedDay = Date()
    @State private var viewMode: CalendarViewMode = CalendarViewMode(
        rawValue: SouveraCalendarSettings.defaultView
    ) ?? .day
    @State private var searchQuery = ""
    @State private var showSearch = false
    @State private var scrollToNowTrigger = 0
    @State private var detailEvent: CalendarEventModel?
    @State private var editState: EditSheetState?
    @State private var showCalendarPicker = false
    @State private var showMonthYearPicker = false

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
            GeometryReader { geometry in
                let isWide = geometry.size.width > geometry.size.height
                let bottomInset = max(geometry.safeAreaInsets.bottom, 48)
                VStack(spacing: 0) {
                    if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        content(isWide: isWide, width: geometry.size.width, height: geometry.size.height, bottomInset: bottomInset)
                    } else {
                        searchResults
                    }
                }
                .padding(.top, 8)
                .overlay(alignment: .top) {
                    // Suchfeld als Overlay: überlagert den Inhalt, ohne ihn
                    // zu verschieben (nur auf Knopfdruck sichtbar).
                    if showSearch {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField(NSLocalizedString("_mail_search_hint_", comment: ""), text: $searchQuery)
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                            if !searchQuery.isEmpty {
                                Button {
                                    searchQuery = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(radius: 4)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: showSearch)
            }
            .navigationTitle(NSLocalizedString("_calendar_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Ein einziger Button mit Auswahl-Menü (wie die
                    // Mail-Sortierung): aktueller Modus + Häkchen.
                    Menu {
                        ForEach(CalendarViewMode.allCases) { mode in
                            Button {
                                viewMode = mode
                            } label: {
                                if viewMode == mode {
                                    Label(mode.title, systemImage: "checkmark")
                                } else {
                                    Text(mode.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(viewMode.title).font(.subheadline)
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                    }
                    .accessibilityLabel(NSLocalizedString("_settings_calendar_default_view_", comment: ""))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSearch.toggle()
                        if !showSearch { searchQuery = "" }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel(NSLocalizedString("_mail_search_", comment: ""))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editState = EditSheetState(draft: EventDraft(start: selectedDay, end: selectedDay.addingTimeInterval(3600)), existing: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showCalendarPicker = true
                    } label: {
                        Image(systemName: "calendar.badge.checkmark")
                    }
                }
            }
        }
        .onAppear {
            selectedDay = Date()
            scrollToNowTrigger += 1
            Task { await viewModel.load() }
            viewModel.startAutoRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            Task { await viewModel.load() }
        }
        .souveraCacheBanner(active: $viewModel.cacheBannerActive)
        .overlay(alignment: .bottom) {
            if let feedback = viewModel.actionFeedback {
                HStack(spacing: 8) {
                    Image(systemName: feedback.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(feedback.success ? .green : .red)
                    Text(feedback.message).font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: viewModel.actionFeedback) { _, feedback in
            guard feedback != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                viewModel.actionFeedback = nil
            }
        }
        .sheet(isPresented: $showCalendarPicker) {
            CalendarPickerSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showMonthYearPicker) {
            MonthYearPickerSheet(initial: viewModel.visibleMonth) { date in
                viewModel.jumpToMonth(date)
            }
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

    @ViewBuilder
    private func content(isWide: Bool, width: CGFloat, height: CGFloat, bottomInset: CGFloat) -> some View {
        switch viewMode {
        case .month:
            monthView(isWide: isWide, width: width, height: height, bottomInset: bottomInset)
        case .day:
            dayView(isWide: isWide, scrollTrigger: scrollToNowTrigger)
        case .threeDay:
            threeDayView(isWide: isWide, scrollTrigger: scrollToNowTrigger)
        }
    }

    // MARK: - Month

    /// Breitengrenze für die 50/50-Aufteilung der Landscape-Monatsansicht.
    private static let wideSplitThreshold: CGFloat = 700

    @ViewBuilder
    private func monthView(isWide: Bool, width: CGFloat, height: CGFloat, bottomInset: CGFloat) -> some View {
        if isWide {
            // Apple-Stil: links kompakter Monatskalender, rechts die
            // scrollbare Terminliste des gewählten Tages. Spaltenbreite:
            // 50/50 ab der Breitengrenze, darunter wird die linke Spalte
            // schmaler, damit die Terminliste genug Platz behält.
            let splitWidth: CGFloat = width >= Self.wideSplitThreshold
                ? width / 2
                : max(230, width * 0.4)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    monthSwitcher(compact: true)
                    monthGrid(compact: true, availableHeight: height - bottomInset)
                    Spacer(minLength: 0)
                }
                .frame(width: splitWidth)
                Divider()
                dayEventList
                    .frame(maxWidth: .infinity)
            }
            .safeAreaPadding(.bottom, 8)
            .refreshable { await viewModel.load() }
        } else {
            VStack(spacing: 0) {
                monthSwitcher(compact: false)
                monthGrid(compact: false, availableHeight: height - bottomInset)
                Divider()
                dayEventList
            }
            .refreshable { await viewModel.load() }
        }
    }

    private func monthSwitcher(compact: Bool) -> some View {
        HStack {
            Button {
                viewModel.shiftMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Button {
                showMonthYearPicker = true
            } label: {
                Text(viewModel.monthTitle)
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                viewModel.shiftMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
        }
        .padding(.horizontal, compact ? 8 : 20)
        .padding(.vertical, compact ? 4 : 8)
    }

    private var weekdaySymbols: [String] {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private func monthGrid(compact: Bool, availableHeight: CGFloat) -> some View {
        let days = viewModel.monthDays
        let weeks = max(4, min(6, Int(ceil(Double(days.count) / 7.0))))
        // Zellenhöhe dynamisch aus der verfügbaren Höhe (abzüglich
        // Umschalter, Wochentagszeile, Paddings und Sicherheitsrand), damit
        // die Monatsansicht bis knapp über die Tab-Leiste reicht, aber nie
        // dahinter verschwindet.
        let budget = max(120, availableHeight - (compact ? 64 : 130))
        let cellSize: CGFloat = compact
            ? min(34, max(18, (budget - 14) / CGFloat(weeks)))
            : 40
        let dayFont = Font.system(size: max(10, min(15, cellSize * 0.5)))
        let weekdayFont = Font.system(size: max(8, min(10, cellSize * 0.3)))
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: compact ? 2 : 4), count: 7),
            spacing: compact ? 2 : 4
        ) {
            ForEach(weekdaySymbols, id: \.self) { label in
                Text(label).font(weekdayFont).foregroundStyle(.secondary)
            }
            ForEach(days, id: \.self) { day in
                dayCell(day, compact: compact, cellSize: cellSize, dayFont: dayFont)
            }
        }
        .padding(.horizontal, compact ? 4 : 10)
        .padding(.bottom, compact ? 4 : 8)
    }

    @ViewBuilder
    private func dayCell(_ day: Date, compact: Bool = false, cellSize: CGFloat = 30, dayFont: Font = .subheadline) -> some View {
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
                Task { await viewModel.ensureDayCovered(day) }
            }
        } label: {
            VStack(spacing: compact ? 1 : 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(dayFont)
                    .fontWeight(isToday ? .bold : .regular)
                    .frame(width: cellSize, height: cellSize)
                    .background(
                        Circle()
                            .fill(isSelected ? Color(NCBrandColor.shared.customer) : .clear)
                    )
                    .foregroundStyle(isSelected ? Color.white : (inMonth ? (isToday ? Color(NCBrandColor.shared.customer) : Color.primary) : Color.secondary))
                Circle()
                    .fill(dayDotColor(day))
                    .frame(width: compact ? 3 : 5, height: compact ? 3 : 5)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Day

    private func dayView(isWide: Bool, scrollTrigger: Int = 0) -> some View {
        VStack(spacing: 0) {
            dateOnlySwitcher(day: selectedDay, compact: isWide)
            Divider()
            TimelineDayView(
                day: selectedDay,
                events: viewModel.events(on: selectedDay),
                showHourLabels: true,
                hourHeight: isWide ? 44 : 56,
                onSelect: { detailEvent = $0 },
                colorFor: { viewModel.color(for: $0) },
                onCreate: createEventInSlot,
                bottomPadding: isWide ? 12 : 40,
                scrollTrigger: scrollTrigger
            )
            .refreshable { await viewModel.load() }
        }
        .offset(x: swipeOffset)
        .gesture(horizontalSwipe(step: 1))
    }

    /// Datum + Pfeile (der Wochentag kommt aus dem Timeline-Kopf, sonst
    /// stünde er doppelt da).
    private func dateOnlySwitcher(day: Date, compact: Bool = false) -> some View {
        HStack {
            Button {
                shiftSelectedDay(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Text(day, style: .date).font(.headline)
            Spacer()
            Button {
                shiftSelectedDay(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, compact ? 2 : 8)
    }

    /// Nur Pfeile (3-Tage-Ansicht: die Tagesköpfe zeigen Datum/Wochentag).
    private func arrowsOnlySwitcher(step: Int, compact: Bool = false) -> some View {
        HStack {
            Button {
                shiftSelectedDay(by: -step)
            } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Button {
                shiftSelectedDay(by: step)
            } label: {
                Image(systemName: "chevron.right")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, compact ? 2 : 8)
    }

    /// Swipe horizontal: Tag (step=1) bzw. 3 Tage (step=3) weiter. Die
    /// Ansicht folgt dem Finger und federt beim Loslassen zurück bzw.
    /// wechselt den Tag.
    @GestureState private var swipeOffset: CGFloat = 0

    private func horizontalSwipe(step: Int) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($swipeOffset) { value, state, _ in
                let h = value.translation.width
                let v = value.translation.height
                state = abs(h) > abs(v) ? h : 0
            }
            .onEnded { value in
                let h = value.translation.width
                let v = value.translation.height
                guard abs(h) > abs(v) else { return }
                let threshold: CGFloat = 90
                if abs(h) >= threshold {
                    shiftSelectedDay(by: h < 0 ? step : -step)
                }
            }
    }

    /// Öffnet den Erstell-Dialog mit dem getroffenen Zeitslot.
    private func createEventInSlot(start: Date, end: Date) {
        editState = EditSheetState(
            draft: EventDraft(start: start, end: end),
            existing: nil
        )
    }

    private func dayDotColor(_ day: Date) -> Color {
        guard let first = viewModel.events(on: day).first else { return .clear }
        return viewModel.color(for: first)
    }

    private func shiftSelectedDay(by days: Int) {
        let calendar = Calendar.current
        if let shifted = calendar.date(byAdding: .day, value: days, to: selectedDay) {
            selectedDay = shifted
            viewModel.ensureMonth(contains: shifted)
            // Tag außerhalb des geladenen Fensters? Events gezielt nachladen,
            // damit die Tagesliste/Timeline nie leer ist.
            Task { await viewModel.ensureDayCovered(shifted) }
        }
    }

    // MARK: - 3 days

    private func threeDayView(isWide: Bool, scrollTrigger: Int = 0) -> some View {
        VStack(spacing: 0) {
            ThreeDayTimelineView(
                days: threeDayRange,
                eventsProvider: { viewModel.events(on: $0) },
                onSelect: { detailEvent = $0 },
                colorFor: { viewModel.color(for: $0) },
                onCreate: createEventInSlot,
                compact: isWide,
                onPrev: { shiftSelectedDay(by: -3) },
                onNext: { shiftSelectedDay(by: 3) },
                scrollTrigger: scrollTrigger
            )
        }
        .offset(x: swipeOffset)
        .refreshable { await viewModel.load() }
        .gesture(horizontalSwipe(step: 3))
    }

    private var threeDayRange: [Date] {
        // Der aktuelle Tag steht IMMER in der ersten Spalte: die Fenster
        // sind an heute verankert (heute + 3*k Tage), die Pfeile/Swipe
        // schieben um ganze Fenster (±3).
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let selected = calendar.startOfDay(for: selectedDay)
        let dayDiff = calendar.dateComponents([.day], from: today, to: selected).day ?? 0
        let offset = dayDiff >= 0 ? (dayDiff / 3) * 3 : ((dayDiff - 2) / 3) * 3
        guard let base = calendar.date(byAdding: .day, value: offset, to: today),
              let second = calendar.date(byAdding: .day, value: 1, to: base),
              let third = calendar.date(byAdding: .day, value: 2, to: base) else {
            return [selectedDay]
        }
        return [base, second, third]
    }

    // MARK: - Event rows

    @ViewBuilder
    private func eventRow(_ event: CalendarEventModel) -> some View {
        Button {
            detailEvent = event
        } label: {
            CalendarEventRow(event: event, color: viewModel.color(for: event))
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
            let upcoming = viewModel.upcomingEvents()
            if dayEvents.isEmpty {
                if upcoming.isEmpty {
                    Spacer()
                    Text(NSLocalizedString("_calendar_no_events_", comment: "")).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List {
                        Section(NSLocalizedString("_calendar_upcoming_", comment: "")) {
                            ForEach(upcoming) { event in
                                eventRow(event)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
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
    var color: Color = Color(NCBrandColor.shared.customer)

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 4)
            if event.isTask {
                Image(systemName: "checklist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(event.title).font(.subheadline).fontWeight(.medium).lineLimit(1)
                    if !event.reminders.isEmpty {
                        Image(systemName: "bell.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    if event.talkRoomToken != nil {
                        Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
    var colorFor: (CalendarEventModel) -> Color = { _ in Color(NCBrandColor.shared.customer) }
    var onCreate: ((Date, Date) -> Void)? = nil
    var bottomPadding: CGFloat = 40
    /// Zählt bei jedem Erscheinen des Kalenders hoch (Tab-Wechsel) ->
    /// Scroll zur Jetzt-Linie.
    var scrollTrigger: Int = 0

    private let hours = Array(0..<24)
    @State private var slotActive = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    allDaySection
                    HStack(alignment: .top, spacing: 0) {
                        hourScale
                        TimelineColumn(day: day, events: events, hourHeight: hourHeight, onSelect: onSelect, colorFor: colorFor, onCreate: onCreate, onSlotActive: { slotActive = $0 })
                    }
                }
                .padding(.bottom, bottomPadding)
            }
            .scrollDisabled(slotActive)
            .onAppear {
                scrollToNow(proxy)
            }
            .onChange(of: scrollTrigger) { _, _ in
                scrollToNow(proxy)
            }
        }
    }

    private func scrollToNow(_ proxy: ScrollViewProxy) {
        let currentHour = Calendar.current.component(.hour, from: Date())
        if Calendar.current.isDateInToday(day) {
            proxy.scrollTo("hour_\(currentHour)", anchor: .top)
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
/// event blocks. Overlapping events are laid out side by side. Shared
/// between the day and 3-day views.
private struct TimelineColumn: View {
    let day: Date
    let events: [CalendarEventModel]
    let hourHeight: CGFloat
    let onSelect: (CalendarEventModel) -> Void
    var colorFor: (CalendarEventModel) -> Color = { _ in Color(NCBrandColor.shared.customer) }
    var onCreate: ((Date, Date) -> Void)? = nil
    var showTrailingBorder: Bool = false
    /// Meldet nach oben, ob gerade ein Terminslot gezeichnet wird - dann
    /// sperrt die übergeordnete ScrollView das Scrollen.
    var onSlotActive: ((Bool) -> Void)? = nil

    private let hours = Array(0..<24)

    var body: some View {
        GeometryReader { geometry in
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
                if let slot = dragSlot {
                    let offsetY = CGFloat(slot.start) / 60.0 * hourHeight
                    let height = CGFloat(max(slot.end - slot.start, 15)) / 60.0 * hourHeight
                    Rectangle()
                        .fill(Color(NCBrandColor.shared.customer).opacity(0.25))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(NCBrandColor.shared.customer).opacity(0.6), lineWidth: 1)
                        )
                        .padding(.horizontal, 2)
                        .offset(y: offsetY + 2)
                        .frame(height: max(height - 4, 20), alignment: .top)
                }
                ForEach(timedEvents) { event in
                    eventBlock(event, containerWidth: geometry.size.width)
                }
                if showsNowLine {
                    // Jetzt-Linie bewusst ZULETZT zeichnen - immer sichtbar,
                    // auch im Landscape, über allen Event-Blöcken.
                    nowLine
                }
            }
            .contentShape(Rectangle())
            // Reiner Long-Press setzt nur ein Flag; der Slot-Drag läuft
            // simultan und zeichnet erst nach dem Long-Press. Beides
            // blockiert das Scrollen der ScrollView nicht.
            .simultaneousGesture(slotDrag)
            .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 14) {
                longPressActive = true
            }
            .onChange(of: dragSlot != nil) { _, active in
                onSlotActive?(active)
            }
        }
        .overlay(alignment: .trailing) {
            if showTrailingBorder {
                Rectangle()
                    .fill(Color(.separator).opacity(0.35))
                    .frame(width: 1)
            }
        }
    }

    private var timedEvents: [CalendarEventModel] {
        events.filter { !$0.allDay }.sorted { $0.start < $1.start }
    }

    /// Heutige Spalte bekommt eine rötliche Jetzt-Linie.
    private var showsNowLine: Bool {
        Calendar.current.isDateInToday(day)
    }

    private var nowLine: some View {
        let calendar = Calendar.current
        let now = Date()
        let dayStart = calendar.startOfDay(for: day)
        let minutes = max(0, min(24 * 60 - 1, calendar.dateComponents([.minute], from: dayStart, to: now).minute ?? 0))
        let offsetY = CGFloat(minutes) / 60.0 * hourHeight
        return HStack(spacing: 0) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
            Rectangle()
                .fill(Color.red.opacity(0.85))
                .frame(height: 1.5)
        }
        .offset(y: offsetY - 3)
    }

    /// Spalten-Aufteilung für überlappende Termine (greedy).
    private func columnLayouts() -> [String: (column: Int, count: Int)] {
        var result: [String: (Int, Int)] = [:]
        var cluster: [CalendarEventModel] = []
        for event in timedEvents {
            if let lastEnd = cluster.map(\.end).max(), event.start >= lastEnd {
                assignColumns(cluster, into: &result)
                cluster = []
            }
            cluster.append(event)
        }
        assignColumns(cluster, into: &result)
        return result
    }

    private func assignColumns(_ cluster: [CalendarEventModel], into result: inout [String: (Int, Int)]) {
        guard !cluster.isEmpty else { return }
        var columnEnds: [Date] = []
        var columns: [String: Int] = [:]
        for event in cluster {
            if let found = columnEnds.firstIndex(where: { event.start >= $0 }) {
                columnEnds[found] = event.end
                columns[event.id] = found
            } else {
                columnEnds.append(event.end)
                columns[event.id] = columnEnds.count - 1
            }
        }
        let count = columnEnds.count
        for event in cluster {
            result[event.id] = (columns[event.id] ?? 0, count)
        }
    }

    @ViewBuilder
    private func eventBlock(_ event: CalendarEventModel, containerWidth: CGFloat) -> some View {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let start = max(event.start, dayStart)
        let end = min(event.end, calendar.date(byAdding: .day, value: 1, to: dayStart) ?? event.end)
        let startMinutes = max(0, calendar.dateComponents([.minute], from: dayStart, to: start).minute ?? 0)
        let durationMinutes = max(30, calendar.dateComponents([.minute], from: start, to: end).minute ?? 30)
        let offsetY = CGFloat(startMinutes) / 60.0 * hourHeight
        let height = CGFloat(durationMinutes) / 60.0 * hourHeight
        let layout = columnLayouts()[event.id] ?? (0, 1)
        let width = containerWidth / CGFloat(layout.count)
        let x = CGFloat(layout.column) * width

        Button {
            onSelect(event)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.caption).fontWeight(.semibold)
                    .lineLimit(2)
                if height > 40 {
                    Text(timeText(event))
                        .font(.caption2)
                        .lineLimit(1)
                }
                if height > 64 {
                    HStack(spacing: 4) {
                        if !event.reminders.isEmpty {
                            Image(systemName: "bell.fill").font(.system(size: 9))
                        }
                        if event.talkRoomToken != nil {
                            Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 9))
                        }
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(3)
            .background(colorFor(event).opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .offset(x: x, y: offsetY + 2)
        .frame(width: max(width - 3, 0), height: max(height - 4, 28), alignment: .top)
        .zIndex(1)
    }

    /// Tap auf die freie Fläche = Termin im Zeitslot erstellen; Ziehen wählt
    /// den Slot-Bereich. Zeiten rasten in 15-Minuten-Schritten ein
    /// (Start abrunden, Ende aufrunden, mindestens 15 Minuten) und der Slot
    /// wird während des Ziehens sichtbar markiert.
    @GestureState private var dragSlot: (start: Int, end: Int)?

    private static func minute(for y: CGFloat, hourHeight: CGFloat) -> Int {
        let minutes = Int((y / hourHeight) * 60)
        return max(0, min(24 * 60 - 1, minutes))
    }

    private static func snapDown(_ minute: Int) -> Int { (minute / 15) * 15 }
    private static func snapUp(_ minute: Int) -> Int { ((minute + 14) / 15) * 15 }

    private func timeText(_ event: CalendarEventModel) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: event.start)) – \(formatter.string(from: event.end))"
    }
}

/// The 3-day view: ONE shared hour scale on the left and three day columns
/// that scroll together in a single scroll view.
private struct ThreeDayTimelineView: View {
    @State private var slotActive = false
    let days: [Date]
    let eventsProvider: (Date) -> [CalendarEventModel]
    let onSelect: (CalendarEventModel) -> Void
    var colorFor: (CalendarEventModel) -> Color = { _ in Color(NCBrandColor.shared.customer) }
    var onCreate: ((Date, Date) -> Void)? = nil
    var compact: Bool = false
    var onPrev: () -> Void = {}
    var onNext: () -> Void = {}
    /// Zählt bei jedem Erscheinen des Kalenders hoch (Tab-Wechsel) ->
    /// Scroll zur Jetzt-Linie.
    var scrollTrigger: Int = 0

    private let hours = Array(0..<24)
    private var hourHeight: CGFloat { compact ? 40 : 44 }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // Feste Tagesköpfe: bleiben beim Scrollen stehen; die
                // Pfeile liegen IN dieser Zeile (links/rechts der Tage).
                HStack(alignment: .top, spacing: 0) {
                    Color.clear.frame(width: 34, height: compact ? 32 : 40)
                    ForEach(days, id: \.self) { day in
                        VStack(spacing: 1) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                                .font(compact ? .system(size: 10) : .caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                            Text("\(Calendar.current.component(.day, from: day))")
                                .font(compact ? .subheadline.weight(.semibold) : .headline)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? 32 : 40)
                    }
                }
                .overlay(alignment: .leading) {
                    Button(action: onPrev) {
                        Image(systemName: "chevron.left")
                            .font(.subheadline)
                            .frame(width: 30, height: compact ? 32 : 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 36)
                }
                .overlay(alignment: .trailing) {
                    Button(action: onNext) {
                        Image(systemName: "chevron.right")
                            .font(.subheadline)
                            .frame(width: 30, height: compact ? 32 : 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 2)
                }
                Divider()
                ScrollView {
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
                                onSelect: onSelect,
                                colorFor: colorFor,
                                onCreate: onCreate,
                                showTrailingBorder: true,
                                onSlotActive: { slotActive = $0 }
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.bottom, compact ? 12 : 40)
                }
                .scrollDisabled(slotActive)
            }
            .onAppear {
                scrollToNow(proxy)
            }
            .onChange(of: scrollTrigger) { _, _ in
                scrollToNow(proxy)
            }
        }
    }

    private func scrollToNow(_ proxy: ScrollViewProxy) {
        let currentHour = Calendar.current.component(.hour, from: Date())
        if days.contains(where: { Calendar.current.isDateInToday($0) }) {
            proxy.scrollTo("hour_\(currentHour)", anchor: .top)
        }
    }
}

/// Detail view of one event with edit, delete and Talk-channel actions.
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
                        if let callToken = SouveraLinkOpener.talkRoomToken(in: location) {
                            // Der Ort enthält den Videoanruf-Link: ganze Zeile
                            // als Button - öffnet das Link-Modul direkt.
                            Button {
                                if event.talkRoomToken != nil {
                                    viewModel.openTalkRoom(for: event)
                                } else {
                                    NotificationCenter.default.post(
                                        name: .openLinkRoom,
                                        object: ["token": callToken, "title": event.title]
                                    )
                                }
                                dismiss()
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "video.fill")
                                        .foregroundStyle(Color(NCBrandColor.shared.customer))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(location)
                                            .font(.subheadline)
                                            .foregroundStyle(Color(NCBrandColor.shared.customer))
                                            .lineLimit(2)
                                        Text(NSLocalizedString("_calendar_join_video_call_", comment: ""))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "mappin")
                                    .foregroundStyle(.secondary)
                                Text(SouveraLinkOpener.linkified(location))
                                    .souveraOpenURLAction()
                            }
                        }
                    }
                }
                if !event.reminders.isEmpty {
                    Section(NSLocalizedString("_calendar_reminders_", comment: "")) {
                        ForEach(event.reminders.sorted(), id: \.self) { minutes in
                            Label(CalendarReminderText.label(minutes: minutes), systemImage: "bell")
                        }
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
                        Text(SouveraLinkOpener.linkified(notes))
                            .textSelection(.enabled)
                            .souveraOpenURLAction()
                    }
                }
                if let roomName = event.talkRoomName {
                    Section(NSLocalizedString("_calendar_talk_channel_", comment: "")) {
                        HStack {
                            Label(roomName, systemImage: "bubble.left.and.bubble.right")
                            Spacer()
                            Button(NSLocalizedString("_calendar_open_talk_", comment: "")) {
                                viewModel.openTalkRoom(for: event)
                                dismiss()
                            }
                        }
                    }
                }
                if !event.isTask {
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
    /// Talk-Token, mit dem das Sheet geöffnet wurde - wird der Link entfernt,
    /// löschen wir nach dem Speichern den zugehörigen Channel.
    @State private var originalTalkToken: String?
    /// Raum, der in DIESER Sitzung erstellt wurde (noch ungespeichert) -
    /// wird bei Abbruch/Entfernen aufgeräumt (Waisen-Schutz).
    @State private var createdSessionToken: String?
    /// Link wurde in dieser Sitzung explizit per Menü entfernt.
    @State private var removedTalkLink = false
    @Environment(\.dismiss) private var dismiss

    init(viewModel: CalendarViewModel, draft: EventDraft, existing: CalendarEventModel?) {
        self.viewModel = viewModel
        self.existing = existing
        _draft = State(initialValue: draft)
        _originalTalkToken = State(initialValue: draft.talkRoomToken)
    }
    @State private var saving = false
    @State private var errorMessage: String?

    private var selectedCalendarName: String {
        viewModel.writableCalendars.first(where: { $0.href == draft.calendarHref })?.displayName
            ?? viewModel.defaultCalendar?.displayName
            ?? ""
    }

    private var calendarDisplayName: String {
        viewModel.calendars.first(where: { $0.href == existing?.calendarHref })?.displayName ?? ""
    }
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
                if existing == nil {
                    // Neue Termine: Ziel-Kalender wählbar (nur schreibbare).
                    Section(NSLocalizedString("_calendar_select_calendar_", comment: "")) {
                        Menu {
                            ForEach(viewModel.writableCalendars, id: \.href) { calendar in
                                Button {
                                    draft.calendarHref = calendar.href
                                } label: {
                                    if draft.calendarHref == calendar.href {
                                        Label(calendar.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(calendar.displayName)
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(selectedCalendarName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    // Bestehende Termine: Kalender nur anzeigen.
                    Section(NSLocalizedString("_calendar_select_calendar_", comment: "")) {
                        Label(calendarDisplayName, systemImage: "calendar")
                    }
                }
                Section {
                    DatePicker(NSLocalizedString("_calendar_start_", comment: ""), selection: $draft.start, displayedComponents: draft.allDay ? .date : [.date, .hourAndMinute])
                    DatePicker(NSLocalizedString("_calendar_end_", comment: ""), selection: $draft.end, displayedComponents: draft.allDay ? .date : [.date, .hourAndMinute])
                }
                Section {
                    TextField(NSLocalizedString("_calendar_location_", comment: ""), text: $draft.location)
                }
                Section(NSLocalizedString("_calendar_reminders_", comment: "")) {
                    ForEach(draft.reminders.sorted(), id: \.self) { minutes in
                        HStack {
                            Label(reminderLabel(minutes), systemImage: "bell")
                                .font(.subheadline)
                            Spacer()
                            Button {
                                draft.reminders.removeAll { $0 == minutes }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Menu {
                        ForEach(CalendarReminderText.presets, id: \.self) { minutes in
                            Button(reminderLabel(minutes)) {
                                if !draft.reminders.contains(minutes) {
                                    draft.reminders.append(minutes)
                                }
                            }
                        }
                    } label: {
                        Label(NSLocalizedString("_calendar_reminder_add_", comment: ""), systemImage: "plus.bell")
                    }
                }
                Section(NSLocalizedString("_calendar_attendees_", comment: "")) {
                    ForEach(draft.attendees, id: \.self) { attendee in
                        HStack {
                            Text(attendee).font(.subheadline)
                            Spacer()
                        }
                        // Entfernen bewusst per Swipe (kein nacktes X mehr,
                        // das versehentlich angetippt wird).
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                draft.attendees.removeAll { $0 == attendee }
                            } label: {
                                Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash")
                            }
                        }
                    }
                    HStack {
                        TextField(NSLocalizedString("_calendar_add_attendee_", comment: ""), text: $attendeeInput)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .onSubmit {
                                addAttendee(attendeeInput)
                            }
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
                        // Unbekannte E-Mail-Adressen direkt übernehmen -
                        // der Add-Button erscheint nur bei gültiger Eingabe,
                        // der Kontakt-Picker behält sein Personen-Icon.
                        if attendeeInput.trimmingCharacters(in: .whitespaces).contains("@") {
                            Button {
                                addAttendee(attendeeInput)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Color(NCBrandColor.shared.customer))
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
                            // "…"-Menü statt nacktem X: Öffnen und Entfernen
                            // sind explizite Aktionen (kein versehentliches
                            // Löschen des Raums beim Speichern).
                            Menu {
                                Button {
                                    if let token = draft.talkRoomToken {
                                        NotificationCenter.default.post(
                                            name: .openLinkRoom,
                                            object: ["token": token, "title": roomName]
                                        )
                                        dismiss()
                                    }
                                } label: {
                                    Label(NSLocalizedString("_calendar_open_talk_", comment: ""), systemImage: "arrow.up.right.square")
                                }
                                Button(role: .destructive) {
                                    removeTalkLinkFromDraft()
                                } label: {
                                    Label(NSLocalizedString("_calendar_talk_remove_", comment: ""), systemImage: "link.badge.minus")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
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
                                    attendees: draft.attendees,
                                    eventUid: draft.uid,
                                    notes: draft.notes
                                ) {
                                    draft.talkRoomToken = room.token
                                    draft.talkRoomName = room.name
                                    createdSessionToken = room.token
                                    // Store the join link in the standard fields, exactly
                                    // like the Nextcloud Calendar web app: LOCATION when
                                    // free, otherwise appended to the DESCRIPTION - so
                                    // invitation mails carry the link too.
                                    if draft.location.trimmingCharacters(in: .whitespaces).isEmpty {
                                        draft.location = room.url
                                    } else {
                                        draft.notes = draft.notes.isEmpty ? room.url : draft.notes + "\n\n" + room.url
                                    }
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
            .onAppear {
                // Default-Zielkalender für neue Termine: persönlicher.
                if existing == nil, draft.calendarHref.isEmpty {
                    draft.calendarHref = viewModel.defaultCalendar?.href ?? ""
                }
            }
            .sheet(isPresented: $showContactPicker) {
                ContactPickerSheet { email in
                    addAttendee(email)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) {
                        cleanupUnsavedSessionRoom()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(NSLocalizedString("_contact_save_", comment: "")) {
                            saving = true
                            // Noch nicht übernommene E-Mail-Eingabe mitnehmen
                            // (kein stiller Verlust beim Speichern).
                            let pending = attendeeInput.trimmingCharacters(in: .whitespaces)
                            if !pending.isEmpty {
                                addAttendee(pending)
                            }
                            Task {
                                let ok = await viewModel.saveEvent(draft, existing: existing)
                                if ok {
                                    await applyTalkLinkChanges()
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

    private func reminderLabel(_ minutes: Int) -> String {
        CalendarReminderText.label(minutes: minutes)
    }

    private func removeTalkLinkFromDraft() {
        let token = draft.talkRoomToken
        removedTalkLink = true
        draft.talkRoomToken = nil
        draft.talkRoomName = nil
        // Auch die im Standardfeld gespeicherte URL (LOCATION/DESCRIPTION)
        // entfernen, damit der Link wirklich aus dem Termin verschwindet.
        if let token, !token.isEmpty {
            let suffix = "/call/\(token)"
            if draft.location.contains(suffix) {
                draft.location = ""
            }
            draft.notes = draft.notes
                .components(separatedBy: .newlines)
                .filter { !$0.contains(suffix) }
                .joined(separator: "\n")
        }
    }

    private func addAttendee(_ email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.contains("@"), !draft.attendees.contains(trimmed) else { return }
        draft.attendees.append(trimmed)
        attendeeInput = ""
        attendeeSuggestions = []
    }

    /// Setzt die Talk-Link-Änderungen nach erfolgreichem Speichern um:
    /// - explizit entfernt → zugehörigen Raum löschen (gespeicherten ODER
    ///   in dieser Sitzung erstellten)
    /// - neuer Link erstellt, während ein alter gespeichert war → alten Raum
    ///   ersetzen (kein Leak)
    /// - sonst: nichts löschen (der Raum bleibt bestehen).
    private func applyTalkLinkChanges() async {
        if removedTalkLink {
            if let created = createdSessionToken, !created.isEmpty, created != originalTalkToken {
                JmapLog.write("Calendar talk: removing unsaved session room \(created)")
                await viewModel.deleteTalkRoom(token: created)
            } else if let original = originalTalkToken, !original.isEmpty {
                await viewModel.deleteTalkRoom(token: original)
            }
            return
        }
        if let created = createdSessionToken, !created.isEmpty, created != originalTalkToken,
           let original = originalTalkToken, !original.isEmpty {
            JmapLog.write("Calendar talk: replacing old room \(original) with \(created)")
            await viewModel.deleteTalkRoom(token: original)
        }
    }

    /// Abbruch ohne Speichern: ein in dieser Sitzung erstellter, noch nicht
    /// gespeicherter Raum wird wieder gelöscht (kein Waisenraum).
    private func cleanupUnsavedSessionRoom() {
        guard !saving else { return }
        if let created = createdSessionToken, !created.isEmpty, created != originalTalkToken {
            JmapLog.write("Calendar talk: cancel - removing unsaved session room \(created)")
            Task { await viewModel.deleteTalkRoom(token: created) }
        }
    }
}

/// Calendar selection sheet: toggle calendars (persistent) and pick a
/// custom color per calendar via its "..." menu.
private struct CalendarPickerSheet: View {
    @ObservedObject var viewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss

    private let palette: [String] = [
        "#4BBFEA", "#496BBF", "#34C759", "#FF9500", "#FF3B30",
        "#AF52DE", "#FF2D55", "#8E8E93"
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.calendars, id: \.href) { calendar in
                    HStack(spacing: 12) {
                        Button {
                            viewModel.toggleCalendar(calendar)
                            Task { await viewModel.load() }
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(viewModel.color(for: calendar) ?? Color(NCBrandColor.shared.customer))
                                    .frame(width: 14, height: 14)
                                Text(calendar.displayName)
                                    .lineLimit(1)
                                Spacer()
                                if viewModel.isSelected(calendar) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color(NCBrandColor.shared.customer))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Menu {
                            Button {
                                viewModel.setCustomColor("", for: calendar)
                            } label: {
                                Label(NSLocalizedString("_calendar_color_default_", comment: ""), systemImage: "arrow.counterclockwise")
                            }
                            ForEach(palette, id: \.self) { hex in
                                Button {
                                    viewModel.setCustomColor(hex, for: calendar)
                                } label: {
                                    Label(NSLocalizedString("_calendar_color_", comment: ""), systemImage: "circle.fill")
                                }
                                .tint(Color(hex: hex) ?? .blue)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("_calendar_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await viewModel.load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(NSLocalizedString("_calendar_refresh_", comment: ""))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("_done_", comment: "")) { dismiss() }
                }
            }
        }
    }
}

extension Color {
    /// Creates a Color from "#RRGGBB" / "#RRGGBBAA" hex strings; returns
    /// nil for unparseable values.
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6 || cleaned.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else { return nil }
        let r, g, b, a: Double
        if cleaned.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self.init(red: r, green: g, blue: b, opacity: a)
    }
}

/// Monat/Jahr-Auswahl: Jahres-Stepper + 12-Monats-Raster.
private struct MonthYearPickerSheet: View {
    let initial: Date
    let onSelect: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var year: Int
    @State private var month: Int

    init(initial: Date, onSelect: @escaping (Date) -> Void) {
        self.initial = initial
        self.onSelect = onSelect
        let calendar = Calendar.current
        _year = State(initialValue: calendar.component(.year, from: initial))
        _month = State(initialValue: calendar.component(.month, from: initial))
    }

    private let monthNames: [String] = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        return (1...12).map { month in
            formatter.monthSymbols[month - 1]
        }
    }()

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                HStack {
                    Button {
                        year -= 1
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    Spacer()
                    Text("\(year)")
                        .font(.title2.bold())
                        .monospacedDigit()
                    Spacer()
                    Button {
                        year += 1
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                }
                .padding(.horizontal, 40)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    ForEach(1...12, id: \.self) { candidate in
                        Button {
                            selectMonth(candidate)
                        } label: {
                            Text(monthNames[candidate - 1])
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    candidate == month && year == Calendar.current.component(.year, from: initial)
                                        ? Color(NCBrandColor.shared.customer).opacity(0.25)
                                        : Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                Spacer()
            }
            .padding(.top, 16)
            .navigationTitle(NSLocalizedString("_calendar_month_year_picker_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func selectMonth(_ candidate: Int) {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.year = year
        components.month = candidate
        components.day = 1
        if let date = Calendar.current.date(from: components) {
            onSelect(date)
        }
        dismiss()
    }
}
