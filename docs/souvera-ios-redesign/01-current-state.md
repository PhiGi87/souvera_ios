<!-- SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors -->
<!-- SPDX-License-Identifier: GPL-2.0-or-later -->

# 01 — Ist-Zustand der Souvera iOS App

> Dieses Dokument erfasst die technische Basis, die vollständige Screen-Übersicht und eine
> professionelle Design-Bewertung. Es ist die Analysegrundlage für das Redesign und wird
> in dieser Phase **nicht** umgesetzt.

---

## 1. Technische Basis

### 1.1 Projektursprung

Die App ist ein **Fork des Nextcloud iOS-Clients**, der zu „Souvera Workspace" umbenannt wurde
(Bundle-ID `eu.souvera.app`, Produktname „Souvera"). Der README beschreibt sie als eine App, die
„file sync, mail, calls and notes" vereint. Das prägt die Architektur fundamental: ein
**UIKit-Skelett mit einer schnell wachsenden SwiftUI-Inhaltsschicht**.

### 1.2 Build-Einstellungen (aus `Souvera.xcodeproj/project.pbxproj`)

| Einstellung | Wert | Bedeutung für das Redesign |
|---|---|---|
| `IPHONEOS_DEPLOYMENT_TARGET` | **17.0** (alle Targets) | `NavigationStack`, `@Observable`, iOS 17-`onChange`-Form, `.scrollEdgeAppearance`, `ContentUnavailableView`, Symbol Effects verfügbar |
| `SWIFT_VERSION` | 5.0 | Kein Swift-6-Zwang; Concurrency bereits weitgehend sauber (`@MainActor`, Actors, `@unchecked Sendable`) |
| `MARKETING_VERSION` | 33.1.0 | Erbt Versionsnummer von Nextcloud 33.x |
| `TARGETED_DEVICE_FAMILY` | 1,2 (iPhone + iPad) | iPad muss mitgedacht werden |
| `LastUpgradeCheck` | Xcode 26.4 | iOS-26-APIs (`Liquid Glass`) technisch erreichbar |

### 1.3 SwiftUI / UIKit-Verhältnis

- **~259 von 410 Swift-Dateien** importieren UIKit, **~120** importieren SwiftUI.
- **118 `struct …: View`**, **34 UIViewController-Klassen**.
- Die **neuere, nutzernahe Oberfläche ist fast vollständig SwiftUI**: Mail, Kalender, Link/Talk,
  Kontakte, Shield, More, Einstellungen, Assistant, Transfers, ToS, Maintenance.
- Das **Fundament ist UIKit** (mit Storyboards): Intro, Login, alle `NCCollectionViewCommon`-Dateilisten
  (Files/Favorites/Recent/Offline/Shares/Groupfolders), Media, Trash, Activity, Notifications,
  Share-Detail, Select, Scan, alle Dokument-Viewer (PDF/RichDocument/DirectEditing/QuickLook),
  Tab-Bar/Navigations-Gerüst.

Konsequenz: Ein Redesign darf **nicht** pauschal „alles auf SwiftUI umstellen". Die UIKit-Screens
bleiben funktional und werden primär über ein einheitliches Erscheinungsbild (Farben, Typografie,
Komponenten, Appearances) angeglichen.

### 1.4 Navigation

- Root-Router: `iOSClient/SceneDelegate.swift` installiert `NCMainTabBarController` als
  `window.rootViewController` (nach Maintenance-, Migrations- und Login-/Intro-Prüfungen).
- **5 Tabs** (`NCMainTabBarController.configureTabControllers()`):

| Index | Tab | Technik | Root |
|---|---|---|---|
| 0 | **Mail** (Start-Tab) | SwiftUI | `MailView()` |
| 1 | **Kalender** | SwiftUI | `SouveraCalendarView()` |
| 2 | **Link/Talk** | SwiftUI | `LinkView()` |
| 3 | **Dateien/Home** | UIKit | `NCFilesNavigationController` |
| 4 | **Mehr** | SwiftUI | `NCMoreView` in `NCMoreNavigationController` |

- SwiftUI-Tabs werden in `UIHostingController` in einer `UINavigationController` mit
  **ausgeblendetem UIKit-Bar** gehostet (`makeHostedTab`), damit SwiftUI eigene `NavigationStack`-Bars
  rendert. Daraus entsteht eine **doppelte Navigations-Welt**: SwiftUI-Tabs nutzen `NavigationStack`,
  UIKit-Tabs nutzen `UINavigationController`.
- `NCMainNavigationController` hängt global **rechte Bar-Buttons** an jede UIKit-Liste:
  Benachrichtigungen (bell), Assistant (sparkles), Transfers (arrows), Option (ellipsis) — plus einen
  **schwebenden „+"-Button** (nur auf `NCFiles`).

### 1.5 State Management

- **~30 Singletons** (`static let shared`): `NCGlobal`, `NCSession`, `NCAppStateManager`,
  `NCManageDatabase` (Realm), `NCNetworking`, `NCNetworkingProcess`, `NCImageCache`,
  `NCPreferences`, `NCBrandOptions`/`NCBrandColor`, `LinkVoIPManager`, `SceneManager`, u. a.
- **Drei parallele Muster**:
  1. `NotificationCenter` (Namen zentral in `NCGlobal`, z. B. `notificationCenterChangeTheming`),
  2. Combine `ObservableObject` + `@Published` (dominant bei neuen ViewModels: `MailViewModel`,
     `ShieldViewModel`, `CalendarViewModel`),
  3. SwiftUI `@Observable` (nur 8 Dateien, v. a. Assistant-Modul).
- **Keine Dependency Injection** — jeder Screen greift direkt auf Singletons zu; ViewModels werden
  mit `@StateObject` selbst erzeugt.

Konsequenz: Redesign-Views müssen weiter über `NCBrandColor`/`NCManageDatabase`/`NCNetworking`
lesen/schreiben. Ein State-Management-Wechsel ist **ausdrücklich nicht** geplant.

### 1.6 Networking & Persistenz

- **NextcloudKit** (SwiftPM) als zentraler HTTP-Client; `NCNetworking` als Singleton + Delegate.
- **Realm** (`souvera.realm`, schemaVersion 410) über `NCManageDatabase` (~30 Extensions).
- Neuere Souvera-Eigentransporte: JMAP (`JmapClient`, Standard via `useJmapMail`), IMAP/SMTP
  (SwiftNIO), Shield-API (`URLSession`), Link/Talk (OCS + WebRTC + HPB), CalDAV/CardDAV.

### 1.7 Vorhandene Design-System-Strukturen

Es existiert **kein zentrales Design-Token-System**. Konkret:

- **Farbe**: Ein zentrales Singleton `NCBrandColor` (`Brand/NCBrand.swift`) mit Brand-Farbe
  `customer = #4BBFEA` und **Server-Theming** (`getElement(account:)`). Semantische UIKit-Farben
  (`.label`, `.systemBackground`, …) werden weitgehend korrekt genutzt. **Kein** adaptives
  Farb-Asset-Catalog (nur `SystemBackgroundInverted.colorset`).
- **Typografie**: Dynamic Type ist erste Klasse (`UIFont+Extension` mit `maximumPointSize`-Caps,
  SwiftUI `View.cappedFont`). Ein gebündelter Monospace-Font **Inconsolata** (8 Schnitte) ist
  registriert, wird aber **nirgends verwendet** (Nextcloud-Altlast).
- **Icons**: SF Symbols dominant; gebündelte Bilder sind die tintbare „folder/file"-Familie.
  Zentrale Auflöser: `NCUtility.loadImage` und `NCImageCache`.
- **Corner-Radien/Spacing**: hartkodierte Magic Numbers überall (`3, 5, 6, 8, 10, 11, 12, 14, 15,
  16, 20, 22, 25, 30, 40`, `.infinity`). Kein einheitlicher Maßstab.
- **Globales Appearance-Setup**: fehlt. Nur ein einziger `appearance()`-Call (Third-Party `DropDown`
  in `NCShare.swift`). Keine zentrale `UINavigationBar`/`UITabBar`-Konfiguration.

### 1.8 Dark Mode / Accessibility

- Dark Mode über Nutzer-Einstellung (`appearanceAutomatic` / `appearanceInterfaceStyle`), angewendet
  via `overrideUserInterfaceStyle` auf alle Fenster; einige SwiftUI-Screens mit
  `.preferredColorScheme(...)`.
- **Lücken**: iOS-spezifische Accessibility-Patterns (SwiftUI `.accessibility*`-Modifier,
  `ContentUnavailableView`, „Loading → Content"-Übergänge) werden **nicht konsistent** genutzt.

---

## 2. Vollständige Screen-Übersicht

### 2.1 Onboarding & Login

| Screen | Datei | Technik | Erreichbar über |
|---|---|---|---|
| Intro/Onboarding (4-Slide-Karussell) | `Brand/Intro/NCIntroViewController.swift` | UIKit | Start ohne Account |
| Login (Slug-Login, QR, Login Flow v2) | `iOSClient/Login/NCLogin.swift` | UIKit | Intro „Log in" |
| Login-WebView-Fallback (mTLS) | `iOSClient/Login/NCLoginProvider.swift` | UIKit | Login |
| QR-Scanner | `iOSClient/Login/NCLoginQRCode.swift` | UIKit | Login |
| Zertifikat-Details | `iOSClient/Login/NCViewCertificateDetails.swift` | UIKit | SSL-Dialog |

### 2.2 Mail (Tab 0, SwiftUI)

- `MailView` (ein `NavigationStack`): Ordnerliste → Nachrichtenliste → Detail → Verfassen → Suche.
- Unteransichten: `MailFolderListView`, `MailMessageListView`, `MailMovePickerView`,
  `MailSearchView`, `MailDetailView`, `MailComposeView`, `MailSendBanner`, `AutoRefreshRingView`.
- Sheets: `ContactPickerSheet`, `NextcloudFilePickerView`.

### 2.3 Kalender (Tab 1, SwiftUI)

- `SouveraCalendarView`: Tag-/3-Tage-/Monatsansicht, Suche, Plus (Termin), Kalender-Picker.
- Sheets: `CalendarPickerSheet`, `CalendarEventDetailSheet`, `CalendarEventEditSheet`, Feedback-Toast.

### 2.4 Link/Talk (Tab 2, SwiftUI + UIKit-Call)

- `LinkView`: `LinkConversationListView` → `LinkChatView`.
- `LinkCallViewController` (UIKit, WebRTC): Vollbild-Call mit Remote-/Self-Video, Mute/Video/Auflegen.
- `IncomingCallOverlayView`, Call-Banner („zurück zum Anruf").

### 2.5 Dateien/Home (Tab 3, UIKit)

- `NCFiles` (`NCCollectionViewCommon`): Ordner als Liste/Raster/Foto, Suche, Rich-Workspace-Header,
  Empfehlungen, Pull-to-Refresh, E2EE.
- Gleiche Basis für: **Favoriten, Recent, Offline, Shares, Groupfolders** (je `NCCollectionViewCommon`
  mit eigenem `layoutKey` + Empty-State-Copy).
- **Media** (`NCMedia`), **Trash** (`NCTrash`) — eigene UIKit-Screens.
- Zellen: `NCListCell`, `NCGridCell`, `NCPhotoCell`, `NCRecommendationsCell`.

### 2.6 Mehr (Tab 4, SwiftUI)

- `NCMoreView` (von `NCMoreModel` getrieben): Account-Header, „Mehr Apps"-Shortcuts, Auto-Upload,
  Menüliste (Favoriten, Media, Activity, Kontakte, Shield, Recent, Shares, Offline, Groupfolders,
  Scan, Trash), externe Seiten, Einstellungen, Quota, Build-Label.

### 2.7 Kontakte & Shield (aus „Mehr", SwiftUI)

- `SouveraContactsView` (+ `ContactDetailSheet`, `ContactEditSheet`, `DirectoryUserDetailSheet`).
- `ShieldView`: Quarantäne/Whitelist/Blacklist, `ShieldDetailSheet`, `ShieldReleaseSheet`.
- `SouveraNotesView`: **Platzhalter** („Notizen").

### 2.8 Assistant (modal, SwiftUI)

- `NCAssistant` (Typ-/Task-/Chat-Modus), `NCAssistantChat`, `NCAssistantChatConversations`,
  `NCAssistantTaskDetail`, `NCAssistantCreateNewTask`, Empty-/ChatInput-/Status-Komponenten.

### 2.9 Activity, Notifications, Transfers

- `NCActivity` (UIKit), `NCNotification` (UIKit, PageSheet), `TransfersView` (SwiftUI, PageSheet).

### 2.10 Viewer (Dateivorschau, gemischt)

- `NCViewer`-Router → Media (`NCMediaViewerView`, SwiftUI), PDF, RichDocument, DirectEditing,
  QuickLook (UIKit), Context-Menu (`NCViewerProviderContextMenu`), Rich-Workspace-Header.

### 2.11 Share, Select, Account, Settings, Creation

- **Share**: `NCShare` (UIKit) + `NCSharePaging` (Activity/Sharing-Tabs), `NCTagEditorView` (SwiftUI),
  Advanced-Permissions/Download-Limit.
- **Select**: `NCSelect` (UIKit) + SwiftUI-Wrapper `SelectView`.
- **Account**: `NCAccountSettingsView` (SwiftUI), `NCAccountRequest`, `NCShareAccounts`,
  `NCStatusMessageView`, `NCUserStatusView`.
- **Settings**: `NCSettingsView` + Display/Advanced/Auto-Upload/E2EE/Acknowledgements/Browser/Passcode.
- **Creation**: `NCContextMenuPlus`, `NCUploadAssetsView` (SwiftUI), `UploadConflictView` (SwiftUI),
  `NCScan`/`NCUploadScanDocument`, `NCAudioRecorder`, `NCColorPicker`, `NCBrowserWeb`.

### 2.12 Globale Overlays

- `Lucid Banner`-System (Error/Info/Warning/Hud/Upload-Banner), `NCHUDView`, `NCPopupViewController`.
- Privacy-Screen (LaunchScreen), Passcode (`TOPasscodeViewController`).

---

## 3. Design-Bewertung (aus Sicht eines iOS Product Designers)

### 3.1 Gesamteindruck

Die App fühlt sich derzeit **wie zwei Apps** an:

1. **Nextcloud-Erbe** (UIKit-Dateibrowser, Login, Viewer, Share) — funktional und solide, aber
   generisch, technisch, ohne Souvera-Identität.
2. **Neue SwiftUI-Module** (Mail, Kalender, Link, Kontakte, Shield, More) — moderner, aber
   untereinander **nicht konsistent** und teils „Web-/AI-lastig".

### 3.2 Konkrete Inkonsistenzen (mit Beleg)

1. **Brand-Farbe wird inkonsistent verwendet.**
   - `NCBrandColor.customer = #4BBFEA` (Souvera) — aber `NCMoreView.swift:19` definiert
     `shortcutIconColor = Color(red: 0, green: 130/255, blue: 201/255)` mit Kommentar
     „Nextcloud Color" (= `#0082C9`). Die „Mehr Apps"-Shortcuts sind **Nextcloud-blau**, der Rest Souvera.
   - `Brand/LaunchScreen.storyboard:24` hat Hintergrund `red 0, green 0.5098, blue 0.788` =
     `#0082C9` (Nextcloud-Blau) statt Souvera `#4BBFEA`.
   - `NCBrandColor.createUserColors()` erzeugt Avatar-Paletten aus Nextclouds
     Rot/Gelb/Blau (`#B6469D`, `#DDCB55`, `#0082C9`) — nicht Souvera.
   - Server-Theming (`use_themingColor = true`) kann die Souvera-Farbe zur Laufzeit **überschreiben**.

2. **Kein einheitliches Farbsystem für Zustände.**
   - Shield nutzt `.tint(.green)` für „Zustellen", `.orange` für Warnungen, `.red` für Fehler — mit
     Systemfarben gemischt, nicht über semantische Tokens. Mail verwendet eigene Banner-Töne.

3. **Viel zu viele eigene „Cards".**
   - `NCMoreView` baut Account-Header (Gradient + `cornerRadius:16` + Stroke + Shadow),
     Menü-Sections (`cornerRadius:14`) und Shortcut-Buttons als **selbstgebastelte Cards** statt
     nativer `.insetGrouped`-`List`. Das ist genau das generische „alles in abgerundeten Containern"-
     Muster, das vermieden werden soll.

4. **Loading-/Empty-/Error-States sind ad-hoc.**
   - Shield (`ShieldView.swift`) verwendet `Spacer(); ProgressView(); Spacer()` und
     `Text(...).foregroundStyle(.secondary)` als Empty-State — statt `ContentUnavailableView`
     (iOS 17+). Kein einheitliches Muster über Module hinweg.

5. **Doppelte Navigations-Chrome.**
   - SwiftUI-Tabs zeichnen eigene `NavigationStack`-Bars, UIKit-Tabs nutzen
     `UINavigationController`. Toolbar-Buttons (bell/sparkles/transfers/ellipsis) existieren nur im
     UIKit-Bereich; SwiftUI-Tabs haben eigene, abweichende Toolbars.

6. **Hartkodierte Metriken.**
   - Corner-Radien 3–40, Spacing-Literale überall. Keine Quelle für Konsistenz.

7. **Liquid-Glass-Fallback vorhanden, aber uneinheitlich.**
   - `NCMainNavigationController` hat bereits einen iOS-26-Sonderpfad für den „+"-Button
     (Zeile 122–141), aber ohne zentrale Design-Sprache.

### 3.3 Markierte Probleme (Kurz-Klassifikation)

| Kategorie | Befund |
|---|---|
| Inkonsistenz | Brand-Farbe vs. Nextcloud-Blau; Toolbars; Cards; Metriken |
| Technisch wirkend | Dateibrowser-Listen, Viewer, Share (Nextcloud-Erbe) |
| Web-/AI-ähnlich | `NCMoreView`-Card-Sammlung, Gradient-Header |
| Generische UI | Empty/Error/Loading als `Text`/`ProgressView` |
| Fehlendes Branding | Start-/Login-/Einstellungs-Screens tragen kaum Souvera-Identität |
| UX-Probleme | Doppel-Navigation; Quarantäne-Release-Sheet mit fixen Detents; Misch-Kommentarsprachen |

### 3.4 Positiv (erhaltenswert)

- Dynamic Type ist grundsätzlich angelegt (`UIFont+Extension`, `cappedFont`).
- Semantische Systemfarben in weiten Teilen korrekt.
- SF Symbols als primäres Icon-System (modern).
- Neuere ViewModels sauber `@MainActor` + `ObservableObject`/`@Published`.
- iPad/Multi-Window und Dark-Mode-Grundgerüst vorhanden.
