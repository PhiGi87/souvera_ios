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

    /// Wechselt zwischen Front- und Rückkamera.
    func switchCamera() {
        videoCapturer?.switchCamera()
    }

    /// Run 25.10.: Public-Hook fuer viewWillTransition (Main-Thread).
    func updateOrientation() {
        videoCapturer?.updateRotation()
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
    private var usingFrontCamera = true
    private var currentInput: AVCaptureDeviceInput?
    /// Zuletzt berechneter AVFoundation-Rotationswinkel (Grad).
    private var captureRotationAngle: CGFloat = 90

    init(delegate: RTCVideoSource) {
        self.delegate = delegate
        self.capturer = RTCVideoCapturer(delegate: delegate)
        super.init()
        configureSession()
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged),
                                               name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    private func configureSession() {
        session.sessionPreset = .high
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        applyCaptureRotation()
        installCameraInput()
    }

    /// Tauscht den Kamera-Input (Front ↔ Rück) und aktualisiert die Rotation.
    func switchCamera() {
        let newPosition: AVCaptureDevice.Position = usingFrontCamera ? .back : .front
        guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition) != nil
            || AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) != nil else {
            return
        }
        usingFrontCamera.toggle()
        let wasRunning = session.isRunning
        if wasRunning { session.stopRunning() }
        installCameraInput()
        if wasRunning { session.startRunning() }
    }

    private func installCameraInput() {
        session.beginConfiguration()
        if let currentInput, session.inputs.contains(currentInput) {
            session.removeInput(currentInput)
            self.currentInput = nil
        }
        let position: AVCaptureDevice.Position = usingFrontCamera ? .front : .back
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
        if let device,
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
        }
        session.commitConfiguration()
        // Beim Input-Tausch (Front ↔ Rück) wird die AVCaptureConnection neu
        // erzeugt und verliert die Rotations-Einstellung - erneut anwenden.
        applyCaptureRotation()
        updateRotation()
    }

    @objc private func orientationChanged() {
        updateRotation()
    }

    /// Wendet den zuletzt berechneten Rotationswinkel auf die
    /// AVCaptureConnection an (auch nach Input-Tausch/Konfiguration).
    private func applyCaptureRotation() {
        if let connection = output.connections.first,
           connection.isVideoRotationAngleSupported(captureRotationAngle) {
            connection.videoRotationAngle = captureRotationAngle
        }
    }

    /// Run 25.10. (Fix "Kamera genau 90 Grad falsch auf dem Duo, offen und
    /// geknickt"): Die Rotation uebernimmt AVFOUNDATION selbst - Apple-API
    /// AVCaptureConnection.videoRotationAngle (iOS 17+, Nachfolger des
    /// deprecated videoOrientation). AVFoundation kennt die Sensor-
    /// Montage des jeweiligen Geraets (beim Duo weicht die innere Kamera
    /// von der iPhone-Annahme ab - daher war die RTC-Mapping-Tabelle
    /// systematisch 90 Grad daneben) und dreht die Buffer auf die
    /// angeforderte Display-Orientierung. Die WebRTC-Frames werden immer
    /// mit Rotation ._0 gesendet (Buffer kommen fertig gedreht an).
    /// Quelle der Orientierung: UIWindowScene.interfaceOrientation der
    /// aktiven Szene (Apple-Duo-Vorgabe: keine UIDevice-Orientierung),
    /// Gilt fuer offen, geknickt (Tent), hoch und quer.
    func updateRotation() {
        let orientation: UIInterfaceOrientation = MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
            return scene?.interfaceOrientation ?? .portrait
        }
        // Dokumentierte Aequivalente zu AVCaptureVideoOrientation:
        // .portrait = 90, .portraitUpsideDown = 270,
        // .landscapeLeft = 0, .landscapeRight = 180.
        let angle: CGFloat
        switch orientation {
        case .portraitUpsideDown: angle = 270
        case .landscapeLeft: angle = 0
        case .landscapeRight: angle = 180
        default: angle = 90
        }
        captureRotationAngle = angle
        MainActor.assumeIsolated {
            applyCaptureRotation()
            CallDebugLog.log("CameraRotation", "angle=\(angle) orientation=\(orientation.rawValue)")
        }
    }

    func startCapture() {
        updateRotation()
        // Orientierungs-Benachrichtigungen aktivieren: ohne diesen Aufruf
        // feuert orientationDidChangeNotification NIE - die Eigenansicht
        // würde sich während des Calls nicht an Hochkant/Landscape anpassen.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func stopCapture() {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
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
        // Buffer kommen von AVFoundation fertig gedreht (videoRotationAngle)
        // - die WebRTC-Frames tragen daher immer ._0.
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: Int64(timeStampNs))
        delegate.capturer(capturer, didCapture: frame)
    }

    private var firstFrameLogged = false
}
