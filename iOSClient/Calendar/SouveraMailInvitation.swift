// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//

import Foundation

/// Eine per Mail erhaltene Termineinladung (iMIP). `ics` ist gesetzt,
/// wenn ein text/calendar-Part gefunden und geparst wurde - ohne ICS
/// kann nur per Antwort-E-Mail geantwortet werden (kein Kalender-Write).
struct SouveraMailInvitation: Identifiable {
    let id: String
    /// JMAP-Id der Einladungsmail (fuer "gelesen markieren").
    let messageId: String
    let accountId: String
    let subject: String
    let from: String
    let organizerEmail: String
    /// Geparster Termin (aus dem text/calendar-Part); nil bei reiner
    /// Text-Einladung ohne ICS.
    let event: CalendarEventModel?
    /// Original-ICS der Einladung (fuer Kalender-Create mit PARTSTAT-
    /// Aenderung und VALARM-Ergaenzung).
    let rawICS: String?
    /// Run 17.09.: Lazy-Aufloesung bereits versucht (kein doppelter Fetch).
    var resolved: Bool = false
    /// Zeitraum, in dem die Mail gesehen wurde (fuer Duplikat-Gate).
    let receivedAt: Date
    /// Run 18.09.: Art der iTIP-Nachricht - "cancel" = Absage durch den
    /// Organisator (manuelles Entfernen ueber Button), "invitation" =
    /// neu/erneut (bei hoeherer SEQUENCE alte Antwort verwerfen).
    var kind: Kind = .invitation
    var sequence: Int = 0

    enum Kind: String {
        case invitation, cancel
    }
}

extension SouveraMailInvitation {
    var isCancellation: Bool { kind == .cancel }

    /// Echte Termin-UID (nicht die Mail-ID) - fuer UID-Match im Kalender.
    var eventUID: String {
        if let event, !event.uid.isEmpty, event.uid != messageId { return event.uid }
        if let rawICS, let uid = SouveraInvitationCenter.quickExtract(rawICS, key: "UID") {
            return uid
        }
        return ""
    }
}

extension SouveraMailInvitation {
    var displayTitle: String {
        event?.title ?? subject
    }

    var displayOrganizer: String {
        if let name = event?.organizerName, !name.isEmpty { return name }
        if let mail = event?.organizerEmail, !mail.isEmpty { return mail }
        return from
    }

    var needsAction: Bool {
        event?.ownPartstat == "needs-action" || event == nil
    }
}
