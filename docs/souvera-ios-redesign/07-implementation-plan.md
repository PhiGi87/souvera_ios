<!-- SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors -->
<!-- SPDX-License-Identifier: GPL-2.0-or-later -->

# 07 — Umsetzungsplan (Reihenfolge)

> Nicht-chaotische, funktional sichere Reihenfolge. Jede Phase ist für sich review-/testbar und
> darf bestehende Funktion nicht brechen. Keine Phase in diesem Dokument wird **jetzt** umgesetzt.

---

## Phase A — Design Foundation

- Zentrale Tokens einführen: `UIColor.souvera.*` / `Color.souvera.*` (Farben, Spacing, Radien,
  Typografie-Rollen) als **einzige neue Quelle**.
- `NCBrandColor` um semantische Tokens ergänzen (Souvera-first: Server-Theming-Verhalten festlegen).
- `#0082C9`-Vorkommen (`NCMoreView.shortcutIconColor`, LaunchScreen, Avatar-Palette) auf Souvera-Töne.
- Launch-/Privacy-Screen-Hintergrund auf `#4BBFEA`.
- Basis-Komponenten als SwiftUI (`SouveraButtonStyle`, `SouveraIconButton`, `SouveraListRow`,
  `SouveraBadge`, `SouveraEmptyState`, `SouveraErrorState`, `SouveraLoadingView`, `SouveraToast`,
  `SouveraSheetHeader`, `SouveraAvatar`) + UIKit-Äquivalente.
- Inconsolata-Font entfernen.

**Definition of Done:** Tokens/Component-Preview-Katalog existiert; Tests (Swift Testing) für Tokens
grün; App baut ohne Warnungen.

---

## Phase B — Globale Navigation

- `NCMainTabBarController`/`NCMainNavigationController`: einheitliche `UITabBarAppearance`/
  `UINavigationBarAppearance`, gemeinsames Toolbar-Chrome (UIKit + SwiftUI aus denselben Tokens).
- SwiftUI-Tab-Host (`makeHostedTab`) sauber konfigurieren (kein doppeltes Chrome, Edge-Swipe-Back).
- Tab-Wechsel-Übergang (reduzierbar).
- `SouveraSheetHeader` + `PresentationDetent`-Kurven als Standard etablieren.

**Definition of Done:** Tab-/Nav-Chrome in allen 5 Tabs identisch; Navigation funktioniert unverändert.

---

## Phase C — Kernbereiche

Reihenfolge innerhalb der Phase nach Risiko (niedrig → hoch), nicht nach Wichtigkeit:

1. **Mehr** (`NCMoreView` → native `List`) — niedriges Risiko, hohe Sichtbarkeit.
2. **Kontakte, Shield** — SwiftUI, isoliert.
3. **Mail** (Ordner/Liste/Detail/Compose/Suche) — Komponenten-Ersetzung.
4. **Kalender** — Hauptansicht + Sheets.
5. **Link/Talk** — Liste/Chat (Call nur kosmetisch).

**Definition of Done:** Kern-Tabs nutzen Komponenten/Tokens; Funktions-Parität (Liste/Detail/Compose/
Termin/Chat) bestätigt.

---

## Phase D — Secondary Screens

- Activity, Notifications, Transfers, Assistant, Account-Screens, Einstellungen + Unter-Screens,
  Share-Detail, Select, Creation/Picker, Terms of Service, Client Integration.
- Viewer (Media/PDF/Rich/DirectEditing/QuickLook): **strikt kosmetisch**.

**Definition of Done:** alle Sekundärflächen auf Tokens; Viewer-Logik unverändert.

---

## Phase E — Empty / Error / Loading States

- Flächendeckend `SouveraEmptyState`/`SouveraErrorState`/`SouveraLoadingView`
  (UIKit: `NCSectionFirstHeaderEmptyData` vereinheitlichen; SwiftUI: `ContentUnavailableView`-Basis).
- Alle ad-hoc `ProgressView`/`Text`-Zustände ersetzen.

**Definition of Done:** kein nackter `ProgressView`/`Text`-Empty mehr.

---

## Phase F — Motion & Polish

- Motion-Schicht anwenden (Übergänge, Symbol Effects, Haptik).
- Liquid-Glass-Akzente (iOS 26) mit Material-Fallback an den definierten Stellen (Tab-/Toolbar-,
  Floating-, Such-Overlays).
- `SouveraToast`-Queue ersetzt ad-hoc Toasts.

**Definition of Done:** Motion konsistent, Reduce-Motion greift, keine Jank-Risiken.

---

## Phase G — Accessibility

- VoiceOver-Labels/Hints/Traits, Dynamic-Type-Großprüfung, Kontraste (AA), Touch-Targets ≥ 44 pt,
  Keyboard-/Switch-Control-Alternativen für Gesten.
- Detents-fixe Höhen und `.height(...)`-Sheets auf Kurven umstellen.

**Definition of Done:** Accessibility-Inspection bei allen Größen fehlerfrei.

---

## Phase H — Final QA & Abnahme

- Vollständiger Durchlauf aller Screens (Light/Dark, kleine/große iPhones, iPad, Dynamic Type,
  Reduce Motion) gegen die Abnahmekriterien (Dokument 08).
- Alte Stile/Komponenten-Reste beseitigen; Compiler-/Lint-Warnungen prüfen.

---

## Reihenfolge-Begründung

- **A → B** zuerst: Ohne Tokens/Chrome erzeugt jedes Screen-Redesign neue Inkonsistenz.
- **C vor D**: Kernbereiche (Mail/Kalender/Link/Mehr) sind Markengesicht und SwiftUI (leicht
  umbaubar); sie liefern die schnellste sichtbare Wirkung.
- **Dateibrowser (HIGH risk)** wird als Teil von C/E **schrittweise** angepasst (rein visuell),
  mit gesonderten Regressionstests, da er die zentrale Datei-Engine teilt.
- **E** bewusst nach C/D, damit Empty/Error-Komponenten zuerst existieren und dann flächendeckend
  eingesetzt werden.
- **F/G** zum Schluss: Motion/Accessibility auf stabiler visueller Basis.
