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
            // Run 17.09. (Feedback): fehlgeparste Zeiträume (Ende vor
            // Anfang, "28.08 14:00 - 10:30") und Multitages-Übrigbleibsel
            // (> 7 Tage) überschatten alles - ignorieren.
            guard other.end > other.start else { return nil }
            guard other.end.timeIntervalSince(other.start) < 7 * 86400 else { return nil }
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
                    // Run 18.09. (Feedback): linksbuendig ohne Icon-Einrückung.
                    HStack(spacing: 0) {
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

// MARK: - B8: Tages-Popup (Run 18.09. final)
//
// Absolutes Koordinatensystem: Stundenlinien, Labels und Terminblöcke
// werden ALLE aus demselben minutes x hourHeight-Wert positioniert -
// keine VStack/HStack-Interaktion, dadurch exakte Ausrichtung.
// Überlappungs-Cluster: einzelne Termine volle Breite, kollidierende
// Termine teilen sich Spalten.

struct SouveraDayPreviewPopup: View {
    let day: Date
    let highlightEvent: CalendarEventModel
    let collidingEvent: CalendarEventModel
    let allEvents: [CalendarEventModel]
    let onDismiss: () -> Void

    private let hourHeight: CGFloat = 52
    private let labelWidth: CGFloat = 44

    private var hours: [Int] { Array(0..<24) }

    private var dayEvents: [CalendarEventModel] {
        allEvents
            .filter { Calendar.current.isDate($0.start, inSameDayAs: day) && !$0.allDay }
            .sorted { $0.start < $1.start }
    }

    /// Run 18.09. (Feedback): Überlappungs-CLUSTER - nur wirklich
    /// kollidierende Termine teilen Spalten; Einzeltermine volle Breite.
    private struct Cluster {
        var events: [CalendarEventModel] = []
        var columns: [[CalendarEventModel]] = []
        var end: Date = Date.distantPast
    }

    private var clusters: [Cluster] {
        var clusters: [Cluster] = []
        for event in dayEvents {
            if let last = clusters.last, event.start < last.end {
                // Kollision mit dem laufenden Cluster: Spalte finden.
                var cluster = last
                var placed = false
                for index in cluster.columns.indices {
                    if cluster.columns[index].allSatisfy({ $0.end <= event.start || event.end <= $0.start }) {
                        cluster.columns[index].append(event)
                        placed = true
                        break
                    }
                }
                if !placed { cluster.columns.append([event]) }
                cluster.events.append(event)
                cluster.end = max(cluster.end, event.end)
                clusters[clusters.count - 1] = cluster
            } else {
                clusters.append(Cluster(events: [event], columns: [[event]], end: event.end))
            }
        }
        return clusters
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
            card
                .padding(.horizontal, 28)
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack {
                Text(dayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button(NSLocalizedString("_done_", comment: "")) { onDismiss() }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    // Run 18.09.: ABSOLUTES Koordinatensystem - Grid und
                    // Blöcke aus derselben minutes -> y-Rechnung.
                    ZStack(alignment: .topLeading) {
                        // Stundenlinien + Labels
                        ForEach(hours, id: \.self) { hour in
                            let y = CGFloat(hour) * hourHeight
                            Text(String(format: "%02d:00", hour))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: labelWidth, alignment: .center)
                                .offset(y: y - 8)
                            Rectangle()
                                .fill(Color(.systemGray5))
                                .frame(height: 0.5)
                                .offset(y: y)
                                .padding(.leading, labelWidth + 8)
                                .id(y)
                        }
                        // Terminblöcke (clusterweise, volle Breite wenn
                        // solo) - Run 19.09.: .position mit explizitem
                        // ZENTRUM (mathematisch eindeutig, kein Offset-Drift).
                        ForEach(clusters.indices, id: \.self) { clusterIndex in
                            clusterBlocks(clusters[clusterIndex], clusterIndex: clusterIndex)
                        }
                    }
                    .frame(height: 24 * hourHeight)
                    .padding(.vertical, 8)
                }
                .onAppear {
                    // Run 19.09. (Feedback): Auto-Position auf den
                    // Einladungstermin, mit Retry nach dem Layout-Commit -
                    // danach ist freies Scrollen uneingeschraenkt.
                    let hour = Calendar.current.component(.hour, from: highlightEvent.start)
                    let target = CGFloat(max(0, hour - 1)) * hourHeight
                    for delay in [0.0, 0.15, 0.4] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(.systemGray4), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 18)
        .frame(maxHeight: 560)
    }

    /// Verfügbare Breite für die Blöcke (innen, nach Labelspalte).
    private var availableWidth: CGFloat {
        UIScreen.main.bounds.width - 56 - labelWidth - 8 - 12 - 12
    }

    private func offsetY(for event: CalendarEventModel) -> CGFloat {
        let startOfDay = Calendar.current.startOfDay(for: day)
        let minutes = Calendar.current.dateComponents([.minute],
                                                      from: startOfDay, to: event.start).minute ?? 0
        return CGFloat(minutes) / 60 * hourHeight
    }

    private func blockHeight(for event: CalendarEventModel) -> CGFloat {
        let minutes = event.end.timeIntervalSince(event.start) / 60
        return max(26, CGFloat(minutes) / 60 * hourHeight)
    }

    private func block(for event: CalendarEventModel) -> some View {
        let isInvite = event.href == highlightEvent.href
        let isCollision = event.href == collidingEvent.href
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let border: Color = isInvite ? .blue : (isCollision ? .orange : .clear)
        let fill: Color = isInvite ? Color.blue.opacity(0.10) : (isCollision ? Color.orange.opacity(0.12) : Color(.systemGray6))
        return VStack(alignment: .leading, spacing: 2) {
            if !event.allDay {
                Text("\(formatter.string(from: event.start)) – \(formatter.string(from: event.end))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(event.title)
                .font(.caption.weight(isInvite || isCollision ? .semibold : .regular))
                .lineLimit(2)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 7).fill(fill))
        // Schraffur AUSSCHLIESSLICH fuer unbeantwortete Einladungen.
        .overlay(
            SouveraHatchOverlay()
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .opacity(event.ownPartstat == "needs-action" ? 0.35 : 0)
        )
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(border, lineWidth: isInvite || isCollision ? 1.5 : 0))
    }

    private var dayTitle: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }

    // Run 19.09.: Cluster-Rendering ausgelagert (Typ-Checker).
    @ViewBuilder
    private func clusterBlocks(_ cluster: Cluster, clusterIndex: Int) -> some View {
        let columnCount = CGFloat(max(1, cluster.columns.count))
        ForEach(cluster.columns.indices, id: \.self) { columnIndex in
            ForEach(cluster.columns[columnIndex]) { event in
                let width = max(60, availableWidth / columnCount - (columnCount > 1 ? 6 : 0))
                let height = blockHeight(for: event)
                let y = offsetY(for: event)
                block(for: event)
                    .frame(width: width, height: height)
                    .position(
                        x: labelWidth + 8 + availableWidth / columnCount / 2
                            + CGFloat(columnIndex) * (availableWidth / columnCount),
                        y: y + height / 2)
            }
        }
    }
}

/// Schraffur-Overlay (diagonale Streifen) fuer offene Termine.
struct SouveraHatchOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let stride: CGFloat = 10
                var x: CGFloat = -size.height
                while x < size.width {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    context.stroke(path, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                    x += stride
                }
            }
        }
        .allowsHitTesting(false)
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
    /// Run 17.09. (Feedback): Vorschläge NUR Mo-Fr 08:00-17:00 Uhr, in
    /// der DAUER der Einladung; erste freie Lücken laut Kalenderstand.
    /// Manuelle Auswahl kommt über den DatePicker im Detail.
    static func proposals(for event: CalendarEventModel,
                          in all: [CalendarEventModel],
                          maxCount: Int = 3) -> [Date] {
        guard !event.allDay else { return [] }
        let duration = event.end.timeIntervalSince(event.start)
        guard duration > 0 else { return [] }
        let calendar = Calendar.current
        let busy: [(Date, Date)] = all.filter { !$0.allDay }.map { ($0.start, $0.end) }

        func isFree(_ start: Date, end: Date) -> Bool {
            !busy.contains { s, e in s < end && start < e }
        }

        var slots: [Date] = []
        var day = calendar.startOfDay(for: event.start)
        for _ in 0..<10 where slots.count < maxCount {
            // Werktag?
            if calendar.isDateInWeekend(day) {
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                continue
            }
            guard let windowStart = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day),
                  let windowEnd = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: day) else { continue }
            var candidate = max(windowStart, day == calendar.startOfDay(for: event.start) ? event.end : windowStart)
            while candidate.addingTimeInterval(duration) <= windowEnd, slots.count < maxCount {
                if isFree(candidate, end: candidate.addingTimeInterval(duration)) {
                    slots.append(candidate)
                    candidate = candidate.addingTimeInterval(duration)
                } else {
                    candidate = candidate.addingTimeInterval(900)
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return Array(slots.prefix(maxCount))
    }
}



// MARK: - Run 18.09.: Status-Anzeige in Vergangenheitsform

enum SouveraRSVPStatus {
    /// Vergangenheits-Label ("Angenommen") + Farbe + Icon je PARTSTAT.
    static func label(for partstat: String) -> (text: String, color: Color, icon: String)? {
        switch partstat {
        case "accepted":
            return (NSLocalizedString("_invitations_done_accepted_", comment: ""), .green, "checkmark.circle.fill")
        case "tentative":
            return (NSLocalizedString("_invitations_done_tentative_", comment: ""), .orange, "questionmark.circle.fill")
        case "declined":
            return (NSLocalizedString("_invitations_done_declined_", comment: ""), .red, "xmark.circle.fill")
        default:
            return nil
        }
    }
}
