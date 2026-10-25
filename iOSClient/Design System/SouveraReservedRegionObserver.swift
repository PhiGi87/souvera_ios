// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 25.10. (Apple-konform): Regionen werden ausschliesslich im
// positionierenden View gelesen ("check in the view that positions the
// content") und in updateConstraints(), damit UIKit die Lesung trackt und
// bei Regionswechseln (Kamera aktiv/inaktiv, Faltzustand) ERNEUT aufruft.
// viewDidLayoutSubviews/SwiftUI-body werden bei Regionswechseln nicht
// benachrichtigt - genau das war die zweite Falle der ersten Umstellung.

import UIKit

/// Beobachtet aktive Occlusion-Regionen (iOS 27.1+) des eigenen Fensters
/// und meldet Aenderungen an den Header-Coordinator.
final class SouveraReservedRegionObserver: UIView {

    /// Wird nur bei tatsaechlicher Aenderung der Regionen gerufen.
    var onOcclusionsChanged: (([SouveraHeaderGeometry.Occlusion]) -> Void)?

    private var lastOcclusions: [SouveraHeaderGeometry.Occlusion] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Verankert den Observer full-frame im Parent (Ursprung 0/0), damit
    /// die gelesenen Frames direkt Fensterkoordinaten entsprechen.
    func install(in parent: UIView) {
        parent.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: parent.topAnchor),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        ])
    }

    override func updateConstraints() {
        super.updateConstraints()
        let current = readOcclusions()
        guard current != lastOcclusions else { return }
        lastOcclusions = current
        onOcclusionsChanged?(current)
    }

    /// Aktive Occlusion-Regionen in FENSTERKOORDINATEN. Die Lesung erfolgt
    /// am Fenster selbst (dessen Koordinatenraum = Fensterkoordinaten);
    /// Aeltere Systeme melden keine Regionen - dann bleibt die Liste leer
    /// und die Spec faellt auf die Tabelle zurueck.
    func readOcclusions() -> [SouveraHeaderGeometry.Occlusion] {
        guard let window else { return [] }
        if #available(iOS 27.1, *) {
            return window.reservedRegions(kind: .occlusion)
                .filter { $0.isActive }
                .map { SouveraHeaderGeometry.Occlusion(frame: $0.frame) }
        }
        return []
    }
}
