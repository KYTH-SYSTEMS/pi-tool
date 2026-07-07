# Pi-Tool (inoffiziell) — evcc · Pi-hole · System

Schlanke **Android-App** (clean minimal, Hell/Dunkel/System), die deine
**self-hosted Dienste auf dem Raspberry Pi per Knopfdruck via SSH
aktualisiert und installiert** — und ihre Web-Oberfläche öffnet. „Verbindung
testen" erkennt automatisch, was läuft, und zeigt pro Dienst eine Karte:
[evcc](https://evcc.io), **Pi-hole** und das **ganze System** (alle Pakete via
`apt full-upgrade`). IP + Pi-Zugang eintragen, tippen, fertig. Verteilung als
**APK über GitHub Releases**.

> ⚠️ Hinweis: Die App führt mit deinem eingegebenen Passwort `sudo`-Befehle
> (`apt`, `pihole`, `systemctl`, ggf. `docker compose`) auf dem Pi aus. Nutze
> sie nur für Geräte, die dir gehören.
>
> ℹ️ **Inoffizielles** Community-Tool, nicht mit evcc oder Pi-hole verbunden.
> Für die tägliche Lade-Steuerung gibt es die
> [offizielle evcc-App](https://play.google.com/store/apps/details?id=io.evcc.android).

## Funktionen

- **Dienste auto-erkennen** — „Verbindung herstellen" findet evcc, Pi-hole,
  Home Assistant und das System in *einer* SSH-Sitzung und zeigt pro Dienst eine
  Karte (Status, Version, Aktualisieren/Installieren, „Oberfläche öffnen").
- **evcc aktualisieren** — erkennt automatisch, ob evcc als **apt-Paket**
  oder im **Docker-Container** läuft, und nimmt den passenden Weg.
- **Pi-hole** — aktualisieren (`pihole -up`), Blocklisten erneuern (`pihole -g`),
  DNS neustarten, installieren (experimentell), `/admin` öffnen.
- **Home Assistant** — als **Docker-Container** installieren (installiert bei
  Bedarf zuerst Docker, experimentell) und aktualisieren (Image-Pull + Neuanlage,
  Daten im `/config`-Volume bleiben erhalten), Web-UI auf Port 8123 öffnen.
- **Grafana, InfluxDB & Mosquitto** — werden automatisch erkannt, wenn per apt
  installiert: eigene Karte mit Update (apt `--only-upgrade`) und Web-UI
  (Grafana :3000, InfluxDB v2 :8086; Mosquitto ist ein MQTT-Broker ohne Web-UI).
- **Dienst hinzufügen** — der Hauptbildschirm zeigt nur **installierte** Dienste
  als Karte; ein „+ Dienst hinzufügen"-Knopf öffnet eine Auswahl **aller noch
  nicht installierten** Dienste (evcc, Pi-hole, Home Assistant, Grafana,
  InfluxDB, Mosquitto) und installiert den gewählten (experimentell). So bleibt
  die Übersicht schlank, egal wie viele Dienste unterstützt werden.
- **Konsole** — eigene Befehle direkt per SSH auf dem Pi absetzen (`sudo` wird
  unterstützt, das Pi-Passwort wird sicher via stdin gepiped), Ausgabe live.
  Auf eigene Gefahr — freie Befehle laufen mit deinen Rechten auf dem Pi.
- **System** — alle Pakete aktualisieren (`apt full-upgrade`), Pi neustarten.
- **Pi-Gesundheit** — die System-Karte zeigt Temperatur, freien Speicher, RAM
  und Uptime; bei knappem Speicher (<1 GB oder ≥90 % belegt) warnt sie, bevor
  ein Update daran scheitert.
- **Probelauf** (`--dry-run`) — zeigt gefahrlos, ob ein Update verfügbar ist.
- **Backup vor Update** — sichert vor einem apt-Update automatisch `evcc.yaml` +
  die Datenbank als zeitgestempeltes Archiv auf dem Pi (abschaltbar); schlägt es
  fehl, wird der Fehler angezeigt und das Update gestoppt.
- **Backup wiederherstellen** — listet die vorhandenen evcc-Backups auf dem Pi,
  eines auswählen → evcc stoppen, entpacken, neu starten (mit Sicherheitsabfrage).
- **Pi-hole- & Home-Assistant-Backup** — Pi-hole per Teleporter-Export (offizielles,
  importierbares Format), Home Assistant als Tar des `/config`-Verzeichnisses;
  landet unter `/var/backups/pi-tool/` auf dem Pi. **Wiederherstellen und
  Verwalten direkt in der App** (Pi-hole-Import via `pihole-FTL --teleporter`,
  nur v6; HA: Container stoppen → entpacken → starten). Automatische Rotation:
  die letzten 5 Backups je Dienst bleiben.
- **Aufräumen** — die System-Karte gibt Speicher frei (apt autoremove/clean,
  ungenutzte Docker-Images, Journal >7 Tage) und zeigt, wie viel frei wurde.
- **„Aktuell"-Anzeige** — bei evcc/Pi-hole/System zeigt die Karte „Aktuell", wenn
  keine neue Version ansteht (statt „Aktualisieren"); erzwingen geht über das ⋮-Menü.
- **Abbrechen** — eine laufende Aktion lässt sich abbrechen (schließt die
  SSH-Verbindung).
- **Verbindung herstellen** — Host/Zugang in Sekunden prüfen, ohne etwas zu ändern.
- **evcc installieren** auf einem frischen Pi (offizielles apt-Repo).
- **evcc-Status (Live)** — liest die aktuellen Werte direkt aus der evcc-Web-API
  (PV, Netz, Hausverbrauch, Batterie, Ladepunkte), rein lesend.
- **Pi im Netzwerk suchen** — findet im selben WLAN Geräte mit offenem
  SSH-Port und übernimmt die IP per Tippen. Wird beim ersten Start und nach
  „Profil hinzufügen" (solange noch kein Host eingetragen ist) prominent als
  Knopf angeboten; sonst jederzeit über das ⋮-Menü.
- **Updates im Hintergrund** — lange Aktionen (Update/Installation) laufen über
  einen Vordergrunddienst weiter, auch wenn du die App in den Hintergrund legst
  oder den Bildschirm ausschaltest (Benachrichtigung „Pi-Tool …").
- **Mehrere Pi-Profile** — pro Pi ein benanntes Profil, schnell umschaltbar.
- **SSH-Key- oder Passwort-Login**, **App-Sperre** (Biometrie/PIN),
  **stable/nightly**-Kanal, **Update-Verlauf**, **In-App-Update-Hinweis**.
- **Dienst-/System-Aktionen:** evcc-Dienst neustarten, Pi neustarten, `systemctl
  status` ansehen, Live-Log teilen.

## Was die App macht

Beim Tippen auf **„evcc aktualisieren"** erkennt die App zuerst die
Installationsart und nimmt dann den passenden Weg:

**apt-Installation** (Standard auf dem Pi) — die validierte SSH-Sequenz:

1. Version vorher: `dpkg-query -W -f='${Version}' evcc`
2. `sudo -S apt-get update -qq`
3. `sudo -S apt-get install --only-upgrade -y evcc`
   (bei aktiviertem Schalter **„Komplettes System-Upgrade"** stattdessen
   `sudo -S apt-get full-upgrade -y`)
4. `systemctl is-active evcc` → erwartet `active`
5. Version nachher → Diff wird gemeldet („evcc 0.310.0 → 0.311.0 aktualisiert"
   bzw. „war schon aktuell").

Der Dienst startet beim apt-Upgrade automatisch neu. Mit **„Probelauf (ändert
nichts)"** läuft dieselbe Sequenz mit `--dry-run` — nichts wird verändert.

**Docker-Installation** — läuft evcc in einem Container, aktualisiert die App
ihn passend zum Setup:
- **docker compose**: `docker compose pull` → `up -d` im Projektverzeichnis,
  mit gepinntem Projekt (`-p`) und Compose-Datei(en) (`-f`), damit kein
  Doppel-Container entsteht; fällt automatisch auf das v1-Binary
  `docker-compose` zurück, wenn das v2-Plugin fehlt.
- **`docker run`** (ohne compose): zieht das neue Image und legt den Container
  **aus `docker inspect` rekonstruiert** neu an (Ports, Volumes, Env,
  Restart-Policy, Netzwerk sowie `--device`/`--privileged`/`--group-add` für
  USB-/RS485-Zähler). Der alte Container wird dabei nur **umbenannt**
  (`<name>-evccpitool-old`), nie gelöscht — schlägt die Neuanlage fehl, wird er
  automatisch zurückgerollt. **Experimentell**, nicht gegen jede Konfiguration
  getestet.

Docker-Befehle laufen bei Bedarf automatisch über `sudo`.

Mit **„Verbindung herstellen"** prüfst du in Sekunden, ob Host/Port/Benutzer/Zugang
stimmen: die App verbindet, erkennt die Installationsart (apt/Docker) und
meldet Version bzw. Container — **ohne irgendetwas zu verändern**.

### evcc-Status (Live)

Über das ⋮-Menü → **„evcc-Status (Live)"** liest die App die aktuellen Werte
**direkt aus der evcc-Web-API** (`GET http://<pi>:7070/api/state`) und zeigt
PV-Erzeugung, Netz, Hausverbrauch, Batterie-Ladestand und die Ladepunkte. Rein
lesend über HTTP — **kein SSH, keine Zugangsdaten**. Die App ist robust gegen
verschiedene evcc-Versionen (mit/ohne `result`-Hülle, fehlende Felder).

### Pi im Netzwerk finden

⋮-Menü → **„Pi im Netzwerk suchen"** scannt das lokale `/24`-Netz nach Geräten
mit offenem **SSH-Port (22)** und listet sie auf — Tippen übernimmt die IP ins
Host-Feld. Funktioniert nur im **selben WLAN**; findet die App nichts, einfach
die IP von Hand eintragen.

### evcc installieren

Über den Button **„evcc installieren"** (Abschnitt „Erstinstallation auf neuem
Pi") richtet die App evcc auf einem frisch konfigurierten Pi ein (nach
[offizieller evcc-Doku](https://docs.evcc.io/en/installation/linux)): offizielles
apt-Repo via `setup.deb.sh` hinzufügen → `apt install -y evcc` →
`systemctl enable --now evcc`. Alles läuft als root über **einen** `sudo -S bash
-s`-Aufruf (Passwort als erste stdin-Zeile, **nie** in der Befehlszeile). Danach
zeigt die App **„Einrichtung öffnen"** → `http://<pi>:7070`. Über die
Einstellungen lässt sich vorab der **nightly-Kanal** (unstable) wählen.

## Installation (Sideload)

1. Auf der [Releases-Seite](../../releases) die neueste **`app-release.apk`**
   herunterladen (Handy-Browser genügt, kein GitHub-Account nötig).
2. Beim Öffnen fragt Android nach **„Unbekannte Quellen / Apps aus dieser
   Quelle zulassen"** → erlauben.
3. APK installieren, App öffnen.

## Nutzung

| Feld | Bedeutung | Default |
|------|-----------|---------|
| **Host / IP** | IP des Pi (z. B. `192.168.178.64`) oder Tailscale-IP | – |
| **Benutzer** | SSH-Benutzer | `pi` |
| **Port** | SSH-Port | `22` |
| **Login** | **Passwort** oder **SSH-Key** (PEM, optional mit Passphrase) | Passwort |
| **Passwort** | Pi-Passwort für SSH + `sudo` (bei Key-Login: nur für `sudo`) | – |
| **Komplettes System-Upgrade** | Aus = nur evcc; Ein = alle apt-Pakete | Aus |

Mehrere Pis verwaltest du über die **Profilleiste** oben (umschalten, anlegen,
umbenennen, löschen). In den **Einstellungen** (⋮-Menü): App-Sperre per
Biometrie/PIN, Status beim Start prüfen, HTTPS + Port der evcc-Oberfläche,
Design (System/Hell/Dunkel), nightly-Kanal.

Alle Eingaben werden **verschlüsselt im Android Keystore** gespeichert
(`flutter_secure_storage`) und automatisch gesichert — einmal eintragen, danach
nur noch tippen.

## Sicherheit

- Passwort und SSH-Key liegen **nur verschlüsselt** im Keystore, nie im Klartext.
- Das `sudo`-Passwort wird der Abfrage **über stdin** übergeben (`sudo -S`),
  **nie** als Teil der Befehlszeile — und aus dem sichtbaren Log
  **herausgefiltert**.
- Der **Live-Status** nutzt nur lesendes HTTP gegen die evcc-Oberfläche — dabei
  werden **keine** Zugangsdaten gesendet.
- Kein Account, kein Cloud-Backend. Annahme: LAN-Nutzung (zuhause im WLAN).
  Remote optional über **Tailscale-IP** (kein Portforwarding nötig).
- Optionale **App-Sperre** per Biometrie/PIN; der Bildschirm ist gegen
  Screenshots/Recents geschützt (`FLAG_SECURE`).
- **Host-Key-Verifizierung (TOFU):** Beim ersten Connect zeigt die App den
  SSH-Fingerprint zur **Bestätigung** an und merkt ihn erst nach Zustimmung;
  danach wird er geprüft. Ändert er sich (möglicher MITM oder neu aufgesetzter
  Pi), **blockiert** die App und sendet kein Passwort — erst nach bewusstem
  „neuen Key vertrauen".

## Build & Releases (CI)

Der APK-Build läuft komplett in **GitHub Actions** — lokal ist **keine
Android-Toolchain** nötig.

- Workflow: [`.github/workflows/build.yml`](.github/workflows/build.yml)
- Trigger: Push auf `main` (baut + testet) und Tag `v*` (baut + signiert +
  legt ein **Release mit `app-release.apk`** an).
- Schritte: `flutter pub get` → `flutter analyze` → `flutter test` →
  `flutter build apk --release` (arm64), signiert mit einem Release-Keystore aus
  den Repo-Secrets. Zusätzlich entsteht ein **`.aab`** für den Play Store.

### Ein neues Release veröffentlichen

```bash
# Version in pubspec.yaml anheben (z. B. 0.8.0+16), committen, dann:
git tag v0.8.0
git push origin v0.8.0
```

CI baut die signierte APK und hängt sie ans GitHub-Release.

### Benötigte Repo-Secrets (Signierung)

| Secret | Inhalt |
|--------|--------|
| `KEYSTORE_BASE64` | Release-Keystore (`.jks`), base64-kodiert |
| `KEYSTORE_PASSWORD` | Keystore-Passwort |
| `KEY_ALIAS` | Key-Alias (`evcc`) |
| `KEY_PASSWORD` | Key-Passwort |

> Der Keystore wird **nie** ins Repo committet (`.gitignore`). Bewahre die
> `.jks`-Datei + Passwort sicher auf — sie wird für künftige signierte Updates
> gebraucht.

## Verteilung: Sideload **und** Play-Store-fähig

Beide Wege funktionieren parallel, ohne sich zu stören:

- **Sideload (Standard):** Die signierte **`app-release.apk`** am `v*`-Release —
  Freunde laden + installieren direkt, ohne Konto.
- **Play Store (optional):** Derselbe CI-Lauf erzeugt zusätzlich ein **`.aab`**
  (App Bundle) als Artifact **`evcc-pi-tool-playstore-aab`**. Damit ist alles für
  eine Play-Einreichung vorbereitet:
  - Datenschutzerklärung: <https://profex1337.github.io/evcc-pi-tool/privacy.html>
  - Store-Assets + Texte + Data-Safety + Checkliste: [`store/play/listing.md`](store/play/listing.md)
  - Selbst beizusteuern: Google-Play-Account (25 $), Screenshots, der 14-Tage-
    Closed-Test für neue Privat-Accounts.
  > Hinweis: Play nutzt **Play App Signing** (re-signiert das Bundle) — die
  > Play-Version hat daher eine andere Signatur als die Sideload-APK; beide Kanäle
  > laufen unabhängig nebeneinander.

## Haftungsausschluss

Inoffizielles Community-Tool, **nicht** mit dem evcc-Projekt verbunden. Die App
führt mit deinen Zugangsdaten `sudo`-Befehle (`apt`, `systemctl`, `reboot`,
`docker`) auf deinem Gerät aus. **Nutzung auf eigene Gefahr — keine Haftung für
Schäden an System, Daten oder Hardware.** Lizenz: [MIT](LICENSE) („AS IS", ohne
Gewährleistung).

## Entwicklung

```bash
flutter pub get
flutter analyze
flutter test
```

> 📐 **Vollständige Architektur-Referenz:** [`ARCHITECTURE.md`](ARCHITECTURE.md)
> (Schichten, Seams, Sicherheits-Invarianten, „neuen Dienst hinzufügen").
> Arbeitsregeln + Pflege-Pflicht: [`CLAUDE.md`](CLAUDE.md).

Die Architektur trennt **testbare reine Logik** von I/O:

- `lib/src/commands.dart` — Kommando-Bau + Docker-/Install-Erkennung
- `lib/src/parsing.dart` — Output-Parsing + Ergebnis-Zusammenfassung
- `lib/src/evcc_updater.dart` — SSH-/Update-Orchestrierung hinter dem
  `SshRunner`-Interface (Unit-Tests ohne echtes SSH); `dartssh2_runner.dart` ist
  der dünne reale Adapter
- `lib/src/evcc_api.dart` — read-only evcc-Web-API-Client + defensiver Parser
- `lib/src/network_scan.dart` — Subnetz-Scan für „Pi finden"
- `lib/src/profiles.dart` / `settings_store.dart` — verschlüsselte Config
- `lib/main.dart` — UI

Tests: `flutter test` (reine Logik via TDD, Updater via `FakeSshRunner`,
Widget-Tests mit injizierten Fakes).

## Roadmap

- iOS: bewusst später. Die Flutter-Codebasis hält die Tür offen.
- Docker-`run`-Rekonstruktion deckt die gängigen Fälle ab; exotische Flags
  (`--mount type=volume`, custom `--entrypoint`) werden noch nicht übernommen.
