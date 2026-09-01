// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2024 Aditya Tyagi
// SPDX-FileCopyrightText: 2024 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import NextcloudKit
import FirebaseCrashlytics

/// Settings view for Nextcloud
@MainActor
struct NCSettingsView: View {
    // State to control the visibility of the acknowledgements view
    @State private var showLanguageRestart = false
    // State to control the visibility of the passcode view
    @State private var showPasscode = false
    // State to contorl the visibility of the change passcode view
    @State private var showChangePasscode = false
    // State to control the visibility of the Policy view
    // State to control the visibility of the Source Code  view
    // Logs teilen: Bestätigung, Sendestatus und Ergebnis-Overlay
    @State private var showLogsConfirm = false
    @State private var isSendingLogs = false
    @State private var logsResult: (success: Bool, message: String)?
    // Push-Diagnose-Sheet
    @State private var showPushDiagnostics = false
    // Cache leeren: Bestätigung + Ergebnis-Overlay
    @State private var showClearCacheConfirm = false
    @State private var clearCacheResult: String?
    // Object of ViewModel of this view
    @ObservedObject var model: NCSettingsModel

    var capabilities: NKCapabilities.Capabilities {
        NCNetworking.shared.capabilities[model.controller?.account ?? ""] ?? NKCapabilities.Capabilities()
    }

    var body: some View {
        Form {
            // `Privacy` Section
            Section(content: {
                Button(action: {
                    showPasscode.toggle()
                }, label: {
                    HStack {
                        Image(systemName: model.isLockActive ? "lock" : "lock.open")
                            .font(.icon())
                            .foregroundColor(Color(NCBrandColor.shared.iconImageColor))
                            .opacity(NCBrandOptions.shared.enforce_passcode_lock ? 0.5 : 1)
                            .frame(width: 39)

                        Text(model.isLockActive ? NSLocalizedString("_lock_active_", comment: "") : NSLocalizedString("_lock_not_active_", comment: ""))
                            .font(.body)
                    }
                })
                .tint(Color(NCBrandColor.shared.textColor))
                .disabled(NCBrandOptions.shared.enforce_passcode_lock)
            }, header: {
                Text(NSLocalizedString("_privacy_", comment: ""))
                    .font(.headline)
            }, footer: {
                if NCBrandOptions.shared.enforce_passcode_lock {
                    Text(NSLocalizedString("_lock_cannot_disable_mdm_", comment: ""))
                        .font(.footnote)
                }
            })

            Section(content: {
                Toggle(NSLocalizedString("_enable_touch_face_id_", comment: ""), isOn: $model.enableTouchFaceID)
                    .font(.body)
                    .disabled(!model.isLockActive)
                    .onChange(of: model.enableTouchFaceID) {
                        model.updateTouchIDSetting()
                    }
            }, footer: {
                if !model.isLockActive {
                    Text(NSLocalizedString("_touch_face_id_requires_passcode_", comment: ""))
                        .font(.footnote)
                }
            })
            .tint(Color(NCBrandColor.shared.getElement(account: model.session.account)))

            if model.isLockActive {
                Section(content: {
                    Group {
                        // Change passcode
                        Button(action: {
                            showChangePasscode.toggle()
                        }, label: {
                            VStack {
                                Text(NSLocalizedString("_change_lock_passcode_", comment: ""))
                                    .font(.body)
                                    .tint(Color(NCBrandColor.shared.textColor))
                            }
                        })
                        if !NCBrandOptions.shared.enforce_passcode_lock {
                            // Do not ask for passcode on startup
                            Toggle(NSLocalizedString("_lock_protection_no_screen_", comment: ""), isOn: $model.lockScreen)
                                .font(.body)
                                .onChange(of: model.lockScreen) {
                                    model.updateLockScreenSetting()
                                }
                        }

                        // Reset app wrong attempts
                        Toggle(NSLocalizedString("_reset_wrong_passcode_option_", comment: ""), isOn: $model.resetWrongAttempts)
                            .font(.body)
                            .onChange(of: model.resetWrongAttempts) {
                                model.updateResetWrongAttemptsSetting()
                            }
                    }
                }, footer: {
                    Text(String(format: NSLocalizedString("_reset_wrong_passcode_desc_", comment: ""), NCBrandOptions.shared.resetAppPasscodeAttempts))
                        .font(.footnote)

                })
                .tint(Color(NCBrandColor.shared.getElement(account: model.session.account)))
            }

            if !NCBrandOptions.shared.enforce_privacyScreenEnabled {
                Section(content: {
                    // Splash screen when app inactive
                    Toggle(NSLocalizedString("_privacy_screen_", comment: ""), isOn: $model.privacyScreen)
                        .font(.body)
                        .onChange(of: model.privacyScreen) {
                            model.updatePrivacyScreenSetting()
                        }
                }, footer: {
                    Text(NSLocalizedString("_privacy_screen_footer_", comment: ""))
                        .font(.footnote)
                })
                .tint(Color(NCBrandColor.shared.getElement(account: model.session.account)))
            }

            // Display
            // Standard-Kalenderansicht
            Section(header: Text(NSLocalizedString("_settings_calendar_default_view_", comment: "")).font(.headline), content: {
                Picker(NSLocalizedString("_settings_calendar_default_view_", comment: ""), selection: Binding(
                    get: { SouveraCalendarSettings.defaultView },
                    set: { SouveraCalendarSettings.setDefaultView($0) }
                )) {
                    Text(NSLocalizedString("_calendar_day_", comment: "")).tag("day")
                    Text(NSLocalizedString("_calendar_three_days_", comment: "")).tag("threeDay")
                    Text(NSLocalizedString("_calendar_month_", comment: "")).tag("month")
                }
                .pickerStyle(.segmented)
            })
            // Auto-Refresh (Mail & Kalender)
            Section(header: Text(NSLocalizedString("_settings_auto_refresh_", comment: "")).font(.headline), content: {
                Picker(NSLocalizedString("_settings_auto_refresh_interval_", comment: ""), selection: Binding(
                    get: { SouveraAutoRefresh.intervalSeconds },
                    set: { SouveraAutoRefresh.set(seconds: $0) }
                )) {
                    ForEach(SouveraAutoRefresh.presets, id: \.self) { seconds in
                        Text(SouveraAutoRefresh.label(for: seconds))
                            .tag(seconds)
                    }
                }
                .pickerStyle(.segmented)
            })
            // Sprache (In-App-Wechsel, wirkt nach Neustart)
            Section(header: Text(NSLocalizedString("_settings_language_", comment: "")).font(.headline), content: {
                Picker(NSLocalizedString("_settings_language_", comment: ""), selection: Binding(
                    get: { SouveraLanguage.currentCode },
                    set: { code in
                        SouveraLanguage.set(code)
                        showLanguageRestart = true
                    }
                )) {
                    Text(NSLocalizedString("_souvera_language_system_", comment: "")).tag("system")
                    Text("Deutsch").tag("de")
                    Text("English").tag("en")
                    Text("Español").tag("es")
                    Text("Français").tag("fr")
                    Text("Nederlands").tag("nl")
                }
                .pickerStyle(.menu)
            })
            Section(header: Text(NSLocalizedString("_display_", comment: "")).font(.headline), content: {
                NavigationLink(destination: LazyView {
                    NCDisplayView(model: NCDisplayModel(controller: model.controller))
                }) {
                    HStack {
                        Image(systemName: "sun.max.circle")
                            .font(.icon())
                            .foregroundColor(Color(NCBrandColor.shared.iconImageColor))
                            .frame(width: 39)

                        Text(NSLocalizedString("_display_", comment: ""))
                            .font(.body)
                    }
                }
            })
            // Calender & Contacts
            if !NCBrandOptions.shared.disable_mobileconfig {
                Section(content: {
                    Button(action: {
                        model.getConfigFiles()
                    }, label: {
                        HStack {
                            Image(systemName: "calendar.badge.plus")
                                .font(.icon())
                                .foregroundColor(Color(NCBrandColor.shared.iconImageColor))
                                .frame(width: 39)

                            Text(NSLocalizedString("_mobile_config_", comment: ""))
                                .font(.body)
                        }
                    })
                    .tint(Color(NCBrandColor.shared.textColor))
                }, header: {
                    Text(NSLocalizedString("_calendar_contacts_", comment: ""))
                        .font(.headline)
                }, footer: {
                    VStack(alignment: .leading) {
                        Text(NSLocalizedString("_calendar_contacts_footer_warning_", comment: ""))
                            .font(.footnote)

                        Spacer()
                        Text(NSLocalizedString("_calendar_contacts_footer_", comment: ""))
                            .font(.footnote)
                    }
                })
            }
            // Users
            Section(content: {
                Toggle(NSLocalizedString("_settings_account_request_", comment: ""), isOn: $model.accountRequest)
                    .font(.body)
                    .tint(Color(NCBrandColor.shared.getElement(account: model.session.account)))
                    .onChange(of: model.accountRequest) {
                        model.updateAccountRequest()
                    }
            }, header: {
                Text(NSLocalizedString("_users_", comment: ""))
                    .font(.headline)
            }, footer: {
                Text(NSLocalizedString("_users_footer_", comment: ""))
                    .font(.footnote)
            })
            // E2EEncryption` Section
            if capabilities.e2EEEnabled {
                E2EESection(model: model)
            }
            // `Advanced` Section
            Section {
                NavigationLink(destination: LazyView {
                    NCSettingsAdvancedView(model: NCSettingsAdvancedModel(controller: model.controller), showExitAlert: false, showCacheAlert: false)
                }) {
                    HStack {
                        Image(systemName: "gear")
                            .font(.icon())
                            .foregroundColor(Color(NCBrandColor.shared.iconImageColor))
                            .frame(width: 39)

                        Text(NSLocalizedString("_advanced_", comment: ""))
                            .font(.body)
                    }
                }
            }
            // `Information` Section - nur "Über die App"
            Section(header: Text(NSLocalizedString("_information_", comment: "")).font(.headline), content: {
                NavigationLink(destination: LazyView {
                    SouveraAboutView()
                }) {
                    HStack {
                        Image(systemName: "info.circle")
                            .font(.icon())
                            .foregroundColor(Color(NCBrandColor.shared.iconImageColor))
                            .frame(width: 39)
                        Text(NSLocalizedString("_settings_about_app_", comment: ""))
                            .font(.body)
                    }
                }
            })
#if DEBUG
            Section(header: Text("Debug").font(.headline), content: {
                Button(action: {
                    Crashlytics.crashlytics().log("Test crash triggered")
                    fatalError("🔥 Crash test")
                }, label: {
                    HStack {
                        Image(systemName: "flame.fill")
                            .font(.icon())
                            .foregroundColor(.red)
                            .frame(width: 39)

                        Text("Test crash triggered")
                            .font(.body)
                    }
                })
                .tint(Color(NCBrandColor.shared.textColor))
            })
#endif

            // `Diagnose` Section - ganz unten in den Einstellungen
            Section(header: Text(NSLocalizedString("_settings_diagnostics_", comment: "")).font(.headline), content: {
                Button(action: {
                    logsResult = nil
                    showLogsConfirm = true
                }, label: {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.icon())
                            .foregroundColor(Color(NCBrandColor.shared.iconImageColor))
                            .frame(width: 39)
                        Text(NSLocalizedString("_settings_logs_", comment: ""))
                            .font(.body)
                    }
                })
                .tint(Color(NCBrandColor.shared.textColor))

                Button(action: {
                    showPushDiagnostics = true
                }, label: {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.icon())
                            .foregroundColor(Color(NCBrandColor.shared.iconImageColor))
                            .frame(width: 39)
                        Text(NSLocalizedString("_settings_push_diag_", comment: ""))
                            .font(.body)
                    }
                })
                .tint(Color(NCBrandColor.shared.textColor))

                Button(action: {
                    clearCacheResult = nil
                    showClearCacheConfirm = true
                }, label: {
                    HStack {
                        Image(systemName: "trash")
                            .font(.icon())
                            .foregroundColor(Color(NCBrandColor.shared.iconImageColor))
                            .frame(width: 39)
                        Text(NSLocalizedString("_settings_clear_cache_", comment: ""))
                            .font(.body)
                    }
                })
                .tint(Color(NCBrandColor.shared.textColor))
            })
        }
        .souveraCenteredDialog(
            isPresented: $showLogsConfirm,
            title: NSLocalizedString("_settings_logs_confirm_title_", comment: ""),
            message: NSLocalizedString("_settings_logs_confirm_message_", comment: ""),
            actions: [
                SouveraCenteredDialog.DialogAction(
                    label: NSLocalizedString("_settings_logs_confirm_send_", comment: ""),
                    role: .primary
                ) {
                    sendLogs()
                },
                SouveraCenteredDialog.DialogAction(
                    label: NSLocalizedString("_cancel_", comment: ""),
                    role: .cancel
                ) {}
            ]
        )
        .souveraCenteredDialog(
            isPresented: $showClearCacheConfirm,
            title: NSLocalizedString("_settings_clear_cache_confirm_title_", comment: ""),
            message: NSLocalizedString("_settings_clear_cache_confirm_message_", comment: ""),
            actions: [
                SouveraCenteredDialog.DialogAction(
                    label: NSLocalizedString("_settings_clear_cache_confirm_", comment: ""),
                    role: .destructive
                ) {
                    clearAllCaches()
                },
                SouveraCenteredDialog.DialogAction(
                    label: NSLocalizedString("_cancel_", comment: ""),
                    role: .cancel
                ) {}
            ]
        )
        .overlay(alignment: .bottom) {
            if isSendingLogs {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(NSLocalizedString("_settings_logs_sending_", comment: ""))
                        .font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let logsResult {
                HStack(spacing: 8) {
                    Image(systemName: logsResult.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(logsResult.success ? .green : .red)
                    Text(logsResult.message).font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: logsResult == nil) { _, _ in
            guard let logsResult else { return }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.logsResult = nil
            }
        }
        .overlay(alignment: .bottom) {
            if let clearCacheResult {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(clearCacheResult).font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: clearCacheResult) { _, newValue in
            guard newValue != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.clearCacheResult = nil
            }
        }
        .sheet(isPresented: $showPushDiagnostics) {
            SouveraPushDiagnosticsView()
        }
        .sheet(isPresented: $showPasscode) {
            SetupPasscodeView(isLockActive: $model.isLockActive, controller: model.controller)
        }
        .sheet(isPresented: $showChangePasscode) {
            SetupPasscodeView(isLockActive: $model.isLockActive, controller: model.controller, changePasscode: true)
        }
        .navigationBarTitle(NSLocalizedString("_settings_", comment: ""))
        .defaultViewModifier(model)
        .alert(NSLocalizedString("_settings_language_", comment: ""), isPresented: $showLanguageRestart) {
            Button(NSLocalizedString("_ok_", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("_language_restart_", comment: ""))
        }
    }

    /// Sendet die Logs per JMAP-Mail an die feste Host-On-Adresse
    /// (Bestätigung erfolgte im Dialog; Ergebnis als Overlay).
    private func sendLogs() {
        isSendingLogs = true
        logsResult = nil
        Task {
            let result = await SouveraLogSender.sendLogs()
            isSendingLogs = false
            switch result {
            case .success:
                logsResult = (true, NSLocalizedString("_settings_logs_sent_", comment: ""))
            case .failure(let error):
                SouveraLog.write("Settings", "logs send failed: \(error.localizedDescription)")
                logsResult = (false, NSLocalizedString("_settings_logs_failed_", comment: ""))
                // Fallback: Share-Sheet, damit die Logs trotzdem rauskommen.
                presentShareFallback()
            }
        }
    }

    /// Leert sämtliche App-Caches (Mail + Kalender + Kontakte über MailCache,
    /// Link über LinkCache) für einen frischen Start im Fehlerfall.
    private func clearAllCaches() {
        MailCache.clearAll()
        LinkCache.clearAll()
        // Sichtbare Module neu laden, damit nicht erst nach einem Neustart
        // frisch geladen wird.
        NotificationCenter.default.post(name: Notification.Name(NCGlobal.shared.notificationCenterChangeUser), object: nil)
        clearCacheResult = NSLocalizedString("_settings_clear_cache_done_", comment: "")
        SouveraLog.write("Settings", "all app caches cleared")
    }

    /// Share-Sheet-Fallback, wenn der Mail-Versand der Logs fehlschlägt.
    private func presentShareFallback() {
        guard let url = SouveraLogSender.combinedLogFileURL(),
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        top.present(activityVC, animated: true)
    }
}

struct E2EESection: View {
    @ObservedObject var model: NCSettingsModel

    var body: some View {
        Section(header: Text(NSLocalizedString("_e2e_settings_title_", comment: "")).font(.headline), content: {
            NavigationLink(destination: LazyView {
                NCManageE2EEView(model: NCManageE2EE(controller: model.controller))
            }) {
                HStack {
                    Image(systemName: "lock")
                        .font(.icon())
                        .foregroundColor(Color(NCBrandColor.shared.iconImageColor))
                        .frame(width: 39)

                    Text(NSLocalizedString("_e2e_settings_", comment: ""))
                        .font(.body)
                }
            }
        })
    }
}

#Preview {
    NCSettingsView(model: NCSettingsModel(controller: nil))
}
