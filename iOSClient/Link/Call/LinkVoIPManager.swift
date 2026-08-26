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
import WebRTC
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

    /// Registriert eine bereits laufende Session (z. B. die vom Call-VC
    /// privat erzeugte) im Shared State: Damit greifen endActiveCall,
    /// das "kein Fullscreen im eigenen Call"-Guard und die Geister-
    /// Bereinigung (leaveCall) für JEDE Session.
    func noteSessionStarted(_ session: CallSession, token: String, title: String, withVideo: Bool) {
        activeSession = session
        activeCallInfo = (token, title, withVideo)
        NotificationCenter.default.post(name: .linkCallStateChanged, object: nil)
    }

    /// true, solange ein eingehender Anruf über CallKit klingelt - der
    /// In-App-Fullscreen muss dann NICHT zusätzlich erscheinen (Dedup).
    var hasRingingCall: Bool {
        pendingIncomingCall != nil || !activeCalls.isEmpty
    }

    /// Starts an outgoing call; the session stays alive independently of the
    /// call view controller so the UI can be re-attached later.
    func startOutgoingCall(account: LinkAccount, token: String, title: String, withVideo: Bool, callbacks: CallSessionCallbacks?) {
        endActiveCall()
        let session = CallSession(account: account, token: token, callbacks: callbacks, withVideo: withVideo)
        activeSession = session
        activeCallInfo = (token, title, withVideo)
        session.start()
        NotificationCenter.default.post(name: .linkCallStateChanged, object: nil)
    }

    /// Meldet einen ausgehenden Call an CallKit (Talk-Standard: System-
    /// Integration, Hintergrund-Audio). AKTUELL DEAKTIVIERT: Der Report
    /// ohne `connectedAt` kann die Audio-Session dauerhaft blockieren
    /// (kein Ton in beide Richtungen) - erst nach sauberem Medien-Handshake
    /// wieder aktivieren.
    func reportOutgoingCall(token: String, title: String, withVideo: Bool) {
        guard Self.reportOutgoingToCallKit else {
            CallDebugLog.log("LinkVoIPManager", "outgoing CallKit report disabled (flag off)")
            return
        }
        let uuid = UUID()
        activeCalls[uuid] = token
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: title)
        update.hasVideo = withVideo
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
        CallDebugLog.log("LinkVoIPManager", "outgoing call reported to CallKit token=\(token)")
    }

    private static let reportOutgoingToCallKit = false

    /// Starts an INCOMING call session (after the user accepted): same
    /// lifecycle as outgoing calls so banners and CallKit stay in sync.
    /// Der Berechtigungs-Flow läuft vor dem Session-Start (einmalig, Dialoge
    /// nur beim ersten Mal); ohne Kamera-Recht startet der Video-Call
    /// audio-only.
    @discardableResult
    func startIncomingCall(account: LinkAccount, token: String, title: String, withVideo: Bool) -> CallSession? {
        // Nur EINE Call-Session gleichzeitig (Parallele-Session-Schutz).
        endActiveCall()
        // Session erst nach der Berechtigungs-Prüfung anlegen, damit ein
        // abgelehnter Kamera-Zugriff gar nicht erst einen Video-Track
        // erzeugt (audio-only statt kaputtem Capture).
        let session = CallSession(account: account, token: token, callbacks: nil, withVideo: withVideo, silent: false)
        activeSession = session
        activeCallInfo = (token, title, withVideo)
        NotificationCenter.default.post(name: .linkCallStateChanged, object: nil)
        Task {
            let allowPrompt = UIApplication.shared.applicationState == .active
            let audioOk = await CallPermissions.ensureAudio(allowPrompt: allowPrompt)
            CallDebugLog.log("LinkVoIPManager", "incoming call: microphone granted=\(audioOk)")
            if audioOk, withVideo {
                let cameraOk = await CallPermissions.ensureCamera(allowPrompt: allowPrompt)
                CallDebugLog.log("LinkVoIPManager", "incoming call: camera granted=\(cameraOk)")
                if cameraOk {
                    session.start()
                    return
                }
                // Kamera verweigert: Call ohne Video weiterführen.
                session.startAudioOnly()
                return
            }
            session.start()
        }
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
    /// Simulates an incoming Talk call for UI testing (CallKit cannot show
    /// incoming calls in the iOS simulator, so the app presents its own
    /// full-screen accept/decline overlay instead).
    func simulateIncomingCall(token: String, title: String, hasVideo: Bool) {
        CallDebugLog.log("LinkVoIPManager", "simulated incoming call token=\(token) title=\(title) video=\(hasVideo)")
        NotificationCenter.default.post(
            name: .linkSimulateIncomingCall,
            object: nil,
            userInfo: ["token": token, "title": title, "hasVideo": hasVideo]
        )
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
        // TALK-STANDARD (wie talk-ios NCKeyChainController.pushTokenSHA512):
        // Hash des KOMBINIERTEN Tokens ("normal voip") - genau der String,
        // den wir am Proxy als pushToken registrieren. Sonst kennt der
        // Proxy das Gerät nicht ("unknown device" -> Zeile wird gelöscht)
        // und der Call-Push kommt nie an.
        let combinedPushToken = SouveraPushRegistrar.combinedToken(
            normal: NCPreferences().deviceTokenPushNotification,
            voip: voipToken
        )
        guard !proxyServerUrl.isEmpty,
              let pushTokenHash = NCEndToEndEncryption.shared().createSHA512(combinedPushToken) else {
            nkLog(tag: global.logTagPN, emoji: .error, message: "Link VoIP registration skipped: no proxy URL or token hash")
            return
        }

        Task {
            let preferences = NCPreferences()
            // Token-Hygiene: hat der VoIP-Token gewechselt (Reinstall),
            // wird die alte Registrierung VOR der neuen abgemeldet -
            // keine Geräte-Leichen.
            let previousVoipToken = UserDefaults.standard.string(forKey: Self.voipTokenKey)
            if let previousVoipToken, previousVoipToken != voipToken,
               UserDefaults.standard.string(forKey: Self.voipDeviceIdentifierKey) != nil {
                let tblAccounts = await NCManageDatabase.shared.getAllTableAccountAsync()
                for tblAccount in tblAccounts {
                    await Self.unregisterVoipPush(baseUrl: tblAccount.urlBase, username: tblAccount.user)
                }
            }
            UserDefaults.standard.set(voipToken, forKey: Self.voipTokenKey)
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
                // KANAL-TRENNUNG mit ZWEI Servertoken: Die Server-Tabelle
                // dedupliziert Gerätezeilen pro (Benutzer, Session-Token).
                // Diese Registrierung läuft daher über die MAIL-Credential
                // Y (zweites NC-Login, eigener Token) - sonst würde sie die
                // Normal-Push-Zeile überschreiben und der Talk-Kanal fehlt.
                let talkUserAgent = "Mozilla/5.0 (iOS) Nextcloud-Talk v21.0.0 (Souvera Workspace)"
                let registration = await Self.registerTalkDevice(
                    account: account,
                    baseUrl: urlBase,
                    username: tblAccount.user,
                    pushTokenHash: pushTokenHash,
                    devicePublicKey: devicePublicKey,
                    proxyServerUrl: proxyServerUrl,
                    talkUserAgent: talkUserAgent
                )
                guard let registration,
                      let deviceIdentifier = registration.deviceIdentifier,
                      let signature = registration.signature,
                      let subscribingPublicKey = registration.publicKey else {
                    nkLog(tag: global.logTagPN, emoji: .error, message: "Link VoIP Nextcloud registration FAILED for \(urlBase)")
                    UserDefaults.standard.set("failed NC \(Date())", forKey: "SouveraPushRegStatusVoip")
                    SouveraLog.write("PushVoip", "NC registration FAILED \(urlBase)")
                    continue
                }
                nkLog(tag: global.logTagPN, emoji: .success, message: "Link VoIP Nextcloud registration OK for \(urlBase) (proxyServer=\(proxyServerUrl))")
                SouveraLog.write("PushVoip", "NC registration OK \(urlBase) (via mail credential)")
                // Für die Abmeldung beim Logout (P45a) die Gerätedaten merken.
                UserDefaults.standard.set(deviceIdentifier, forKey: Self.voipDeviceIdentifierKey)
                UserDefaults.standard.set(signature, forKey: Self.voipDeviceSignatureKey)
                UserDefaults.standard.set(subscribingPublicKey, forKey: Self.voipDevicePublicKeyKey)

                let combined = combinedPushToken
                // Tolerante Registrierung: 2xx = Erfolg (Proxy antwortet
                // mit leerem Body).
                let proxyOk = await SouveraPushRegistrar.registerAtProxy(proxyServerUrl: proxyServerUrl,
                                                                         pushToken: combined,
                                                                         deviceIdentifier: deviceIdentifier,
                                                                         signature: signature,
                                                                         publicKey: subscribingPublicKey)
                if proxyOk {
                    nkLog(tag: global.logTagPN, emoji: .success, message: "Link VoIP proxy registration OK at \(proxyServerUrl)")
                    UserDefaults.standard.set("ok \(Date())", forKey: "SouveraPushRegStatusVoip")
                    SouveraLog.write("PushVoip", "proxy registration OK \(proxyServerUrl)")
                } else {
                    nkLog(tag: global.logTagPN, emoji: .error, message: "Link VoIP proxy registration FAILED at \(proxyServerUrl)")
                    UserDefaults.standard.set("failed proxy \(Date())", forKey: "SouveraPushRegStatusVoip")
                    SouveraLog.write("PushVoip", "proxy registration FAILED \(proxyServerUrl)")
                }
            }
        }
    }

    private static let voipTokenKey = "souvera_voip_token"
    private static let voipDeviceIdentifierKey = "souvera_voip_device_identifier"
    private static let voipDeviceSignatureKey = "souvera_voip_device_signature"
    private static let voipDevicePublicKeyKey = "souvera_voip_device_public_key"

    /// Logout-Cleanup: Talk-Gerät am Proxy UND am Server abmelden
    /// (Talk-Muster unsubscribeAccount) - keine toten Zeilen mehr.
    static func unregisterVoipPush(baseUrl: String, username: String) async {
        let defaults = UserDefaults.standard
        let identifier = defaults.string(forKey: voipDeviceIdentifierKey)
        let signature = defaults.string(forKey: voipDeviceSignatureKey)
        let publicKey = defaults.string(forKey: voipDevicePublicKeyKey)
        let proxy = NCBrandOptions.shared.pushNotificationServerProxy
        if let identifier, let signature, let publicKey, !proxy.isEmpty {
            await SouveraPushRegistrar.unregisterAtProxy(proxyServerUrl: proxy,
                                                         deviceIdentifier: identifier,
                                                         signature: signature,
                                                         publicKey: publicKey)
        }
        // NC-Zeile (Talk, Token Y) entfernen - best effort.
        let manager = SouveraMailCredentialManager()
        if let mailAccount = await manager.ensureCombinedCredential() {
            await unregisterTalkDeviceOcs(baseUrl: baseUrl,
                                          username: username,
                                          ncPassword: mailAccount.mailPassword)
        }
        defaults.removeObject(forKey: voipDeviceIdentifierKey)
        defaults.removeObject(forKey: voipDeviceSignatureKey)
        defaults.removeObject(forKey: voipDevicePublicKeyKey)
        SouveraLog.write("PushVoip", "voip push unregistered")
    }

    /// Eigener OCS-DELETE `ocs/v2.php/apps/notifications/api/v2/push` mit
    /// der übergebenen NC-Credential (Y).
    private static func unregisterTalkDeviceOcs(baseUrl: String,
                                                username: String,
                                                ncPassword: String) async {
        let root = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(root)/ocs/v2.php/apps/notifications/api/v2/push") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        let raw = "\(username):\(ncPassword)"
        req.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        req.setValue("Mozilla/5.0 (iOS) Nextcloud-Talk v21.0.0 (Souvera Workspace)", forHTTPHeaderField: "User-Agent")
        let result = try? await URLSession.shared.data(for: req)
        let status = (result?.1 as? HTTPURLResponse)?.statusCode ?? -1
        SouveraLog.write("PushVoip", "NC talk-device unregister http \(status)")
    }

    /// Registriert das Talk/VoIP-Gerät am Nextcloud-Server mit der
    /// MAIL-Credential (Y): eigener Session-Token -> EIGENE Gerätezeile mit
    /// apptype=talk. Ohne Mail-Credential: Fallback auf die normale
    /// NextcloudKit-Session (Zeile bleibt dann nextcloud - Mail/Chat-Push
    /// bleibt funktionsfähig, Call-Push fehlt).
    private static func registerTalkDevice(
        account: String,
        baseUrl: String,
        username: String,
        pushTokenHash: String,
        devicePublicKey: String,
        proxyServerUrl: String,
        talkUserAgent: String
    ) async -> (deviceIdentifier: String?, signature: String?, publicKey: String?)? {
        let manager = SouveraMailCredentialManager()
        var mailAccount = await manager.ensureCombinedCredential()
        if let mailAccount {
            let attempt = await registerTalkDeviceOcs(
                baseUrl: baseUrl,
                username: username,
                ncPassword: mailAccount.mailPassword,
                pushTokenHash: pushTokenHash,
                devicePublicKey: devicePublicKey,
                proxyServerUrl: proxyServerUrl,
                talkUserAgent: talkUserAgent
            )
            if let attempt { return attempt }
            // 401/Fehler: Credential prüfen/erneuern und EINMAL wiederholen.
            SouveraLog.write("PushVoip", "NC registration with mail credential failed - validating/renewing")
            if let renewed = await manager.renewCredential(), renewed.mailPassword != mailAccount.mailPassword {
                if let retry = await registerTalkDeviceOcs(
                    baseUrl: baseUrl,
                    username: username,
                    ncPassword: renewed.mailPassword,
                    pushTokenHash: pushTokenHash,
                    devicePublicKey: devicePublicKey,
                    proxyServerUrl: proxyServerUrl,
                    talkUserAgent: talkUserAgent
                ) {
                    return retry
                }
            }
            SouveraLog.write("PushVoip", "NC registration via mail credential unavailable - falling back to NextcloudKit session")
        }
        // Fallback: bisheriger Weg über die NextcloudKit-Session (X).
        let responsePN = await NextcloudKit.shared.subscribingPushNotificationAsync(serverUrl: baseUrl,
                                                                                    pushTokenHash: pushTokenHash,
                                                                                    devicePublicKey: devicePublicKey,
                                                                                    proxyServerUrl: proxyServerUrl,
                                                                                    account: account,
                                                                                    options: NKRequestOptions(customUserAgent: talkUserAgent))
        guard responsePN.error == .success else { return nil }
        return (responsePN.deviceIdentifier, responsePN.signature, responsePN.publicKey)
    }

    /// Eigener OCS-POST `ocs/v2.php/apps/notifications/api/v2/push` mit
    /// Talk-User-Agent und der übergebenen NC-Credential (Y).
    private static func registerTalkDeviceOcs(
        baseUrl: String,
        username: String,
        ncPassword: String,
        pushTokenHash: String,
        devicePublicKey: String,
        proxyServerUrl: String,
        talkUserAgent: String
    ) async -> (deviceIdentifier: String?, signature: String?, publicKey: String?)? {
        let root = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(root)/ocs/v2.php/apps/notifications/api/v2/push") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let raw = "\(username):\(ncPassword)"
        req.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        req.setValue(talkUserAgent, forHTTPHeaderField: "User-Agent")

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let params = [
            "pushTokenHash": pushTokenHash,
            "devicePublicKey": devicePublicKey,
            "proxyServer": proxyServerUrl
        ]
        let form = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
        req.httpBody = form.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            SouveraLog.write("PushVoip", "NC talk-device registration http \(status)")
            guard (200..<300).contains(status),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ocs = json["ocs"] as? [String: Any],
                  let ocsData = ocs["data"] as? [String: Any] else { return nil }
            return (
                ocsData["deviceIdentifier"] as? String,
                ocsData["signature"] as? String,
                ocsData["publicKey"] as? String
            )
        } catch {
            SouveraLog.write("PushVoip", "NC talk-device registration failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Incoming call → CallKit

    /// Talk-Muster (maxRingingTime): unbeantwortete Push-Calls nach
    /// 45 s automatisch beenden - sonst klingelt das Gerät ewig.
    private var ringingTimeoutTimer: Timer?

    private func reportIncomingCall(roomToken: String, displayName: String, hasVideo: Bool, completion: @escaping () -> Void) {
        let uuid = UUID()
        activeCalls[uuid] = roomToken
        pendingIncomingCall = (roomToken, displayName, hasVideo)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: displayName)
        update.hasVideo = hasVideo
        update.localizedCallerName = displayName
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                nkLog(tag: self?.global.logTagPN ?? NCGlobal.shared.logTagPN, emoji: .error, message: "Link CallKit report failed: \(error.localizedDescription)")
            } else {
                self?.startRingingTimeout(for: uuid)
            }
            completion()
        }
    }

    private func startRingingTimeout(for uuid: UUID) {
        DispatchQueue.main.async {
            self.ringingTimeoutTimer?.invalidate()
            self.ringingTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
                guard let self, self.pendingIncomingCall != nil else { return }
                CallDebugLog.log("LinkVoIPManager", "ringing timeout - ending unanswered call")
                self.pendingIncomingCall = nil
                self.activeCalls[uuid] = nil
                self.provider.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)
                NotificationCenter.default.post(name: .linkEndCall, object: nil)
            }
        }
    }

    private func cancelRingingTimeout() {
        ringingTimeoutTimer?.invalidate()
        ringingTimeoutTimer = nil
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
        cancelRingingTimeout()
        let roomToken = activeCalls[action.callUUID] ?? ""
        activeCalls[action.callUUID] = nil
        action.fulfill()
        if !roomToken.isEmpty {
            let pending = pendingIncomingCall
            pendingIncomingCall = nil
            // Session ZENTRAL hier starten - funktioniert auch bei
            // gesperrtem Gerät/Hintergrund (keine UI-Abhängigkeit). Der
            // AppDelegate-Observer präsentiert danach nur noch die UI.
            if let account = LinkAccount.active() {
                _ = startIncomingCall(
                    account: account,
                    token: roomToken,
                    title: pending?.title ?? "",
                    withVideo: pending?.hasVideo ?? false
                )
            }
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
        cancelRingingTimeout()
        activeCalls[action.callUUID] = nil
        pendingIncomingCall = nil
        action.fulfill()
        // Auflegen beendet die aktive Session IMMER - auch wenn die
        // Call-UI nie präsentiert werden konnte (gesperrtes Gerät).
        endActiveCall()
        NotificationCenter.default.post(name: .linkEndCall, object: nil)
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        CallDebugLog.log("LinkVoIPManager", "CallKit didActivate audioSession")
        CallSession.activateCallAudioSession()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        CallDebugLog.log("LinkVoIPManager", "CallKit didDeactivate audioSession")
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.setActive(false)
        session.unlockForConfiguration()
    }
}

extension Notification.Name {
    static let linkAnswerCall = Notification.Name("linkAnswerCall")
    static let linkEndCall = Notification.Name("linkEndCall")
    /// Die Call-UI wurde beendet: SwiftUI muss die fullScreenCover-Items
    /// leeren, sonst bleibt ein weisser Cover zurück.
    static let linkCallUIClose = Notification.Name("linkCallUIClose")
    /// Räume wurden außerhalb des Link-Tabs geändert (z. B. Kalender-Channel).
    static let linkRoomsChanged = Notification.Name("linkRoomsChanged")
    /// Simulierter eingehender Anruf (DEBUG, Simulator).
    static let linkSimulateIncomingCall = Notification.Name("linkSimulateIncomingCall")
}
