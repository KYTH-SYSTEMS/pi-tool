# Play Store — Listing & Einreichung (Pi-Tool)

Alles hier ist vorbereitet. Was nur **du** machen kannst, ist unten unter „Checkliste" markiert.

## Assets (in diesem Ordner)
- App-Icon 512×512: `icon-512.png`
- Feature-Graphic 1024×500: `feature-graphic-1024x500.png`
- Screenshots: **fehlen** — bitte 2–8 Handy-Screenshots der laufenden App machen (Play will min. 2).

## Texte

**App-Name (max. 30):**
```
Pi-Tool
```

**Kurz- & Vollbeschreibung:** maßgeblich sind die fastlane-Metadaten — **von dort kopieren**, damit es nur eine Quelle gibt (kein doppelter, driftender Text):
- Deutsch: [`fastlane/metadata/android/de-DE/short_description.txt`](../../fastlane/metadata/android/de-DE/short_description.txt) + [`full_description.txt`](../../fastlane/metadata/android/de-DE/full_description.txt)
- Englisch: [`fastlane/metadata/android/en-US/`](../../fastlane/metadata/android/en-US/)

Diese beschreiben den Multi-Service-Stand (evcc + Pi-hole + ganzer Pi) inkl. Affiliation-Hinweis „nicht mit evcc oder Pi-hole verbunden".

**Was ist neu (Release Notes):** siehe jeweiliges GitHub-Release.

## Kategorie / Kontakt
- Kategorie: **Tools** (Productivity ginge auch)
- Tags: Raspberry Pi, SSH, evcc, Pi-hole
- Website: https://profex1337.github.io/evcc-pi-tool/
- Datenschutz-URL: **https://profex1337.github.io/evcc-pi-tool/privacy.html**
- Kontakt-E-Mail: **hello@kyth.systems**
- Impressum-URL: **https://profex1337.github.io/evcc-pi-tool/impressum.html**

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
- **Play App Signing** aktivieren. Unser Release-Keystore wird zum **Upload-Key**
  (Secrets `KEYSTORE_*` sind schon gesetzt; der CI-Build erzeugt das `.aab`).

## Artefakt
- Das `app-release.aab` kommt aus dem GitHub-Actions-Lauf (Artifact **evcc-pi-tool-playstore-aab**)
  des jeweiligen `v*`-Tags. Herunterladen → in der Play Console als Bundle hochladen.

## Checkliste (nur du)
- [ ] Google-Play-Developer-Account (einmalig 25 $)
- [ ] Neuer Privat-Account: **Closed Test mit 12+ Testern über 14 Tage** vor Produktiv-Release
- [ ] 2–8 Screenshots erstellen
- [ ] Kontakt-E-Mail in der Console setzen
- [ ] `.aab` aus dem CI-Artifact hochladen, Data-Safety + Content-Rating ausfüllen, Datenschutz-URL eintragen
- [ ] **Foreground-Service-Erklärung (Data sync)** in der Console ausfüllen (siehe Abschnitt oben) – sonst Ablehnung
- [ ] (Empfohlen) im Listing klar „inoffiziell, nicht mit evcc oder Pi-hole verbunden" erwähnen (steht schon in der Beschreibung)
```
