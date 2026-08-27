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
    @State private var callContext: CallContext?
    @State private var showCallBanner = false
    @State private var returnToCall = false
    @State private var showCreateChannel = false
    @State private var channelName = ""
    @State private var showAddParticipant = false
    @State private var startCallRequest: CallStartRequest?
    @State private var showParticipants = false
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
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if case let .chat(token, title) = viewModel.route {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                viewModel.back()
                            } label: {
                                Image(systemName: "chevron.backward")
                                    .frame(width: 28, height: 28)
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                viewModel.loadParticipants()
                                showParticipants = true
                            } label: {
                                Image(systemName: "person.2")
                            }
                            .accessibilityLabel(NSLocalizedString("_link_participants_", comment: ""))
                        }
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            if viewModel.currentRoom?.hasCall == true {
                                // Läuft im Raum bereits ein Call: direkt
                                // teilnehmen statt neu anzurufen.
                                Button {
                                    callContext = CallContext(token: token, title: title, withVideo: false, silent: false)
                                } label: {
                                    Label(NSLocalizedString("_link_join_call_", comment: ""), systemImage: "phone.fill.arrow.up.right")
                                        .foregroundStyle(.green)
                                        .labelStyle(.titleAndIcon)
                                }
                            } else {
                                Button {
                                    startCallRequest = CallStartRequest(token: token, title: title, withVideo: false)
                                } label: {
                                    Image(systemName: "phone.fill").foregroundStyle(.green)
                                }
                                Button {
                                    startCallRequest = CallStartRequest(token: token, title: title, withVideo: true)
                                } label: {
                                    Image(systemName: "video.fill").foregroundStyle(Color(NCBrandColor.shared.customer))
                                }
                            }
                        }
                    }
                    if case .home = viewModel.route {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                channelName = ""
                                showCreateChannel = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel(NSLocalizedString("_link_create_channel_", comment: ""))
                        }
                    }
                }
        }
        .onAppear {
            viewModel.start()
            viewModel.reconnectSignalingIfNeeded()
            viewModel.startRoomPolling()
            // Ein von außen angeforderter Raum wird nur geöffnet, wenn der
            // Nutzer nicht bereits in einem Chat navigiert (sonst würde die
            // Route mitten in der Bedienung überschrieben).
            if let pending = LinkViewModel.pendingOpenRoom, case .home = viewModel.route {
                LinkViewModel.pendingOpenRoom = nil
                viewModel.openConversation(token: pending.token, title: pending.title)
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
        .souveraCacheBanner(active: $viewModel.cacheBannerActive)
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
        .fullScreenCover(item: $viewModel.incomingCallRoom) { room in
            IncomingCallOverlayView(
                title: room.displayName,
                hasVideo: false,
                onAccept: {
                    viewModel.dismissIncomingCall()
                    callContext = CallContext(token: room.token, title: room.displayName, withVideo: false, silent: false)
                },
                onDecline: {
                    viewModel.dismissIncomingCall()
                },
                onMinimize: {
                    viewModel.minimizeIncomingCall()
                }
            )
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

    private var navigationTitle: String {
        if case let .chat(_, title) = viewModel.route { return title }
        return NSLocalizedString("_link_", comment: "")
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.route {
        case .home:
            LinkConversationListView(viewModel: viewModel) { room in
                callContext = CallContext(token: room.token, title: room.displayName, withVideo: false, silent: false)
            }
        case let .chat(token, title):
            LinkChatView(viewModel: viewModel, token: token, title: title)
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
    @State private var searchQuery = ""
    @State private var deleteRoom: LinkConversation?
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
        List {
            if let offlineNotice = viewModel.offlineNotice {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                        Text(offlineNotice).font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
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
        .searchable(text: $searchQuery, prompt: NSLocalizedString("_link_search_people_", comment: ""))
        .onChange(of: searchQuery) { _, newValue in
            viewModel.searchUsers(query: newValue)
        }
        .refreshable { viewModel.loadConversations() }
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
                Circle().fill(Color(NCBrandColor.shared.customer)).frame(width: 44, height: 44)
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
                    .offset(x: 3, y: 3)
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
    /// sichtbarer Sprung).
    @State private var chatPositioned = false
    /// "Runter zu den neuesten Nachrichten"-Button sichtbar (hochgescrollt)?
    @State private var showScrollBottom = false

    var body: some View {
        VStack(spacing: 0) {
            messageList
                .fullScreenCover(item: $fullscreenImageMessage) { target in
                    LinkImageViewer(
                        title: target.fileInfo()?.name ?? "",
                        imageData: viewModel.chatImageCache[target.id]
                    )
                }
            Divider()
            composer
        }
        .offset(x: backDragOffset)
        .gesture(edgeSwipeBack)
        .overlay {
            if let target = reactionTarget {
                EmojiReactionOverlay(
                    onPick: { emoji in
                        viewModel.toggleReaction(message: target, emoji: emoji)
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

    private func showsDaySeparator(index: Int, message: LinkChatMessage) -> Bool {
        guard index > 0 else { return true }
        let previous = visibleItems[index - 1]
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
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
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
            ScrollViewReader { proxy in
                List {
                    // Sentinel oben: lädt ältere Nachrichten nach, falls der
                    // Historie-Loop noch nicht fertig ist (kein Paging-UI).
                    if viewModel.hasMoreHistory {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                        .onAppear { viewModel.loadEarlierHistory() }
                    }
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, message in
                        // Tageswechsel-Trennlinie (P68j): vor der ersten
                        // Nachricht eines neuen Kalendertags.
                        if showsDaySeparator(index: index, message: message) {
                            daySeparatorRow(for: message.timestamp)
                        }
                        // "Neue Nachrichten"-Trennlinie vor der ersten
                        // ungelesenen Nachricht (Talk-Standard).
                        if !viewModel.hideUnreadSeparator,
                           viewModel.unreadBoundary == message.id {
                            unreadSeparatorRow
                        }
                        if message.isSystemMessage {
                            LinkSystemMessageRow(message: message)
                                .id(message.id)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                                .listRowBackground(Color.clear)
                        } else {
                            LinkMessageRow(
                                viewModel: viewModel,
                                message: message,
                                isOwn: message.actorId == viewModel.currentUserId,
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
                                onStartReply: { replyingTo = message },
                                onStartForward: { forwardTarget = message },
                                onLongPress: { target in reactionTarget = target },
                                onShare: { target in prepareShare(for: target) }
                            )
                            .id(message.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                            .listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Chat-Standard: Liste bleibt bei neuen Nachrichten unten;
                // das Nachladen älterer Nachrichten oben reißt die
                // Leseposition nicht mit. Die EINTRITTSPOSITION setzt
                // scrollPosition(id:) deterministisch (Trennlinie bzw.
                // Ende), bevor die Liste sichtbar wird - kein sichtbares
                // Scrollen beim Raumeintritt.
                .defaultScrollAnchor(.bottom)
                .overlay(alignment: .bottom) {
                    // "Zu den neuesten Nachrichten"-Button (Design-Pendant
                    // zum Mail-Up-Pfeil): fade-in nur, wenn man zu älteren
                    // Nachrichten hochgescrollt ist.
                    if let lastId = items.last?.id {
                        scrollBottomButton(proxy: proxy, lastId: lastId)
                            .padding(.bottom, 16)
                            .opacity(showScrollBottom ? 1 : 0)
                            .animation(.easeInOut(duration: 0.25), value: showScrollBottom)
                    }
                }
                .modifier(SouveraScrollBottomObserver { visible in
                    if visible != showScrollBottom {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showScrollBottom = visible
                        }
                    }
                    // Am Ende angekommen: Trennlinie ausblenden + Read-Marker.
                    if !visible {
                        viewModel.noteScrolledToNewest()
                    }
                })
                .onChange(of: token) { _, _ in
                    chatPositioned = false
                    showScrollBottom = false
                }
                // Position-vor-Sichtbarkeit: EINMALIG unsichtbar an die
                // Trennlinie (ungelesen) bzw. ans Ende (keine Ungelesenen)
                // springen, danach einblenden. Die Boundary kann erst nach
                // dem Cache-Publish eintreffen - onChange positioniert
                // daher solange nach, bis eingeblendet wird. Kein
                // scrollPosition-Modifier: der hatte den Bottom-Anchor
                // neutralisiert.
                .opacity(chatPositioned ? 1 : 0)
                .onAppear {
                    guard !chatPositioned else { return }
                    positionChat(proxy: proxy, items: items)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        chatPositioned = true
                    }
                }
                .onChange(of: viewModel.unreadBoundary) { _, _ in
                    guard !chatPositioned else { return }
                    positionChat(proxy: proxy, items: items)
                }
            }
        }
    }

    /// Dezente Trennlinie "Neue Nachrichten" (Talk-Standard).
    private var unreadSeparatorRow: some View {
        HStack(spacing: 10) {
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
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
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

    /// Setzt die Eintrittsposition: mit Ungelesenen an die Trennlinie
    /// (oben), sonst an die neueste Nachricht (unten).
    private func positionChat(proxy: ScrollViewProxy, items: [LinkChatMessage]) {
        if let boundary = viewModel.unreadBoundary {
            proxy.scrollTo(boundary, anchor: .top)
        } else if let lastId = items.last?.id {
            proxy.scrollTo(lastId, anchor: .bottom)
        }
    }

    /// "Runter zu den neuesten Nachrichten": identisches Design wie der
    /// Mail-Up-Pfeil (Kreis, Material, Schatten), Icon arrow.down.
    private func scrollBottomButton(proxy: ScrollViewProxy, lastId: Int64) -> some View {
        Button {
            withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
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

    /// Beobachtet den Abstand zum unteren Listenende (iOS 18+): meldet
    /// `true`, sobald man mehr als 120 px von den neuesten Nachrichten
    /// entfernt ist (Button "runter" wird eingeblendet). Unter iOS 18:
    /// kein Callback.
    private struct SouveraScrollBottomObserver: ViewModifier {
        let onChange: (Bool) -> Void

        func body(content: Content) -> some View {
            if #available(iOS 18.0, *) {
                content.onScrollGeometryChange(for: ScrollGeometry.self) { geometry in
                    geometry
                } action: { _, geometry in
                    let bottomDistance = geometry.contentSize.height
                        - geometry.contentInsets.bottom
                        - (geometry.contentOffset.y + geometry.containerSize.height)
                    onChange(bottomDistance > 120)
                }
            } else {
                content
            }
        }
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
            if editingMessage != nil {
                HStack {
                    Text(NSLocalizedString("_link_edit_message_", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(NSLocalizedString("_cancel_", comment: "")) {
                        editingMessage = nil
                        draft = ""
                    }
                    .font(.caption)
                    Button(NSLocalizedString("_contact_save_", comment: "")) {
                        if let message = editingMessage {
                            viewModel.editMessage(message, text: draft)
                            editingMessage = nil
                            draft = ""
                        }
                    }
                    .font(.caption).bold()
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                Divider()
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
            HStack(spacing: 8) {
            Menu {
                Button {
                    showFilePicker = true
                } label: {
                    Label(NSLocalizedString("_link_attach_file_", comment: ""), systemImage: "doc.badge.plus")
                }
                Button {
                    showPhotoPicker = true
                } label: {
                    Label(NSLocalizedString("_link_attach_photos_", comment: ""), systemImage: "photo.on.rectangle")
                }
                Button {
                    showNextcloudPicker = true
                } label: {
                    Label(NSLocalizedString("_link_share_file_", comment: ""), systemImage: "building.columns")
                }
            } label: {
                Image(systemName: "paperclip")
                    .foregroundStyle(Color(NCBrandColor.shared.customer))
                    .frame(width: 30, height: 30)
            }
            TextField(NSLocalizedString("_link_message_", comment: ""), text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
            Button {
                let text = draft
                let replyTarget = replyingTo?.id
                draft = ""
                replyingTo = nil
                viewModel.send(text: text, replyTo: replyTarget)
            } label: {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color(NCBrandColor.shared.customer))
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
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
    var showTime: Bool = true
    var showsAvatar: Bool = true
    let onStartEdit: () -> Void
    let onFileTap: (LinkFileInfo) -> Void
    /// P68k: Tap auf ein Inline-Bild -> Vollbild-Viewer.
    var onImageTap: (LinkChatMessage) -> Void = { _ in }
    let onStartReply: () -> Void
    let onStartForward: () -> Void
    var onLongPress: (LinkChatMessage) -> Void = { _ in }
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

    /// Emoji-Reaktions-Pills, halb überlappend am unteren Bubble-Rand.
    @ViewBuilder
    private func reactionPills(message: LinkChatMessage) -> some View {
        HStack(spacing: 4) {
            ForEach(message.reactions.sorted(by: { $0.key < $1.key }), id: \.key) { emoji, count in
                Text("\(emoji) \(count)")
                    .font(.caption2)
                    .foregroundStyle(message.reactionsSelf.contains(emoji) ? .white : .primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(message.reactionsSelf.contains(emoji)
                            ? Color.orange.opacity(0.95)
                            : Color(.secondarySystemBackground))
                    )
                    .overlay(
                        Capsule().stroke(message.reactionsSelf.contains(emoji) ? Color.orange : .clear, lineWidth: 1)
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
                Circle().fill(Color(NCBrandColor.shared.customer))
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
            .frame(maxWidth: 230, alignment: .leading)
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
                if let file = message.fileInfo(), !viewModel.isImageMessage(message) {
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
                        onImageTap: { onImageTap(message) }
                    )
                    .task {
                        if viewModel.isImageMessage(message) {
                            await viewModel.loadChatImage(for: message)
                        }
                    }
                        .overlay(alignment: isOwn ? .bottomTrailing : .bottomLeading) {
                            // Reaktionen leicht überlappend am unteren Bubble-Rand,
                            // etwas eingerückt (nicht ganz bündig mit der Kante),
                            // ohne den Nachrichtentext zu verdecken.
                            if !message.reactions.isEmpty {
                                reactionPills(message: message)
                                    .offset(x: isOwn ? -6 : 6, y: 10)
                            }
                        }
                    if !isOwn { Spacer(minLength: 40) }
                }
                // Mit Reaktionen hängen die Pills über die Unterkante - der
                // Zeitstempel der nächsten Nachricht braucht dann mehr Abstand.
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
                    viewModel.deleteMessage(message)
                } label: {
                    Label(NSLocalizedString("_delete_", comment: ""), systemImage: "trash")
                }
                .tint(.red)
                Button {
                    onStartEdit()
                } label: {
                    Label(NSLocalizedString("_contact_edit_", comment: ""), systemImage: "pencil")
                }
                .tint(.blue)
            }
        }
    }
}

private struct LinkMessageBubble: View {
    let message: LinkChatMessage
    let isOwn: Bool
    /// P68k: Bildnachricht (Bild + Caption IN der Bubble, einheitliche Optik).
    var isImageMessage: Bool = false
    var imageData: Data?
    var onImageTap: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !isOwn {
                Text(message.actorDisplayName).font(.caption2).foregroundStyle(.secondary)
            }
            if isImageMessage {
                imageContent
                // Optionaler Text des Absenders unter dem Bild.
                if let caption = message.fileCaption() {
                    Text(caption)
                        .souveraOpenURLAction()
                }
            } else if message.fileName() != nil {
                Text(displayText)
            } else {
                Text(message.attributedDisplayText())
                    .souveraOpenURLAction()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isOwn ? Color(NCBrandColor.shared.customer).opacity(0.9) : Color(.secondarySystemBackground))
        )
        .foregroundStyle(isOwn ? .white : .primary)
    }

    /// Bild im Bubble (Tap -> Vollbild), mit Lade-Platzhalter.
    @ViewBuilder
    private var imageContent: some View {
        if let imageData, !imageData.isEmpty, let ui = UIImage(data: imageData) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onTapGesture { onImageTap() }
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
                        ForEach(viewModel.participants.filter { $0.actorType != "deleted_users" }) { participant in
                            HStack(spacing: 10) {
                                Image(systemName: participantIcon(participant.actorType))
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(participant.displayName).font(.subheadline)
                                    if participant.participantType == 1 || participant.participantType == 2 {
                                        Text(NSLocalizedString("_link_participant_moderator_", comment: ""))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
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
            .sheet(item: $viewModel.externalInviteContext) { context in
                ExternalInviteSheet(context: context)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("_cancel_", comment: "")) { dismiss() }
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

    private func participantIcon(_ actorType: String) -> String {
        switch actorType {
        case "guests": return "person.crop.circle.badge.questionmark"
        case "federated_users": return "globe"
        case "emails": return "envelope"
        default: return "person.crop.circle"
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
struct EmojiReactionOverlay: View {
    let onPick: (String) -> Void
    let onCancel: () -> Void

    private let emojis = ["👍", "❤️", "😂", "🎉", "😮", "😢", "🙏", "🔥"]

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }
            // Passt die Reihe -> einzeilig, sonst automatisch 2 Reihen à 4
            // (kompakt, läuft nie über den Bildschirmrand).
            ViewThatFits(in: .horizontal) {
                emojiRow(Array(emojis))
                compactGrid
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
