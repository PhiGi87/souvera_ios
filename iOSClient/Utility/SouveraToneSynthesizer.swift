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
                do {
                    try data.write(to: url, options: .atomic)
                    SouveraLog.write("ToneSynthesizer", "tone generated ok: \(url.lastPathComponent)")
                } catch {
                    SouveraLog.write("ToneSynthesizer", "tone write failed: \(error.localizedDescription)")
                }
            } else {
                SouveraLog.write("ToneSynthesizer", "tone synthesis failed for \(sound.rawValue)")
            }
        }
    }

    // MARK: - Synthese (16-bit PCM, mono, 44.1 kHz, ~1,2 s)

    /// Manuelle WAV-Erzeugung (RIFF-Header + PCM16) - bewusst OHNE
    /// AVAudioFile, dessen format.settings-Schreibweg die Dateien zuvor
    /// nicht zuverlässig erzeugte ("tote" Töne).
    static func synthesize(_ sound: SouveraCalendarReminderSound) -> Data? {
        let sampleRate = 44100
        let duration = 1.2
        let frameCount = Int(Double(sampleRate) * duration)
        var pcm = [Int16](repeating: 0, count: frameCount)

        var rngState: UInt64 = 0x9E3779B97F4A7C15
        func nextRandom() -> Double {
            rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
            return Double((rngState >> 33) & 0x7FFFFFFF) / Double(0x7FFFFFFF)
        }

        for i in 0..<frameCount {
            let t = Double(i) / Double(sampleRate)
            var value: Double
            switch sound {
            case .bell:
                value = 0.55 * sin(2 * .pi * 880 * t) * exp(-4.0 * t)
                    + 0.35 * sin(2 * .pi * 1318.5 * t) * exp(-6.0 * t)
            case .chime:
                value = 0.5 * sin(2 * .pi * 1318.5 * t) * exp(-5.0 * t)
                    + 0.2 * sin(2 * .pi * 2637 * t) * exp(-7.0 * t)
            case .bowl:
                value = 0.6 * sin(2 * .pi * 196 * t) * exp(-1.6 * t)
                    + 0.3 * sin(2 * .pi * 294 * t) * exp(-2.4 * t)
            case .wind:
                let noise = (nextRandom() * 2.0 - 1.0)
                let envelope = sin(.pi * min(t / duration, 1.0))
                value = noise * 0.25 * envelope
            default:
                value = 0
            }
            let clamped = max(-1.0, min(1.0, value))
            pcm[i] = Int16(clamped * 32767.0)
        }

        let dataSize = frameCount * 2
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(uint32LE(UInt32(36 + dataSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(uint32LE(16))
        data.append(uint16LE(1))          // PCM
        data.append(uint16LE(1))          // mono
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(UInt32(sampleRate * 2))) // byte rate
        data.append(uint16LE(2))          // block align
        data.append(uint16LE(16))         // bits
        data.append(contentsOf: Array("data".utf8))
        data.append(uint32LE(UInt32(dataSize)))
        for sample in pcm {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }

    private static func uint16LE(_ v: UInt16) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }
}
