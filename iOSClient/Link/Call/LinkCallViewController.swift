// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// In-call UI for "Link": full-screen remote video with a local self-view and mute/video/hangup
// controls. Driven by CallSession. Mirrors android link/call/CallActivity.

import UIKit
import AVFoundation
import WebRTC

final class LinkCallViewController: UIViewController, CallSessionCallbacks {
    private let account: LinkAccount
    private let token: String
    private let title_: String

    private var session: CallSession?
    private let localView = RTCMTLVideoView()
    private var localTrack: RTCVideoTrack?

    /// Kachel eines Remote-Streams (Fokus-Modus); Key = session|roomType.
    private final class StreamTile {
        let container = UIView()
        let videoView = RTCMTLVideoView()
        let session: String
        let roomType: String
        var track: RTCVideoTrack?

        init(session: String, roomType: String) {
            self.session = session
            self.roomType = roomType
            container.backgroundColor = .black
            container.layer.cornerRadius = 10
            container.clipsToBounds = true
            videoView.videoContentMode = .scaleAspectFill
            videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            videoView.frame = container.bounds
            container.addSubview(videoView)
        }
    }

    private var tiles: [String: StreamTile] = [:]
    /// Manuell fokussierte Kachel (Tap auf eine kleine Kachel).
    private var manualFocusKey: String?
    /// Vom aktiven Sprecher fokussierte Kachel.
    private var speakerFocusKey: String?
    /// Zuletzt angezeigte Fokus-Kachel.
    private var lastFocusedKey: String?

    /// Layout-Modus: Raster (Standard) oder Fokus/Speaker.
    private enum CallLayoutMode {
        case raster, focus
    }
    private var layoutMode: CallLayoutMode = .raster
    /// Eigenansicht nur bei aktivem Video (Kamera an + Track vorhanden).
    private var shouldShowLocalView: Bool { isVideoOn && localTrack != nil }
    /// Container für das lokale Bild, damit es im Raster als Kachel
    /// eingereiht werden kann.
    private lazy var localContainer: UIView = {
        let c = UIView()
        c.backgroundColor = .black
        c.layer.cornerRadius = 10
        c.clipsToBounds = true
        return c
    }()
    private var localViewPanOrigin: CGPoint = .zero

    private var isMuted = false
    private var isVideoOn: Bool

    private var attachedSession: CallSession?
    private var isSpeakerOn = false
    private let silent: Bool

    init(account: LinkAccount, token: String, title: String, withVideo: Bool = true, silent: Bool = false, session: CallSession? = nil) {
        self.account = account
        self.token = token
        self.title_ = title
        self.isVideoOn = withVideo
        self.silent = silent
        self.attachedSession = session
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // P68e: Der App-Vollscreen ist (ab jetzt) präsentiert - das
        // LinkView-Banner ("Zum Anruf wechseln") bleibt damit aus.
        LinkVoIPManager.shared.noteCallUIPresented()
        view.backgroundColor = .black
        setupVideoViews()
        setupControls()
        setupParticipantsOverlay()

        if let attached = attachedSession {
            self.session = attached
            attached.reattach(callbacks: self)
            applyInitialControlStates()
        } else if let active = LinkVoIPManager.shared.activeSession,
                  active.token == token,
                  !active.hasEnded {
            // P68c: Läuft bereits eine Session zu DIESEM Raum (z. B. über
            // CallKit angenommen und nun "In Souvera öffnen"/Video bzw.
            // "Teilnehmen" getippt), wird sie ÜBERNOMMEN statt beendet.
            // Der alte Fallback killte den laufenden Call (endActiveCall)
            // und startete eine frische Session - Audio fiel aus, Video-
            // Zustand ging verloren, der Anruf kam nur "verspätet" an.
            self.session = active
            active.reattach(callbacks: self)
            applyInitialControlStates()
            CallDebugLog.log("CallVC", "took over active session token=\(token.prefix(8)) (no restart)")
        } else {
            // Nur EINE Call-Session gleichzeitig: eine noch laufende Session
            // sauber beenden, bevor eine neue startet (sonst entstehen
            // parallele eigene Sessions im Raum -> MCU-Chaos, kein Medien-
            // Fluss, "Gelöschter Benutzer"-Geister).
            LinkVoIPManager.shared.endActiveCall()
            CallDebugLog.log("CallVC", "no active session - starting fresh call token=\(token.prefix(8))")
            let session = CallSession(account: account, token: token, callbacks: self, withVideo: isVideoOn, silent: silent)
            self.session = session
            // Shared State registrieren: endActiveCall/leaveCall/Fullscreen-
            // Guard gelten damit auch für diese (bisher private) Session -
            // das verhindert "Gelöschter Benutzer"-Geister und den
            // Incoming-Fullscreen über dem eigenen Call.
            LinkVoIPManager.shared.noteSessionStarted(session, token: token, title: title_, withVideo: isVideoOn)
            applyMuteStateOnly()
            // Berechtigungs-Flow VOR dem Call-Start; die Dialoge erscheinen
            // nur beim allerersten Mal (Talk-Standard). Ohne Mikrofon kein
            // Call; ohne Kamera läuft der Video-Call audio-only weiter.
            Task {
                let audioOk = await CallPermissions.ensureAudio(allowPrompt: UIApplication.shared.applicationState == .active)
                if !audioOk {
                    CallDebugLog.log("CallVC", "microphone denied - aborting call")
                    await MainActor.run { self.showPermissionDeniedHint() }
                    return
                }
                if isVideoOn {
                    let cameraOk = await CallPermissions.ensureCamera()
                    CallDebugLog.log("CallVC", "camera permission granted=\(cameraOk)")
                    if !cameraOk {
                        await MainActor.run {
                            self.isVideoOn = false
                            self.videoButton?.setImage(UIImage(systemName: "video.slash.fill"), for: .normal)
                            self.participantsLabel.text = NSLocalizedString("_link_camera_denied_", comment: "")
                        }
                    }
                }
                if session.hasEnded { return }
                // Erst jetzt Video einschalten (Kamera-Rechte liegen vor):
                // erzeugt den Track lazy bzw. bleibt bei Audio-only aus.
                session.setVideoEnabled(isVideoOn)
                session.start()
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(externalEnd), name: .linkEndCall, object: nil)
        loadParticipants()
        // Display während des Calls wach halten (kein Sperrbildschirm, bis
        // aufgelegt wird) - Apple-Standard für Call-UIs.
        UIApplication.shared.isIdleTimerDisabled = true
        participantRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.loadParticipants()
        }
    }

    /// Initiale Button-Zustände für re-attached Sessions (Rückkehr aus dem
    /// Chat): der tatsächliche Session-Zustand gewinnt - ein im Call
    /// aktiviertes/deaktiviertes Video oder Mute wird NICHT zurückgesetzt.
    private func applyInitialControlStates() {
        if let session {
            isVideoOn = session.isVideoEnabled
            videoButton?.setImage(UIImage(systemName: isVideoOn ? "video.fill" : "video.slash.fill"), for: .normal)
            isMuted = session.isMutedLocally
            muteButton?.setImage(UIImage(systemName: isMuted ? "mic.slash.fill" : "mic.fill"), for: .normal)
        }
    }

    /// Nur der Mute-Zustand (frische Sessions: der Video-Zustand folgt nach
    /// dem Berechtigungs-Flow).
    private func applyMuteStateOnly() {
        videoButton?.setImage(UIImage(systemName: isVideoOn ? "video.fill" : "video.slash.fill"), for: .normal)
        if silent {
            isMuted = true
            session?.setMuted(true)
            muteButton?.setImage(UIImage(systemName: "mic.slash.fill"), for: .normal)
        }
    }

    private func showPermissionDeniedHint() {
        let alert = UIAlertController(
            title: NSLocalizedString("_link_mic_denied_", comment: ""),
            message: NSLocalizedString("_link_mic_denied_hint_", comment: ""),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("_ok_", comment: ""), style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    // MARK: - Participants overlay

    private let participantsLabel = UILabel()

    private var participantRefreshTimer: Timer?

    private func setupParticipantsOverlay() {
        participantsLabel.translatesAutoresizingMaskIntoConstraints = false
        participantsLabel.textColor = .white
        participantsLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        participantsLabel.numberOfLines = 0
        participantsLabel.textAlignment = .center
        view.addSubview(participantsLabel)
        NSLayoutConstraint.activate([
            participantsLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            participantsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            participantsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])
    }

    private func loadParticipants() {
        Task {
            let api = LinkOcsApi(account: account)
            let names = await api.callParticipantNames(token: token)
            await MainActor.run {
                participantsLabel.text = names.isEmpty ? "" : names.joined(separator: ", ")
            }
        }
    }

    private func setupVideoViews() {
        localView.videoContentMode = .scaleAspectFill
        localView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        localView.frame = localContainer.bounds
        localContainer.addSubview(localView)
        view.addSubview(localContainer)

        // Kamera-Wechsel als kleiner Overlay-Button IN der Eigenansicht
        // (unten rechts) - die untere Leiste bleibt für Mute/Video/Speaker/
        // Auflegen frei.
        let camButton = UIButton(type: .system)
        camButton.setImage(UIImage(systemName: "camera.rotate"), for: .normal)
        camButton.tintColor = .white
        camButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        camButton.layer.cornerRadius = 18
        camButton.translatesAutoresizingMaskIntoConstraints = false
        camButton.addTarget(self, action: #selector(switchCamera), for: .touchUpInside)
        camButton.isHidden = true
        switchCameraButton = camButton
        localContainer.addSubview(camButton)
        NSLayoutConstraint.activate([
            camButton.trailingAnchor.constraint(equalTo: localContainer.trailingAnchor, constant: -4),
            camButton.bottomAnchor.constraint(equalTo: localContainer.bottomAnchor, constant: -4),
            camButton.widthAnchor.constraint(equalToConstant: 36),
            camButton.heightAnchor.constraint(equalToConstant: 36)
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(localViewPanned(_:)))
        localContainer.addGestureRecognizer(pan)
        localContainer.isUserInteractionEnabled = true
    }

    @objc private func localViewPanned(_ gesture: UIPanGestureRecognizer) {
        // Nur im Floating-Modus (1:1/Fokus) verschiebbar; im Raster bleibt
        // die Eigenansicht als feste Kachel.
        guard layoutMode != .raster || tiles.count <= 1 else { return }
        switch gesture.state {
        case .began:
            localViewPanOrigin = localContainer.frame.origin
        case .changed:
            let t = gesture.translation(in: view)
            var f = localContainer.frame
            f.origin = CGPoint(x: localViewPanOrigin.x + t.x, y: localViewPanOrigin.y + t.y)
            localContainer.frame = f
        case .ended, .cancelled:
            snapLocalViewToCorner()
        default:
            break
        }
    }

    /// Schnappt die Eigenansicht in die nächstgelegene Ecke.
    private func snapLocalViewToCorner() {
        let size = localContainer.frame.size
        let inset: CGFloat = 16
        let safeTop = view.safeAreaInsets.top
        let safeBottom = view.safeAreaInsets.bottom
        let minX = inset
        let maxX = view.bounds.width - size.width - inset
        let minY = safeTop + inset
        let maxY = view.bounds.height - safeBottom - 120 - size.height - inset
        var target = localContainer.frame.origin
        if target.x < (minX + maxX) / 2 { target.x = minX } else { target.x = maxX }
        if target.y < (minY + maxY) / 2 { target.y = minY } else { target.y = maxY }
        UIView.animate(withDuration: 0.2) {
            self.localContainer.frame.origin = target
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutTiles()
    }

    /// Fullscreen-Call rotiert mit der Display-Orientierung (Hochkant/
    /// Landscape), unabhängig von der SwiftUI-Host-Umgebung.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        [.portrait, .landscapeLeft, .landscapeRight]
    }

    override var shouldAutorotate: Bool { true }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // P68e: Vollscreen verlassen (Call beendet/verlassen) - Banner
        // wieder erlauben, Presenter kann erneut präsentieren.
        LinkVoIPManager.shared.noteCallUIDismissed()
    }

    /// Layout-Dispatcher: Raster (Standard) oder Fokus/Speaker.
    private func layoutTiles() {
        // Eigenansicht ausblenden, solange das Video nicht aktiv ist.
        localContainer.isHidden = !shouldShowLocalView
        // Screen-Share bleibt immer groß/vorn (Inhalte lesbar).
        if let _ = tiles.keys.sorted().first(where: { tiles[$0]?.roomType == "screen" }) {
            layoutFocus()
            return
        }
        if tiles.count == 1 {
            // 1:1: entfernter Teilnehmer groß, Eigenansicht floating.
            layoutFocus()
        } else if layoutMode == .raster {
            layoutRaster()
        } else {
            layoutFocus()
        }
    }

    /// Raster: alle Kacheln (remote + Eigenansicht) gleich groß.
    private func layoutRaster() {
        let width = view.bounds.width
        let safeTop = view.safeAreaInsets.top

        let remoteKeys = tiles.keys.sorted()
        let totalTiles = remoteKeys.count + (shouldShowLocalView ? 1 : 0)

        let columns: Int
        if totalTiles <= 1 { columns = 1 }
        else if totalTiles <= 4 { columns = 2 }
        else { columns = 3 }

        let gap: CGFloat = 8
        let margin: CGFloat = 8
        let availableWidth = width - margin * 2 - gap * CGFloat(columns - 1)
        let tileWidth = availableWidth / CGFloat(columns)
        let tileHeight = tileWidth * 1.4

        var index = 0
        var x = margin
        var y = safeTop + margin

        func place(_ container: UIView) {
            container.layer.cornerRadius = 10
            container.layer.borderWidth = 1.5
            container.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
            container.frame = CGRect(x: x, y: y, width: tileWidth, height: tileHeight)
            index += 1
            if index % columns == 0 {
                x = margin
                y += tileHeight + gap
            } else {
                x += tileWidth + gap
            }
        }

        for key in remoteKeys {
            guard let tile = tiles[key] else { continue }
            place(tile.container)
        }
        if shouldShowLocalView {
            place(localContainer)
        }
    }

    /// Fokus/Speaker: große Fokus-Kachel + kleine Kacheln unten.
    private func layoutFocus() {
        let width = view.bounds.width
        let height = view.bounds.height
        let safeTop = view.safeAreaInsets.top
        let safeBottom = view.safeAreaInsets.bottom

        let focusKey = resolveFocusKey()
        guard let focusKey, let focusTile = tiles[focusKey] else {
            layoutRaster()
            return
        }

        let stripKeys = tiles.keys
            .filter { $0 != focusKey && tiles[$0]?.roomType != "screen" }
            .sorted()

        focusTile.container.layer.cornerRadius = stripKeys.isEmpty ? 0 : 12
        focusTile.container.layer.borderWidth = 0

        if stripKeys.isEmpty {
            // 1:1: Fokus füllt den gesamten Bildschirm.
            focusTile.container.frame = CGRect(x: 0, y: 0, width: width, height: height)
        } else {
            let tileWidth: CGFloat = 96
            let tileHeight: CGFloat = 136
            let gap: CGFloat = 8
            let controlsHeight: CGFloat = 92
            // Klarer Abstand zwischen der großen Fokus-/Speaker-Kachel und den
            // darunter liegenden Mini-Kacheln (vorher überlappten sie fast).
            let stripSpacing: CGFloat = 24
            let stripTopY = height - safeBottom - controlsHeight - tileHeight - gap
            let focusHeight = max(height * 0.4, min(height * 0.66, stripTopY - safeTop - stripSpacing))
            focusTile.container.frame = CGRect(x: 0, y: safeTop, width: width, height: focusHeight)

            var x: CGFloat = 12
            for key in stripKeys {
                guard let tile = tiles[key] else { continue }
                tile.container.layer.cornerRadius = 10
                tile.container.layer.borderWidth = 1.5
                tile.container.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
                tile.container.frame = CGRect(
                    x: x,
                    y: stripTopY,
                    width: tileWidth,
                    height: tileHeight
                )
                x += tileWidth + gap
            }
        }
        lastFocusedKey = focusKey
        layoutLocalFloating()
    }

    /// Eigenansicht als kleines Floating-Tile (oben rechts).
    private func layoutLocalFloating() {
        let size = CGSize(width: 110, height: 160)
        localContainer.layer.cornerRadius = 8
        localContainer.layer.borderWidth = 0
        localContainer.frame = CGRect(
            x: view.bounds.width - size.width - 16,
            y: view.safeAreaInsets.top + 16,
            width: size.width,
            height: size.height
        )
    }

    /// Vorrang: Screen-Share > aktiver Sprecher > manueller Fokus > zuletzt
    /// fokussierte Kachel > erste Kachel.
    private func resolveFocusKey() -> String? {
        if let screenKey = tiles.keys.sorted().first(where: { tiles[$0]?.roomType == "screen" }) {
            return screenKey
        }
        if let speaker = speakerFocusKey, tiles[speaker] != nil {
            return speaker
        }
        if let manual = manualFocusKey, tiles[manual] != nil {
            return manual
        }
        if let last = lastFocusedKey, tiles[last] != nil {
            return last
        }
        return tiles.keys.sorted().first
    }

    private static func key(session: String, roomType: String) -> String {
        "\(session)|\(roomType)"
    }

    private func setupControls() {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32)
        ])

        muteButton = controlButton(systemName: "mic.fill", action: #selector(toggleMute))
        videoButton = controlButton(systemName: "video.slash.fill", action: #selector(toggleVideo))
        speakerButton = controlButton(systemName: "speaker.wave.2.fill", action: #selector(toggleSpeaker))
        hangupButton = controlButton(systemName: "phone.down.fill", tint: .systemRed, action: #selector(hangup))
        let moreButton = moreMenuButton()

        // Kern-Buttons + "…"-Menü (Layout/Chat) in EINER Reihe; Kamera-Wechsel
        // liegt in der Eigenansicht. So bleiben Mute UND Auflegen sichtbar.
        stack.addArrangedSubview(muteButton!)
        stack.addArrangedSubview(videoButton!)
        stack.addArrangedSubview(speakerButton!)
        stack.addArrangedSubview(moreButton)
        stack.addArrangedSubview(hangupButton!)
    }

    /// "…"-Menü (Layout-Toggle + Chat) als Button in der unteren Leiste.
    private func moreMenuButton() -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        button.layer.cornerRadius = 28
        button.widthAnchor.constraint(equalToConstant: 56).isActive = true
        button.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let layoutAction = UIAction(
            title: NSLocalizedString("_link_call_toggle_layout_", comment: ""),
            image: UIImage(systemName: layoutMode == .raster ? "square.grid.2x2" : "person.crop.rectangle")
        ) { [weak self] _ in self?.toggleLayout() }
        let chatAction = UIAction(
            title: NSLocalizedString("_link_call_chat_", comment: ""),
            image: UIImage(systemName: "bubble.left.and.bubble.right.fill")
        ) { [weak self] _ in self?.openChat() }
        button.menu = UIMenu(options: .displayInline, children: [layoutAction, chatAction])
        button.showsMenuAsPrimaryAction = true
        return button
    }

    private var muteButton: UIButton?
    private var videoButton: UIButton?
    private var speakerButton: UIButton?
    private var switchCameraButton: UIButton?
    private var hangupButton: UIButton?

    private func controlButton(systemName: String, tint: UIColor = .white, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = tint
        button.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        button.layer.cornerRadius = 28
        button.widthAnchor.constraint(equalToConstant: 56).isActive = true
        button.heightAnchor.constraint(equalToConstant: 56).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func toggleMute() {
        isMuted.toggle()
        session?.setMuted(isMuted)
        muteButton?.setImage(UIImage(systemName: isMuted ? "mic.slash.fill" : "mic.fill"), for: .normal)
        CallDebugLog.log("CallVC", "mute \(isMuted ? "on" : "off")")
    }

    @objc private func toggleVideo() {
        isVideoOn.toggle()
        session?.setVideoEnabled(isVideoOn)
        videoButton?.setImage(UIImage(systemName: isVideoOn ? "video.fill" : "video.slash.fill"), for: .normal)
        switchCameraButton?.isHidden = !isVideoOn
        CallDebugLog.log("CallVC", "video \(isVideoOn ? "on" : "off")")
    }

    @objc private func switchCamera() {
        session?.switchCamera()
        CallDebugLog.log("CallVC", "switch camera")
    }

    @objc private func toggleLayout() {
        layoutMode = (layoutMode == .raster) ? .focus : .raster
        CallDebugLog.log("CallVC", "layout \(layoutMode == .raster ? "raster" : "focus")")
        layoutTiles()
    }

    @objc private func toggleSpeaker() {
        isSpeakerOn.toggle()
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        do {
            try audioSession.setCategory(.playAndRecord, with: [.allowBluetooth, .allowBluetoothA2DP])
            // Talk-Standard: Hörmuschel = voiceChat, Lautsprecher = videoChat.
            try audioSession.setMode(isSpeakerOn ? .videoChat : .voiceChat)
            try audioSession.setActive(true)
            try audioSession.overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
        } catch {
            CallDebugLog.log("CallVC", "audio route error \(error.localizedDescription)")
        }
        audioSession.unlockForConfiguration()
        speakerButton?.setImage(UIImage(systemName: isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill"), for: .normal)
        CallDebugLog.log("CallVC", "speaker \(isSpeakerOn ? "on" : "off")")
    }

    /// Hands the running call over to the shared manager and opens the chat.
    @objc private func openChat() {
        guard let session else { return }
        LinkVoIPManager.shared.takeOverCall(session, token: token, title: title_, withVideo: isVideoOn)
        NotificationCenter.default.post(name: .openLinkRoom, object: ["token": token, "title": title_])
        dismiss(animated: true)
    }

    @objc private func hangup() {
        session?.hangup()
    }

    @objc private func externalEnd() {
        session?.hangup()
    }

    private func closeCallUI() {
        guard !isBeingDismissed else { return }
        NotificationCenter.default.post(name: .linkCallUIClose, object: nil)
        dismiss(animated: true)
    }

    // MARK: - CallSessionCallbacks

    func onVideoPermissionDenied() {
        DispatchQueue.main.async {
            self.videoButton?.setImage(UIImage(systemName: "video.slash.fill"), for: .normal)
            self.participantsLabel.text = NSLocalizedString("_link_camera_denied_", comment: "")
        }
    }

    func onLocalVideo(track: RTCVideoTrack) {
        DispatchQueue.main.async {
            self.localTrack = track
            if !self.isVideoOn {
                track.isEnabled = false
            } else {
                track.add(self.localView)
                self.switchCameraButton?.isHidden = false
            }
        }
    }

    func onRemoteVideo(session: String, roomType: String, track: RTCVideoTrack) {
        DispatchQueue.main.async {
            let key = Self.key(session: session, roomType: roomType)
            let tile: StreamTile
            if let existing = self.tiles[key] {
                tile = existing
            } else {
                tile = StreamTile(session: session, roomType: roomType)
                let tap = UITapGestureRecognizer(target: self, action: #selector(self.tileTapped(_:)))
                tile.container.addGestureRecognizer(tap)
                tile.container.isUserInteractionEnabled = true
                self.tiles[key] = tile
                self.view.insertSubview(tile.container, at: 0)
            }
            tile.track = track
            track.add(tile.videoView)
            CallDebugLog.log("CallVC", "remote tile added \(key.prefix(14))")
            self.layoutTiles()
        }
    }

    func onRemoteVideoRemoved(session: String, roomType: String) {
        DispatchQueue.main.async {
            let key = Self.key(session: session, roomType: roomType)
            self.tiles.removeValue(forKey: key)?.container.removeFromSuperview()
            if self.manualFocusKey == key { self.manualFocusKey = nil }
            if self.speakerFocusKey == key { self.speakerFocusKey = nil }
            if self.lastFocusedKey == key { self.lastFocusedKey = nil }
            CallDebugLog.log("CallVC", "remote tile removed \(key.prefix(14))")
            self.layoutTiles()
        }
    }

    func onActiveSpeaker(session: String, roomType: String) {
        DispatchQueue.main.async {
            self.speakerFocusKey = Self.key(session: session, roomType: roomType)
            self.layoutTiles()
        }
    }

    @objc private func tileTapped(_ gesture: UITapGestureRecognizer) {
        guard let container = gesture.view,
              let tile = self.tiles.values.first(where: { $0.container === container }) else { return }
        let key = Self.key(session: tile.session, roomType: tile.roomType)
        manualFocusKey = key
        CallDebugLog.log("CallVC", "manual focus \(key.prefix(14))")
        layoutTiles()
    }

    func onEnded() {
        DispatchQueue.main.async {
            self.closeCallUI()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        participantRefreshTimer?.invalidate()
        participantRefreshTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        // Safety net: never leave the call audio session active.
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        try? audioSession.setActive(false)
        audioSession.unlockForConfiguration()
    }
}
