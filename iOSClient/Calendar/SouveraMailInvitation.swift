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
