// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Dezenter Hinweiston, wenn im Vordergrund ein Push erfolgreich
// entschlüsselt wurde (iOS spielt im Vordergrund keinen Sound).
// Wiedergabe über die .ambient-AudioSession: respektiert den
// Klingelschalter und wird nicht mit Musik/Telefonie gemischt.

import AVFoundation
import UIKit

final class SouveraForegroundTone {
    static let shared = SouveraForegroundTone()
    private var player: AVAudioPlayer?

    private static var toneURL: URL? {
        guard let dir = SouveraToneSynthesizer.soundsDirectory() else { return nil }
        let url = dir.appendingPathComponent("souvera-foreground-blip.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            if let data = synthesizeBlip() {
                try? data.write(to: url, options: .atomic)
            }
        }
        return url
    }

    /// Ein einzelner, sehr weicher Strike (~0,6 s, leise).
    private static func synthesizeBlip() -> Data? {
        let sampleRate = 44100
        let duration = 0.6
        let frameCount = Int(Double(sampleRate) * duration)
        var pcm = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let t = Double(i) / Double(sampleRate)
            let attack = min(t / 0.015, 1.0)
            let decay = exp(-7.0 * t)
            var value = 0.16 * attack * decay * sin(2 * .pi * 987.77 * t)
            value += 0.06 * attack * decay * sin(2 * .pi * 1480.0 * t)
            let clamped = max(-1.0, min(1.0, value))
            pcm[i] = Int16(clamped * 32767.0)
        }

        let dataSize = frameCount * 2
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataSize))
        for sample in pcm {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Spielt den Hinweiston nur ab, wenn die App sichtbar im Vordergrund ist.
    func playIfForeground() {
        guard UIApplication.shared.applicationState == .active else { return }
        guard let url = Self.toneURL else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
            if player == nil || player?.url != url {
                player = try AVAudioPlayer(contentsOf: url)
            }
            player?.volume = 0.5
            player?.currentTime = 0
            player?.play()
        } catch {
            SouveraLog.write("ForegroundTone", "play failed: \(error.localizedDescription)")
        }
    }
}
