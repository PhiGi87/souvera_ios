// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 03.11.: SwiftUI-Einstellungsseite für den Abwesenheitsassistenten
// (Vacation Responder), gehostet unter dem Mehr-Menü. Folgt dem
// HIG-Settings-Pattern (Form mit Sektionen) und dem Muster der anderen
// gepushten Souvera-Screens (host bar liefert Titel/Zurück über
// `pushHosted`, Speichern-Button im Toolbar-Trailing).
//
// Run 04.11.: Die Abwesenheit läuft komplett über die offizielle
// Nextcloud Out-of-Office OCS-API (dav-App, siehe
// SouveraOutOfOfficeOcsApi.swift). Der "Jetzt synchronisieren"-Button
// und die read-only NC-Sektion sind entfallen: der souvera_mail-Cron
// übernimmt die NC-Abwesenheit stündlich in den Sieve-Responder, ein
// manueller Sync ist nicht mehr möglich/nötig. Der "Betreff" heißt
// jetzt "Status" (OCS-Feld) und ist auf 100 Zeichen begrenzt.
//
// Zeitraum: leer = ab heute/ein Jahr - umgesetzt als "Zeitraum"-
// Toggle; wenn an, zwei date-only DatePickers mit Validierung (Bis >= Von).

import SwiftUI

struct SouveraVacationView: View {
    @State private var state = SouveraVacationState(enabled: false, subject: "", message: "", from: nil, to: nil, available: true)
    @State private var hasPeriod = false
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isSaved = false

    var body: some View {
        Form {
            if let errorMessage {
                errorSection(errorMessage)
            }
            availabilitySection
            if state.enabled {
                periodSection
                contentSection
            }
            footerSection
        }
        .disabled(isLoading || isSaving)
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

    /// Fehler-Banner mit Statuscode/Server-Message und Wiederholen-Button.
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

    private var availabilitySection: some View {
        Section {
            // Aus = löscht die OCS-Abwesenheit (Toggle-Semantik, ohne
            // Bestätigungsdialog - konsistent mit einem einfachen Schalter).
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
            // OCS-Feld "status": serverseitig auf 100 Zeichen begrenzt -
            // hier ebenfalls kappen, damit keine 400-Antwort entsteht.
            TextField(
                NSLocalizedString("_vacation_status_", value: "Status", comment: ""),
                text: Binding(
                    get: { state.subject },
                    set: { state.subject = String($0.prefix(100)) }
                )
            )
            .onChange(of: state.subject) { _, newValue in
                if newValue.count > 100 {
                    state.subject = String(newValue.prefix(100))
                }
            }
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
        } header: {
            Text(NSLocalizedString("_vacation_title_", value: "Vacation responder", comment: ""))
        } footer: {
            // Die NC-Abwesenheit wird vom souvera_mail-Cron stündlich
            // in den Sieve-Responder übernommen.
            Text(NSLocalizedString("_vacation_footer_", value: "The out-of-office note is synced with the mail server automatically (up to one hour).", comment: ""))
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
            // Präzises Fehler-Banner mit Statuscode/Server-Message.
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save() async {
        // Zeitraum-Toggle aus: keine Daten mitsenden (nil = ab heute/ein Jahr).
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
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
