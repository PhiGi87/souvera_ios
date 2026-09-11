/*
 SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
 SPDX-License-Identifier: GPL-2.0-or-later
*/

import SwiftUI
import UIKit

/// Ein Element der Chat-Liste: GLOBALE Index-Position in `visibleItems`
/// (für die Tages-/Zeit-/Avatar-Logik) plus Nachricht.
struct LinkChatListItem: Identifiable, Equatable {
    let globalIndex: Int
    let message: LinkChatMessage
    var id: Int64 { message.id }

    static func == (lhs: LinkChatListItem, rhs: LinkChatListItem) -> Bool {
        lhs.globalIndex == rhs.globalIndex && lhs.message.id == rhs.message.id
    }
}

/// UIKit-Chat-Liste (Run 11.09., zweiphasig, Diffable): Die Liste zeigt AB
/// DEM EINTRITT nur das Initialfenster (neueste Seite inkl. aller
/// Ungelesenen, per bewährtem KVO-stabilisiertem Eintritts-Scroll
/// positioniert) und wächst erst NACH dem Settle, wenn
/// `loadRemainingHistoryInBackground` die älteren Batches liefert. Jeder
/// Batch wird per `NSDiffableDataSourceSnapshot` als Insert OBERHALB des
/// sichtbaren Bereichs angewendet - die Datenquelle berechnet die
/// Manipulationen garantiert gültig (keine
/// Invalid-Batch-Updates-Crashklasse) und UICollectionView hält die
/// sichtbaren Zeilen bei Insertionen darüber an Ort und Stelle: kein
/// Sprung, kein Drift, ruhiges Hochscrollen in die wachsende Historie.
///
/// Abschnitt 0 = Header-Zelle (Lade-Spinner / "Anfang der Unterhaltung",
/// steht IM Scroll-Inhalt am Verlaufskopf - nie über Text), Abschnitt 1 =
/// Nachrichten. Die Zeilen-Inhalte bleiben SwiftUI über
/// UIHostingConfiguration (iOS 16+, dokumentiert).
    private enum EntryTarget {
        case bottom
        /// Boundary als Message-ID (nicht Index): Phase-1-Updates und
        /// Verlaufs-Prepends verschieben Indizes, die ID bleibt stabil.
        case separator(id: Int64)
    }

@MainActor
final class LinkChatListController: NSObject, ObservableObject {

    enum Section: Int, Hashable {
        case header
        case messages
    }

    /// Diffable-Item: Header-Kennung oder Nachrichten-ID.
    enum ListItem: Hashable {
        case header
        case message(id: Int64)
    }

    private static let headerSection = Section.header
    private static let messageSection = Section.messages

    // MARK: - Vom SwiftUI-Host gesetzte Eingänge (je Update)

    private(set) var items: [LinkChatListItem] = []
    private var isLoadingHistory = false
    private var rowProvider: ((Int) -> AnyView)?
    private var onDistanceChanged: ((_ distanceToBottom: CGFloat) -> Void)?
    private var viewModel: LinkViewModel?
    private var onEntrySettled: (() -> Void)?
    private var onRequestOlder: (() -> Void)?

    // MARK: - Interner Zustand

    private weak var collectionView: UICollectionView?
    private var dataSource: UICollectionViewDiffableDataSource<Section, ListItem>?
    private var contentSizeObservation: NSKeyValueObservation?
    private var lastRoomToken: String?
    private var pendingEntryBoundary: Int64?
    private var didInitialEntry = false
    /// Committete Nachrichten-IDs (aufsteigend, wie `items`).
    private var committedIds: [Int64] = []

    // Eintritts-Stabilisierung
    private var isEntryStabilizing = false
    private var entryTarget: EntryTarget = .bottom
    private var lastStableContentHeight: CGFloat = -1
    private var stableSizeCount = 0
    private var entryTimeoutTask: Task<Void, Never>?
    /// Startzeit des Eintritts: das Settle braucht eine Mindestdauer,
    /// sonst feuert es, bevor die Self-Sizing-Hoehen real sind (Log
    /// 11.09.: "entry scroll" und "settled" in derselben Millisekunde).
    private var entryStartTime: CFTimeInterval = 0
    /// Korrektur-Paesse (+0,15/+0,35/+0,7 s): fahren das Eintrittsziel
    /// erneut an, bis die Hoehen real sind (talk-ios: wiederholtes
    /// scrollToRow bis die Position haelt). Tasks statt DispatchWorkItem:
    /// erben die MainActor-Isolation der Klasse und sind cancel-bar.
    private var entryRescrollTasks: [Task<Void, Never>] = []
    /// Content-Signatur des letzten Updates: Aendert sich der Zellinhalt
    /// relevante ViewModel-Stand (Bilder/PDF geladen, Boundary, ...) bei
    /// UNVERAENDERTEN IDs, werden die sichtbaren Zellen rekonfiguriert -
    /// Diffable fasst unveranderte Items sonst nie wieder an und die
    /// Zelleninhalte blieben eingefroren (Platzhalter "Bild wird
    /// geladen...", alte Gruppierung, Run-Feedback 11.09.).
    private var lastContentSignature: Int = 0
    /// Cooldown fuer Batch-Publikationen am Verlaufskopf.
    private var lastOlderRequestAt: CFTimeInterval = 0

    // MARK: - Update vom SwiftUI-Host

    func update(items: [LinkChatListItem],
                roomToken: String,
                unreadBoundary: Int64?,
                isLoadingHistory: Bool,
                viewModel: LinkViewModel,
                rowProvider: @escaping (Int) -> AnyView,
                onDistanceChanged: @escaping (CGFloat) -> Void,
                onEntrySettled: @escaping () -> Void,
                onRequestOlder: @escaping () -> Void) {
        let roomChanged = roomToken != lastRoomToken
        if roomChanged {
            lastRoomToken = roomToken
            didInitialEntry = false
            pendingEntryBoundary = unreadBoundary
            committedIds = []
            // Laufende Eintritts-Phase des VORHERIGEN Raums beenden.
            cancelEntryRescrollPasses()
            isEntryStabilizing = false
            entryTarget = .bottom
            entryTimeoutTask?.cancel()
            entryTimeoutTask = nil
            lastContentSignature = 0
        }
        self.items = items
        self.isLoadingHistory = isLoadingHistory
        self.viewModel = viewModel
        self.rowProvider = rowProvider
        self.onDistanceChanged = onDistanceChanged
        self.onEntrySettled = onEntrySettled
        self.onRequestOlder = onRequestOlder

        guard let dataSource else { return }

        // Header-Zelle NICHT per reconfigureItems anfassen: Der Aufruf
        // crashte (tf03/tf04: Assertion, wenn das Header-Item noch nicht
        // in der Collection View geladen ist). Die Zelle dequeue't beim
        // Erreichen des Verlaufskopfs neu; ihr Inhalt (LinkChatHeader-
        // Bubble) beobachtet das ViewModel reaktiv und ist damit
        // zustandsaktuell ohne manuelle Manipulation.

        let newIds = items.map(\.id)
        let signature = contentSignature()
        let contentChanged = signature != lastContentSignature
        lastContentSignature = signature
        if newIds == committedIds {
            // Struktur unverändert - aber Zellinhalt (Bilder/PDF/Boundary)
            // kann sich geaendert haben: sichtbare Zellen reaktiv
            // auffrischen.
            if contentChanged {
                reconfigureVisibleMessages()
            }
            return
        }

        // Reines Prepend? (aeltere Batches kommen nur on-demand am
        // Verlaufskopf via publishOlderBatch, bzw. waehrend der
        // Eintritts-Phase aus der Phase-1-Abdeckungskette.)
        let isPurePrepend = !committedIds.isEmpty
            && newIds.count > committedIds.count
            && Array(newIds.suffix(committedIds.count)) == committedIds

        applySnapshot(ids: newIds, isPrepend: isPurePrepend)

        if !didInitialEntry, !items.isEmpty {
            didInitialEntry = true
            DispatchQueue.main.async { [weak self] in
                self?.performEntryScroll()
            }
        }
    }

    // MARK: - Content-Reaktivitaet

    /// Billige Signatur allen zellrelevanten ViewModel-Stands (keine
    /// Inhalte selbst - nur Zaehler/IDs; O(1)).
    private func contentSignature() -> Int {
        guard let viewModel else { return 0 }
        var hash = 17
        if case let .success(msgs) = viewModel.messages {
            hash = hash &* 31 &+ msgs.count
            hash = hash &* 31 &+ Int(truncatingIfNeeded: msgs.last?.id ?? 0)
        }
        hash = hash &* 31 &+ viewModel.chatImageCache.count
        hash = hash &* 31 &+ viewModel.chatImageFailed.count
        hash = hash &* 31 &+ viewModel.chatPdfCache.count
        hash = hash &* 31 &+ Int(truncatingIfNeeded: viewModel.unreadBoundary ?? 0)
        hash = hash &* 31 &+ (viewModel.hideUnreadSeparator ? 1 : 0)
        hash = hash &* 31 &+ (viewModel.isLoadingHistory ? 1 : 0)
        return hash
    }

    /// Rekonfiguriert NUR die sichtbaren Nachrichten-Zellen (geladene
    /// Items - kein tf03/tf04-Risiko) per dokumentierter Diffable-API
    /// (snapshot.reconfigureItems). Ausreichend: Unsichtbare Zellen
    /// werden beim Scroll-Dequeue ohnehin frisch konfiguriert.
    private func reconfigureVisibleMessages() {
        guard let collectionView, let dataSource, !items.isEmpty else { return }
        let visibleIds = collectionView.indexPathsForVisibleItems
            .filter { $0.section == Self.messageSection.rawValue && $0.item < items.count }
            .map { ListItem.message(id: items[$0.item].message.id) }
        guard !visibleIds.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(visibleIds)
        dataSource.apply(snapshot, animatingDifferences: false)
        SouveraLog.write("LinkChat", "reconfigure visible cells: \(visibleIds.count)")
    }

    // MARK: - Snapshot-Anwendung

    private func applySnapshot(ids: [Int64], isPrepend: Bool = false) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, ListItem>()
        snapshot.appendSections([.header, .messages])
        snapshot.appendItems([.header], toSection: .header)
        snapshot.appendItems(ids.map { ListItem.message(id: $0) }, toSection: .messages)

        // Prepend: Inhaltshoehe vor/nach dem Apply messen und das Offset
        // um das Delta nachziehen (Stream-/Chat-SDK-Standard). KEIN Pin
        // mehr ueber absolute Frames: nach dem Einfuegen von ~100 Zellen
        // beruhen die Attribute auf Schaetzhoehen - der alte Pin rechnete
        // damit massiv falsch und der Offset wurde geclampt = Sprung zum
        // Gespraechsanfang (Log 11.09.: relative=-579, 3 Pins in 160ms).
        // Das Delta bleibt auf den Schaetzfehler beschraenkt und wird beim
        // Weiterscrollen von UIKit-Kalibrierung kontinuierlich aufgeloest.
        var oldContentHeight: CGFloat?
        var oldOffsetY: CGFloat?
        if isPrepend, !isEntryStabilizing, let collectionView {
            oldContentHeight = collectionView.contentSize.height
            oldOffsetY = collectionView.contentOffset.y
        }

        dataSource?.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self, self.committedIds == ids, let collectionView = self.collectionView else { return }
            guard let oldContentHeight, let oldOffsetY else { return }
            collectionView.layoutIfNeeded()
            let delta = collectionView.contentSize.height - oldContentHeight
            guard delta > 0 else { return }
            collectionView.contentOffset.y = oldOffsetY + delta
            SouveraLog.write("LinkChat", "re-anchor after history prepend (delta): +\(Int(delta))pt")
        }
        committedIds = ids
    }

    // MARK: - Öffentliche Scroll-Kommandos (SwiftUI -> UIKit)

    /// Eintritt: Ungelesen -> Trennlinie mittig (talk-ios .middle), sonst
    /// ans Listenende. Anschließend Stabilisierungs-Phase: Solange sich
    /// die Self-Sizing-Höhen noch ändern, wird das Ziel erneut angefahren.
    private func performEntryScroll() {
        guard let collectionView, !items.isEmpty else { return }
        cancelEntryRescrollPasses()
        isEntryStabilizing = true
        stableSizeCount = 0
        lastStableContentHeight = -1
        entryStartTime = CACurrentMediaTime()
        if let boundary = pendingEntryBoundary {
            // Ziel als ID: die Nachricht kann beim ersten Pass noch nicht
            // im Fenster sein (Phase-1-Kette publiziert nach) - die
            // Paesse stufen die Trennlinie nach, sobald sie da ist.
            entryTarget = .separator(id: boundary)
        } else {
            entryTarget = .bottom
        }
        scrollToEntryTarget()
        pendingEntryBoundary = nil
        [0.15, 0.35, 0.7].forEach { delay in
            entryRescrollTasks.append(Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let self, self.isEntryStabilizing else { return }
                self.scrollToEntryTarget()
                self.evaluateEntrySettle()
            })
        }
        startEntryTimeout()
    }

    /// Faehrt das Eintrittsziel an: Trennlinie (Index je Pass neu aus der
    /// Boundary-ID abgeleitet) oder Listenende.
    private func scrollToEntryTarget() {
        guard let collectionView, !items.isEmpty else { return }
        switch entryTarget {
        case .bottom:
            scrollToBottom(animated: false)
        case .separator(let id):
            if let index = items.firstIndex(where: { $0.message.id == id }) {
                collectionView.layoutIfNeeded()
                collectionView.scrollToItem(at: messageIndexPath(item: index),
                                            at: .centeredVertically, animated: false)
            } else {
                // Boundary (noch) nicht im Fenster: zunaechst ans Ende.
                scrollToBottom(animated: false)
            }
        }
    }

    /// Settle erst nach Mindestdauer UND stabiler Hoehe (behebt das
    /// Sofort-Settle desselben Millisekunden-Timestamps, Log 11.09.).
    private func evaluateEntrySettle() {
        guard isEntryStabilizing else { return }
        if stableSizeCount >= 2,
           CACurrentMediaTime() - entryStartTime >= 0.4 {
            finishEntryStabilization(reason: "stable")
        }
    }

    private func cancelEntryRescrollPasses() {
        entryRescrollTasks.forEach { $0.cancel() }
        entryRescrollTasks.removeAll()
    }

    private func startEntryTimeout() {
        entryTimeoutTask?.cancel()
        entryTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.finishEntryStabilization(reason: "timeout")
        }
    }

    private func finishEntryStabilization(reason: String) {
        guard isEntryStabilizing else { return }
        isEntryStabilizing = false
        cancelEntryRescrollPasses()
        entryTimeoutTask?.cancel()
        entryTimeoutTask = nil
        SouveraLog.write("LinkChat", "entry settled (UIKit, \(reason))")
        onEntrySettled?()
    }

    /// KVO auf contentSize (dokumentiert): Eintritts-Stabilisierung - das
    /// Ziel wird erneut angefahren, bis die Höhe stabil ist.
    private func handleContentSizeChanged() {
        guard let collectionView, isEntryStabilizing else { return }
        let height = collectionView.contentSize.height

        if abs(height - lastStableContentHeight) < 1 {
            stableSizeCount += 1
        } else {
            stableSizeCount = 0
        }
        lastStableContentHeight = height

        // Ziel erneut anfahren (Index je Pass aus der ID abgeleitet).
        scrollToEntryTarget()
        evaluateEntrySettle()
    }

    private func messageIndexPath(item: Int) -> IndexPath {
        IndexPath(item: item, section: Self.messageSection.rawValue)
    }

    func scrollToBottom(animated: Bool) {
        guard let collectionView, !items.isEmpty else { return }
        let indexPath = messageIndexPath(item: items.count - 1)
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
    }

    /// Verspaetete Ungelesen-Trennlinie (Room-Objekt/Boundary kommt nach
    /// dem Cache-first): Waehrend der Eintritts-Phase das Ziel auf die
    /// Trennlinie umstellen und sofort anfahren; danach nicht mehr in die
    /// Leseposition eingreifen.
    func applyBoundary(_ boundary: Int64?) {
        guard let boundary else { return }
        if isEntryStabilizing {
            entryTarget = .separator(id: boundary)
            scrollToEntryTarget()
            evaluateEntrySettle()
        } else if !didInitialEntry {
            pendingEntryBoundary = boundary
        }
    }

    // MARK: - UICollectionViewDataSource (Diffable)

    func makeCollectionView() -> UICollectionView {
        var listConfiguration = UICollectionLayoutListConfiguration(appearance: .plain)
        listConfiguration.showsSeparators = false
        let layout = UICollectionViewCompositionalLayout.list(using: listConfiguration)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "LinkChatCell")
        collectionView.backgroundColor = .clear
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .automatic
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        let dataSource = UICollectionViewDiffableDataSource<Section, ListItem>(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "LinkChatCell", for: indexPath)
            guard let self else { return cell }
            if item == .header, let viewModel = self.viewModel {
                cell.contentConfiguration = UIHostingConfiguration {
                    LinkChatHeaderBubble(viewModel: viewModel)
                }
                .margins(.all, 0)
            } else if case let .message(id) = item, let rowProvider = self.rowProvider,
                      let chatItem = self.items.first(where: { $0.message.id == id }) {
                cell.contentConfiguration = UIHostingConfiguration {
                    rowProvider(chatItem.globalIndex)
                }
                .margins(.all, 0)
            }
            cell.backgroundConfiguration = .clear()
            return cell
        }
        collectionView.dataSource = dataSource
        collectionView.delegate = self
        self.dataSource = dataSource
        self.collectionView = collectionView
        // KVO auf contentSize (dokumentiertes NSKeyValueObserving) - Kern
        // der Eintritts-Stabilisierung.
        contentSizeObservation = collectionView.observe(\UICollectionView.contentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleContentSizeChanged()
            }
        }
        return collectionView
    }
}

extension LinkChatListController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let distance = scrollView.contentSize.height
            - scrollView.adjustedContentInset.bottom
            - (scrollView.contentOffset.y + scrollView.frame.height)
        onDistanceChanged?(distance)

        // Nahe am Verlaufskopf: naechste gepufferte aeltere Batches
        // anfordern (talk-ios laedt Verlauf ebenfalls nur am Kopf nach).
        // Erst NACH dem Eintritts-Settle - in der Phase gehoert der
        // Offset dem Entry-Scroll.
        // Cooldown: Ein Batch-Publish pro 400ms - der fruehere Pin loss
        // bei einem Fling 3 Batches in 160ms anwenden (Log 11.09.), jede
        // Anwendung verschiebt das Offset und stapelte den Fehler.
        if !isEntryStabilizing, !items.isEmpty,
           scrollView.contentOffset.y + scrollView.adjustedContentInset.top < 300,
           CACurrentMediaTime() - lastOlderRequestAt >= 0.4 {
            lastOlderRequestAt = CACurrentMediaTime()
            onRequestOlder?()
        }
    }
}

/// SwiftUI-Brücke: hostet die UIKit-Chat-Liste.
struct LinkChatListView: UIViewRepresentable {
    @ObservedObject var controller: LinkChatListController
    let items: [LinkChatListItem]
    let roomToken: String
    let unreadBoundary: Int64?
    let isLoadingHistory: Bool
    let isPositioned: Bool
    let viewModel: LinkViewModel
    let rowProvider: (Int) -> AnyView
    let onDistanceChanged: (CGFloat) -> Void
    let onEntrySettled: () -> Void
    let onRequestOlder: () -> Void

    func makeUIView(context: Context) -> UICollectionView {
        controller.makeCollectionView()
    }

    func updateUIView(_ uiView: UICollectionView, context: Context) {
        controller.update(
            items: items,
            roomToken: roomToken,
            unreadBoundary: unreadBoundary,
            isLoadingHistory: isLoadingHistory,
            viewModel: viewModel,
            rowProvider: rowProvider,
            onDistanceChanged: onDistanceChanged,
            onEntrySettled: onEntrySettled,
            onRequestOlder: onRequestOlder
        )
    }
}


/// Header-Zellen-Inhalt (Abschnitt 0 der Chat-Liste, steht IM Scroll-
/// Inhalt am Verlaufskopf - nie ueber Text): Spinner waehrend der
/// Vollverlauf laedt, "Anfang der Unterhaltung" am Verlaufsanfang.
/// Beobachtet das ViewModel reaktiv - Zustandswechsel erscheinen ohne
/// manuelle Zellen-Manipulation (Run-Fix: der fruehere
/// reconfigureItems-Aufruf crashte, weil die Header-Zelle zum
/// Aufrufzeitpunkt noch nicht in der Collection View existierte).
struct LinkChatHeaderBubble: View {
    @ObservedObject var viewModel: LinkViewModel

    var body: some View {
        Group {
            if viewModel.isLoadingHistory {
                hintBubble {
                    ProgressView()
                    Text(NSLocalizedString("_link_older_loading_", comment: ""))
                }
            } else if !viewModel.hasMoreHistory {
                hintBubble {
                    Text(NSLocalizedString("_link_history_start_", comment: ""))
                }
            } else {
                // Weder Laden noch Gespraeuchsanfang: Bubble ausblenden
                // (Self-Sizing reduziert die Zelle auf 0 Hoehe).
                Color.clear.frame(height: 0)
            }
        }
    }

    private func hintBubble<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            Spacer()
            HStack(spacing: 8) {
                content()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(NCBrandColor.shared.customer).opacity(0.12), in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
