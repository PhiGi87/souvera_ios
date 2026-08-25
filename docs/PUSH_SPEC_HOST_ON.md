# Push-Spezifikation für Host-On (Souvera Server)

Dieses Dokument beschreibt die Server-seitigen Erweiterungen, die die
Souvera-iOS-App benötigt, um **Mail-Push** und **Kalender-Push** (inkl.
zuverlässiger Erinnerungen) zu liefern. Die App-Seite ist bereits
vorbereitet (Deep-Links, Hintergrund-Resync, Termin-Detail).

## Grundlage

- Push-Kette: Nextcloud-Notification -> Push-Proxy (push.souvera.eu) ->
  APNs -> iOS-App (Notification Service Extension entschlüsselt und zeigt
  die Notification).
- Routing (bereits aktiv, `PushController`/`pushcontroller.php`):
  Non-Talk-Apps -> alle Non-Talk-Geräte; Talk-Apps (`spreed`, `talk`,
  `admin_notification_talk`) -> Talk-Geräte (VoIP-Kanal).

## 1. Mail-Push (App-Id `souvera_mail`)

**Ziel:** Bei einer neuen Mail im Posteingang erhält der Benutzer sofort
eine Push-Notification - unabhängig davon, ob die App offen ist.

**Server (souvera_mail):**
1. Beim Zustellen/Erkennen einer neuen Mail im Posteingang eine
   Nextcloud-Notification erzeugen:
   - `app` = `souvera_mail`
   - `objectId`/`id` = JMAP-E-Mail-Id (z. B. `"dpzmaaa91l"`)
   - `subject` = Betreff der Mail (App zeigt ihn als Body; Absender
     optional in `subjectRichParameters`)
   - Erzeugung nur für neue Mails (keine Duplikate bei Wiederholung);
   Debounce ~30 s.
2. Keine weiteren Routing-Änderungen nötig: `souvera_mail` ist eine
   Non-Talk-App und wird an alle registrierten Geräte gepusht.

**App (vorbereitet):**
- Tap auf die Notification öffnet direkt die jeweilige Mail
  (`SouveraPushDeepLink.mail` + JMAP `Email/get`); ohne Mail-Id nur der
  Mail-Tab.
- Nach Empfang im Hintergrund kann die App den Mail-Sync anstoßen
  (bereits vorhandener `SouveraBackgroundSync.syncMail()`).

## 2. Kalender-Push (App-Id `souvera_calendar`)

**Ziel:** Termin-Änderungen (auf jedem Gerät) erreichen die App sofort;
die App resynct den Kalender und plant Erinnerungen - ohne auf den
opportunistischen iOS-Background-Task angewiesen zu sein.

**Server (souvera/CalDAV-Hook):**
1. Bei CalDAV-Schreiboperationen auf eigenen Kalendern (sabre-Hooks
   `afterWriteContent`/`afterCreateFile`/`afterUnbind`) eine
   Nextcloud-Notification erzeugen:
   - `app` = `souvera_calendar`
   - `objectId`/`id` = Event-UID
   - `subject` = "Kalender aktualisiert" (stiller Weckruf) bzw. bei
     Neuanlage "Neuer Termin: <Titel>"
2. Empfohlen still (kein Banner) oder dezentes Banner bei Neuanlage.

**App (vorbereitet):**
- Empfang im Hintergrund -> `SouveraBackgroundSync.syncCalendar()` +
  `SouveraReminderScheduler.schedule` (Erinnerungen sofort geplant).
- Tap -> Termin-Detail (`SouveraPushDeepLink.event` -> `findEvent(uid:)`).

## Hinweise

- Beide Erweiterungen sind isolierte Server-Patches (Notification über die
  vorhandene Notifications-API); kein Client-Protokollwechsel nötig.
- Geräte-Abmeldung bei Logout ist app-seitig umgesetzt (Proxy + Server),
  damit keine toten Gerätezeilen entstehen.
