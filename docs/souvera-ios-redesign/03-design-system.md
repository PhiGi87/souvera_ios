<!-- SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors -->
<!-- SPDX-License-Identifier: GPL-2.0-or-later -->

# 03 — Souvera iOS Design System (Konzept)

> Zentrales, wiederverwendbares Design System. Ziel: „Souvera Brand × native Apple UX".
> Grundsatz: **iOS braucht nicht für alles eine Card.** Weißraum, Hierarchie und native Listen vor
> eigenen Containern.

---

## 1. Prinzipien

1. **Native zuerst** — `List`/`Form` (`.insetGrouped`), `ContentUnavailableView`, `NavigationStack`,
   `.toolbar`, `.confirmationDialog`, SF Symbols, native Materials.
2. **Semantik statt hartkodierter Hex-Werte** — alle Farben/Metriken laufen über Tokens.
3. **Ein Blau-Spektrum** — Primärakzent `#4BBFEA`, Tiefton für Kontrast/„on brand".
4. **Dynamic Type überall** — keine fixen Fontgrößen; Detents über `PresentationDetent`-Kurven,
   keine fixen Höhen.
5. **Light + Dark vollständig** — adaptive Tokens.
6. **Reduce Motion respektieren** — Animationen über eine zentrale Motion-Schicht.

---

## 2. Colors

### 2.1 Token-Tabelle

| Token | Light | Dark | Anmerkung |
|---|---|---|---|
| `brandPrimary` | `#4BBFEA` | `#5BC3EE` (aufgehellt) | Akzent/Tint |
| `brandPrimaryDeep` | `#3B86D0` | `#5A9FDB` | Buttons, Links, „on brand"-Flächen (AA) |
| `brandOnPrimary` | Weiß | Weiß | Text auf `brandPrimaryDeep` |
| `brandSurface` | `#4BBFEA @ 12%` | `#4BBFEA @ 18%` | dezente Markenfläche |
| `accent` | `brandPrimaryDeep` | `brandPrimary` | System-Accent (`.tint`) |
| `background` | `.systemBackground` | `.systemBackground` | Hauptgrund |
| `backgroundGrouped` | `.systemGroupedBackground` | `.systemGroupedBackground` | Listen/Formen |
| `backgroundSecondary` | `.secondarySystemBackground` | `.secondarySystemBackground` | Karten |
| `surface` | `.secondarySystemGroupedBackground` | `.secondarySystemGroupedBackground` | Erhöhte Flächen |
| `textPrimary` | `.label` | `.label` | |
| `textSecondary` | `.secondaryLabel` | `.secondaryLabel` | |
| `textTertiary` | `.tertiaryLabel` | `.tertiaryLabel` | |
| `success` | `.green` | `.green` | |
| `warning` | `.orange` | `.orange` | |
| `error` | `.red` | `.red` | |
| `separator` | `.separator` | `.separator` | |
| `border` | `.separator @ 50%` | `.separator @ 50%` | dezente Rahmen |

**Regeln:**
- `brandPrimary` ist eine **Akzentfarbe**, niemals Textfarbe (Kontrast < AA).
- Jede Stelle, die heute `NCBrandColor.shared.customer` als Text-/Buttonfarbe nutzt, wird auf
  `brandPrimaryDeep` umgestellt, wo AA-Kontrast nötig ist.
- **Kein hartkodiertes `#0082C9`** (Nextcloud-Blau) mehr. Die verbliebenen Vorkommen
  (`NCMoreView.shortcutIconColor`, LaunchScreen-Hintergrund, Avatar-Palette) werden auf Souvera-Töne
  migriert.

### 2.2 Umsetzung im Code

- **UIKit**: Tokens als `UIColor`-Kategorie (z. B. `UIColor.souvera.brandPrimary`), die auf
  `NCBrandColor`/Systemfarben mit `traitCollection`-Auflösung zeigen. `NCBrandColor` bleibt die
  Runtime-Quelle; eine schlanke Adapter-Schicht stellt die semantischen Tokens bereit.
- **SwiftUI**: `Color`-Extensions auf denselben Tokens; `ShapeStyle`-Konformität für adaptive Nutzung.
- **Server-Theming**: `use_themingColor` für Souvera auf **off** bzw. auf einen
  „Souvera-first"-Modus stellen, damit die Markenfarbe konsistent bleibt (Entscheidung in Phase A).
- Empfehlung: ein **Asset-Catalog-Farbset** (`Color.xcassets`) für die Licht/Dunkel-Werte der
  Markentöne, damit auch Storyboards/IB konsistent sind.

---

## 3. Typography

Systemfont **SF Pro**; semantische Rollen über Text-Styles (Dynamic Type automatisch):

| Rolle | Text-Style | Gewicht | Verwendung |
|---|---|---|---|
| `largeTitle` | `.largeTitle` | Bold | Nur Hauptscreens mit Collapse-Verhalten |
| `pageTitle` | `.title` / `.title2` | Bold | Screen-Titel |
| `sectionTitle` | `.title3` | Semibold | Gruppen-/Abschnittstitel |
| `headline` | `.headline` | Semibold | Betonter Inhalt |
| `body` | `.body` | Regular | Primärtext |
| `secondary` | `.subheadline` | Regular | Sekundärtext |
| `caption` | `.caption` / `.footnote` | Regular | Metadaten, Zeitstempel |
| `button` | `.headline`/`.body` | Medium/Semibold | Button-Label |
| `metadata` | `.caption2` | Regular | feine Zusatzinfos |

**Regeln:**
- Keine `.system(size:)`-Fixwerte für Fließtext (außer Metriken wie Icons).
- `View.cappedFont`/`UIFont+Extension`-Caps bleiben als optionaler oberer Deckel erhalten, werden
  aber auf einen einheitlichen Cap (`accessibility2`) vereinheitlicht.
- `Font.icon(...)` bleibt die zentrale Icon-Font-Hilfe.
- Die ungenutzte **Inconsolata** wird entfernt (Projekt-Referenz + `UIAppFonts`).

---

## 4. Layout

### 4.1 Spacing Scale (8-pt-Basis, iOS-konform)

| Token | Wert |
|---|---|
| `spaceXXS` | 4 |
| `spaceXS` | 8 |
| `spaceSM` | 12 |
| `spaceMD` | 16 (Standard-Content-Margin) |
| `spaceLG` | 20 (Section-Abstand) |
| `spaceXL` | 24 |
| `spaceXXL` | 32 |

### 4.2 Corner Radius Scale

| Token | Wert | Verwendung |
|---|---|---|
| `radiusSM` | 8 | kleine Controls |
| `radiusMD` | 12 | Karten, Thumbnails |
| `radiusLG` | 16 | Sheets, große Karten |
| `radiusFull` | `.infinity` | Avatare, Pills, Buttons (nur wo sinnvoll) |

- Native `.insetGrouped`-Listen übernehmen die Systemradien (keine eigenen Cards nötig).

### 4.3 Content Margins

- Horizontal **16 pt** (Listen/Formen), Seiten-**20 pt** auf iOS-Paddings für freie Screens.
- Section-Abstand **20–24 pt**; iPad **20–24 pt** plus ggf. Breitenbeschränkung.

### 4.4 Component Heights

| Komponente | Höhe |
|---|---|
| Touch-Target (Mindest) | 44 pt |
| List-Row (Standard) | 44–54 pt |
| Primary Button | 50 pt |
| Icon-Button | 44 pt |
| Tab-Leiste | System |

---

## 5. Components (nur was wirklich gebraucht wird)

| Komponente | Zweck | Umsetzung | Status heute |
|---|---|---|---|
| `SouveraButtonStyle` | Primary/Secondary/Tertiary-Buttons | SwiftUI `ButtonStyle` (prominent = `brandPrimaryDeep`, tinted = `brandPrimary`) | `ButtonRounded` existiert, vereinheitlichen |
| `SouveraIconButton` | Toolbar-/Inline-Icon-Aktion | `.buttonStyle(.borderless)` + 44pt-Frame | vereinheitlichen |
| `SouveraSearchField` | Einheitliche Suche | `.searchable`-Konfiguration | je Modul ad-hoc |
| `SouveraEmptyState` | Leerzustand | `ContentUnavailableView` + Brand-Ton | ad-hoc `Text` |
| `SouveraErrorState` | Fehler mit Retry | `ContentUnavailableView` + „Erneut"-Button | ad-hoc |
| `SouveraLoadingView` | Ladezustand | `ProgressView` + Beschriftung, mit Fade-in | `ProgressView` nackt |
| `SouveraAvatar` | Account-/Kontakt-Avatar | Bild mit `brandSurface`-Fallback | `NCUtility.createAvatar` |
| `SouveraSectionHeader` | Gruppenkopf | native Section-Header + `textSecondary` | uneinheitlich |
| `SouveraListRow` | Standardzeile | native `List`-Row + Label | eigene Cards |
| `SouveraBadge` | Status-/Count-Pill | `Capsule` mit semantischer Farbe | uneinheitlich |
| `SouveraToast` | Transientes Feedback | zentrale Overlay-Komponente (ersetzt ad-hoc Toasts) | je Modul eigener Toast |
| `SouveraSheetHeader` | Sheet-Titel/Grabber | `.presentationDragIndicator` + Titel | uneinheitlich |

**Explizit NICHT** geplant: eigener „Floating Action Button", eigene „Card-Komponente",
eigene Menü-Engine — iOS bietet Native (`ToolbarItem`, `.menu`, `List`) und das ist die
hochwertigste Wahl.

---

## 6. Modul-Akzente (subtile Differenzierung)

Alle Module nutzen dieselben Tokens. Dezente Erkennungsmerkmale **nur über Farbe auf der
`brandPrimary`-Basis** (analog zur Produktfamilie), nie neue Formsprachen:

| Modul | Akzent |
|---|---|
| Mail | `brandPrimary` (Cyan) |
| Kalender | `brandPrimaryDeep` (Kobalt) |
| Link/Talk | Indigo-Ton aus Logo (`#496BBF`) |
| Dateien | `brandPrimary` (Cyan) |
| Shield | `brandPrimaryDeep` mit `warning`/`error`-Semantik |
| Kontakte | `brandPrimary` |

Diese Akzente bleiben **Tint/Hervorhebung**; Grundfläche, Typografie und Komponenten bleiben identisch.
