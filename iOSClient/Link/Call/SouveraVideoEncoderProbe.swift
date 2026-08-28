// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WebRTC

/// P68v-Diagnose: Decorator um die Video-Encoder-Factory, der jeden
/// encode()-Aufruf (inkl. Codec und Ergebnis) sowie Encoder-Fehler loggt.
/// Damit ist im Log beweisbar, ob Kamera-Frames den Encoder erreichen -
/// die getStats-API liefert auf diesem WebRTC-Build leere Reports.
final class SouveraProbeVideoEncoderFactory: NSObject, RTCVideoEncoderFactory {
    private let inner = RTCDefaultVideoEncoderFactory()

    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        guard let encoder = inner.createEncoder(info) else { return nil }
        return SouveraProbeVideoEncoder(inner: encoder, codecName: info.name)
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        inner.supportedCodecs()
    }
}

/// Forwarding-Wrapper mit Zähl-/Fehler-Log.
final class SouveraProbeVideoEncoder: NSObject, RTCVideoEncoder {
    private let inner: RTCVideoEncoder
    private let codecName: String
    private var encodeCount = 0
    private var loggedOnce = false
    private var lastLog = Date.distantPast

    init(inner: RTCVideoEncoder, codecName: String) {
        self.inner = inner
        self.codecName = codecName
        super.init()
        CallDebugLog.log("EncoderProbe", "encoder created: \(codecName) impl=\(inner.implementationName())")
    }

    private var callbackDelivered = 0
    private var lastDeliveryLog = Date.distantPast
    private var firstFrameLogged = false

    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        // P68v: Zeigt, ob die Engine den Encoder überhaupt verdrahtet
        // (Callback-Installation) - die Übergabe der kodierten Frames
        // hängt daran.
        CallDebugLog.log("EncoderProbe", "callback installed codec=\(codecName)")
        let wrapped: RTCVideoEncoderCallback = { [weak self] frame, info in
            guard let self else { return callback?(frame, info) ?? true }
            self.callbackDelivered += 1
            let now = Date()
            if now.timeIntervalSince(self.lastDeliveryLog) >= 2 {
                self.lastDeliveryLog = now
                CallDebugLog.log("EncoderProbe", "callback delivered #\(self.callbackDelivered) codec=\(self.codecName)")
            }
            return callback?(frame, info) ?? true
        }
        inner.setCallback(wrapped)
    }

    func implementationName() -> String {
        inner.implementationName()
    }

    func setBitrate(_ bitrate: UInt32, framerate: UInt32) -> Int32 {
        // P68w: Bitrate 0 oder ausbleibende Raten = Encoder produziert
        // nichts - genau der Kandidat für den fehlenden Callback.
        if bitrate != lastLoggedBitrate || framerate != lastLoggedFramerate {
            lastLoggedBitrate = bitrate
            lastLoggedFramerate = framerate
            CallDebugLog.log("EncoderProbe", "setBitrate codec=\(codecName) bitrate=\(bitrate) fps=\(framerate)")
        }
        return inner.setBitrate(bitrate, framerate: framerate)
    }

    private var lastLoggedBitrate: UInt32 = 0xFFFF_FFFF
    private var lastLoggedFramerate: UInt32 = 0xFFFF_FFFF

    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        let result = inner.startEncode(with: settings, numberOfCores: numberOfCores)
        CallDebugLog.log("EncoderProbe", "startEncode codec=\(codecName) w=\(settings.width) h=\(settings.height) result=\(result)")
        return result
    }

    func encode(_ frame: RTCVideoFrame, codecSpecificInfo: RTCCodecSpecificInfo?, frameTypes: [NSNumber]) -> Int {
        if !firstFrameLogged {
            firstFrameLogged = true
            // P68w: Dimensions-/Rotations-/Timestamp-Mismatch erkennen
            // (z. B. Capturer liefert andere Größe als startEncode 720x1280).
            CallDebugLog.log("EncoderProbe", "first frame codec=\(codecName) w=\(frame.width) h=\(frame.height) rot=\(frame.rotation.rawValue) ts=\(frame.timeStampNs) ntpt=\(frame.ntpTimeMs)")
        }
        let result = inner.encode(frame, codecSpecificInfo: codecSpecificInfo, frameTypes: frameTypes)
        encodeCount += 1
        let now = Date()
        if !loggedOnce || now.timeIntervalSince(lastLog) >= 2 {
            lastLog = now
            loggedOnce = true
            CallDebugLog.log("EncoderProbe", "encode #\(encodeCount) codec=\(codecName) result=\(result) frameTypes=[\(frameTypes.map { $0.intValue }.map(String.init).joined(separator: ","))]")
        }
        return result
    }

    func release() -> Int {
        CallDebugLog.log("EncoderProbe", "release codec=\(codecName) totalEncodes=\(encodeCount)")
        return inner.release()
    }

    var resolutionAlignment: Int { inner.resolutionAlignment }
    var applyAlignmentToAllSimulcastLayers: Bool { inner.applyAlignmentToAllSimulcastLayers }
    var supportsNativeHandle: Bool { inner.supportsNativeHandle }

    func scalingSettings() -> RTCVideoEncoderQpThresholds? {
        inner.scalingSettings()
    }

}
