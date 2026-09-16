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
                    Label(NSLocalizedString(rsvp.titleKey, comment: ""), systemImage: rsvp.icon)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(rsvp.color)
                        .frame(width: 34, height: 34)
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
                Text(NSLocalizedString("_invitations_overlap_", comment: ""))
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
                    Text(NSLocalizedString("_invitations_overlap_", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text(NSLocalizedString("_invitations_no_ics_hint_", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if processedIds.contains(invite.id) {
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
            } else {
                Text(NSLocalizedString("_invitations_answer_in_mail_", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        guard !event.allDay else { return false }
        return center.calendarInvites.contains { other in
            other.href != event.href
                && !other.allDay
                && other.start < event.end && event.start < other.end
        }
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
    let event: CalendarEventModel
    let organizerFallback: String
    /// nil = Antworten hier nicht moeglich (Hinweis statt Buttons).
    let respond: (CalendarViewModel.CalendarRSVP, [Int]?, String?) async -> Bool?
    /// Überschneidungsprüfungs-Basis (nil = keine Prüfung möglich).
    var overlapEvents: [CalendarEventModel] = []

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var answeredText: String?
    @State private var reminderMinutes: [Int] = [15]
    @State private var remindersTouched = false
    @State private var dayPreview: SouveraOverlap?
    @State private var declineProposalMode = false
    @State private var altProposalDate: Date?

    /// Eigene Rollen-Optionen je nach bisherigem PARTSTAT (B6).
    private var allowedOptions: [CalendarViewModel.CalendarRSVP] {
        switch event.ownPartstat {
        case "accepted": return [.tentative, .declined]
        case "tentative": return [.accepted, .declined]
        case "declined": return [.accepted, .tentative]
        default: return CalendarViewModel.CalendarRSVP.allCases
        }
    }

    private var currentStatusKey: String? {
        switch event.ownPartstat {
        case "accepted": return "_invitations_accept_"
        case "tentative": return "_invitations_tentative_"
        case "declined": return "_invitations_decline_"
        default: return nil
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(event.title).font(.title3).fontWeight(.semibold)
                }
                Section(NSLocalizedString("_calendar_when_", comment: "")) {
                    Text(timeLine)
                }
                Section(NSLocalizedString("_invitations_organizer_", comment: "")) {
                    Text(event.organizerName.isEmpty
                         ? (event.organizerEmail.isEmpty ? organizerFallback : event.organizerEmail)
                         : event.organizerName)
                }
                if !overlapEvents.isEmpty {
                    Section(NSLocalizedString("_invitations_overlap_", comment: "")) {
                        SouveraOverlapListView(event: event, allEvents: overlapEvents) { overlap in
                            dayPreview = overlap
                        }
                    }
                }
                if !event.attendees.isEmpty {
                    Section(NSLocalizedString("_calendar_attendees_", comment: "")) {
                        ForEach(event.attendees, id: \.self) { attendee in
                            Text(attendee).font(.subheadline)
                        }
                    }
                }
                // B4: Eigene Erinnerungen (Standard 15 min).
                Section(NSLocalizedString("_calendar_reminders_", comment: "")) {
                    SouveraReminderEditor(minutes: $reminderMinutes)
                        .onChange(of: reminderMinutes) { _, _ in remindersTouched = true }
                }
                rsvpSection
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
        .sheet(item: $dayPreview) { overlap in
            SouveraDayPreviewPopup(
                day: overlap.event.start,
                highlightEvent: event,
                collidingEvent: overlap.event,
                allEvents: overlapEvents,
                onDismiss: { dayPreview = nil })
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
            } else if respond != nil {
                if let key = currentStatusKey {
                    Label(NSLocalizedString(key, comment: ""), systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                HStack(spacing: 10) {
                    ForEach(allowedOptions, id: \.rawValue) { rsvp in
                        Button {
                            handle(rsvp, respond: respond)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: rsvp.icon)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(rsvp.color)
                                Text(NSLocalizedString(rsvp.titleKey, comment: ""))
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy)
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
                Label(NSLocalizedString("_invitations_overlap_", comment: ""), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }

    /// B9: Alternativvorschlag beim Ablehnen - optional, Slots in der
    /// DAUER der Einladung.
    @ViewBuilder
    private var declineProposalView: some View {
        let slots = SouveraAltProposal.proposals(for: event, in: overlapEvents)
        Text(NSLocalizedString("_invitations_propose_alternative_", comment: ""))
            .font(.subheadline)
        if !slots.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(slots, id: \.timeIntervalSince1970) { slot in
                        Button {
                            altProposalDate = slot
                        } label: {
                            Text(slotText(slot))
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(
                                    altProposalDate == slot ? Color.blue : Color(.systemGray5)))
                                .foregroundStyle(altProposalDate == slot ? .white : .primary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        HStack(spacing: 10) {
            Button {
                sendDecline(proposal: altProposalDate)
            } label: {
                Text(NSLocalizedString("_invitations_send_", comment: ""))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button {
                // B9: ausdrücklich ohne Vorschlag ablehnen.
                sendDecline(proposal: nil)
            } label: {
                Text(NSLocalizedString("_invitations_no_proposal_", comment: ""))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func slotText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func handle(_ rsvp: CalendarViewModel.CalendarRSVP,
                        respond: (CalendarViewModel.CalendarRSVP, [Int]?, String?) async -> Bool?) {
        if rsvp == .declined {
            // B9: erst der optionale Alternativvorschlag.
            declineProposalMode = true
            return
        }
        busy = true
        Task {
            let reminders = remindersTouched ? reminderMinutes : nil
            let ok = await respond(rsvp, reminders, nil)
            busy = false
            if ok == true {
                answeredText = NSLocalizedString(rsvp.titleKey, comment: "")
            }
        }
    }

    private func sendDecline(proposal: Date?) {
        busy = true
        let proposalText: String?
        if let proposal {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            let duration = event.end.timeIntervalSince(event.start)
            let end = proposal.addingTimeInterval(duration)
            let endFormatter = DateFormatter()
            endFormatter.dateStyle = .none
            endFormatter.timeStyle = .short
            proposalText = "\(formatter.string(from: proposal)) – \(endFormatter.string(from: end))"
        } else {
            proposalText = nil
        }
        Task {
            let reminders = remindersTouched ? reminderMinutes : nil
            let ok = await respond(.declined, reminders, proposalText)
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
