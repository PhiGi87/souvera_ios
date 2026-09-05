// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lokaler Warteton für laufende "Link"-Calls ohne Teilnehmer: sanfter
// Doppel-Chime (synthetisiert, lizenzfrei), geloopt über die bereits
// aktive RTCAudioSession des Calls. Start nach der Audio-Session-
// Aktivierung in CallSession.startMedia, Stop sobald ein Teilnehmer
// beitritt oder der Call endet.

import Foundation
import AVFAudio

@MainActor
final class SouveraRingbackPlayer {
    static let shared = SouveraRingbackPlayer()

    private var player: AVAudioPlayer?

    private init() {}

    /// Startet den Warteton (idempotent; erzeugt die Tondatei bei Bedarf).
    func start() {
        guard player == nil else { return }
        SouveraToneSynthesizer.ensureCallRingbackGenerated()
        guard let url = SouveraToneSynthesizer.callRingbackURL() else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 0.6
            p.prepareToPlay()
            p.play()
            player = p
            CallDebugLog.log("Ringback", "waiting tone started")
        } catch {
            CallDebugLog.log("Ringback", "waiting tone start failed: \(error.localizedDescription)")
        }
    }

    /// Stoppt den Warteton (idempotent).
    func stop() {
        guard let player else { return }
        player.stop()
        self.player = nil
        CallDebugLog.log("Ringback", "waiting tone stopped")
    }
}
