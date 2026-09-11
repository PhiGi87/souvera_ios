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
        case separator(index: Int)
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
    private var headerContent: AnyView?
    private var rowProvider: ((Int) -> AnyView)?
    private var onDistanceChanged: ((_ distanceToBottom: CGFloat) -> Void)?
    private var onEntrySettled: (() -> Void)?

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

    // MARK: - Update vom SwiftUI-Host

    func update(items: [LinkChatListItem],
                roomToken: String,
                unreadBoundary: Int64?,
                isLoadingHistory: Bool,
                headerContent: AnyView?,
                rowProvider: @escaping (Int) -> AnyView,
                onDistanceChanged: @escaping (CGFloat) -> Void,
                onEntrySettled: @escaping () -> Void) {
        let roomChanged = roomToken != lastRoomToken
        if roomChanged {
            lastRoomToken = roomToken
            didInitialEntry = false
            pendingEntryBoundary = unreadBoundary
            committedIds = []
        }
        self.items = items
        self.isLoadingHistory = isLoadingHistory
        self.rowProvider = rowProvider
        self.onDistanceChanged = onDistanceChanged
        self.onEntrySettled = onEntrySettled
        self.headerContent = headerContent

        guard let dataSource else { return }

        // Header-Zelle bei jedem Update auffrischen (billig - eine Zelle):
        // der Zustand wechselt zwischen Lade-Spinner, "Anfang der
        // Unterhaltung" und leer.
        collectionView.reconfigureItems([.header])

        let newIds = items.map(\.id)
        guard newIds != committedIds else { return }
        applySnapshot(ids: newIds)

        if !didInitialEntry, !items.isEmpty {
            didInitialEntry = true
            DispatchQueue.main.async { [weak self] in
                self?.performEntryScroll()
            }
        }
    }

    // MARK: - Snapshot-Anwendung

    private func applySnapshot(ids: [Int64]) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, ListItem>()
        snapshot.appendSections([.header, .messages])
        snapshot.appendItems([.header], toSection: .header)
        snapshot.appendItems(ids.map { ListItem.message(id: $0) }, toSection: .messages)
        dataSource?.apply(snapshot, animatingDifferences: false)
        committedIds = ids
    }

    // MARK: - Öffentliche Scroll-Kommandos (SwiftUI -> UIKit)

    /// Eintritt: Ungelesen -> Trennlinie mittig (talk-ios .middle), sonst
    /// ans Listenende. Anschließend Stabilisierungs-Phase: Solange sich
    /// die Self-Sizing-Höhen noch ändern, wird das Ziel erneut angefahren.
    private func performEntryScroll() {
        guard let collectionView, !items.isEmpty else { return }
        isEntryStabilizing = true
        stableSizeCount = 0
        lastStableContentHeight = -1
        if let boundary = pendingEntryBoundary,
           let index = items.firstIndex(where: { $0.message.id == boundary }) {
            entryTarget = .separator(index: index)
            collectionView.layoutIfNeeded()
            collectionView.scrollToItem(at: messageIndexPath(item: index),
                                        at: .centeredVertically, animated: false)
            SouveraLog.write("LinkChat", "entry scroll: separator \(boundary) centered")
        } else {
            entryTarget = .bottom
            scrollToBottom(animated: false)
            SouveraLog.write("LinkChat", "entry scroll: bottom")
        }
        pendingEntryBoundary = nil
        startEntryTimeout()
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

        switch entryTarget {
        case .bottom:
            scrollToBottom(animated: false)
        case .separator(let index):
            collectionView.layoutIfNeeded()
            collectionView.scrollToItem(at: messageIndexPath(item: index),
                                        at: .centeredVertically, animated: false)
        }
        if stableSizeCount >= 2 {
            finishEntryStabilization(reason: "stable")
        }
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

    /// Nachziehender Eintritts-Scroll (verspätete Ungelesen-Trennlinie).
    func requestEntry(boundary: Int64?) {
        pendingEntryBoundary = boundary
        performEntryScroll()
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
            if item == .header, let headerContent = self.headerContent {
                cell.contentConfiguration = UIHostingConfiguration {
                    headerContent
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
    let headerContent: AnyView?
    let rowProvider: (Int) -> AnyView
    let onDistanceChanged: (CGFloat) -> Void
    let onEntrySettled: () -> Void

    func makeUIView(context: Context) -> UICollectionView {
        controller.makeCollectionView()
    }

    func updateUIView(_ uiView: UICollectionView, context: Context) {
        controller.update(
            items: items,
            roomToken: roomToken,
            unreadBoundary: unreadBoundary,
            isLoadingHistory: isLoadingHistory,
            headerContent: headerContent,
            rowProvider: rowProvider,
            onDistanceChanged: onDistanceChanged,
            onEntrySettled: onEntrySettled
        )
    }
}
