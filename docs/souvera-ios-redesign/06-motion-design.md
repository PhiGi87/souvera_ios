<!-- SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors -->
<!-- SPDX-License-Identifier: GPL-2.0-or-later -->

# 06 — Motion Design

> Konsistente, subtile Motion-Sprache. Prinzip: schnell, hochwertig, nachvollziehbar, performant —
> **kein Effektfeuerwerk**. Alle Animationen respektieren `Reduce Motion` und `Dynamic Type`.

---

## 1. Leitwerte

| Eigenschaft | Wert |
|---|---|
| Dauer | 150–250 ms (Standard), 300 ms max für Sheet-/Push-Übergänge |
| Kurve | `.easeOut`/`.easeInOut`; iOS-Systemkurven bevorzugen (`.smooth`/`.spring(response:dampingFraction:)` dezent) |
| Fokus | nur Opazität, Transform, Position — **nie** Breite/Höhe/layout animieren |
| Reduzierbar | `@Environment(\.accessibilityReduceMotion)` → Instant-Übergang, kein Parallax |

## 2. Einsatzorte

| Ort | Motion | Haptik |
|---|---|---|
| Push/Pop (Navigation) | System-Übergang (nicht überschreiben) | — |
| Tab-Wechsel | subtiler Crossfade/Opacity (reduzierbar); kein hartes „Springen" | leichte Selection-Haptik |
| Auswahl (Liste/Toolbar) | 120 ms Opacity/Scale-Feedback | `UIImpactFeedbackGenerator` (light) |
| Expand/Collapse (Section, Quarantäne-Detail) | `.smooth`-Höhe/Fade, max 200 ms | — |
| Sheet-Präsentation | System; Detents-Drag | — |
| Erfolg (Senden, Speichern, Zustellen) | Symbol-Effekt `checkmark.circle.fill` `.bounce` (iOS 17+) | success-Haptik |
| Fehler | dezentes Shake/Fade des Toasts | error-Haptik |
| Refresh | native `refreshable`/`UIRefreshControl` | — |
| Loading → Content | 150 ms Fade-in (verhindert Flackern) | — |
| Empty → Content | Fade-in | — |
| Button-Feedback | Press-Scale (SF-Symbol `symbolEffect`) | light Haptik |
| Symbol Effects | `.bounce`/`.pulse` nur für Statusänderungen (ungelesen, Live) | — |

## 3. Symbol Effects (iOS 17+)

- Einsatz gezielt: `checkmark` (Erfolg), `bell.badge` (neue Benachrichtigung), `livephoto`, Kalender.
- Mit `#available`/`symbolEffect`-Fallbacks für ältere Systeme.

## 4. iOS 26 Liquid Glass Motion

- `glassEffectID` + `@Namespace` für **Morphing** nur bei ausgewählten Elementen (z. B. Floating
  „+" → Sheet). Fallback: Standard-Material + Fade.

## 5. Performance-Regeln

- Animierte Werte nur auf der Main-Thread-View-Ebene; keine Dauer-Animationen in `List`-Rows
  (per `Timer`/`TimelineView` sparsam).
- `withAnimation` gezielt; keine unbewussten Implicit-Animationen auf großen Datenmengen.
- `Task.sleep`-basierte Toasts (wie heute im Shield) über eine **zentrale** `SouveraToast`-Queue
  ersetzen, um Timer-Chaos zu vermeiden.

## 6. Haptik-Konvention

| Aktion | Generator |
|---|---|
| Primäre Aktion / Erfolg | `.medium`/success |
| Destruktiv | `.warning`/`.rigid` |
| Auswahl/Toggle | `.light` |
| Pull-to-Refresh abgeschlossen | success (einmalig) |
