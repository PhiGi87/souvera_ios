// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import AVFAudio

/// Synthetisiert die vier Kalender-Erinnerungs-Töne (kurze WAV-Chimes)
/// und legt sie im App-Container unter Library/Sounds ab. Von dort
/// referenziert UNNotificationSound(named:) sie zuverlässig (System-
/// UI-Sounds per Dateiname griffen auf iOS 26 nicht).
enum SouveraToneSynthesizer {

    static func fileName(for sound: SouveraCalendarReminderSound) -> String? {
        switch sound {
        case .bell: return "souvera-cal-bell.wav"
        case .chime: return "souvera-cal-chime.wav"
        case .bowl: return "souvera-cal-bowl.wav"
        case .wind: return "souvera-cal-wind.wav"
        default: return nil
        }
    }

    static func url(for sound: SouveraCalendarReminderSound) -> URL? {
        guard let fileName = fileName(for: sound),
              let dir = soundsDirectory() else { return nil }
        return dir.appendingPathComponent(fileName)
    }

    static func soundsDirectory() -> URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    /// Erzeugt fehlende Tondateien (einmalig pro Gerät/Installation).
    static func ensureAllGenerated() {
        guard let dir = soundsDirectory() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for sound in SouveraCalendarReminderSound.allCases {
            guard let url = url(for: sound),
                  !FileManager.default.fileExists(atPath: url.path) else { continue }
            if let data = synthesize(sound) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Synthese (16-bit PCM, mono, 44.1 kHz, ~1,2 s)

    private static func synthesize(_ sound: SouveraCalendarReminderSound) -> Data? {
        let sampleRate = 44100.0
        let duration = 1.2
        let frameCount = Int(sampleRate * duration)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        var rngState: UInt64 = 0x9E3779B97F4A7C15
        func nextRandom() -> Double {
            rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
            return Double((rngState >> 33) & 0x7FFFFFFF) / Double(0x7FFFFFFF)
        }

        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            var value: Double
            switch sound {
            case .bell:
                // Zwei hell schwingende Sinus mit schnellem Abklingen.
                value = 0.55 * sin(2 * .pi * 880 * t) * exp(-4.0 * t)
                    + 0.35 * sin(2 * .pi * 1318.5 * t) * exp(-6.0 * t)
            case .chime:
                value = 0.5 * sin(2 * .pi * 1318.5 * t) * exp(-5.0 * t)
                    + 0.2 * sin(2 * .pi * 2637 * t) * exp(-7.0 * t)
            case .bowl:
                // Tiefer Gong, lang ausklingend.
                value = 0.6 * sin(2 * .pi * 196 * t) * exp(-1.6 * t)
                    + 0.3 * sin(2 * .pi * 294 * t) * exp(-2.4 * t)
            case .wind:
                // Weiches Rauschen mit sanfter Hüllkurve.
                let noise = (nextRandom() * 2.0 - 1.0)
                let envelope = sin(.pi * min(t / duration, 1.0))
                value = noise * 0.25 * envelope
            default:
                value = 0
            }
            channel[i] = Float(max(-1.0, min(1.0, value)))
        }

        do {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("souvera-tone-\(UUID().uuidString).wav")
            let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            try file.write(from: buffer)
            let data = try Data(contentsOf: tempURL)
            try? FileManager.default.removeItem(at: tempURL)
            return data
        } catch {
            return nil
        }
    }
}
