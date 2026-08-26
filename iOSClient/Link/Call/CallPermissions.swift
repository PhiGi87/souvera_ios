// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation

/// Einmaliger Berechtigungs-Flow für Link-Calls (Nextcloud-Talk-Standard):
/// Die Systemdialoge erscheinen NUR beim allerersten Mal (Status
/// .notDetermined). Danach wird nur noch der gespeicherte Status geprüft -
/// vor jedem Call kommt kein Dialog mehr. Bei verweigertem Mikrofon ist kein
/// Call möglich; bei verweigerter Kamera läuft der Call audio-only.
enum CallPermissions {
    /// True, wenn das Mikrofon nutzbar ist (fragt beim ersten Mal an).
    static func ensureAudio(allowPrompt: Bool = true) async -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        switch audioSession.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            // Im Hintergrund/gesperrt KANN kein Dialog erscheinen - der
            // Prompt würde den Session-Start dauerhaft blockieren. Dort
            // ohne Prompt fortfahren (CallKit liefert den Audio-Kontext).
            guard allowPrompt else { return true }
            return await withCheckedContinuation { continuation in
                audioSession.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    /// True, wenn die Kamera nutzbar ist (fragt beim ersten Mal an).
    static func ensureCamera(allowPrompt: Bool = true) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            guard allowPrompt else { return true }
            return await AVCaptureDevice.requestAccess(for: .video)
        @unknown default:
            return false
        }
    }
}
