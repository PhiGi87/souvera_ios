// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run 24.10. (Duo-Außendisplay, Hochkant):
// Die rechten Header-Aktionen wandern aus dem blauen Header in eine eigene
// schwebende Glas-Pille im rechten Button-Bereich, direkt oberhalb der
// System-Tab-Leiste. Nur in diesem einen Layout (kompakte Phone-Breite,
// Hochformat, Tab-Leiste vertikal am rechten Rand). Alle anderen Layouts
// behalten die Aktionen im Header.
//
// Die System-Tab-Leiste selbst lässt sich nicht um eigene Buttons erweitern;
// deshalb die separate Pille. Sie wird aus derselben Brücke gespeist, die
// auch die UIKit-/Bridge-Header befüllt.

import SwiftUI
import UIKit
import Combine

/// Menüeintrag der Aktions-Pille (UIMenus und Bridge-Menüs werden auf diesen
/// neutralen Typ abgebildet).
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

    /// Stabiler Vergleichswert fuer den Rail-Host (erkennt echte Aenderungen).
    var signature: String {
        let kids = (children ?? []).map(\.signature).joined(separator: ",")
        return "\(id):\(title):\(icon ?? ""):\(isChecked):\(isDestructive):[\(kids)]"
    }
}

extension SouveraRailMenuEntry {
    /// Menue-Signatur fuer den Rail-Host (erkennt echte Aenderungen).
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

/// Einzelne Aktion der rechten Pille.
struct SouveraRailAction: Identifiable {
    let id: String
    let icon: String
    var title: String?
    var tint: Color?
    var accessibilityLabel: String
    var menu: [SouveraRailMenuEntry]?
    /// UIKit-Menue (z. B. das "... "-Menue von Dateien). Wird ueber einen
    /// UIButton mit `showsMenuAsPrimaryAction` gerendert, weil UIActions
    /// ihre Handler nicht oeffentlich preisgeben.
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

    /// Stabiler Vergleichswert fuer den Rail-Host (erkennt echte Aenderungen).
    var signature: String {
        let menus = (menu ?? []).map(\.signature).joined(separator: ";")
        let uikitMenu = uiMenu.map { SouveraRailMenuEntry.signature(of: $0) } ?? ""
        return "\(id):\(icon):\(accessibilityLabel):\(String(describing: tint)):[\(menus)]:[\(uikitMenu)]"
    }
}

/// Beobachtbares Modell der aktuell sichtbaren Pille. Der Tab-Controller
/// befuellt es aus der Bruecke bzw. den Trailing-Items des gewaehlten Tabs.
final class SouveraActionRailModel: ObservableObject {
    @Published var actions: [SouveraRailAction] = []
}

/// Aktionsquelle fuer UIKit-basierte Tabs (Dateien/Mehr).
final class SouveraActionRailSource: ObservableObject {
    @Published var actions: [SouveraRailAction] = []
}

/// Reine, unit-testbare Layoutregeln fuer die Pille.
enum SouveraActionRailLayout {
    /// Nur Außendisplay hochkant: kompakte Phone-Breite und die Tab-Leiste
    /// schwebt vertikal am rechten Rand. Querformat, Innendisplay, iPad und
    /// die normale untere Tab-Leiste bleiben unveraendert.
    static func isActive(horizontalSizeClass: UIUserInterfaceSizeClass,
                         idiom: UIUserInterfaceIdiom,
                         isPortrait: Bool,
                         tabBarFrame: CGRect,
                         viewBounds: CGRect,
                         tabBarHidden: Bool) -> Bool {
        guard !tabBarHidden else { return false }
        guard horizontalSizeClass == .compact, idiom == .phone else { return false }
        guard isPortrait else { return false }
        guard tabBarFrame.width > 0, tabBarFrame.height > 0 else { return false }
        // Nicht sichtbar / aus dem Fenster geschoben.
        guard tabBarFrame.intersects(viewBounds) else { return false }
        // Vertikale Leiste (Sidebar) statt unterer Tab-Leiste.
        guard tabBarFrame.height > tabBarFrame.width else { return false }
        // Am rechten Rand.
        guard tabBarFrame.midX > viewBounds.midX else { return false }
        return true
    }

    static func contentHeight(actionCount: Int,
                              button: CGFloat = 44,
                              spacing: CGFloat = 2,
                              padding: CGFloat = 8) -> CGFloat {
        guard actionCount > 0 else { return 0 }
        return CGFloat(actionCount) * button
            + CGFloat(actionCount - 1) * spacing
            + padding
    }

    /// Rechtsbuendig oberhalb der Tab-Leiste. Reicht die Hoehe nicht (z. B.
    /// weil eine Sidebar ihre volle Container-Hoehe meldet), wird die Pille
    /// oben rechts unter dem Header platziert - weiterhin im rechten
    /// Button-Bereich und oberhalb der Tab-Leiste.
    static func frame(tabBarFrame: CGRect,
                      headerBottom: CGFloat,
                      actionCount: Int,
                      viewBounds: CGRect,
                      gap: CGFloat = 8,
                      width: CGFloat = 52) -> CGRect {
        guard actionCount > 0 else { return .zero }
        let desiredHeight = contentHeight(actionCount: actionCount)
        let maxBottom = tabBarFrame.minY - gap
        let maxTop = headerBottom + gap
        let trailing = min(tabBarFrame.maxX, viewBounds.maxX - gap)
        let x = trailing - width

        if maxBottom - maxTop >= min(desiredHeight, 44) {
            let height = max(0, min(desiredHeight, maxBottom - maxTop))
            let y = maxBottom - height
            return CGRect(x: x, y: y, width: width, height: height)
        }

        let height = max(0, min(desiredHeight, viewBounds.maxY - maxTop - gap))
        return CGRect(x: x, y: maxTop, width: width, height: height)
    }
}

/// Die schwebende Glas-Pille. Wird vom Tab-Controller als Overlay gehalten;
/// die Position kommt aus `SouveraActionRailLayout`.
struct SouveraActionRailView: View {
    @ObservedObject var model: SouveraActionRailModel

    var body: some View {
        VStack(spacing: 2) {
            ForEach(model.actions) { action in
                actionButton(action)
            }
        }
        .padding(4)
        .modifier(SouveraHeaderGlass(shape: Capsule()))
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actionButton(_ action: SouveraRailAction) -> some View {
        if let uiMenu = action.uiMenu {
            SouveraRailMenuButton(menu: uiMenu, icon: action.icon)
                .frame(width: 44, height: 44)
                .accessibilityLabel(Text(action.accessibilityLabel.isEmpty ? action.id : action.accessibilityLabel))
        } else if let entries = action.menu {
            Menu {
                ForEach(entries) { entry in
                    menuEntry(entry)
                }
            } label: {
                actionIcon(action)
            }
            .menuIndicator(.hidden)
            .accessibilityLabel(Text(action.accessibilityLabel.isEmpty ? action.id : action.accessibilityLabel))
        } else {
            Button(action: action.handler) {
                actionIcon(action)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(action.accessibilityLabel.isEmpty ? action.id : action.accessibilityLabel))
        }
    }

    private func actionIcon(_ action: SouveraRailAction) -> some View {
        Image(systemName: action.icon)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(action.tint ?? Color(red: 0.1, green: 0.1, blue: 0.1))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }

    /// Rekursive Menues koennen keinen opaken Rueckgabetyp ableiten -
    /// deshalb hier bewusst `AnyView`.
    private func menuEntry(_ entry: SouveraRailMenuEntry) -> AnyView {
        if let children = entry.children, !children.isEmpty {
            return AnyView(
                Menu {
                    ForEach(children) { child in
                        menuEntry(child)
                    }
                } label: {
                    Label(entry.title, systemImage: entry.icon ?? "chevron.right")
                }
            )
        }
        return AnyView(
            Button(role: entry.isDestructive ? .destructive : nil) {
                entry.handler()
            } label: {
                if entry.isChecked {
                    Label(entry.title, systemImage: "checkmark")
                } else if let icon = entry.icon {
                    Label(entry.title, systemImage: icon)
                } else {
                    Text(entry.title)
                }
            }
        )
    }
}

/// Icon-Button, der ein bestehendes `UIMenu` ueber UIKit praesentiert.
private struct SouveraRailMenuButton: UIViewRepresentable {
    let menu: UIMenu
    let icon: String

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.contentHorizontalAlignment = .center
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.menu = menu
        button.tintColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        let configuration = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        button.setImage(UIImage(systemName: icon, withConfiguration: configuration), for: .normal)
    }
}
