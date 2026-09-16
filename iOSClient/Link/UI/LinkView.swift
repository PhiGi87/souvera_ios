// SPDX-FileCopyrightText: 2026 Souvera / Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// SwiftUI surface for "Link" (Nextcloud Talk): conversation list + live chat. Mirrors the android
// link/ui Compose screens (ConversationListScreen, ChatScreen) but idiomatic SwiftUI.

import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

/// Root Link screen; switches between the conversation list and an open chat.
struct LinkView: View {
    @StateObject private var viewModel = LinkViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Landscape-Split (Raumliste links, Chat rechts) - Geometrie-basiert,
    /// gilt für iPhone, iPad und Mac (siehe GeometryReader im body).
    @State private var landscapeLayout = false
    @State private var callContext: CallContext?
    /// Lobby-Verwaltung (Fullscreen): Raum mit aktiver Lobby.
    @State private var lobbyManagementRoom: LinkConversation?
    /// Online-Status-Button (Run 15.09.): Status-Picker-Sheet.
    @State private var showUserStatus = false
    @State private var showCallBanner = false
    @State private var returnToCall = false
    @State private var showCreateChannel = false
    @State private var channelName = ""
    @State private var showAddParticipant = false
    @State private var startCallRequest: CallStartRequest?
    @State private var showParticipants = false
    @State private var settingsRoom: LinkConversation?
    @State private var searchActive = false
    @State private var searchQuery = ""
#if DEBUG
    @State private var simulatedIncoming: SimulatedCall?
#endif

    struct CallStartRequest: Identifiable {
        let token: String
        let title: String
        let withVideo: Bool
        var id: String { "\(token)|\(withVideo)" }
    }

    struct CallContext: Identifiable {
        let token: String
        let title: String
        let withVideo: Bool
        let silent: Bool
        var id: String { "\(token)|\(withVideo)|\(silent)" }
    }

        var body: some View {
        NavigationStack {
            // Landscape-Erkennung über Geometrie (Breite > Höhe) - wie in
            // MailView; Size-Classes sind auf iPad/iPhone unzuverlässig.
            GeometryReader { geo in
                content
                    .souveraOfflineBanner()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onAppear { updateLandscapeLayout(geo.size) }
                    .onChange(of: geo.size) { _, newSize in
                        updateLandscapeLayout(newSize)
                    }
            }
            // Souvera-Modul-Header (Run 15.09.): eigene Navbar - iOS 26
            // "Liquid Glass" flattet toolbarBackground-Verlaeufe und tintet
            // Buttons. Header 1:1 wie Mehr/Dateien (Verlauf + weisse Pills
            // mit dunklen Icons); System-Navigationbar komplett versteckt.
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                moduleHeader
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Foreground (Run 15.09.): Status + Presence automatisch
            // auffrischen - NICHT erst nach Klick auf den Status-Button.
            if phase == .active {
                viewModel.loadUserStatuses()
                Task { @MainActor in
                    await viewModel.refreshOwnStatus()
                }
            }
        }
        .onChange(of: viewModel.route) { _, _ in
            populateHeaderBridge()
        }
        .onChange(of: viewModel.currentRoom?.hasCall) { _, _ in
            populateHeaderBridge()
        }
        .onChange(of: viewModel.currentRoom?.lobbyState) { _, _ in
            populateHeaderBridge()
        }
        .onAppear {
            viewModel.start()
            viewModel.reconnectSignalingIfNeeded()
            viewModel.startRoomPolling()
            viewModel.loadUserStatuses()
            // Run 15.09.: eigener Status FRISCH vom Server (der DB-Stand
            // wird nur bei App-Start gepflegt - der Button blieb sonst
            // stehen, bis man ihn anklickte).
            let dbStatus = NCManageDatabase.shared.getActiveTableAccount()?.userStatusStatus
            viewModel.ownStatus = dbStatus
            Task { @MainActor in
                await viewModel.refreshOwnStatus()
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                viewModel.loadUserStatuses()
            }
            // Ein von außen angeforderter Raum wird nur geöffnet, wenn der
            // Nutzer nicht bereits in einem Chat navigiert (sonst würde die
            // Route mitten in der Bedienung überschrieben).
            if let pending = LinkViewModel.pendingOpenRoom, case .home = viewModel.route {
                LinkViewModel.pendingOpenRoom = nil
                viewModel.openConversation(token: pending.token, title: pending.title)
            }
            Task { @MainActor in
                await viewModel.refreshOwnStatus()
            }
        }
        .onDisappear {
            // Tab verlassen: Signaling trennen, damit Talk Push-Notifications
            // nicht länger unterdrückt.
            viewModel.disconnectSignaling()
            viewModel.stopRoomPolling()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                viewModel.disconnectSignaling()
                viewModel.stopRoomPolling()
            case .active:
                viewModel.reconnectSignalingIfNeeded()
                viewModel.startRoomPolling()
            @unknown default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .linkCallStateChanged)) { _ in
            // P68e: Banner nur, wenn KEIN App-Call-Vollscreen offen ist -
            // der Nutzer landet nach "In Souvera öffnen" direkt im
            // Vollscreen statt im "Zum Anruf wechseln"-Zwischenzustand.
            showCallBanner = LinkVoIPManager.shared.activeCallInfo != nil
                && !LinkVoIPManager.shared.isCallUIPresented
        }
        .onReceive(NotificationCenter.default.publisher(for: .linkCallUIClose)) { _ in
            // Wichtig: die Cover-Items leeren, sonst bleibt nach dem Auflegen
            // ein weisser Cover-Bildschirm zurück.
            callContext = nil
            returnToCall = false
        }
#if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .linkSimulateIncomingCall)) { notification in
            guard let token = notification.userInfo?["token"] as? String else { return }
            let title = (notification.userInfo?["title"] as? String) ?? NSLocalizedString("_link_incoming_call_", comment: "")
            let hasVideo = (notification.userInfo?["hasVideo"] as? Bool) ?? false
            simulatedIncoming = SimulatedCall(token: token, title: title, hasVideo: hasVideo)
        }
#endif
        .overlay(alignment: .top) {
            if showCallBanner, let info = LinkVoIPManager.shared.activeCallInfo {
                activeCallBanner(title: info.title)
            }
        }
        .overlay(alignment: .bottom) {
            if let feedback = viewModel.actionFeedback {
                HStack(spacing: 8) {
                    Image(systemName: feedback.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(feedback.success ? .green : .red)
                    Text(feedback.message).font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: viewModel.actionFeedback) { _, feedback in
            guard feedback != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                viewModel.actionFeedback = nil
            }
        }
        .fullScreenCover(item: $callContext) { context in
            if let account = LinkAccount.active() {
                LinkCallViewControllerWrapper(
                    account: account,
                    token: context.token,
                    title: context.title,
                    withVideo: context.withVideo,
                    silent: context.silent
                )
                .ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $returnToCall) {
            if let info = LinkVoIPManager.shared.activeCallInfo,
               let session = LinkVoIPManager.shared.activeSession,
               let account = LinkAccount.active() {
                LinkCallViewControllerWrapper(
                    account: account,
                    token: info.token,
                    title: info.title,
                    withVideo: info.withVideo,
                    session: session
                )
                .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showParticipants) {
            LinkParticipantsSheet(viewModel: viewModel)
        }
        .sheet(item: $settingsRoom) { room in
            LinkRoomSettingsSheet(viewModel: viewModel, room: room, onLobbyChanged: {
                // Frisches Raum-Objekt: der Lobby-Toggle zeigt beim
                // Wieder-Oeffnen den Server-Stand (Run-Feedback 15.09.).
                if let fresh = viewModel.currentRoom, fresh.token == room.token {
                    settingsRoom = fresh
                }
            })
        }
        .fullScreenCover(item: $lobbyManagementRoom) { lobbyRoom in
            LinkLobbyManagementView(viewModel: viewModel, room: lobbyRoom)
        }
        .sheet(isPresented: $showUserStatus, onDismiss: {
            // Status-Picker geschlossen: eigenen Status frisch vom Server
            // holen (der Picker schreibt die DB in seinem onDisappear -
            // der Server ist die Wahrheit).
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                await viewModel.refreshOwnStatus()
            }
        }) {
            if let account = NCManageDatabase.shared.getActiveTableAccount()?.account {
                NCUserStatusView(account: account, controller: nil)
            }
        }
        .overlay {
            if let request = startCallRequest {
                CallStartOverlay(
                    title: request.title,
                    withVideo: request.withVideo,
                    onStart: { silent in
                        callContext = CallContext(
                            token: request.token,
                            title: request.title,
                            withVideo: request.withVideo,
                            silent: silent
                        )
                        startCallRequest = nil
                    },
                    onCancel: { startCallRequest = nil }
                )
            }
        }
        .alert(NSLocalizedString("_link_create_channel_", comment: ""), isPresented: $showCreateChannel) {
            TextField(NSLocalizedString("_link_channel_name_", comment: ""), text: $channelName)
            Button(NSLocalizedString("_link_create_channel_", comment: "")) {
                viewModel.createChannel(name: channelName)
            }
            Button(NSLocalizedString("_cancel_", comment: ""), role: .cancel) {}
        }
#if DEBUG
        .fullScreenCover(item: $simulatedIncoming) { call in
            IncomingCallOverlayView(
                title: call.title,
                hasVideo: call.hasVideo,
                onAccept: {
                    simulatedIncoming = nil
                    guard let account = LinkAccount.active() else { return }
                    _ = LinkVoIPManager.shared.startIncomingCall(
                        account: account,
                        token: call.token,
                        title: call.title,
                        withVideo: call.hasVideo
                    )
                    returnToCall = true
                },
                onDecline: {
                    simulatedIncoming = nil
                }
            )
        }
#endif
    }

#if DEBUG
    private struct SimulatedCall: Identifiable {
        let token: String
        let title: String
        let hasVideo: Bool
        var id: String { token }
    }
#endif

    /// Call-Button mit pulsierendem grünem Kreis-Hintergrund: ein im Raum
    /// laufender Call soll optisch sofort herausstechen (Run-Feedback
    /// 11.09., "Button einfach nur schwarz"). Bei Reduce Motion nur ein
    /// sanfter Opacity-Hinweis statt Scale-Puls.
    private struct LinkPulsingCallButton: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                // iOS 17: symbolEffect(.pulse) pulsiert das Icon OHNE
                // Layout-Animation (der fruehere Frame-Wechsel liess den
                // Toolbar-Button wackeln, Run-Feedback 11.09.) + statischer
                // Halo, dessen Opacity atmet (render-only).
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.18))
                        .frame(width: 28, height: 28)
                    Image(systemName: "phone.fill.arrow.up.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                }
                .frame(width: 32, height: 32)
            }
            .accessibilityLabel(NSLocalizedString("_link_join_call_", comment: ""))
        }
    }

    /// Green banner shown while a call is running without its own UI.
    private func activeCallBanner(title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "phone.fill")
                .foregroundStyle(.white)
                .padding(6)
                .background(Circle().fill(Color.green))
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Button(NSLocalizedString("_link_call_return_", comment: "")) {
                returnToCall = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button(role: .destructive) {
                LinkVoIPManager.shared.endActiveCall()
            } label: {
                Image(systemName: "phone.down.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4)
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    /// Run 16.09.: Header-Aktionen als Bridge-Items — die hosting
    /// UIKit-Bar rendert sie (1:1 wie Mehr/Dateien, inkl. Flanking auf
    /// dem iPad). Route-abhängig: Home oder Chat-Raum.
    private func populateHeaderBridge() {
        guard let bridge = headerBridge else { return }
        if case let .chat(token, title) = viewModel.route {
            let roomTitle = viewModel.currentRoom?.displayName ?? title
            var trailing: [SouveraHeaderBridge.Item] = []
            var trailingMenus: [SouveraHeaderBridge.MenuGroup] = []

            trailingMenus.append(SouveraHeaderBridge.MenuGroup(
                id: "gear", icon: "gearshape",
                accessibilityLabel: NSLocalizedString("_link_room_settings_", comment: ""),
                entries: [
                    .init(id: "participants", title: NSLocalizedString("_link_participants_", comment: ""), icon: "person.2") {
                        viewModel.loadParticipants()
                        showParticipants = true
                    },
                    .init(id: "settings", title: NSLocalizedString("_link_room_settings_", comment: ""), icon: "gearshape") {
                        settingsRoom = viewModel.currentRoom
                    }
                ]
            ))
            if viewModel.currentRoom?.canManage == true,
               viewModel.currentRoom?.lobbyState == 1 {
                trailing.append(SouveraHeaderBridge.Item(
                    id: "lobby", icon: "clock.arrow.circlepath",
                    accessibilityLabel: NSLocalizedString("_link_lobby_toggle_", comment: "")
                ) {
                    lobbyManagementRoom = viewModel.currentRoom
                })
            }
            if viewModel.currentRoom?.hasCall == true {
                trailing.append(SouveraHeaderBridge.Item(
                    id: "call", icon: "phone.fill", isGreen: true,
                    accessibilityLabel: NSLocalizedString("_link_join_call_", comment: "")
                ) {
                    callContext = CallContext(token: token, title: roomTitle, withVideo: false, silent: false)
                })
            } else {
                trailing.append(SouveraHeaderBridge.Item(
                    id: "call", icon: "phone.fill", isGreen: true,
                    accessibilityLabel: NSLocalizedString("_link_start_call_", comment: "")
                ) {
                    startCallRequest = CallStartRequest(token: token, title: roomTitle, withVideo: false)
                })
            }

            bridge.title = roomTitle
            bridge.leadingItems = landscapeLayout ? [] : [
                .init(id: "back", icon: "chevron.backward",
                      accessibilityLabel: NSLocalizedString("_back_", comment: "")) {
                    viewModel.back()
                }
            ]
            bridge.trailingItems = trailing
            bridge.trailingMenus = trailingMenus
            bridge.leadingCustoms = []
            bridge.trailingCustoms = []
        } else {
            // Home: Suche links, Status + "+" rechts.
            bridge.title = NSLocalizedString("_link_", comment: "")
            bridge.leadingItems = [
                .init(id: "search", icon: "magnifyingglass",
                      accessibilityLabel: NSLocalizedString("_mail_search_", comment: "")) {
                    searchActive = true
                }
            ]
            bridge.trailingItems = []
            bridge.trailingMenus = []
            bridge.leadingCustoms = []
            bridge.trailingCustoms = [SouveraHeaderBridge.Custom(
                id: "status-plus", view: {
                    let host = UIHostingController(rootView:
                        HStack(spacing: 2) {
                            LinkOnlineStatusButton(status: viewModel.ownStatus) {
                                showUserStatus = true
                            }
                            Button {
                                channelName = ""
                                showCreateChannel = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(Color(red: 0.1, green: 0.1, blue: 0.1))
                                    .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.trailing, 4)
                    )
                    host.view.backgroundColor = .clear
                    return host.view
                }()
            )]
        }
    }

    private var navigationTitle: String {
        if case let .chat(token, title) = viewModel.route {
            // Echter Raumname, sobald der Raum geladen ist - der Titel aus
            // Deep-Links ist das Push-Subject ("Gast 1 (Gast) in Test Termin").
            if let room = viewModel.currentRoom, room.token == token, !room.displayName.isEmpty {
                return room.displayName
            }
            return title
        }
        return NSLocalizedString("_link_", comment: "")
    }

    @ViewBuilder
    private var content: some View {
        if landscapeLayout {
            landscapeSplitContent
        } else {
            switch viewModel.route {
            case .home:
                LinkConversationListView(
                    viewModel: viewModel,
                    searchActive: $searchActive,
                    searchQuery: $searchQuery
                ) { room in
                    callContext = CallContext(token: room.token, title: room.displayName, withVideo: false, silent: false)
                }
            case let .chat(token, title):
                LinkChatView(viewModel: viewModel, token: token, title: title)
            }
        }
    }

    private func updateLandscapeLayout(_ size: CGSize) {
        let isLandscape = size.width > size.height
        guard isLandscape != landscapeLayout else { return }
        landscapeLayout = isLandscape
        SouveraLog.write("LinkUI", "layout landscape=\(isLandscape) size=\(Int(size.width))x\(Int(size.height))")
    }

    /// Landscape-Split: Raum-Übersicht links (~1/3, max. 320 pt auf dem
    /// iPhone), der gewählte Chat rechts. KEIN Fokus-Leser bei Link - die
    /// rechte Spalte ist immer die klassische Chat-Ansicht (volle Höhe für
    /// Eingabezeile/Tastatur).
    private var landscapeSplitContent: some View {
        GeometryReader { geo in
            let roomWidth = min(320, max(260, geo.size.width / 3))
            HStack(spacing: 0) {
                LinkConversationListView(
                    viewModel: viewModel,
                    searchActive: $searchActive,
                    searchQuery: $searchQuery
                ) { room in
                    callContext = CallContext(token: room.token, title: room.displayName, withVideo: false, silent: false)
                }
                .frame(width: roomWidth)
                Divider()
                ZStack {
                    if case let .chat(token, title) = viewModel.route {
                        LinkChatView(viewModel: viewModel, token: token, title: title)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text(NSLocalizedString("_link_select_room_", comment: ""))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Hosts the UIKit in-call screen inside SwiftUI.
struct LinkCallViewControllerWrapper: UIViewControllerRepresentable {
    let account: LinkAccount
    let token: String
    let title: String
    let withVideo: Bool
    var silent: Bool = false
    var session: CallSession? = nil

    func makeUIViewController(context: Context) -> LinkCallViewController {
        LinkCallViewController(account: account, token: token, title: title, withVideo: withVideo, silent: silent, session: session)
    }

    func updateUIViewController(_ uiViewController: LinkCallViewController, context: Context) {}
}

/// Full-screen incoming call overlay (In-App-Call-UI im Vordergrund sowie
/// Simulator-Tests, wo CallKit keine eingehenden Anrufe zeigt): Annehmen
/// startet die Call-Session, Ablehnen schließt das Overlay.
/// App-weiter Zustand für die "Anruf minimiert"-Leiste: Der In-App-Call-
/// Fullscreen lässt sich minimieren, die Leiste zeigt den klingelnden Anruf
/// oben in der App (Annehmen/Ablehnen) - man kann weiterarbeiten. Zusätzlich
/// läuft der Anruf als Live Activity (Dynamic Island), von dort sind
/// Annehmen/Ablehnen per App-Intent möglich.
final class SouveraCallBannerModel: ObservableObject {
    static let shared = SouveraCallBannerModel()

    @Published var minimizedIncoming: LinkConversation? {
        didSet {
            if minimizedIncoming == nil {
                SouveraCallLiveActivity.end()
            }
        }
    }

    /// Vom Host (NCMainTabBarController) gesetzt: funktionieren unabhängig
    /// von der LinkView (auch wenn der Link-Tab nie geöffnet wurde).
    var onAccept: ((LinkConversation) -> Void)?
    var onDecline: ((LinkConversation) -> Void)?

    func accept(_ room: LinkConversation) {
        minimizedIncoming = nil
        onAccept?(room)
    }

    func decline(_ room: LinkConversation) {
        minimizedIncoming = nil
        onDecline?(room)
    }

    /// Aufruf aus den Live-Activity-App-Intents (Insel-Buttons).
    func acceptIfPresent() {
        if let room = minimizedIncoming { accept(room) }
    }

    func declineIfPresent() {
        if let room = minimizedIncoming { decline(room) }
    }

    private init() {}
}

/// Schmale Leiste oben in der App (über allen Tabs): klingelnder Anruf mit
/// Annehmen/Ablehnen, wenn der Fullscreen minimiert wurde.
struct SouveraIncomingCallBannerView: View {
    @ObservedObject private var model = SouveraCallBannerModel.shared
    /// Vertikaler Zieh-Offset für das Hoch-Swipe-Schließen.
    @GestureState private var dragY: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if let room = model.minimizedIncoming {
                HStack(spacing: 12) {
                    Image(systemName: "phone.ring.fill")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.green))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(room.displayName)
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(NSLocalizedString("_link_incoming_call_", comment: ""))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                    Button {
                        model.decline(room)
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.red))
                    }
                    .accessibilityLabel(NSLocalizedString("_link_decline_", comment: ""))
                    Button {
                        model.accept(room)
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.green))
                    }
                    .accessibilityLabel(NSLocalizedString("_link_accept_", comment: ""))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color(red: 0.12, green: 0.14, blue: 0.2)))
                .shadow(radius: 8)
                .padding(.horizontal, 12)
                // Notch-Abstand: etwas großzügiger, damit die Leiste nicht
                // hinter der Notch/Dynamic Island verschwindet.
                .padding(.top, 10)
                .padding(.bottom, 2)
                .transition(.move(edge: .top).combined(with: .opacity))
                .offset(y: dragY)
                .gesture(
                    DragGesture()
                        .updating($dragY) { value, state, _ in
                            state = min(0, value.translation.height)
                        }
                        .onEnded { value in
                            if value.translation.height < -40 {
                                model.minimizedIncoming = nil
                            }
                        }
                )
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.minimizedIncoming == nil)
    }
}

struct IncomingCallOverlayView: View {
    let title: String
    let hasVideo: Bool
    let onAccept: () -> Void
    let onDecline: () -> Void
    var onMinimize: () -> Void = {}

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.14, blue: 0.2), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                HStack {
                    Spacer()
                    Button(action: onMinimize) {
                        Image(systemName: "chevron.down")
                            .font(.title3.bold())
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.white.opacity(0.15)))
                    }
                    .accessibilityLabel(NSLocalizedString("_link_call_minimize_", comment: ""))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                Spacer()
                Text(NSLocalizedString("_link_incoming_call_", comment: ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if hasVideo {
                    Label(NSLocalizedString("_link_video_call_", comment: ""), systemImage: "video.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                HStack(spacing: 60) {
                    Button(action: onDecline) {
                        VStack(spacing: 6) {
                            Image(systemName: "phone.down.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(Circle().fill(Color.red))
                            Text(NSLocalizedString("_link_decline_", comment: ""))
                                .font(.caption)
                                .foregroundStyle(.white)
                        }
                    }
                    Button(action: onAccept) {
                        VStack(spacing: 6) {
                            Image(systemName: "phone.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(Circle().fill(Color.green))
                            Text(NSLocalizedString("_link_accept_", comment: ""))
                                .font(.caption)
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.bottom, 80)
            }
        }
    }
}

/// The list of conversations with a "start new conversation" search bar.
struct LinkConversationListView: View {
    @ObservedObject var viewModel: LinkViewModel
    @Binding var searchActive: Bool
    @Binding var searchQuery: String
    @State private var deleteRoom: LinkConversation?
    @State private var settingsRoom: LinkConversation?
    /// Startet einen direkten Audio-Call für den Raum (vom Eltern-View).
    var onCall: (LinkConversation) -> Void = { _ in }

#if DEBUG
    /// Simuliert einen eingehenden Anruf (CallKit liefert im Simulator nicht).
    private func simulateIncomingCall(video: Bool) {
        var token = "debug-token"
        var title = NSLocalizedString("_link_incoming_call_", comment: "")
        if case let .success(rooms) = viewModel.conversations, let first = rooms.first {
            token = first.token
            title = first.displayName
        }
        LinkVoIPManager.shared.simulateIncomingCall(token: token, title: title, hasVideo: video)
    }
#endif

    private func suggestionIcon(_ source: String) -> String {
        switch source {
        case "groups": return "person.3.fill"
        case "federated": return "globe"
        case "email_guest": return "envelope.badge.person.crop"
        default: return "person.crop.circle"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if searchActive {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(NSLocalizedString("_link_search_people_", comment: ""), text: $searchQuery)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    Button(NSLocalizedString("_cancel_", comment: "")) {
                        searchActive = false
                        searchQuery = ""
                        viewModel.searchUsers(query: "")
                    }
                }
                .padding(12)
                Divider()
            }
            List {
#if DEBUG
            Section(NSLocalizedString("_link_debug_", comment: "")) {
                Button {
                    simulateIncomingCall(video: false)
                } label: {
                    Label(NSLocalizedString("_link_debug_simulate_call_audio_", comment: ""), systemImage: "phone.fill")
                }
                Button {
                    simulateIncomingCall(video: true)
                } label: {
                    Label(NSLocalizedString("_link_debug_simulate_call_video_", comment: ""), systemImage: "video.fill")
                }
            }
#endif
            if !viewModel.userResults.isEmpty {
                Section(NSLocalizedString("_link_start_conversation_", comment: "")) {
                    ForEach(viewModel.userResults) { suggestion in
                        Button {
                            viewModel.startConversation(id: suggestion.id, source: suggestion.source, title: suggestion.label)
                            searchQuery = ""
                        } label: {
                            Label(suggestion.label, systemImage: suggestionIcon(suggestion.source))
                        }
                    }
                }
            }

            switch viewModel.conversations {
            case .loading:
                HStack { Spacer(); ProgressView(); Spacer() }
            case let .error(message):
                Text(message).foregroundStyle(.secondary)
            case let .success(rooms):
                if rooms.isEmpty {
                    Text(NSLocalizedString("_link_no_conversations_", comment: "")).foregroundStyle(.secondary)
                } else {
                    ForEach(rooms) { room in
                        Button {
                            viewModel.openConversation(token: room.token, title: room.displayName)
                        } label: {
                            LinkConversationRow(viewModel: viewModel, room: room)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if room.canManage {
                                Button {
                                    settingsRoom = room
                                } label: {
                                    Label(NSLocalizedString("_link_room_settings_", comment: ""), systemImage: "gearshape")
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                onCall(room)
                            } label: {
                                Label(NSLocalizedString("_link_swipe_call_", comment: ""), systemImage: "phone.fill")
                            }
                            .tint(.green)
                        }
                        .swipeActions(edge: .trailing) {
                            if room.canDelete {
                                Button(role: .destructive) {
                                    deleteRoom = room
                                } label: {
                                    Label(NSLocalizedString("_link_delete_room_", comment: ""), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { viewModel.loadConversations() }
        .onChange(of: searchQuery) { _, newValue in
            viewModel.searchUsers(query: newValue)
        }
        .confirmationDialog(
            NSLocalizedString("_link_delete_room_", comment: ""),
            isPresented: Binding(
                get: { deleteRoom != nil },
                set: { if !$0 { deleteRoom = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("_delete_", comment: ""), role: .destructive) {
                if let room = deleteRoom {
                    Task { await viewModel.deleteConversation(token: room.token) }
                }
                deleteRoom = nil
            }
            Button(NSLocalizedString("_cancel_", comment: ""), role: .cancel) {
                deleteRoom = nil
            }
        } message: {
            Text(NSLocalizedString("_link_delete_room_confirm_", comment: ""))
                + Text("\n\"") + Text(deleteRoom?.displayName ?? "") + Text("\"")
        }
        .sheet(item: $settingsRoom) { room in
            LinkRoomSettingsSheet(viewModel: viewModel, room: room, onLobbyChanged: {
                // Frisches Raum-Objekt: der Lobby-Toggle zeigt beim
                // Wieder-Oeffnen den Server-Stand (Run-Feedback 15.09.).
                if let fresh = viewModel.currentRoom, fresh.token == room.token {
                    settingsRoom = fresh
                }
            })
        }
    }
    }
}

private struct LinkConversationRow: View {
    @ObservedObject var viewModel: LinkViewModel
    let room: LinkConversation

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(room.displayName).font(.body).fontWeight(.medium).lineLimit(1)
                    if room.hasCall {
                        Image(systemName: "phone.fill").foregroundStyle(.green).font(.caption)
                    }
                }
                Text(room.lastMessageText()).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Nextcloud-Status des 1:1-Gegenuebers (Anzeigename-Mapping; der
    /// Raumname eines 1:1-Chats ist der Kontoname des Peers).
    private var peerStatus: String? {
        guard room.isOneToOne else { return nil }
        return viewModel.userStatusesByName[room.displayName]
            ?? viewModel.userStatuses[room.displayName]
    }

    /// Raum-Avatar (1:1 liefert den Avatar des Gegenübers) mit dem
    /// Unread-Badge überlappend unten rechts. SVG-Antworten (generierte
    /// Gruppen-Avatare) kann UIImage nicht dekodieren -> Icon-Kreis wie Talk.
    private var avatar: some View {
        let url = viewModel.roomAvatarURL(for: room)
        return ZStack {
            if let data = viewModel.avatarCache[url],
               let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
            } else {
                Circle().fill(LinearGradient(colors: SouveraAppearance.gradientColors,
                                             startPoint: .top, endPoint: .bottom)).frame(width: 44, height: 44)
                Image(systemName: room.isOneToOne ? "person.fill" : "person.3.fill")
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 44, height: 44)
        .overlay(alignment: .bottomTrailing) {
            if room.unreadMessages > 0 {
                Text(room.unreadMessages > 99 ? "99+" : "\(room.unreadMessages)")
                    .font(.caption2).fontWeight(.bold).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.red))
                    .offset(x: 3, y: room.isOneToOne && peerStatus != nil ? -14 : 3)
            }
            if room.isOneToOne, let status = peerStatus {
                // Status-Pill am Gegenueber von 1:1-Chats (Run 15.09.) -
                // IMMER sichtbar (unabhaengig vom Unread-Badge, der ggf.
                // oben rechts erscheint), volle Farben, opak-weisser Ring.
                LinkPresence.statusPill(for: status, size: 15)
                    .offset(x: 2, y: 2)
            }
        }
        .task {
            await viewModel.loadAvatar(url: url)
        }
    }
}

/// Ziel-Auswahl für "Weiterleiten": zeigt die vorhandenen Channels,
/// durchsuchbar; ein Tipp sendet die Nachricht ins Ziel.
private struct ForwardPickerSheet: View {
    @ObservedObject var viewModel: LinkViewModel
    let message: LinkChatMessage
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.conversations {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .error(errorMessage):
                    Text(errorMessage).foregroundStyle(.secondary).padding()
                case let .success(rooms):
                    let filtered = query.isEmpty
                        ? rooms
                        : rooms.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
                    if filtered.isEmpty {
                        Text(NSLocalizedString("_link_no_conversations_", comment: ""))
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        List(filtered) { room in
                            Button {
                                viewModel.forwardMessage(message, to: room)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: room.isOneToOne ? "person.crop.circle" : "person.3.fill")
                                        .foregroundStyle(.secondary)
                                    Text(room.displayName).lineLimit(1)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .listStyle(.plain)
                        .searchable(text: $query, prompt: NSLocalizedString("_link_search_people_", comment: ""))
                    }
                }
            }
            .navigationTitle(NSLocalizedString("_link_forward_to_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
                }
            }
        }
    }
}

/// A live chat: message list (auto-scrolls to newest) + composer.
struct LinkChatView: View {
    @ObservedObject var viewModel: LinkViewModel
    let token: String
    let title: String
    /// P68k: Nachricht, deren Bild gerade im Vollbild-Viewer geöffnet ist.
    @State private var fullscreenImageMessage: LinkChatMessage?
    /// P68o: PDF-Datei für den QuickLook-Vollbild-Viewer.
    @State private var pdfPreviewURL: URL?
    /// P68n: Nach dem Senden ans Listenende springen.
    @State private var scrollToNewestPending = false
    /// Run 15.09.: Fokus-Anker für den Composer — das „+"-Menü/Emoji-
    /// Keyboard-Wechsel dürfen den Fokus nicht verlieren (Refocus).
    @FocusState private var composerFocused: Bool
    @State private var lastVisibleMessageId: Int64?
    @State private var draft = ""
    @State private var showFilePicker = false
    @State private var showNextcloudPicker = false
    @State private var showPhotoPicker = false
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var sharePayload: SouveraSharePayload?
    @State private var editingMessage: LinkChatMessage?
    @State private var mentionSuggestions: [LinkParticipant] = []
    @State private var reactionTarget: LinkChatMessage?
    @State private var replyingTo: LinkChatMessage?
    @State private var forwardTarget: LinkChatMessage?
    /// Kanten-Swipe (links → rechts) zurück zur Raumübersicht (einfache
    /// Variante: Ansicht folgt dem Finger, kein Preview-Overlay).
    @State private var backDragOffset: CGFloat = 0
    /// Chat-Eintritt: Die Liste wird unsichtbar an die Trennlinie bzw.
    /// ans Ende positioniert, bevor sie eingeblendet wird (kein
    /// sichtbarer Sprung). Mit der UIKit-Liste ist der Eintritts-Scroll
    /// deterministisch (ein Frame statt Retry-Loop).
    @State private var chatPositioned = false
    /// "Runter zu den neuesten Nachrichten"-Button sichtbar (hochgescrollt)?
    @State private var showScrollBottom = false
    /// Nutzer ist am OBEREN Listenende (Offset <= 2 px) - schaltet die
    /// Hinweis-/Lade-Bubble sichtbar (Run-Korrektur: Bubble gehört in den
    /// Scroll-Inhalt, nicht fixiert).
    /// UIKit-Chat-Liste: Scroll-Kommandos + Delegates (talk-ios-Muster).
    @StateObject private var chatListController = LinkChatListController()
    /// Echte Distanz zum Listenende (aus scrollViewDidScroll) - Grundlage
    /// für Klemme und Down-Pfeil.
    @State private var chatBottomDistance: CGFloat = .infinity

    var body: some View {
        VStack(spacing: 0) {
            messageList
                // Offenen Raum app-weit melden: Push-Banner für DIESEN Raum
                // werden unterdrückt (nur Ton), Run 12.09.
                .onAppear { SouveraOpenChatState.shared.token = token }
                .onDisappear { if SouveraOpenChatState.shared.token == token { SouveraOpenChatState.shared.token = nil } }
                .onChange(of: token) { _, newToken in
                    SouveraOpenChatState.shared.token = newToken
                }
                .fullScreenCover(item: $fullscreenImageMessage) { target in
                    LinkImageViewer(
                        title: target.fileInfo()?.name ?? "",
                        imageData: viewModel.chatImageCache[target.id]
                    )
                }
                .quickLookPreview($pdfPreviewURL)
            Divider()
            composer
        }
        .offset(x: backDragOffset)
        .gesture(edgeSwipeBack)
        .overlay {
            if let target = reactionTarget {
                EmojiReactionOverlay(
                    ownReaction: target.reactionsSelf.first,
                    onPick: { emoji in
                        viewModel.setReaction(message: target, emoji: emoji)
                        reactionTarget = nil
                    },
                    onRemove: {
                        viewModel.removeOwnReaction(message: target)
                        reactionTarget = nil
                    },
                    onCancel: { reactionTarget = nil }
                )
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                let didStart = url.startAccessingSecurityScopedResource()
                let data = try? Data(contentsOf: url)
                if didStart { url.stopAccessingSecurityScopedResource() }
                guard let data else { return }
                // Auch Datei-Anhänge ans neue Ende pinnen (Run 13.09.).
                scrollToNewestPending = true
                viewModel.sendAttachment(
                    data: data,
                    fileName: url.lastPathComponent,
                    mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                )
            case .failure:
                break
            }
        }
        .sheet(isPresented: $showNextcloudPicker) {
            NextcloudFilePickerView { selection in
                guard let selection else { return }
                viewModel.shareAttachment(selection)
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoSelections, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoSelections) { _, items in
            importPhotos(items)
        }
        .sheet(item: $sharePayload) { payload in
            SouveraShareSheet(items: payload.items)
        }
        .sheet(item: $forwardTarget) { message in
            ForwardPickerSheet(viewModel: viewModel, message: message)
        }
        .onChange(of: draft) { _, _ in
            updateMentions()
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                viewModel.signaling.stopLocalTyping()
            } else {
                viewModel.signaling.notifyTyping()
            }
        }
    }

    /// Kanten-Geste: von der linken Bildschirmkante nach rechts ziehen
    /// führt zurück zur Raumübersicht.
    private var edgeSwipeBack: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard value.startLocation.x < 32,
                      value.translation.width > 0,
                      abs(value.translation.height) < abs(value.translation.width) else { return }
                backDragOffset = min(value.translation.width, 140)
            }
            .onEnded { value in
                let qualifies = value.startLocation.x < 32
                    && value.translation.width > 80
                    && abs(value.translation.height) < abs(value.translation.width)
                if qualifies {
                    viewModel.back()
                }
                withAnimation(.easeOut(duration: 0.2)) {
                    backDragOffset = 0
                }
            }
    }

    private func updateMentions() {
        guard let lastAt = draft.lastIndex(of: "@") else {
            mentionSuggestions = []
            return
        }
        let fragment = String(draft[draft.index(after: lastAt)...])
        guard !fragment.contains(" "), !fragment.contains("\n") else {
            mentionSuggestions = []
            return
        }
        let query = fragment.lowercased()
        mentionSuggestions = viewModel.participants
            .filter { $0.displayName.lowercased().contains(query) }
            .prefix(5)
            .map { $0 }
    }

    private func insertMention(_ participant: LinkParticipant) {
        guard let lastAt = draft.lastIndex(of: "@") else { return }
        let prefix = String(draft[..<lastAt])
        let displayName = participant.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = prefix + "@\"" + displayName + "\" "
        mentionSuggestions = []
    }

    /// Nachrichten ohne gelöschte Systemmeldungen (Grundlage für Tages-
    /// trenner und Unread-Linie).
    private var visibleItems: [LinkChatMessage] {
        guard case let .success(items) = viewModel.messages else { return [] }
        return items.filter { $0.systemMessage != "message_deleted" }
    }

    /// Render-Basis: Verlauf + abgeleitete pendent Nachrichten der
    /// Offline-Warteschlange (negative IDs). EINE Quelle fuer
    /// chatListItems UND rowProvider - der fruehere Split (rowProvider
    /// indexierte das messages-only-Array) liess pendent Zeilen als
    /// EmptyView rendern (Run-Feedback 11.09.: "waehrend offline nicht
    /// sichtbar").
    /// Eigenen Anzeigenamen ableiten (fuer pendent Nachrichten): Name der
    /// letzten eigenen Nachricht im Verlauf, sonst Username-Präfix. Der
    /// fruehere Raumname erzeugte falsche Kuerzel ("TT" statt "AR",
    /// Run-Feedback 12.09.).
    private var ownDisplayName: String {
        if let own = visibleItems.last(where: { $0.actorId == viewModel.currentUserId }),
           !own.actorDisplayName.isEmpty {
            return own.actorDisplayName
        }
        return viewModel.currentUserId.split(separator: "@").first.map(String.init) ?? viewModel.currentUserId
    }

    private var renderMessages: [LinkChatMessage] {
        var items = visibleItems
        if case let .chat(token, _) = viewModel.route {
            let displayName = ownDisplayName
            let pendingTemps = viewModel.pendingMessages
                .filter { $0.token == token }
                .sorted { $0.createdAt < $1.createdAt }
                .map { pending in
                    LinkChatMessage.makePending(
                        id: pending.id,
                        token: pending.token,
                        actorId: viewModel.currentUserId,
                        displayName: displayName,
                        timestamp: pending.createdAt,
                        text: pending.text,
                        replyParent: replyParent(for: pending.replyTo, in: items),
                        attachmentFileName: pending.kind == .attachment ? pending.fileName : nil
                    )
                }
            items.append(contentsOf: pendingTemps)
        }
        return items
    }

    /// Kompletter Verlauf als UIKit-Liste-Items (globaler Index = Listen-
    /// position - der Render-Fenster-Mechanismus ist mit der Vollverlauf-
    /// Vereinfachung entfallen).
    private var chatListItems: [LinkChatListItem] {
        renderMessages.enumerated().map { LinkChatListItem(globalIndex: $0.offset, message: $0.element) }
    }

    /// Antwort-Kontext fuer pendent Nachrichten (Quote aus dem geladenen
    /// Verlauf ableiten).
    private func replyParent(for replyTo: Int64?, in items: [LinkChatMessage]) -> LinkParent? {
        guard let replyTo, let original = items.first(where: { $0.id == replyTo }) else { return nil }
        return LinkParent(from: original)
    }

    /// Sende-Status: Queue-Pendant liefert .queued (1 Haken); JEDE andere
    /// EIGENE Nachricht ist serverseitig angekommen -> .sent (2 Haken,
    /// dauerhaft, talk-web-Stil - Run-Feedback 12.09.). Fremde: nil.
    private func pendingState(for message: LinkChatMessage) -> LinkPendingMessage.PendingState? {
        guard message.actorId == viewModel.currentUserId else { return nil }
        if let queued = viewModel.pendingMessages.first(where: { $0.id == message.id }) {
            return queued.state
        }
        return message.id > 0 ? .sent : nil
    }

    private func showsDaySeparator(index: Int, message: LinkChatMessage) -> Bool {
        // Pendent Nachrichten haengen direkt am heutigen Ende - keine
        // eigene Tages-Trennlinie (die ID-Aufloesung greift fuer sie eh
        // nicht, sie stehen nur in der Queue).
        if message.id < 0 { return false }
        // Nachbar per ID aufloesen (wie showsTime/showsAvatar): der rohe
        // Index kann bei nachtraeglichen Inserts vor der Zelle auf einen
        // falschen Nachbarn zeigen (eingefrorene Zelle -> doppelte/
        // fehlende Tages-Trennlinien, Run-Feedback 11.09.).
        let visible = visibleItems
        guard let currentIndex = visible.firstIndex(where: { $0.id == message.id }) else { return true }
        guard currentIndex > 0 else { return true }
        let previous = visible[currentIndex - 1]
        let calendar = Calendar.current
        let prevDay = calendar.startOfDay(for: Date(timeIntervalSince1970: previous.timestamp))
        let thisDay = calendar.startOfDay(for: Date(timeIntervalSince1970: message.timestamp))
        return prevDay != thisDay
    }

    /// Dezente Tages-Trennlinie im Verlauf (P68j).
    private func daySeparatorRow(for timestamp: TimeInterval) -> some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1)
            Text(dayLabel(for: timestamp))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func dayLabel(for timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return NSLocalizedString("_link_today_", comment: "")
        }
        if calendar.isDateInYesterday(date) {
            return NSLocalizedString("_link_yesterday_", comment: "")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d. MMMM"
        return formatter.string(from: date)
    }

    @ViewBuilder
    private var messageList: some View {
        switch viewModel.messages {
        case .loading:
            Spacer(); ProgressView(); Spacer()
        case let .error(message):
            Spacer(); Text(message).foregroundStyle(.secondary); Spacer()
        case let .success(items):
            LinkChatListView(
                controller: chatListController,
                items: chatListItems,
                roomToken: token,
                unreadBoundary: viewModel.unreadBoundary,
                isLoadingHistory: viewModel.isLoadingHistory,
                isPositioned: chatPositioned,
                viewModel: viewModel,
                rowProvider: { globalIndex in
                    let render = renderMessages
                    guard render.indices.contains(globalIndex) else { return AnyView(EmptyView()) }
                    return AnyView(chatRow(index: globalIndex, message: render[globalIndex], items: render))
                },
                onDistanceChanged: { distance in
                    handleBottomDistance(distance)
                },
                onEntrySettled: {
                    onEntrySettled()
                },
                onRequestOlder: {
                    // On-demand-Verlauf am Kopf: naechste gepufferte
                    // Batch einfuegen (Controller haelt die Position).
                    viewModel.publishOlderBatch()
                }
            )
            .opacity(chatPositioned ? 1 : 0)
                // Raumwechsel: Zustände zurücksetzen (die Liste resetiert
                // ihren Eintritts-Scroll selbst über roomToken).
                .onChange(of: token) { _, _ in
                    chatPositioned = false
                    showScrollBottom = false
                    chatBottomDistance = .infinity
                    lastVisibleMessageId = items.last?.id
                }
                // Verspätete Trennlinie (Room-Objekt/Boundary kommt nach dem
                // Cache-first): Der Controller zieht das Eintrittsziel auf
                // die Trennlinie nach, solange die Eintritts-Phase läuft -
                // nicht der frühere !chatPositioned-Guard (der feuerte nie,
                // weil chatPositioned vor der Boundary bereits true war).
                .onChange(of: viewModel.unreadBoundary) { _, boundary in
                    chatListController.applyBoundary(boundary)
                }
                // Verlaufs-Prepend fertig: Die Leseposition hält der
                // Controller über die Offset-Delta-Erhaltung - kein
                // zusätzlicher Re-Anchor-Scroll mehr nötig.
                .onChange(of: renderMessages.last?.id) { _, newLastId in
                    // Neue Nachricht (Server-Echo ODER offline Queue-Zuwachs):
                    // ans neue Ende klemmen - eigene immer, fremde wenn nicht
                    // manuell hochgescrollt (Run-Feedback 14.09.).
                    autoPinIfNeeded(newLastId: newLastId)
                }
                .onChange(of: viewModel.pendingMessages.count) { _, _ in
                    // Direkter Offline-Trigger: Queue-Zuwachs pinned sofort
                    // (Run-Feedback 14.09.: offline rutschten Nachrichten
                    // unter die Kante).
                    autoPinIfNeeded(newLastId: viewModel.pendingMessages.last?.id)
                }
                // "Zu den neuesten Nachrichten"-Button: am VIEWPORT gebunden,
                // mittig unten, optisch identisch zum Mail-Up-Pfeil.
                .overlay(alignment: .bottom) {
                    if let lastId = items.last?.id {
                        scrollBottomButton(lastId: lastId)
                            .padding(.bottom, 16)
                            .opacity(showScrollBottom ? 1 : 0)
                            .animation(.easeInOut(duration: 0.25), value: showScrollBottom)
                    }
                }
            }
    }


    /// Dezente Trennlinie "Neue Nachrichten" (Talk-Standard).
    private var unreadSeparatorRow: some View {        HStack(spacing: 10) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1)
            Text(NSLocalizedString("_link_new_messages_", comment: ""))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Fotos aus dem System-Picker übernehmen und in den Chat hochladen
    /// (kein Berechtigungsdialog - der System-Picker läuft außerhalb der App).
    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            var counter = 0
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first
                let ext = type?.preferredFilenameExtension ?? "jpg"
                counter += 1
                let name = "Foto_\(Int(Date().timeIntervalSince1970))_\(counter).\(ext)"
                let mime = type?.preferredMIMEType ?? "image/jpeg"
                // Auch Anhänge ans neue Ende pinnen (Run 13.09.).
                scrollToNewestPending = true
                viewModel.sendAttachment(data: data, fileName: name, mimeType: mime)
            }
            await MainActor.run { photoSelections = [] }
        }
    }

    /// Baut die Teile-Liste für das iOS-Teilen-Sheet (Text, Links, Anhang).
    private func prepareShare(for message: LinkChatMessage) {
        Task {
            let items = await viewModel.shareItems(for: message)
            guard !items.isEmpty else { return }
            await MainActor.run {
                sharePayload = SouveraSharePayload(items: items)
            }
        }
    }

    /// UIKit-Liste hat den Eintritts-Scroll gesetzt (talk-ios: reloadData +
    /// imperative scrollToRow) -> Liste einblenden und den KOMPLETTEN
    /// Verlauf im Hintergrund nachladen (Run-Vereinfachung 10.09.).
    /// Auto-Pin-Regel (Run 14.09.): EIGENE Nachrichten pinnen immer;
    /// fremde pinnen, solange nicht manuell hochgescrollt wurde
    /// (Toleranz 300 px = "am Ende").
    private func autoPinIfNeeded(newLastId: Int64?) {
        guard chatPositioned, newLastId != nil, newLastId != lastVisibleMessageId else { return }
        if scrollToNewestPending {
            scrollToNewestPending = false
            chatListController.pinToBottomUntilStable()
            viewModel.noteScrolledToNewest()
        } else if chatBottomDistance <= 300 {
            chatListController.pinToBottomUntilStable()
        }
        lastVisibleMessageId = newLastId
    }

    private func onEntrySettled() {
        chatPositioned = true
        SouveraLog.write("LinkChat", "entry settled (UIKit)")
        viewModel.loadFullHistoryInBackground()
    }

    /// Distanz zum Listenende (aus scrollViewDidScroll): steuert den
    /// Down-Pfeil, den Read-Marker und die Klemm-Logik.
    private func handleBottomDistance(_ distance: CGFloat) {
        chatBottomDistance = distance
        let visible = distance > 120
        if visible != showScrollBottom {
            withAnimation(.easeInOut(duration: 0.25)) {
                showScrollBottom = visible
            }
        }
        if !visible {
            viewModel.noteScrolledToNewest()
        }
    }

    /// F1: Eine Chat-Zeile inkl. Tages-/Ungelesen-Trennlinien — ausgelagert,
    /// damit der Zellen-Content für den Type-Checker handhabbar bleibt.
    /// (Scroll-IDs entfallen: die UIKit-Liste adressiert Zellen über
    /// IndexPath, nicht über SwiftUI-IDs.)
    @ViewBuilder
    private func chatRow(index: Int, message: LinkChatMessage, items: [LinkChatMessage]) -> some View {
        // Tageswechsel-Trennlinie (P68j): vor der ersten Nachricht eines
        // neuen Kalendertags.
        if showsDaySeparator(index: index, message: message) {
            daySeparatorRow(for: message.timestamp)
        }
        // "Neue Nachrichten"-Trennlinie vor der ersten ungelesenen
        // Nachricht (Talk-Standard).
        if !viewModel.hideUnreadSeparator,
           viewModel.unreadBoundary == message.id {
            unreadSeparatorRow
        }
        if message.isSystemMessage {
            LinkSystemMessageRow(message: message)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
        } else {
                            LinkMessageRow(
                                viewModel: viewModel,
                                message: message,
                                isOwn: message.actorId == viewModel.currentUserId,
                                pendingState: pendingState(for: message),
                                showTime: showsTime(index: index, message: message, items: items),
                                showsAvatar: showsAvatar(index: index, message: message, items: items),
                                onStartEdit: { editingMessage = message; draft = message.message },
                                onFileTap: { info in
                                    // Datei im Dateien-Modul anzeigen (Ordner
                                    // des Talk-Uploads statt lokaler Vorschau).
                                    viewModel.openFileInFiles(info)
                                },
                                onImageTap: { target in
                                    fullscreenImageMessage = target
                                },
                                onPdfTap: { target in
                                    if let url = viewModel.chatPdfCache[target.id] {
                                        pdfPreviewURL = url
                                    }
                                },
                                onStartReply: { replyingTo = message },
                                onStartForward: { forwardTarget = message },
                                onLongPress: { target in reactionTarget = target },
                                onShare: { target in prepareShare(for: target) }
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
        }
    }

    /// "Runter zu den neuesten Nachrichten": identisches Design wie der
    /// Mail-Up-Pfeil (Kreis, Material, Schatten), Icon arrow.down.
    private func scrollBottomButton(lastId: Int64) -> some View {
        Button {
            chatListController.scrollToBottom(animated: true)
            withAnimation(.easeInOut(duration: 0.25)) {
                showScrollBottom = false
            }
            viewModel.noteScrolledToNewest()
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(NCBrandColor.shared.customer))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("_link_scroll_bottom_", comment: ""))
    }

/// Zeitstempel minutengenau gruppieren: bei Minutenwechsel UND am Start
    /// einer Autoren-Gruppe (dort sitzt der Stempel neben dem Avatar).
    private func showsTime(index: Int, message: LinkChatMessage, items: [LinkChatMessage]) -> Bool {
        let visible = items.filter { $0.systemMessage != "message_deleted" }
        guard let currentIndex = visible.firstIndex(where: { $0.id == message.id }),
              currentIndex > 0 else { return true }
        let previous = visible[currentIndex - 1]
        guard !previous.isSystemMessage else { return true }
        if previous.actorId != message.actorId { return true }
        if message.timestamp - previous.timestamp > 300 { return true }
        return minuteStamp(message) != minuteStamp(previous)
    }

    /// Avatar (Talk-Stil) nur am Start einer Folge desselben Autors zeigen;
    /// Folge-Nachrichten desselben Autors (innerhalb 5 Min.) rücken ein.
    private func showsAvatar(index: Int, message: LinkChatMessage, items: [LinkChatMessage]) -> Bool {
        let visible = items.filter { $0.systemMessage != "message_deleted" }
        guard let currentIndex = visible.firstIndex(where: { $0.id == message.id }) else { return false }
        if currentIndex == 0 { return true }
        let previous = visible[currentIndex - 1]
        guard !previous.isSystemMessage else { return true }
        guard previous.actorId == message.actorId else { return true }
        return message.timestamp - previous.timestamp > 300
    }

    private func minuteStamp(_ message: LinkChatMessage) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmm"
        return formatter.string(from: Date(timeIntervalSince1970: message.timestamp))
    }

    /// Talk-Logik: 1 Person "X schreibt…", 2 "X und Y schreiben…",
    /// 3+ "Mehrere Personen schreiben…".
    private func typingText(names: [String]) -> String {
        switch names.count {
        case 1:
            return String(format: NSLocalizedString("_link_typing_one_", comment: ""), names[0])
        case 2:
            return String(format: NSLocalizedString("_link_typing_two_", comment: ""), names[0], names[1])
        default:
            return NSLocalizedString("_link_typing_many_", comment: "")
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if !viewModel.typingNames.isEmpty {
                HStack(spacing: 6) {
                    Text(typingText(names: viewModel.typingNames))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TypingDotsView()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            if !mentionSuggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(mentionSuggestions) { participant in
                        Button {
                            insertMention(participant)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: participant.actorType == "guests" ? "person.crop.circle.badge.questionmark" : "person.crop.circle")
                                    .foregroundStyle(.secondary)
                                Text(participant.displayName).font(.subheadline)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .background(Color(.secondarySystemBackground))
            }

            // Run 15.09.: Bearbeiten-Chip (ersetzt die alte Speichern/
            // Abbrechen-Leiste) - der Composer-Text wird per Senden
            // gespeichert (commitEdit).
            if editingMessage != nil {
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("_link_edit_message_", comment: ""))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        editingMessage = nil
                        draft = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }

            if let replyingTo {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(String(format: NSLocalizedString("_link_reply_to_", comment: ""), replyingTo.actorDisplayName))
                            .font(.caption)
                            .fontWeight(.medium)
                        Text(replyingTo.message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        self.replyingTo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                // Runder "+"-Button (Anhang-Menü) - Talk-Stil, Run 15.09.
                Menu {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label(NSLocalizedString("_link_attach_file_", comment: ""), systemImage: "doc.badge.plus")
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        // Run 15.09.: Keyboard beim Menü halten — Fokus kurz
                        // nach der Menü-Öffnung zurücksetzen (Emoji-Flow).
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            composerFocused = true
                        }
                    })
                    Button {
                        showPhotoPicker = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            composerFocused = true
                        }
                    } label: {
                        Label(NSLocalizedString("_link_attach_photos_", comment: ""), systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showNextcloudPicker = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            composerFocused = true
                        }
                    } label: {
                        Label(NSLocalizedString("_link_share_file_", comment: ""), systemImage: "building.columns")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color(.systemBackground)))
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                }
                // Weiße Pille als Textfeld-Container; rechts reservierter
                // Bereich: Sendeknopf (blauer Kreis, weißes Icon) nur bei
                // Text - sonst frei für den späteren Mikrofon-Button
                // (Run-Feedback 15.09.).
                HStack(spacing: 8) {
                    TextField(NSLocalizedString("_link_message_", comment: ""), text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($composerFocused)
                        .lineLimit(1...5)
                    // Reservierter Platz für den späteren Mikrofon-Button.
                    Color.clear.frame(width: 30, height: 30)
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .padding(.vertical, 5)
                .frame(minHeight: 44)
                // Run 15.09.: RoundedRectangle(22) statt Capsule - bei
                // einer Zeile (Höhe 44) pixelidentisch zur Capsule, bei
                // mehreren Zeilen bleiben die Ecken konstant rund (kein
                // deformierter Stadium-Look). Das Höhenwachstum morpht
                // weich über den Spring unten (kein harter Shape-Wechsel).
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(.systemBackground)))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Sendeknopf RECHTS NEBEN der Pille (Run-Feedback 15.09.):
                    // Pille verkürzt sich animiert, Knopf blendet ein/aus.
                    Button {
                        let text = draft
                        if let editing = editingMessage {
                            // Run 15.09.: Bearbeiten - die NACHRICHT wird an
                            // Position/Zeitstempel geändert, nicht neu gesendet.
                            viewModel.commitEdit(editing, text: text)
                        } else {
                            let replyTarget = replyingTo?.id
                            // P68n: Nach dem Senden automatisch ans Ende scrollen.
                            scrollToNewestPending = true
                            viewModel.send(text: text, replyTo: replyTarget)
                        }
                        draft = ""
                        editingMessage = nil
                        replyingTo = nil
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle().fill(LinearGradient(colors: SouveraAppearance.gradientColors,
                                                             startPoint: .top, endPoint: .bottom))
                            )
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 14)
            // Flüssiger Composer (Run 15.09.): Höhenwachstum (Mehrzeiler)
            // und Send-Button-Einblendung teilen sich einen Spring - das
            // Feld wächst weich, der Button gleitet, kein Layout-Sprung.
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: draft)
        }
    }
}

/// Drei animierte Punkte für die Tipp-Anzeige (Talk-Stil).
private struct TypingDotsView: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(animate ? 0.25 : 1)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.18),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

/// One chat message row: bubble, optional file chip, swipe actions
/// (delete/edit for own messages).
private struct LinkMessageRow: View {
    @ObservedObject var viewModel: LinkViewModel
    let message: LinkChatMessage
    let isOwn: Bool
    var pendingState: LinkPendingMessage.PendingState?
    var showTime: Bool = true
    var showsAvatar: Bool = true
    let onStartEdit: () -> Void
    let onFileTap: (LinkFileInfo) -> Void
    /// P68k: Tap auf ein Inline-Bild -> Vollbild-Viewer.
    var onImageTap: (LinkChatMessage) -> Void = { _ in }
    /// P68o: Tap auf ein PDF-Thumbnail -> QuickLook-Viewer.
    var onPdfTap: (LinkChatMessage) -> Void = { _ in }
    let onStartReply: () -> Void
    let onStartForward: () -> Void
    var onLongPress: (LinkChatMessage) -> Void = { _ in }

    /// Nachricht bearbeitet? Serverbasiert (lastEditTimestamp aus der
    /// Poll-Antwort) oder lokaler Fallback (eigene Edits, Run 15.09.).
    private func isMessageEdited(_ message: LinkChatMessage) -> Bool {
        if message.lastEditTimestamp > 0 { return true }
        return message.id > 0 && viewModel.editedIds.contains(message.id)
    }
    /// "Teilen…" aus dem Kontextmenü (iOS-Teilen-Sheet).
    var onShare: (LinkChatMessage) -> Void = { _ in }

    private var messageTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: message.timestamp))
    }

    /// Initialen aus dem Anzeigenamen (Fallback-Avatar).
    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }

    /// Emoji-Reaktions-Pills, halb überlappend an der linken unteren
    /// Bubble-Ecke (einheitlich für eigene UND fremde Nachrichten,
    /// Run-Feedback 13.09.). Fremde Reaktionen = helles Grün (abgehoben
    /// vom Nachrichten-Blau), eigene = orange + Ring als Eigen-Kennung.
    @ViewBuilder
    private func reactionPills(message: LinkChatMessage) -> some View {
        HStack(spacing: 4) {
            ForEach(message.reactions.sorted(by: { $0.key < $1.key }), id: \.key) { emoji, count in
                let isOwn = message.reactionsSelf.contains(emoji)
                Text("\(emoji) \(count)")
                    .font(.caption2)
                    .foregroundStyle(isOwn ? .white : .primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        // DECKEND (Run-Feedback 14.09.: 0.2-Opazität liess den
                        // Hintergrund durchscheinen): festes helles Grün.
                        Capsule().fill(isOwn
                            ? Color.orange.opacity(0.95)
                            : Color(red: 0.5, green: 0.85, blue: 0.55))
                    )
                    .overlay(
                        Capsule().stroke(isOwn ? Color.white.opacity(0.85) : .clear, lineWidth: 1)
                    )
            }
        }
    }

    /// Autor-Avatar (Talk-Stil): nur am Start einer Gruppe desselben Autors,
    /// sonst ein leerer Platzhalter gleicher Breite (Einrückung).
    @ViewBuilder
    private var avatarColumn: some View {
        let url = viewModel.userAvatarURL(for: message)
        if !showsAvatar {
            Color.clear.frame(width: 30, height: 30)
        } else if let url, let data = viewModel.avatarCache[url], let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
                .frame(width: 30, height: 30)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(LinearGradient(colors: SouveraAppearance.gradientColors,
                                             startPoint: .top, endPoint: .bottom))
                Text(initials(message.actorDisplayName))
                    .font(.caption2).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            .task {
                if let url { await viewModel.loadAvatar(url: url) }
            }
        }
    }

    /// Zitat des Elternteils bei Antworten (klein, über der Bubble).
    @ViewBuilder
    private var replyQuote: some View {
        if let parent = message.parent, !parent.isSystemMessage {
            HStack(spacing: 5) {
                Rectangle().fill(Color.gray.opacity(0.45)).frame(width: 2.5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(parent.actorDisplayName).font(.caption2).fontWeight(.medium)
                    // P68l (1b): Platzhalter im Zitat auflösen (sonst steht
                    // {mention-user1} roh im Text).
                    Text(parent.resolvedDisplayText).font(.caption2).lineLimit(2)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            // Bindung an die Bubble: bei EIGENEN Nachrichten rechtsbündig
            // (rechte Kante von Zitat und Bubble incl. Haken-Spalte
            // fluchten), bei fremden wie bisher linksbündig
            // (Run-Feedback 15.09.).
            .frame(maxWidth: 230, alignment: isOwn ? .trailing : .leading)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if !isOwn {
                avatarColumn
            }
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 2) {
                if showTime {
                    Text(messageTime)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(.leading, isOwn ? 0 : 6)
                        .padding(.trailing, isOwn ? 6 : 0)
                }
                replyQuote
                // P68k: Bildnachrichten rendern Bild + Caption IN der Bubble
                // (einheitliche Optik); Nicht-Bild-Dateien behalten den Chip.
                if let file = message.fileInfo(),
                   !viewModel.isImageMessage(message),
                   !viewModel.isPdfMessage(message) {
                    Button {
                        onFileTap(file)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paperclip").font(.caption)
                            Text(file.name).font(.caption).lineLimit(1)
                            if file.size > 0 {
                                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 0) {
                    if isOwn { Spacer(minLength: 40) }
                    LinkMessageBubble(
                        message: message,
                        isOwn: isOwn,
                        isImageMessage: viewModel.isImageMessage(message),
                        imageData: viewModel.chatImageCache[message.id],
                        imageFailed: message.id > 0 && viewModel.chatImageFailed.contains(message.id),
                        isPdfMessage: viewModel.isPdfMessage(message),
                        pdfThumbData: viewModel.chatPdfThumbCache[message.id],
                        pendingState: pendingState,
                        onImageTap: { onImageTap(message) },
                        onPdfTap: { onPdfTap(message) }
                    )
                    .task {
                        if viewModel.isImageMessage(message) {
                            await viewModel.loadChatImage(for: message)
                        } else if viewModel.isPdfMessage(message) {
                            await viewModel.loadChatPdf(for: message)
                        }
                    }
                        .overlay(alignment: .bottomLeading) {
                            // Reaktionen leicht überlappend an der LINKEN
                            // unteren Bubble-Ecke - bei eigenen Nachrichten
                            // genau wie bei fremden (Run-Feedback 13.09.),
                            // ohne den Nachrichtentext zu verdecken.
                            if !message.reactions.isEmpty {
                                reactionPills(message: message)
                                    .offset(x: 6, y: 10)
                            }
                        }
                    if !isOwn { Spacer(minLength: 40) }
                }
                // Mit Reaktionen hängen die Pills über die Unterkante -
                // der Zeitstempel der nächsten Nachricht braucht dann mehr
                // Abstand (Run-Feedback 13.09.).
                .padding(.bottom, message.reactions.isEmpty ? 0 : 10)
                .contextMenu {
                    Button {
                        onShare(message)
                    } label: {
                        Label(NSLocalizedString("_link_share_message_", comment: ""), systemImage: "square.and.arrow.up")
                    }
                    Button {
                        onLongPress(message)
                    } label: {
                        Label(NSLocalizedString("_link_react_message_", comment: ""), systemImage: "face.smiling")
                    }
                    if isOwn {
                        // Bearbeiten (Run 15.09.): eigene, echte Nachrichten
                        // im Lang-Touch-Menü editieren — NUR wenn der Server
                        // `edit-messages` unterstützt (sonst 400er).
                        if message.id > 0, viewModel.supportsMessageEditing {
                            Button {
                                onStartEdit()
                            } label: {
                                Label(NSLocalizedString("_contact_edit_", comment: ""), systemImage: "pencil")
                            }
                        }
                        // Löschen gehört ins Lang-Touch-Menü, nicht in den
                        // Swipe (Run-Feedback 13.09. - versehentliches
                        // Löschen beim Wischen).
                        Button(role: .destructive) {
                            viewModel.deleteMessage(message)
                        } label: {
                            Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash")
                        }
                    }
                    if let ownReaction = message.reactionsSelf.first {
                        // Run-Vorgabe E2: eigene Reaktion auch aus dem
                        // Kontextmenü entfernen (destruktive Rolle,
                        // Apple-Doku ButtonRole.destructive).
                        Button(role: .destructive) {
                            viewModel.removeOwnReaction(message: message)
                        } label: {
                            Label(
                                String(format: NSLocalizedString("_link_reaction_remove_", comment: ""), ownReaction),
                                systemImage: "trash"
                            )
                        }
                    }
                }
            }
            if isOwn {
                avatarColumn
            }
        }
        .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                onStartReply()
            } label: {
                Label(NSLocalizedString("_link_reply_", comment: ""), systemImage: "arrowshape.turn.up.left")
            }
            .tint(.gray)
            Button {
                onStartForward()
            } label: {
                Label(NSLocalizedString("_link_forward_", comment: ""), systemImage: "arrowshape.turn.up.right")
            }
            .tint(.blue)
            if isOwn {
                Button {
                    onStartEdit()
                } label: {
                    Label(NSLocalizedString("_contact_edit_", comment: ""), systemImage: "pencil")
                }
                .tint(.blue)
            }
        }
        // Run 15.09.: "bearbeitet" klein/zart unter der Bubble —
        // SERVERBASIERT (lastEditTimestamp aus der Poll-Antwort, gilt für
        // eigene UND fremde Edits) mit editedIds-Fallback.
        if isMessageEdited(message), !message.isHiddenSystemMessage {
            Text(NSLocalizedString("_link_message_edited_", comment: ""))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
        }
    }
}

private struct LinkMessageBubble: View {
    let message: LinkChatMessage
    let isOwn: Bool
    /// P68k: Bildnachricht (Bild + Caption IN der Bubble, einheitliche Optik).
    var isImageMessage: Bool = false
    var imageData: Data?
    /// Download endgueltig fehlgeschlagen -> "nicht verfuegbar"-Platzhalter
    /// statt endlosem "Bild wird geladen..." (Run-Feedback 11.09.).
    var imageFailed: Bool = false
    /// P68o: PDF-Nachricht (Thumbnail der 1. Seite + QuickLook-Tap).
    var isPdfMessage: Bool = false
    var pdfThumbData: Data?
    /// Sende-Status (Offline-Warteschlange): .queued = 1 Haken, .sent =
    /// 2 Haken; nil = zugestellte Nachricht. Haken IN der Bubble rechts
    /// neben der Nachricht (talk-web-Stil, Run-Feedback 12.09.).
    var pendingState: LinkPendingMessage.PendingState?
    var onImageTap: () -> Void = {}
    var onPdfTap: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !isOwn {
                Text(message.actorDisplayName).font(.caption2).foregroundStyle(.secondary)
            }
            if isPdfMessage {
                // Kein Dateiname/Caption unter dem Thumbnail - der Name ist
                // nur im Vollbild-Viewer sichtbar (Run-Feedback 13.09.).
                pdfContent
            } else if isImageMessage {
                imageContent
            } else if message.fileName() != nil {
                Text(displayText)
            } else {
                Text(message.attributedDisplayText())
                    .souveraOpenURLAction()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        // Eigene Nachrichten: Reserverand rechts, damit die Haken (unten
        // rechts, s. u.) nicht unter dem Text liegen (Run-Feedback 14.09.).
        .padding(.trailing, isOwn ? 34 : 0)
        // P68k-Width: Bild-/PDF-Bubbles huggen den Inhalt (kein breiter
        // Hintergrund); die Caption-Caps (220/180) bleiben erhalten und
        // wickeln weiter. Textnachrichten sind unverändert.
        .fixedSize(horizontal: isImageMessage || isPdfMessage, vertical: false)
        .background(
            Group {
                if isOwn {
                    // Souvera-Gradient (wie Fullscreen-Hintergrund, Run 15.09.)
                    LinearGradient(colors: SouveraAppearance.gradientColors,
                                   startPoint: .top, endPoint: .bottom)
                } else {
                    Color(.secondarySystemBackground)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
        )
        // Liefer-Haken UNTEN RECHTS IN der Bubble - einheitlich fuer alle
        // Nachrichtentypen (Run-Feedback 14.09.: Doppel-Ausgabe durch zwei
        // Renderpfade und Ecken-Clipping behoben).
        .overlay(alignment: .bottomTrailing) {
            if let pendingState {
                deliveryCheckmarks(pendingState)
                    .padding(.trailing, 10)
                    .padding(.bottom, 6)
            }
        }
        .foregroundStyle(isOwn ? .white : .primary)
    }

    /// Liefer-Haken (talk-web): 1 Haken = in der Warteschlange,
    /// 2 Haken = vom Server angenommen.
    @ViewBuilder
    private func deliveryCheckmarks(_ state: LinkPendingMessage.PendingState) -> some View {
        // Doppelhaken UEBERLAPPEND (WhatsApp/Talk-Optik, Run-Feedback 12.09.).
        HStack(spacing: -3) {
            if state == .sent {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(state == .sent ? 1 : 0)
            }
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(isOwn ? .white.opacity(0.85) : .secondary)
    }

    /// PDF-Thumbnail (1. Seite) im Bubble (Tap -> QuickLook), mit
    /// Lade-Platzhalter (P68o).
    @ViewBuilder
    private var pdfContent: some View {
        if let pdfThumbData, !pdfThumbData.isEmpty, let ui = UIImage(data: pdfThumbData) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 180, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "doc.richtext")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .onTapGesture { onPdfTap() }
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 140, height: 180)
                .overlay(
                    VStack(spacing: 6) {
                        Image(systemName: "doc.richtext").font(.title3)
                        Text(NSLocalizedString("_link_image_loading_", comment: ""))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                )
        }
    }

    /// Bild im Bubble (Tap -> Vollbild), mit Lade-Platzhalter; nach
    /// endgueltig fehlgeschlagenem Download (2 Versuche) "nicht
    /// verfuegbar" statt fuer immer "Bild wird geladen..." (Run-Feedback
    /// 11.09.).
    @ViewBuilder
    private var imageContent: some View {
        if let imageData, !imageData.isEmpty, let ui = UIImage(data: imageData) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onTapGesture { onImageTap() }
        } else if imageFailed {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 160, height: 64)
                .overlay(
                    HStack(spacing: 6) {
                        Image(systemName: "photo.slash").font(.caption)
                        Text(NSLocalizedString("_link_image_failed_", comment: ""))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                )
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 160, height: 100)
                .overlay(
                    HStack(spacing: 6) {
                        Image(systemName: "photo").font(.caption)
                        Text(NSLocalizedString("_link_image_loading_", comment: ""))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                )
        }
    }

    private var messageTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: message.timestamp))
    }

    private var displayText: String {
        if let file = message.fileName() { return "📎 \(file)" }
        return message.displayText()
    }
}

/// Zentrierte graue Zeile für Systemnachrichten (Variablen ersetzt).
private struct LinkSystemMessageRow: View {
    let message: LinkChatMessage

    var body: some View {
        HStack {
            Spacer()
            Text(message.displayText())
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.vertical, 3)
            Spacer()
        }
    }
}

/// Info-Sheet nach dem Einladen eines externen Teilnehmers: Raum-Link
/// kopieren + Hinweis auf die aktivierte Lobby.
private struct ExternalInviteSheet: View {
    let context: LinkViewModel.ExternalInviteContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.green.opacity(0.15)).frame(width: 56, height: 56)
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .padding(.top, 6)

            Text(NSLocalizedString("_link_guest_invited_", comment: ""))
                .font(.headline)
            Text(context.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                UIPasteboard.general.string = context.link
                dismiss()
            } label: {
                Label(NSLocalizedString("_link_copy_room_link_", comment: ""), systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(NCBrandColor.shared.customer))

            HStack(spacing: 8) {
                Image(systemName: "door.left.hand.open")
                    .foregroundStyle(.secondary)
                Text(NSLocalizedString("_link_lobby_enabled_hint_", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(NSLocalizedString("_ok_", comment: ""), role: .cancel) {
                dismiss()
            }
            .font(.subheadline)
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }
}

/// Zeigt die Teilnehmer des geöffneten Channels; bei Owner-/Moderator-Recht
/// können Teilnehmer gesucht/hinzugefügt und per Swipe entfernt werden.
struct LinkParticipantsSheet: View {
    @ObservedObject var viewModel: LinkViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var removeCandidate: LinkParticipant?

    var body: some View {
        NavigationStack {
            // Apple-Standard-Swipes (Run 15.09., Rueckbau: die Custom-
            // Swipe-Geste funktionierte im Scroll-Kontext nicht zuverlaessig).
            List {
                if viewModel.currentRoom?.canManage == true {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField(NSLocalizedString("_link_search_people_", comment: ""), text: $query)
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                        }
                    }
                    if !viewModel.userResults.isEmpty {
                        Section(NSLocalizedString("_link_add_participant_", comment: "")) {
                            ForEach(viewModel.userResults) { suggestion in
                                Button {
                                    viewModel.addParticipant(suggestion)
                                    viewModel.loadParticipants()
                                    query = ""
                                } label: {
                                    Label(suggestion.label, systemImage: suggestionIcon(suggestion.source))
                                }
                            }
                        }
                    }
                }
                Section(NSLocalizedString("_link_participants_", comment: "")) {
                    if viewModel.participants.isEmpty {
                        Text(NSLocalizedString("_link_no_participants_", comment: ""))
                            .foregroundStyle(.secondary)
                    } else {
                        // Teilnehmer ohne anzeigbaren Namen (E-Mail-
                        // Platzhalter) ausblenden - sonst leere Zeilen.
                        ForEach(viewModel.participants.filter {
                            $0.actorType != "deleted_users"
                                && !$0.displayName.trimmingCharacters(in: .whitespaces).isEmpty
                        }) { participant in
                            HStack(spacing: 10) {
                                Image(systemName: participantIcon(participant.actorType))
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(participant.displayName).font(.subheadline)
                                    Text(roleLabel(participant))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                // Status-Pill am Teilnehmer (Run 15.09.).
                                if participant.actorType == "users" {
                                    LinkPresence.statusPill(
                                        for: participant.status
                                            ?? viewModel.userStatuses[participant.actorId]
                                            ?? "offline",
                                        size: 13
                                    )
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                if canRemove(participant) {
                                    Button(role: .destructive) {
                                        removeCandidate = participant
                                    } label: {
                                        Label(NSLocalizedString("_link_participant_remove_", comment: ""), systemImage: "person.crop.circle.badge.minus")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("_link_participants_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // X statt Abbrechen (Konsistenz zu Raum-Einstellungen).
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(NSLocalizedString("_close_", comment: ""))
                }
            }
            .confirmationDialog(
                NSLocalizedString("_link_participant_remove_", comment: ""),
                isPresented: Binding(
                    get: { removeCandidate != nil },
                    set: { if !$0 { removeCandidate = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(NSLocalizedString("_link_participant_remove_", comment: ""), role: .destructive) {
                    if let participant = removeCandidate {
                        viewModel.removeParticipant(participant)
                    }
                    removeCandidate = nil
                }
                Button(NSLocalizedString("_cancel_", comment: ""), role: .cancel) {
                    removeCandidate = nil
                }
            } message: {
                Text(removeCandidate?.displayName ?? "")
            }
        }
        .onChange(of: query) { _, newValue in
            viewModel.searchUsers(query: newValue)
        }
    }

    private func suggestionIcon(_ source: String) -> String {
        switch source {
        case "groups": return "person.3.fill"
        case "federated": return "globe"
        case "email_guest": return "envelope.badge.person.crop"
        default: return "person.crop.circle"
        }
    }

    /// Entfernen nur mit Moderator-Recht UND weder für die eigene Person
    /// noch für den Besitzer (participantType == 1).
    private func canRemove(_ participant: LinkParticipant) -> Bool {
        guard viewModel.currentRoom?.canManage == true else { return false }
        let isOwn = participant.actorType == "users" && participant.actorId == viewModel.currentUserId
        let isOwner = participant.participantType == 1
        return !isOwn && !isOwner
    }

    /// Rolle des Teilnehmers (Owner/Moderator/Mitglied) - fuer ALLE
    /// Teilnehmer sichtbar (Run 15.09., Feedback "Namen und Rolle").
    private func roleLabel(_ participant: LinkParticipant) -> String {
        switch participant.participantType {
        case 1: return NSLocalizedString("_link_participant_owner_", comment: "")
        case 2: return NSLocalizedString("_link_participant_moderator_", comment: "")
        default: return NSLocalizedString("_link_participant_member_", comment: "")
        }
    }

    private func participantIcon(_ actorType: String) -> String {
        switch actorType {
        case "guests": return "person.crop.circle.badge.questionmark"
        case "federated_users": return "globe"
        case "emails": return "envelope"
        default: return "person.crop.circle"
        }
    }
}

/// Raum-Einstellungen: Gäste-Zugang (öffentlich/privat) + Gäste-Link kopieren.
struct LinkRoomSettingsSheet: View {
    @ObservedObject var viewModel: LinkViewModel
    let room: LinkConversation
    /// Wird nach erfolgreicher Lobby-Aenderung gerufen - der Aufrufer
    /// frischt sein Raum-Objekt (und damit das Sheet) auf.
    var onLobbyChanged: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var isPublic: Bool
    @State private var working = false
    @State private var copied = false
    @State private var lobbyEnabled = false

    init(viewModel: LinkViewModel, room: LinkConversation, onLobbyChanged: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.room = room
        self.onLobbyChanged = onLobbyChanged
        _isPublic = State(initialValue: room.isPublic)
        _lobbyEnabled = State(initialValue: room.lobbyState == 1)
    }



    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: Binding(
                        get: { isPublic },
                        set: { newValue in
                            guard !working else { return }
                            Task {
                                working = true
                                let ok = await viewModel.toggleGuestAccess(token: room.token, enabled: newValue)
                                working = false
                                if ok { isPublic = newValue }
                            }
                        }
                    )) {
                        Label(NSLocalizedString("_link_guests_allow_", comment: ""), systemImage: "person.crop.circle.badge.plus")
                    }
                    .disabled(working)
                } footer: {
                    Text(NSLocalizedString("_link_guests_allow_hint_", comment: ""))
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { lobbyEnabled },
                        set: { newValue in
                            guard !working else { return }
                            Task {
                                working = true
                                let ok = await viewModel.toggleLobby(token: room.token, enabled: newValue)
                                working = false
                                if ok {
                                    lobbyEnabled = newValue
                                    onLobbyChanged()
                                }
                            }
                        }
                    )) {
                        Label(NSLocalizedString("_link_lobby_toggle_", comment: ""), systemImage: "hourglass")
                    }
                    .disabled(working)
                } footer: {
                    Text(NSLocalizedString("_link_lobby_toggle_hint_", comment: ""))
                }

                if isPublic {
                    Section {
                        Button {
                            UIPasteboard.general.string = viewModel.guestURL(for: room)
                            copied = true
                        } label: {
                            Label(NSLocalizedString("_link_copy_room_link_", comment: ""), systemImage: "link")
                        }
                        if copied {
                            Text(NSLocalizedString("_link_guest_link_copied_", comment: ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("_link_room_settings_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Run 15.09.: Schließen über X-Symbol statt "Abbrechen"-Text.
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(NSLocalizedString("_close_", comment: ""))
                }
            }
        }
    }
}

/// Zentrales rundes Anruf-Overlay: normal starten oder stiller Anruf.
struct CallStartOverlay: View {
    let title: String
    let withVideo: Bool
    let onStart: (Bool) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }
            VStack(spacing: 22) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                HStack(spacing: 44) {
                    Button {
                        onStart(false)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: withVideo ? "video.fill" : "phone.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(Circle().fill(Color.green))
                            Text(NSLocalizedString("_link_start_call_", comment: ""))
                                .font(.caption)
                        }
                    }
                    Button {
                        onStart(true)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "bell.slash.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(Circle().fill(Color.orange))
                            Text(NSLocalizedString("_link_silent_call_", comment: ""))
                                .font(.caption)
                        }
                    }
                }
                Button(NSLocalizedString("_cancel_", comment: "")) {
                    onCancel()
                }
                .foregroundStyle(.secondary)
            }
            .padding(26)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
            .padding(32)
        }
    }
}

/// Emoji-Auswahl für Reaktionen (langes Drücken auf eine Nachricht).
/// Run-Vorgaben: max. eine eigene Reaktion (bestehende wird beim Wählen
/// eines anderen Emojis überschrieben) und die Option, die eigene Reaktion
/// wieder zu entfernen (destruktive Rolle, Apple-Doku ButtonRole).
struct EmojiReactionOverlay: View {
    var ownReaction: String? = nil
    let onPick: (String) -> Void
    var onRemove: () -> Void = {}
    let onCancel: () -> Void

    private let emojis = ["👍", "❤️", "😂", "🎉", "😮", "😢", "🙏", "🔥"]

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }
            VStack(spacing: 10) {
                // Passt die Reihe -> einzeilig, sonst automatisch 2 Reihen à 4
                // (kompakt, läuft nie über den Bildschirmrand).
                ViewThatFits(in: .horizontal) {
                    emojiRow(Array(emojis))
                    compactGrid
                }
                if let ownReaction {
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label(
                            String(format: NSLocalizedString("_link_reaction_remove_", comment: ""), ownReaction),
                            systemImage: "trash"
                        )
                        .font(.subheadline.weight(.medium))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        }
    }

    private func emojiButton(_ emoji: String) -> some View {
        Button {
            onPick(emoji)
        } label: {
            Text(emoji)
                .font(.system(size: 22))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(.secondarySystemBackground)))
                .overlay {
                    if emoji == ownReaction {
                        // Eigene Reaktion: Ring als Kennung.
                        Circle().stroke(Color(NCBrandColor.shared.customer), lineWidth: 2.5)
                    }
                }
        }
    }

    private func emojiRow(_ items: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { emoji in
                emojiButton(emoji)
            }
        }
    }

    private var compactGrid: some View {
        VStack(spacing: 6) {
            emojiRow(Array(emojis.prefix(4)))
            emojiRow(Array(emojis.suffix(4)))
        }
    }
}

/// Payload für das iOS-Teilen-Sheet (UIActivityViewController).
struct SouveraSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// UIActivityViewController-Wrapper: das typische iOS-Teilen-Menü.
struct SouveraShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}


// MARK: - Chat-Scroll-Steuerung (A: ScrollPosition-Struct-API)





/// Lobby-Verwaltung (Run 15.09.): Teilnehmer gruppiert nach Status
/// (aktiv im Call / wartend in der Lobby / offline), mit Entfernen- und
/// "Alle zulassen"-Aktion. Auto-Refresh alle 5 s.
/// Presence-Mapping (Run 15.09.): Nextcloud-Benutzer-Status ->
/// Farbe/Label - geteilt vom Online-Status-Button (Header) und der
/// Lobby-Verwaltung.
enum LinkPresence {
    static func color(for status: String?) -> Color {
        switch status {
        case "online": return .green
        case "away": return .yellow
        case "dnd", "busy": return .red
        default: return Color(.systemGray)
        }
    }

    /// Offizielle Nextcloud-Status-Icons (Run 15.09.): grüner Haken =
    /// Online, gelber Mond = Abwesend, roter Kreis = Beschaeftigt,
    /// roter Kreis mit Minus = Nicht stoeren, grauer Kreis = Unsichtbar.
    static func symbol(for status: String?) -> Image {
        switch status {
        case "online": return Image(systemName: "checkmark.circle.fill")
        case "away": return Image(systemName: "moon.circle.fill")
        case "busy": return Image(systemName: "circle.fill")
        case "dnd": return Image(systemName: "minus.circle.fill")
        default: return Image(systemName: "circle")
        }
    }

    static func label(for status: String?) -> String {
        switch status {
        case "online": return NSLocalizedString("_online_", comment: "")
        case "away": return NSLocalizedString("_away_", comment: "")
        case "dnd": return NSLocalizedString("_dnd_", comment: "")
        case "busy": return NSLocalizedString("_busy_", comment: "")
        default: return NSLocalizedString("_offline_", comment: "")
        }
    }

    /// Sattes, deutliches Farbschema (kein systemYellow/-Green - die sind
    /// auf hellem Grund zu blass; Run 15.09., Feedback "klare Farben").
    static func vividColor(for status: String?) -> Color {
        switch status {
        case "online": return Color(red: 0.18, green: 0.72, blue: 0.27)   // #2EB845
        case "away": return Color(red: 0.96, green: 0.65, blue: 0.14)     // #F5A623
        case "dnd", "busy": return Color(red: 0.86, green: 0.16, blue: 0.16) // #DB2929
        default: return Color(red: 0.55, green: 0.57, blue: 0.60)         // grau
        }
    }

    /// Kleine Status-Pill (NC-Icon in Vollfarbe, opak-weisser Ring) - das
    /// Element darf NIE abgeschnitten werden, darum ohne Offset ausserhalb
    /// von Grenzen einsetzen (in ZStack bottomTrailing).
    static func statusPill(for status: String?, size: CGFloat) -> some View {
        symbol(for: status)
            .font(.system(size: size, weight: .bold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(vividColor(for: status))
            .background(
                Circle()
                    .fill(Color.white)
                    .frame(width: size + 5, height: size + 5)
            )
            .frame(width: size + 5, height: size + 5)
    }
}

/// Online-Status-Button (Run 15.09.): runder Material-Button mit
/// Presence-Dot an der Kante (Avatar-Muster aus den Kontoeinstellungen).
/// Tap oeffnet den bestehenden Status-Picker.
private struct LinkOnlineStatusButton: View {
    let status: String?
    let action: () -> Void

    var body: some View {
        // Header-Button (Run 15.09., 2. Runde): Person-Icon zentriert im
        // festen Frame, Status-Pill INNERHALB der Grenzen unten rechts -
        // nichts wird abgeschnitten. Satte Vollfarben, opak-weisser Ring.
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Self.darkIcon)
                    .frame(width: 30, height: 30)
                LinkPresence.statusPill(for: status, size: 13)
            }
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("_set_user_status_", comment: ""))
    }

    private static let darkIcon = Color(red: 0.1, green: 0.1, blue: 0.1)
}

/// Lobby-Verwaltung (Run 15.09., neu): Mitgliedschafts-basierte
/// Gruppierung - "Teilnehmer" = alle eingeladenen/zugeordneten internen
/// Teilnehmer (mit Presence-Status) + zugelassene externe; "Warten in
/// der Lobby" = wartende externe Teilnehmer mit Einzel-Zulassen.
/// Leere Sektionen werden nicht gerendert. Auto-Refresh 2 s, plus
/// Signaling-getriggerter Sofort-Refresh (onParticipantsChanged).
private struct LinkLobbyManagementView: View {
    @ObservedObject var viewModel: LinkViewModel
    let room: LinkConversation
    @Environment(\.dismiss) private var dismiss
    @State private var refreshTask: Task<Void, Never>?
    @State private var workingAttendee: Int?

    /// Klassifizierung nach Talk-Konstanten (Run 15.09., verified gegen
    /// nextcloud/spreed constants.md): participantType 1 Owner, 2 Moderator,
    /// 3 User, 4 Guest, 5 User following a public link, 6 Guest with
    /// moderator permissions.
    private static func isModerator(_ p: LinkParticipant) -> Bool {
        [1, 2, 6].contains(p.participantType)
    }

    /// Intern: eingeladene Konten der Instanz (Owner/Moderator/User) und
    /// registrierte User, die per Link beigetreten sind (type 5).
    private static func isInternal(_ p: LinkParticipant) -> Bool {
        [1, 2, 3].contains(p.participantType)
            || (p.participantType == 5 && p.actorType == "users")
    }

    private var internalParticipants: [LinkParticipant] {
        viewModel.participants.filter { Self.isInternal($0) || Self.isModerator($0) }
    }

    /// Zugelassene externe Teilnehmer (nicht mehr wartend).
    private var admittedExternals: [LinkParticipant] {
        viewModel.participants.filter {
            !Self.isInternal($0) && !Self.isModerator($0) && $0.inCall != 0
        }
    }

    /// Wartende externe Lobby-Teilnehmer - NIE Moderatoren oder interne.
    private var waitingExternals: [LinkParticipant] {
        viewModel.participants.filter {
            !Self.isInternal($0) && !Self.isModerator($0) && $0.inCall == 0
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !internalParticipants.isEmpty || !admittedExternals.isEmpty {
                    Section(NSLocalizedString("_lobby_section_participants_", comment: "")) {
                        ForEach(internalParticipants) { participant in
                            participantRow(participant)
                        }
                        ForEach(admittedExternals) { participant in
                            participantRow(participant)
                        }
                    }
                }

                if !waitingExternals.isEmpty {
                    Section(NSLocalizedString("_lobby_section_waiting_", comment: "")) {
                        ForEach(waitingExternals) { participant in
                            participantRow(participant, waiting: true)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        removeParticipant(participant)
                                    } label: {
                                        Label(NSLocalizedString("_link_participant_remove_", comment: ""), systemImage: "person.crop.circle.badge.minus")
                                    }
                                }
                        }
                        Button {
                            Task { await viewModel.setLobbyEnabled(false, token: room.token) }
                        } label: {
                            Label(NSLocalizedString("_lobby_admit_all_", comment: ""), systemImage: "person.checkmark")
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("_link_lobby_title_", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(NSLocalizedString("_close_", comment: ""))
                }
            }
            .onAppear {
                viewModel.loadParticipants()
                viewModel.loadUserStatuses()
                refreshTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard !Task.isCancelled else { return }
                        viewModel.loadParticipants()
                        viewModel.loadUserStatuses()
                    }
                }
            }
            .onDisappear {
                refreshTask?.cancel()
            }
        }
    }

    /// Presence-Status des Teilnehmers (nur bekannte User-Accounts).
    private func userStatus(_ participant: LinkParticipant) -> String? {
        guard participant.actorType == "users" else { return nil }
        // Primaer der Teilnehmer-Status aus der API (includeStatus=true,
        // echtes DND sofort); Bulk-Fetch nur Fallback (Run 15.09.).
        if let status = participant.status, !status.isEmpty {
            return status
        }
        return viewModel.userStatuses[participant.actorId] ?? "offline"
    }

    /// Statuszeile: Presence (+ "im Anruf", der Call ist optional).
    private func statusLine(_ participant: LinkParticipant) -> String? {
        var parts: [String] = []
        if let status = userStatus(participant) {
            parts.append(LinkPresence.label(for: status))
        }
        if participant.inCall != 0 {
            parts.append(NSLocalizedString("_lobby_status_in_call_", comment: ""))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private func participantRow(_ participant: LinkParticipant, waiting: Bool = false) -> some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    Circle().fill(Color.Souvera.brandPrimaryDeep)
                    Text(initials(displayName(participant)))
                        .font(.caption2).foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)
                // NC-Status-Pill an der Kante (Avatar-Muster, Run 15.09.):
                // satte Vollfarben, opak-weisser Ring - keine Transparenz.
                LinkPresence.statusPill(for: userStatus(participant), size: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(participant))
                    .lineLimit(1)
                if let email = emailLine(participant) {
                    Text(email)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let line = statusLine(participant) {
                    Text(line)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if workingAttendee == participant.attendeeId {
                ProgressView()
            } else if waiting {
                // Run 15.09.: nur der gruene "Zulassen"-Button - Entfernen
                // kommt als Swipe-Geste (volles Design).
                Button {
                    admit(participant)
                } label: {
                    // Gueltiges SF-Symbol (person.badge.checkmark
                    // existiert nicht - der Button war unsichtbar).
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .foregroundStyle(.green)
                }
                .accessibilityLabel(NSLocalizedString("_lobby_admit_one_", comment: ""))
            }
        }
    }

    /// Externe Teilnehmer (guests/emails) - interne sind die
    /// eingeladenen Owner/Moderator/User-Konten.
    private func isExternal(_ participant: LinkParticipant) -> Bool {
        participant.actorType == "guests" || participant.actorType == "emails"
    }

    /// Signaling-User-Daten des Teilnehmers (ueber sessionIds gemappt):
    /// Klartext-Name/E-Mail von Gaesten - die OCS-Liste liefert fuer
    /// E-Mail-Teilnehmer nur den SHA-256-Hash der Adresse (Run 15.09.).
    private func signalingInfo(_ participant: LinkParticipant) -> LinkSignalingUserInfo? {
        for sid in participant.sessionIds {
            if let info = viewModel.signalingUsers[sid] {
                return info
            }
        }
        return nil
    }

    /// Namens-Anzeige (Run 15.09., Talk-Web-Logik): Gaeste ohne Namen
    /// heissen "Gast" - NIEMALS der kryptische Session-Hash. User mit
    /// leerem Namen fallen auf die actorId zurueck.
    private func displayName(_ participant: LinkParticipant) -> String {
        if let info = signalingInfo(participant), let name = info.displayName, !name.isEmpty {
            return name
        }
        if !participant.displayName.isEmpty { return participant.displayName }
        if isExternal(participant) {
            return NSLocalizedString("_link_guest_", comment: "")
        }
        if !participant.actorId.isEmpty { return participant.actorId }
        return NSLocalizedString("_link_lobby_unknown_", comment: "")
    }

    /// Zweite Zeile: E-Mail-Adresse. Quelle 1: Signaling-User-Daten
    /// (Klartext). Quelle 2: actorId, WENN sie eine E-Mail ist ("@") -
    /// sonst nichts (niemals einen Hash zeigen).
    private func emailLine(_ participant: LinkParticipant) -> String? {
        if let info = signalingInfo(participant), let email = info.email, !email.isEmpty {
            return email
        }
        guard participant.actorType == "emails", !participant.actorId.isEmpty,
              participant.actorId.contains("@") else { return nil }
        return participant.actorId
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined().uppercased()
    }

    private func admit(_ participant: LinkParticipant) {
        workingAttendee = participant.attendeeId
        Task {
            let ok = await viewModel.admitParticipant(participant, token: room.token)
            await MainActor.run {
                workingAttendee = nil
                if ok { viewModel.loadParticipants() }
            }
        }
    }

    private func removeParticipant(_ participant: LinkParticipant) {
        workingAttendee = participant.attendeeId
        viewModel.removeParticipant(participant)
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                workingAttendee = nil
            }
        }
    }
}
