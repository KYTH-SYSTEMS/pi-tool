# Pi-Tool — Launch-Kit (kostenloser Start)

> **STATUS: LAUNCH ERLEDIGT — die App ist seit 26.07.2026 in Google Play live**
> ([`systems.kyth.pitool`](https://play.google.com/store/apps/details?id=systems.kyth.pitool),
> v0.61.0 / versionCode 112; IARC-Ratings live, Global Rating ID
> `a9a55def-8a3d-8414-84d0-3f6b21e9cff5`). Dieses Dokument ist ab jetzt
> **Historie/Referenz**, keine offene To-do-Liste mehr. **F-Droid/IzzyOnDroid
> entfällt** (IzzyOnDroid hat unter seiner AI-Policy abgelehnt) → Kanäle sind
> Play + direkte APK am GitHub-Release. Offen bleibt nur der spätere
> **Pro-Flip** (DormantEntitlement → echtes Play Billing).

Ziel: **kostenlos** in Google Play + auf F-Droid, Reichweite sammeln, den 5-€-Pro-Kauf
später per Update nachschieben (Gating liegt schon fertig+schlafend im Code).

Legende: **[DU]** = nur du kannst es (Konto, Zahlung, Gerät) · **[ICH]** = mache/habe ich erledigt.

---

## 0. Zuerst starten (hat Vorlauf!)
- **[DU] Google-Play-Developer-Konto** als Organisation (KYTH. Systems UG). Einmalig 25 $.
  Org-Konten brauchen eine **D-U-N-S-Nummer** + Identitätsprüfung → **Tage bis Wochen**.
  Jetzt anstoßen, läuft parallel zu allem anderen. (D-U-N-S kostenlos bei Dun & Bradstreet.)
- **[x] Öffentliche Kontakt-E-Mail: `support@kyth.systems`** (festgelegt 2026-07) — kommt ins
  Play-„Contact details"-Feld. Deckt sich mit dem In-App-„Support kontaktieren" (`kSupportEmail`).

---

## 1. Store-Eintrag (Texte + Grafiken)
Schon fertig im Repo unter `fastlane/metadata/android/{de-DE,en-US}/`:
- **[ICH] Titel** `title.txt` — „Pi-Tool (inoffiziell)" / „Pi-Tool (unofficial)" (max 30 Zeichen ✓)
- **[ICH] Kurzbeschreibung** `short_description.txt` (max 80 Zeichen ✓)
- **[ICH] Vollbeschreibung** `full_description.txt` (max 4000 Zeichen ✓)
- **[ICH] Changelog** `changelogs/57.txt` (= versionCode von 0.23.0)
- **[ICH] App-Icon** 512×512 (`images/icon.png`) + **Feature-Grafik** 1024×500 (`images/featureGraphic.png`)

Fehlt noch:
- **[DU] Screenshots** (mind. 2, empfohlen 4–6). Brauchen die laufende App → Emulator/Gerät.
  Specs: PNG/JPG, 9:16 (Hochformat), kürzeste Seite ≥ 320 px, längste ≤ 3840 px.
  Ablage für F-Droid/fastlane: `fastlane/metadata/android/de-DE/images/phoneScreenshots/1.png` (2.png, …).
  Motiv-Vorschläge: Karten-Übersicht (evcc/Pi-hole/System), „Dienst hinzufügen"-Picker,
  Konsole, Backups-Sheet, Health-Anzeige.

Weitere Eintrags-Felder in der Play Console:
- **Kategorie:** Tools. **Tags:** passend (kein Spam).
- **Datenschutz-URL:** https://profex1337.github.io/evcc-pi-tool/privacy.html (steht ✓)

---

## 2. Data Safety (Datensicherheit) — exakte Antworten
Kernaussage: **Wir sammeln/teilen NICHTS.** Zugangsdaten gibt der Nutzer ein, sie bleiben
**nur auf dem Gerät** (verschlüsselt im Android Keystore) und gehen ausschließlich an den
**eigenen Pi** des Nutzers. Kein Backend, keine Analytics, keine Ads-SDKs, kein Crash-Reporting.

- „Sammelt oder teilt deine App Nutzerdaten?" → **Nein.**
  (Play-Definition „Sammeln" = Übertragung an Entwickler/Dritte. Auf-dem-Gerät-Speicherung zählt nicht,
  und die SSH-Verbindung geht nur an das eigene Gerät des Nutzers.)
- „Daten bei Übertragung verschlüsselt?" → **Ja** (SSH).
- „Können Nutzer Löschung anfordern?" → Daten liegen nur lokal; Deinstallation entfernt alles.
- Ads / Werbe-IDs → **Nein.**

> Hinweis: Diese Angaben sind eine verbindliche Erklärung. Sie sind für unsere App korrekt
> („No data collected / No data shared"); einmal in Ruhe gegenlesen und abnicken.

---

## 3. Content Rating (Alterseinstufung, IARC-Fragebogen)
Alles **Nein** (keine Gewalt, kein Sex, keine Drogen, kein Glücksspiel, kein Nutzer-Chat,
kein Standort-Teilen). Ergebnis: **USK 0 / PEGI 3 / „Ab 0"**.

---

## 4. Zielgruppe, Ads, Preis
- **Zielgruppe/Alter:** **nicht** für Kinder — Bracket **18+** wählen (Admin-/Utility-Tool),
  hält uns aus der „Families"-Policy raus.
- **Enthält Ads:** Nein.
- **Preis:** **Kostenlos.** (Pro kommt später als In-App-Kauf — jetzt noch NICHTS anlegen.)

---

## 5. Closed Testing — für unser ORG-Konto NICHT nötig
Der Pflicht-Test (≥ 12 opted-in Tester über 14 Tage) gilt **nur für PERSONAL-Konten**, die
**nach dem 13.11.2023** angelegt wurden. **Organisations-Konten (= unsere KYTH. Systems UG)
sind davon befreit** und dürfen direkt in die Produktion — genau das ist der Hauptgrund fürs
Org-Konto (spart 14 Tage + das Organisieren von 12 Testern).
- Voraussetzung: die **D-U-N-S-verifizierte Organisation** (siehe §0). Danach: AAB in den
  Produktions-Track, Review abwarten, live.
- (Google-Policy-Stand 2026 — der Testzwang wurde am 11.12.2024 von 20 auf 12 Tester gesenkt,
  Org-Konten bleiben ausgenommen. Beim Einrichten in der Console kurz gegenprüfen.)

---

## 6. ASO / Auffindbarkeit (+ Markenrecht!)
- Play hat **kein** separates Keyword-Feld — Suchbegriffe kommen aus Titel + Beschreibung.
  Natürlich einbauen (steht in der Beschreibung schon): *Raspberry Pi, SSH, self-hosted,
  Server, Update, Admin, evcc, Pi-hole, Home Assistant*.
- **Markenrecht:** „evcc"/„Pi-hole"/„Home Assistant" **NICHT in den Titel** (Play flaggt das als
  Impersonation, und es verärgert die Projekte). In der Beschreibung ok — mit dem „inoffiziell,
  nicht verbunden"-Hinweis (steht schon drin).

---

## 7. F-Droid — Reichweiten-Kanal (Strategie nach IzzyOnDroid-Absage)
Unsere App ist FOSS (MIT), **ohne** proprietäre/Google-Bibliotheken (kein Firebase/GMS,
kein Tracking) → technisch F-Droid-tauglich.

> **IzzyOnDroid: ABGELEHNT (2026-07-12).** Grund: „the level of LLM assistance used in
> this application exceeds our acceptable thresholds" — Verstoß gegen die *App Inclusion
> AI Policy* von IzzyOnDroid. Wir hatten die (überwiegende) KI-Entwicklung **ehrlich
> deklariert**; das war richtig. IzzyOnDroid ist damit als Kanal **zu**. **Nicht** durch
> Herunterspielen der KI-Nutzung erneut einreichen (unehrlich + Reputationsrisiko).

**Wichtig: Das betrifft NUR IzzyOnDroid.** Google Play hat **keine** KI-Assistenz-Policy →
der Play-Launch ist voll intakt.

**Verbleibende F-Droid-Optionen (ohne IzzyOnDroids KI-Gate):**
- **Eigenes F-Droid-Repo (empfohlen, volle Kontrolle):** Wir hosten ein F-Droid-kompatibles
  Repo (`fdroidserver`), das die signierte APK aus den GitHub-Releases zieht. Nutzer fügen
  unsere Repo-URL im F-Droid-Client hinzu. Kein Gatekeeper. → mittlerer Setup-Aufwand.
- **Offizielles F-Droid-Repo:** baut aus dem Quellcode (RFP bei `gitlab.com/fdroid/rfp`).
  Ob F-Droid-Main dieselbe KI-Haltung hat wie IzzyOnDroid, ist **unklar** — vor Aufwand
  erst prüfen. Reproducible-Build-Rezept nötig (fummeliger).
- **Direkt-APK (schon live):** die signierte `app-release.apk` an jedem GitHub-Release —
  sideloadbar, sofort.

---

## 8. Checkliste
**[DU] — Vorlauf, jetzt starten**
- [ ] D-U-N-S-Nummer beantragen (kritischer Pfad, bis ~30 Tage)
- [ ] Google-Play-Konto (KYTH-Org) + Identitätsprüfung (mit HRB 46313)
- [x] öffentliche Kontakt-E-Mail festgelegt: support@kyth.systems
- [x] Screenshots **aufgefrischt (2026-07-14)** — 5 Stück, gerendert über Test-Fakes (kein
      echter Pi), in `fastlane/…/{de-DE,en-US}/images/phoneScreenshots/1–5.png` (1080×2160, ≤2:1):
      1 Cockpit (eingeklappte Zugangsdaten-Karte v0.56 + System-Health + evcc), 2 Dienst-Karten
      (Home Assistant + Tailscale + AdGuard), 3 „Dienst hinzufügen", 4 Automatik (3 Kacheln inkl.
      Geplante Backups), 5 „Alle Pis"-Ampel (orange/grün). Generator: `test/screenshots.dart`.
- [x] Voll-Beschreibungen (de/en) **auf v0.56-Funktionsstand gebracht (2026-07-14)**: u. a.
      Pi herunterfahren, AdGuard/Node-RED/Zigbee2MQTT, Docker-Container, Speicherplatz analysieren,
      Sicherheits-Check, geplante Backups, Tailscale-Fernzugriff, SSH-Key-Auto-Einrichtung.
      DE 3967 / EN 3838 Zeichen (< 4000).

**[DU] — in der Play Console**
- [ ] **App-Inhalte → App-Zugriff = „Alle Funktionen sind ohne besondere Zugangsdaten
      verfügbar"** — und KEIN Anweisungs-Eintrag darunter. Steht dort „eingeschränkt" mit einem
      Eintrag ohne Benutzername/Passwort, blockt die Console das Einreichen mit **„Fehlende
      Anmeldedaten"** (Pre-Submit-Check auf die Erklärung, kein Review-Befund). Die Angabe ist
      inhaltlich korrekt: die App hat kein Konto und kein Login, seit v0.61.0 ist über
      „Demo ausprobieren" auf dem Verbindungs-Screen die **ganze** App inkl. aller Pro-Funktionen
      ohne Zugangsdaten erreichbar; die SSH-Felder sind die Zugangsdaten zum **eigenen Gerät des
      Nutzers**, kein Login in einen Dienst von uns. Genau diese Einstellung hat v0.61.0 durchs
      Review getragen (die Ablehnung vom 19.07.2026 kam, als es diesen Demo-Weg noch nicht gab).
      Der Demo-Link versteckt sich nur, wenn schon ein Host eingetragen ist (`main.dart`
      ValueListenableBuilder auf `_host`) — bei der Frisch-Installation eines Prüfers ist er also
      immer sichtbar.
- [ ] **Erwartbar beim Einreichen: „Fehlende Anmeldedaten" trotz korrekter „Nein"-Angabe.** Das
      ist Googles automatischer Vorab-Scan, der das SSH-Passwortfeld für eine Kontoanmeldung
      hält (derselbe Fehlalarm wie bei v0.60.0). Dann **nicht** die Erklärung ändern und **keine**
      erfundenen Zugangsdaten eintragen, sondern den angebotenen Weg „Liegt hier deiner Ansicht
      nach ein Fehler vor? → ohne Korrektur einreichen" nehmen. So ist v0.63.0 am 26.07.2026
      eingereicht worden; dieselbe Konstellation (Erklärung „Nein" + Demo-Einstieg) hat v0.61.0
      durchs Review gebracht. Falls ein Mensch danach doch Zugangsdaten verlangt: erst im
      Einspruch auf „Demo ausprobieren" verweisen, erst als letztes Mittel der Plan B vom
      19.07.2026 (wegwerfbarer öffentlich erreichbarer SSH-Server als Prüf-Zugang) — bisher nie
      nötig gewesen.
- [ ] Store-Eintrag füllen (Texte aus `fastlane/…` übernehmen oder via `fastlane supply`)
- [ ] Data Safety = „no data collected/shared" (siehe §2)
- [ ] Content Rating (alles Nein → USK 0)
- [ ] Zielgruppe 18+, keine Ads, kostenlos
- [ ] signiertes **AAB** (CI-Artefakt vom `v*`-Release) in den Produktions-Track hochladen
- [ ] Kein Closed Test nötig (Org-Konto) → direkt zur Produktion einreichen

**F-Droid — ENTSCHIEDEN: nicht weiterverfolgen (2026-07-12)**
- [x] ~~IzzyOnDroid RFP~~ **ABGELEHNT (KI-Policy)** — siehe §7; Kanal zu
- [x] Eigenes F-Droid-Repo: **NEIN** (Entscheidung Stefan) — Fokus liegt auf Google Play.
      Direkt-APK an den GitHub-Releases bleibt als Sideload-Kanal bestehen.

**[ICH] — erledigt / auf Zuruf**
- [x] fastlane-Metadaten (Titel, Kurz-/Langbeschreibung, Changelog, Icon, Feature-Grafik)
- [x] `&amp;`-Fix in der englischen Kurzbeschreibung
- [x] Datenschutz + Impressum gehostet (GitHub Pages)
- [x] Freemium-Gating fertig + schlafend (Pro-Umschaltung ohne Nacharbeit)
- [ ] auf Zuruf: Community-Launch-Posts (evcc-Forum/Reddit), `fastlane supply`-Setup,
      Pro-Kauf scharf schalten (In-App-Kauf), iOS
