// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Einladungs-Sheet: offene Kalender- und Mail-Einladungen mit
// Annehmen / Vielleicht / Ablehnen. Kalender-Antworten schreiben die
// PARTSTAT per CalDAV-PUT, Mail-Antworten senden eine iTIP-REPLY-Mail.
import SwiftUI

struct SouveraInvitationSheetView: View {
    @ObservedObject var center: SouveraInvitationCenter
    let respondCalendar: (CalendarEventModel, CalendarViewModel.CalendarRSVP) async -> Bool
    let respondMail: (SouveraMailInvitation, CalendarViewModel.CalendarRSVP) async -> Bool
    @Environment(\.dismiss) private var dismiss
    /// false im Kalender-Kontext: Mail-Einladungen koennen hier nicht
    /// beantwortet werden (kein Mail-Client) - Hinweis statt Buttons.
    var mailInteractionEnabled = true
    /// Run 16.09.: Tap auf die Zeile oeffnet die Termin-Detailansicht
    /// (Ueberschneidungen etc. pruefen, dort auch antworten).
    var onOpenCalendarEvent: (CalendarEventModel) -> Void = { _ in }
    var onOpenMailInvite: (SouveraMailInvitation) -> Void = { _ in }

    @State private var busyId: String?
    @State private var processedIds: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                if !center.calendarInvites.isEmpty {
                    Section(NSLocalizedString("_invitations_section_calendar_", comment: "")) {
                        ForEach(center.calendarInvites) { event in
                            calendarRow(event)
                        }
                    }
                }
                if !center.mailInvites.isEmpty {
                    Section(NSLocalizedString("_invitations_section_mail_", comment: "")) {
                        ForEach(center.mailInvites) { invite in
                            mailRow(invite)
                        }
                    }
                }
                if center.calendarInvites.isEmpty && center.mailInvites.isEmpty {
                    Section {
                        Text(NSLocalizedString("_invitations_none_", comment: ""))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(Text(NSLocalizedString("_invitations_title_", comment: "")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("_done_", comment: "")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.light)
    }

    // MARK: - Zeilen

    private func rsvpButtons(id: String,
                             respond: @escaping (CalendarViewModel.CalendarRSVP) async -> Bool)
        -> some View {
        HStack(spacing: 8) {
            ForEach(CalendarViewModel.CalendarRSVP.allCases, id: \.rawValue) { rsvp in
                Button {
                    busyId = id
                    Task {
                        let ok = await respond(rsvp)
                        if ok { processedIds.insert(id) }
                        busyId = nil
                    }
                } label: {
                    // Run 18.09. (Feedback): kompakte Icon-Kreise.
                    Image(systemName: rsvp.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(rsvp.color)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(rsvp.color.opacity(0.14)))
                }
                .buttonStyle(.borderless)
                .disabled(busyId == id)
                .accessibilityLabel(Text(NSLocalizedString(rsvp.titleKey, comment: "")))
            }
        }
    }

    @ViewBuilder
    private func calendarRow(_ event: CalendarEventModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.title).font(.headline)
            Text(organizerLine(event.organizerName, event.organizerEmail))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(timeLine(event))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if overlapHint(event) {
                Text(NSLocalizedString("_invitations_overlap_header_", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if processedIds.contains(event.href) {
                Text(NSLocalizedString("_invitations_answered_", comment: ""))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                HStack {
                    rsvpButtons(id: event.href) { rsvp in
                        await respondCalendar(event, rsvp)
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { onOpenCalendarEvent(event) }
    }

    @ViewBuilder
    private func mailRow(_ invite: SouveraMailInvitation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(invite.displayTitle).font(.headline)
            Text(organizerLine("", invite.displayOrganizer))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let event = invite.event {
                Text(timeLine(event))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if overlapHint(event) {
                    Text(NSLocalizedString("_invitations_overlap_header_", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if invite.isCancellation {
                // Run 18.09.: Absage -> manuell entfernen (im Detail).
                Text(NSLocalizedString("_invitations_cancelled_", comment: ""))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            } else if processedIds.contains(invite.id) {
                Text(NSLocalizedString("_invitations_answered_", comment: ""))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else if mailInteractionEnabled {
                HStack {
                    rsvpButtons(id: invite.id) { rsvp in
                        await respondMail(invite, rsvp)
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { onOpenMailInvite(invite) }
    }

    // MARK: - Helfer

    private func organizerLine(_ name: String, _ email: String) -> String {
        let organizerPrefix = NSLocalizedString("_invitations_organizer_", comment: "")
        if !name.isEmpty { return "\(organizerPrefix): \(name)" }
        if !email.isEmpty { return "\(organizerPrefix): \(email)" }
        return organizerPrefix
    }

    private func timeLine(_ event: CalendarEventModel) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = event.allDay ? .none : .short
        if event.allDay {
            return DateFormatter.localizedString(
                from: event.start, dateStyle: .medium, timeStyle: .none)
        }
        return "\(formatter.string(from: event.start)) – \(formatter.string(from: event.end))"
    }

    /// true, wenn der Termin zeitlich mit einem anderen Termin im
    /// geladenen Fenster kollidiert (Grob-Heuristik wie besprochen).
    private func overlapHint(_ event: CalendarEventModel) -> Bool {
        // Run 17.09.: zentraler Rechner (inkl. invalide Zeiträume-Filter).
        return !SouveraOverlapCalculator.overlaps(of: event, in: center.calendarInvites).isEmpty
    }
}


// Run 16.09.: Termin-Detailansicht einer Einladung - zeigt alle Details
// (Zeit, Organisator, Teilnehmer, Ueberschneidung) und direkt die
// RSVP-Buttons. `respond` liefert nil, wenn Antworten in diesem Kontext
// nicht moeglich ist (z. B. Mail-Einladung ohne Mail-Client).
// Run 16.09.: Termin-Detailansicht einer Einladung - alle Details
// (Zeit, Organisator, Teilnehmer), Überschneidungsliste mit Tages-Popup
// (B7/B8), Erinnerungs-Editor (B4), zustandsabhängiges RSVP (B6) und
// optionaler Alternativvorschlag beim Ablehnen (B9).
struct SouveraInvitationDetailView: View {
    @ObservedObject var center: SouveraInvitationCenter = .shared
    let event: CalendarEventModel
    let organizerFallback: String
    /// nil = Antworten hier nicht moeglich (Hinweis statt Buttons).
    let respond: ((CalendarViewModel.CalendarRSVP, [Int]?, String?, String?) async -> Bool?)?
    /// Run 18.09. (Feedback): Zurueck-Button oben links, wenn aus der
    /// Einladungs-Übersicht geöffnet.
    var onBack: (() -> Void)? = nil
    /// Überschneidungsprüfungs-Basis (nil = keine Prüfung möglich).
    @State var overlapEvents: [CalendarEventModel] = []
    /// Run 18.09.: Liefert die Termine eines Tages on-demand (Mail-
    /// Direktdetail: Kalenderstand wird lazy geladen).
    var overlapProvider: ((Date) async -> [CalendarEventModel])? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var answeredText: String?
    @State private var reminderMinutes: [Int] = [15]
    @State private var remindersTouched = false
    @State private var dayPreview: SouveraOverlap?
    @State private var declineProposalMode = false
    @State private var altProposalStart: Date = {
        // Run 18.09.: naechste volle Stunde, Ende +30 min.
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: Date())
        let base = (components.minute ?? 0) == 0
            ? Date()
            : calendar.date(byAdding: .minute, value: 60 - (components.minute ?? 0), to: Date()) ?? Date()
        return base
    }()
    @State private var altProposalEnd: Date = {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: Date())
        let base = (components.minute ?? 0) == 0
            ? Date()
            : calendar.date(byAdding: .minute, value: 60 - (components.minute ?? 0), to: Date()) ?? Date()
        return base.addingTimeInterval(1800)
    }()
    /// Run 17.09.: Kalender-Auswahl pro Einladung (Default: persoenlich).
    @State private var calendars: [CalDavCalendar] = []
    @State private var selectedCalendarHref: String?
    /// Run 17.09. (3.2): kein Zeitslot erkannt -> manuell setzbar.
    @State private var manualStart: Date = Date()
    @State private var manualEnd: Date = Date().addingTimeInterval(1800)
    @State private var manualTimesSet = false
    @State private var showManualProposal = false

    /// Eigene Rollen-Optionen je nach bisherigem PARTSTAT (B6).
    private var allowedOptions: [CalendarViewModel.CalendarRSVP] {
        switch event.ownPartstat {
        case "accepted": return [.tentative, .declined]
        case "tentative": return [.accepted, .declined]
        case "declined": return [.accepted, .tentative]
        default: return CalendarViewModel.CalendarRSVP.allCases
        }
    }

    /// Der Zeitslot - manuell ueberschreibbar (3.2); Live-Stand aus dem
    /// Center (setManualTimes aktualisiert die Einladung dort).
    /// Run 18.09.: CANCEL - Absage durch den Organisator: Entfernen-Button.
    @State private var cancelRemoved = false
    @State private var cancelBusy = false

    private var effectiveEvent: CalendarEventModel {
        center.mailInvites.first(where: { $0.id == event.href })?.event ?? event
    }

    private var currentStatusKey: String? {
        switch event.ownPartstat {
        case "accepted": return "_invitations_accept_"
        case "tentative": return "_invitations_tentative_"
        case "declined": return "_invitations_decline_"
        default: return nil
        }
    }

    /// Run 18.09. (Feedback): Live-Stand aus dem Center - NIE der beim
    /// Oeffnen eingefrorene Snapshot. Solange die Aufloesung laeuft,
    /// erscheint eine Warteuhr (Spinner) statt Fantasie-Daten.
    private var liveInvitation: SouveraMailInvitation? {
        center.mailInvites.first(where: { $0.id == event.href })
    }

    private var isResolving: Bool {
        guard let live = liveInvitation else { return false }
        return !live.resolved && live.event == nil
    }

    private var isCancellation: Bool {
        liveInvitation?.isCancellation == true
    }

    private var displayEvent: CalendarEventModel {
        effectiveEvent
    }

    /// Run 18.09.: vorkompiliert - der body-Ausdruck war zu komplex.
    private var hasOverlaps: Bool {
        !SouveraOverlapCalculator.overlaps(of: displayEvent, in: overlapEvents).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                titleSection
                whenSection
                organizerSection
                if !isResolving, hasOverlaps {
                    overlapSection
                }
                if !isResolving, !displayEvent.attendees.isEmpty {
                    attendeesSection
                }
                reminderSection
                calendarSection
                if isCancellation {
                    cancelSection
                } else {
                    rsvpSection
                }
            }
            .navigationTitle(Text(NSLocalizedString("_invitations_title_", comment: "")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if onBack != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            onBack?()
                        } label: {
                            Label(NSLocalizedString("_back_", comment: ""), systemImage: "chevron.backward")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("_done_", comment: "")) { dismiss() }
                }
            }
            .onChange(of: isResolving) { _, resolving in
                // Run 18.09.: Nach dem Resolve die Überschneidungsbasis
                // (Mail-Direktdetail: Kalender-Tag lazy) nachladen.
                if !resolving, let overlapProvider {
                    Task {
                        overlapEvents = await overlapProvider(displayEvent.start)
                    }
                }
            }
            .onAppear {
                Task {
                    if let overlapProvider {
                        overlapEvents = await overlapProvider(displayEvent.start)
                    }
                    let client = CalDavClient(account: nil)
                    let fetched = await client.fetchCalendars()
                    calendars = fetched
                    if selectedCalendarHref == nil {
                        selectedCalendarHref = (fetched.first(where: { $0.canWrite && $0.isPersonal })
                            ?? fetched.first(where: { $0.canWrite }))?.href
                    }
                }
            }
        }
        .preferredColorScheme(.light)
        // Run 17.09. (Feedback): echtes Popup-Overlay statt Sheet.
        .overlay {
            if let overlap = dayPreview {
                SouveraDayPreviewPopup(
                    day: overlap.event.start,
                    highlightEvent: displayEvent,
                    collidingEvent: overlap.event,
                    allEvents: overlapEvents + [displayEvent],
                    onDismiss: { dayPreview = nil })
            }
        }
    }

    // Run 18.09.: body in kleine Sektionen zerlegt (Typ-Checker).

    @ViewBuilder
    private var titleSection: some View {
        Section {
            if isResolving {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(NSLocalizedString("_invitations_loading_", comment: ""))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(displayEvent.title).font(.title3).fontWeight(.semibold)
            }
        }
    }

    @ViewBuilder
    private var whenSection: some View {
        Section(NSLocalizedString("_calendar_when_", comment: "")) {
            if isResolving {
                ProgressView()
            } else if let answered = SouveraRSVPStatus.label(for: displayEvent.ownPartstat) {
                // Nach Beantwortung ist der Zeitslot NICHT mehr editierbar.
                Label(answered.text, systemImage: answered.icon)
                    .foregroundStyle(answered.color)
                    .font(.subheadline.weight(.medium))
            } else if displayEvent.uid.isEmpty {
                // 3.2: kein Zeitslot erkannt -> manuell setzen.
                DatePicker(NSLocalizedString("_calendar_start_", comment: ""),
                           selection: $manualStart,
                           displayedComponents: [.date, .hourAndMinute])
                DatePicker(NSLocalizedString("_calendar_end_", comment: ""),
                           selection: $manualEnd,
                           in: manualStart...,
                           displayedComponents: [.date, .hourAndMinute])
                    .onChange(of: manualEnd) { _, newValue in
                        manualTimesSet = true
                        SouveraInvitationCenter.shared.setManualTimes(
                            inviteId: event.href,
                            title: event.title,
                            start: manualStart, end: max(newValue, manualStart.addingTimeInterval(300)),
                            organizerEmail: event.organizerEmail)
                    }
                    .onChange(of: manualStart) { _, newValue in
                        SouveraInvitationCenter.shared.setManualTimes(
                            inviteId: event.href,
                            title: event.title,
                            start: newValue, end: max(manualEnd, newValue.addingTimeInterval(300)),
                            organizerEmail: event.organizerEmail)
                    }
            } else {
                Text(timeLine)
            }
        }
    }

    @ViewBuilder
    private var organizerSection: some View {
        Section(NSLocalizedString("_invitations_organizer_", comment: "")) {
            if isResolving {
                ProgressView()
            } else {
                let organizerText = displayEvent.organizerName.isEmpty
                    ? (displayEvent.organizerEmail.isEmpty ? organizerFallback : displayEvent.organizerEmail)
                    : displayEvent.organizerName
                Text(organizerText)
            }
        }
    }

    @ViewBuilder
    private var overlapSection: some View {
        Section(NSLocalizedString("_invitations_overlap_header_", comment: "")) {
            SouveraOverlapListView(event: displayEvent, allEvents: overlapEvents) { overlap in
                dayPreview = overlap
            }
        }
    }

    @ViewBuilder
    private var attendeesSection: some View {
        Section(NSLocalizedString("_calendar_attendees_", comment: "")) {
            ForEach(displayEvent.attendees, id: \.self) { attendee in
                Text(attendee).font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private var reminderSection: some View {
        Section(NSLocalizedString("_calendar_reminders_", comment: "")) {
            SouveraReminderEditor(minutes: $reminderMinutes)
                .onChange(of: reminderMinutes) { _, _ in remindersTouched = true }
        }
    }

    @ViewBuilder
    private var calendarSection: some View {
        Section(NSLocalizedString("_calendar_", comment: "")) {
            if calendars.isEmpty {
                Text(NSLocalizedString("_loading_", comment: ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Picker(NSLocalizedString("_calendar_", comment: ""),
                       selection: $selectedCalendarHref) {
                    ForEach(calendars.filter { $0.canWrite }, id: \.href) { calendar in
                        Text(calendar.displayName).tag(calendar.href as String?)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var cancelSection: some View {
        Section {
            if cancelRemoved {
                Label(NSLocalizedString("_invitations_cancel_removed_", comment: ""),
                      systemImage: "trash.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                Button {
                    cancelBusy = true
                    Task {
                        let ok = await SouveraInvitationCenter.shared.removeCancelledEvent(
                            uid: displayEvent.uid,
                            title: displayEvent.title,
                            start: displayEvent.start,
                            end: displayEvent.end)
                        cancelBusy = false
                        if ok {
                            cancelRemoved = true
                            SouveraInvitationCenter.markAnswered(messageId: displayEvent.href)
                            SouveraInvitationCenter.shared.removeMailInvitation(event.href)
                        }
                    }
                } label: {
                    Label(NSLocalizedString("_invitations_cancel_remove_", comment: ""),
                          systemImage: "trash")
                        .foregroundStyle(.red)
                }
                .disabled(cancelBusy)
            }
        } header: {
            Text(NSLocalizedString("_invitations_cancelled_", comment: ""))
        }
    }

    @ViewBuilder
    private var rsvpSection: some View {
        Section {
            if let answeredText {
                Label(answeredText, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if declineProposalMode {
                declineProposalView
            } else if let respond {
                if let status = SouveraRSVPStatus.label(for: displayEvent.ownPartstat) {
                    // Run 18.09. (Feedback): beantwortet -> Status-Label in
                    // Vergangenheitsform mit Farbe/Icon.
                    Label(status.text, systemImage: status.icon)
                        .foregroundStyle(status.color)
                        .font(.subheadline.weight(.medium))
                } else {
                HStack(spacing: 12) {
                    ForEach(allowedOptions, id: \.rawValue) { rsvp in
                        Button {
                            handle(rsvp, respond: respond)
                        } label: {
                            // Run 18.09. (Feedback): kompakte Icon-Kreise.
                            Image(systemName: rsvp.icon)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(rsvp.color)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(rsvp.color.opacity(0.14)))
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                    }
                    }
                }
            } else {
                Text(NSLocalizedString("_invitations_answer_in_mail_", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(NSLocalizedString("_invitations_rsvp_", comment: ""))
        } footer: {
            if !overlapEvents.isEmpty,
               !SouveraOverlapCalculator.overlaps(of: event, in: overlapEvents).isEmpty {
                Label(NSLocalizedString("_invitations_overlap_header_", comment: ""), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }

    /// B9: Alternativvorschlag beim Ablehnen - optional, Slots in der
    /// DAUER der Einladung.
    @ViewBuilder
    private var declineProposalView: some View {
        // Run 18.09. (Feedback): KEINE automatischen Vorschläge mehr -
        // optionaler manueller Zeitslot (nur bei Touch eingeblendet),
        // darunter ein einziger "Senden"-Button. Ohne Angabe wird ohne
        // Vorschlag gesendet.
        Button {
            withAnimation { showManualProposal.toggle() }
        } label: {
            Label(NSLocalizedString("_invitations_add_proposal_", comment: ""),
                  systemImage: showManualProposal ? "minus.circle" : "plus.circle")
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.borderless)
        if showManualProposal {
            // Run 18.09. (Feedback): Start UND Ende auswaehlbar; Start
            // default = naechste volle Stunde, Ende mind. +30 min.
            DatePicker(NSLocalizedString("_calendar_start_", comment: ""),
                       selection: $altProposalStart,
                       in: Date()...,
                       displayedComponents: [.date, .hourAndMinute])
                .font(.subheadline)
                .onChange(of: altProposalStart) { _, newValue in
                    // Start auf volle Stunde gerundet + Ende mind. 30 min.
                    let calendar = Calendar.current
                    let components = calendar.dateComponents([.hour, .minute], from: newValue)
                    let rounded = (components.minute ?? 0) == 0
                        ? newValue
                        : calendar.date(byAdding: .minute, value: 60 - (components.minute ?? 0), to: newValue) ?? newValue
                    if rounded != altProposalStart {
                        altProposalStart = rounded
                        if altProposalEnd < rounded.addingTimeInterval(1800) {
                            altProposalEnd = rounded.addingTimeInterval(1800)
                        }
                    }
                }
            DatePicker(NSLocalizedString("_calendar_end_", comment: ""),
                       selection: $altProposalEnd,
                       in: altProposalStart.addingTimeInterval(1800)...,
                       displayedComponents: [.date, .hourAndMinute])
                .font(.subheadline)
        }
        Button {
            // Proposal nur senden, wenn Start+Ende gesetzt.
            let proposal: String? = showManualProposal ? Self.proposalText(
                start: altProposalStart, end: altProposalEnd) : nil
            sendDecline(proposalText: proposal)
        } label: {
            Text(NSLocalizedString("_invitations_send_", comment: ""))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy)
    }

    private static func proposalText(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let endFormatter = DateFormatter()
        endFormatter.dateStyle = .none
        endFormatter.timeStyle = .short
        return "\(formatter.string(from: start)) – \(endFormatter.string(from: end))"
    }

    private func slotText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func handle(_ rsvp: CalendarViewModel.CalendarRSVP,
                        respond: @escaping (CalendarViewModel.CalendarRSVP, [Int]?, String?, String?) async -> Bool?) {
        if rsvp == .declined {
            // B9: erst der optionale Alternativvorschlag.
            declineProposalMode = true
            return
        }
        busy = true
        Task {
            let reminders = remindersTouched ? reminderMinutes : nil
            let ok = await respond(rsvp, reminders, nil, selectedCalendarHref)
            busy = false
            if ok == true {
                answeredText = NSLocalizedString(rsvp.titleKey, comment: "")
            }
        }
    }

    private func sendDecline(proposalText: String?) {
        guard let respond else { return }
        busy = true
        Task {
            let reminders = remindersTouched ? reminderMinutes : nil
            let ok = await respond(.declined, reminders, proposalText, selectedCalendarHref)
            busy = false
            if ok == true {
                answeredText = NSLocalizedString("_invitations_decline_", comment: "")
                declineProposalMode = false
            }
        }
    }

    private var timeLine: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = event.allDay ? .none : .short
        if event.allDay {
            return DateFormatter.localizedString(from: event.start, dateStyle: .medium, timeStyle: .none)
        }
        let endFormatter = DateFormatter()
        endFormatter.dateStyle = .none
        endFormatter.timeStyle = .short
        return "\(formatter.string(from: event.start)) – \(endFormatter.string(from: event.end))"
    }
}
