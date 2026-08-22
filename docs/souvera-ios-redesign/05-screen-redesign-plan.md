<!-- SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors -->
<!-- SPDX-License-Identifier: GPL-2.0-or-later -->

# 05 — Screen-by-Screen Redesign-Plan

> Für jeden relevanten Screen: Ist-Zustand, Probleme, Zielrichtung, Komponenten, Interaktionen,
> technischer Änderungsumfang, Risiko. Risikobewertung = Gefahr, bestehende Funktionalität zu brechen.

---

## A. Onboarding & Login

### A.1 Intro / Onboarding
- **Aktueller Zustand:** UIKit-Karussell (`NCIntroViewController`, 4 Slides aus `intro1..4`), Log-in-Button, „Sign up"/„Host your own" für Souvera ausgeblendet.
- **Probleme:** veraltete Storyboard-Optik, Brand-Farben teils Nextcloud, wenig Souvera-Identität, keine souveränitätsbezogene Aussage.
- **Zukünftige Designrichtung:** native SwiftUI-Intro (`TabView` mit Seiten-Paging) in Souvera-Blau: 3–4 Slides, die die Workspace-Module (Mail, Dateien, Kalender/Link, Shield/Sicherheit) vorstellen; dezente „Made & hosted in Germany"-Note; klarer primärer „Anmelden"-CTA.
- **Komponenten:** `SouveraButtonStyle`, Bildmarke/`intro*`-SVGs, `SouveraSectionHeader`.
- **Interaktionen:** Seiten-Übergang (reduzierbar), Button-Haptik.
- **Technischer Änderungsumfang:** neue SwiftUI-Intro-View; `SceneDelegate`-Zweig statt Storyboard; `disable_intro`-Logik erhalten.
- **Risiko:** MEDIUM (Start-Router ändert sich).

### A.2 Login
- **Aktueller Zustand:** `NCLogin` (UIKit): Slug-Feld, Logo, Log-in, QR, Zertifikat, Server-Picker.
- **Probleme:** technische Optik, Inkonsistente Markenfarbe, kein Lade-/Fehler-Komfort, Web-/Nextcloud-Look.
- **Zukünftige Designrichtung:** SwiftUI-Login: Bildmarke zentriert, Slug-Eingabe mit `brandPrimaryDeep`-Tint, prominenter CTA, QR als Icon-Button, sauberer Loading-/Fehlerzustand, DSGVO-/Souveränitäts-Hinweis.
- **Komponenten:** `SouveraButtonStyle`, `SouveraTextField`-Stil, `SouveraLoadingView`, `SouveraErrorState`.
- **Interaktionen:** Login-Flow (ASWebAuthenticationSession) unverändert; Button-Haptik, Keychain-Anzeige.
- **Technischer Änderungsumfang:** neue SwiftUI-View um `NCLoginProvider`-Logik herum; `NCLogin`-Storyboard ersetzen.
- **Risiko:** HIGH (Login-Flow ist kritisch; `NCLoginProvider`, QR, Zertifikat müssen erhalten bleiben).

### A.3 QR-Scanner & Zertifikat-Detail & WebView-Fallback
- **Probleme:** reine UIKit-Altlasten ohne Markenbezug.
- **Ziel:** optische Angleichung (Farben, Navigation-Titel) ohne Logikänderung.
- **Komponenten:** Tokens.
- **Änderungsumfang:** kosmetisch.
- **Risiko:** LOW.

---

## B. Mail (Tab 0)

### B.1 Ordnerliste (`MailFolderListView`)
- **Probleme:** eigene Baum-Rows, uneinheitliche Metriken.
- **Ziel:** native `List` mit einheitlichen `SouveraListRow`, Ordner-Icons (SF Symbols), Badge für ungelesene Counts.
- **Komponenten:** `SouveraListRow`, `SouveraBadge`.
- **Interaktionen:** Auswahl-Feedback, Pull-to-Refresh.
- **Änderungsumfang:** `MailView.swift`/`MailViewModel.swift`.
- **Risiko:** LOW.

### B.2 Nachrichtenliste (`MailMessageListView`)
- **Ziel:** native Liste, klare Hierarchie (Absender/Subjekt/Datum), Swipe-Aktionen (Flag/Gelesen/Archiv), einheitliche Empty/Loading.
- **Komponenten:** `SouveraEmptyState`, `SouveraLoadingView`, `SouveraListRow`.
- **Interaktionen:** Swipe (leading = Flag, trailing = Archiv/Löschen), Kontextmenü.
- **Änderungsumfang:** `MailView.swift`.
- **Risiko:** LOW.

### B.3 Nachrichten-Detail (`MailDetailView`)
- **Ziel:** aufgeräumter Header, native Toolbar (Antworten/Weiterleiten/Flag/Verschieben), konsistente Anhangsdarstellung.
- **Komponenten:** `SouveraIconButton`, `SouveraBadge`.
- **Interaktionen:** Toolbar-Haptik, „Zustellen/Ablehnen"-Feedback (Shield-Verknüpfung).
- **Änderungsumfang:** `MailView.swift`.
- **Risiko:** LOW.

### B.4 Verfassen (`MailComposeView`) & Kontakt-/Datei-Picker
- **Ziel:** nativer Compose-Sheet, `SouveraTextField`, Empfänger-Chips, konsistenter Senden-CTA + Send-Banner.
- **Komponenten:** `SouveraButtonStyle`, `SouveraToast`, `SouveraBadge`.
- **Interaktionen:** Send-Feedback (Erfolg/Fehler), Haptik.
- **Änderungsumfang:** `MailComposeView`, `ContactPickerSheet`, `NextcloudFilePickerView`.
- **Risiko:** MEDIUM (Compose-Flow).

### B.5 Suche (`MailSearchView`) / Verschieben (`MailMovePickerView`)
- **Ziel:** native `.searchable`/Picker-Sheets mit einheitlichem Stil.
- **Risiko:** LOW.

---

## C. Kalender (Tab 1)

### C.1 Hauptansicht (`SouveraCalendarView`)
- **Probleme:** eigener Tag/3-Tage/Monat-Wechsel, teils unruhig.
- **Ziel:** nativer Segmented-Header, klarer Tagesfokus, `brandPrimaryDeep`-Akzent für „heute", einheitliche Event-Zellen, reduzierter Floating-Add.
- **Komponenten:** `SouveraSectionHeader`, `SouveraIconButton`, `SouveraEmptyState`.
- **Interaktionen:** Segmented-Switch (reduzierbar), Kalender-Scroll, Pull-to-Refresh.
- **Änderungsumfang:** `SouveraCalendarView.swift`, `CalendarViewModel.swift`.
- **Risiko:** MEDIUM.

### C.2 Termin-Detail / -Edit / Kalender-Picker (Sheets)
- **Ziel:** native Sheets mit `PresentationDetent`-Kurven (statt fixer Höhen), konsistente Formularfelder, prominenter „Speichern".
- **Komponenten:** `SouveraSheetHeader`, `SouveraButtonStyle`, Form.
- **Interaktionen:** Save-Feedback-Toast, Haptik.
- **Risiko:** MEDIUM (Kalender-Schreiblogik).

---

## D. Link / Talk (Tab 2)

### D.1 Konversationsliste (`LinkConversationListView`)
- **Ziel:** native Liste, Avatar+Name+Hinzufügen von Letzter-Nachricht, einheitliche Badges (ungelesen).
- **Komponenten:** `SouveraListRow`, `SouveraAvatar`, `SouveraBadge`.
- **Interaktionen:** Swipe (stummschalten/verlassen), Kontextmenü.
- **Risiko:** LOW.

### D.2 Chat (`LinkChatView`)
- **Ziel:** aufgeräumter Nachrichtenfluss, native Toolbar mit Anruf-Buttons, einheitliche Eingabeleiste.
- **Komponenten:** `SouveraIconButton`, `SouveraEmptyState`.
- **Interaktionen:** Anruf-/Teilnahme-Feedback, Haptik.
- **Risiko:** MEDIUM (Call-Übergabe).

### D.3 Call (`LinkCallViewController`) & Incoming-Overlay
- **Ziel:** nur kosmetische Angleichung (Farben/Tint), WebRTC-Logik unverändert.
- **Risiko:** LOW–MEDIUM (keine Logikänderung).

---

## E. Dateien / Home (Tab 3) — UIKit

### E.1 Dateibrowser (`NCFiles`/`NCCollectionViewCommon`)
- **Probleme:** technischer Look, unruhige Optionen, uneinheitliche Empty/Loading.
- **Ziel:** einheitliche Listen-/Raster-/Foto-Zellen über Tokens; semantische `NCBrandColor`-Tints;
  einheitliche Empty-States; `brandSurface`-Akzent für Auswahl; Toolbar-Chrome vereinheitlichen.
- **Komponenten:** Tokens + `SouveraEmptyState`-Äquivalent (UIKit-Variante), `SouveraBadge`.
- **Interaktionen:** Pull-to-Refresh, Swipe, Kontextmenü (bleiben), Auswahl-Haptik.
- **Änderungsumfang:** `NCCollectionViewCommon`, Zellen (`NCListCell`/`NCGridCell`/`NCPhotoCell`),
  `NCSectionFirstHeaderEmptyData`, `NCMainNavigationController`.
- **Risiko:** HIGH (zentrale Datei-Engine; rein visuell bleiben, keine Datenlogik anfassen).

### E.2 Favoriten / Recent / Offline / Shares / Groupfolders
- **Ziel:** erben die Änderungen von E.1 automatisch (gleiche Basisklasse); nur Empty-State-Copy/Icon anpassen.
- **Risiko:** LOW (profitieren von E.1).

### E.3 Media-Galerie (`NCMedia`) & Trash (`NCTrash`)
- **Ziel:** kosmetische Angleichung, einheitliche Edit-/Select-Bars.
- **Risiko:** MEDIUM (eigene UIKit-Screens).

---

## F. Mehr (Tab 4)

### F.1 `NCMoreView`
- **Probleme:** Card-Sammlung, Gradient-Header, hartkodiertes Nextcloud-Blau, eigene Divider.
- **Ziel:** native `List` (`.insetGrouped`) mit Account-Header, „Mehr Apps"-Sektion, Menü-Zeilen;
  `brandPrimary`-Tint; Quota als schlanke Progress-Row. **Keine** eigenen Cards mehr.
- **Komponenten:** `SouveraListRow`, `SouveraAvatar`, `SouveraBadge`, nativer Fortschritt.
- **Interaktionen:** Menü-/Push-Navigation (bleibt), Account-Switch-Menü.
- **Änderungsumfang:** `NCMoreView.swift`, `NCMoreModel.swift` (nur Optik).
- **Risiko:** LOW–MEDIUM (viel Verhalten in `NCMoreModel.perform` — unangetastet).

---

## G. Kontakte, Shield, Notes

### G.1 Kontakte (`SouveraContactsView` + Sheets)
- **Ziel:** native Liste mit Suche, einheitliche Detail-/Edit-Sheets, Avatar-Fallbacks.
- **Komponenten:** `SouveraListRow`, `SouveraAvatar`, `SouveraEmptyState`.
- **Risiko:** LOW.

### G.2 Shield (`ShieldView` + Detail/Release-Sheets)
- **Probleme:** ad-hoc Loading/Empty (`ProgressView`/`Text`), fixe Sheet-Detents, `.green`-Tint.
- **Ziel:** `ContentUnavailableView` für Empty/Error, `SouveraLoadingView`, Detents über Kurven,
  `success`/`warning`/`error`-Tokens, einheitlicher Feedback-Toast.
- **Komponenten:** `SouveraEmptyState`, `SouveraErrorState`, `SouveraLoadingView`, `SouveraToast`.
- **Interaktionen:** Swipe-Aktionen bleiben, Release-Bestätigung mit Haptik.
- **Änderungsumfang:** `ShieldView.swift`, `ShieldDetailSheet`, `ShieldReleaseSheet`.
- **Risiko:** LOW (ViewModel/API unangetastet).

### G.3 Notes (`SouveraNotesView`)
- **Ziel:** konsistenter Platzhalter (`ContentUnavailableView`), bis das Modul kommt.
- **Risiko:** LOW.

---

## H. Assistant (modal)

### H.1 `NCAssistant` + Chat/Task/Conversations
- **Ziel:** einheitliche Navigation, native Chat-/Typ-/Task-Listen, konsistente Eingabeleiste,
  `brandPrimary`-Akzent für AI (dezent).
- **Komponenten:** `SouveraListRow`, `SouveraEmptyState`, `ChatInputField` (vereinheitlicht).
- **Risiko:** MEDIUM (neue Feature-Fläche, `@Observable`-Modelle erhalten).

---

## I. Activity, Notifications, Transfers

### I.1 Activity (`NCActivity`, UIKit)
- **Ziel:** kosmetische Angleichung (Farben, Zellen), einheitlicher Footer.
- **Risiko:** LOW.

### I.2 Notifications (`NCNotification`, UIKit)
- **Ziel:** native Sheet-Optik, einheitliche Zeilen/Empty.
- **Risiko:** LOW.

### I.3 Transfers (`TransfersView`, SwiftUI)
- **Ziel:** einheitliche Status-Pills (`SouveraBadge`), konsistente Empty/Loading, native Sheet-Detents.
- **Komponenten:** `SouveraBadge`, `SouveraEmptyState`, `SouveraLoadingView`.
- **Risiko:** LOW.

---

## J. Viewer (Dateivorschau)

### J.1 Media-Viewer (`NCMediaViewerView`) & PDF/Rich/DirectEditing/QuickLook
- **Ziel:** nur kosmetische Angleichung (Tint, Toolbar-Icons, Statusleiste). **Keine**
  Wiedergabe-/Render-Logik anfassen.
- **Risiko:** MEDIUM (sehr funktionskritisch; strikt visuell).

### J.2 Rich-Workspace-Header
- **Ziel:** dezentes `brandSurface`-Styling.
- **Risiko:** LOW.

---

## K. Share, Select

### K.1 Share-Detail (`NCShare` + `NCSharePaging` + Advanced)
- **Ziel:** kosmetische Angleichung (Farben, Zellen, Tag-Editor-Tokens).
- **Risiko:** MEDIUM.

### K.2 Select (`NCSelect` + SwiftUI-Wrapper)
- **Ziel:** optische Angleichung; Auswahl-/Copy/Move-Logik unverändert.
- **Risiko:** LOW–MEDIUM.

---

## L. Account-Screens

### L.1 Account-Einstellungen (`NCAccountSettingsView`)
- **Ziel:** native `Form`, einheitliche Avatare, konsistente Aktionen (Hinzufügen/Löschen).
- **Risiko:** LOW.

### L.2 Account-Request / Share-Accounts (UIKit-Popups)
- **Ziel:** optische Angleichung über `NCPopupViewController`-Tokens.
- **Risiko:** LOW.

### L.3 Status / User-Status (SwiftUI)
- **Ziel:** einheitliche Liste/Emoji-Auswahl, semantische Statusfarben.
- **Risiko:** LOW.

---

## M. Einstellungen

### M.1 `NCSettingsView` + Display/Advanced/Auto-Upload/E2EE/Acknowledgements/Browser/Passcode
- **Ziel:** native `Form`-Hierarchie, einheitliche `SouveraListRow`, konsistente Toggles,
  `brandPrimaryDeep`-Akzent, saubere Unter-Screens. Auto-Upload-Animation behalten, aber über Tokens.
- **Komponenten:** `SouveraListRow`, `SouveraSectionHeader`, `SouveraButtonStyle`.
- **Risiko:** LOW–MEDIUM (viele Unter-Screens; rein visuell).

---

## N. Creation & Picker

### N.1 Plus-Menü, Upload, Scan, Audio, Color, Browser
- **Ziel:** einheitliche Menü-Optik (`SouveraIconButton`/Tint), konsistente Sheets.
- **Risiko:** LOW–MEDIUM.

---

## O. Globale Overlays

### O.1 Lucid Banner / HUD / Popup / Passcode / Privacy-Screen
- **Ziel:** Banner-Farben/Tokens vereinheitlichen (`success`/`warning`/`error`), einheitliche Radien,
  Launch-/Privacy-Screen-Hintergrund auf Souvera-Blau (#4BBFEA statt #0082C9).
- **Komponenten:** `SouveraToast` (perspektivisch ersetzt ad-hoc Banner), Tokens.
- **Risiko:** LOW.

---

## Risiko-Zusammenfassung

| Risiko | Screens |
|---|---|
| HIGH | Login, Dateibrowser (`NCCollectionViewCommon`) |
| MEDIUM | Intro, Mail-Compose, Kalender, Chat, Media/Trash, Viewer, Share, Settings, Assistant |
| LOW | alles Übrige (rein kosmetisch) |
