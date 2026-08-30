// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from souvera_android link/call/WebRtcClient.kt.
//
// Owns the process-wide RTCPeerConnectionFactory for the "Link" (Nextcloud Talk) call stack, plus
// local audio/video capture. Built on the talk-ios WebRTC build (import WebRTC). One instance per
// active call; call dispose() when the call ends.

import Foundation
import AVFoundation
import WebRTC

final class WebRtcClient {
    private let factory: RTCPeerConnectionFactory
    private var videoCapturer: ManualVideoCapturer?
    private var videoSource: RTCVideoSource?
    private var disposed = false

    init() {
        RTCInitializeSSL()
        // P68z: talk-iOS-Parität - rohe Encoder-Factory (kein Probe-Wrapper).
        // Der Wrapper (setCallback-Umschreibung) war eine Abweichung im
        // Encoder-Pfad; talk-iOS nutzt die Default-Factory direkt.
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

    /// Creates the local video track and starts front-camera capture.
    /// P68v: talk-iOS-Muster (NCCameraController): manuelle AVCaptureSession,
    /// Frames werden via videoSource.capturer(didCapture:) eingespeist -
    /// der eingebaute RTCCameraVideoCapturer lieferte auf diesem WebRTC-Build
    /// offenbar keine Frames an den Encoder (Remote schwarz trotz Live-Source).
    func createLocalVideoTrack() -> RTCVideoTrack? {
        let source = factory.videoSource()
        videoSource = source
        // P68z: talk-iOS-Parität - KEIN adaptOutputFormat. Die frühere
        // adaptOutputFormat(toWidth:1280,height:720) war vertauscht
        // (Landschaft statt Porträt) und ein Kandidat dafür, dass libvpx
        // die Frames annahm, aber keinen Output lieferte.
        let capturer = ManualVideoCapturer(delegate: source)
        videoCapturer = capturer
        capturer.startCapture()
        return factory.videoTrack(with: source, trackId: "link_video0")
    }

    /// Restarts the camera capture (video was re-enabled after a stop).
    func startVideoCapture() {
        videoCapturer?.startCapture()
    }

    /// Stops the camera capture (video off - the camera LED must go out).
    func stopVideoCapture() {
        videoCapturer?.stopCapture()
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

/// Manuelle Kamera-Einspeisung (talk-iOS-NCCameraController-Muster, minimal):
/// AVCaptureSession mit Front-Kamera, Porträt-Ausrichtung der Frames und
/// Rotation nach Geräteorientierung.
private final class ManualVideoCapturer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private weak var delegate: RTCVideoSource?
    private let capturer: RTCVideoCapturer
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "souvera.camera.capture")
    private let usingFrontCamera = true
    private var videoRotation: RTCVideoRotation = ._0
    private var deviceOrientation: UIDeviceOrientation = .portrait

    init(delegate: RTCVideoSource) {
        self.delegate = delegate
        self.capturer = RTCVideoCapturer(delegate: delegate)
        super.init()
        configureSession()
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged),
                                               name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
        if let device,
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        output.connections.first?.videoOrientation = .portrait
        session.commitConfiguration()
    }

    @objc private func orientationChanged() {
        deviceOrientation = UIDevice.current.orientation
        updateRotation()
    }

    private func updateRotation() {
        // talk-iOS-Mapping (Front-Kamera, Frames in Porträt-Ausrichtung).
        if deviceOrientation == .portrait {
            videoRotation = ._0
        } else if deviceOrientation == .portraitUpsideDown {
            videoRotation = ._180
        } else if deviceOrientation == .landscapeRight {
            videoRotation = usingFrontCamera ? ._270 : ._90
        } else if deviceOrientation == .landscapeLeft {
            videoRotation = usingFrontCamera ? ._90 : ._270
        }
    }

    func startCapture() {
        updateRotation()
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func stopCapture() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let delegate,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // P68z: Einmalig das Pixel-Format + Größe loggen (NV12 vs. BGRA -
        // talk-iOS rendert via CoreImage auf BGRA; ein Format-Problem wäre
        // der nächste Kandidat, falls der Encoder weiter keinen Output liefert).
        if !firstFrameLogged {
            firstFrameLogged = true
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            var chars = [Character]()
            for shift in stride(from: 24, through: 0, by: -8) {
                let byte = (Int(format) >> shift) & 0xFF
                if byte > 0 { chars.append(Character(UnicodeScalar(byte)!)) }
            }
            CallDebugLog.log("CameraProbe", "first frame format=\(String(chars)) w=\(CVPixelBufferGetWidth(pixelBuffer)) h=\(CVPixelBufferGetHeight(pixelBuffer))")
        }
        let timeStampNs = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000_000
        // talk-iOS-Muster: der Frame erwartet einen RTCVideoFrameBuffer -
        // das CVPixelBuffer wird in ein RTCCVPixelBuffer gewrappt.
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: videoRotation, timeStampNs: Int64(timeStampNs))
        delegate.capturer(capturer, didCapture: frame)
    }

    private var firstFrameLogged = false
}
