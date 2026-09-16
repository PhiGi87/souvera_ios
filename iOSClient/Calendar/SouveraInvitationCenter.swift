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

        var invites: [SouveraMailInvitation] = []
        for json in candidates {
            let subject = (json["subject"] as? String) ?? ""
            let keywords = (json["keywords"] as? [String: Any]) ?? [:]
            let isRead = keywords["$seen"] as? Bool == true
            guard !isRead else { continue }
            let from = Self.firstFromAddress(json)
            let lowerSubject = subject.lowercased()
            let subjectHint = lowerSubject.hasPrefix("invitation:")
                || lowerSubject.hasPrefix("einladung:")
                || lowerSubject.hasPrefix("invito:")
                || lowerSubject.hasPrefix("invitation :")
            let attachments = (json["attachments"] as? [[String: Any]]) ?? []
            let icsAttachment = attachments.first(where: {
                ($0["type"] as? String)?.lowercased().contains("calendar") == true
                    || (($0["name"] as? String)?.lowercased().hasSuffix(".ics") == true)
            })
            guard subjectHint || icsAttachment != nil else { continue }
            guard let messageId = json["id"] as? String else { continue }

            var parsedEvent: CalendarEventModel?
            if let att = icsAttachment, let blobId = att["blobId"] as? String {
                let data = try? await client.downloadBlob(
                    accountId: accountId, blobId: blobId, mimeType: "text/calendar")
                if let ics = String(data: data ?? Data(), encoding: .utf8) {
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

    // MARK: - Antworten per iTIP-REPLY-Mail (externe Organisatoren)

    /// Baut eine iTIP-REPLY-Mail (text/calendar Attachment + Text) und
    /// laedt sie als Temp-Datei fuer die Send-Pipeline.
    static func makeReplyMail(for invitation: SouveraMailInvitation,
                              status: String) -> OutgoingMessage? {
        let organizer = invitation.displayOrganizer
        guard invitation.organizerEmail.contains("@") || organizer.contains("@") else { return nil }
        let to = invitation.organizerEmail.contains("@")
            ? invitation.organizerEmail
            : organizer

        let statusWord: String
        switch status {
        case "ACCEPTED": statusWord = NSLocalizedString("_invitations_accept_", comment: "")
        case "TENTATIVE": statusWord = NSLocalizedString("_invitations_tentative_", comment: "")
        default: statusWord = NSLocalizedString("_invitations_decline_", comment: "")
        }

        let body = String(
            format: NSLocalizedString("_invitations_reply_body_", comment: ""),
            statusWord, invitation.displayTitle)

        var outgoing = OutgoingMessage()
        outgoing.to = [to]
        outgoing.subject = "Reply: \(invitation.displayTitle)"
        outgoing.body = body

        if let event = invitation.event {
            let ics = Self.buildReplyICS(event: event, attendeeEmail: "", status: status)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("invite-reply-\(UUID().uuidString).ics")
            do {
                try ics.data(using: .utf8)?.write(to: url)
                outgoing.attachments = [OutgoingAttachment(
                    name: "invite.ics", mimeType: "text/calendar", fileURL: url)]
            } catch {
                SouveraLog.write("Invitations", "reply ics write failed: \(error)")
            }
        }
        return outgoing
    }

    /// Minimale iTIP-REPLY-ICS (METHOD:REPLY) mit dem eigenen PARTSTAT.
    static func buildReplyICS(event: CalendarEventModel, attendeeEmail: String, status: String) -> String {
        let me = attendeeEmail.isEmpty ? CalendarViewModel.ownAttendeeEmail() : attendeeEmail
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        return [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Souvera//Invite Reply//DE",
            "METHOD:REPLY",
            "BEGIN:VEVENT",
            "UID:\(event.uid)",
            "SEQUENCE:\(event.sequence)",
            "DTSTAMP:\(stamp)",
            "ORGANIZER;CN=\(escapeICS(event.organizerName)):mailto:\(event.organizerEmail)",
            "ATTENDEE;PARTSTAT=\(status):mailto:\(me)",
            "END:VEVENT",
            "END:VCALENDAR"
        ].joined(separator: "\r\n")
    }

    private static func escapeICS(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
    }
}
