// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 25.10. (Geknicktes Call-Erlebnis): Posen-Verwaltung um die Falz.
//
// Run 27.10. (DOKUMENTIERTE ABWEICHUNG von der System-Container-Präferenz):
// Die erste Implementierung nutzte UIArrangementViewController (Apple,
// iOS 27.1, Overlay-Arrangement). In DREI unabhängigen Crash-Logs warf
// sein SwiftUI-Hosting-Interna beim Umhängen unserer Container eine
// Auto-Layout-Exception (SIGABRT in -[UIView _postMovedFromSuperview:] /
// _addChildViewController-Hierarchie-Check), und die Slot-Platzierung
// ergab einen schwarzen Screen mit geklemmten Controls. Der Container
// ist nicht mit unserem Content kombinierbar (RTC-Video-Views + SwiftUI-
// Chat-Host, frame-basierte Flat-Mode-Pflege). Daher verwaltet dieser
// Controller die Posen jetzt selbst mit expliziten Frames - plain UIKit,
// keine Constraints an den umgehängten Containern selbst, kein fremdes
// Container-Interna-Layout. Die Posen-Matrix folgt weiterhin Apples
// UIOverlayArrangement-Spezifikation (developer.apple.com/documentation/
// uikit/uioverlayarrangement-swift.struct):
// - Geknickt hochkant (Tent): Secondary/Video OBEN, Primary/Controls UNTEN
// - Geknickt quer (Buch):    Secondary/Call LEADING, Primary/Chat TRAILING

import UIKit

/// Dünner Host-VC fuer eine umgezogene Container-View.
final class CallPartHostViewController: UIViewController {
    private var contentView: UIView?

    init(contentView: UIView) {
        self.contentView = contentView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = contentView ?? UIView() }

    /// Nimmt die Container-View auf (Re-Parenting beim Posen-Wechsel).
    func setContent(_ newContent: UIView) {
        contentView = newContent
        if isViewLoaded { view = newContent }
    }
}

/// Posen des geknickten Call-Erlebnisses (dateibweit, damit Referenzen
/// ohne Availability-Erboundsicht moeglich sind).
enum FoldedCallPose {
    case portraitFolded
    case bookFolded
}

@available(iOS 27.1, *)
protocol CallFoldedArranging: AnyObject {
    func apply(pose: FoldedCallPose)
    var currentPose: FoldedCallPose? { get }
}

@available(iOS 27.1, *)
final class CallFoldedArrangementController: UIViewController, CallFoldedArranging {

    private(set) var currentPose: FoldedCallPose?

    private let tilesContentView: UIView
    private let chromeContentView: UIView
    private let chatContentView: UIView
    /// Composite der Buech-Haelfte: Video oben, Controls darunter.
    private let composite = UIView()

    /// Self-View-Container wird im geknickten Hochformat von der Control-
    /// Hälfte gehalten (Nutzer-Entscheidung) - der Call-Owner benachrichtigt.
    var onSelfViewToChrome: () -> Void = {}
    /// Rueckweg - im Buch-Modus gehoert die Eigenansicht zur Video-Seite.
    var onSelfViewToTiles: () -> Void = {}
    /// Run 27.10.: Nach JEDEM Posen-Layout (synchron, frische Frames) -
    /// der Owner positioniert die Eigenansicht und layoutet die Kacheln
    /// mit den ENDGUELTIGEN Container-Bounds (keine stale Bounds mehr,
    /// kein async-Timing).
    var onPoseLayout: () -> Void = {}

    init(tilesContentView: UIView,
         chromeContentView: UIView,
         chatContentView: UIView,
         onSelfViewToChrome: @escaping () -> Void,
         onSelfViewToTiles: @escaping () -> Void) {
        self.tilesContentView = tilesContentView
        self.chromeContentView = chromeContentView
        self.chatContentView = chatContentView
        self.onSelfViewToChrome = onSelfViewToChrome
        self.onSelfViewToTiles = onSelfViewToTiles
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        composite.backgroundColor = .black
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutForCurrentPose()
    }

    /// Wendet die Platzierung fuer die Pose an. Nur bei Posen-WECHSEL aktiv:
    /// Re-Parenting und Self-View-Callbacks laufen sonst bei jedem Layout-
    /// Durchlauf des Owners. Run 27.10.: Das Layout laeuft SYNCHRON hier -
    /// setNeedsLayout liess die Frames erst spaeter setzen, waehrend der
    /// Owner im selben Durchlauf mit stale Bounds weiterrechnete.
    func apply(pose: FoldedCallPose) {
        guard currentPose != pose else { return }
        currentPose = pose
        CallDebugLog.log("Fold", "apply \(pose == .portraitFolded ? "portraitFolded" : "bookFolded")")
        switch pose {
        case .portraitFolded:
            onSelfViewToChrome()
        case .bookFolded:
            onSelfViewToTiles()
        }
        layoutForCurrentPose()
    }

    // MARK: - Geometrie

    private func place(_ subview: UIView, in parent: UIView) {
        if subview.superview !== parent {
            parent.addSubview(subview)
        }
    }

    /// Falz-Band in View-Koordinaten. Run 27.10.: Explizit nach AKTIVER
    /// Division-Region filtern (Apples Query kann inaktive Regionen
    /// liefern - vgl. SouveraFoldSupport) und degenerierte Frames
    /// verwerfen; ohne verlaessliche Falz dient eine synthetische
    /// Halbierung als Fallback.
    private func divisionBand(vertical: Bool) -> CGRect {
        let bounds = view.bounds
        if #available(iOS 27.1, *) {
            let regions = view.reservedRegions(kind: .division)
            if let frame = regions.first(where: { $0.isActive })?.frame {
                let isVerticalBand = frame.height > frame.width
                if isVerticalBand == vertical {
                    let plausible = vertical
                        ? frame.minX > 0 && frame.maxX < bounds.width * 0.95
                        : frame.minY > 0 && frame.maxY < bounds.height * 0.95
                    if plausible { return frame }
                }
            }
        }
        return vertical
            ? CGRect(x: bounds.midX - 12, y: 0, width: 24, height: bounds.height)
            : CGRect(x: 0, y: bounds.midY - 12, width: bounds.width, height: 24)
    }

    private func layoutForCurrentPose() {
        guard let pose = currentPose else { return }
        // Run 27.10. (Fix "schwarzer Screen beim Drehen/Knicken"): Ein
        // verzoegerter Layout-Durchlauf nach dem Teardown darf die Container
        // NICHT mehr aus der Call-View in die abgetrennte Hierarchie
        // zurueckholen.
        guard view.window != nil, view.superview != nil else { return }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        switch pose {
        case .portraitFolded:
            // Tent-Falte (horizontales Band): Video oben, Controls unten.
            place(tilesContentView, in: view)
            place(chromeContentView, in: view)
            if chatContentView.superview !== nil { chatContentView.removeFromSuperview() }
            if composite.superview !== nil { composite.removeFromSuperview() }
            let band = divisionBand(vertical: false)
            tilesContentView.frame = CGRect(x: 0, y: 0,
                                            width: bounds.width,
                                            height: max(0, band.minY))
            chromeContentView.frame = CGRect(x: 0, y: band.maxY,
                                             width: bounds.width,
                                             height: max(0, bounds.height - band.maxY))
        case .bookFolded:
            // Buch-Falte (vertikales Band): Call-Composite links, Chat rechts.
            place(tilesContentView, in: composite)
            place(chromeContentView, in: composite)
            place(composite, in: view)
            place(chatContentView, in: view)
            let band = divisionBand(vertical: true)
            let leftWidth = max(0, band.minX)
            let rightWidth = max(0, bounds.width - band.maxX)
            composite.frame = CGRect(x: 0, y: 0, width: leftWidth, height: bounds.height)
            chatContentView.frame = CGRect(x: band.maxX, y: 0,
                                           width: rightWidth, height: bounds.height)
            // Innerhalb des Composites: Video oben (65 %), Controls unten.
            let videoHeight = max(0, composite.bounds.height * 0.65)
            tilesContentView.frame = CGRect(x: 0, y: 0,
                                            width: leftWidth, height: videoHeight)
            chromeContentView.frame = CGRect(x: 0, y: videoHeight,
                                             width: leftWidth,
                                             height: max(0, composite.bounds.height - videoHeight))
        }
        CallDebugLog.log("Fold", "layout pose=\(pose == .portraitFolded ? "portrait" : "book") "
                               + "root=\(view.bounds) tiles=\(tilesContentView.frame) "
                               + "chrome=\(chromeContentView.frame) chat=\(chatContentView.frame)")
        onPoseLayout()
    }
}
