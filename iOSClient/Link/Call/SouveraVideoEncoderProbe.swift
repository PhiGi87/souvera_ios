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
        CallDebugLog.log("EncoderProbe", "encoder created: \(codecName)")
    }

    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        inner.setCallback(callback)
    }

    func implementationName() -> String {
        inner.implementationName()
    }

    func setBitrate(_ bitrate: UInt32, framerate: UInt32) -> Int32 {
        inner.setBitrate(bitrate, framerate: framerate)
    }

    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        let result = inner.startEncode(with: settings, numberOfCores: numberOfCores)
        CallDebugLog.log("EncoderProbe", "startEncode codec=\(codecName) w=\(settings.width) h=\(settings.height) result=\(result)")
        return result
    }

    func encode(_ frame: RTCVideoFrame, codecSpecificInfo: RTCCodecSpecificInfo?, frameTypes: [NSNumber]) -> Int {
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
