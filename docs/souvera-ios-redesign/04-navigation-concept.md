<!-- SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors -->
<!-- SPDX-License-Identifier: GPL-2.0-or-later -->

# 04 — Navigationskonzept

> Ziel: eine konsistente, Apple-native Navigation, die die hybride UIKit/SwiftUI-Welt vereinheitlicht
> und die Marke „ein Workspace" transportiert.

---

## 1. Ist-Zustand (Kurz)

- 5 Tabs: Mail · Kalender · Link · Dateien · Mehr.
- SwiftUI-Tabs hosten eigene `NavigationStack`-Bars; der Dateien-Tab (UIKit) nutzt
  `UINavigationController` mit globalem Chrome (bell/sparkles/transfers/ellipsis + Floating „+").
- Ergebnis: **zwei Navigation-Welten** mit unterschiedlichen Toolbars und Übergängen.

## 2. Zielstruktur (beibehalten, harmonisiert)

Die Tab-Struktur bleibt **inhaltlich korrekt** und wird nicht umgebaut. Verändert wird das
**Erscheinungsbild und die Konsistenz**, nicht die Anzahl/Zuordnung der Tabs:

| Index | Tab | Ziel |
|---|---|---|
| 0 | Mail | SwiftUI `NavigationStack` |
| 1 | Kalender | SwiftUI `NavigationStack` |
| 2 | Link | SwiftUI `NavigationStack` |
| 3 | Dateien | UIKit, aber mit **angepasstem** `NCMainNavigationController` |
| 4 | Mehr | SwiftUI `NavigationStack` (bzw. `List`) |

**Nicht geplant:** Tab-Anzahl ändern, „Home"-Tab verschieben, Drawer einführen. Der Start-Tab bleibt
Mail (Produktfokus: Mail ist der Kern des Workspace).

## 3. Kernänderungen

### 3.1 Ein gemeinsames Toolbar-Chrome

- Ein gemeinsames **Rechts-Set** für die primären globalen Aktionen (Benachrichtigungen, Assistant,
  Transfers) wird als SwiftUI-`.toolbar`-Block **und** als UIKit-`UIBarButtonItem`-Set aus denselben
  Icon-/Tint-Tokens erzeugt. Ziel: identisches Aussehen in beiden Welten.
- Der **Option-Button (ellipsis)** bleibt kontextabhängig (nur Listen), aber mit einheitlicher
  Optik.
- Der **Floating „+"-Button** (nur Dateien) wird vereinheitlicht: konsistente Größe/Radius/Shadow
  über die Tokens; auf iOS 26 als Glass-Element mit Material-Fallback.

### 3.2 SwiftUI-Tabs nicht mehr „nackt" hosten

- `makeHostedTab` bleibt, aber der Host wird so konfiguriert, dass die UIKit-Leiste
  **einheitliche** `UITabBarAppearance`/`UINavigationBarAppearance` erbt (keine doppelten Back-Arrows,
  sauberes Edge-Swipe-Back).

### 3.3 Deep Links & Tab-Wechsel

- Bestehende Deep-Link-Aktionen (`NCDeepLinkHandler`, `DeepLink`) bleiben unverändert. Der
  Tab-Wechsel bekommt einen **subtilen, reduzierbaren** Übergang (kein hartes Umschalten).

### 3.4 Sheets, Search, Context Menus, Swipe Actions (native)

| Muster | Ziel |
|---|---|
| Sheets | native `.sheet`/`.pageSheet` mit `.presentationDragIndicator`; Detents über `PresentationDetent`-Kurven statt fixer `.height(...)` |
| Search | `.searchable` einheitlich; auf iOS 26 optional prominentes Glass-Searchfeld |
| Context Menus | `.contextMenu`/`UIContextMenuConfiguration` einheitlich; destruktive Aktionen ans Ende, rot |
| Swipe Actions | einheitliche `swipeActions` (leading = konstruktiv, trailing = destruktiv) |
| Menus | `.menu`/`UIAction` statt eigener Menü-Engines |

---

## 4. iOS 26+ / Liquid Glass (gezielt, nicht flächendeckend)

`SWIFT_VERSION`/Deployment erlauben `#available(iOS 26, *)`-Gating mit Material-Fallback.
Liquid Glass wird **nur** an folgenden Stellen eingesetzt (siehe `swiftui-expert-skill/liquid-glass.md`):

- **Tab-Leiste** (floating/glass-artig, falls iOS 26-Standard dies nicht ohnehin liefert).
- **Toolbar-/Floating-Controls** („+", primäre Aktionen).
- **Suchfeld-Overlays**.
- **Ausgewählte Interaktionselemente** (z. B. Kalender-Schnelltermine, Mail-Compose-FAB).

**Explizit NICHT** mit Glass: jede Karte/Liste/Fläche. Fallback für < iOS 26 ist immer
`.ultraThinMaterial`/Standard-Appearance.

**Regeln** (aus dem Skill):
- `.glassEffect` nach Layout-Modifiern; `.interactive()` nur auf tappbaren Elementen;
  `GlassEffectContainer` für Gruppen; keine eigenen Darkening-Backgrounds hinter Toolbars
  (Konflikt mit Scroll-Edge-Effekt).

---

## 5. Navigations-Hierarchie je Bereich

- **Mail**: Ordner → Nachrichten → Detail → Compose/Sheet; Suche als Overlay.
- **Kalender**: Tag/3-Tage/Monat (Segmented) → Event-Detail-Sheet → Edit-Sheet.
- **Link**: Konversationsliste → Chat; Calls als Vollbild.
- **Dateien**: Ordner → Unterordner (Push) → Viewer/Share (Push/Sheet); Suche als `searchController`.
- **Mehr**: `List` mit Gruppen → Push-Ziele (SwiftUI) bzw. Storyboard-Push (UIKit-Altlasten).
- **Globale Overlays**: Benachrichtigungen/Transfers/Assistant als Sheets (bleiben).

## 6. Konsistenz-Regeln (verbindlich)

1. Alle Push-Übergänge nutzen das System (Back-Geste funktioniert überall).
2. Toolbar-Aktionen max. 2–3 sichtbare Icons + Overflow-Menü.
3. Primäre Aktionen in Daumenreichweite (unten) oder Toolbar, nicht oben links.
4. Destruktive Aktionen immer mit `role: .destructive` (rot) und Bestätigung.
5. Kein eigenes „Hamburger"-Menü; „Mehr"-Tab bleibt der Sammelpunkt für seltene Ziele.
