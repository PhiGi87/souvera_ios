// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Live Activity für einen minimierten eingehenden Call: Der klingelnde
// Anruf erscheint in der Dynamic Island (bzw. auf dem Sperrbildschirm) und
// kann dort per Annehmen/Ablehnen-Buttons bedient werden. Die App-Intents
// laufen im App-Prozess und nutzen das SouveraCallBannerModel.

import ActivityKit
import AppIntents
import Foundation
import SwiftUI
import WidgetKit

struct SouveraCallAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var state: String
    }

    let roomTitle: String
}

enum SouveraCallLiveActivity {
    private static var current: Activity<SouveraCallAttributes>?

    /// Startet die Live Activity (Dynamic Island/Lock-Screen), sofern der
    /// Benutzer Live Activities erlaubt hat. Ältere Geräte (kein Island)
    /// zeigen den Anruf weiterhin nur über die In-App-Leiste.
    static func start(title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            SouveraLog.write("CallActivity", "start skipped (not authorized)")
            return
        }
        guard current == nil else { return }
        let attributes = SouveraCallAttributes(roomTitle: title)
        let state = SouveraCallAttributes.ContentState(state: "ringing")
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(90))
        do {
            current = try Activity.request(attributes: attributes, content: content, pushType: nil)
            SouveraLog.write("CallActivity", "started for \u{22}\(title)\u{22}")
        } catch {
            SouveraLog.write("CallActivity", "start failed: \(error.localizedDescription)")
        }
    }

    static func end() {
        guard let activity = current else { return }
        let activityRef = activity
        current = nil
        Task {
            await activityRef.end(nil, dismissalPolicy: .immediate)
        }
        SouveraLog.write("CallActivity", "ended")
    }
}

struct SouveraAcceptCallIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Accept"

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            SouveraCallBannerModel.shared.acceptIfPresent()
        }
        return .result()
    }
}

struct SouveraDeclineCallIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Decline"

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            SouveraCallBannerModel.shared.declineIfPresent()
        }
        return .result()
    }
}

struct SouveraCallLiveActivityView: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SouveraCallAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "phone.ring.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.roomTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(NSLocalizedString("_link_incoming_call_", comment: ""))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "phone.ring.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.roomTitle)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 10) {
                        Button(intent: SouveraDeclineCallIntent()) {
                            Image(systemName: "phone.down.fill")
                                .font(.body.bold())
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color.red))
                        }
                        Button(intent: SouveraAcceptCallIntent()) {
                            Image(systemName: "phone.fill")
                                .font(.body.bold())
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color.green))
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "phone.ring.fill")
                    .foregroundStyle(.green)
            } compactTrailing: {
                Text(context.attributes.roomTitle)
                    .font(.caption2)
                    .lineLimit(1)
            } minimal: {
                Image(systemName: "phone.ring.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}
