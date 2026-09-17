// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zentrale Sammelstelle fuer offene Termineinladungen (Kalender- und
// Mail-iMIP-Quelle). Beobachtet vom Einladungs-FAB und -Sheet.
import Foundation
import SwiftUI

@MainActor
final class SouveraInvitationCenter: ObservableObject {
    static let shared = SouveraInvitationCenter()

    /// Offene Einladungen aus dem Kalender (ownPartstat = NEEDS-ACTION).
    @Published var calendarInvites: [CalendarEventModel] = []
    /// Per Mail erhaltene Einladungen (iMIP-Scan des Posteingangs).
    @Published var mailInvites: [SouveraMailInvitation] = []

    /// Account-Key, fuer den der aktuelle Stand gilt (Accountwechsel).
    @Published private(set) var accountKey: String = ""

    var totalCount: Int { calendarInvites.count + mailInvites.count }

    func setCalendarInvites(_ events: [CalendarEventModel], accountKey: String) {
        guard self.accountKey == accountKey || calendarInvites.isEmpty || self.accountKey.isEmpty else { return }
        self.accountKey = accountKey
        // Signaturen vergleichen, damit das @Published-Objekt nicht bei
        // jedem 30-s-Sync die UI triggert.
        let newSig = events.map { "\($0.href)|\($0.etag ?? "")" }.sorted().joined(separator: ",")
        let oldSig = calendarInvites.map { "\($0.href)|\($0.etag ?? "")" }.sorted().joined(separator: ",")
        if newSig != oldSig {
            calendarInvites = events
        }
    }

    func setMailInvites(_ invites: [SouveraMailInvitation], accountKey: String) {
        guard self.accountKey == accountKey || mailInvites.isEmpty || self.accountKey.isEmpty else { return }
        self.accountKey = accountKey
        let newSig = invites.map { $0.id }.sorted().joined(separator: ",")
        let oldSig = mailInvites.map { $0.id }.sorted().joined(separator: ",")
        if newSig != oldSig {
            mailInvites = invites
        }
    }

    func removeMailInvitation(_ id: String) {
        mailInvites.removeAll { $0.id == id }
    }

    func removeCalendarInvitation(_ href: String) {
        calendarInvites.removeAll { $0.href == href }
    }

    func resetForAccountSwitch(_ accountKey: String) {
        guard self.accountKey != accountKey else { return }
        calendarInvites = []
        mailInvites = []
        self.accountKey = accountKey
    }

    /// Run 16.09.: Anzeige-Termin fuer Einladungsmails OHNE ICS -
    /// nur Betreff/Absender als Detail-Information.
    static func placeholderEvent(for invite: SouveraMailInvitation) -> CalendarEventModel {
        CalendarEventModel(
            id: invite.id,
            uid: "",
            sequence: 0,
            title: invite.displayTitle,
            start: Date(),
            end: Date(),
            allDay: false,
            location: nil,
            description: nil,
            attendees: [],
            talkRoomToken: nil,
            talkRoomName: nil,
            calendarHref: "",
            href: invite.id,
            etag: nil,
            reminders: [],
            isTask: false,
            organizerName: "",
            organizerEmail: invite.organizerEmail,
            ownPartstat: ""
        )
    }

    // MARK: - Beantwortete Einladungen (persistiert)

    private static let answeredKey = "invitations_answered_message_ids"
    private static var answeredMessageIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: answeredKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: answeredKey) }
    }

    static func markAnswered(messageId: String) {
        var ids = answeredMessageIds
        ids.insert(messageId)
        answeredMessageIds = ids
        Task { @MainActor in
            SouveraInvitationCenter.shared.removeMailInvitation(messageId)
        }
    }

    // MARK: - Mail-iMIP-Scan

    /// Scannt die uebergebenen Posteingang-Kandidaten nach Einladungsmails.
    /// Fuer Kandidaten (Einladungs-Betreff oder text/calendar-Anhang) wird
    /// der ICS-Part (auch ohne sichtbaren .ics-Anhang, siehe Feedback
    /// 16.09. 17:23) per Blob-Download geladen und geparst.
    func scanMailInvites(accountId: String,
                         accountKey: String,
                         ownEmail: String,
                         candidates: [[String: Any]],
                         client: JmapClient,
                         api: JmapApi) async {
        resetForAccountSwitch(accountKey)

        let answered = Self.answeredMessageIds
        var invites: [SouveraMailInvitation] = []
        for json in candidates {
            let subject = (json["subject"] as? String) ?? ""
            guard let messageId = json["id"] as? String else { continue }
            // Run 16.09. (Log d1diaaa3q9): GELESENE Einladungen duerfen
            // nicht mehr uebersprungen werden - der Tester oeffnet die
            // Mail natuerlich zuerst ($seen). Gefiltert werden nur noch
            // BEANTWORTETE Einladungen.
            guard !answered.contains(messageId) else { continue }
            let from = Self.firstFromAddress(json)
            let lowerSubject = subject.lowercased()
            let subjectHint = lowerSubject.hasPrefix("invitation:")
                || lowerSubject.hasPrefix("einladung:")
                || lowerSubject.hasPrefix("invito:")
                || lowerSubject.hasPrefix("invitation :")
            // Run 16.09. (Log d1diaaa3q9): Der text/calendar-Part kommt
            // je nach Sender als Attachment ODER als Inline-Part (JMAP
            // listet beide in "attachments", unsere Mapper teilen sie
            // nur fuer die ANZEIGE) - deshalb im rohen attachments-Array
            // suchen, das deckt beide Dispositionen ab.
            let attachments = (json["attachments"] as? [[String: Any]]) ?? []
            let icsAttachment = attachments.first(where: {
                ($0["type"] as? String)?.lowercased().contains("calendar") == true
                    || (($0["name"] as? String)?.lowercased().hasSuffix(".ics") == true)
            })
            guard subjectHint || icsAttachment != nil else { continue }

            var parsedEvent: CalendarEventModel?
            var invitationICS: String?
            if let att = icsAttachment, let blobId = att["blobId"] as? String {
                let data = try? await client.downloadBlob(
                    accountId: accountId, blobId: blobId, mimeType: "text/calendar")
                if let ics = String(data: data ?? Data(), encoding: .utf8) {
                    invitationICS = ics
                    parsedEvent = ICSParser.parseEvents(
                        ics, calendarHref: "", href: messageId, etag: nil,
                        ownEmail: ownEmail.lowercased()
                    ).first
                }
            }

            invites.append(SouveraMailInvitation(
                id: messageId,
                messageId: messageId,
                accountId: accountId,
                subject: subject,
                from: from,
                organizerEmail: parsedEvent?.organizerEmail ?? from,
                event: parsedEvent,
                rawICS: parsedEvent != nil ? invitationICS : nil,
                receivedAt: Date()
            ))
        }
        setMailInvites(invites, accountKey: accountKey)
    }

    private static func firstFromAddress(_ json: [String: Any]) -> String {
        if let fromList = json["from"] as? [[String: Any]],
           let first = fromList.first,
           let emails = first["email"] as? [String] ?? (first["email"] as? String).map({ [$0] }),
           let address = emails.first {
            return address
        }
        if let fromList = json["from"] as? [[String: Any]],
           let first = fromList.first,
           let name = first["name"] as? String {
            return name
        }
        return ""
    }

    /// Run 16.09.: Brücke für RSVP aus dem KALENDER-Kontext auf eine
    /// Mail-Einladung, wenn kein CalDAV-Entry existiert: Kalender-Create
    /// + Antwort-Mail, ohne MailViewModel.
    static func respondViaMail(_ invitation: SouveraMailInvitation,
                               _ status: CalendarViewModel.CalendarRSVP,
                               _ reminderMinutes: [Int]?,
                               _ altProposal: String?,
                               calendarHref: String? = nil) async -> Bool {
        // Run 17.09.: erst echte Termindaten (Lazy-Fetch + Text-Fallback).
        let resolved = await SouveraInvitationCenter.shared.resolveInvitation(invitation)
        var createICS = resolved.rawICS
        if createICS == nil, let event = resolved.event {
            createICS = synthesizeICS(title: event.title, start: event.start, end: event.end,
                                      organizerEmail: resolved.organizerEmail)
        }
        if status != .declined, let ics = createICS {
            _ = await SouveraInvitationCenter.shared.createCalendarEvent(
                from: resolved, ics: ics, status: status.rawValue,
                calendarHref: calendarHref, reminderMinutes: reminderMinutes)
        }
        let statusWord = NSLocalizedString(status.titleKey, comment: "")
        // Run 18.09.: Antwort-Mail IMMER (auch ohne geparstes Event).
        let sent = await sendReply(invitation: resolved, statusWord: statusWord,
                                   altProposal: altProposal)
        if !sent { return false }
        markAnswered(messageId: resolved.messageId)
        await MainActor.run {
            SouveraInvitationCenter.shared.removeMailInvitation(resolved.id)
        }
        return true
    }

    // MARK: - Lazy-Auflösung der Einladungsdaten (Run 17.09.)

    /// Stellt sicher, dass die Einladung echte Termindaten hat:
    /// 1) rohe ICS (bereits im Scan ODER Lazy-Fetch), 2) Text-Fallback.
    /// Aktualisiert die Einladung im Center und liefert den Stand zurück.
    @discardableResult
    func resolveInvitation(_ invitation: SouveraMailInvitation) async -> SouveraMailInvitation {
        if invitation.resolved == true { return invitation }
        if invitation.event != nil, invitation.rawICS != nil { return invitation }
        guard let details = await SouveraInviteMailSender.fetchInvitationDetails(messageId: invitation.messageId) else {
            return invitation
        }
        let ownEmail = CalendarViewModel.ownAttendeeEmail()
        var event: CalendarEventModel?
        var rawICS: String?
        if let ics = details.ics {
            rawICS = ics
            event = ICSParser.parseEvents(ics, calendarHref: "", href: invitation.messageId,
                                          etag: nil, ownEmail: ownEmail.lowercased()).first
            if event == nil {
                SouveraLog.write("Invitations", "ICS \(invitation.messageId) konnte nicht geparst werden - Text-Fallback")
            }
        }
        if event == nil, let parsed = SouveraInviteMailSender.parseTimeFromText(
            subject: invitation.subject, plainText: details.plainText) {
            // Text-Termin: eigener ICS wird beim Create synthetisiert.
            event = CalendarEventModel(
                id: invitation.messageId, uid: invitation.messageId, sequence: 0,
                title: parsed.title, start: parsed.start, end: parsed.end, allDay: false,
                location: nil, description: nil, attendees: [], talkRoomToken: nil,
                talkRoomName: nil, calendarHref: "", href: invitation.messageId, etag: nil,
                reminders: [], isTask: false, organizerName: "", organizerEmail: invitation.organizerEmail,
                ownPartstat: "needs-action")
            SouveraLog.write("Invitations", "Text-Fallback \(invitation.messageId): \(parsed.start)-\(parsed.end)")
        }
        let resolved = SouveraMailInvitation(
            id: invitation.id, messageId: invitation.messageId, accountId: invitation.accountId,
            subject: invitation.subject, from: invitation.from,
            organizerEmail: event?.organizerEmail ?? invitation.organizerEmail,
            event: event, rawICS: rawICS, resolved: true,
            receivedAt: invitation.receivedAt)
        updateInvite(resolved)
        return resolved
    }

    /// Run 17.09. (3.2): manueller Zeitraum (UI) - ersetzt den
    /// Platzhalter-Termin durch echte Zeiten; die Einladung gilt als
    /// aufgeloest (kein erneuter Fetch).
    @MainActor
    func setManualTimes(inviteId: String, title: String,
                        start: Date, end: Date, organizerEmail: String) {
        guard let idx = mailInvites.firstIndex(where: { $0.id == inviteId }) else { return }
        let invitation = mailInvites[idx]
        if invitation.resolved { return } // einmal manuell gesetzt bleibt gesetzt
        let event = CalendarEventModel(
            id: invitation.messageId, uid: "", sequence: 0,
            title: title, start: start, end: end, allDay: false,
            location: nil, description: nil, attendees: [], talkRoomToken: nil,
            talkRoomName: nil, calendarHref: "", href: invitation.messageId, etag: nil,
            reminders: [], isTask: false, organizerName: "",
            organizerEmail: invitation.organizerEmail.isEmpty ? organizerEmail : invitation.organizerEmail,
            ownPartstat: "needs-action")
        mailInvites[idx] = SouveraMailInvitation(
            id: invitation.id, messageId: invitation.messageId, accountId: invitation.accountId,
            subject: invitation.subject, from: invitation.from,
            organizerEmail: event.organizerEmail,
            event: event, rawICS: nil, resolved: true,
            receivedAt: invitation.receivedAt)
    }

    func updateInvite(_ invitation: SouveraMailInvitation) {
        if let idx = mailInvites.firstIndex(where: { $0.id == invitation.id }) {
            mailInvites[idx] = invitation
        }
    }

    /// Synthetisiert eine minimale VEVENT-ICS (fuer Text-Fallback-Termine).
    static func synthesizeICS(title: String, start: Date, end: Date,
                              organizerEmail: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Souvera//Invite//DE",
            "METHOD:REQUEST",
            "BEGIN:VEVENT",
            "UID:\(UUID().uuidString.lowercased())",
            "DTSTAMP:\(formatter.string(from: Date()))",
            "DTSTART:\(formatter.string(from: start))",
            "DTEND:\(formatter.string(from: end))",
            "SUMMARY:\(escapeICS(title))",
            organizerEmail.contains("@") ? "ORGANIZER:mailto:\(organizerEmail)" : "",
            "END:VEVENT",
            "END:VCALENDAR"
        ].filter { !$0.isEmpty }.joined(separator: "\r\n")
    }

    // MARK: - Kalender-Create aus Mail-Einladung (B1)

    /// Traegt einen eingeladenen Termin in den gewaehlten Kalender ein
    /// (Default: persoenlicher, schreibbarer Kalender). Die eigene
    /// PARTSTAT wird gesetzt, Erinnerungen ergaenzt.
    @discardableResult
    func createCalendarEvent(from invitation: SouveraMailInvitation,
                             ics: String,
                             status: String,
                             calendarHref: String?,
                             reminderMinutes: [Int]?) async -> Bool {
        // Run 18.09. (Feedback: Create passiert nicht): NICHT mehr am
        // geparsten Modell haengen - UID direkt aus der ICS extrahieren
        // (parseEvents kann an exotischen ICS scheitern, die ICS selbst
        // ist trotzdem valide).
        let uid = Self.quickExtract(ics, key: "UID") ?? invitation.messageId
        let me = CalendarViewModel.ownAttendeeEmail()
        guard !me.isEmpty,
              var updated = CalendarViewModel.updatePartstat(ics: ics, attendeeEmail: me, status: status) else {
            SouveraLog.write("Invitations", "calendar create: own attendee not found")
            return false
        }
        if let reminderMinutes {
            updated = CalendarViewModel.setValarms(ics: updated, minutes: reminderMinutes)
        } else {
            updated = CalendarViewModel.ensureDefaultReminder(ics: updated, status: status)
        }
        let client = CalDavClient(account: nil)
        let calendars = await client.fetchCalendars()
        let chosen: CalDavCalendar? =
            (calendarHref.flatMap { href in calendars.first(where: { $0.href == href && $0.canWrite }) })
            ?? calendars.first(where: { $0.canWrite && $0.isPersonal })
            ?? calendars.first(where: { $0.canWrite && !$0.href.contains("deck") })
        guard let target = chosen else {
            SouveraLog.write("Invitations", "calendar create: no writable calendar")
            return false
        }
        let created = await client.createEvent(calendarHref: target.href, ics: updated, uid: uid)
        if created != nil {
            SouveraLog.write("Invitations", "calendar create ok in \(target.displayName) uid=\(uid)")
        } else {
            SouveraLog.write("Invitations", "calendar create FAILED uid=\(uid)")
        }
        return created != nil
    }

    /// Erster Wert des Keys in der ICS (zeilenbasiert, Folding-tolerant).
    static func quickExtract(_ ics: String, key: String) -> String? {
        let unfolded = ics
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\n ", with: "")
        for line in unfolded.components(separatedBy: .newlines) {
            if line.uppercased().hasPrefix("\(key.uppercased()):") {
                return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Antworten per Mail (moderne Mail + ICS-REPLY-Anhang)

    /// Baut die Antwort-Mail: moderner HTML-Body mit Eckdaten, klarer
    /// Antwortzeile, Absender-Adresse und optionalem Alternativvorschlag
    /// (B9). Laedt den ICS-REPLY-Anhang als Temp-Datei.
    static func makeReplyMail(event: CalendarEventModel?,
                              title: String,
                              organizerEmail: String,
                              statusWord: String,
                              altProposal: String?) async -> (to: String, html: String, text: String, icsURL: URL?) {
        let me = CalendarViewModel.ownAttendeeEmail()
        let to = organizerEmail.contains("@") ? organizerEmail : ""

        var rows = ""
        func row(_ label: String, _ value: String) {
            guard !value.isEmpty else { return }
            rows += "<tr><td style=\"padding:5px 16px 5px 0;color:#8a8a8e;white-space:nowrap;font-size:13px;vertical-align:top\">\(label)</td>"
                + "<td style=\"padding:5px 0;font-weight:600;font-size:14px\">\(value)</td></tr>"
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        var timeText = ""
        if let event {
            if event.allDay {
                timeText = DateFormatter.localizedString(from: event.start, dateStyle: .full, timeStyle: .none)
            } else {
                let endFormatter = DateFormatter()
                endFormatter.dateStyle = .none
                endFormatter.timeStyle = .short
                timeText = "\(formatter.string(from: event.start)) – \(endFormatter.string(from: event.end))"
            }
        }

        row(NSLocalizedString("_calendar_when_", comment: ""), timeText)
        if let location = event?.location, !location.isEmpty {
            row(NSLocalizedString("_calendar_location_", comment: ""), location)
        }
        if let orga = event?.organizerEmail, !orga.isEmpty, orga != to {
            row(NSLocalizedString("_invitations_organizer_", comment: ""), orga)
        }
        row(NSLocalizedString("_invitations_reply_from_", comment: ""), me)
        if let altProposal, !altProposal.isEmpty {
            row(NSLocalizedString("_invitations_alt_proposal_", comment: ""), altProposal)
        }

        let escapedTitle = (event?.title ?? title)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        // Run 18.09. (Feedback): elegante Karte - Status als farbige
        // Kopfzeile mit Doppelpunkt, Eckdaten als saubere Tabelle.
        let statusColor: String
        if statusWord.hasPrefix(NSLocalizedString("_invitations_accept_", comment: "")) {
            statusColor = "#34c759"
        } else if statusWord.hasPrefix(NSLocalizedString("_invitations_tentative_", comment: "")) {
            statusColor = "#ff9500"
        } else {
            statusColor = "#ff3b30"
        }
        let html = """
        <div style="font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:560px">
          <div style="background:#f5f6f8;border-radius:14px;overflow:hidden;border:1px solid #e5e5ea">
            <div style="padding:14px 18px;background:\(statusColor)">
              <span style="color:#ffffff;font-size:16px;font-weight:700">\(statusWord):</span>
              <span style="color:#ffffff;font-size:16px">\(escapedTitle)</span>
            </div>
            <table style="border-collapse:collapse;font-size:14px">\(rows)</table>
            <div style="padding:10px 18px 14px;color:#8a8a8e;font-size:12px">Souvera Workspace</div>
          </div>
        </div>
        """
        let text = """
        \(statusWord): \(event?.title ?? title)
        \(timeText)
        \(NSLocalizedString("_invitations_reply_from_", comment: "")): \(me)
        """
        + (altProposal.map { "\n\(NSLocalizedString("_invitations_alt_proposal_", comment: "")): \($0)" } ?? "")

        var icsURL: URL?
        if let event {
            let ics = buildReplyICS(event: event, statusWord: statusWord, altProposal: altProposal)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("invite-reply-\(UUID().uuidString).ics")
            if let data = ics.data(using: .utf8) {
                try? data.write(to: url)
                icsURL = url
            }
        }
        return (to, html, text, icsURL)
    }

    /// Sendet die Antwort-Mail komplett (Aufbau + Versand). Funktioniert
    /// auch OHNE geparstes Event (Titel/Zeit aus dem Text-Fallback).
    @discardableResult
    static func sendReply(invitation: SouveraMailInvitation, statusWord: String,
                          altProposal: String?) async -> Bool {
        let reply = await makeReplyMail(
            event: invitation.event,
            title: invitation.displayTitle,
            organizerEmail: invitation.organizerEmail,
            statusWord: statusWord,
            altProposal: altProposal)
        guard !reply.to.isEmpty else {
            SouveraLog.write("Invitations", "reply mail: no organizer address")
            return false
        }
        let sent = await SouveraInviteMailSender.shared.send(
            to: reply.to,
            subject: "\(statusWord): \(invitation.displayTitle)",
            html: reply.html,
            text: reply.text,
            icsAttachmentURL: reply.icsURL)
        SouveraLog.write("Invitations", "reply mail \(sent ? "sent" : "FAILED") to \(reply.to)")
        return sent
    }

    /// Kompatibilitaets-Wrapper: Antwort aus dem KALENDER-Kontext
    /// (CalDAV-Event vorhanden).
    @discardableResult
    static func sendReply(event: CalendarEventModel, statusWord: String,
                          altProposal: String?) async -> Bool {
        let invitation = SouveraMailInvitation(
            id: event.href, messageId: event.href, accountId: "",
            subject: event.title, from: event.organizerEmail,
            organizerEmail: event.organizerEmail,
            event: event, rawICS: nil, resolved: true, receivedAt: Date())
        return await sendReply(invitation: invitation, statusWord: statusWord,
                               altProposal: altProposal)
    }

    /// Minimale iTIP-REPLY-ICS (METHOD:REPLY) mit dem eigenen PARTSTAT;
    /// der Alternativvorschlag steht als Kommentar im DESCRIPTION-Feld.
    static func buildReplyICS(event: CalendarEventModel, statusWord: String,
                              altProposal: String?) -> String {
        let me = CalendarViewModel.ownAttendeeEmail()
        let status: String
        switch statusWord.lowercased() {
        case let w where w.contains(NSLocalizedString("_invitations_accept_", comment: "").lowercased()):
            status = "ACCEPTED"
        case let w where w.contains(NSLocalizedString("_invitations_tentative_", comment: "").lowercased()):
            status = "TENTATIVE"
        default:
            status = "DECLINED"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Souvera//Invite Reply//DE",
            "METHOD:REPLY",
            "BEGIN:VEVENT",
            "UID:\(event.uid)",
            "SEQUENCE:\(event.sequence)",
            "DTSTAMP:\(stamp)",
            "ORGANIZER;CN=\(escapeICS(event.organizerName)):mailto:\(event.organizerEmail)",
            "ATTENDEE;PARTSTAT=\(status):mailto:\(me)"
        ]
        if let altProposal, !altProposal.isEmpty {
            let label = NSLocalizedString("_invitations_alt_proposal_", comment: "")
            lines.append("DESCRIPTION:\(escapeICS("\(label): \(altProposal)"))")
        }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n")
    }

        private static func escapeICS(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
    }
}
