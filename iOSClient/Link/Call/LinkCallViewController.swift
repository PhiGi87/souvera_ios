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
    private let remoteView = RTCMTLVideoView()
    private let localView = RTCMTLVideoView()
    private var remoteTrack: RTCVideoTrack?
    private var localTrack: RTCVideoTrack?

    private var isMuted = false
    private var isVideoOn: Bool

    private var attachedSession: CallSession?
    private var isSpeakerOn = false

    init(account: LinkAccount, token: String, title: String, withVideo: Bool = true, session: CallSession? = nil) {
        self.account = account
        self.token = token
        self.title_ = title
        self.isVideoOn = withVideo
        self.attachedSession = session
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupVideoViews()
        setupControls()
        setupParticipantsOverlay()

        if let attached = attachedSession {
            self.session = attached
            attached.reattach(callbacks: self)
        } else {
            let session = CallSession(account: account, token: token, callbacks: self, withVideo: isVideoOn)
            self.session = session
            session.start()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(externalEnd), name: .linkEndCall, object: nil)
        loadParticipants()
    }

    // MARK: - Participants overlay

    private let participantsLabel = UILabel()

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
        remoteView.videoContentMode = .scaleAspectFill
        remoteView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(remoteView)
        NSLayoutConstraint.activate([
            remoteView.topAnchor.constraint(equalTo: view.topAnchor),
            remoteView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            remoteView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            remoteView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        localView.videoContentMode = .scaleAspectFill
        localView.translatesAutoresizingMaskIntoConstraints = false
        localView.layer.cornerRadius = 8
        localView.clipsToBounds = true
        view.addSubview(localView)
        NSLayoutConstraint.activate([
            localView.widthAnchor.constraint(equalToConstant: 110),
            localView.heightAnchor.constraint(equalToConstant: 160),
            localView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            localView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16)
        ])
    }

    private func setupControls() {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32)
        ])

        muteButton = controlButton(systemName: "mic.fill", action: #selector(toggleMute))
        videoButton = controlButton(systemName: "video.slash.fill", action: #selector(toggleVideo))
        speakerButton = controlButton(systemName: "speaker.wave.2.fill", action: #selector(toggleSpeaker))
        chatButton = controlButton(systemName: "bubble.left.and.bubble.right.fill", action: #selector(openChat))
        hangupButton = controlButton(systemName: "phone.down.fill", tint: .systemRed, action: #selector(hangup))

        stack.addArrangedSubview(muteButton!)
        stack.addArrangedSubview(speakerButton!)
        stack.addArrangedSubview(videoButton!)
        stack.addArrangedSubview(chatButton!)
        stack.addArrangedSubview(hangupButton!)
    }

    private var muteButton: UIButton?
    private var videoButton: UIButton?
    private var speakerButton: UIButton?
    private var chatButton: UIButton?
    private var hangupButton: UIButton?

    private func controlButton(systemName: String, tint: UIColor = .white, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = tint
        button.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        button.layer.cornerRadius = 30
        button.widthAnchor.constraint(equalToConstant: 60).isActive = true
        button.heightAnchor.constraint(equalToConstant: 60).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func toggleMute() {
        isMuted.toggle()
        session?.setMuted(isMuted)
        muteButton?.setImage(UIImage(systemName: isMuted ? "mic.slash.fill" : "mic.fill"), for: .normal)
    }

    @objc private func toggleVideo() {
        isVideoOn.toggle()
        session?.setVideoEnabled(isVideoOn)
        videoButton?.setImage(UIImage(systemName: isVideoOn ? "video.fill" : "video.slash.fill"), for: .normal)
    }

    @objc private func toggleSpeaker() {
        isSpeakerOn.toggle()
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        do {
            try audioSession.setCategory(.playAndRecord, with: [.allowBluetooth, .allowBluetoothA2DP])
            try audioSession.setMode(.videoChat)
            try audioSession.setActive(true)
            try audioSession.overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
        } catch {
            CallDebugLog.log("CallVC", "audio route error \(error.localizedDescription)")
        }
        audioSession.unlockForConfiguration()
        speakerButton?.setImage(UIImage(systemName: isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill"), for: .normal)
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

    // MARK: - CallSessionCallbacks

    func onLocalVideo(track: RTCVideoTrack) {
        DispatchQueue.main.async {
            self.localTrack = track
            if !self.isVideoOn {
                track.isEnabled = false
            } else {
                track.add(self.localView)
            }
        }
    }

    func onRemoteVideo(track: RTCVideoTrack) {
        DispatchQueue.main.async {
            self.remoteTrack = track
            track.add(self.remoteView)
        }
    }

    func onEnded() {
        DispatchQueue.main.async {
            self.dismiss(animated: true)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
