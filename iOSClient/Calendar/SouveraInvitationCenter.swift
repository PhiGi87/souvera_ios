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
        // Run 19.09. (Feedback): beantwortete Einladungen (UID-Marker oder
        // PARTSTAT != needs-action) erscheinen NICHT mehr im Center - der
        // Einladungs-Button/Badge verschwindet sofort nach der Antwort.
        let answered = Self.answeredUids()
        let pending = events.filter {
            $0.ownPartstat == "needs-action" && !Self.isAnswered(uid: $0.uid)
        }
        let newSig = pending.map { "\($0.href)|\($0.etag ?? "")" }.sorted().joined(separator: ",")
        let oldSig = calendarInvites.map { "\($0.href)|\($0.etag ?? "")" }.sorted().joined(separator: ",")
        if newSig != oldSig {
            calendarInvites = pending
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
    private static let answeredSequenceKey = "invitations_answered_sequence_by_uid"
    private static let answeredEndKey = "invitations_answered_enddates"
    /// Run 19.09. (Feedback): beantwortete Termin-UIDs - Uebersicht-Filter
    /// und Schraffur sind damit sofort korrekt, auch wenn der Server noch
    /// NEEDS-ACTION liefert.
    private static let answeredUidsKey = "invitations_answered_uids"

    /// Run 19.09. (Feedback): Einmaliger Reset aller LOKALEN Einladungs-
    /// Daten nach dem Update - damit ist der Stand GERAETUEBERGREIFEND
    /// server-first (Cross-Device-Test). Der Guard-Key sorgt dafuer, dass
    /// der Reset GENAU EINMAL pro Installation laeuft.
    static func resetLocalStateOnce() {
        let guardKey = "invitations_local_state_cleared_v1"
        guard !UserDefaults.standard.bool(forKey: guardKey) else { return }
        let keys = [
            "invitations_answered_message_ids",
            "invitations_answered_sequence_by_uid",
            "invitations_answered_enddates",
            "invitations_answered_uids",
            "invitations_answered_status_uid",
            "invitations_uid_enddates",
            "invitations_not_in_calendar_ids",
            "invitations_reminder_overrides",
            "invitations_reminder_overrides_uid"
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(true, forKey: guardKey)
        SouveraLog.write("Invitations", "local invitation state cleared once (v1)")
    }

    static func answeredUids() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: answeredUidsKey) ?? [])
    }

    static func isAnswered(uid: String) -> Bool {
        guard !uid.isEmpty else { return false }
        return answeredUids().contains(uid.lowercased())
    }

    static func markAnsweredUid(_ uid: String, end: Date?, status: String? = nil) {
        guard !uid.isEmpty else { return }
        var uids = answeredUids()
        uids.insert(uid.lowercased())
        UserDefaults.standard.set(Array(uids), forKey: answeredUidsKey)
        if let end {
            var ends = UserDefaults.standard.dictionary(forKey: "invitations_uid_enddates") as? [String: Double] ?? [:]
            ends[uid.lowercased()] = end.timeIntervalSince1970
            UserDefaults.standard.set(ends, forKey: "invitations_uid_enddates")
        }
        // Run 19.09. (Feedback): gegebene Antwort pro UID merken - die
        // Termin-Ansicht zeigt spaeter den Status, auch wenn der Server
        // (noch) NEEDS-ACTION liefert.
        if let status {
            var statuses = UserDefaults.standard.dictionary(forKey: "invitations_answered_status_uid") as? [String: String] ?? [:]
            statuses[uid.lowercased()] = status.lowercased()
            UserDefaults.standard.set(statuses, forKey: "invitations_answered_status_uid")
        }
    }

    /// Gegebene Antwort fuer eine Termin-UID (falls lokal gemerkt).
    static func answeredStatus(forUID uid: String) -> String? {
        guard !uid.isEmpty else { return nil }
        return (UserDefaults.standard.dictionary(forKey: "invitations_answered_status_uid") as? [String: String])?[uid.lowercased()]
    }

    /// Run 18.09.: SEQUENCE-Buchhaltung je UID. Eine verschobene Einladung
    /// kommt als NEUE Mail (neue messageId) und wird daher vom Scan
    /// ohnehin neu erfasst - die Buchhaltung dokumentiert die letzte
    /// beantwortete SEQUENCE (fuer kuenftige Duplikat-Gates).
    static func resetAnsweredIfNewerSequence(uid: String, sequence: Int) {
        guard sequence > 0 else { return }
        var byUid = UserDefaults.standard.dictionary(forKey: answeredSequenceKey) as? [String: Int] ?? [:]
        let previous = byUid[uid.lowercased()] ?? -1
        if sequence > previous {
            byUid[uid.lowercased()] = sequence
            UserDefaults.standard.set(byUid, forKey: answeredSequenceKey)
        }
    }
    private static var answeredMessageIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: answeredKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: answeredKey) }
    }

    /// Run 19.09. (Feedback): Einladungsdaten (Antworten, Sequences,
    /// Cancel-Markierungen) werden geloescht, sobald der Termin vorbei ist
    /// - besonders abgelehnte Einladungen hinterlassen keine Reste.
    static func cleanupExpired(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-86400) // 1 Tag Toleranz
        var answered = answeredMessageIds
        var ends = UserDefaults.standard.dictionary(forKey: answeredEndKey) as? [String: Double] ?? [:]
        let expiredIds = ends.filter { Date(timeIntervalSince1970: $0.value) < cutoff }.map(\.key)
        for id in expiredIds {
            answered.remove(id)
            ends.removeValue(forKey: id)
        }
        if !expiredIds.isEmpty {
            answeredMessageIds = answered
            UserDefaults.standard.set(ends, forKey: answeredEndKey)
        }
        var byUid = UserDefaults.standard.dictionary(forKey: answeredSequenceKey) as? [String: Int] ?? [:]
        var uidEnds = UserDefaults.standard.dictionary(forKey: "invitations_uid_enddates") as? [String: Double] ?? [:]
        let expiredUids = uidEnds.filter { Date(timeIntervalSince1970: $0.value) < cutoff }.map(\.key)
        for uid in expiredUids {
            byUid.removeValue(forKey: uid)
            uidEnds.removeValue(forKey: uid)
        }
        if !expiredUids.isEmpty {
            UserDefaults.standard.set(byUid, forKey: answeredSequenceKey)
            UserDefaults.standard.set(uidEnds, forKey: "invitations_uid_enddates")
        }
        // answered-UID-Marker + Erinnerungs-Overrides aufraeumen.
        if !expiredUids.isEmpty {
            var answered = answeredUids()
            for uid in expiredUids { answered.remove(uid) }
            UserDefaults.standard.set(Array(answered), forKey: answeredUidsKey)
            var remOverrides = UserDefaults.standard.dictionary(forKey: reminderOverridesUIDKey) as? [String: [Int]] ?? [:]
            for uid in expiredUids { remOverrides.removeValue(forKey: uid) }
            UserDefaults.standard.set(remOverrides, forKey: reminderOverridesUIDKey)
        }
        if !expiredIds.isEmpty || !expiredUids.isEmpty {
            SouveraLog.write("Invitations", "cleanup: \(expiredIds.count) Antworten, \(expiredUids.count) UIDs entfernt (Termin vorbei)")
        }
    }

    static func markAnswered(messageId: String, eventEnd: Date? = nil) {
        var ids = answeredMessageIds
        ids.insert(messageId)
        answeredMessageIds = ids
        // Run 19.09.: End-Zeitpunkt merken (Basis fuer das Cleanup
        // abgelaufener Einladungsdaten).
        if let eventEnd {
            var ends = UserDefaults.standard.dictionary(forKey: answeredEndKey) as? [String: Double] ?? [:]
            ends[messageId] = eventEnd.timeIntervalSince1970
            UserDefaults.standard.set(ends, forKey: answeredEndKey)
        }
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
        // Run 19.09. (Feedback): einmaliger Lokal-Reset nach dem Update -
        // danach ist der Stand server-first (Cross-Device konsistent).
        Self.resetLocalStateOnce()
        // Run 19.09.: abgelaufene Einladungsdaten aufraeumen.
        Self.cleanupExpired()

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
            // Run 18.09. (Feedback): auch ABLESAGEN erkennen - Betreff-
            // Praefix "Abgesagt:"/"Cancelled:" (auch ohne ICS).
            let cancelHint = lowerSubject.hasPrefix("abgesagt:")
                || lowerSubject.hasPrefix("cancelled:")
                || lowerSubject.hasPrefix("canceled:")
                || lowerSubject.hasPrefix("abgesagt ")
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
            guard subjectHint || cancelHint || icsAttachment != nil else { continue }

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

            // Run 18.09.: METHOD/SEQUENCE erkennen (CANCEL + erneute
            // Antwort-Wahl bei hoeherer SEQUENCE).
            var kind: SouveraMailInvitation.Kind = cancelHint ? .cancel : .invitation
            var sequence = 0
            if let ics = invitationICS {
                let method = (Self.quickExtract(ics, key: "METHOD") ?? "REQUEST").uppercased()
                sequence = Int(Self.quickExtract(ics, key: "SEQUENCE") ?? "") ?? 0
                if method == "CANCEL" { kind = .cancel }
                if let uid = Self.quickExtract(ics, key: "UID") {
                    Self.resetAnsweredIfNewerSequence(uid: uid, sequence: sequence)
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
                receivedAt: Date(),
                kind: kind, sequence: sequence))
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
        // Run 19.09.: zuerst PUT auf einen bereits vorhandenen Termin
        // (UID-Match) - nur ohne Match neu anlegen (kein Duplikat).
        var handledExisting = false
        if !resolved.isCancellation, !resolved.eventUID.isEmpty {
            handledExisting = await SouveraInvitationCenter.shared.respondToExistingCalendarEvent(
                uid: resolved.eventUID, status: status.rawValue,
                reminderMinutes: reminderMinutes)
            // Run 19.09. (Feedback): Ablehnung entfernt den Termin
            // komplett aus dem Kalender.
            if status == .declined {
                _ = await SouveraInvitationCenter.shared.removeEventByUID(resolved.eventUID)
            }
        }
        if status != .declined, !resolved.isCancellation, !handledExisting {
            var createICS = resolved.rawICS
            if createICS == nil, let event = resolved.event {
                createICS = synthesizeICS(title: event.title, start: event.start, end: event.end,
                                          organizerEmail: resolved.organizerEmail)
            }
            if let ics = createICS {
                _ = await SouveraInvitationCenter.shared.createCalendarEvent(
                    from: resolved, ics: ics, status: status.rawValue,
                    calendarHref: calendarHref, reminderMinutes: reminderMinutes)
            }
        }
        if !resolved.isCancellation, !resolved.eventUID.isEmpty {
            SouveraInvitationCenter.markAnsweredUid(resolved.eventUID, end: resolved.event?.end,
                                                    status: status.rawValue)
        }
        let statusWord = NSLocalizedString(status.titleKey, comment: "")
        // Run 18.09.: Antwort-Mail IMMER (auch ohne geparstes Event).
        let sent = await sendReply(invitation: resolved, statusWord: statusWord,
                                   altProposal: altProposal)
        if !sent { return false }
        markAnswered(messageId: resolved.messageId, eventEnd: resolved.event?.end)
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
        var kind = invitation.kind
        var sequence = invitation.sequence
        if let ics = details.ics {
            rawICS = ics
            // Run 18.09.: METHOD:CANCEL / METHOD:REQUEST+SEQUENCE erkennen.
            let method = (Self.quickExtract(ics, key: "METHOD") ?? "REQUEST").uppercased()
            sequence = Int(Self.quickExtract(ics, key: "SEQUENCE") ?? "") ?? 0
            kind = method == "CANCEL" ? .cancel : .invitation
            // Run 18.09.: Betreff-Fallback, falls kein METHOD in der ICS.
            if invitation.subject.lowercased().hasPrefix("abgesagt:")
                || invitation.subject.lowercased().hasPrefix("cancelled:")
                || invitation.subject.lowercased().hasPrefix("canceled:") {
                kind = .cancel
            }
            event = ICSParser.parseEvents(ics, calendarHref: "", href: invitation.messageId,
                                          etag: nil, ownEmail: ownEmail.lowercased()).first
            if event == nil {
                SouveraLog.write("Invitations", "ICS \(invitation.messageId) konnte nicht geparst werden - Text-Fallback")
            }
            if kind == .cancel {
                // Absage: keine Antwort noetig - partstat neutral lassen.
                event = event.map { e in
                    CalendarEventModel(id: e.id, uid: e.uid, sequence: e.sequence,
                                       title: e.title, start: e.start, end: e.end, allDay: e.allDay,
                                       location: e.location, description: e.description,
                                       attendees: e.attendees, talkRoomToken: e.talkRoomToken,
                                       talkRoomName: e.talkRoomName, calendarHref: e.calendarHref,
                                       href: e.href, etag: e.etag, reminders: e.reminders,
                                       isTask: e.isTask, organizerName: e.organizerName,
                                       organizerEmail: e.organizerEmail, ownPartstat: "")
                }
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
            receivedAt: invitation.receivedAt, kind: kind, sequence: sequence)
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
        // Run 19.09. (Feedback: erstellter Termin traegt NEEDS-ACTION
        // statt der Antwort, Log: createEvent -> 415): Die ICS ZUERST
        // normalisieren (CRLF, kein METHOD, keine Leerzeilen) - die 415
        // kam vom Roh-ICS. Erst DANACH PARTSTAT + VALARM aufsetzen, damit
        // der erstellte Termin die Antwort traegt.
        let normalized = Self.normalizeForCalendar(ics)
        guard !me.isEmpty,
              var updated = CalendarViewModel.updatePartstat(ics: normalized, attendeeEmail: me, status: status) else {
            SouveraLog.write("Invitations", "calendar create: own attendee not found (uid=\(uid))")
            return false
        }
        let effectiveReminders = reminderMinutes ?? Self.reminderOverrides(invitation.id)
        if let effectiveReminders {
            updated = CalendarViewModel.setValarms(ics: updated, minutes: effectiveReminders)
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
        var created = await client.createEvent(calendarHref: target.href, ics: updated, uid: uid)
        if created == nil, updated != normalized {
            // Fallback 1: normalisierte Original-ICS ohne PARTSTAT-Umschrieb.
            created = await client.createEvent(calendarHref: target.href, ics: normalized, uid: uid)
        }
        if created == nil, let event = invitation.event {
            // Fallback 2: exakt der bewaehrte "Neuer Termin"-Weg - ICS
            // frisch via buildICS bauen (Titel/Zeiten/Ort/Teilnehmer).
            let draft = EventDraft(
                uid: uid, sequence: 0, title: event.title, start: event.start, end: event.end,
                allDay: event.allDay, location: event.location ?? "",
                notes: event.description ?? "", attendees: event.attendees,
                talkRoomToken: event.talkRoomToken, talkRoomName: event.talkRoomName,
                calendarHref: target.href)
            var rebuilt = ICSParser.buildICS(draft, organizerEmail: event.organizerEmail,
                                             organizerName: event.organizerName)
            // Run 19.09. (Feedback): die gewaehlte Antwort in den eigenen
            // Attendee schreiben - buildICS setzt sonst ueberall
            // NEEDS-ACTION.
            if let withPartstat = CalendarViewModel.updatePartstat(
                ics: rebuilt, attendeeEmail: me, status: status) {
                rebuilt = withPartstat
            }
            created = await client.createEvent(calendarHref: target.href, ics: rebuilt, uid: uid)
            SouveraLog.write("Invitations", "create fallback via buildICS: \(created != nil)")
        }
        if created != nil {
            SouveraLog.write("Invitations", "calendar create ok in \(target.displayName) uid=\(uid)")
        } else {
            SouveraLog.write("Invitations", "calendar create FAILED uid=\(uid)")
        }
        return created != nil
    }

    /// Run 18.09.: Externe ICS in die buildICS-kompatible Form bringen:
    /// entfalten, CRLF-Zeilenenden, keine METHOD-Zeile, keine Leerzeilen.
    static func normalizeForCalendar(_ ics: String) -> String {
        var lines: [String] = []
        for raw in ics.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if raw.hasPrefix(" ") || raw.hasPrefix("\t"), let last = lines.last {
                lines[lines.count - 1] += String(raw.dropFirst())
            } else {
                lines.append(raw.trimmingCharacters(in: .whitespaces))
            }
        }
        return lines
            .filter { !$0.isEmpty && !$0.uppercased().hasPrefix("METHOD:") }
            .joined(separator: "\r\n")
    }

    /// Erster Wert des Keys in der ICS (zeilenbasiert, Folding-tolerant).
    /// nonisolated: wird auch aus nonisolated Kontexten (z. B. dem
    /// Mail-Modell) aufgerufen.
    nonisolated static func quickExtract(_ ics: String, key: String) -> String? {
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

    /// Run 18.09. (Feedback): Matching UID ODER exakt Titel (normalisiert)
    /// + Start/Ende ±5 min - ohne ICS kein blur-Raten.
    func removeCancelledEvent(uid: String, title: String = "",
                              start: Date? = nil, end: Date? = nil) async -> Bool {
        let client = CalDavClient(account: nil)
        let calendars = await client.fetchCalendars()
        let calendar = Calendar.current
        let now = Date()
        let normalizedTitle = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
        var removed = false
        for cal in calendars {
            let fetched = await client.fetchEvents(
                calendarHref: cal.href,
                start: calendar.date(byAdding: .day, value: -30, to: now) ?? now,
                end: calendar.date(byAdding: .day, value: 370, to: now) ?? now)
            for entry in fetched {
                var matches = false
                if !uid.isEmpty,
                   entry.ics.uppercased().contains("UID:\(uid.uppercased())") {
                    matches = true
                } else if !normalizedTitle.isEmpty, let refStart = start, let refEnd = end {
                    let candidate = ICSParser.parseEvents(
                        entry.ics, calendarHref: cal.href, href: entry.href,
                        etag: entry.etag).first
                    if let candidate {
                        let candidateTitle = candidate.title.lowercased()
                            .components(separatedBy: CharacterSet.alphanumerics.inverted)
                            .filter { !$0.isEmpty }.joined(separator: " ")
                        let startDelta = abs(candidate.start.timeIntervalSince(refStart))
                        let endDelta = abs(candidate.end.timeIntervalSince(refEnd))
                        matches = candidateTitle == normalizedTitle
                            && startDelta <= 300 && endDelta <= 300
                    }
                }
                if matches {
                    let ok = await client.deleteEvent(entry)
                    SouveraLog.write("Invitations", "cancel remove uid=\(uid) title=\(title): \(ok)")
                    if ok { removed = true }
                }
            }
        }
        if !removed {
            SouveraLog.write("Invitations", "cancel remove: kein Match (uid=\(uid) title=\(title))")
        }
        return removed
    }

    /// Run 19.09. (Feedback): Termin nach einer Ablehnung aus dem Kalender
    /// entfernen (DELETE mit ETag-Retry).
    @discardableResult
    func removeEventByUID(_ uid: String) async -> Bool {
        guard !uid.isEmpty else { return false }
        let client = CalDavClient(account: nil)
        let calendars = await client.fetchCalendars()
        let calendar = Calendar.current
        let now = Date()
        for cal in calendars {
            let fetched = await client.fetchEvents(
                calendarHref: cal.href,
                start: calendar.date(byAdding: .day, value: -90, to: now) ?? now,
                end: calendar.date(byAdding: .day, value: 730, to: now) ?? now)
            for entry in fetched where entry.ics.uppercased().contains("UID:\(uid.uppercased())") {
                let ok = await CalendarViewModel.deleteEventEntry(entry, client: client)
                SouveraLog.write("Invitations", "decline remove uid=\(uid): \(ok)")
                return ok
            }
        }
        SouveraLog.write("Invitations", "decline remove uid=\(uid): nicht im Kalender")
        return false
    }

    // MARK: - Erinnerungen (Run 19.09., einheitlich)

    private static let reminderOverridesKey = "invitations_reminder_overrides"
    private static let reminderOverridesUIDKey = "invitations_reminder_overrides_uid"

    /// Gespeicherte Erinnerungen einer Einladung (vor dem Kalender-Create).
    static func reminderOverrides(_ inviteId: String) -> [Int]? {
        let dict = UserDefaults.standard.dictionary(forKey: reminderOverridesKey) as? [String: [Int]]
        return dict?[inviteId]
    }

    /// Erinnerungen ueber die Termin-UID finden - Run 19.09. (Feedback):
    /// PERSISTENT per UID gespeichert (funktioniert ueber App-Neustarts
    /// und Modulgrenzen hinweg), Fallback: Session-Einladungen.
    static func reminderOverride(forUID uid: String) -> [Int]? {
        guard !uid.isEmpty else { return nil }
        let byUid = UserDefaults.standard.dictionary(forKey: reminderOverridesUIDKey) as? [String: [Int]] ?? [:]
        if let minutes = byUid[uid.lowercased()] { return minutes }
        let dict = UserDefaults.standard.dictionary(forKey: reminderOverridesKey) as? [String: [Int]] ?? [:]
        for invite in SouveraInvitationCenter.shared.mailInvites
        where invite.eventUID.caseInsensitiveCompare(uid) == .orderedSame {
            if let minutes = dict[invite.id] { return minutes }
        }
        return nil
    }

    /// Setzt die Erinnerungen einer Einladung: liegt der Termin schon im
    /// Kalender (UID-Match) -> sofort per PUT speichern; sonst an der
    /// Einladung merken (der Create wendet sie an).
    @discardableResult
    func updateInvitationReminders(_ invitation: SouveraMailInvitation,
                                   minutes: [Int]) async -> Bool {
        var dict = UserDefaults.standard.dictionary(forKey: Self.reminderOverridesKey) as? [String: [Int]] ?? [:]
        dict[invitation.id] = minutes
        UserDefaults.standard.set(dict, forKey: Self.reminderOverridesKey)
        // Run 19.09. (Feedback): zusaetzlich PERSISTENT per UID merken.
        

        let eventUID = invitation.eventUID
        guard !eventUID.isEmpty else { return true }
        let client = CalDavClient(account: nil)
        let calendars = await client.fetchCalendars()
        let calendar = Calendar.current
        let now = Date()
        for cal in calendars {
            let fetched = await client.fetchEvents(
                calendarHref: cal.href,
                start: calendar.date(byAdding: .day, value: -90, to: now) ?? now,
                end: calendar.date(byAdding: .day, value: 730, to: now) ?? now)
            for entry in fetched where entry.ics.uppercased().contains("UID:\(eventUID.uppercased())") {
                let updated = CalendarViewModel.setValarms(ics: entry.ics, minutes: minutes)
                let ok = await client.updateEvent(entry, ics: updated)
                SouveraLog.write("Invitations", "reminders update uid=\(eventUID): \(ok)")
                return ok
            }
        }
        return true
    }

    // MARK: - Antwort auf einen bereits im Kalender liegenden Termin

    /// Run 19.09. (Feedback: keine Duplikate, Antwort muss persistieren):
    /// Wenn ein Termin mit dieser UID bereits im Kalender liegt, wird nur
    /// die eigene PARTSTAT per PUT aktualisiert (CalDAV + Server-iTIP).
    @discardableResult
    func respondToExistingCalendarEvent(uid: String, status: String,
                                        reminderMinutes: [Int]?) async -> Bool {
        guard !uid.isEmpty else { return false }
        let client = CalDavClient(account: nil)
        let calendars = await client.fetchCalendars()
        let me = CalendarViewModel.ownAttendeeEmail()
        let calendar = Calendar.current
        let now = Date()
        for cal in calendars {
            let fetched = await client.fetchEvents(
                calendarHref: cal.href,
                start: calendar.date(byAdding: .day, value: -90, to: now) ?? now,
                end: calendar.date(byAdding: .day, value: 730, to: now) ?? now)
            for entry in fetched where entry.ics.uppercased().contains("UID:\(uid.uppercased())") {
                guard let partstat = CalendarViewModel.updatePartstat(
                    ics: entry.ics, attendeeEmail: me, status: status) else { continue }
                var updated = partstat
                let override = reminderMinutes ?? Self.reminderOverride(forUID: uid)
                if let override {
                    updated = CalendarViewModel.setValarms(ics: updated, minutes: override)
                } else {
                    updated = CalendarViewModel.ensureDefaultReminder(ics: updated, status: status)
                }
                let ok = await client.updateEvent(entry, ics: updated)
                SouveraLog.write("Invitations", "RSVP existing event uid=\(uid): \(ok)")
                return ok
            }
        }
        SouveraLog.write("Invitations", "RSVP existing event uid=\(uid): nicht im Kalender")
        return false
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
        // Run 19.09. (Feedback): das Statuswort ZENTRAL in die
        // Vergangenheitsform ueberfuehren - Aufrufer duerfen das
        // Button-Label ("Annehmen") durchreichen, die Mail zeigt nie
        // "Annehmen".
        let acceptBtn = NSLocalizedString("_invitations_accept_", comment: "")
        let tentativeBtn = NSLocalizedString("_invitations_tentative_", comment: "")
        let doneWord: String
        if statusWord.hasPrefix(NSLocalizedString("_invitations_done_accepted_", comment: ""))
            || statusWord == acceptBtn {
            doneWord = NSLocalizedString("_invitations_done_accepted_", comment: "")
        } else if statusWord.hasPrefix(NSLocalizedString("_invitations_done_tentative_", comment: ""))
            || statusWord == tentativeBtn {
            doneWord = NSLocalizedString("_invitations_done_tentative_", comment: "")
        } else {
            doneWord = NSLocalizedString("_invitations_done_declined_", comment: "")
        }
        let statusWord = doneWord
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
        // Run 18.09.: statusWord ist jetzt die Vergangenheitsform
        // ("Angenommen") - Farbwahl darauf umgestellt.
        let acceptedWord = NSLocalizedString("_invitations_done_accepted_", comment: "")
        let tentativeWord = NSLocalizedString("_invitations_done_tentative_", comment: "")
        let statusColor: String
        if statusWord.hasPrefix(acceptedWord) {
            statusColor = "#34c759"
        } else if statusWord.hasPrefix(tentativeWord) {
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
            <table style="border-collapse:collapse;font-size:14px;margin:10px 18px;width:calc(100% - 36px)">\(rows)</table>
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
    /// Run 19.09. (Feedback): EINE Quelle fuer das Statuswort in der Mail -
    /// Button-Label ("Annehmen"/"Ablehnen") wird in die Vergangenheitsform
    /// ueberfuehrt ("Angenommen"/"Abgelehnt"); bereits konvertierte Woerter
    /// bleiben unveraendert.
    static func doneStatusWord(for statusWord: String) -> String {
        let accepted = NSLocalizedString("_invitations_done_accepted_", comment: "")
        let tentative = NSLocalizedString("_invitations_done_tentative_", comment: "")
        let declined = NSLocalizedString("_invitations_done_declined_", comment: "")
        if statusWord == NSLocalizedString("_invitations_accept_", comment: "") || statusWord == accepted {
            return accepted
        }
        if statusWord == NSLocalizedString("_invitations_tentative_", comment: "") || statusWord == tentative {
            return tentative
        }
        if statusWord == NSLocalizedString("_invitations_decline_", comment: "") || statusWord == declined {
            return declined
        }
        return declined
    }

    @discardableResult
    static func sendReply(invitation: SouveraMailInvitation, statusWord: String,
                          altProposal: String?) async -> Bool {
        // Run 18.09./19.09. (Feedback): Betreff UND Body immer in der
        // Vergangenheitsform - nie das Button-Label.
        let doneWord = doneStatusWord(for: statusWord)
        let reply = await makeReplyMail(
            event: invitation.event,
            title: invitation.displayTitle,
            organizerEmail: invitation.organizerEmail,
            statusWord: doneWord,
            altProposal: altProposal)
        guard !reply.to.isEmpty else {
            SouveraLog.write("Invitations", "reply mail: no organizer address")
            return false
        }
        let sent = await SouveraInviteMailSender.shared.send(
            to: reply.to,
            subject: "\(doneWord): \(invitation.displayTitle)",
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
        // Wrapper reicht durch - die Vergangenheitsform setzt sendReply
        // (invitation:).
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
        // Run 18.09.: Mapping auf Vergangenheitsform + Fallback auf
        // Button-Label (falls Aufrufer noch statusWord übergibt).
        let accepted = NSLocalizedString("_invitations_done_accepted_", comment: "").lowercased()
        let tentative = NSLocalizedString("_invitations_done_tentative_", comment: "").lowercased()
        let acceptBtn = NSLocalizedString("_invitations_accept_", comment: "").lowercased()
        let tentativeBtn = NSLocalizedString("_invitations_tentative_", comment: "").lowercased()
        let w = statusWord.lowercased()
        let status: String
        if w.hasPrefix(accepted) || w.contains(acceptBtn) {
            status = "ACCEPTED"
        } else if w.hasPrefix(tentative) || w.contains(tentativeBtn) {
            status = "TENTATIVE"
        } else {
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
