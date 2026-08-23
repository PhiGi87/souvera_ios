<!-- SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors -->
<!-- SPDX-License-Identifier: GPL-2.0-or-later -->

# 09 — Implementation Log

> Chronik der Umsetzung, getroffene Entscheidungen und Abweichungen vom Phase-1-Plan.

---

## 1. Umgebungsbedingte Einschränkung (wichtig)

Die Umsetzung läuft in einer **Linux-Umgebung ohne Xcode, Swift-Toolchain, Simulator und
`xcodebuild`**. Dadurch gilt:

- **Kein Compile-/Build-Nachweis** möglich. Der gesamte Code wurde „correct-by-construction"
  geschrieben und gegen die bestehenden Konventionen/APIs der Codebasis geprüft (iOS 17,
  `SWIFT_VERSION 5.0`), aber nicht kompiliert.
- **Keine visuelle Verifikation** über Simulator/Screenshots möglich.
- Der Xcode-Build muss auf einem macOS-Rechner mit Xcode 26.x ausgeführt werden (siehe
  `README.md`, „Xcode 26.1 Project Setup").

Diese Einschränkung ist der Grund, warum die Umsetzung bewusst **inkrementell und risikoarm**
erfolgte: die Design-Foundation und die in sich geschlossenen SwiftUI-Oberflächen wurden
vollständig umgesetzt; großflächige, nicht verifizierbare Umbauten der größten UIKit-/SwiftUI-
Screens (Dateibrowser, Viewer, Share, Login) wurden **nicht** blind durchgezogen, um keine
Compilerfehler einzuführen.

---

## 2. Umgesetzte Bereiche

### 2.1 Design Foundation (Phase A)

Neues Verzeichnis `iOSClient/Design System/` (7 Dateien, im Xcode-Projekt registriert):

| Datei | Inhalt |
|---|---|
| `SouveraTokens.swift` | `enum SouveraTokens` — Spacing (4–32), Radius (8/12/16), Metrics (44/50/54), Touch-Targets |
| `UIColor+Souvera.swift` | `UIColor.Souvera` — adaptive Brand-Tokens (Light/Dark) |
| `Color+Souvera.swift` | `Color.Souvera` — SwiftUI-Pendant der UIKit-Tokens |
| `SouveraButtonStyle.swift` | `SouveraButtonStyle` (primary/secondary/tertiary, `fullWidth`) |
| `SouveraStateView.swift` | `SouveraStateView` (loading/empty/error auf `ContentUnavailableView`-Basis) |
| `SouveraBadge.swift` | `SouveraBadge` (neutral/brand/success/warning/error) |
| `SouveraToast.swift` | `SouveraToast` + `SouveraToastCenter` (zentrale Toast-Queue) + `.souveraToast()` |

Registrierung in `Souvera.xcodeproj/project.pbxproj` über die vier Standard-Abschnitte
(PBXBuildFile, PBXFileReference, PBXGroup, PBXSourcesBuildPhase) mit eindeutigen 24-Hex-IDs.
Die Dateien liegen physisch in `iOSClient/Design System/` und sind im `Extensions`-Navigator-
Gruppenblock eingeordnet.

### 2.2 Branding-Fixes

- **Avatar-Palette** (`Brand/NCBrand.swift`, `createUserColors()`): von Nextclouds
  Rot/Gelb/Blau (`#B6469D`, `#DDCB55`, `#0082C9`) auf das Souvera-Blau-Spektrum
  (Indigo `#496BBF` → Cyan `#4BBFEA` → Tiefblau `#3B86D0`) umgestellt. Die Vielfalt bleibt
  erhalten (notwendig zur Unterscheidung von Avataren), ist aber jetzt eindeutig Souvera.
- **Launch-/Privacy-Screen** (`Brand/LaunchScreen.storyboard`): Hintergrund von Nextcloud-Blau
  `#0082C9` auf Souvera `#4BBFEA` korrigiert.
- **Nextcloud-Blau entfernt**: das letzte hartkodierte `#0082C9` (in `NCMoreView`) ist mit dem
  Rewrite verschwunden; eine Repo-weite Suche nach `#0082C9`/`130/255` liefert 0 Treffer.

### 2.3 Screen-Migrationen (SwiftUI)

| Screen | Änderung |
|---|---|
| **Mehr** (`NCMoreView`) | Komplett auf native `.insetGrouped`-`List` umgestellt; Gradient-Card-Header, selbstgebaute Cards und hartkodierte Divider entfernt; Account-Header als natives `Menu` + Avatar; `Color.Souvera`-Tint. |
| **Shield** (`ShieldView`) | Loading/Empty/Error auf `SouveraStateView`; ad-hoc Toast-Overlay durch zentrale `SouveraToastCenter` ersetzt; Release-Sheet-Detent von fixer `.height` auf `.medium` (Dynamic-Type-sicher). |
| **Kontakte** (`SouveraContactsView`) | Avatar-Initialen von `customer`-Cyan auf `brandPrimaryDeep` (Kontrast); Zustände auf `SouveraStateView`. |
| **Notizen** (`SouveraNotesView`) | Hartkodiertes „Notizen" → lokalisierter `SouveraStateView`-Leerzustand. |
| **Transfers** (`NCTransfersView`) | Latenter `Color(Color(...))`-Doppel-Wrap in der Fortschrittsanzeige bereinigt; Brand-Token angewendet. |

---

## 3. Abweichungen vom Phase-1-Plan (mit Begründung)

| Plan-Vorgabe | Entscheidung | Begründung |
|---|---|---|
| Server-Theming (`use_themingColor`) auf „Souvera-first" schalten | **Beibehalten** (`true`) | Funktionserhalt: Souvera ist Managed-Hosting mit ggf. kundenspezifischem Server-Theming. Der Standard-Fallback ist bereits Souvera. Flippen wäre eine Verhaltensänderung ohne Freigabe. |
| Inconsolata-Font entfernen | **Noch nicht entfernt** | `project.pbxproj`-Ressourcen-Einträge + `UIAppFonts` entfernen ist ohne Build-Verifikation fehleranfällig; die Font ist funktional harmlos (ungenutzt). Als Folgeschritt dokumentiert. |
| Alle ~30 Screens vollständig umbauen | **Foundation + SwiftUI-Kernflächen** umgesetzt, große UIKit-/Viewer-/Login-Screens zurückgestellt | Kein Compiler/Simulator: unverifizierbare Großumbauten der kritischen Screens (Dateibrowser, Viewer, Share, Login) würden Compilerfehler-Risiko unverhältnismäßig erhöhen. |
| `Color.souvera`-Tokens statt Duplikate in `NCBrandColor` | Tokens nur in `UIColor.Souvera`/`Color.Souvera` | Vermeidung einer zweiten Wahrheitsquelle; `NCBrandColor.customer` bleibt als Alt-Schnittstelle erhalten. |
| Avatar-Palette komplett monochrom | Blau-Spektrum mit Vielfalt | Reine Monochromie würde Avatare ununterscheidbar machen (UX-Rückschritt). |

---

## 4. Technische Hinweise für den Build

- Neue Dateien müssen beim ersten macOS-Build ggf. einmal in Xcode „File > Synchronize" oder per
  Öffnen des Projekts bestätigt werden — die `project.pbxproj`-Referenzen sind bereits gesetzt.
- `SouveraStateView` nutzt `ContentUnavailableView` (iOS 17) — Deployment-Target ist 17.0, kein
  `#available` nötig.
- `SouveraToastCenter` ist bewusst **nicht** `@MainActor`-isoliert (vermeidet Static-Isolation-
  Warnungen in `ViewModifier`); Mutationen laufen zur Laufzeit auf dem Main-Thread.
- Es wurden **keine neuen Lokalisierungsschlüssel** eingeführt (verwendet: `_error_`, `_retry_`,
  `_souvera_notes_`, `_contact_empty_`, `_shield_empty_`, `_shield_load_error_` — alle vorhanden).
