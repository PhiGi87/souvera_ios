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

/// UIKit-Chat-Liste (Run 11.09., zweiphasig): Die Liste zeigt AB DEM
/// EINTRITT nur das Initialfenster (neueste Seite inkl. aller Ungelesenen,
/// per bewährtem KVO-stabilisiertem Eintritts-Scroll positioniert) und
/// wächst erst NACH dem Settle, wenn `loadRemainingHistoryInBackground`
/// die älteren Batches liefert. Jeder Batch wird als Insert OBERHALB des
/// sichtbaren Bereichs eingefügt (`performBatchUpdates` + `insertItems`) -
/// UICollectionView hält dabei die sichtbaren Zeilen an Ort und Stelle
/// (dokumentiertes Batch-Verhalten): kein Sprung, kein Drift, ruhiges
/// Hochscrollen in die wachsende Historie. Konkurrierende Mechanismen
/// (Pull, Fenster-Erweiterung, Reload-Kämpfe) sind entfernt - es gibt
/// nur noch diesen einen Hintergrund-Actor.
///
/// Abschnitt 0 = Header-Zelle (Lade-Spinner / "Anfang der Unterhaltung",
/// steht IM Scroll-Inhalt am Verlaufskopf - nie über Text), Abschnitt 1 =
/// Nachrichten. Die Zeilen-Inhalte bleiben SwiftUI über
/// UIHostingConfiguration (iOS 16+, dokumentiert).
@MainActor
final class LinkChatListController: NSObject, ObservableObject, UICollectionViewDataSource, UICollectionViewDelegate {

    private enum EntryTarget {
        case bottom
        case separator(index: Int)
    }

    private static let headerSection = 0
    private static let messageSection = 1

    // MARK: - Vom SwiftUI-Host gesetzte Eingänge (je Update)

    private(set) var items: [LinkChatListItem] = []
    private var isLoadingHistory = false
    private var headerContent: AnyView?
    private var rowProvider: ((Int) -> AnyView)?
    private var onDistanceChanged: ((_ distanceToBottom: CGFloat) -> Void)?
    private var onEntrySettled: (() -> Void)?

    /// Header-Zelle neu konfigurieren (Zustandswechsel Lade-Spinner /
    /// "Anfang der Unterhaltung" / leer).
    private func reconfigureHeader() {
        guard let collectionView else { return }
        let headerIndexPath = IndexPath(item: 0, section: Self.headerSection)
        guard let cell = collectionView.cellForItem(at: headerIndexPath) else { return }
        cell.contentConfiguration = UIHostingConfiguration {
            headerContent
        }
        .margins(.all, 0)
    }

    // MARK: - Interner Zustand

    private weak var collectionView: UICollectionView?
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

        guard let collectionView else { return }

        // Header-Zelle bei jedem Update auffrischen (billig - eine Zelle):
        // der Zustand wechselt zwischen Lade-Spinner, "Anfang der
        // Unterhaltung" und leer.
        reconfigureHeader()

        let newIds = items.map(\.id)
        guard newIds != committedIds else { return }
        applyDiff(newIds: newIds)
    }

    // MARK: - Incrementelle Pflege (Standard-Chat-Muster)

    /// - Reiner Prepend (ältere Batches aus dem Hintergrund-Chain) ->
    ///   oben einfügen; UICollectionView hält die sichtbaren Zeilen bei
    ///   Batch-Updates an Ort und Stelle (dokumentiert).
    /// - Reiner Append (neue Meldungen) -> unten einfügen.
    /// - Alles andere (Edits/Removals/Mixed) -> voller Reload.
    private func applyDiff(newIds: [Int64]) {
        guard let collectionView else { return }
        let old = committedIds
        // Gemeinsames Präfix
        var prefix = 0
        while prefix < old.count, prefix < newIds.count, old[prefix] == newIds[prefix] { prefix += 1 }
        // Gemeinsames Suffix
        var suffixOld = old.count
        var suffixNew = newIds.count
        while suffixOld > prefix, suffixNew > prefix, old[suffixOld - 1] == newIds[suffixNew - 1] {
            suffixOld -= 1
            suffixNew -= 1
        }
        let insertedCount = suffixNew - prefix
        let removedCount = (old.count - suffixOld) - prefix

        if insertedCount == 0, removedCount == 0 { return }
        committedIds = newIds

        if removedCount == 0, insertedCount > 0 {
            // Lage der Insertion relativ zur ERSTEN committeten Zeile:
            // davor = Prepend (obere Insert-Region, außerhalb des
            // sichtbaren Bereichs beim unten stehenden Nutzer), dahinter =
            // Append (untere Insert-Region).
            let prependCount = max(0, old.count - suffixOld)
            let appendCount = insertedCount - prependCount
            collectionView.performBatchUpdates {
                if prependCount > 0 {
                    collectionView.insertItems(
                        at: (0..<prependCount).map { IndexPath(item: $0, section: Self.messageSection) }
                    )
                }
                if appendCount > 0 {
                    collectionView.insertItems(
                        at: (old.count..<(old.count + appendCount)).map { IndexPath(item: $0, section: Self.messageSection) }
                    )
                }
            }
            return
        }
        // Removals oder Edits -> voller Reload (Position bleibt numerisch
        // erhalten; UIKit hält sichtbare Zellen bei Self-Sizing stabil).
        collectionView.reloadData()
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
        IndexPath(item: item, section: Self.messageSection)
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

    // MARK: - UICollectionViewDataSource

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        2
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        section == Self.headerSection ? 1 : items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "LinkChatCell", for: indexPath)
        if indexPath.section == Self.headerSection {
            cell.contentConfiguration = UIHostingConfiguration {
                headerContent
            }
            .margins(.all, 0)
        } else if items.indices.contains(indexPath.item), let rowProvider {
            cell.contentConfiguration = UIHostingConfiguration {
                rowProvider(items[indexPath.item].globalIndex)
            }
            .margins(.all, 0)
        }
        cell.backgroundConfiguration = .clear()
        return cell
    }

    // MARK: - SwiftUI-Anbindung

    func makeCollectionView() -> UICollectionView {
        var listConfiguration = UICollectionLayoutListConfiguration(appearance: .plain)
        listConfiguration.showsSeparators = false
        let layout = UICollectionViewCompositionalLayout.list(using: listConfiguration)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "LinkChatCell")
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.backgroundColor = .clear
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .automatic
        collectionView.translatesAutoresizingMaskIntoConstraints = false
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
