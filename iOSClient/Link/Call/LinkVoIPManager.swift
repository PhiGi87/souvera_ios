// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PushKit + CallKit for "Link" (Nextcloud Talk) VoIP calls.
//
// - Generates a PushKit VoIP token and registers it Nextcloud-push-v2-compatibly with the Souvera
//   push proxy (https://push.souvera.eu). The proxy automatically targets the VoIP APNs topic
//   `eu.souvera.app.voip` for call notifications; the device only supplies the VoIP token
//   plus the existing device public key + signature that NCPushNotification already provisioned.
// - On an incoming VoIP push, decrypts the payload with the account's device private key (same E2E
//   material as normal notifications) and reports the call to CallKit so iOS rings even when the app
//   is suspended. Answering opens the in-app call UI.
//
// The exact dual-token (APNs + VoIP) registration contract is validated on-device against the live
// proxy; failures are logged and never crash the app.

import Foundation
import PushKit
import CallKit
import AVFoundation
import NextcloudKit

final class LinkVoIPManager: NSObject {
    static let shared = LinkVoIPManager()

    private let global = NCGlobal.shared
    private var voipRegistry: PKPushRegistry?
    private let provider: CXProvider
    private let callController = CXCallController()

    /// The current PushKit VoIP token as a lowercase hex string (never logged in full).
    private(set) var voipToken: String = ""
    /// Call being offered via CallKit right now (set when reporting, consumed
    /// on answer or cleared on decline).
    private(set) var pendingIncomingCall: (token: String, title: String, hasVideo: Bool)?
    /// The currently running outgoing call (owned by this manager so it can
    /// outlive the call UI when the user switches to the chat).
    private(set) var activeSession: CallSession?
    private(set) var activeCallInfo: (token: String, title: String, withVideo: Bool)?
    /// Room token of the call currently reported to CallKit, keyed by CallKit UUID.
    private var activeCalls: [UUID: String] = [:]

    private override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Call once at startup to begin receiving VoIP pushes.
    func register() {
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        voipRegistry = registry
    }

    // MARK: - Outgoing calls (shared session)

    /// Starts an outgoing call; the session stays alive independently of the
    /// call view controller so the UI can be re-attached later.
    func startOutgoingCall(account: LinkAccount, token: String, title: String, withVideo: Bool, callbacks: CallSessionCallbacks?) {
        let session = CallSession(account: account, token: token, callbacks: callbacks, withVideo: withVideo)
        activeSession = session
        activeCallInfo = (token, title, withVideo)
        session.start()
        NotificationCenter.default.post(name: .linkCallStateChanged, object: nil)
    }

    /// Starts an INCOMING call session (after the user accepted): same
    /// lifecycle as outgoing calls so banners and CallKit stay in sync.
    @discardableResult
    func startIncomingCall(account: LinkAccount, token: String, title: String, withVideo: Bool) -> CallSession? {
        let session = CallSession(account: account, token: token, callbacks: nil, withVideo: withVideo)
        activeSession = session
        activeCallInfo = (token, title, withVideo)
        session.start()
        NotificationCenter.default.post(name: .linkCallStateChanged, object: nil)
        return session
    }

    /// Adopts a session started by a call view controller so the call keeps
    /// running while the user switches to the chat.
    func takeOverCall(_ session: CallSession, token: String, title: String, withVideo: Bool) {
        activeSession = session
        activeCallInfo = (token, title, withVideo)
        session.callbacks = nil
        NotificationCenter.default.post(name: .linkCallStateChanged, object: nil)
    }

    /// Called when the session reports it ended - clears the active state so
    /// banners disappear everywhere.
    func callSessionDidEnd(_ session: CallSession) {
        guard activeSession === session else { return }
        activeSession = nil
        activeCallInfo = nil
        NotificationCenter.default.post(name: .linkCallStateChanged, object: nil)
    }

    /// Ends the active call from any surface (banner, CarPlay, ...).
    func endActiveCall() {
        activeSession?.hangup()
    }

    /// The call was ended from inside the app (hangup button): close the
    /// matching CallKit transaction so no dead call remains.
    func callEndedByApp() {
        for uuid in activeCalls.keys {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        }
        activeCalls.removeAll()
    }

#if DEBUG
    /// Simulates an incoming Talk call for UI testing (CallKit does not
    /// deliver to the iOS simulator). Long-press the "+" in the Link tab.
    func simulateIncomingCall(token: String, title: String, hasVideo: Bool) {
        reportIncomingCall(roomToken: token, displayName: title, hasVideo: hasVideo) {}
        CallDebugLog.log("LinkVoIPManager", "simulated incoming call token=\(token) title=\(title) video=\(hasVideo)")
    }
#endif

    // MARK: - Push-v2 VoIP registration

    private func subscribeVoipToken() {
        let tokenPreview = voipToken.isEmpty ? "empty" : "len \(voipToken.count)"
        guard !voipToken.isEmpty else {
            nkLog(tag: global.logTagPN, emoji: .error, message: "Link VoIP registration skipped: no PushKit token (\(tokenPreview))")
            return
        }
        let proxyServerUrl = NCBrandOptions.shared.pushNotificationServerProxy
        guard !proxyServerUrl.isEmpty,
              let pushTokenHash = NCEndToEndEncryption.shared().createSHA512(voipToken) else {
            nkLog(tag: global.logTagPN, emoji: .error, message: "Link VoIP registration skipped: no proxy URL or token hash")
            return
        }

        Task {
            let preferences = NCPreferences()
            for tblAccount in await NCManageDatabase.shared.getAllTableAccountAsync() {
                let account = tblAccount.account
                let urlBase = tblAccount.urlBase
                // Reuse the device key pair NCPushNotification already provisioned for this account.
                guard let publicKeyData = preferences.getPushNotificationPublicKey(account: account),
                      let devicePublicKey = String(data: publicKeyData, encoding: .utf8) else {
                    nkLog(tag: global.logTagPN, emoji: .error, message: "Link VoIP: no device public key for \(urlBase); regular push must register first")
                    continue
                }

                nkLog(tag: global.logTagPN, emoji: .start, message: "Registering Link VoIP push for \(urlBase) via proxy \(proxyServerUrl)")
                let responsePN = await NextcloudKit.shared.subscribingPushNotificationAsync(serverUrl: urlBase,
                                                                                            pushTokenHash: pushTokenHash,
                                                                                            devicePublicKey: devicePublicKey,
                                                                                            proxyServerUrl: proxyServerUrl,
                                                                                            account: account)
                guard responsePN.error == .success,
                      let deviceIdentifier = responsePN.deviceIdentifier,
                      let signature = responsePN.signature,
                      let subscribingPublicKey = responsePN.publicKey else {
                    nkLog(tag: global.logTagPN, emoji: .error, message: "Link VoIP Nextcloud registration FAILED for \(urlBase), status \(responsePN.error.errorCode)")
                    continue
                }
                nkLog(tag: global.logTagPN, emoji: .success, message: "Link VoIP Nextcloud registration OK for \(urlBase) (proxyServer=\(proxyServerUrl))")

                let userAgent = String(format: "%@  (Strict VoIP)", NCBrandOptions.shared.getUserAgent())
                let options = NKRequestOptions(customUserAgent: userAgent)
                let combined = SouveraPushRegistrar.combinedToken(
                    normal: NCPreferences().deviceTokenPushNotification,
                    voip: voipToken
                )
                let responseProxy = await NextcloudKit.shared.subscribingPushProxyAsync(proxyServerUrl: proxyServerUrl,
                                                                                        pushToken: combined,
                                                                                        deviceIdentifier: deviceIdentifier,
                                                                                        signature: signature,
                                                                                        publicKey: subscribingPublicKey,
                                                                                        account: account,
                                                                                        options: options)
                if responseProxy.error == .success {
                    nkLog(tag: global.logTagPN, emoji: .success, message: "Link VoIP proxy registration OK at \(proxyServerUrl)")
                } else {
                    nkLog(tag: global.logTagPN, emoji: .error, message: "Link VoIP proxy registration FAILED at \(proxyServerUrl), status \(responseProxy.error.errorCode)")
                }
            }
        }
    }

    // MARK: - Incoming call → CallKit

    private func reportIncomingCall(roomToken: String, displayName: String, hasVideo: Bool, completion: @escaping () -> Void) {
        let uuid = UUID()
        activeCalls[uuid] = roomToken
        pendingIncomingCall = (roomToken, displayName, hasVideo)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: displayName)
        update.hasVideo = hasVideo
        update.localizedCallerName = displayName
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                nkLog(tag: self.global.logTagPN, emoji: .error, message: "Link CallKit report failed: \(error.localizedDescription)")
            }
            completion()
        }
    }

    /// Decrypts a VoIP payload with the account device private key and pulls out the call info.
    private func decryptCallPayload(_ payload: [AnyHashable: Any]) -> (roomToken: String, displayName: String, hasVideo: Bool)? {
        guard let message = payload["subject"] as? String else { return nil }
        for tblAccount in NCManageDatabase.shared.getAllTableAccount() {
            guard let privateKey = NCPreferences().getPushNotificationPrivateKey(account: tblAccount.account),
                  let decrypted = NCPushNotificationEncryption.shared().decryptPushNotification(message, withDevicePrivateKey: privateKey),
                  let data = decrypted.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // Für die Feld-Verifikation mit einem echten Anruf: komplettes
            // entschlüsseltes JSON loggen (keine Secrets).
            CallDebugLog.log("LinkVoIPManager", "decrypted call push: \(decrypted)")
            let rich = json["subjectRichParameters"] as? [String: Any]
            let callRich = rich?["call"] as? [String: Any]
            // Talk liefert den Raum-Token in objectId; aeltere/andere
            // Feldnamen werden toleriert.
            let roomToken = (json["objectId"] as? String)
                ?? (callRich?["id"] as? String)
                ?? (json["id"] as? String)
                ?? (json["nid"].map { "\($0)" } ?? "")
            let displayName = (callRich?["name"] as? String)
                ?? (json["subject"] as? String)
                ?? NSLocalizedString("_link_incoming_call_", comment: "")
            let type = (json["type"] as? String) ?? ""
            let hasVideo = type.contains("video")
            return (roomToken, displayName, hasVideo)
        }
        return nil
    }
}

// MARK: - PKPushRegistryDelegate

extension LinkVoIPManager: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        voipToken = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        nkLog(tag: global.logTagPN, emoji: .success, message: "PushKit VoIP token received, length \(voipToken.count)")
        subscribeVoipToken()
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        nkLog(tag: global.logTagPN, emoji: .info, message: "PushKit VoIP token invalidated")
        voipToken = ""
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        // iOS REQUIRES reporting a call for every VoIP push, else the app is killed. Always report.
        if let call = decryptCallPayload(payload.dictionaryPayload) {
            reportIncomingCall(roomToken: call.roomToken, displayName: call.displayName, hasVideo: call.hasVideo, completion: completion)
        } else {
            reportIncomingCall(roomToken: "", displayName: NSLocalizedString("_link_incoming_call_", comment: ""), hasVideo: true, completion: completion)
        }
    }
}

// MARK: - CXProviderDelegate

extension LinkVoIPManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        activeCalls.removeAll()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let roomToken = activeCalls[action.callUUID] ?? ""
        activeCalls[action.callUUID] = nil
        action.fulfill()
        if !roomToken.isEmpty {
            let pending = pendingIncomingCall
            pendingIncomingCall = nil
            NotificationCenter.default.post(
                name: .linkAnswerCall,
                object: nil,
                userInfo: [
                    "token": roomToken,
                    "title": pending?.title ?? "",
                    "hasVideo": pending?.hasVideo ?? false
                ]
            )
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        activeCalls[action.callUUID] = nil
        pendingIncomingCall = nil
        action.fulfill()
        NotificationCenter.default.post(name: .linkEndCall, object: nil)
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {}
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}

extension Notification.Name {
    static let linkAnswerCall = Notification.Name("linkAnswerCall")
    static let linkEndCall = Notification.Name("linkEndCall")
}
