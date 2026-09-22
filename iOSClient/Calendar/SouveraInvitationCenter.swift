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

    /// Run 19.09. (Feedback Cross-Device): UIDs von Terminen, die laut
    /// SERVER (CalDAV-PARTSTAT != needs-action) bereits beantwortet sind.
    /// Damit lassen sich auf einem anderen Geraet beantwortete
    /// Mail-Einladungen auch hier ausblenden.
    private(set) var serverAnsweredUids: Set<String> = []

    func setServerAnsweredUids(_ uids: Set<String>) {
        serverAnsweredUids = uids
    }

    /// Run 19.09. (Feedback Accountwechsel): kompletten Stand verwerfen -
    /// die alten accountKey-Guards liessen sonst die Einladungen des
    /// vorherigen Accounts stehen bzw. blockierten das Update.
    func resetForNewAccount() {
        calendarInvites = []
        mailInvites = []
        serverAnsweredUids = []
        accountKey = ""
    }

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
        // Run 19.09. (Feedback): keine Doppelanzeige - eine Mail-Einladung,
        // deren Termin bereits als offene Kalender-Einladung vorliegt,
        // wird ausgeblendet (UID-basiert).
        let openCalendarUids = Set(calendarInvites.map { $0.uid.lowercased() }.filter { !$0.isEmpty })
        let deduped = invites.filter { invite in
            let uid = invite.eventUID.lowercased()
            return uid.isEmpty || !openCalendarUids.contains(uid)
        }
        let newSig = deduped.map { $0.id }.sorted().joined(separator: ",")
        let oldSig = mailInvites.map { $0.id }.sorted().joined(separator: ",")
        if newSig != oldSig {
            mailInvites = deduped
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
        serverAnsweredUids = []
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

    /// Run 22.09.: Erinnerungs-Overrides zu einer Antwort entfernen
    /// (UID- und Message-Key).
    nonisolated static func clearReminderOverride(uid: String, inviteId: String?) {
        if !uid.isEmpty {
            var byUid = UserDefaults.standard.dictionary(forKey: reminderOverridesUIDKey) as? [String: [Int]] ?? [:]
            byUid.removeValue(forKey: uid.lowercased())
            UserDefaults.standard.set(byUid, forKey: reminderOverridesUIDKey)
        }
        if let inviteId, !inviteId.isEmpty {
            var dict = UserDefaults.standard.dictionary(forKey: reminderOverridesKey) as? [String: [Int]] ?? [:]
            dict.removeValue(forKey: inviteId)
            UserDefaults.standard.set(dict, forKey: reminderOverridesKey)
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
            // Run 19.09.: auch den Antwort-Status-Marker aufraeumen (wurde
            // bisher nie entfernt und wuchs unbefristet).
            var statuses = UserDefaults.standard.dictionary(forKey: "invitations_answered_status_uid") as? [String: String] ?? [:]
            for uid in expiredUids { statuses.removeValue(forKey: uid) }
            UserDefaults.standard.set(statuses, forKey: "invitations_answered_status_uid")
            // Und den persistenten "nicht im Kalender"-Marker.
            var notInCal = Set(UserDefaults.standard.stringArray(forKey: "invitations_not_in_calendar_ids") ?? [])
            for uid in expiredUids { notInCal.remove(uid) }
            UserDefaults.standard.set(Array(notInCal), forKey: "invitations_not_in_calendar_ids")
            // Ausstehende Entfernungen abgelaufener Termine verwerfen.
            var pending = Set(UserDefaults.standard.stringArray(forKey: pendingRemovalKey) ?? [])
            for uid in expiredUids { pending.remove(uid) }
            UserDefaults.standard.set(Array(pending), forKey: pendingRemovalKey)
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
    /// Run 22.09.: Einheitlicher Inbox-Scan fuer Foreground, Auto-Refresh
    /// und BGAppRefresh - loest bei Bedarf die Inbox-ID auf und ruft den
    /// eigentlichen Scan auf.
    func scanInbox(accountId: String, accountKey: String, ownEmail: String,
                   inboxJmapId: String?, limit: Int = 40,
                   client: JmapClient, api: JmapApi) async {
        var mailboxId = inboxJmapId ?? ""
        if mailboxId.isEmpty {
            guard let boxes = try? await api.getMailboxes(accountId: accountId),
                  let inbox = boxes.first(where: { ($0["role"] as? String) == "inbox" }),
                  let id = inbox["id"] as? String, !id.isEmpty else { return }
            mailboxId = id
        }
        do {
            let resp = try await api.queryEmails(accountId: accountId,
                                                 inMailboxId: mailboxId,
                                                 limit: limit, position: 0)
            let ids = (resp["ids"] as? [String]) ?? []
            guard !ids.isEmpty else {
                await setMailInvites([], accountKey: accountKey)
                return
            }
            let detailed = try await api.getEmails(
                accountId: accountId,
                ids: ids,
                bodyProperties: ["subject", "from", "keywords", "attachments", "partId", "blobId", "size", "type", "name", "disposition", "cid"],
                fetchAllBodyValues: true
            )
            await scanMailInvites(accountId: accountId, accountKey: accountKey,
                                  ownEmail: ownEmail, candidates: detailed,
                                  client: client, api: api)
        } catch {
            SouveraLog.write("Invitations", "scanInbox failed: \(error)")
        }
    }

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
            // Run 19.09. (Feedback: Zeiten erst nach Klick): zusaetzlich
            // inlineAttachments pruefen - fetchInvitationDetails findet
            // den Part dort, der Scan bisher nicht.
            let attachments = ((json["attachments"] as? [[String: Any]]) ?? [])
                + ((json["inlineAttachments"] as? [[String: Any]]) ?? [])
            let icsAttachment = attachments.first(where: {
                ($0["type"] as? String)?.lowercased().contains("calendar") == true
                    || (($0["name"] as? String)?.lowercased().hasSuffix(".ics") == true)
            })
            guard subjectHint || cancelHint || icsAttachment != nil else { continue }

            var parsedEvent: CalendarEventModel?
            var invitationICS: String?
            // Run 22.09. (Feedback: Erkennung dauerte lange): Bereits
            // aufgeloeste Einladungen wiederverwenden - kein erneuter
            // ICS-Blob-Download bei jedem Scan (Throttle-freundlich).
            if let existing = mailInvites.first(where: { $0.messageId == messageId }) {
                parsedEvent = existing.event
                invitationICS = existing.rawICS
            }
            if invitationICS == nil, parsedEvent == nil,
               let att = icsAttachment, let blobId = att["blobId"] as? String {
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

            // Run 19.09. (Feedback Cross-Device: "auf iPhone beantwortet,
            // iPad zeigt sie weiter"): Ist der Termin laut Server bereits
            // beantwortet (PARTSTAT != needs-action), die Mail-Einladung
            // hier ausblenden UND die Mail in den Papierkorb verschieben -
            // damit ist der Stand geraeteuebergreifend konsistent.
            // Run 22.09. (Feedback: Absage-Mail verschwand wiederholt): Das
            // gilt NUR fuer echte Einladungen - eine Absage-Mail
            // ("Abgesagt: …") ist eine Information des Organisators und darf
            // NICHT automatisch getrasht werden. Ausserdem wird die Mail als
            // beantwortet markiert, damit sie nach einem manuellen
            // Zurueckverschieben nicht erneut verarbeitet wird.
            let isCancelMail = cancelHint || (invitationICS.map {
                (Self.quickExtract($0, key: "METHOD") ?? "").uppercased() == "CANCEL"
            } ?? false)
            let candidateUID = parsedEvent?.uid
                ?? invitationICS.flatMap { Self.quickExtract($0, key: "UID") }
                ?? ""
            if !isCancelMail, !candidateUID.isEmpty,
               serverAnsweredUids.contains(candidateUID.lowercased()) {
                SouveraLog.write("Invitations", "skip server-answered invite uid=\(candidateUID) mail=\(messageId)")
                Self.markAnswered(messageId: messageId, eventEnd: parsedEvent?.end)
                Task { await SouveraInviteMailSender.shared.moveToTrash(messageId: messageId) }
                continue
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
            // Run 19.09. (Feedback Absage ohne ICS): rawICS AUCH bei
            // Parse-Fehler behalten - eventUID/quickExtract findet die
            // echte UID dann trotzdem (Absage-Entfernen scheiterte sonst
            // mit uid=).
            if kind == .cancel {
                SouveraLog.write("Invitations", "cancel mail \(messageId): ics=\(invitationICS != nil) parsed=\(parsedEvent != nil)")
            }
            invites.append(SouveraMailInvitation(
                id: messageId,
                messageId: messageId,
                accountId: accountId,
                subject: subject,
                from: from,
                organizerEmail: parsedEvent?.organizerEmail ?? from,
                event: parsedEvent,
                rawICS: invitationICS,
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
            // Run 22.09. (Feedback: einheitliche Ablehnung, Std-CalDAV-
            // Logik): Der Termin bleibt beim Ablehnen im Kalender stehen
            // (durchgestrichen, ohne Erinnerungen) - kein DELETE mehr.
        }
        var created = false
        if status != .declined, !resolved.isCancellation, !handledExisting {
            var createICS = resolved.rawICS
            if createICS == nil, let event = resolved.event {
                createICS = synthesizeICS(title: event.title, start: event.start, end: event.end,
                                          organizerEmail: resolved.organizerEmail)
            }
            if let ics = createICS {
                created = await SouveraInvitationCenter.shared.createCalendarEvent(
                    from: resolved, ics: ics, status: status.rawValue,
                    calendarHref: calendarHref, reminderMinutes: reminderMinutes)
            }
        }
        if !resolved.isCancellation, !resolved.eventUID.isEmpty {
            SouveraInvitationCenter.markAnsweredUid(resolved.eventUID, end: resolved.event?.end,
                                                    status: status.rawValue)
        }
        // Run 22.09. (Feedback: Server-iTIP): App-Antwortmail nur noch als
        // FALLBACK - bei Alternativvorschlag (Server-REPLY hat keinen
        // Freitext) oder wenn kein Kalender-Write gelungen ist. Sonst
        // versendet Nextcloud die Antwort selbst (PARTSTAT in CalDAV).
        let calendarWrite = handledExisting || created
        let needsAppMail = (altProposal?.isEmpty == false) || !calendarWrite
        if needsAppMail {
            let statusWord = NSLocalizedString(status.titleKey, comment: "")
            _ = await sendReply(invitation: resolved, statusWord: statusWord,
                                altProposal: altProposal)
        }
        SouveraLog.write("Invitations", "mail RSVP \(status.rawValue) uid=\(resolved.eventUID) calendarWrite=\(calendarWrite) appMail=\(needsAppMail)")
        markAnswered(messageId: resolved.messageId, eventEnd: resolved.event?.end)
        await MainActor.run {
            SouveraInvitationCenter.shared.removeMailInvitation(resolved.id)
        }
        // Run 19.09. (Feedback): Einladungsmail nach der Antwort serverseitig
        // in den Papierkorb - geraeteuebergreifend konsistent.
        let trashed = await SouveraInviteMailSender.shared.moveToTrash(messageId: resolved.messageId)
        SouveraLog.write("Invitations", "mail RSVP \(status.rawValue) uid=\(resolved.eventUID) mail->trash=\(trashed)")
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
        // Run 22.09. (Feedback: Server-iTIP): Zweistufig anlegen - erst mit
        // NEEDS-ACTION, danach den finalen PARTSTAT per PUT. Nur dieser
        // Wechsel triggert den iTIP-REPLY des Servers an den Organisator.
        let needsTwoStep = status.lowercased() != "needs-action"
        let createICS = needsTwoStep
            ? (CalendarViewModel.updatePartstat(ics: updated, attendeeEmail: me, status: "NEEDS-ACTION") ?? updated)
            : updated
        var created = await client.createEvent(calendarHref: target.href, ics: createICS, uid: uid)
        if created == nil, createICS != normalized {
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
        guard let created else {
            SouveraLog.write("Invitations", "calendar create FAILED uid=\(uid)")
            return false
        }
        SouveraLog.write("Invitations", "calendar create ok in \(target.displayName) uid=\(uid)")
        guard needsTwoStep else { return true }
        // Finalen PARTSTAT nachziehen (ETag-Retry) - erst dadurch sendet der
        // Server den iTIP-REPLY an den Organisator.
        var finalOK = await client.updateEvent(created, ics: updated)
        if !finalOK {
            let noEtag = CalDavEventEntry(calendarHref: created.calendarHref,
                                          href: created.href, etag: nil, ics: updated)
            finalOK = await client.updateEvent(noEtag, ics: updated)
        }
        SouveraLog.write("Invitations", "calendar create two-step PARTSTAT \(status) ok=\(finalOK) uid=\(uid)")
        return finalOK
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
            .map { Self.stripScheduleAgentParameter($0) }
            .joined(separator: "\r\n")
    }

    /// Run 22.09. (Feedback: Server-iTIP): `SCHEDULE-AGENT=CLIENT` in
    /// ATTENDEE-Zeilen unterdrueckt das Server-Scheduling - Parameter
    /// entfernen, damit Nextcloud den iTIP-REPLY selbst sendet.
    nonisolated static func stripScheduleAgentParameter(_ line: String) -> String {
        guard line.uppercased().hasPrefix("ATTENDEE"), let colon = line.firstIndex(of: ":") else { return line }
        var head = String(line[..<colon])
        head = head.replacingOccurrences(of: ";schedule-agent=client", with: "", options: .caseInsensitive)
        head = head.replacingOccurrences(of: ";schedule-agent=server", with: "", options: .caseInsensitive)
        return head + String(line[colon...])
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

    /// Ergebnis einer Absage-Entfernung (Run 19.09.): unterscheidet echtes
    /// "nicht gefunden" von einem Fehler (412/Netz) - nur ersteres darf
    /// dauerhaft quittiert werden.
    enum CancelRemovalResult { case removed, notFound, failed }

    /// Run 18.09. (Feedback): Matching UID ODER exakt Titel (normalisiert)
    /// + Start/Ende ±5 min - ohne ICS kein blur-Raten.
    func removeCancelledEvent(uid: String, title: String = "",
                              start: Date? = nil, end: Date? = nil) async -> CancelRemovalResult {
        let client = CalDavClient(account: nil)
        let calendars = await client.fetchCalendars()
        let calendar = Calendar.current
        let now = Date()
        let normalizedTitle = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
        var removed = false
        var found = false
        var deleteFailed = false
        for cal in calendars {
            let fetched = await client.fetchEvents(
                calendarHref: cal.href,
                start: calendar.date(byAdding: .day, value: -30, to: now) ?? now,
                end: calendar.date(byAdding: .day, value: 370, to: now) ?? now)
            for entry in fetched {
                var matches = false
                if !uid.isEmpty,
                   Self.icsHasUID(entry.ics, uid) {
                    matches = true
                } else if !normalizedTitle.isEmpty {
                    let candidate = ICSParser.parseEvents(
                        entry.ics, calendarHref: cal.href, href: entry.href,
                        etag: entry.etag).first
                    if let candidate {
                        let candidateTitle = candidate.title.lowercased()
                            .components(separatedBy: CharacterSet.alphanumerics.inverted)
                            .filter { !$0.isEmpty }.joined(separator: " ")
                        if candidateTitle == normalizedTitle {
                            // Run 19.09. (Feedback Absage ohne ICS): Mit
                            // Zeitraum praezise (±5 min), OHNE Zeitraum
                            // (reine Betreff-Absage) nur der normalisierte
                            // Titel - sonst wurde nie entfernt.
                            if let refStart = start, let refEnd = end {
                                let startDelta = abs(candidate.start.timeIntervalSince(refStart))
                                let endDelta = abs(candidate.end.timeIntervalSince(refEnd))
                                matches = startDelta <= 300 && endDelta <= 300
                            } else {
                                matches = true
                            }
                        }
                    }
                }
                if matches {
                    found = true
                    // Run 19.09.: ETag-Retry wie beim Ablehnen.
                    let ok = await CalendarViewModel.deleteEventEntry(entry, client: client)
                    SouveraLog.write("Invitations", "cancel remove uid=\(uid) title=\(title): \(ok)")
                    if ok { removed = true } else { deleteFailed = true }
                }
            }
        }
        if removed { return .removed }
        if found || deleteFailed {
            SouveraLog.write("Invitations", "cancel remove FAILED (uid=\(uid) title=\(title))")
            return .failed
        }
        SouveraLog.write("Invitations", "cancel remove: kein Match (uid=\(uid) title=\(title))")
        return .notFound
    }

    /// Run 19.09. (Feedback Absage): Absage-Mail aufloesen (ICS/UID per
    /// Lazy-Fetch) und den Termin entfernen; danach Mail in den Papierkorb.
    /// Ein Pfad fuer Detail- und Uebersichts-Button.
    /// Liefert true, wenn quittiert werden darf (entfernt ODER echt nicht
    /// gefunden); false nur bei echtem Fehler (Zeile bleibt stehen).
    @discardableResult
    func removeCancelledMail(_ invitation: SouveraMailInvitation) async -> Bool {
        let resolved = await resolveInvitation(invitation)
        let result = await removeCancelledEvent(
            uid: resolved.eventUID,
            title: resolved.displayTitle,
            start: resolved.event?.start,
            end: resolved.event?.end)
        // Run 22.09. (Feedback: Server-DELETE gestoert): Auch ein
        // Serverfehler wird LOKAL quittiert (Absage fuer den Nutzer
        // erledigt); der Termin wird fuer den gedrosselten Server-Retry
        // vorgemerkt. Keine harte Fehlermeldung.
        if case .failed = result, !resolved.eventUID.isEmpty {
            Self.addPendingRemoval(resolved.eventUID)
        }
        Self.markAnswered(messageId: resolved.messageId, eventEnd: resolved.event?.end)
        await MainActor.run {
            SouveraInvitationCenter.shared.removeMailInvitation(resolved.id)
        }
        _ = await SouveraInviteMailSender.shared.moveToTrash(messageId: resolved.messageId)
        return true
    }

    /// Run 19.09. (Feedback): Termin nach einer Ablehnung aus dem Kalender
    /// entfernen (DELETE mit ETag-Retry). Exakter UID-Match; entfernt ALLE
    /// Treffer (nicht nur den ersten) und meldet Erfolg, wenn mindestens
    /// einer geloescht wurde.
    @discardableResult
    func removeEventByUID(_ uid: String) async -> Bool {
        guard !uid.isEmpty else { return false }
        let client = CalDavClient(account: nil)
        let calendars = await client.fetchCalendars()
        let calendar = Calendar.current
        let now = Date()
        var removedAny = false
        var found = false
        for cal in calendars {
            let fetched = await client.fetchEvents(
                calendarHref: cal.href,
                start: calendar.date(byAdding: .day, value: -90, to: now) ?? now,
                end: calendar.date(byAdding: .day, value: 730, to: now) ?? now)
            for entry in fetched where Self.icsHasUID(entry.ics, uid) {
                found = true
                let ok = await CalendarViewModel.deleteEventEntry(entry, client: client)
                SouveraLog.write("Invitations", "decline remove uid=\(uid): \(ok)")
                if ok { removedAny = true }
            }
        }
        if !found {
            SouveraLog.write("Invitations", "decline remove uid=\(uid): nicht im Kalender")
        }
        return removedAny
    }

    // MARK: - Exakter UID-Match (Run 19.09.)
    //
    // Ersetzt das frühere `ics.contains("UID:<uid>")`, das UID-Praefixe
    // falsch traf (UID "abc" matchte "UID:abcd").

    nonisolated static func icsHasUID(_ ics: String, _ uid: String) -> Bool {
        let target = uid.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return false }
        let unfolded = ics
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "")
        for raw in unfolded.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count > 4, line.prefix(4).uppercased() == "UID:" else { continue }
            let value = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces).lowercased()
            if value == target { return true }
        }
        return false
    }

    // MARK: - Ausstehende Entfernungen (Run 19.09.)
    //
    // Schlaegt das Löschen eines abgelehnten Termins fehl (412/Netz),
    // wird die UID gemerkt und beim naechsten Kalender-Load erneut
    // versucht - die Antwort selbst gilt bereits als erteilt.

    private static let pendingRemovalKey = "invitations_pending_removal_uids"
    /// Run 22.09.: Zeitstempel je vorgemerkter UID (Drossel + Verfall).
    private static let pendingRemovalDatesKey = "invitations_pending_removal_dates"
    private static let pendingRemovalLastAttemptKey = "invitations_pending_removal_last_attempt"

    nonisolated static func addPendingRemoval(_ uid: String) {
        guard !uid.isEmpty else { return }
        let key = uid.lowercased()
        var uids = Set(UserDefaults.standard.stringArray(forKey: pendingRemovalKey) ?? [])
        uids.insert(key)
        UserDefaults.standard.set(Array(uids), forKey: pendingRemovalKey)
        var dates = UserDefaults.standard.dictionary(forKey: pendingRemovalDatesKey) as? [String: Double] ?? [:]
        dates[key] = Date().timeIntervalSince1970
        UserDefaults.standard.set(dates, forKey: pendingRemovalDatesKey)
    }

    nonisolated static func removePendingRemoval(_ uid: String) {
        guard !uid.isEmpty else { return }
        let key = uid.lowercased()
        var uids = Set(UserDefaults.standard.stringArray(forKey: pendingRemovalKey) ?? [])
        uids.remove(key)
        UserDefaults.standard.set(Array(uids), forKey: pendingRemovalKey)
        var dates = UserDefaults.standard.dictionary(forKey: pendingRemovalDatesKey) as? [String: Double] ?? [:]
        dates.removeValue(forKey: key)
        UserDefaults.standard.set(dates, forKey: pendingRemovalDatesKey)
    }

    nonisolated static func pendingRemovals() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pendingRemovalKey) ?? [])
    }

    /// Wird beim Kalender-Load aufgerufen; entfernt erfolgreich die
    /// vorgemerkten Termine und raeumt die Liste.
    func retryPendingRemovals() async {
        // Run 22.09.: gedrosselt (max. 1x/10 min) + Verfall nach 24 h -
        // vorher lief alle ~30 s ein 3er-DELETE-Sturm gegen einen Termin,
        // der serverseitig nicht loeschbar war.
        let now = Date()
        let lastAttempt = UserDefaults.standard.double(forKey: Self.pendingRemovalLastAttemptKey)
        guard now.timeIntervalSince1970 - lastAttempt >= 600 else { return }
        var pending = Self.pendingRemovals()
        guard !pending.isEmpty else { return }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.pendingRemovalLastAttemptKey)
        var dates = UserDefaults.standard.dictionary(forKey: Self.pendingRemovalDatesKey) as? [String: Double] ?? [:]
        for uid in pending {
            if let date = dates[uid], now.timeIntervalSince1970 - date > 86_400 {
                Self.removePendingRemoval(uid)
                pending.remove(uid)
            }
        }
        for uid in pending {
            if await removeEventByUID(uid) {
                Self.removePendingRemoval(uid)
            }
        }
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
        // Der Key wurde zuvor nur gelesen/aufgeraeumt, nie geschrieben -
        // die gewaehlte Erinnerung ging bei Neustart/Resolve verloren.
        let eventUID = invitation.eventUID
        if !eventUID.isEmpty {
            var byUid = UserDefaults.standard.dictionary(forKey: Self.reminderOverridesUIDKey) as? [String: [Int]] ?? [:]
            byUid[eventUID.lowercased()] = minutes
            UserDefaults.standard.set(byUid, forKey: Self.reminderOverridesUIDKey)
        }
        guard !eventUID.isEmpty else {
            // Noch kein Kalender-Termin: die Erinnerung wird beim Anlegen
            // angewandt (gueltiger Pfad, kein Fehler).
            SouveraLog.write("Invitations", "reminders deferred (keine UID fuer \(invitation.id))")
            return true
        }
        let client = CalDavClient(account: nil)
        let calendars = await client.fetchCalendars()
        let calendar = Calendar.current
        let now = Date()
        for cal in calendars {
            let fetched = await client.fetchEvents(
                calendarHref: cal.href,
                start: calendar.date(byAdding: .day, value: -90, to: now) ?? now,
                end: calendar.date(byAdding: .day, value: 730, to: now) ?? now)
            for entry in fetched where Self.icsHasUID(entry.ics, eventUID) {
                let updated = CalendarViewModel.setValarms(ics: entry.ics, minutes: minutes)
                if await client.updateEvent(entry, ics: updated) {
                    SouveraLog.write("Invitations", "reminders update uid=\(eventUID): true")
                    return true
                }
                // Run 19.09.: 412-Retry ohne If-Match (stale ETag).
                let noEtag = CalDavEventEntry(calendarHref: entry.calendarHref,
                                              href: entry.href, etag: nil, ics: entry.ics)
                let ok = await client.updateEvent(noEtag, ics: updated)
                SouveraLog.write("Invitations", "reminders update uid=\(eventUID): \(ok) (retry)")
                return ok
            }
        }
        // Run 22.09.: UID-Match fehlgeschlagen - das war bisher ein STILLES
        // "return true" und liess Erinnerungen verschwinden. Jetzt sichtbar.
        SouveraLog.write("Invitations", "reminders update uid=\(eventUID): kein Termin im Kalender gefunden")
        return false
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
            for entry in fetched where Self.icsHasUID(entry.ics, uid) {
                guard let partstat = CalendarViewModel.updatePartstat(
                    ics: entry.ics, attendeeEmail: me, status: status) else { continue }
                var updated = partstat
                if status.lowercased() == "declined" {
                    // Run 22.09. (Feedback): Ablehnen entfernt ALLE Erinnerungen.
                    updated = CalendarViewModel.setValarms(ics: updated, minutes: [])
                    Self.clearReminderOverride(uid: uid, inviteId: nil)
                } else {
                    let override = reminderMinutes ?? Self.reminderOverride(forUID: uid)
                    if let override {
                        updated = CalendarViewModel.setValarms(ics: updated, minutes: override)
                    } else {
                        updated = CalendarViewModel.ensureDefaultReminder(ics: updated, status: status)
                    }
                }
                let ok = await client.updateEvent(entry, ics: updated)
                SouveraLog.write("Invitations", "RSVP existing event uid=\(uid): \(ok)")
                // Run 19.09.: 412-Retry ohne If-Match (stale ETag).
                let finalOk: Bool
                if ok {
                    finalOk = true
                } else {
                    let noEtag = CalDavEventEntry(calendarHref: entry.calendarHref,
                                                  href: entry.href, etag: nil, ics: entry.ics)
                    finalOk = await client.updateEvent(noEtag, ics: updated)
                    SouveraLog.write("Invitations", "RSVP existing event uid=\(uid): \(finalOk) (retry)")
                }
                // Run 19.09. (Feedback): ICS zuruecklesen und den
                // serverseitigen PARTSTAT loggen (Cross-Device-Diagnose).
                if finalOk, let verify = await client.fetchEventICS(entry) {
                    let server = CalendarViewModel.serverPartstat(ics: verify, attendeeEmail: me)
                    SouveraLog.write("Invitations", "RSVP verify uid=\(uid): server PARTSTAT=\(server)")
                }
                return finalOk
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
