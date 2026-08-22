<!-- SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors -->
<!-- SPDX-License-Identifier: GPL-2.0-or-later -->

# 02 — Souvera Markenanalyse

> Ziel: die Markenidentität erfassen, um sie **native** auf iOS zu übertragen. Nicht die Website
> nachbauen — die Identität in Apple-native Muster übersetzen. Originalassets haben Vorrang;
> es werden **keine** neue Wortmarke und **kein** neues Logo erfunden.

---

## 1. Markenkern

| Dimension | Wert |
|---|---|
| Marke | **Souvera** (Wortmarke „SOUVERA." mit Punkt) |
| Produkt | **Souvera Workspace** („ein digitaler Arbeitsplatz") |
| Claim | „Ihre Daten. Ihre Sicherheit. Ihr Workspace." |
| Positionierung | DSGVO-konforme Microsoft-365-Alternative, „Made & hosted in Germany" |
| Anbieter | Host-On Service Provider GmbH, Frankfurt am Main |
| Wertversprechen | Digitale Souveränität, Vertrauen, Sicherheit, Datenschutz, Verlässlichkeit |

Die Kernbegriffe der Marke sind **souverän, sicher, vertrauenswürdig, verlässlich, professionell**.
Das Design-Ziel muss genau diese Werte transportieren — nicht „spielerisch/bunt".

### Produktfamilie (alle dieselbe Handschrift)

- **Souvera Central** (Administration), **Souvera Mail**, **Souvera Shield** (Mail-Sicherheit)
- Dazu integrierte Module: **Dateien, Desk (Office), Link (Chat/Videokonferenz), Kalender & Kontakte**,
  zentrale Suche — und **Souvera AI** (in Entwicklung, „Demnächst").

Für die iOS-App heißt das: Mail, Dateien, Kalender, Link und Kontakte sind **ein Workspace**,
keine unabhängigen Apps.

---

## 2. Farben (aus Originalassets extrahiert)

### 2.1 Primär-/Akzentfarbe

- **Souvera-Blau `#4BBFEA`** (RGB 75/191/234) — entspricht exakt `NCBrandColor.customer`.
  Ein helles, klares Cyan-Blau: frisch, technisch, freundlich, aber nicht aggressiv.
- Kontrast-Info: `#4BBFEA` ist auf Weiß **nicht** AA-konform für normalen Text (Kontrast ≈ 1.9:1).
  Es ist eine **Akzent-/Flächenfarbe**, keine Textfarbe. Weißer Text auf `#4BBFEA` ist ebenfalls
  grenzwertig → für „on brand"-Text wird ein **dunklerer Blauton** benötigt.

### 2.2 Logo-Gradient (aus `logo.svg`, `intro1.svg`, `Souvera-logo-white.svg`)

Die Bildmarke ist ein abstraktes, geometrisches Zeichen aus **vier Segmenten** mit Blau-Verläufen:

| Stop | Hex | Rolle |
|---|---|---|
| `#4BBFEA` | Primär helles Cyan | Top-Segment (Start) |
| `#4D9DDA` | Mittelblau | Übergang |
| `#5AAADE` | Cyan-Blau | 2. Segment |
| `#496BBF` | Indigo-Blau | Tiefe |
| `#559DD8` | Hellblau | 3. Segment |
| `#4A65BC` | Tiefes Blau | Tiefe |
| `#3B86D0` | Kobalt | 4. Segment |

Die Marke lebt von einem **Blau-Spektrum von Cyan bis Indigo** — das ist die natürliche
Farbwelt für Souvera (nicht ein einzelnes Flachblau).

### 2.3 Ableitung für iOS (Light/Dark)

Die Website nutzt Weiß als Grundfläche und Blau als Akzent. Für iOS ergibt sich:

- **Brand Primary** (Akzent): `#4BBFEA` (Light), im Dark Mode leicht aufgehellt/entsättigt.
- **Brand Primary Deep** (für „on brand"-Flächen, Buttons, Links): ein dunklerer Blauton aus dem
  Logo-Gradient, z. B. `#3B86D0` oder `#0082C9`-nah. Dieser sichert AA-Kontrast.
- **Sekundär**: gedeckte Blau-/Grautöne, keine zweite Buntfarbe.
- **Status**: Systemfarben (Grün/Rot/Orange) bleiben erhalten, aber über **semantische Tokens**
  (nicht direkt).

> Hinweis: Der Skill `ui-ux-pro-max` lieferte für „sovereign secure productivity" ein generisches
> Violett-Palette-Ergebnis. Das wurde bewusst **verworfen** („do not persist unverified output"):
> Die echte Souvera-Identität ist Blau. Originalassets haben Vorrang.

---

## 3. Logo & Wortmarke

- **Bildmarke**: 4-Segment-Geometrie mit Blau-Verlauf (siehe oben). Liegt vor als:
  - `Brand/Custom.xcassets/logo.imageset/logo.svg` (Wortmarke „SOUVERA" mit Bildmarke, weiß auf
    Verlauf),
  - `AppIcon.icon/Assets/Souvera-logo-white.svg` (weiße Bildmarke auf Vollfläche),
  - `Brand/Custom.xcassets/intro1.svg` (Bildmarke pur, 4 Segmente).
- **Wortmarke**: „SOUVERA." — eigene, geometrische Buchstabenformen, mit finalem Punkt.
- **App-Icon** (`Brand/Custom.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png`): weiße
  Souvera-Bildmarke auf blauer Vollfläche (kein neues Icon nötig).

**Regel fürs Redesign:** Bildmarke und Wortmarke unverändert übernehmen. Die Bildmarke darf als
dezentes Markenzeichen (z. B. Login/Empty-State-Branding) verwendet werden, aber **nicht** als
Dekor-Element auf jedem Screen.

---

## 4. Typografie (Web) und Übertrag auf iOS

- Web verwendet eine klare, moderne serifenlose Grotesk mit kräftigen Headlines und viel Weißraum.
- **iOS-Übertrag**: **SF Pro (Systemfont)** — das ist die Apple-native, „deference"-konforme Wahl
  und die einzige sinnvolle Option für eine native App. Die gebündelte **Inconsolata** (Monospace)
  ist eine Nextcloud-Altlast und soll **entfernt** werden (keine Verwendung, keine Markenrelevanz).
- Markenpersönlichkeit entsteht auf iOS über **Weißraum, Gewicht und Hierarchie** — nicht über eine
  eigene Font.

---

## 5. Formensprache & Gesamtwirkung

- **Formen**: geometrisch, klar, segmentiert (Bildmarke). **Radien**: maßvoll rund (nicht pillig).
- **Illustrationen**: die Website zeigt Produkt-Screenshots statt bunter Illustrationen. Für iOS:
  **sparsam**, funktional, native SF-Symbol-basiert.
- **Icon-Stil**: SF Symbols (native) passen zur geometrischen Marke.
- **Gesamtwirkung**: hell, aufgeräumt, „souverän", viel Weiß, Blau als klares Signal.

---

## 6. Bestehende Brand-Assets im Projekt (Übersicht)

| Asset | Pfad | Verwendung |
|---|---|---|
| Brand-Optionen | `Brand/NCBrand.swift` (`NCBrandOptions`, `NCBrandColor`) | Zentrale Brand-Konfiguration |
| Logo (Wort+Bild) | `Brand/Custom.xcassets/logo.imageset/logo.svg` | LaunchScreen, Login |
| App-Icon | `Brand/Custom.xcassets/AppIcon.appiconset/` | App-Icon |
| Intro-Slides | `Brand/Custom.xcassets/intro1..4` | Onboarding |
| Icon-Bildmarke | `AppIcon.icon/Assets/Souvera-logo-white.svg` | Watch/Icon |
| LaunchScreen | `Brand/LaunchScreen.storyboard` | Start & Privacy-Screen |
| DB-Name | `Brand/Database.swift` (`souvera.realm`) | Persistenz |

---

## 7. Design-Direktiven aus der Marke (Zusammenfassung)

1. **Blau ist die einzige Markenfarbe** — Cyan→Indigo-Spektrum als Primär-/Tiefen-Akzent.
2. **Viel Weißraum, klare Hierarchie** — „souverän" = ruhig, nicht bunt.
3. **Wortmarke „SOUVERA."** — die Punkt-Schreibung ist Teil der Identität, aber nicht erzwingbar
   in jedem iOS-Label; primär für Login/About/Empty-State-Branding.
4. **Deutschland/Souveränität** darf subtil transportiert werden (Datenschutz-Hinweise im
   Login/Onboarding), ohne nationalistische Gesten.
5. **Souvera AI** als „Demnächst"-Thema nur dort erwähnen, wo es produktiv relevant ist (Assistant).
