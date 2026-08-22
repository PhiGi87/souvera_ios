<!-- SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors -->
<!-- SPDX-License-Identifier: GPL-2.0-or-later -->

# 08 — Abnahmekriterien

> Kriterien, wann das Redesign als abgeschlossen gilt. Jede Zeile ist prüfbar.

---

## 1. Vollständigkeit

- [ ] Alle vom Nutzer erreichbaren Screens (siehe `01-current-state.md` §2) angepasst.
- [ ] Kein Screen zeigt noch „Nextcloud-Look"/Alt-Styles (explizit prüfen: Login, Dateibrowser, Viewer, Share).
- [ ] Keine Placeholder-UI und keine Mock-Daten als Ersatz produktiver Daten.
- [ ] Keine „TODO-Redesign"-Screens oder auskommentierte Alt-Views.

## 2. Branding

- [ ] Souvera-Blau (`#4BBFEA`-Spektrum) konsistent; **kein** hartkodiertes `#0082C9` mehr.
- [ ] Wortmarke/Bildmarke korrekt und nur an vorgesehenen Stellen (Login, About, Empty-State-Branding, Launch).
- [ ] Launch-/Privacy-Screen-Hintergrund = Souvera-Blau.
- [ ] Alle Module wirken als **ein** Workspace (gleiche Tokens, gleiche Komponenten, nur dezente Modul-Akzente).

## 3. Design-System

- [ ] Alle Farben/Metriken über Tokens (keine neuen Magic Numbers in produktiven Views).
- [ ] Komponenten-Katalog wird tatsächlich genutzt (keine parallelen Eigenimplementierungen).
- [ ] Native Muster bevorzugt (`List`/`Form`, `ContentUnavailableView`, `.toolbar`, `.sheet`,
      `.confirmationDialog`, `.searchable`, `.menu`, Swipe-Actions).

## 4. Light & Dark Mode

- [ ] Light Mode vollständig korrekt.
- [ ] Dark Mode vollständig korrekt (adaptiv über Tokens, keine „invertierten" Hartfarben).
- [ ] Kontrast AA (4.5:1) für Text; Markenfarbe nur als Akzent/Fläche, nicht als Textfarbe.

## 5. Geräte & Größen

- [ ] Kleine iPhones (SE/13 mini) und große iPhones (Pro Max) geprüft.
- [ ] iPad geprüft (Split/Mehrspaltig, Popover statt Sheet wo nötig).
- [ ] Dynamic Type von klein bis `accessibility2` geprüft — keine abgeschnittenen Texte/überlaufenden
      Komponenten; Sheets nutzen Detent-Kurven (keine fixen Höhen).

## 6. Motion & Accessibility

- [ ] Reduce Motion respektiert (Instant-Übergänge, kein Parallax).
- [ ] VoiceOver: alle interaktiven Elemente mit Label/Trait; Gesten haben Button-/Menü-Alternativen.
- [ ] Touch-Targets ≥ 44 pt; Abstand zwischen Targets ≥ 8 pt.

## 7. Technische Abnahme

- [ ] Keine Compilerfehler; SwiftLint sauber.
- [ ] Bestehende Funktionen erhalten (Sync, Upload/Download, Mail JMAP/IMAP, Kalender CalDAV,
      Kontakte CardDAV, Talk/Calls, Shield, Login-Flow, Multi-Account, Deep Links).
- [ ] Keine Backend-/API-/State-Management-/Architektur-Änderungen ohne ausdrückliche Freigabe.
- [ ] Keine offensichtlichen Layoutfehler (Log-Inspection, Simulator-Durchlauf).
- [ ] Unit-Tests (Swift Testing) für neue Tokens/Komponenten grün; Bestandstests nicht gebrochen.

## 8. Daten- & Code-Qualität

- [ ] Keine Log-/Debug-Ausgaben von Secrets/Tokens.
- [ ] Einheitliche Kommentarsprache (keine gemischten DE/EN-Fragmente in neuem Code).
- [ ] Neue Dateien mit SPDX-Header (Jahr der Erstellung).

---

## Abnahme-Ritual

1. **Automatisch:** Build + SwiftLint + `xcodebuild test` (Unit/Integration).
2. **Manuell:** kompletter Screen-Durchlauf in Light/Dark auf zwei Gerätegrößen + iPad.
3. **Accessibility:** VoiceOver + Dynamic-Type-Max + Reduce Motion Durchlauf.
4. **Regression:** Kern-Flows (Login → Mail senden/empfangen, Datei-Upload/-Download, Termin,
   Talk-Call, Shield-Release) einmal end-to-end.
