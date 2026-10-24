// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 24.10.: Kollabschutz fuer die Bridge-Bar der gehosteten Module
// (Mail/Kalender/Link). UIKit laesst die Hoehe der NavigationBar bei
// Layout-/Route-Wechseln kurz auf ~24 pt einbrechen; im Innendisplay
// quer blieb die Bar in der Einzel-Mail-Ansicht dauerhaft kollabiert
// (Log: bridgeBarHeight=24, Build 202610242028). Die Layout-Hoehe ist
// fest 58 pt (SouveraLayoutMode.bridgeBarLayoutHeight); der Hintergrund
// ueberzeichnet quer sichtbar auf ~82 pt. Wir erzwingen sie daher in
// sizeThatFits, statt auf instabile System-Messungen zu vertrauen.

import UIKit

final class SouveraBridgeNavigationBar: UINavigationBar {

    private var lastRepairLog: String?

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        var fitted = super.sizeThatFits(size)
        if #available(iOS 26.0, *) {
            fitted.height = SouveraLayoutMode.bridgeBarLayoutHeight
        }
        return fitted
    }

    /// Run 24.10.: iOS 26 leitet die Bar-Hoehe nicht aus sizeThatFits ab -
    /// beim Oeffnen der Einzel-Mail kollabiert sie auf ~24 pt (Log
    /// bridgeBarHeight=24, sichtbarer blauer Streifen). Deshalb korrigieren
    /// wir die Hoehe nach jedem Layout-Pass hart auf die Layout-Hoehe.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard #available(iOS 26.0, *) else { return }
        guard !isHidden else { return }
        let target = SouveraLayoutMode.bridgeBarLayoutHeight
        let current = bounds.height
        guard current > 0.5, abs(current - target) > 0.5 else { return }
        var frame = self.frame
        frame.size.height = target
        self.frame = frame
        let stamp = "\(Int(current))"
        if stamp != lastRepairLog {
            lastRepairLog = stamp
            SouveraLog.write("SidebarActions",
                             "[SidebarActions] barRepair \(Int(current))->\(Int(target)) alpha=\(alpha)")
        }
    }
}
