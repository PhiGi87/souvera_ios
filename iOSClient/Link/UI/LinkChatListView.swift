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
/// Scroll-Steuerung auf iOS 26 unzuverlässig war (Eintritt landete immer
/// oben, Scroll-Observer feuerten nicht, Pull tot). Muster 1:1 aus
/// nextcloud/talk-ios (UITableView) übernommen - mit dokumentierten
/// UIKit-APIs: imperative Scrolls nach dem Layout, scrollViewDidScroll
/// mit Offset < 0 für den Verlaufs-Pull, Offset-Erhalt über
/// scrollToItem(previousFirst, .top).
///
/// Die Zeilen-Inhalte bleiben SwiftUI: Jede Cell hostet den bestehenden
/// Zeilen-View über UIHostingConfiguration (iOS 16+, dokumentiert).
@MainActor
final class LinkChatListController: NSObject, ObservableObject, UICollectionViewDataSource, UICollectionViewDelegate {

    // MARK: - Vom SwiftUI-Host gesetzte Eingänge (je Update)

    private(set) var items: [LinkChatListItem] = []
    private var canLoadOlder = false
    private var canExtendWindow = false
    private var rowProvider: ((Int) -> AnyView)?
    private var onPullToRefresh: (() -> Void)?
    private var onWindowExtend: ((_ previousFirstId: Int64) -> Void)?
    private var onDistanceChanged: ((_ distanceToBottom: CGFloat) -> Void)?
    private var onEntrySettled: (() -> Void)?

    // MARK: - Interner Zustand

    private weak var collectionView: UICollectionView?
    private var lastRoomToken: String?
    private var pendingEntryBoundary: Int64?
    private var didInitialEntry = false
    private var isExtendingWindow = false
    private var lastPullLogAt = Date.distantPast

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
                onEntrySettled: @escaping () -> Void) {
        let roomChanged = roomToken != lastRoomToken
        if roomChanged {
            lastRoomToken = roomToken
            didInitialEntry = false
            isExtendingWindow = false
            pendingEntryBoundary = unreadBoundary
        }
        self.items = items
        self.canLoadOlder = canLoadOlder && isPositioned
        self.canExtendWindow = canExtendWindow && isPositioned
        self.rowProvider = rowProvider
        self.onPullToRefresh = onPullToRefresh
        self.onWindowExtend = onWindowExtend
        self.onDistanceChanged = onDistanceChanged
        self.onEntrySettled = onEntrySettled

        guard let collectionView else { return }
        collectionView.reloadData()
        if !didInitialEntry, !items.isEmpty {
            didInitialEntry = true
            DispatchQueue.main.async { [weak self] in
                self?.performEntryScroll()
            }
        }
    }

    // MARK: - Öffentliche Scroll-Kommandos (SwiftUI -> UIKit)

    /// Eintritt: Ungelesen -> Trennlinie mittig (talk-ios .middle), sonst
    /// ans Listenende. UIKit materialisiert synchron -> deterministisch.
    private func performEntryScroll() {
        guard let collectionView else { return }
        if let boundary = pendingEntryBoundary,
           let index = items.firstIndex(where: { $0.message.id == boundary }) {
            collectionView.scrollToItem(at: IndexPath(item: index, section: 0),
                                        at: .centeredVertically, animated: false)
            SouveraLog.write("LinkChat", "entry scroll: separator \(boundary) centered")
        } else {
            scrollToBottom(animated: false)
            SouveraLog.write("LinkChat", "entry scroll: bottom")
        }
        pendingEntryBoundary = nil
        onEntrySettled?()
    }

    func scrollToBottom(animated: Bool) {
        guard let collectionView, !items.isEmpty else { return }
        let indexPath = IndexPath(item: items.count - 1, section: 0)
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
    }

    /// Re-Anchor (Verlaufs-Prepend und Render-Fenster-Erweiterung): die
    /// bisher sichtbare älteste Zeile bleibt an derselben Stelle.
    func reanchor(id: Int64) {
        guard let collectionView, let index = items.firstIndex(where: { $0.message.id == id }) else { return }
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: false)
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

        let overscroll = scrollView.contentOffset.y - scrollView.adjustedContentInset.top

        // Verlaufs-Pull: JEDER Overscroll am Listenanfang (talk-ios
        // scrollViewDidScroll + contentOffset.y < 0); das Flaggen-Gate
        // (canLoadOlder = hasMoreHistory && !isLoadingOlder) verhindert
        // Doppel-Feuer.
        if overscroll < 0, canLoadOlder {
            let now = Date()
            if now.timeIntervalSince(lastPullLogAt) > 1 {
                lastPullLogAt = now
                SouveraLog.write("LinkChat", "history pull triggered (scrollViewDidScroll, overscroll=\(Int(overscroll))px)")
            }
            onPullToRefresh?()
        }

        // Render-Fenster-Erweiterung nahe dem Fensteranfang (Gate gegen
        // Rückkopplung über isExtendingWindow; nur wenn überhaupt noch
        // Zeilen oberhalb gerendert werden können).
        if scrollView.contentOffset.y <= 4,
           overscroll >= 0,
           canExtendWindow,
           !isExtendingWindow,
           let first = items.first {
            isExtendingWindow = true
            SouveraLog.write("LinkChat", "render window extension requested (firstId=\(first.message.id))")
            onWindowExtend?(first.message.id)
        }
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
            onEntrySettled: onEntrySettled
        )
    }
}
