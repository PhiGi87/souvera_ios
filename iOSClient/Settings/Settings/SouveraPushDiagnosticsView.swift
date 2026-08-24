// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import NextcloudKit

/// Push-Diagnose: Registrierungsstatus (normal + VoIP), Token-Längen und ein
/// "Test-Push senden"-Knopf. Der Test-Push ruft den Notifications-OCS-
/// Endpoint auf; der Server liefert einen Diagnose-Text zurück (Gerätezahl,
/// Proxy-Ergebnis), der hier angezeigt wird - genau das, was Host-On für die
/// Proxy-Fehleranalyse braucht.
struct SouveraPushDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var isTalkTest = false

    var body: some View {
        NavigationStack {
            List {
                Section(NSLocalizedString("_settings_push_diag_status_", comment: "")) {
                    LabeledContent(NSLocalizedString("_settings_push_diag_apns_", comment: "")) {
                        tokenStatus(NCPreferences().deviceTokenPushNotification)
                    }
                    LabeledContent(NSLocalizedString("_settings_push_diag_voip_", comment: "")) {
                        tokenStatus(LinkVoIPManager.shared.voipToken)
                    }
                    LabeledContent(NSLocalizedString("_settings_push_diag_registration_", comment: "")) {
                        Text(SouveraLogSender.pushRegistrationStatus())
                            .font(.caption)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section {
                    // Differenzierte Tests: Mail/Chat (normaler Kanal) und
                    // Call (Talk-Kanal via Talk-User-Agent).
                    Button {
                        runTestPush(talk: false)
                    } label: {
                        HStack {
                            if isTesting && !isTalkTest {
                                ProgressView()
                            } else {
                                Label(NSLocalizedString("_settings_push_diag_test_mail_", comment: ""), systemImage: "envelope.badge")
                            }
                        }
                    }
                    .disabled(isTesting)
                    Button {
                        runTestPush(talk: true)
                    } label: {
                        HStack {
                            if isTesting && isTalkTest {
                                ProgressView()
                            } else {
                                Label(NSLocalizedString("_settings_push_diag_test_call_", comment: ""), systemImage: "phone.badge.waveform")
                            }
                        }
                    }
                    .disabled(isTesting)
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text(NSLocalizedString("_settings_push_diag_test_hint_", comment: ""))
                }
            }
            .navigationTitle(NSLocalizedString("_settings_push_diag_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
            }
        }
    }

    private func tokenStatus(_ token: String) -> Text {
        if token.isEmpty {
            return Text(NSLocalizedString("_settings_push_diag_missing_", comment: "")).foregroundStyle(.red)
        }
        return Text("\(token.count)").foregroundStyle(.green)
    }

    private func runTestPush(talk: Bool) {
        guard let tbl = NCManageDatabase.shared.getActiveTableAccount() else {
            testResult = NSLocalizedString("_settings_push_diag_no_account_", comment: "")
            return
        }
        isTesting = true
        isTalkTest = talk
        testResult = nil
        Task {
            defer { isTesting = false }
            let root = tbl.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(root)/ocs/v2.php/apps/notifications/api/v3/test/self") else {
                testResult = NSLocalizedString("_settings_push_diag_error_", comment: "")
                return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            let davPassword = NCPreferences().getPassword(account: tbl.account)
            let raw = "\(tbl.user):\(davPassword)"
            req.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
            req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if talk {
                // Talk-UA: der Server erzeugt dann eine Talk-Test-
                // Benachrichtigung, die an TALK-Geräte (dein iPhone) geht.
                req.setValue("Mozilla/5.0 (iOS) Nextcloud-Talk v21.0.0 (Souvera Workspace)", forHTTPHeaderField: "User-Agent")
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard (200..<300).contains(status),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ocs = json["ocs"] as? [String: Any],
                      let payload = ocs["data"] as? [String: Any] else {
                    testResult = "HTTP \(status)"
                    return
                }
                let result = payload["message"] as? String ?? NSLocalizedString("_settings_push_diag_sent_", comment: "")
                testResult = result
                let label = talk ? "call" : "mail/chat"
                SouveraLog.write("PushDiagnostics", "test push (\(label)) result: \(result)")
                UserDefaults.standard.set("\(label): \(result)", forKey: "SouveraLastTestPushResult")
            } catch {
                testResult = error.localizedDescription
            }
        }
    }
}
