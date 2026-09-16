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
struct SouveraInvitationDetailView: View {
    let event: CalendarEventModel
    let organizerFallback: String
    /// nil = Antworten hier nicht moeglich (Hinweis statt Buttons).
    let respond: (CalendarViewModel.CalendarRSVP) async -> Bool?
    /// Ueberschneidungspruefung gegen den geladenen Kalenderstand
    /// (nil = keine Pruefung moeglich, z. B. im Mail-Modul).
    var overlapCheck: ((CalendarEventModel) -> Bool)? = nil
    var answerInMailHint: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var answeredText: String?

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
                if let overlapCheck, overlapCheck(event) {
                    Section {
                        Label(NSLocalizedString("_invitations_overlap_", comment: ""), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if !event.attendees.isEmpty {
                    Section(NSLocalizedString("_calendar_attendees_", comment: "")) {
                        ForEach(event.attendees, id: \.self) { attendee in
                            Text(attendee).font(.subheadline)
                        }
                    }
                }
                Section {
                    if let answeredText {
                        Label(answeredText, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if let respond {
                        HStack(spacing: 10) {
                            ForEach(CalendarViewModel.CalendarRSVP.allCases, id: \.rawValue) { rsvp in
                                Button {
                                    busy = true
                                    Task {
                                        let ok = await respond(rsvp)
                                        busy = false
                                        if ok == true {
                                            answeredText = NSLocalizedString(rsvp.titleKey, comment: "")
                                        }
                                    }
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
                        Text(NSLocalizedString(answerInMailHint
                            ? "_invitations_answer_in_mail_"
                            : "_invitations_no_ics_hint_", comment: ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(NSLocalizedString("_invitations_rsvp_", comment: ""))
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

    private var timeLine: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = event.allDay ? .none : .short
        if event.allDay {
            return DateFormatter.localizedString(from: event.start, dateStyle: .medium, timeStyle: .none)
        }
        return "\(formatter.string(from: event.start)) - \(formatter.string(from: event.end))"
    }
}
