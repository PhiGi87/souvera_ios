// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 03.11.: SwiftUI-Einstellungsseite für den Abwesenheitsassistenten
// (Vacation Responder), gehostet unter dem Mehr-Menü. Folgt dem
// HIG-Settings-Pattern (Form mit Sektionen) und dem Muster der anderen
// gepushten Souvera-Screens (host bar liefert Titel/Zurück über
// `pushHosted`, Speichern-Button im Toolbar-Trailing).
//
// Run 04.11.: Fehlerbehandlung präzisiert - Lade-/Save-Fehler werden
// nicht mehr pauschal als "nicht verfügbar" geworfen, sondern als
// Fehler-Banner mit Statuscode/Server-Message + Wiederholen-Button
// gezeigt. Nur available:false bzw. 404 bleibt der unavailable-Hinweis.
// Neu: "Jetzt synchronisieren"-Button (ruft syncNow, lädt danach neu)
// und eine read-only Sektion "In Nextcloud gepflegte Abwesenheit"
// (aus GET /vacation/state, wie die Webmail-"Von Nextcloud übernehmen"-
// Anzeige). Kein Follow-Toggle - dafür existiert kein Server-Endpunkt.
//
// Zeitraum: leer = ab sofort/unbefristet - umgesetzt als "Zeitraum"-
// Toggle; wenn an, zwei date-only DatePickers mit Validierung (Bis >= Von).

import SwiftUI

struct SouveraVacationView: View {
    @State private var state = SouveraVacationState(enabled: false, subject: "", message: "", from: nil, to: nil, available: true)
    @State private var combinedState: SouveraVacationCombinedState?
    @State private var hasPeriod = false
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isSyncing = false
    @State private var errorMessage: String?
    @State private var isSaved = false

    var body: some View {
        Form {
            // Server ohne Vacation-Unterstützung: nur Hinweis, keine Bearbeitung.
            // Run 04.11.: Fallback-Values decken alle Sprachen ohne eigene
            // lproj-Einträge ab (Transifex liefert spätere Übersetzungen).
            if !state.available {
                Section {
                    Label(NSLocalizedString("_vacation_unavailable_", value: "The mail server does not support an out-of-office note", comment: ""), systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            } else {
                if let errorMessage {
                    errorSection(errorMessage)
                }
                // Read-only: die in Nextcloud gepflegte Abwesenheit
                // (Quelle: GET /vacation/state) - wie in der Webmail.
                if let combined = combinedState, combined.ncActive {
                    ncAbsenceSection(combined)
                }
                availabilitySection
                if state.enabled {
                    periodSection
                    contentSection
                }
                footerSection
            }
        }
        .disabled(isLoading || isSaving || !state.available)
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .alert(
            NSLocalizedString("_vacation_saved_", value: "Saved", comment: ""),
            isPresented: $isSaved
        ) {
            Button(NSLocalizedString("_ok_", comment: ""), role: .cancel) {}
        }
        .task { await load() }
    }

    // MARK: - Sektionen

    /// Run 04.11.: Fehler-Banner mit Statuscode/Server-Message und
    /// Wiederholen-Button statt catch-all → "nicht verfügbar".
    private func errorSection(_ message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button(NSLocalizedString("_vacation_retry_", value: "Retry", comment: "")) {
                    Task { await load() }
                }
            }
        }
    }

    /// Read-only Anzeige der NC-Abwesenheit (start/end/short/long/
    /// replacement aus dem combined State).
    private func ncAbsenceSection(_ combined: SouveraVacationCombinedState) -> some View {
        Section {
            if !combined.start.isEmpty || !combined.end.isEmpty {
                LabeledContent(
                    NSLocalizedString("_vacation_nc_period_", value: "Period", comment: ""),
                    value: [combined.start, combined.end].filter { !$0.isEmpty }.joined(separator: " – ")
                )
            }
            if !combined.short.isEmpty {
                LabeledContent(
                    NSLocalizedString("_vacation_subject_", value: "Subject", comment: ""),
                    value: combined.short
                )
            }
            if !combined.long.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("_vacation_message_", value: "Message", comment: ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(combined.long)
                }
            }
            if !combined.replacement.isEmpty {
                LabeledContent(
                    NSLocalizedString("_vacation_nc_replacement_", value: "Replacement", comment: ""),
                    value: combined.replacement
                )
            }
            if !combined.inEffect {
                Text(NSLocalizedString("_vacation_nc_planned_", value: "This period is scheduled and has not started yet.", comment: ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(NSLocalizedString("_vacation_nc_absence_", value: "Out of office in Nextcloud", comment: ""))
        }
    }

    private var availabilitySection: some View {
        Section {
            Toggle(NSLocalizedString("_vacation_enabled_", value: "Active", comment: ""), isOn: $state.enabled)
        }
    }

    private var periodSection: some View {
        Section {
            Toggle(NSLocalizedString("_vacation_period_", value: "Period", comment: ""), isOn: $hasPeriod)
            if hasPeriod {
                DatePicker(
                    NSLocalizedString("_vacation_from_", value: "From", comment: ""),
                    selection: Binding(
                        get: { state.from ?? Date() },
                        set: { state.from = $0; validatePeriod() }
                    ),
                    displayedComponents: .date
                )
                DatePicker(
                    NSLocalizedString("_vacation_to_", value: "To", comment: ""),
                    selection: Binding(
                        get: { state.to ?? state.from ?? Date() },
                        set: { state.to = $0; validatePeriod() }
                    ),
                    in: (state.from ?? Date.distantPast)...,
                    displayedComponents: .date
                )
            }
        }
    }

    private var contentSection: some View {
        Section {
            TextField(NSLocalizedString("_vacation_subject_", value: "Subject", comment: ""), text: $state.subject)
            TextField(
                NSLocalizedString("_vacation_message_", value: "Message", comment: ""),
                text: $state.message,
                axis: .vertical
            )
            .lineLimit(4...10)
        }
    }

    private var footerSection: some View {
        Section {
            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Text(NSLocalizedString("_vacation_save_", value: "Save", comment: ""))
                }
            }
            // Run 04.11.: manueller NC→Sieve-Sync (POST /vacation/sync),
            // danach den Zustand neu laden.
            Button {
                Task { await syncNow() }
            } label: {
                if isSyncing {
                    ProgressView()
                } else {
                    Text(NSLocalizedString("_vacation_sync_now_", value: "Sync now", comment: ""))
                }
            }
            .disabled(isSyncing)
        } header: {
            Text(NSLocalizedString("_vacation_title_", value: "Vacation responder", comment: ""))
        } footer: {
            Text(NSLocalizedString("_vacation_footer_", value: "Replies are sent once per sender while the responder is active.", comment: ""))
        }
    }

    // MARK: - Logik

    private func validatePeriod() {
        // "Bis" darf nicht vor "Von" liegen - sonst den Endzeitpunkt anheben.
        if let from = state.from, let to = state.to, to < from {
            state.to = from
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await SouveraVacationResponder.load()
            state = loaded
            hasPeriod = loaded.from != nil || loaded.to != nil
            errorMessage = nil
        } catch {
            // Run 04.11.: kein catch-all → .unavailable() mehr. Nur 404
            // (alter Server) bleibt über load() der unavailable-Hinweis;
            // alle anderen Fehler (inkl. 412 CSRF, 5xx) landen im
            // präzisen Fehler-Banner mit Statuscode/Server-Message.
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        // Combined State ist Best-Effort: Fehler → Sektion einfach
        // weglassen (Server ohne /state-Route o. ä.).
        combinedState = try? await SouveraVacationResponder.loadState()
    }

    private func save() async {
        // Zeitraum-Toggle aus: keine Daten mitsenden (nil = ab sofort/unbefristet).
        var payload = state
        if !hasPeriod {
            payload.from = nil
            payload.to = nil
        }
        validatePeriod()
        isSaving = true
        defer { isSaving = false }
        do {
            try await SouveraVacationResponder.save(payload)
            errorMessage = nil
            isSaved = true
        } catch {
            // Präzise Meldung: Statuscode + Server-Message (z. B. 412
            // CSRF, solange der Server-Patch fehlt).
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await SouveraVacationResponder.syncNow()
            errorMessage = nil
            // Nach dem Sync den Zustand neu laden (Sieve hat ggf. den
            // Vacation-Block aktualisiert).
            await load()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
