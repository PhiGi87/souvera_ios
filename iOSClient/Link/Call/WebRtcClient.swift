// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from souvera_android link/call/WebRtcClient.kt.
//
// Owns the process-wide RTCPeerConnectionFactory for the "Link" (Nextcloud Talk) call stack, plus
// local audio/video capture. Built on the talk-ios WebRTC build (import WebRTC). One instance per
// active call; call dispose() when the call ends.

import Foundation
import WebRTC

final class WebRtcClient {
    private let factory: RTCPeerConnectionFactory
    private var videoCapturer: RTCCameraVideoCapturer?
    private var videoSource: RTCVideoSource?
    private var disposed = false

    init() {
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
    }

    func createPeerConnection(iceServers: [RTCIceServer], delegate: RTCPeerConnectionDelegate) -> RTCPeerConnection? {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        return factory.peerConnection(with: config, constraints: constraints, delegate: delegate)
    }

    func createLocalAudioTrack() -> RTCAudioTrack {
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        return factory.audioTrack(with: source, trackId: "link_audio0")
    }

    /// Creates the local video track and starts front-camera capture. Returns nil if no camera.
    func createLocalVideoTrack() -> RTCVideoTrack? {
        let source = factory.videoSource()
        videoSource = source
        let capturer = RTCCameraVideoCapturer(delegate: source)
        videoCapturer = capturer

        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front })
            ?? RTCCameraVideoCapturer.captureDevices().first else { return nil }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        // Pick a format close to 1280x720.
        let format = formats.min(by: { lhs, rhs in
            let ld = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rd = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return abs(Int(ld.width) - 1280) < abs(Int(rd.width) - 1280)
        }) ?? formats.first
        if let format {
            let fps = (format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30)
            capturer.startCapture(with: device, format: format, fps: Int(min(fps, 30)))
        }
        return factory.videoTrack(with: source, trackId: "link_video0")
    }

    func dispose() {
        if disposed { return }
        disposed = true
        videoCapturer?.stopCapture()
        videoCapturer = nil
        videoSource = nil
        RTCCleanupSSL()
    }
}
