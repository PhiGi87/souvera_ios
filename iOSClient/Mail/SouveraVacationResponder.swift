// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 04.11.: Abwesenheitsassistent (Vacation Responder) läuft
// KOMPLETT über die offizielle Nextcloud Out-of-Office OCS-API
// (dav-App, siehe SouveraOutOfOfficeOcsApi.swift). Die bisherigen
// souvera_mail-Endpunkte (/apps/souvera_mail/vacation...) sind für
// native Clients durch den CSRF-Check (HTTP 412) blockiert; der
// souvera_mail-Cron übernimmt die NC-Abwesenheit stündlich in den
// Sieve-Responder. Ein manueller Sync ist daher nicht mehr nötig.
//
// Mapping OCS-Datensatz ↔ SouveraVacationState:
//   enabled  = OCS-Datensatz existiert (GET 404 = kein Datensatz)
//   from/to  = firstDay/lastDay (device-local Dates, nil-tolerant)
//   subject  = status (≤ 100 Zeichen, OCS-Feld "status")
//   message  = message
//   available= immer true (die dav-App ist Kern-Nextcloud)
//
// Auth: HTTP Basic mit dem Nextcloud-User und dem App-Passwort des
// aktiven Accounts (tblAccount + NCPreferences-Passwort) - identisch
// zum bisherigen Schema (Login-Flow `SouveraMailLoginFlow`,
// Geräte-Registrierung `SouveraMailDeviceRegistrar`).

import Foundation

/// Zustand des Abwesenheitsassistenten, wie er in der UI gehalten wird.
struct SouveraVacationState: Equatable {
    /// Abwesenheit aktiv (ein OCS-Datensatz existiert).
    var enabled: Bool
    /// Kurztext der Abwesenheit (OCS "status", ≤ 100 Zeichen).
    var subject: String
    /// Text der Abwesenheitsnotiz.
    var message: String
    /// Start des Zeitraums (nil = ab heute beim Speichern).
    var from: Date?
    /// Ende des Zeitraums (nil = ein Jahr ab Start beim Speichern).
    var to: Date?
    /// true = die Abwesenheit lässt sich bearbeiten (dav-App vorhanden).
    var available: Bool

    static func unavailable() -> SouveraVacationState {
        SouveraVacationState(enabled: false, subject: "", message: "", from: nil, to: nil, available: false)
    }
}

/// Typisierte Fehler für die UI-Anzeige (NSLocalizedDescriptionKey).
enum SouveraVacationError: Error, LocalizedError {
    /// Kein aktiver Account bzw. unvollständige Account-Daten.
    case noAccount
    /// Ungültige Server-Antwort (kein OCS-Envelope / unerwartetes JSON).
    case invalidResponse
    /// Lokale Validierung fehlgeschlagen (Start nach Ende).
    case validation
    /// HTTP-Fehler mit Statuscode und optionaler Server-Message.
    case http(Int, String?)

    var errorDescription: String? {
        switch self {
        // Run 04.11.: Fallback-Value deckt alle Sprachen ohne eigene
        // lproj-Einträge ab (Transifex liefert spätere Übersetzungen).
        case .noAccount:
            return NSLocalizedString("_vacation_error_", value: "The vacation responder could not be saved.", comment: "")
        case .invalidResponse:
            return NSLocalizedString("_vacation_error_", value: "The vacation responder could not be saved.", comment: "")
        case .validation:
            return NSLocalizedString("_vacation_error_period_", value: "The start date must not be after the end date.", comment: "")
        case .http(let code, let message):
            // Run 04.11.: Statuscode + Server-Message präzise anzeigen
            // statt alles als "nicht verfügbar" zu werfen.
            let status = NSLocalizedString("_vacation_error_status_", value: "Request failed (%@)", comment: "")
            let base = String(format: status, "\(code)")
            if let message, !message.isEmpty {
                return "\(base): \(message)"
            }
            return base
        }
    }
}

/// Fassade des Abwesenheitsassistenten über die offizielle Nextcloud
/// Out-of-Office OCS-API (siehe Dateikopf und
/// `SouveraOutOfOfficeOcsApi`).
enum SouveraVacationResponder {

    /// Liest den Zustand. Kein OCS-Datensatz (HTTP 404 beim GET) ergibt
    /// einen leeren, aber editierbaren Zustand (available = true), damit
    /// das Formular leer erscheint.
    static func load(account: String? = nil) async throws -> SouveraVacationState {
        guard let record = try await SouveraOutOfOfficeOcsApi.get(account: account) else {
            return SouveraVacationState(enabled: false, subject: "", message: "", from: nil, to: nil, available: true)
        }
        return SouveraVacationState(
            enabled: true,
            subject: record.status,
            message: record.message,
            from: record.firstDay,
            to: record.lastDay,
            available: true
        )
    }

    /// Speichert den Zustand: aktiv → OCS set, inaktiv → OCS clear
    /// (löscht die Abwesenheit serverseitig; der souvera_mail-Cron
    /// zieht die Änderung spätestens nach einer Stunde in den
    /// Sieve-Responder).
    static func save(account: String? = nil, _ state: SouveraVacationState) async throws {
        guard state.enabled else {
            try await SouveraOutOfOfficeOcsApi.clear(account: account)
            return
        }
        // OCS verlangt firstDay/lastDay zwingend. Ohne Zeitraum in der
        // UI gilt: Start = heute, Ende = ein Jahr später (unbefristet).
        let firstDay = state.from ?? Calendar.current.startOfDay(for: Date())
        let lastDay = state.to ?? Calendar.current.date(byAdding: .year, value: 1, to: firstDay) ?? firstDay
        do {
            try await SouveraOutOfOfficeOcsApi.set(
                account: account,
                firstDay: firstDay,
                lastDay: lastDay,
                status: state.subject,
                message: state.message,
                replacementUserId: nil
            )
        } catch let error as SouveraVacationError {
            // Run 04.11.: Selbstheilung beim 500-Pfad. Der Server liest
            // beim Schreiben die calendar-availability (Scheduling-Inbox)
            // ungeschützt mit Sabre VObject; ein korrupter Wert wirft
            // uncaught → HTTP 500 (siehe
            // SouveraCalendarAvailabilityRepair.swift, Dateikopf).
            // Diagnose + Repair laufen, danach GENAU EIN Save-Retry.
            // Alle anderen Fehler (und gescheiterte Repairs) fliegen
            // unverändert weiter.
            guard case .http(500, _) = error else { throw error }
            SouveraLog.write("Vacation", "save 500 -> availability repair")
            let repaired = try? await SouveraCalendarAvailabilityRepair.diagnoseAndRepair(account: account)
            guard repaired == true else {
                SouveraLog.write("Vacation", "save after repair: repair nicht möglich -> Fehler weiterreichen")
                throw error
            }
            do {
                try await SouveraOutOfOfficeOcsApi.set(
                    account: account,
                    firstDay: firstDay,
                    lastDay: lastDay,
                    status: state.subject,
                    message: state.message,
                    replacementUserId: nil
                )
                SouveraLog.write("Vacation", "save after repair status=ok")
            } catch let retryError as SouveraVacationError {
                SouveraLog.write("Vacation", "save after repair status=failed (\(retryError))")
                throw retryError
            }
        }
    }
}
