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
    /// Kamera-Zugriff beim Video-Einschalten verweigert (UI-Hinweis).
    func onVideoPermissionDenied()
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
    /// Raum-Token (lesbar für die Call-Übernahme P68c).
    let token: String
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

    /// "status"-DataChannel pro MCU-Verbindung (Janus-Protokoll wie im
    /// souvera_android-Pendant): Publisher + Subscriber. Über den Kanal
    /// melden wir dem MCU unseren Medienzustand (unmute/mute/videoOn/off).
    private var statusChannels: [String: RTCDataChannel] = [:]

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
        timingLog("session init")
        // P68v: Encoder-Fähigkeit hart loggen (beweist, ob VP8-Encoding im
        // Build enthalten ist - entscheidend für die Video-Diagnose).
        CallDebugLog.log("CallSession", "video encoder codecs: \(RTCDefaultVideoEncoderFactory.supportedCodecs().map { $0.name }.joined(separator: ","))")
    }

    /// P68g: Meilenstein-Logs für die Call-Aufbau-Latenz (Start -> audioOn).
    private let sessionStartDate = Date()
    private func timingLog(_ milestone: String) {
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(sessionStartDate))
        CallDebugLog.log("CallTiming", "\(milestone) +\(elapsed)s")
    }

    /// P68w: Serielle WebRTC-Queue für ALLE PeerConnection-Operationen
    /// (talk-iOS WebRTCCommon-Muster: "Every call into the WebRTC library
    /// must be dispatched to this queue"). Parallele Calls aus WebRTC-
    /// Callbacks + Websocket-Receive + MainActor sind ein Kandidat für den
    /// ausbleibenden Encoder-Callback gewesen.
    nonisolated static let webRtcQueue = DispatchQueue(label: "souvera.webrtc", qos: .userInitiated)

    /// Safety-Net: Wird die Session ohne explizites hangup() freigegeben
    /// (UI weg, App beendet, Crash-Pfade), bleibt sonst eine Geister-
    /// Session ("Gelöschter Benutzer") im Raum zurück.
    deinit {
        if !endedOnce {
            CallDebugLog.log("CallSession", "deinit without hangup - sending leaveCall")
            let api = api
            let token = token
            Task.detached {
                await api.leaveCall(token: token)
            }
        }
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
        timingLog("startMedia")
        // P68g: Settings ggf. aus dem Pre-Warm (VoIP-Push hat sie schon vor
        // der Annahme geladen). joinRoom läuft IMMER frisch hier - eine
        // veraltete Session aus dem Pre-Warm verursachte die 404-Kette
        // und den Session-Mismatch am MCU (keine Medien).
        let settings: SignalingSettings?
        if let pre = LinkVoIPManager.shared.consumePrewarmedSettings(for: token) {
            settings = pre
            timingLog("prewarm settings consumed")
        } else {
            settings = await api.getSignalingSettings(token: token)
        }
        guard let settings else {
            CallDebugLog.log("CallSession", "getSignalingSettings failed"); return end()
        }
        timingLog("settings done")
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
        lastSignalingSettings = settings
        if settings.hasExternalServer {
            // P68w: Basis-/Android-Reihenfolge (talk-iOS NCCallController +
            // souvera_android CallSession.kt): ERST die frische Session
            // (joinRoom), DANN der Signaling-Connect MIT dieser Session -
            // der HPB ordnet die Verbindung sofort dem User zu (kein
            // "Gelöschter Benutzer") und joint den Raum direkt nach dem
            // Hello. joinCall folgt NACH dem Room-Join (onRoomJoined),
            // der Publisher NACH dem joinCall-Erfolg. Der frühe joinCall
            // vor dem Room-Join (P68q) ist rückgebaut - er verzögerte den
            // participants/update-Broadcast und machte den "Gelöschter
            // Benutzer"-Transienten permanent.
            Task { [weak self] in
                guard let self else { return }
                guard let freshSession = await self.api.joinRoom(token: self.token) else {
                    CallDebugLog.log("CallSession", "joinRoom failed"); self.end()
                    return
                }
                self.timingLog("fresh joinRoom done")
                let client = HpbSignalingClient(settings: settings, backendUrl: self.account.baseUrl, roomToken: self.token, ncSessionId: freshSession, listener: self)
                self.signaling = client
                client.connect()
            }
        } else {
            CallDebugLog.log("CallSession", "No external signaling server; 1:1 internal not implemented")
        }
    }

    private var signalingConnected = false

    // MARK: - HpbSignalingListener

    var hasEnded: Bool { endedOnce }

    func onConnected(ownSessionId: String, mcuActive: Bool) {
        self.ownSessionId = ownSessionId
        self.mcuActive = mcuActive
        CallDebugLog.log("CallSession", "signaling connected own=\(ownSessionId) mcu=\(mcuActive)")
        timingLog("signaling connected")
        signalingConnected = true
        // P68w: Der Client joint den Raum direkt nach dem Hello (Session
        // wurde beim Connect übergeben). joinCall NICHT hier senden -
        // vor dem Room-Join beantwortet der Server mit 404 ("not joined").
        // joinCall läuft erst nach dem Room-Join (onRoomJoined).
    }

    /// The signaling room join is confirmed. P68g: Der erste joinCall wurde
    /// serverseitig immer mit 404 beantwortet; ein FRISCHES joinRoom direkt
    /// davor lieferte 200. Deshalb: nochmal joinRoom (frische Session) und
    /// die Signaling-VERBINDUNG mit dieser Session NEU aufbauen - der
    /// Same-Socket-Rejoin ("room"-Message mit neuer Session) wurde vom HPB
    /// ignoriert (belegt: kein participants/update, keine Medien). Der
    /// frische Connect mit der frischen Session ist das bewährte Muster.
    func onRoomJoined() {
        timingLog("room joined")
        sendJoinCall()
    }

    /// P68g: Signaling-Verbindung mit einer frischen Session neu aufbauen
    /// (Settings + Audio-Track werden wiederverwendet - nur der Websocket
    /// wird neu geöffnet). Der zweite Room-Join triggert onRoomJoined erneut
    /// und öffnet dann den Call.
    private func reconnectSignaling(sessionId: String) {
        guard let settings = lastSignalingSettings else {
            CallDebugLog.log("CallSession", "reconnect failed: no settings")
            return
        }
        signaling?.close()
        signaling = nil
        peers.removeAll()
        statusChannels.removeAll()
        publisherCreated = false
        joinCallSent = false
        signalingConnected = false
        let client = HpbSignalingClient(settings: settings, backendUrl: account.baseUrl, roomToken: token, ncSessionId: sessionId, listener: self)
        signaling = client
        client.connect()
        timingLog("signaling reconnect")
    }

    /// P68g: Letzte Signaling-Settings (für den Reconnect mit frischer
    /// Session - ohne erneuten Settings-Fetch).
    private var lastSignalingSettings: SignalingSettings?

    /// P68v: Video-Sender-Parameter loggen (nach der Answer gefüllt).
    private func logVideoSenderParams() {
        guard let pub = peers[ownSessionId] else { return }
        for sender in pub.senders where sender.track?.kind == "video" {
            let params = sender.parameters
            let codecNames = params.codecs.map { $0.name }.joined(separator: ",")
            let encodings = params.encodings.map { "ssrc=\($0.ssrc ?? 0) active=\($0.isActive)" }.joined(separator: " ")
            CallDebugLog.log("CallSession", "video sender params after answer codecs=[\(codecNames)] encodings=[\(encodings)]")
        }
    }

    /// P68g: joinCall mit klarer Fehlerpolitik:
    /// - 404 (deterministisch: "not joined"): KEINE Retries - sofort der
    ///   Reconnect mit frischer joinRoom-Session (gleicher Settings/Audio,
    ///   nur der Websocket wird neu aufgebaut). Greift der auch nicht,
    ///   folgt einmalig der volle Neuaufbau (talk-iOS forceReconnect).
    /// - Netzfehler (0/5xx): bis zu 3 Retries.
    private var joinCallSent = false
    private var cheapRejoinDone = false
    private var forceRejoinedOnce = false
    private func sendJoinCall(retry: Int = 3) {
        guard !joinCallSent, !endedOnce else { return }
        joinCallSent = true
        timingLog("joinCall sending")
        Task { [weak self] in
            guard let self else { return }
            let flags = self.callFlags
            let status = await self.api.joinCall(token: self.token, flags: flags, silent: self.silent)
            let ok = (200..<300).contains(status)
            if ok {
                CallDebugLog.log("CallSession", "joinCall sent flags=\(flags)")
                self.timingLog("joinCall ok")
                // P68w: Basis-Muster (talk-iOS): der Publisher wird direkt
                // nach dem joinCall-Erfolg erstellt - NICHT erst nach dem
                // participants/update (das verzögerte den Publisher um
                // 10-20 s und machte den Teilnehmer stumm, bis Video
                // gestartet wurde). onSelfInCall bleibt als Fallback.
                self.createPublisherIfNeeded()
            } else if status == 404, !self.cheapRejoinDone, !self.endedOnce {
                // Billiger Rejoin: nur joinRoom + joinCall erneut (Signaling
                // bleibt). ~0,5 s statt ~2,5 s Komplett-Neuaufbau.
                CallDebugLog.log("CallSession", "joinCall 404 - cheap rejoin")
                self.cheapRejoinDone = true
                self.joinCallSent = false
                guard let freshSession = await self.api.joinRoom(token: self.token) else {
                    CallDebugLog.log("CallSession", "cheap rejoin: joinRoom failed - full force rejoin")
                    self.forceFullRejoin()
                    return
                }
                // Frische Session braucht einen FRISCHEN Signaling-Connect
                // (Same-Socket-Rejoin ignoriert der HPB - belegt).
                self.reconnectSignaling(sessionId: freshSession)
            } else if status == 404, !self.forceRejoinedOnce, !self.endedOnce {
                CallDebugLog.log("CallSession", "joinCall 404 again - full force rejoin once")
                self.forceFullRejoin()
            } else if status == 0 || status >= 500 {
                if retry > 0, !self.endedOnce {
                    CallDebugLog.log("CallSession", "joinCall network error http=\(status) - retry (\(retry) left)")
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    self.joinCallSent = false
                    self.sendJoinCall(retry: retry - 1)
                } else {
                    CallDebugLog.log("CallSession", "joinCall FAILED http=\(status) - ending call")
                    self.hangup()
                }
            } else {
                // Andere Fehler (400 consent, 403 Lobby ...): Call beenden.
                CallDebugLog.log("CallSession", "joinCall FAILED http=\(status) - ending call")
                self.hangup()
            }
        }
    }

    /// talk-iOS forceReconnect: Signaling neu verbinden + Raum erneut
    /// joinen, dann joinCall noch einmal.
    private func forceFullRejoin() {
        guard !forceRejoinedOnce, !endedOnce else { return }
        forceRejoinedOnce = true
        joinCallSent = false
        signaling?.close()
        signaling = nil
        publisherCreated = false
        peers.removeAll()
        statusChannels.removeAll()
        signalingConnected = false
        Task { [weak self] in
            guard let self else { return }
            await self.startMedia()
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
    /// P68w: NUR noch Fallback - der Normalfall erstellt den Publisher
    /// direkt nach dem joinCall-Erfolg (talk-iOS-Muster).
    func onSelfInCall() {
        createPublisherIfNeeded()
    }

    private func createPublisherIfNeeded() {
        guard mcuActive, !publisherCreated, !endedOnce else { return }
        publisherCreated = true
        audioOnResendGeneration += 1
        CallDebugLog.log("CallSession", "createPublisher to own=\(ownSessionId)")
        timingLog("createPublisher")
        Self.webRtcQueue.async { [weak self] in
            self?.createPublisher()
        }
    }

    private func createPublisher() {
        let peer = peerFor(key: ownSessionId, session: ownSessionId, addLocalTracks: true, isPublisher: true, roomType: "video")
        // Diagnose: Sender-Anzahl + Track-Arten (fehlen Sender, fließen
        // keine Medien zum MCU).
        let senders = peer.senders
        CallDebugLog.log("CallSession", "publisher senders=\(senders.count) kinds=[\(senders.compactMap { $0.track?.kind }.joined(separator: ","))]")
        peer.offer(for: publisherConstraints()) { [weak self] sdp, _ in
            guard let self, let sdp else { return }
            // P68x: VP8/AV1 komplett aus dem Angebot entfernen - die MCU
            // muss H264 antworten (VideoToolbox). Der VP8-Encoder liefert
            // keine kodierten Frames über den Callback (Proben).
            let preferred = Self.h264OnlySdp(sdp.sdp)
            let finalSdp = RTCSessionDescription(type: sdp.type, sdp: preferred)
            peer.setLocalDescription(finalSdp) { _ in }
            let kinds = Self.mediaLines(of: preferred)
            CallDebugLog.log("CallSession", "publisher offer m-lines=[\(kinds.joined(separator: ","))]")
            CallDebugLog.log("CallSession", "publisher offer video codecs: \(Self.videoCodecLines(of: preferred))")
            self.signaling?.sendOffer(toSession: self.ownSessionId, sdp: preferred)
        }
        startSpeakerPolling()
        // P68a: Der initiale audioOn beim Verbinden wirkt am MCU teils
        // nicht (Ton kommt erst nach User-Toggle). Fix: nach dem
        // Publisher-Connect erneut senden und den Capture einmal kurz
        // re-affirmieren.
        scheduleAudioOnResend()
    }

    /// P68a: audioOn-Resend nach Publisher-Aufbau (+1,5 s und +4 s) plus
    /// Capture-Re-Affirmation (isEnabled false->true). Greift nur, wenn
    /// nicht inzwischen gemutet wurde und die Session noch lebt.
    private func scheduleAudioOnResend() {
        let generation = audioOnResendGeneration
        for delay in [1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.audioOnResendGeneration == generation,
                      !self.isMutedLocally,
                      self.mcuActive else { return }
                CallDebugLog.log("CallSession", "audioOn resend (+\(delay)s)")
                self.sendStatusMessage("audioOn")
                if let track = self.localAudio {
                    track.isEnabled = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        track.isEnabled = true
                        CallDebugLog.log("CallSession", "audio capture re-affirmed")
                    }
                }
            }
        }
    }

    /// P68a: zählt Call-Starts; veraltete Resend-Timer werden ignoriert.
    private var audioOnResendGeneration = 0

    /// P68f: talk-iOS ARDSDPUtils-Port - verschiebt die Payload-Typen des
    /// Ziel-Codecs an den ANFANG der m=video-Zeile (REORDER statt Removal).
    /// Alle anderen Codecs bleiben erhalten; das SDP bleibt damit gültig
    /// (kein verwaister rtx/ssrc-group-FID wie beim früheren Removal, das
    /// die MCU-Ablehnung "m=video 0" auslöste).
    static func preferringVideoCodec(_ sdpText: String, codec: String) -> String {
        var lines = sdpText.components(separatedBy: "\n")
        guard let mLineIndex = lines.firstIndex(where: { $0.hasPrefix("m=video") }) else {
            return sdpText
        }
        // a=rtpmap:<payload> <codec>/<clock rate>[/<params>].
        let pattern = "^a=rtpmap:(\\d+) \(codec)(/\\d+)+[\\r]?$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return sdpText }
        var codecPayloads: [String] = []
        for line in lines {
            let ns = line as NSString
            if let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) {
                codecPayloads.append(ns.substring(with: match.range(at: 1)))
            }
        }
        guard !codecPayloads.isEmpty else { return sdpText }
        let parts = lines[mLineIndex].split(separator: " ")
        guard parts.count > 3 else { return sdpText }
        let header = parts.prefix(3).map(String.init)
        var payloads = parts.dropFirst(3).map(String.init)
        payloads.removeAll { codecPayloads.contains($0) }
        let newParts = header + codecPayloads + payloads
        lines[mLineIndex] = newParts.joined(separator: " ")
        return lines.joined(separator: "\n")
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
                    let preferred = Self.preferringVideoCodec(sdp.sdp, codec: "H264")
                    let finalSdp = RTCSessionDescription(type: sdp.type, sdp: preferred)
                    peer.setLocalDescription(finalSdp) { _ in }
                    self.signaling?.sendOffer(toSession: session, sdp: preferred)
                }
            }
        }
    }

    func onOffer(fromSession: String, sdp: String, roomType: String) {
        Self.webRtcQueue.async { [weak self] in
            self?.handleOffer(fromSession: fromSession, sdp: sdp, roomType: roomType)
        }
    }

    /// P68w: On-Queue-Implementierung (serielle WebRTC-Queue, Basis-Muster).
    private func handleOffer(fromSession: String, sdp: String, roomType: String) {
        // Peers pro Session UND Stream-Typ (Bildschirmfreigabe kommt als
        // zweites Angebot derselben Session).
        let key = Self.streamKey(session: fromSession, roomType: roomType)
        let peer = peerFor(key: key, session: fromSession, addLocalTracks: !mcuActive, isPublisher: false, roomType: roomType)
        // P68f: Remote-Offer ebenfalls mit H264-Präferenz setzen.
        let remote = RTCSessionDescription(type: .offer, sdp: Self.preferringVideoCodec(sdp, codec: "H264"))
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
        Self.webRtcQueue.async { [weak self] in
            self?.handleAnswer(fromSession: fromSession, sdp: sdp)
        }
    }

    /// P68w: On-Queue-Implementierung (serielle WebRTC-Queue, Basis-Muster).
    private func handleAnswer(fromSession: String, sdp: String) {
        // Diagnose: Akzeptiert der MCU unser m=video im Re-Offer?
        // (Port 0 = abgelehnt.)
        let kinds = Self.mediaLines(of: sdp)
        CallDebugLog.log("CallSession", "answer from \(fromSession.prefix(8)) m-lines=[\(kinds.joined(separator: ","))]")
        CallDebugLog.log("CallSession", "answer video codecs: \(Self.videoCodecLines(of: sdp))")
        let peer = peers[fromSession] ?? peers.first(where: { $0.key.hasPrefix("\(fromSession)|") })?.value
        // P68f: auch die ANSWER mit H264-Präferenz setzen (talk-iOS-Muster:
        // bestimmt unseren Sende-Codec).
        let preferredAnswer = Self.preferringVideoCodec(sdp, codec: "H264")
        peer?.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: preferredAnswer)) { [weak self] _ in
            // Nach einer Re-Verhandlung den Medienzustand erneut melden -
            // der MCU kann den letzten Stand sonst verschlucken (verzögerte
            // Mute-/Video-Reaktion).
            self?.sendInitialStatus()
            // P68v: NACH der Answer sind die Sender-Parameter gefüllt
            // (ausgehandelter Codec sichtbar).
            self?.logVideoSenderParams()
        }
    }

    static func streamKey(session: String, roomType: String) -> String {
        "\(session)|\(roomType)"
    }

    func onCandidate(fromSession: String, candidate: [String: Any]) {
        Self.webRtcQueue.async { [weak self] in
            guard let self, let peer = self.peers[fromSession],
                  let sdp = candidate["candidate"] as? String else { return }
            let ice = RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(candidate["sdpMLineIndex"] as? Int ?? 0), sdpMid: candidate["sdpMid"] as? String)
            peer.add(ice) { _ in }
        }
    }

    func onClosed() {}

    // MARK: - Controls

    func setMuted(_ muted: Bool) {
        CallDebugLog.log("CallSession", "setMuted \(muted)")
        localAudio?.isEnabled = !muted
        // TALK-STANDARD: die MCU versteht "audioOn"/"audioOff" (nicht
        // "mute"/"unmute") - falsche Typen lassen den Uplink stumm.
        sendStatusMessage(muted ? "audioOff" : "audioOn")
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
                // Kamera-Rechte VOR der Track-Erstellung: Ohne Freigabe
                // liefert der Capturer nur schwarze/keine Frames und der
                // Browser zeigt ein leeres Tile.
                guard await CallPermissions.ensureCamera() else {
                    CallDebugLog.log("CallSession", "video enable failed: camera permission denied")
                    await MainActor.run {
                        self.isVideoEnabled = false
                        self.callbacks?.onVideoPermissionDenied()
                    }
                    return
                }
                self.createVideoTrackIfNeeded()
                guard let video = self.localVideo else {
                    CallDebugLog.log("CallSession", "video enable failed: no camera track")
                    return
                }
                if !video.isEnabled {
                    video.isEnabled = true
                }
                self.webRtc.startVideoCapture()
                // P68w Basis-Muster: Der Publisher hat die Video-m-line
                // bereits (Platzhalter). Upgrade = NUR sender.track ersetzen
                // - keine neue m-line, keine Renegotiation-Ergänzung (der
                // MCU relayt nachträglich hinzugefügte m-lines nicht).
                // On-Queue (serielle WebRTC-Queue, Basis-Muster).
                Self.webRtcQueue.async { [weak self] in
                    guard let self else { return }
                    for (session, peer) in self.peers where !self.mcuActive || session == self.ownSessionId {
                        if let existing = peer.transceivers.first(where: { $0.mediaType == .video }) {
                            existing.sender.track = video
                            if existing.direction != .sendOnly {
                                existing.setDirection(.sendOnly, error: nil)
                            }
                        }
                    }
                    // Publisher neu verhandeln (MCU), 1:1-Peers ebenfalls.
                    self.renegotiateAfterVideoChange()
                }
                // Call-Flags aktualisieren, damit der Raum als Video-Call gilt.
                if self.callFlags & 4 == 0 {
                    self.callFlags |= 4
                    _ = await self.api.joinCall(token: self.token, flags: self.callFlags, silent: self.silent)
                    CallDebugLog.log("CallSession", "joinCall flags updated to \(self.callFlags)")
                }
                self.sendStatusMessage("videoOn")
                self.isVideoEnabled = true
                // Diagnose: Sender + Kamera-Quelle nach dem Einschalten.
                if let pub = self.peers[self.ownSessionId] {
                    let kinds = pub.senders.compactMap { $0.track?.kind }
                    let sourceState = video.source.state.rawValue
                    CallDebugLog.log("CallSession", "video enabled; publisher senders=\(pub.senders.count) kinds=[\(kinds.joined(separator: ","))] sourceState=\(sourceState)")
                    // P68v: Sender-Parameter loggen (ausgehandelter Codec + Encodings).
                    for sender in pub.senders where sender.track?.kind == "video" {
                        let params = sender.parameters
                        let codecNames = params.codecs.map { $0.name }.joined(separator: ",")
                        let encodings = params.encodings.map { "ssrc=\($0.ssrc ?? 0) active=\($0.isActive)" }.joined(separator: " ")
                        CallDebugLog.log("CallSession", "video sender params codecs=[\(codecNames)] encodings=[\(encodings)]")
                    }
                }
            }
        } else {
            localVideo?.isEnabled = false
            webRtc.stopVideoCapture()
            isVideoEnabled = false
            sendStatusMessage("videoOff")
            // Server-Flags zurücksetzen (ohne WITH_VIDEO), damit andere
            // Clients sofort sehen, dass die Kamera aus ist.
            if callFlags & 4 != 0 {
                callFlags &= ~4
                Task {
                    _ = await api.joinCall(token: token, flags: callFlags, silent: silent)
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
                // P68x: Re-Offer ebenfalls H264-only (VP8/AV1 entfernen).
                let preferred = Self.h264OnlySdp(sdp.sdp)
                let finalSdp = RTCSessionDescription(type: sdp.type, sdp: preferred)
                peer.setLocalDescription(finalSdp) { _ in }
                self.signaling?.sendOffer(toSession: self.ownSessionId, sdp: preferred)
                let kinds = Self.mediaLines(of: preferred)
                CallDebugLog.log("CallSession", "publisher re-offer sent after video change m-lines=[\(kinds.joined(separator: ","))]")
                CallDebugLog.log("CallSession", "publisher re-offer video codecs: \(Self.videoCodecLines(of: preferred))")
            }
        } else {
            for (key, peer) in peers where key != ownSessionId && !key.isEmpty {
                let session = key.split(separator: "|").map(String.init).first ?? ""
                peer.offer(for: receiveConstraints()) { [weak self] sdp, _ in
                    guard let self, let sdp else { return }
                    let preferred = Self.preferringVideoCodec(sdp.sdp, codec: "H264")
                    let finalSdp = RTCSessionDescription(type: sdp.type, sdp: preferred)
                    peer.setLocalDescription(finalSdp) { _ in }
                    self.signaling?.sendOffer(toSession: session, sdp: preferred)
                }
            }
        }
    }

    func hangup() {
        if endedOnce { return }
        endedOnce = true
        stopSpeakerPolling()
        CallDebugLog.log("CallSession", "hangup start")
        if let peer = peers[ownSessionId] {
            dumpOutboundStats(peer: peer, tag: "final")
        }
        Task { await api.leaveCall(token: token) }
        signaling?.close()
        Self.webRtcQueue.async { [weak self] in
            self?.peers.values.forEach { $0.close() }
            self?.peers.removeAll()
        }
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

    /// P68x: Entfernt VP8/AV1 (und deren rtx/red/ulpfec) aus dem Publisher-
    /// Angebot, sodass nur H264 übrig bleibt - die MCU muss H264 antworten
    /// (VideoToolbox). Der VP8-libvpx-Encoder dieses WebRTC-Builds liefert
    /// trotz gültiger Frames/Bitrate keine kodierten Frames über den
    /// Callback aus (kein "callback delivered" in den Proben).
    static func h264OnlySdp(_ sdpText: String) -> String {
        // CRLF erhalten (SDP-Standard). Die vorherige Version strippte das
        // "\r" und joint mit "\n" - das malformte das Angebot (MCU lehnte
        // Video ab) und zerlegte die Diagnose (mediaLines fand keine m=-Zeile).
        var lines = sdpText.components(separatedBy: "\r\n")
        guard let mLineIndex = lines.firstIndex(where: { $0.hasPrefix("m=video") }) else {
            return sdpText
        }
        // Video-Section: von m=video bis zur nächsten m=-Zeile. NUR DIESE
        // Section wird gefiltert - die Audio-Codec-Zeilen (opus/red/...)
        // bleiben unangetastet (die vorherige Version löschte sie mit und
        // machte damit den Audio-Uplink stumm).
        let nextMLine = lines[mLineIndex...].dropFirst().firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.endIndex

        // Payload -> Codec-Name NUR innerhalb der Video-Section.
        var codecByPayload: [String: String] = [:]
        for line in lines[mLineIndex..<nextMLine] where line.hasPrefix("a=rtpmap:") {
            let rest = line.dropFirst("a=rtpmap:".count)
            let parts = rest.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let pt = String(parts[0])
            let codec = parts[1].split(separator: "/").first.map(String.init) ?? ""
            codecByPayload[pt] = codec
        }

        let mParts = lines[mLineIndex].split(separator: " ")
        guard mParts.count > 3 else { return sdpText }
        let header = mParts.prefix(3).map(String.init)
        let payloads = mParts.dropFirst(3).map(String.init)
        let h264Payloads = payloads.filter { codecByPayload[$0]?.caseInsensitiveCompare("H264") == .orderedSame }
        guard !h264Payloads.isEmpty, h264Payloads.count != payloads.count else {
            // Kein H264 oder bereits nur H264 -> unverändert.
            return sdpText
        }
        let kept = Set(h264Payloads)
        lines[mLineIndex] = (header + h264Payloads).joined(separator: " ")

        // a=rtpmap/fmtp/rtcp-fb-Zeilen NUR in der Video-Section filtern.
        let prefixes = ["a=rtpmap:", "a=fmtp:", "a=rtcp-fb:"]
        var result: [String] = []
        for (index, line) in lines.enumerated() {
            if index >= mLineIndex && index < nextMLine {
                var keep = true
                for prefix in prefixes where line.hasPrefix(prefix) {
                    let pt = line.dropFirst(prefix.count).split(separator: " ").first.map(String.init) ?? ""
                    keep = kept.contains(pt)
                    break
                }
                if !keep { continue }
            }
            result.append(line)
        }
        return result.joined(separator: "\r\n")
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
            else if mcuActive, isPublisher {
                // P68w Basis-Muster (talk-iOS createPublisherPeerConnection):
                // In Audio-only-Calls wird von Anfang an eine Platzhalter-
                // Video-m-line (sendOnly ohne Track) verhandelt. Eine
                // NACHträglich per Renegotiation hinzugefügte m-line wird
                // vom MCU nie relayed (dokumentiert in talk-iOS) - das
                // Upgrade ersetzt nur den sender.track.
                let initT = RTCRtpTransceiverInit()
                initT.direction = .sendOnly
                initT.streamIds = ["link"]
                peer.addTransceiver(of: .video, init: initT)
            }
        }
        // Janus erwartet den "status"-DataChannel auf jeder MCU-Verbindung;
        // der Publisher ERSTELLT ihn (landet im Offer), Subscriber erhalten
        // ihn über didOpen aus dem Gegenangebot.
        if mcuActive, isPublisher {
            if let channel = peer.dataChannel(forLabel: "status", configuration: RTCDataChannelConfiguration()) {
                channel.delegate = self
                statusChannels[key] = channel
                CallDebugLog.log("CallSession", "status channel created key=\(key.prefix(12))")
            }
        }
        peers[key] = peer
        return peer
    }

    // MARK: - Status-Kanal (MCU-Medienzustand)

    fileprivate func registerStatusChannel(key: String, channel: RTCDataChannel) {
        statusChannels[key] = channel
        channel.delegate = self
        CallDebugLog.log("CallSession", "status channel opened key=\(key.prefix(12))")
        timingLog("status channel open")
        if channel.readyState == .open {
            sendInitialStatus()
            flushPendingStatus()
        }
    }

    /// Meldet dem MCU den aktuellen Medienzustand. Ohne diese Meldungen
    /// bleibt der Publisher-Uplink am MCU stumm - das ist der Grund, warum
    /// ausgehendes Audio/Video nicht ankam (Android-Pendant sendet sie
    /// ebenfalls).
    private func sendInitialStatus() {
        guard mcuActive else { return }
        // TALK-STANDARD (wie NCCallController.sendMediaState): initial
        // "audioOn" nach dem Publisher-Connect, sonst bleibt der Uplink
        // am MCU stumm.
        sendStatusMessage(localAudio?.isEnabled == false ? "audioOff" : "audioOn")
        sendStatusMessage((localVideo != nil && localVideo?.isEnabled == true) ? "videoOn" : "videoOff")
        timingLog("audioOn sent")
    }

    private func sendStatusMessage(_ type: String) {
        guard mcuActive else { return }
        var sent = false
        for (_, channel) in statusChannels where channel.readyState == .open {
            let payload = ["type": type]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            channel.sendData(RTCDataBuffer(data: data, isBinary: false))
            sent = true
        }
        if sent {
            CallDebugLog.log("CallSession", "status message sent: \(type)")
            return
        }
        // P68g: Status-Queue - solange der Status-Kanal noch nicht offen
        // ist, gehen Mute-/Video-Presses sonst still verloren (wirkt
        // "träge"/wirkungslos). Beim Kanal-Open wird nachgereicht.
        if pendingStatus.last != type {
            pendingStatus.append(type)
            CallDebugLog.log("CallSession", "status message queued (channel not open): \(type)")
        }
    }

    private var pendingStatus: [String] = []

    private func flushPendingStatus() {
        guard !pendingStatus.isEmpty else { return }
        let queued = pendingStatus
        pendingStatus.removeAll()
        for type in queued {
            sendStatusMessage(type)
        }
    }

    private func publisherConstraints() -> RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "false"], optionalConstraints: nil)
    }

    private func receiveConstraints() -> RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"], optionalConstraints: nil)
    }

    /// Extrahiert die m=-Zeilen eines SDP (Typ + Port) - Port 0 bedeutet
    /// ABGELEHNT (z. B. MCU lehnt m=video ab).
    static func mediaLines(of sdp: String) -> [String] {
        sdp.components(separatedBy: "\r\n")
            .filter { $0.hasPrefix("m=") }
            .map { line in
                let parts = line.split(separator: " ")
                guard parts.count >= 2, let first = parts.first else { return "?" }
                return "\(String(first.dropFirst(2))):\(parts[1])"
            }
    }

    /// Video-Codec-Zeilen (m=video + a=rtpmap) für die Diagnose.
    static func videoCodecLines(of sdp: String) -> String {
        sdp.components(separatedBy: "\r\n")
            .filter { $0.hasPrefix("m=video") || $0.hasPrefix("a=rtpmap") }
            .joined(separator: " | ")
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

    // MARK: - Publisher-Diagnose (outbound RTP)

    /// Loggt die outbound-rtp-Statistik des Publishers mehrfach nach dem
    /// Verbindungsaufbau. Steigen bytesSent/packetsSent, fließen unsere
    /// Medien zum MCU; bleiben sie 0, liegt das Problem in der lokalen
    /// Capture-Kette.
    fileprivate func logPublisherStats() {
        guard mcuActive, let peer = peers[ownSessionId] else { return }
        let delays: [Double] = [3, 10]
        for delay in delays {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.peers[self.ownSessionId] != nil else { return }
                self.dumpOutboundStats(peer: peer, tag: "t+\(Int(delay))s")
            }
        }
    }

    private func dumpOutboundStats(peer: RTCPeerConnection, tag: String) {
        // Async-API verwenden: Der Callback-Overload lieferte auf diesem
        // WebRTC-Build IMMER einen leeren Report. Bis zu 3 Versuche.
        Task { [weak self] in
            await self?.fetchStats(peer: peer, attempt: 0, tag: tag)
        }
    }

    private func fetchStats(peer: RTCPeerConnection, attempt: Int, tag: String) async {
        // P68f: Callback-API statt der Async-Variante - letztere lieferte
        // auf diesem WebRTC-Build IMMER einen leeren Report (stat
        // types=[]), sodass nie sichtbar war, ob Video-Frames fließen.
        let report = await withCheckedContinuation { cont in
            peer.statistics { report in
                cont.resume(returning: report)
            }
        }
        let values = report.statistics.values
        // Leerer Report = API quirk: einmal kurz warten und erneut probieren.
        if values.isEmpty, attempt < 2 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await fetchStats(peer: peer, attempt: attempt + 1, tag: tag)
            return
        }
        let outbound = values
            .filter { ($0.values["type"] as? String) == "outbound-rtp" }
            .sorted { (($0.values["kind"] as? String) ?? "") < (($1.values["kind"] as? String) ?? "") }
        if outbound.isEmpty {
            let types = values.compactMap { $0.values["type"] as? String }
            let kindMap = Dictionary(grouping: types, by: { $0 }).mapValues { $0.count }
            CallDebugLog.log("CallSession", "publisher outbound-rtp [\(tag)]: none; stat types=[\(kindMap.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: ","))]")
        }
        for stat in outbound {
            let media = stat.values["mediaType"] as? String
                ?? stat.values["kind"] as? String ?? "?"
            let bytes = stat.values["bytesSent"] as? NSNumber ?? 0
            let packets = stat.values["packetsSent"] as? NSNumber ?? 0
            CallDebugLog.log("CallSession", "publisher outbound-rtp [\(media)] bytesSent=\(bytes) packetsSent=\(packets) [\(tag)]")
        }
    }
}

extension CallSession: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        CallDebugLog.log("CallSession", "status channel state \(dataChannel.label): \(dataChannel.readyState.rawValue)")
        if dataChannel.readyState == .open {
            sendInitialStatus()
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        if !buffer.isBinary, let payload = String(data: buffer.data, encoding: .utf8) {
            CallDebugLog.log("CallSession", "status channel recv \(dataChannel.label): \(payload.prefix(120))")
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {}
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
            // Outbound-RTP-Statistik (bytesSent/packetsSent) nach 3 s und
            // 10 s loggen - beweist im Log, ob Medien tatsächlich zum MCU
            // fließen.
            owner?.logPublisherStats()
        }
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        CallDebugLog.log("PeerObserver", "session=\(session) ICE gathering -> \(Self.stateName(newState))")
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        CallDebugLog.log("PeerObserver", "session=\(session) connection -> \(Self.stateName(newState))")
    }
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        CallDebugLog.log("PeerObserver", "data channel opened key=\(key.prefix(12)) label=\(dataChannel.label)")
        owner?.registerStatusChannel(key: key, channel: dataChannel)
    }

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
