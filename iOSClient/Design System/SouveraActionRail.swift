// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 24.10. (Duo, System-Sidebar):
// Die rechten Header-Aktionen wandern in das iOS-Seitenband
// (`UITabBarController.sidebar.bottomBarView`) - also dorthin, wo auch die
// Tab-Leiste liegt. Keine eigene schwebende Pille mehr: Das System verwaltet
// Breite/Höhe und die Position innerhalb des Bands.
//
// Die Aktionen kommen aus denselben Quellen wie zuvor:
// - Mail/Kalender/Link ueber die SouveraHeaderBridge
// - Dateien/Mehr ueber SouveraActionRailSource

import SwiftUI
import UIKit
import Combine

/// Menueeintrag fuer UIKit-Menues (Bridge-Beschreibungen).
struct SouveraRailMenuEntry: Identifiable {
    let id: String
    let title: String
    let icon: String?
    let isChecked: Bool
    let isDestructive: Bool
    let children: [SouveraRailMenuEntry]?
    let handler: () -> Void

    init(id: String,
         title: String,
         icon: String? = nil,
         isChecked: Bool = false,
         isDestructive: Bool = false,
         children: [SouveraRailMenuEntry]? = nil,
         handler: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.icon = icon
        self.isChecked = isChecked
        self.isDestructive = isDestructive
        self.children = children
        self.handler = handler
    }

    /// Stabiler Vergleichswert fuer den Sidebar-Host.
    var signature: String {
        let kids = (children ?? []).map(\.signature).joined(separator: ",")
        return "\(id):\(title):\(icon ?? ""):\(isChecked):\(isDestructive):[\(kids)]"
    }
}

extension SouveraRailMenuEntry {
    /// Menue-Signatur fuer ein bestehendes `UIMenu` (erkennt Aenderungen).
    static func signature(of menu: UIMenu) -> String {
        menu.children.map { element in
            if let action = element as? UIAction {
                return "\(action.title):\(action.state == .on):\(action.attributes.contains(.destructive))"
            }
            if let submenu = element as? UIMenu {
                return "\(submenu.title):[\(signature(of: submenu))]"
            }
            return ""
        }.joined(separator: ",")
    }
}

/// Einzelne Aktion im Seitenband.
struct SouveraRailAction: Identifiable {
    let id: String
    let icon: String
    var title: String?
    var tint: Color?
    var accessibilityLabel: String
    var menu: [SouveraRailMenuEntry]?
    /// UIKit-Menue (z. B. das "... "-Menue von Dateien).
    var uiMenu: UIMenu?
    let handler: () -> Void

    init(id: String,
         icon: String,
         title: String? = nil,
         tint: Color? = nil,
         accessibilityLabel: String = "",
         menu: [SouveraRailMenuEntry]? = nil,
         uiMenu: UIMenu? = nil,
         handler: @escaping () -> Void) {
        self.id = id
        self.icon = icon
        self.title = title
        self.tint = tint
        self.accessibilityLabel = accessibilityLabel
        self.menu = menu
        self.uiMenu = uiMenu
        self.handler = handler
    }

    /// Stabiler Vergleichswert fuer den Sidebar-Host.
    var signature: String {
        let menus = (menu ?? []).map(\.signature).joined(separator: ";")
        let uikitMenu = uiMenu.map { SouveraRailMenuEntry.signature(of: $0) } ?? ""
        return "\(id):\(icon):\(accessibilityLabel):\(String(describing: tint)):[\(menus)]:[\(uikitMenu)]"
    }
}

/// Aktionsquelle fuer UIKit-basierte Tabs (Dateien/Mehr).
final class SouveraActionRailSource: ObservableObject {
    @Published var actions: [SouveraRailAction] = []
}

/// Reine Aktivierungsregel: Das System-Seitenband ist sichtbar und liegt
/// vertikal am rechten Rand. Dann gehoeren die rechten Header-Aktionen in
/// `sidebar.bottomBarView` - unabhaengig davon, ob außen/innen oder
/// hoch/quer. Bei der unteren Tab-Leiste (Innendisplay hochkant) bleibt der
/// Header zustaendig.
enum SouveraSidebarActions {
    /// Header-Buttons wandern nur im Außendisplay HOCHKANT ins Seitenband -
    /// quer bleiben sie im Header, das Innendisplay ist unveraendert.
    /// (`sidebar.isAvailable` meldet auf dem Duo durchweg `false` und ist
    /// zur Erkennung unbrauchbar - Log 24.10., Build 202610241112.)
    static func isActive(horizontalSizeClass: UIUserInterfaceSizeClass,
                         isPortrait: Bool,
                         tabBarFrame: CGRect,
                         viewBounds: CGRect,
                         tabBarHidden: Bool) -> Bool {
        guard horizontalSizeClass == .compact, isPortrait else { return false }
        guard !tabBarHidden else { return false }
        guard tabBarFrame.width > 0, tabBarFrame.height > 0 else { return false }
        guard tabBarFrame.intersects(viewBounds) else { return false }
        guard tabBarFrame.height > tabBarFrame.width else { return false }
        guard tabBarFrame.midX > viewBounds.midX else { return false }
        return true
    }
}

/// Vertikale System-Toolbar fuer die rechte Sidebar. Wird als
/// `sidebar.bottomBarView` gesetzt; das System verwaltet Breite und Höhe.
final class SouveraSidebarActionBar: UIView {
    private let stack = UIStackView()
    private(set) var actions: [SouveraRailAction] = []

    private let buttonSide: CGFloat = 44
    private let spacing: CGFloat = 2
    private let verticalPadding: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: buttonSide)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(actions: [SouveraRailAction]) {
        guard actions.map(\.signature) != self.actions.map(\.signature) else { return }
        self.actions = actions
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for action in actions {
            let button = makeButton(for: action)
            stack.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: buttonSide),
                button.heightAnchor.constraint(equalToConstant: buttonSide)
            ])
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: buttonSide, height: contentHeight)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: max(buttonSide, size.width), height: contentHeight)
    }

    private var contentHeight: CGFloat {
        guard !actions.isEmpty else { return 0 }
        return CGFloat(actions.count) * buttonSide
            + CGFloat(actions.count - 1) * spacing
            + 2 * verticalPadding
    }

    private func makeButton(for action: SouveraRailAction) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        // Run 24.10.: Text-Items (z. B. "Heute") als Schrift-Button, sonst Icon.
        if action.icon.isEmpty, let title = action.title, !title.isEmpty {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        } else {
            button.setImage(iconImage(action.icon), for: .normal)
        }
        button.accessibilityLabel = action.accessibilityLabel.isEmpty ? action.id : action.accessibilityLabel

        if let uiMenu = action.uiMenu {
            button.menu = uiMenu
            button.showsMenuAsPrimaryAction = true
        } else if let entries = action.menu {
            button.menu = makeMenu(from: entries)
            button.showsMenuAsPrimaryAction = true
        } else {
            button.addAction(UIAction { _ in action.handler() }, for: .touchUpInside)
        }
        return button
    }

    private func iconImage(_ name: String) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        return UIImage(systemName: name, withConfiguration: configuration)
    }

    private func makeMenu(from entries: [SouveraRailMenuEntry]) -> UIMenu {
        UIMenu(title: "", children: entries.map { entry in
            if let children = entry.children, !children.isEmpty {
                return makeMenu(from: children, title: entry.title)
            }
            return UIAction(
                title: entry.title,
                image: entry.icon.flatMap { iconImage($0) },
                attributes: entry.isDestructive ? .destructive : [],
                state: entry.isChecked ? .on : .off
            ) { _ in
                entry.handler()
            }
        })
    }

    private func makeMenu(from entries: [SouveraRailMenuEntry], title: String) -> UIMenu {
        UIMenu(title: title, children: makeMenu(from: entries).children)
    }
}
