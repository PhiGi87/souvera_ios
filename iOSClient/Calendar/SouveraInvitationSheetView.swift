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
    @State private var removedIds: Set<String> = []
    @State private var cancelRemoveId: String?

    var body: some View {
        NavigationStack {
            List {
                // Run 19.09. (Feedback): beantwortete Einladungen (PARTSTAT
                // != needs-action) erscheinen NICHT mehr in der Übersicht -
                // defensiv render-seitig gefiltert.
                let openCalendarInvites = center.calendarInvites.filter {
                    $0.ownPartstat == "needs-action"
                        && !SouveraInvitationCenter.isAnswered(uid: $0.uid)
                }
                if !openCalendarInvites.isEmpty {
                    Section(NSLocalizedString("_invitations_section_calendar_", comment: "")) {
                        ForEach(openCalendarInvites) { event in
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
        // Run 19.09. (Feedback: Zeiten erst nach Klick): Mail-Einladungen
        // ohne geparsten Termin beim Oeffnen im Hintergrund aufloesen,
        // damit von-bis sofort erscheint (Scan deckt mit dem Part-Fix den
        // Regelfall ab, dies ist der Fallback ohne ICS).
        .task {
            let unresolved = center.mailInvites.filter { $0.event == nil && !$0.resolved && !$0.isCancellation }
            for invite in unresolved.prefix(8) {
                _ = await SouveraInvitationCenter.shared.resolveInvitation(invite)
            }
        }
    }

    // MARK: - Zeilen

    private func rsvpButtons(id: String,
                             respond: @escaping (CalendarViewModel.CalendarRSVP) async -> Bool)
        -> some View {
        HStack(spacing: 8) {
            // Run 22.09. (Feedback: Reaktion erst spaet sichtbar): Waehrend
            // der Antwort laeuft ein Apple-typischer Ladekreis.
            if busyId == id {
                ProgressView()
                    .frame(width: 36, height: 36)
            } else {
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
                // Run 19.09. (Feedback): Entfernen auch hier per Button.
                if removedIds.contains(invite.id) {
                    Label(NSLocalizedString("_invitations_cancel_removed_", comment: ""),
                          systemImage: "trash.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        cancelRemoveId = invite.id
                        Task {
                            // Run 19.09. (Feedback Absage ohne ICS): aufloesen
                            // und entfernen in einem Pfad (Titel-Fallback).
                            let ok = await SouveraInvitationCenter.shared.removeCancelledMail(invite)
                            if ok {
                                removedIds.insert(invite.id)
                            }
                            cancelRemoveId = nil
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if cancelRemoveId == invite.id {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "trash")
                            }
                            Text(NSLocalizedString("_invitations_cancel_remove_", comment: ""))
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .disabled(cancelRemoveId != nil)
                }
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
    /// Wird nach dem Schliessen des Ergebnis-Popups gerufen - schliesst
    /// den gesamten Dialog.
    var onFinished: (() -> Void)? = nil
    /// Überschneidungsprüfungs-Basis (nil = keine Prüfung möglich).
    @State var overlapEvents: [CalendarEventModel] = []
    /// Run 18.09.: Liefert die Termine eines Tages on-demand (Mail-
    /// Direktdetail: Kalenderstand wird lazy geladen).
    var overlapProvider: ((Date) async -> [CalendarEventModel])? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    /// Run 19.09. (Feedback): gewaehlte Antwort merken - das Label zeigt
    /// das KORREKTE Icon/Farbe (gruen ✓ / orange ? / rot ✕).
    @State private var answeredRSVP: CalendarViewModel.CalendarRSVP?
    /// Run 19.09.: Erinnerungen (einheitliches Konzept, sofort gespeichert).
    @State private var reminderMinutes: [Int] = []
    @State private var remindersLoaded = false
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
    @State private var cancelNotFound = false
    /// Run 19.09. (Feedback): "nicht im Kalender" PERSISTENT merken -
    /// der Einladungs-Button/Entry bleibt dann dauerhaft ausgeblendet.
    private static let notInCalendarKey = "invitations_not_in_calendar_ids"
    private var isNotInCalendar: Bool {
        UserDefaults.standard.stringArray(forKey: Self.notInCalendarKey)?
            .contains(event.href) == true
    }
    /// Run 19.09. (Feedback): Ergebnis-Popup beim Entfernen.
    @State private var cancelResultAlert: String?

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

    /// Run 19.09. (Feedback): Dialog-Titel dynamisch - "Einladung"
    /// (unbeantwortet), "Termin" (beantwortet), "Absage" (CANCEL).
    private var detailTitle: String {
        if liveInvitation?.isCancellation == true {
            return NSLocalizedString("_invitations_cancel_title_", comment: "")
        }
        if SouveraRSVPStatus.label(for: displayEvent.ownPartstat) != nil
            || answeredRSVP != nil {
            return NSLocalizedString("_invitations_event_title_", comment: "")
        }
        return NSLocalizedString("_invitations_title_detail_", comment: "")
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
            .navigationTitle(Text(detailTitle))
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
                if !resolving, !remindersLoaded {
                    // Run 19.09.: Erinnerungen laden (Overrides gewinnen).
                    if let live = liveInvitation,
                       let override = SouveraInvitationCenter.reminderOverrides(live.id) {
                        reminderMinutes = override
                    } else {
                        reminderMinutes = displayEvent.reminders
                    }
                    remindersLoaded = true
                }
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
        // Run 19.09. (Feedback): Ergebnis-Popup; beim Schliessen schliesst
        // sich der gesamte Dialog.
        .alert(cancelResultAlert ?? "",
               isPresented: Binding(get: { cancelResultAlert != nil },
                                    set: { if !$0 { cancelResultAlert = nil; onFinished?() } })) {
            Button(NSLocalizedString("_done_", comment: "")) {
                cancelResultAlert = nil
                onFinished?()
            }
        }
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
        // Run 19.09. (Feedback): identisches Konzept wie im Termin-Edit;
        // jede Aenderung wird SOFORT gespeichert (PUT bei vorhandenem
        // Termin, sonst beim Anlegen angewandt).
        Section(NSLocalizedString("_calendar_reminders_", comment: "")) {
            ForEach(reminderMinutes.sorted(), id: \.self) { minutes in
                HStack {
                    Label(CalendarReminderText.label(minutes: minutes), systemImage: "bell")
                        .font(.subheadline)
                    Spacer()
                    Button {
                        var updated = reminderMinutes
                        updated.removeAll { $0 == minutes }
                        reminderMinutes = updated
                        Task {
                            _ = await SouveraInvitationCenter.shared.updateInvitationReminders(
                                liveInvitation ?? SouveraMailInvitation(
                                    id: event.href, messageId: event.href, accountId: "",
                                    subject: event.title, from: event.organizerEmail,
                                    organizerEmail: event.organizerEmail,
                                    event: event, rawICS: nil, resolved: true,
                                    receivedAt: Date()),
                                minutes: updated)
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            Menu {
                ForEach(CalendarReminderText.presets, id: \.self) { minutes in
                    Button(CalendarReminderText.label(minutes: minutes)) {
                        guard !reminderMinutes.contains(minutes) else { return }
                        var updated = reminderMinutes
                        updated.append(minutes)
                        reminderMinutes = updated
                        Task {
                            _ = await SouveraInvitationCenter.shared.updateInvitationReminders(
                                liveInvitation ?? SouveraMailInvitation(
                                    id: event.href, messageId: event.href, accountId: "",
                                    subject: event.title, from: event.organizerEmail,
                                    organizerEmail: event.organizerEmail,
                                    event: event, rawICS: nil, resolved: true,
                                    receivedAt: Date()),
                                minutes: updated)
                        }
                    }
                }
            } label: {
                Label(NSLocalizedString("_calendar_reminder_add_", comment: ""), systemImage: "plus.bell")
            }
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
                    // Run 19.09.: Deck-Boards ausschliessen (VEVENT- Create
                    // gegen ein VTODO-Board schlaegt mit 415 fehl).
                    ForEach(calendars.filter { $0.canWrite && !$0.href.contains("app-generated--deck") }, id: \.href) { calendar in
                        Text(calendar.displayName).tag(calendar.href as String?)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var cancelSection: some View {
        Section {
            if cancelRemoved || isNotInCalendar {
                Label(NSLocalizedString("_invitations_cancel_removed_", comment: ""),
                      systemImage: "trash.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else if cancelNotFound {
                Label(NSLocalizedString("_invitations_cancel_not_found_", comment: ""),
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                Button {
                    cancelBusy = true
                    Task {
                        // Run 19.09. (Feedback Absage ohne ICS): zuerst die
                        // echte Mail-Absage aufloesen (UID/ICS per Lazy-
                        // Fetch) - sonst blieb "kein Match".
                        let liveInvite = SouveraInvitationCenter.shared.mailInvites
                            .first(where: { $0.id == event.href })
                        // Run 19.09. (Feedback): echtes "nicht gefunden" vs.
                        // Fehler (412/Netz) unterscheiden - nur bei ersterem
                        // dauerhaft quittieren.
                        var handled = false
                        if let liveInvite {
                            handled = await SouveraInvitationCenter.shared.removeCancelledMail(liveInvite)
                        } else {
                            switch await SouveraInvitationCenter.shared.removeCancelledEvent(
                                uid: displayEvent.uid,
                                title: displayEvent.title,
                                start: displayEvent.start,
                                end: displayEvent.end) {
                            case .removed, .notFound: handled = true
                            case .failed: handled = false
                            }
                        }
                        cancelBusy = false
                        var notFound = Set(UserDefaults.standard.stringArray(
                            forKey: Self.notInCalendarKey) ?? [])
                        if handled {
                            cancelRemoved = true
                            notFound.remove(event.href)
                            UserDefaults.standard.set(Array(notFound), forKey: Self.notInCalendarKey)
                            SouveraInvitationCenter.markAnswered(
                                messageId: displayEvent.href, eventEnd: displayEvent.end)
                            SouveraInvitationCenter.shared.removeMailInvitation(event.href)
                            // Run 19.09.: Absage-Mail serverseitig in den
                            // Papierkorb (alle Geräte).
                            Task { await SouveraInviteMailSender.shared.moveToTrash(messageId: displayEvent.href) }
                            // Run 19.09. (Feedback): Ergebnis-Popup.
                            cancelResultAlert = NSLocalizedString("_invitations_cancel_removed_", comment: "")
                        } else {
                            // Echter Fehler: Zeile BEHALTEN, Fehler zeigen,
                            // NICHT dauerhaft als "nicht im Kalender" merken.
                            cancelResultAlert = NSLocalizedString("_error_occurred_", comment: "")
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
            if let answeredRSVP {
                // Run 19.09. (Feedback): korrektes Icon/Farbe je Antwort.
                let status = SouveraRSVPStatus.label(for: answeredRSVP.rawValue)
                Label(status?.text ?? "", systemImage: status?.icon ?? "checkmark.circle.fill")
                    .foregroundStyle(status?.color ?? .green)
                    .font(.subheadline.weight(.medium))
            } else if declineProposalMode {
                declineProposalView
            } else if let respond {
                if let status = SouveraRSVPStatus.label(for: displayEvent.ownPartstat) {
                    // Run 18.09. (Feedback): beantwortet -> Status-Label in
                    // Vergangenheitsform mit Farbe/Icon.
                    Label(status.text, systemImage: status.icon)
                        .foregroundStyle(status.color)
                        .font(.subheadline.weight(.medium))
                } else if busy {
                    // Run 22.09. (Feedback: Reaktion erst spaet sichtbar):
                    // Ladekreis waehrend der Antwort (Apple-Stil).
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(NSLocalizedString("_invitations_loading_", comment: ""))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
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
            let ok = await respond(rsvp, nil, nil, selectedCalendarHref)
            busy = false
            if ok == true {
                answeredRSVP = rsvp
            }
        }
    }

    private func sendDecline(proposalText: String?) {
        guard let respond else { return }
        busy = true
        Task {
            let ok = await respond(.declined, nil, proposalText, selectedCalendarHref)
            busy = false
            if ok == true {
                answeredRSVP = .declined
                declineProposalMode = false
                // Run 19.09. (Feedback): Ablehnung entfernt den Termin -
                // Ergebnis-Popup, Schliessen beendet den Dialog.
                cancelResultAlert = NSLocalizedString("_invitations_declined_removed_", comment: "")
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
