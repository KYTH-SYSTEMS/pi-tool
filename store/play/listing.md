# Play Store — Listing & Einreichung (Pi-Tool)

Die App ist seit dem 26.07.2026 bei Google Play live. **Seit dem 30.07.2026 veröffentlicht die
CI jedes `v*`-Tag selbst** — AAB und Store-Texte gehen in die Produktions-Spur mit 100 % Rollout,
ohne Entwurf und ohne Zwischenkontrolle (Mechanik: `ARCHITECTURE.md` §8, Einrichtung der
Google-Seite: [`../play-ci-publishing.md`](../play-ci-publishing.md)). Diese Datei hält fest, was
weiterhin **von Hand in der Play Console** liegt: Grafiken, Data Safety, Erklärungen.

## Assets
- App-Icon 512×512: `icon-512.png` (in diesem Ordner)
- Feature-Graphic 1024×500: `feature-graphic-1024x500.png` (in diesem Ordner)
- Screenshots: `fastlane/metadata/android/{de-DE,en-US}/images/phoneScreenshots/` (Generator:
  `test/screenshots.dart`).

Grafiken und Screenshots lädt die CI **nicht** hoch (`skip_upload_images`,
`skip_upload_screenshots` im Fastfile) — sie werden von Hand in der Console gepflegt.

## Texte

Einzige Quelle sind die fastlane-Metadaten; die CI lädt sie mit jedem Tag hoch. **Nichts von Hand
in die Console kopieren** — eine dortige Änderung wird vom nächsten Release wieder überschrieben.

- **App-Name (max. 30):** `title.txt` — derzeit „Pi-Tool: SSH-Verwaltung" (de-DE) bzw.
  „Pi-Tool: SSH Manager" (en-US).
- **Kurz- & Vollbeschreibung (max. 80 / 4000):**
  [`fastlane/metadata/android/de-DE/short_description.txt`](../../fastlane/metadata/android/de-DE/short_description.txt) +
  [`full_description.txt`](../../fastlane/metadata/android/de-DE/full_description.txt), Englisch unter
  [`fastlane/metadata/android/en-US/`](../../fastlane/metadata/android/en-US/).
- **Was ist neu (max. 500):** `changelogs/<versionCode>.txt` in beiden Sprachen. Fehlt die Datei
  oder ist ein Text zu lang, bricht der Tag-Lauf vor dem Bauen ab.

Die Langbeschreibung trägt den Affiliation-Hinweis („Inoffizielles Community-Tool, nicht mit den
genannten Projekten verbunden").

## Kategorie / Kontakt
- Kategorie: **Tools** (Productivity ginge auch)
- Tags: Raspberry Pi, SSH, evcc, Pi-hole
- Website: https://pi-tool.kyth.systems/
- Datenschutz-URL: **https://pi-tool.kyth.systems/privacy.html**
- Kontakt-E-Mail: **hello@kyth.systems**
- Impressum-URL: **https://pi-tool.kyth.systems/impressum.html**

## Data Safety (Formular-Antworten)
- Werden Daten erfasst/geteilt? **Nein** – nichts wird an uns oder Dritte übertragen.
- Lokale Speicherung von Zugangsdaten (Host/Port/User/Passwort): verschlüsselt auf dem Gerät, verlässt das Gerät nicht.
- Datenverschlüsselung bei Übertragung: **Ja** (SSH zum eigenen Server).
- Löschung: durch Deinstallation.
- (Falls das Formular „App-Funktionalität / Credentials" abfragt: lokal, nicht geteilt.)

### Abgleich mit der DSE: ntfy / Health-Alerts (Stand 26.07.2026, v0.63.0)
Die Datenschutzerklärung nennt seit v0.63.0 die ntfy-Übermittlung. **Die Data-Safety-Antwort
bleibt trotzdem „No data collected / No data shared"** — begründet, nicht aus Bequemlichkeit:

- **Die App selbst überträgt nichts an ntfy.** Sie schreibt per SSH einen systemd-Timer auf den
  Pi; das `curl` läuft dort. Auch die Test-Nachricht ist ein SSH-Befehl auf dem Pi
  (`buildTestAlertCommand`), kein HTTP-Aufruf vom Handy. Data Safety fragt nach Daten, die **die
  App vom Gerät des Nutzers** erhebt/teilt.
- **Nutzer-initiiert an ein selbst gewähltes Ziel:** Server *und* Topic gibt der Nutzer ein
  (Play-Ausnahme für Übertragungen aufgrund einer konkreten Nutzeraktion an einen Empfänger,
  mit dem der Nutzer die Weitergabe erwartet). Ohne Einrichtung passiert nichts (Default: aus).
- **Inhalt sind Gerätezustandsdaten des Pi** (Speicher, Temperatur, Dienstnamen, *Anzahl*
  offener Updates) — keine Nutzerdaten aus einer Data-Safety-Kategorie, keine Kennungen.

**Wenn Google in der Console nachfragt** (oder die Antwort konservativer sein soll): Kategorie
wäre „App-Aktivität → Sonstige" bzw. „Diagnose", *shared*, **optional**, Zweck „App-Funktionalität".
Erst ändern, wenn die App selbst zu ntfy spricht — dann ist diese Zeile hinfällig.
→ Bei jeder Änderung an den Health-Alerts diesen Abschnitt gegen `docs/privacy.html` prüfen.

## Play-Console-Warnung „Randlose Anzeige funktioniert möglicherweise nicht für alle Nutzer"
**Status: bekannt, nichts zu tun, nicht blockierend („1 Aktion empfohlen").** Untersucht am
26.07.2026 (v0.63.0, targetSdk 35, Flutter 3.44.4).

- **Unsere Layouts sind korrekt.** Mit simulierten Android-15-Insets gerendert (48 dp Statusbar,
  24 dp Gestenleiste): App-Shell (`Scaffold` + `AppBar` + `NavigationBar`) und Verbindungs-Screen
  halten sauber Abstand, kein Inhalt landet unter einer Systemleiste. Vollbild-Routen sind
  abgedeckt — `_DisclaimerScreen` hat `SafeArea`, `_LockScreen`/Splash sind zentriert, die
  Bottom-Sheets nutzen durchgehend `SafeArea`.
- **Die beanstandeten APIs stecken in der Flutter-Engine, nicht in unserem Code.** Im
  `flutter_embedding`-Jar nachgewiesen: `PlatformPlugin.class` referenziert `setStatusBarColor`,
  `setNavigationBarColor`, `setNavigationBarDividerColor` und `setDecorFitsSystemWindows`,
  `FlutterActivity.class` referenziert `setStatusBarColor` — genau die vier von Google für
  Edge-to-Edge als veraltet markierten Aufrufe. Unser `MainActivity.kt` ruft keinen davon auf
  (nur `FLAG_SECURE`), und `styles.xml` setzt weder `statusBarColor`/`navigationBarColor` noch
  `windowOptOutEdgeToEdgeEnforcement`.
- **Konsequenz:** In der App ist nichts zu reparieren; die Warnung verschwindet erst mit einer
  Flutter-Version, deren Embedding diese Aufrufe nicht mehr enthält. Nicht bei jedem Release neu
  untersuchen — nur gegenprüfen, wenn Google die Warnung von „empfohlen" auf **blockierend**
  hochstuft oder der Text sich ändert (dann wäre der nächste Schritt ein Flutter-Upgrade, nicht
  eine Änderung an unserem Layout).

## Content Rating
- IARC-Fragebogen ausfüllen: keine Gewalt/Sexualität/Glücksspiel etc. → Ergebnis voraussichtlich **USK 0 / PEGI 3**.

## Foreground-Service-Erklärung (Pflicht seit 2024)
- Die App nutzt einen **Vordergrunddienst (Typ „Data sync")**, damit ein gestartetes
  Update/eine Installation im Hintergrund weiterläuft. Google Play verlangt dafür
  in der Console eine **„Berechtigungen für Vordergrunddienste"-Erklärung**:
  - Typ **Data sync** auswählen, Begründung: „Vom Nutzer gestartetes
    SSH-Update/-Installation auf dem eigenen Raspberry Pi muss kurzzeitig
    weiterlaufen, wenn die App in den Hintergrund wechselt." (ggf. Demo-Video).
  - Ohne diese Erklärung wird das Release **abgelehnt**.

## Signing
- **Play App Signing** ist aktiv. Unser Release-Keystore ist der **Upload-Key**
  (Secrets `KEYSTORE_*`; der CI-Build erzeugt und signiert das `.aab`).

## Artefakt
- Das `app-release.aab` baut der GitHub-Actions-Lauf des jeweiligen `v*`-Tags und lädt es im
  selben Lauf zu Play hoch (`fastlane android play_release`, Secret `PLAY_SERVICE_ACCOUNT_JSON`).
  Ein manueller Upload in der Console ist nicht mehr Teil des Ablaufs.
- Zusätzlich liegt das Bundle als Artifact **pi-tool-playstore-aab** am Lauf — für die Ablage,
  oder als Rückfall, falls der Play-Schritt übersprungen wurde (Secret fehlt) oder gescheitert ist.
  Ein von Hand hochgeladenes Bundle verbraucht denselben versionCode.

## Checkliste der Ersteinreichung (Historie)
Die Einreichung ist abgeschlossen (live seit 26.07.2026). Die Liste bleibt als Nachweis stehen,
was einmalig von Hand in der Console zu erledigen war — **nicht als To-do lesen**.

- [x] Google-Play-Developer-Account (einmalig 25 $)
- Closed Test (12+ Tester über 14 Tage): entfiel, weil Organisations-Konto (`../launch-kit.md` §5)
- [x] 2–8 Screenshots erstellen
- [x] Kontakt-E-Mail in der Console setzen
- [x] Erstes `.aab` hochladen, Data-Safety + Content-Rating ausfüllen, Datenschutz-URL eintragen
- [x] **Foreground-Service-Erklärung (Data sync)** in der Console ausfüllen (siehe Abschnitt oben)
- [x] Im Listing klar „inoffiziell" erwähnen (steht in der Beschreibung)
