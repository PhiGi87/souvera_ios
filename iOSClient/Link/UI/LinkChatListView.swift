/*
 SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
 SPDX-License-Identifier: GPL-2.0-or-later
*/

import SwiftUI
import UIKit

/// Ein Element des Render-Fensters: GLOBALE Index-Position in `visibleItems`
/// (für die Tages-/Zeit-/Avatar-Logik) plus Nachricht.
struct LinkChatListItem: Identifiable, Equatable {
    let globalIndex: Int
    let message: LinkChatMessage
    var id: Int64 { message.id }

    static func == (lhs: LinkChatListItem, rhs: LinkChatListItem) -> Bool {
        lhs.globalIndex == rhs.globalIndex && lhs.message.id == rhs.message.id
    }
}

/// UIKit-Chat-Liste (Run 10.09.): Ersetzt den SwiftUI-ScrollView, dessen
/// Scroll-Steuerung auf iOS 26 unzuverlässig war. Muster aus
/// nextcloud/talk-ios (UITableView) auf dokumentierte UIKit-APIs gemappt.
///
/// Self-Sizing-Drift (Log 10.09.: `entry scroll: bottom` landete doch
/// oben): Bei UIHostingConfiguration-Zellen ist `contentSize` nach
/// `reloadData` nur geschätzt - mit jeder auflösenden Zellenhöhe
/// verschiebt sich der Offset. Gegenmittel (dokumentiertes KVO auf
/// `contentSize`): Der Eintritts-Scroll wird bei JEDER Größenänderung
/// erneut angesetzt, bis die Größe stabil ist (2 identische Messungen)
/// oder das Timeout greift - erst dann gilt der Eintritt als gesetzt.
/// Pull und Fenster-Erweiterung feuern zusätzlich nur bei echter
/// Nutzer-Geste (isTracking/isDecelerating) - die "Geister"-Auslösungen
/// während des Drifts sind damit ausgeschlossen.
@MainActor
final class LinkChatListController: NSObject, ObservableObject, UICollectionViewDataSource, UICollectionViewDelegate {

    private enum EntryTarget {
        case bottom
        case separator(index: Int)
    }

    // MARK: - Vom SwiftUI-Host gesetzte Eingänge (je Update)

    private(set) var items: [LinkChatListItem] = []
    private var canLoadOlder = false
    private var canExtendWindow = false
    private var rowProvider: ((Int) -> AnyView)?
    private var onPullToRefresh: (() -> Void)?
    private var onWindowExtend: ((_ previousFirstId: Int64) -> Void)?
    private var onDistanceChanged: ((_ distanceToBottom: CGFloat) -> Void)?
    private var onTopAreaChanged: ((_ isAtTop: Bool) -> Void)?
    private var onEntrySettled: (() -> Void)?

    // MARK: - Interner Zustand

    private weak var collectionView: UICollectionView?
    private var contentSizeObservation: NSKeyValueObservation?
    private var lastRoomToken: String?
    private var pendingEntryBoundary: Int64?
    private var didInitialEntry = false
    private var isExtendingWindow = false

    // Eintritts-Stabilisierung
    private var isEntryStabilizing = false
    private var entryTarget: EntryTarget = .bottom
    private var lastStableContentHeight: CGFloat = -1
    private var stableSizeCount = 0
    private var entryTimeoutTask: Task<Void, Never>?

    // Pull/Prepend: Edge-Trigger + Offset-Delta-Erhaltung
    // (Run 10.09.-Fix "Zucken": Der Pull war level-getriggert - der
    // Self-Sizing-Drift hielt den Offset unter 0 und kettenreiche
    // Nachlade-Pulls mit Re-Anchor-Kämpfen waren die Folge. Jetzt feuert
    // der Pull nur beim Übergang in den Overscroll (Re-Arm bei >= 0), und
    // Voranstellen erhält die Leseposition über die contentSize-Delta-
    // Technik statt über scrollToItem-Kämpfe mit dem ziehenden Finger.)
    private var wasOverscrolled = false
    private var pendingPrependOldHeight: CGFloat?

    // MARK: - Update vom SwiftUI-Host

    func update(items: [LinkChatListItem],
                roomToken: String,
                unreadBoundary: Int64?,
                canLoadOlder: Bool,
                canExtendWindow: Bool,
                isPositioned: Bool,
                rowProvider: @escaping (Int) -> AnyView,
                onPullToRefresh: @escaping () -> Void,
                onWindowExtend: @escaping (Int64) -> Void,
                onDistanceChanged: @escaping (CGFloat) -> Void,
                onTopAreaChanged: @escaping (Bool) -> Void,
                onEntrySettled: @escaping () -> Void) {
        let roomChanged = roomToken != lastRoomToken
        if roomChanged {
            lastRoomToken = roomToken
            didInitialEntry = false
            isExtendingWindow = false
            pendingEntryBoundary = unreadBoundary
            wasOverscrolled = false
        }
        self.items = items
        self.canLoadOlder = canLoadOlder && isPositioned
        self.canExtendWindow = canExtendWindow && isPositioned
        self.rowProvider = rowProvider
        self.onPullToRefresh = onPullToRefresh
        self.onWindowExtend = onWindowExtend
        self.onDistanceChanged = onDistanceChanged
        self.onTopAreaChanged = onTopAreaChanged
        self.onEntrySettled = onEntrySettled

        guard let collectionView else { return }
        // reloadData nur bei wirklich geänderten Items (Vergleich über die
        // Nachrichten-IDs) - sonst würde jedes SwiftUI-Rendering den
        // Scroll-Zustand stören.
        let newIds = items.map(\.id)
        if newIds != lastReloadedIds {
            lastReloadedIds = newIds
            // Offset-Delta-Erhaltung (klassische UIKit-Prepend-Technik):
            // Wurde ein Voranstellen (Pull/Fenster-Erweiterung) angestoßen,
            // verschiebt der neue Inhalt die bisher sichtbaren Zeilen um
            // die Differenz der Inhaltshöhen - contentOffset exakt
            // nachführen. Deterministisch, ohne Höhen zu schätzen und ohne
            // den ziehenden Finger zu bekämpfen.
            let oldHeight = collectionView.contentSize.height
            let isPrepend = pendingPrependOldHeight != nil
            pendingPrependOldHeight = nil
            collectionView.reloadData()
            if isPrepend {
                collectionView.layoutIfNeeded()
                let delta = collectionView.contentSize.height - oldHeight
                if delta > 0 {
                    collectionView.contentOffset.y += delta
                }
            }
            if !didInitialEntry, !items.isEmpty {
                didInitialEntry = true
                DispatchQueue.main.async { [weak self] in
                    self?.performEntryScroll()
                }
            }
        }
    }

    private var lastReloadedIds: [Int64] = []

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
            collectionView.scrollToItem(at: IndexPath(item: index, section: 0),
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

    /// KVO auf contentSize (dokumentiert): Selbst-Sizing-Höhen ändern die
    /// Inhaltsgöße nach dem ersten Layout - Eintritts-Ziel und frischer
    /// Re-Anchor werden solange erneut angefahren, bis sich die Größe
    /// stabilisiert hat.
    private func handleContentSizeChanged() {
        guard let collectionView else { return }
        let height = collectionView.contentSize.height

        if isEntryStabilizing {
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
                collectionView.scrollToItem(at: IndexPath(item: index, section: 0),
                                            at: .centeredVertically, animated: false)
            }
            if stableSizeCount >= 2 {
                finishEntryStabilization(reason: "stable")
            }
        }
    }

    func scrollToBottom(animated: Bool) {
        guard let collectionView, !items.isEmpty else { return }
        let indexPath = IndexPath(item: items.count - 1, section: 0)
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
    }

    /// Abschluss der Fenster-Erweiterung (Gate gegen Rückkopplung).
    func endWindowExtension() {
        isExtendingWindow = false
    }

    /// Nachziehender Eintritts-Scroll (verspätete Ungelesen-Trennlinie).
    func requestEntry(boundary: Int64?) {
        pendingEntryBoundary = boundary
        performEntryScroll()
    }

    // MARK: - UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "LinkChatCell", for: indexPath)
        if let index = items.indices.first(where: { $0 == indexPath.item }), let rowProvider {
            cell.contentConfiguration = UIHostingConfiguration {
                rowProvider(items[index].globalIndex)
            }
            .margins(.all, 0)
        }
        cell.backgroundConfiguration = .clear()
        return cell
    }

    // MARK: - UIScrollViewDelegate (talk-ios-Muster)

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let distance = scrollView.contentSize.height
            - scrollView.adjustedContentInset.bottom
            - (scrollView.contentOffset.y + scrollView.frame.height)
        onDistanceChanged?(distance)
        onTopAreaChanged?(scrollView.contentOffset.y <= 2)

        let overscroll = scrollView.contentOffset.y - scrollView.adjustedContentInset.top
        // Nur echte Nutzer-Gesten lösen Pull/Fenster-Erweiterung aus -
        // programmatische Scrolls (Eintritts-Stabilisierung, Re-Anchor)
        // dürfen die Mechanik nicht "geisterhaft" auslösen (Log 10.09.).
        let userScrolling = scrollView.isTracking || scrollView.isDecelerating
        guard userScrolling else { return }

        // Verlaufs-Pull: EDGE-getriggert (Run-Fix "Zucken") - feuert nur
        // beim Übergang in den Overscroll, Re-Arm erst bei Rückkehr >= 0.
        // Ein level-getriggerter Pull hat den Self-Sizing-Drift in eine
        // Kettennachladefalle verwandelt (Log 10.09. 14:21-14:22: fünf
        // Pulls, komplette Historie in 25 s). Merken der Inhaltshöhe für
        // die Offset-Delta-Erhaltung des Voranstellens.
        if overscroll < 0 {
            if !wasOverscrolled, canLoadOlder {
                wasOverscrolled = true
                pendingPrependOldHeight = scrollView.contentSize.height
                let now = Date()
                if now.timeIntervalSince(lastPullLogAt) > 1 {
                    lastPullLogAt = now
                    SouveraLog.write("LinkChat", "history pull triggered (overscroll edge, \(Int(overscroll))px)")
                }
                onPullToRefresh?()
            }
        } else {
            wasOverscrolled = false
        }

        // Render-Fenster-Erweiterung: ebenfalls edge-getriggert, nur wenn
        // KEIN Server-Pull läuft (doppelseitiges Voranstellen sonst) und
        // überhaupt Zeilen oberhalb gerendert werden können.
        if scrollView.contentOffset.y <= 4,
           overscroll >= 0,
           !wasOverscrolled,
           canExtendWindow,
           !isExtendingWindow,
           let first = items.first {
            isExtendingWindow = true
            pendingPrependOldHeight = scrollView.contentSize.height
            SouveraLog.write("LinkChat", "render window extension requested (firstId=\(first.message.id))")
            onWindowExtend?(first.message.id)
        }
    }

    private var lastPullLogAt = Date.distantPast

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
        // der Eintritts-Stabilisierung und Re-Anchor-Nachführung.
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
    let canLoadOlder: Bool
    let canExtendWindow: Bool
    let isPositioned: Bool
    let rowProvider: (Int) -> AnyView
    let onPullToRefresh: () -> Void
    let onWindowExtend: (Int64) -> Void
    let onDistanceChanged: (CGFloat) -> Void
    let onTopAreaChanged: (Bool) -> Void
    let onEntrySettled: () -> Void

    func makeUIView(context: Context) -> UICollectionView {
        controller.makeCollectionView()
    }

    func updateUIView(_ uiView: UICollectionView, context: Context) {
        controller.update(
            items: items,
            roomToken: roomToken,
            unreadBoundary: unreadBoundary,
            canLoadOlder: canLoadOlder,
            canExtendWindow: canExtendWindow,
            isPositioned: isPositioned,
            rowProvider: rowProvider,
            onPullToRefresh: onPullToRefresh,
            onWindowExtend: onWindowExtend,
            onDistanceChanged: onDistanceChanged,
            onTopAreaChanged: onTopAreaChanged,
            onEntrySettled: onEntrySettled
        )
    }
}
