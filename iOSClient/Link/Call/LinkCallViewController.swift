// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// In-call UI for "Link": full-screen remote video with a local self-view and mute/video/hangup
// controls. Driven by CallSession. Mirrors android link/call/CallActivity.

import UIKit
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

    init(account: LinkAccount, token: String, title: String, withVideo: Bool = true) {
        self.account = account
        self.token = token
        self.title_ = title
        self.isVideoOn = withVideo
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupVideoViews()
        setupControls()

        let session = CallSession(account: account, token: token, callbacks: self)
        self.session = session
        session.start()

        NotificationCenter.default.addObserver(self, selector: #selector(externalEnd), name: .linkEndCall, object: nil)
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

        stack.addArrangedSubview(controlButton(systemName: "mic.slash.fill", action: #selector(toggleMute)))
        stack.addArrangedSubview(controlButton(systemName: "video.slash.fill", action: #selector(toggleVideo)))
        stack.addArrangedSubview(controlButton(systemName: "phone.down.fill", tint: .systemRed, action: #selector(hangup)))
    }

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
    }

    @objc private func toggleVideo() {
        isVideoOn.toggle()
        session?.setVideoEnabled(isVideoOn)
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
