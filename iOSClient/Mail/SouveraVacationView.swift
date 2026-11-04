// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 03.11.: SwiftUI-Einstellungsseite für den Abwesenheitsassistenten
// (Vacation Responder), gehostet unter dem Mehr-Menü. Folgt dem
// HIG-Settings-Pattern (Form mit Sektionen) und dem Muster der anderen
// gepushten Souvera-Screens (host bar liefert Titel/Zurück über
// `pushHosted`, Speichern-Button im Toolbar-Trailing).
//
// Zeitraum: leer = ab sofort/unbefristet - umgesetzt als "Zeitraum"-
// Toggle; wenn an, zwei date-only DatePickers mit Validierung (Bis >= Von).

import SwiftUI

struct SouveraVacationView: View {
    @State private var state = SouveraVacationState(enabled: false, subject: "", message: "", from: nil, to: nil, available: true)
    @State private var hasPeriod = false
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

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
            NSLocalizedString("_vacation_error_", value: "The vacation responder could not be saved.", comment: ""),
            isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(NSLocalizedString("_ok_", comment: ""), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await load() }
    }

    // MARK: - Sektionen

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
        } catch {
            // Server erreichbar, aber Vacation nicht nutzbar: sauber
            // als "nicht verfügbar" zeigen statt Fehler-Banner.
            state = .unavailable()
        }
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
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
