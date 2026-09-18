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
                    // Run 19.09. (Feedback: Position exakt): Das gesamte
                    // Raster + alle Bloecke werden in EINEM Canvas
                    // gezeichnet - eine einzige Koordinatenquelle
                    // (Minuten x Hoehe/60), keine SwiftUI-Layout-Drift.
                    ZStack(alignment: .topLeading) {
                        Canvas { context, size in
                            drawDay(context: context, size: size)
                        }
                        .frame(height: 24 * hourHeight)
                        // Unsichtbarer Fokus-Anker fuer den Auto-Scroll.
                        Color.clear
                            .frame(width: 1, height: 1)
                            .padding(.top, focusY)
                            .id("focus")
                    }
                    .frame(height: 24 * hourHeight)
                }
                .onAppear {
                    // Run 19.09. (Feedback): Auto-Position auf den
                    // Einladungstermin - nach dem Layout-Commit, mit Retry;
                    // danach freies Scrollen ueber den ganzen Tag.
                    SouveraLog.write("PopupDay", "focusY=\(focusY) highlight=\(highlightEvent.title) start=\(highlightEvent.start)")
                    for delay in [0.0, 0.15, 0.4] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            proxy.scrollTo("focus", anchor: .top)
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

    // Run 19.09.: Y-Position des Fokus (Einladungsstart - 1 h).
    private var focusY: CGFloat {
        let target = highlightEvent.start.addingTimeInterval(-3600)
        return max(0, offsetYForDate(target))
    }

    private func offsetYForDate(_ date: Date) -> CGFloat {
        let startOfDay = Calendar.current.startOfDay(for: day)
        let minutes = Calendar.current.dateComponents([.minute], from: startOfDay, to: date).minute ?? 0
        return CGFloat(minutes) / 60 * hourHeight
    }

    /// Zeichnet Stundenraster + Terminbloecke exakt.
    private func drawDay(context: GraphicsContext, size: CGSize) {
        // Raster
        for hour in 0..<24 {
            let y = CGFloat(hour) * hourHeight
            let label = Text(String(format: "%02d:00", hour))
                .font(.caption2)
                .foregroundStyle(Color.secondary)
            context.draw(label, at: CGPoint(x: labelWidth / 2, y: y), anchor: .center)
            var line = Path()
            line.move(to: CGPoint(x: labelWidth + 8, y: y))
            line.addLine(to: CGPoint(x: size.width - 12, y: y))
            context.stroke(line, with: .color(Color(.systemGray5)), lineWidth: 0.5)
        }
        // Bloecke
        let usable = size.width - labelWidth - 8 - 24
        for cluster in clusters {
            let columnCount = max(1, cluster.columns.count)
            for (columnIndex, columnEvents) in cluster.columns.enumerated() {
                for event in columnEvents {
                    let spacing: CGFloat = columnCount > 1 ? 6 : 0
                    let colWidth = usable / CGFloat(columnCount)
                    let x = labelWidth + 8 + CGFloat(columnIndex) * colWidth
                    let width = colWidth - spacing
                    let y = offsetY(for: event)
                    let height = blockHeight(for: event)
                    let rect = CGRect(x: x, y: y, width: width, height: height)
                    let isInvite = event.href == highlightEvent.href
                    let isCollision = event.href == collisionHref
                    let path = Path(roundedRect: rect, cornerRadius: 7)
                    let fill: Color = isInvite ? Color.blue.opacity(0.10)
                        : (isCollision ? Color.orange.opacity(0.12) : Color(.systemGray6))
                    context.fill(path, with: .color(fill))
                    // Schraffur nur fuer unbeantwortete Einladungen
                    if event.ownPartstat == "needs-action",
                       !SouveraInvitationCenter.isAnswered(uid: event.uid) {
                        context.drawLayer { layer in
                            layer.clip(to: path)
                            var x0 = rect.minX - rect.height
                            while x0 < rect.maxX {
                                var hatch = Path()
                                hatch.move(to: CGPoint(x: x0, y: rect.maxY))
                                hatch.addLine(to: CGPoint(x: x0 + rect.height, y: rect.minY))
                                layer.stroke(hatch, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                                x0 += 10
                            }
                        }
                    }
                    let border: Color = isInvite ? .blue : (isCollision ? .orange : .clear)
                    if isInvite || isCollision {
                        context.stroke(path, with: .color(border), lineWidth: 1.5)
                    }
                    // Texte - Run 19.09. (Feedback): auf die Blockbreite
                    // begrenzt und in den Slot geclippt - kein Text mehr
                    // ausserhalb des farbigen Blocks.
                    context.drawLayer { layer in
                        layer.clip(to: path)
                        let timeFormatter = DateFormatter()
                        timeFormatter.dateStyle = .none
                        timeFormatter.timeStyle = .short
                        let innerWidth = rect.width - 12
                        // Run 19.09. (Feedback): Texte in der Blockbreite
                        // zeichnen - der layer.clip schneidet Überstände
                        // zuverlässig ab.
                        let timeText = Text("\(timeFormatter.string(from: event.start)) – \(timeFormatter.string(from: event.end))")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                        layer.draw(timeText, at: CGPoint(x: rect.minX + 6, y: rect.minY + 10), anchor: .topLeading)
                        let titleText = Text(event.title)
                            .font(.caption.weight(isInvite || isCollision ? .semibold : .regular))
                            .foregroundStyle(Color.primary)
                        layer.draw(titleText, at: CGPoint(x: rect.minX + 6, y: rect.minY + 24), anchor: .topLeading)
                    }
                }
            }
        }
    }

    private var collisionHref: String { collidingEvent.href }

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


    private var dayTitle: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: day)
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
        // Run 19.09. (Feedback): case-insensitiv - answeredRSVP.rawValue ist
        // GROSS ("ACCEPTED"), der Parser liefert klein ("accepted").
        switch partstat.lowercased() {
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
