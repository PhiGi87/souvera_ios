// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from souvera_android link/call/CallSession.kt.
//
// Orchestrates a single "Link" call. The Souvera server runs the High Performance Backend with an
// MCU (Janus), so media is not negotiated peer-to-peer: the local participant publishes its stream
// to the MCU (one "publisher" peer connection addressed to its own session) and requests a separate
// "subscriber" peer connection per remote participant. A direct 1:1 fallback is kept for servers
// without an MCU.

import Foundation
import AVFoundation
import WebRTC

protocol CallSessionCallbacks: AnyObject {
    func onLocalVideo(track: RTCVideoTrack)
    /// Neuer Remote-Video-Stream (session + Stream-Typ: "video"/"screen").
    func onRemoteVideo(session: String, roomType: String, track: RTCVideoTrack)
    /// Remote-Stream wurde entfernt (z. B. Bildschirmfreigabe beendet).
    func onRemoteVideoRemoved(session: String, roomType: String)
    /// Aktiver Sprecher gewechselt (Fokus-Modus).
    func onActiveSpeaker(session: String, roomType: String)
    func onEnded()
}

final class CallSession: NSObject, HpbSignalingListener {
    private let account: LinkAccount
    private let token: String
    var callbacks: CallSessionCallbacks?

    private let api: LinkOcsApi
    private let webRtc = WebRtcClient()
    private var signaling: HpbSignalingClient?
    private var localAudio: RTCAudioTrack?
    private var localVideo: RTCVideoTrack?

    private var peers: [String: RTCPeerConnection] = [:]
    private var observers: [String: PeerObserver] = [:]
    private var requestedOffers: Set<String> = []
    private var pendingIceServers: [RTCIceServer] = []
    fileprivate var ownSessionId = ""
    private var mcuActive = false
    private var endedOnce = false
    private let silent: Bool
    private let withVideo: Bool
    /// Aktueller Video-Zustand (für Re-Attach der Call-UI).
    private(set) var isVideoEnabled: Bool
    var isMutedLocally: Bool { !(localAudio?.isEnabled ?? true) }
    private var publisherCreated = false
    private var videoCreationInFlight = false
    /// Remote-Video-Streams (Key = session|roomType) für den Fokus-Modus.
    struct RemoteStream {
        let session: String
        let roomType: String
        let track: RTCVideoTrack
    }
    private(set) var remoteStreams: [String: RemoteStream] = [:]
    private var speakerTimer: Timer?
    private var activeSpeakerKey: String?

    private var callFlags: Int

    init(account: LinkAccount, token: String, callbacks: CallSessionCallbacks?, withVideo: Bool = true, silent: Bool = false) {
        self.account = account
        self.token = token
        self.callbacks = callbacks
        self.silent = silent
        self.withVideo = withVideo
        self.isVideoEnabled = withVideo
        self.callFlags = withVideo ? 7 : 3 // FLAG_IN_CALL|WITH_AUDIO|WITH_VIDEO : IN_CALL|AUDIO
        self.api = LinkOcsApi(account: account)
        super.init()
    }

    func start() {
        Task {
            CallDebugLog.log("CallSession", "start token=\(token)")
            // Audio-Session SOFORT konfigurieren (vor Track-Erstellung und
            // Signaling) - das WebRTC-Audio-Device braucht die aktive
            // playAndRecord-Session, sonst bleibt das Mikrofon stumm und der
            // Browser zeigt den Teilnehmer mit durchgestrichenem Mikrofon.
            Self.activateCallAudioSession()
            await startMedia()
        }
    }

    /// Startet die Medienebene ohne Video (z. B. wenn die Kamera bei einem
    /// eingehenden Video-Call verweigert wurde).
    func startAudioOnly() {
        Task {
            CallDebugLog.log("CallSession", "startAudioOnly token=\(token)")
            Self.activateCallAudioSession()
            await startMedia(forceAudioOnly: true)
        }
    }

    private func startMedia(forceAudioOnly: Bool = false) async {
        if forceAudioOnly {
            callFlags &= ~4
        }
        guard let ncSession = await api.joinRoom(token: token) else {
            CallDebugLog.log("CallSession", "joinRoom failed"); return end()
        }
        guard let settings = await api.getSignalingSettings(token: token) else {
            CallDebugLog.log("CallSession", "getSignalingSettings failed"); return end()
        }
        // joinCall runs after the signaling room join (onRoomJoined) -
        // mirroring the Android client. Opening the call earlier makes
        // the MCU ignore our publisher.
        await MainActor.run {
            let audio = self.webRtc.createLocalAudioTrack()
            // "Stiller Anruf" startet lokal stumm (Talk-Standard).
            audio.isEnabled = !self.silent
            self.localAudio = audio
            CallDebugLog.log("CallSession", "audio track created, muted=\(self.silent)")
            if self.withVideo && !forceAudioOnly {
                self.createVideoTrackIfNeeded()
            }
        }
        pendingIceServers = settings.iceServers()
        if settings.hasExternalServer {
            let client = HpbSignalingClient(settings: settings, backendUrl: account.baseUrl, roomToken: token, ncSessionId: ncSession, listener: self)
            signaling = client
            client.connect()
        } else {
            CallDebugLog.log("CallSession", "No external signaling server; 1:1 internal not implemented")
        }
    }

    // MARK: - HpbSignalingListener

    var hasEnded: Bool { endedOnce }

    func onConnected(ownSessionId: String, mcuActive: Bool) {
        self.ownSessionId = ownSessionId
        self.mcuActive = mcuActive
        CallDebugLog.log("CallSession", "signaling connected own=\(ownSessionId) mcu=\(mcuActive)")
    }

    /// The signaling room join is confirmed - now open the call via OCS.
    func onRoomJoined() {
        Task {
            await api.joinCall(token: token, flags: callFlags, silent: silent)
            CallDebugLog.log("CallSession", "joinCall sent flags=\(callFlags) (after room join)")
        }
    }

    /// Aktiviert die Call-Audio-Session: playAndRecord + voiceChat (Standard
    /// = Hörmuschel); der Speaker-Button schaltet auf .speaker/.videoChat um.
    static func activateCallAudioSession() {
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        do {
            try audioSession.setCategory(.playAndRecord, with: [.allowBluetooth, .allowBluetoothA2DP])
            try audioSession.setMode(.voiceChat)
            try audioSession.setActive(true)
            try audioSession.overrideOutputAudioPort(.none)
            CallDebugLog.log("CallSession", "audio session active (playAndRecord/voiceChat/earpiece)")
        } catch {
            CallDebugLog.log("CallSession", "audio session error: \(error.localizedDescription)")
        }
        audioSession.unlockForConfiguration()
    }

    /// The server confirmed our session is in-call; only now may we publish
    /// to the MCU (publishing earlier is rejected/ignored by Janus).
    func onSelfInCall() {
        guard mcuActive, !publisherCreated else { return }
        publisherCreated = true
        CallDebugLog.log("CallSession", "createPublisher to own=\(ownSessionId)")
        createPublisher()
    }

    private func createPublisher() {
        let peer = peerFor(key: ownSessionId, session: ownSessionId, addLocalTracks: true, isPublisher: true, roomType: "video")
        peer.offer(for: publisherConstraints()) { [weak self] sdp, _ in
            guard let self, let sdp else { return }
            peer.setLocalDescription(sdp) { _ in }
            self.signaling?.sendOffer(toSession: self.ownSessionId, sdp: sdp.sdp)
        }
        startSpeakerPolling()
    }

    // MARK: - Aktiver Sprecher (Fokus-Modus)

    private func startSpeakerPolling() {
        speakerTimer?.invalidate()
        speakerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.pollActiveSpeaker()
        }
    }

    private func stopSpeakerPolling() {
        speakerTimer?.invalidate()
        speakerTimer = nil
        activeSpeakerKey = nil
    }

    /// Pollt die Audio-Level aller Subscriber-Peers und meldet den lautesten
    /// Teilnehmer als aktiven Sprecher (Schwelle + Halten des letzten).
    private func pollActiveSpeaker() {
        guard mcuActive else { return }
        let subscriberPeers = peers.filter { $0.key != ownSessionId }
        guard !subscriberPeers.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            var best: (level: Double, key: String)?
            for (key, peer) in subscriberPeers {
                let level = await self.audioLevel(of: peer)
                if level > (best?.level ?? -1) {
                    best = (level, key)
                }
            }
            guard let best, best.level >= 0.05 else { return }
            guard best.key != self.activeSpeakerKey else { return }
            self.activeSpeakerKey = best.key
            let parts = best.key.split(separator: "|").map(String.init)
            let session = parts.first ?? ""
            let roomType = parts.count > 1 ? parts[1] : "video"
            CallDebugLog.log("CallSession", "active speaker -> \(session.prefix(8)) type=\(roomType) level=\(best.level)")
            self.callbacks?.onActiveSpeaker(session: session, roomType: roomType)
        }
    }

    private func audioLevel(of peer: RTCPeerConnection) async -> Double {
        await withCheckedContinuation { continuation in
            peer.statistics { report in
                let level = report.statistics.values
                    .filter { ($0.values["type"] as? String) == "inbound-rtp" && ($0.values["mediaType"] as? String) == "audio" }
                    .compactMap { ($0.values["audioLevel"] as? NSNumber)?.doubleValue }
                    .max() ?? -1
                continuation.resume(returning: level)
            }
        }
    }

    func onParticipants(sessionIds: [String]) {
        if mcuActive {
            // NIE ein Angebot für die eigene Session anfordern - das
            // korrumpiert den Publisher-Zustand am MCU (Uplink stirbt).
            for session in sessionIds where session != ownSessionId
                && !session.isEmpty
                && requestedOffers.insert(session).inserted {
                signaling?.sendRequestOffer(toSession: session)
            }
            return
        }
        for session in sessionIds where session != ownSessionId && peers[session] == nil {
            let peer = peerFor(key: session, session: session, addLocalTracks: true, isPublisher: false, roomType: "video")
            if ownSessionId > session {
                peer.offer(for: receiveConstraints()) { [weak self] sdp, _ in
                    guard let self, let sdp else { return }
                    peer.setLocalDescription(sdp) { _ in }
                    self.signaling?.sendOffer(toSession: session, sdp: sdp.sdp)
                }
            }
        }
    }

    func onOffer(fromSession: String, sdp: String, roomType: String) {
        // Peers pro Session UND Stream-Typ (Bildschirmfreigabe kommt als
        // zweites Angebot derselben Session).
        let key = Self.streamKey(session: fromSession, roomType: roomType)
        let peer = peerFor(key: key, session: fromSession, addLocalTracks: !mcuActive, isPublisher: false, roomType: roomType)
        let remote = RTCSessionDescription(type: .offer, sdp: sdp)
        peer.setRemoteDescription(remote) { [weak self] _ in
            guard let self else { return }
            peer.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, _ in
                guard let answer else { return }
                peer.setLocalDescription(answer) { _ in }
                self.signaling?.sendAnswer(toSession: fromSession, sdp: answer.sdp)
            }
        }
    }

    func onAnswer(fromSession: String, sdp: String) {
        let peer = peers[fromSession] ?? peers.first(where: { $0.key.hasPrefix("\(fromSession)|") })?.value
        peer?.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { _ in }
    }

    static func streamKey(session: String, roomType: String) -> String {
        "\(session)|\(roomType)"
    }

    func onCandidate(fromSession: String, candidate: [String: Any]) {
        guard let peer = peers[fromSession], let sdp = candidate["candidate"] as? String else { return }
        let ice = RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(candidate["sdpMLineIndex"] as? Int ?? 0), sdpMid: candidate["sdpMid"] as? String)
        peer.add(ice) { _ in }
    }

    func onClosed() {}

    // MARK: - Controls

    func setMuted(_ muted: Bool) {
        CallDebugLog.log("CallSession", "setMuted \(muted)")
        localAudio?.isEnabled = !muted
    }

    /// Video an/aus. Im Audio-Call existiert der Video-Track noch nicht -
    /// er wird hier LAZY erzeugt (Kamera startet erst dann), dem Publisher
    /// hinzugefügt und neu verhandelt; zusätzlich werden die Call-Flags auf
    /// "mit Video" angehoben (Talk-Standard). Aus: Capture stoppen (Kamera
    /// aus), Track deaktivieren.
    func setVideoEnabled(_ enabled: Bool) {
        CallDebugLog.log("CallSession", "setVideoEnabled \(enabled)")
        if enabled {
            Task { @MainActor in
                self.createVideoTrackIfNeeded()
                guard let video = self.localVideo else {
                    CallDebugLog.log("CallSession", "video enable failed: no camera track")
                    return
                }
                if !video.isEnabled {
                    video.isEnabled = true
                }
                self.webRtc.startVideoCapture()
                // Der neue Track muss in bestehende lokale Verbindungen
                // aufgenommen werden (Publisher bzw. 1:1-Peers).
                for (session, peer) in self.peers where !self.mcuActive || session == self.ownSessionId {
                    peer.add(video, streamIds: ["link"])
                }
                // Call-Flags aktualisieren, damit der Raum als Video-Call gilt.
                if self.callFlags & 4 == 0 {
                    self.callFlags |= 4
                    await self.api.joinCall(token: self.token, flags: self.callFlags, silent: self.silent)
                    CallDebugLog.log("CallSession", "joinCall flags updated to \(self.callFlags)")
                }
                // Publisher neu verhandeln (MCU), 1:1-Peers ebenfalls.
                self.renegotiateAfterVideoChange()
            }
            isVideoEnabled = true
        } else {
            localVideo?.isEnabled = false
            webRtc.stopVideoCapture()
            isVideoEnabled = false
            // Server-Flags zurücksetzen (ohne WITH_VIDEO), damit andere
            // Clients sofort sehen, dass die Kamera aus ist.
            if callFlags & 4 != 0 {
                callFlags &= ~4
                Task {
                    await api.joinCall(token: token, flags: callFlags, silent: silent)
                    CallDebugLog.log("CallSession", "joinCall flags updated to \(callFlags) (video off)")
                }
            }
        }
    }

    /// Erzeugt den lokalen Video-Track (nur einmal); die Kamera-Capture
    /// startet erst beim Video-Call oder beim ersten Aktivieren.
    private func createVideoTrackIfNeeded() {
        guard localVideo == nil, !videoCreationInFlight else { return }
        videoCreationInFlight = true
        if let video = webRtc.createLocalVideoTrack() {
            localVideo = video
            callbacks?.onLocalVideo(track: video)
            CallDebugLog.log("CallSession", "local video track created")
        }
        videoCreationInFlight = false
    }

    /// Nach einer Video-Änderung: vorhandene Verbindungen neu aushandeln.
    /// Im MCU-Modus betrifft das die eigene Publisher-Verbindung; im 1:1-
    /// Fall alle Peers, die lokale Tracks tragen.
    private func renegotiateAfterVideoChange() {
        if mcuActive, let peer = peers[ownSessionId] {
            peer.offer(for: publisherConstraints()) { [weak self] sdp, _ in
                guard let self, let sdp else { return }
                peer.setLocalDescription(sdp) { _ in }
                self.signaling?.sendOffer(toSession: self.ownSessionId, sdp: sdp.sdp)
                CallDebugLog.log("CallSession", "publisher re-offer sent after video change")
            }
        } else {
            for (key, peer) in peers where key != ownSessionId && !key.isEmpty {
                let session = key.split(separator: "|").map(String.init).first ?? ""
                peer.offer(for: receiveConstraints()) { [weak self] sdp, _ in
                    guard let self, let sdp else { return }
                    peer.setLocalDescription(sdp) { _ in }
                    self.signaling?.sendOffer(toSession: session, sdp: sdp.sdp)
                }
            }
        }
    }

    func hangup() {
        if endedOnce { return }
        endedOnce = true
        stopSpeakerPolling()
        CallDebugLog.log("CallSession", "hangup start")
        Task { await api.leaveCall(token: token) }
        signaling?.close()
        peers.values.forEach { $0.close() }
        peers.removeAll()
        // dispose() ist teuer und darf den Main-Thread nicht blockieren
        // (sonst bleibt die UI weiss, wenn der Cover geschlossen wird).
        let webRtcDispose = webRtc
        DispatchQueue.global(qos: .userInitiated).async {
            webRtcDispose.dispose()
            CallDebugLog.log("CallSession", "webRtc disposed")
        }

        // Deactivate the call audio session - leaving it active keeps iOS in
        // a dead "call running" state (status bar, routing, mic).
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        try? audioSession.setActive(false)
        audioSession.unlockForConfiguration()

        // End the CallKit transaction if one is active for this call.
        LinkVoIPManager.shared.callEndedByApp()

        callbacks?.onEnded()
        // Clear the shared call state so banners ("Zurück zum Anruf")
        // disappear everywhere - a user-initiated hangup must behave
        // exactly like a remote end.
        LinkVoIPManager.shared.callSessionDidEnd(self)
        NotificationCenter.default.post(name: .linkCallUIClose, object: nil)
        CallDebugLog.log("CallSession", "hangup done")
    }

    // MARK: - Peer helpers

    private func peerFor(key: String, session: String, addLocalTracks: Bool, isPublisher: Bool, roomType: String) -> RTCPeerConnection {
        if let existing = peers[key] { return existing }
        let observer = PeerObserver(session: session, roomType: roomType, key: key, owner: self)
        observers[key] = observer
        guard let peer = webRtc.createPeerConnection(iceServers: pendingIceServers, delegate: observer) else {
            fatalError("Cannot create peer connection")
        }
        if addLocalTracks {
            if let audio = localAudio { peer.add(audio, streamIds: ["link"]) }
            if let video = localVideo { peer.add(video, streamIds: ["link"]) }
        }
        peers[key] = peer
        return peer
    }

    private func publisherConstraints() -> RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "false"], optionalConstraints: nil)
    }

    private func receiveConstraints() -> RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"], optionalConstraints: nil)
    }

    private func end() {
        callbacks?.onEnded()
        LinkVoIPManager.shared.callSessionDidEnd(self)
    }

    fileprivate func emitCandidate(session: String, roomType: String, candidate: RTCIceCandidate) {
        let json: [String: Any] = [
            "candidate": candidate.sdp,
            "sdpMid": candidate.sdpMid ?? "",
            "sdpMLineIndex": Int(candidate.sdpMLineIndex)
        ]
        signaling?.sendCandidate(toSession: session, candidate: json, roomType: roomType)
    }

    fileprivate func emitRemoteVideo(session: String, roomType: String, track: RTCVideoTrack) {
        let key = Self.streamKey(session: session, roomType: roomType)
        remoteStreams[key] = RemoteStream(session: session, roomType: roomType, track: track)
        callbacks?.onRemoteVideo(session: session, roomType: roomType, track: track)
        CallDebugLog.log("CallSession", "remote stream added session=\(session.prefix(8)) type=\(roomType)")
    }

    fileprivate func emitRemoteVideoRemoved(session: String, roomType: String) {
        let key = Self.streamKey(session: session, roomType: roomType)
        guard remoteStreams.removeValue(forKey: key) != nil else { return }
        callbacks?.onRemoteVideoRemoved(session: session, roomType: roomType)
        CallDebugLog.log("CallSession", "remote stream removed session=\(session.prefix(8)) type=\(roomType)")
    }

    /// Re-attaches a new call UI (e.g. after returning from the chat) to the
    /// running session and re-emits the active tracks.
    func reattach(callbacks: CallSessionCallbacks) {
        self.callbacks = callbacks
        if let local = localVideo { callbacks.onLocalVideo(track: local) }
        for (_, stream) in remoteStreams {
            callbacks.onRemoteVideo(session: stream.session, roomType: stream.roomType, track: stream.track)
        }
    }
}

/// Per-remote-participant RTCPeerConnectionDelegate; forwards ICE candidates and remote video.
private final class PeerObserver: NSObject, RTCPeerConnectionDelegate {
    private let session: String
    private let roomType: String
    private let key: String
    private weak var owner: CallSession?

    init(session: String, roomType: String, key: String, owner: CallSession) {
        self.session = session
        self.roomType = roomType
        self.key = key
        self.owner = owner
    }

    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        owner?.emitCandidate(session: session, roomType: roomType, candidate: candidate)
    }

    func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if let video = rtpReceiver.track as? RTCVideoTrack {
            owner?.emitRemoteVideo(session: session, roomType: roomType, track: video)
        }
    }

    // Unused delegate requirements.
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        owner?.emitRemoteVideoRemoved(session: session, roomType: roomType)
    }
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        CallDebugLog.log("PeerObserver", "key=\(key.prefix(12)) ICE connection -> \(Self.stateName(newState))")
        if newState == .connected, key == owner?.ownSessionId {
            // Publisher steht: Audio-Session-Zustand für die Diagnose loggen.
            let audio = RTCAudioSession.sharedInstance()
            CallDebugLog.log("PeerObserver", "publisher connected; audioSession active=\(audio.isActive)")
            let av = AVAudioSession.sharedInstance()
            CallDebugLog.log("PeerObserver", "AVAudioSession category=\(av.category.rawValue) mode=\(av.mode.rawValue) otherAudio=\(av.isOtherAudioPlaying)")
        }
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        CallDebugLog.log("PeerObserver", "session=\(session) ICE gathering -> \(Self.stateName(newState))")
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        CallDebugLog.log("PeerObserver", "session=\(session) connection -> \(Self.stateName(newState))")
    }
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    private static func stateName(_ state: RTCIceConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return "count"
        @unknown default: return "unknown"
        }
    }

    private static func stateName(_ state: RTCIceGatheringState) -> String {
        switch state {
        case .new: return "new"
        case .gathering: return "gathering"
        case .complete: return "complete"
        @unknown default: return "unknown"
        }
    }

    private static func stateName(_ state: RTCPeerConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .failed: return "failed"
        case .closed: return "closed"
        @unknown default: return "unknown"
        }
    }
}
