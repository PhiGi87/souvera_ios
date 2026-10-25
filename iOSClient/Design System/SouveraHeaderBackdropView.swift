// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 25.10. (Fix "weisser Streifen oben", Duo-Aussendisplay hochkant):
// Das System setzt die NavigationBar dort auf y = 24. Der Bereich
// darueber ist Fensterhintergrund - ohne Backdrop blitzt er weiss auf.
// Der Backdrop ist ausschliesslich ein HINTERGRUND: er setzt keine
// Bar-Geometrie (kein frame-Override), sondern fuellt nur den Streifen
// mit der oberen Verlaufsfarbe, damit der Uebergang zur Bar nahtlos ist.

import UIKit

final class SouveraHeaderBackdropView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = SouveraAppearance.gradientTopColor
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Passt die Hoehe an: nur der Bereich OBERHALB der System-Bar wird
    /// gefuellt (0 .. navigationBar.frame.minY). Bei y = 0 unsichtbar.
    func update(barMinY: CGFloat, width: CGFloat) {
        let height = max(0, barMinY)
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        if frame != target {
            frame = target
        }
        let shouldHide = height < 0.5
        if isHidden != shouldHide {
            isHidden = shouldHide
        }
    }
}
