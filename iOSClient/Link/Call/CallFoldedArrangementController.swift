// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Run 25.10. (Geknicktes Call-Erlebnis): UIArrangementViewController
// (Apple, iOS 27.1, Overlay-Arrangement) ordnet die Call-Inhalte um die
// Falz. Apple-Doku nennt als Anwendungsfall wörtlich "a view for video
// playback and a view with playback controls".
//
// Platzierungs-Matrix (Secondary/Primary):
// - Flach/offen/zu:  Call-Composite über Chat (Chat verdeckt - wie heute)
// - Geknickt hoch:   Video OBEN (secondary), Controls + Self-View UNTEN
//                    (primary; die Self-View-Kachel wandert in die
//                    Control-Hälfte - Nutzer-Entscheidung)
// - Geknickt quer (Buch): Call-Composite LINKS (secondary/leading),
//                    interaktiver Chatraum RECHTS (primary/trailing)

import UIKit
import SwiftUI

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

/// Verwaltet die geknickte Anordnung: Secondary/Primary-Belegung je Pose.
/// Abstraktion fuer die type-eliminierte Referenz im Call-VC.
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

    enum Pose { case portraitFolded, bookFolded }

    private(set) var currentPose: FoldedCallPose?

    private let tilesContentView: UIView
    private let chromeContentView: UIView
    private let chatContentView: UIView
    private let chatRetain: UIViewController

    private let arrangement = UIArrangementViewController()
    private let tilesHost: CallPartHostViewController
    private let chromeHost: CallPartHostViewController
    private let compositeHost: CallPartHostViewController
    private let chatHost: UIViewController

    /// Self-View-Container wird im geknickten Hochformat von der Control-
    /// Hälfte gehalten (Nutzer-Entscheidung) - der Call-Owner benachrichtigt.
    var onSelfViewToChrome: () -> Void = {}
    /// Run 26.10.: Rueckweg - im Buch-Modus gehoert die Eigenansicht zur
    /// Video-Seite (Composite links). Der Call-Owner benachrichtigt.
    var onSelfViewToTiles: () -> Void = {}

    init(tilesContentView: UIView,
         chromeContentView: UIView,
         chatContentView: UIView,
         chatRetain: UIViewController,
         onSelfViewToChrome: @escaping () -> Void,
         onSelfViewToTiles: @escaping () -> Void) {
        self.tilesContentView = tilesContentView
        self.chromeContentView = chromeContentView
        self.chatContentView = chatContentView
        self.chatRetain = chatRetain
        self.onSelfViewToChrome = onSelfViewToChrome
        self.onSelfViewToTiles = onSelfViewToTiles
        self.tilesHost = CallPartHostViewController(contentView: tilesContentView)
        self.chromeHost = CallPartHostViewController(contentView: chromeContentView)
        self.compositeHost = CallPartHostViewController(contentView: UIView())
        // Run 26.10. (Fix "Buch-Modus ohne Chat"): Der Chatraum wurde an
        // einen LEEREN UIViewController uebergeben - chatContentView wurde
        // nie platziert. Der Host nimmt die Chat-View direkt auf.
        self.chatHost = CallPartHostViewController(contentView: chatContentView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(arrangement)
        view.addSubview(arrangement.view)
        arrangement.view.frame = view.bounds
        arrangement.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arrangement.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        arrangement.view.frame = view.bounds
    }

    /// Wendet die Platzierung fuer die Pose an (animierter Wechsel).
    func apply(pose: FoldedCallPose) {
        currentPose = pose
        // Run 26.10. (Fix "Abort beim Falten hochkant"): Das Arrangement
        // unterordnet die Placement-VCs per addChild - der UIKit-Hierarchie-
        // Check verweigert einen Child, dessen View noch in einer FREMDEN
        // VC-Hierarchie liegt. Die Container liegen im flachen Modus in der
        // View des Call-VCs -> VOR der Uebergabe ausklinken (der Check
        // greift VOR dem impliziten Re-Parenting).
        tilesContentView.removeFromSuperview()
        chromeContentView.removeFromSuperview()
        // Container-Verdrahtung je Pose:
        switch pose {
        case .portraitFolded:
            // Self-View in die Control-Haeifte holen (Nutzer-Entscheidung).
            onSelfViewToChrome()
            tilesHost.setContent(tilesContentView)
            chromeHost.setContent(chromeContentView)
            arrangement.setViewController(tilesHost, for: .secondary, animated: true)
            arrangement.setViewController(chromeHost, for: .primary, animated: true)
        case .bookFolded:
            // Composite links (Call-View mit Controls), Chatraum rechts.
            onSelfViewToTiles()
            compositeHost.setContent(makeComposite())
            arrangement.setViewController(compositeHost, for: .secondary, animated: true)
            arrangement.setViewController(chatHost, for: .primary, animated: true)
        }
        arrangement.updateArrangement(.overlay, animated: true)
    }

    /// Composite-Container: Video oben, Controls darunter (linke Buech-
    /// haelfte, Nutzer-Entscheidung 3: "Call-View mit Controls").
    private func makeComposite() -> UIView {
        let composite = UIView()
        composite.backgroundColor = .black
        tilesContentView.removeFromSuperview()
        composite.addSubview(tilesContentView)
        chromeContentView.removeFromSuperview()
        composite.addSubview(chromeContentView)
        tilesContentView.translatesAutoresizingMaskIntoConstraints = false
        chromeContentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tilesContentView.topAnchor.constraint(equalTo: composite.topAnchor),
            tilesContentView.leadingAnchor.constraint(equalTo: composite.leadingAnchor),
            tilesContentView.trailingAnchor.constraint(equalTo: composite.trailingAnchor),
            tilesContentView.bottomAnchor.constraint(equalTo: chromeContentView.topAnchor),
            chromeContentView.leadingAnchor.constraint(equalTo: composite.leadingAnchor),
            chromeContentView.trailingAnchor.constraint(equalTo: composite.trailingAnchor),
            chromeContentView.bottomAnchor.constraint(equalTo: composite.bottomAnchor),
            chromeContentView.heightAnchor.constraint(equalTo: composite.heightAnchor, multiplier: 0.35)
        ])
        return composite
    }
}
