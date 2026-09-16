// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// UI-Komponenten für die Einladungs-Detail-Ansicht: Überschneidungs-
// liste (B7), Tages-Popup (B8), Alternativvorschlag (B9) und der
// Erinnerungs-Editor (B4).
import SwiftUI

// MARK: - B7: Überschneidungen

struct SouveraOverlap: Identifiable {
    let event: CalendarEventModel
    /// true = Einladungszeitraum liegt vollständig im anderen Termin.
    let fullOverlap: Bool
    var id: String { event.href }
}

enum SouveraOverlapCalculator {
    /// Alle kollidierenden Termine (Voll- vs. Teilweise) für einen Termin.
    static func overlaps(of event: CalendarEventModel,
                         in all: [CalendarEventModel]) -> [SouveraOverlap] {
        guard !event.allDay else {
            // Ganztägig: Kollision = anderer ganztägiger Termin am selben Tag.
            let day = Calendar.current.startOfDay(for: event.start)
            return all
                .filter { $0.href != event.href && $0.allDay
                    && Calendar.current.isDate($0.start, inSameDayAs: day) }
                .map { SouveraOverlap(event: $0, fullOverlap: true) }
        }
        return all.compactMap { other in
            guard other.href != event.href else { return nil }
            let overlapsTime = other.start < event.end && event.start < other.end
            guard overlapsTime else { return nil }
            if event.allDay != other.allDay {
                // Gemischt: Zeitliche Überschneidung reicht (Ganztägig
                // deckt den ganzen Tag ab).
                return SouveraOverlap(event: other, fullOverlap: true)
            }
            let full = other.start <= event.start && event.end <= other.end
            return SouveraOverlap(event: other, fullOverlap: full)
        }
        .sorted { $0.event.start < $1.event.start }
    }
}

struct SouveraOverlapListView: View {
    let event: CalendarEventModel
    let allEvents: [CalendarEventModel]
    let onTap: (SouveraOverlap) -> Void

    var body: some View {
        let overlaps = SouveraOverlapCalculator.overlaps(of: event, in: allEvents)
        if !overlaps.isEmpty {
            ForEach(overlaps) { overlap in
                Button {
                    onTap(overlap)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: overlap.fullOverlap ? "square.fill.square.stack" : "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(overlap.event.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Text(timeText(overlap.event))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(overlap.fullOverlap
                                 ? NSLocalizedString("_invitations_overlap_full_", comment: "")
                                 : NSLocalizedString("_invitations_overlap_partial_", comment: ""))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func timeText(_ event: CalendarEventModel) -> String {
        let formatter = DateFormatter()
        if event.allDay {
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: event.start)
        }
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let endFormatter = DateFormatter()
        endFormatter.dateStyle = .none
        endFormatter.timeStyle = .short
        return "\(formatter.string(from: event.start)) – \(endFormatter.string(from: event.end))"
    }
}

// MARK: - B8: Tages-Popup (Mini-Tagesansicht)

struct SouveraDayPreviewPopup: View {
    /// Der Tag, der angezeigt wird (Starttag der Kollision).
    let day: Date
    /// Der eingeladene Termin (Akzent-Rahmen).
    let highlightEvent: CalendarEventModel
    /// Der kollidierende Termin (orange).
    let collidingEvent: CalendarEventModel
    let allEvents: [CalendarEventModel]
    let onDismiss: () -> Void

    @State private var scrolledToBlock = false

    private var dayEvents: [CalendarEventModel] {
        allEvents
            .filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
            .sorted { $0.start < $1.start }
    }

    var body: some View {
        NavigationStack {
            Group {
                if dayEvents.isEmpty {
                    Text(NSLocalizedString("_invitations_day_empty_", comment: ""))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(dayEvents) { event in
                                    block(for: event)
                                }
                            }
                            .padding(.vertical, 10)
                        }
                        .onAppear {
                            guard !scrolledToBlock else { return }
                            scrolledToBlock = true
                            let anchor = dayEvents.first {
                                $0.href == highlightEvent.href || $0.href == collidingEvent.href
                            } ?? dayEvents.first
                            if let anchor { proxy.scrollTo(anchor.href, anchor: .center) }
                        }
                    }
                }
            }
            .navigationTitle(Text(dayTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("_done_", comment: "")) { onDismiss() }
                }
            }
        }
        .preferredColorScheme(.light)
    }

    /// Zeitblock eines Termins im Tagesraster (Dauer-proportional,
    /// Mindesthöhe für kurze Termine).
    private func block(for event: CalendarEventModel) -> some View {
        let isInvite = event.href == highlightEvent.href
        let isCollision = event.href == collidingEvent.href
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let duration = max(0, event.end.timeIntervalSince(event.start))
        let minutes = min(240, max(20, duration / 60))
        let border: Color = isInvite ? Color.blue : (isCollision ? .orange : .clear)
        let fill: Color = isInvite ? Color.blue.opacity(0.10) : (isCollision ? Color.orange.opacity(0.12) : Color(.systemGray6))
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                if event.allDay {
                    Text(NSLocalizedString("_calendar_all_day_", comment: ""))
                        .font(.caption.weight(.medium))
                } else {
                    Text("\(formatter.string(from: event.start)) – \(formatter.string(from: event.end))")
                        .font(.caption.weight(.medium))
                }
                Spacer()
                if isCollision {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .foregroundStyle(.secondary)
            Text(event.title)
                .font(.subheadline.weight(isInvite || isCollision ? .semibold : .regular))
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: minutes, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: isInvite || isCollision ? 1.5 : 0.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .id(event.href)
    }

    private var dayTitle: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }
}

// MARK: - B4: Erinnerungs-Editor

struct SouveraReminderEditor: View {
    @Binding var minutes: [Int]

    private let suggestions = [5, 10, 15, 30, 60]

    var body: some View {
        ForEach(minutes.sorted(), id: \.self) { minute in
            HStack {
                Label(String(format: NSLocalizedString("_calendar_reminder_minutes_before_", comment: ""), minute),
                      systemImage: "bell.fill")
                    .font(.subheadline)
                Spacer()
                Button {
                    minutes.removeAll { $0 == minute }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
        }
        HStack(spacing: 6) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    if !minutes.contains(suggestion) { minutes.append(suggestion) }
                } label: {
                    Text("\(suggestion)")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(minutes.contains(suggestion) ? Color.blue : Color(.systemGray5)))
                        .foregroundStyle(minutes.contains(suggestion) ? .white : .primary)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - B9: Alternativvorschlag

enum SouveraAltProposal {
    /// Freie Zeitslots in der DAUER der Einladung (nicht pauschal 30/60):
    /// erste Lücken am selben Tag, sonst nächster Tag gleiche Uhrzeit.
    static func proposals(for event: CalendarEventModel,
                          in all: [CalendarEventModel],
                          maxCount: Int = 3) -> [Date] {
        guard !event.allDay, duration > 0 else { return [] }
        let calendar = Calendar.current
        // Belegte Zeiträume: alle nicht-ganztägigen Termine.
        let busy: [(Date, Date)] = all.filter { !$0.allDay }.map { ($0.start, $0.end) }

        func isFree(_ start: Date, end: Date) -> Bool {
            !busy.contains { s, e in s < end && start < e }
        }

        var slots: [Date] = []
        // Lücken am selben Tag: ab Ende der Einladung bis 21:00 - die
        // Slots haben DIE DAUER DER EINLADUNG (nicht pauschal 30/60).
        var candidate = event.end
        let dayEnd = calendar.date(bySettingHour: 21, minute: 0, second: 0,
                                   of: event.start) ?? event.end
        while candidate.addingTimeInterval(duration) <= dayEnd, slots.count < maxCount {
            if isFree(candidate, end: candidate.addingTimeInterval(duration)) {
                slots.append(candidate)
                candidate = candidate.addingTimeInterval(duration)
            } else {
                candidate = candidate.addingTimeInterval(900)
            }
        }
        // Nächster Tag, gleiche Uhrzeit (bis zu 2 Slots).
        for dayOffset in 1...2 where slots.count < maxCount {
            if let next = calendar.date(byAdding: .day, value: dayOffset, to: event.start),
               isFree(next, end: next.addingTimeInterval(duration)) {
                slots.append(next)
            }
        }
        return Array(slots.prefix(maxCount))
    }
}
