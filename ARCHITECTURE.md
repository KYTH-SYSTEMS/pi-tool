# Pi-Tool — Architektur

> Referenz-Doku der App. **Bei architektur-relevanten Änderungen mitpflegen**
> (siehe `CLAUDE.md`). Stand: v0.32.x.

Pi-Tool ist eine Flutter-**Android**-App, die einen Raspberry Pi (oder jedes
Debian/Linux-Gerät) **per SSH** verwaltet: Dienste erkennen, installieren,
aktualisieren, sichern/wiederherstellen, überwachen, konfigurieren — und
Fernzugriff einrichten. Verteilung als signiertes APK über GitHub Releases
(später Play Store / F-Droid). Interner Dart-Paketname: `evcc_updater`,
App-ID: `systems.kyth.pitool`.

## Schichten (von unten nach oben)

```
┌─────────────────────────────────────────────────────────────┐
│ UI-Shell        main.dart + ui_widgets.dart (part) + splash  │  Cockpit, 4 Tabs
├─────────────────────────────────────────────────────────────┤
│ Orchestrierung  evcc_updater.dart (EvccUpdater)              │  1 Verbindung / Aktion
│                 ↕ SshRunner-Seam                             │
│ SSH-Transport   dartssh2_runner.dart + host_key.dart         │  dartssh2, TOFU
├─────────────────────────────────────────────────────────────┤
│ Reine Logik     commands.dart, parsing.dart, services/*,     │  I/O-frei, TDD
│                 auto_update.dart, alerts.dart, files.dart …  │
├─────────────────────────────────────────────────────────────┤
│ State/Infra     profiles.dart, settings_store.dart,          │  Persistenz, Netz,
│                 entitlement.dart, update_check.dart, evcc_api │  Freemium, Lock …
└─────────────────────────────────────────────────────────────┘
```

**Grundprinzip:** Jede Schicht ist über ein *Seam* (injizierbare Schnittstelle)
testbar. Die reine Logik enthält **kein I/O** — jeder Befehlsstring und jeder
Parser-Edge-Case ist unit-getestet, ohne echten Pi. Fehler in Netz/Plattform
sind durchgängig **fail-soft** (dürfen die App nie stürzen lassen).

---

## 1. SSH-Kern (`ssh_runner.dart`, `dartssh2_runner.dart`, `host_key.dart`)

- **`SshRunner`** (abstrakt): `connect/run/close` + `SshConfig`/`CommandResult`.
  Der Seam existiert, damit die Orchestrierung mit `FakeSshRunner` testbar ist —
  **dartssh2-Typen dürfen hier nicht durchsickern.**
- **`Dartssh2Runner`**: echte Implementierung. Wichtige Invarianten:
  - **`LineBuffer`**: `onOutput` bekommt nur *ganze Zeilen* → die zeilenweise
    `redactPassword`-Maskierung kann nicht durch einen über zwei Netz-Chunks
    gesplitteten Geheimwert ausgehebelt werden. Rohe Chunks nie direkt streamen.
  - **TOFU**: `checkAndRecordHostKey` bricht den Handshake ab (gibt `false`),
    bevor je ein Passwort gesendet wird — sowohl bei geändertem Key als auch bei
    abgelehntem First-Use. Ein abgelehnter First-Use speichert den Key **nicht**.
  - `SshConfig.timeout` begrenzt TCP **und** Auth-Handshake getrennt;
    `commandTimeout` ist ein **Inaktivitäts**-Timeout (lange apt/docker-Läufe,
    die weiter streamen, dürfen laufen). `keepAliveInterval: 20s` verhindert,
    dass NAT/Router die Session in ruhigen dpkg-Phasen killen.
  - `run()` drainiert die Streams via `asFuture()` (feuert nach *allen*
    Kanaldaten) — so geht kein letzter Chunk (z.B. eine kurze Versionsausgabe)
    verloren.
- **`host_key.dart`**: reine TOFU-Verdict-Logik (`verifyHostKey`,
  `hostKeyId('hostkey:$host:$port')`) + `HostKeyStore`-Seam. Nichts wird hier
  gehasht — dartssh2 liefert den fertigen `SHA256:…`-Fingerprint. Storage-Key
  enthält den Port (selber Host, anderer Port = eigene Identität).

## 2. Orchestrierung (`evcc_updater.dart` — `EvccUpdater`)

Führt **jede** Remote-Aktion aus, **eine SSH-Verbindung pro Aktion** über
`_withConnection` (connect → body → typisiertes Fehler-Mapping → immer `close`).

**Sicherheits-Invarianten (nicht verhandelbar):**
- **Sudo-Passwort nur über stdin an `sudo -S`** — nie im Befehlsstring (der wird
  via `log('\$ …')` geloggt). Root-Skripte:
  `installShellCommand = 'LC_ALL=C sudo -S bash -s'`, stdin =
  `'<passwort>\n<script>'` — sudo isst Zeile 1, `bash -s` führt den Rest als root
  aus (solche Skripte enthalten **kein** inneres `sudo`).
- **`LC_ALL=C`** auf sudo/apt-Befehlen ist load-bearing: `isSudoPasswordFailure`
  matcht englische Meldungen; ohne LC_ALL=C bricht die Passwort-Fehlererkennung
  auf lokalisierten Pis still.
- **Redaction**: `_withConnection` wickelt jedes `onLog` in `redactPassword`.
- **Marker-Disziplin** — drei Root-Skript-Helfer, aufsteigend streng:
  - `_runRootScript`: prüft nur Sudo-Ablehnung + Exit-Code.
  - `_runRootScriptExpectMarker`: für **destruktive** Skripte (Restore,
    Config-Save, Timer-Install/Remove) — Erfolg braucht den Marker **und**
    keinen Nonzero-Exit; fehlender Marker = Fehler, **auch bei Exit-Code null**
    (Signal-Kill / Verbindung mitten im Lauf abgerissen → ein halb erledigter
    Restore darf nie als Erfolg gemeldet werden). Skripte laufen unter `set -e`,
    der Marker steht nur am Happy-Path-Ende.
  - `_runRootScriptCapturing`: zusätzlich `BACKUP_OK <pfad>`-Parsing.
- **Cancel**: `cancel()` setzt `_cancelRequested` + schließt `_active`.
  `_withConnection` prüft das Flag (1) nach connect — ein Cancel im Handshake
  muss vor dem (evtl. destruktiven) body stoppen — und (2) nach dem body, weil
  ein Schließen mitten im Befehl `run()` **nicht** immer werfen lässt (dartssh2
  beendet den Stream normal → ein Teil­ergebnis sähe erfolgreich aus).
- **Fehler-Mapping** nur im `catch` von `_withConnection`: HostKeyDeclined →
  connection, HostKeyChanged → hostKeyChanged (mit Fingerprint), Auth/KeyDecode →
  auth, Socket/Timeout → connection, sonst unknown. Runner wird immer im
  `finally` geschlossen.
- `EvccUpdater.real()` muss **dieselbe** `HostKeyStore`-Instanz an Runner-Factory
  und `hostKeyStore` geben, sonst widersprechen sich `forgetHostKey` und Runner.

## 3. Reine Logik — Befehle & Parser (`commands.dart`, `parsing.dart`)

I/O-freier Kern: `commands.dart` baut **jeden** Shell-Befehl/Skript,
`parsing.dart` wertet Ausgaben aus. Zentrale Regeln:
- **`shSingleQuote`** ist das *eine* Escaping-Primitiv (`'\''`-Idiom) — jede in
  Shell interpolierte Variable (Container-Namen, Pfade, Compose-Labels, Env,
  Mounts) geht hindurch. Auch von `files.dart`, `alerts.dart`,
  `pihole_service.dart`, `homeassistant_service.dart` importiert.
- **Config schreiben** umgeht Quoting ganz: Inhalt als **base64** transportiert
  (`buildConfigWriteScript`) → beliebige Bytes, kein Injection-Risiko. Schreibt
  in `mktemp` + `mv -f` (atomar), `chmod/chown --reference` vorher (Rechte
  erhalten), rotiert Backups (neueste 5), Marker `CONFIG_SAVED`.
- **Detection-Batch**: `buildDetectBatch`/`splitDetectSections` bündeln ~13
  Probes in **eine** SSH-Runde (`@@PT@@key@@PT@@`-Marker, `{ cmd ; } 2>&1 || true`
  isoliert einzelne Fehlschläge). Ausgeführt via `detectShellCommand`
  (`LC_ALL=C bash -s`).
- **Docker**: `parseEvccDocker` bevorzugt Image-Match, Name-Fallback nur
  *exakt* `evcc` (sonst würde `evcc-db` fälschlich gewählt). `buildDockerRunCommand`
  rekonstruiert `docker run` aus `docker inspect` mit Whitelist bei Restart-Policy
  und erhält devices/caps/privileged (USB/RS485-Zähler!). `dockerRunRecreateScript`:
  `pull` zuerst → altes Container zu `<name>-evccpitool-old` **umbenennen**
  (Rollback, nie `-v` löschen) → neu starten → `.State.Running` prüfen → bei
  Crash zurückrollen.
- **`parseInstalledVersion`** liefert Version nur bei dpkg-Status exakt
  `installed` (ein `rc`-Zustand trägt noch eine Version → sonst falscher Update-
  Vorschlag). `isAlreadyNewest` nutzt Negative-Lookbehind (`10 upgraded` matcht
  nicht `0 upgraded`), `kept back` ⇒ nicht „aktuell".

## 4. Service-Katalog (`services/*.dart`)

Flutter-freier Dienst-Katalog (siehe `design/2026-06-30-multi-service.md`). Pro
Dienst nur: Befehlsstrings, Root-Skripte, reine Parser. Orchestrierung
(Verbindung, Passwort-Piping, Marker) liegt bewusst in `evcc_updater.dart`.

- **`pi_service.dart`** — `ServiceStatus` (Modell). `updateAvailable` ist nur bei
  `updateKnown == true` aussagekräftig (Tri-State: Docker-evcc / nicht-gepinnte
  HA-Tags zeigen „Aktualisieren" statt falsch „Aktuell"). Reconciler
  `applyLatestEvccVersion` (nur apt-evcc, gegen stalen lokalen apt-Index) /
  `applyLatestHomeAssistantVersion` (nur calver-vs-calver). `compatible=false`
  → Karte ausgegraut mit Grund (z.B. Pi Connect < Bookworm).
- **`apt_services.dart`** — Grafana/InfluxDB/Mosquitto. **Supply-Chain:**
  InfluxDB prüft den GPG-**Fingerprint** vor dem Vertrauen; Grafana speichert den
  armored Key ohne dearmor (aktueller offizieller Flow).
- **`pihole_service.dart`** — v5+v6-Versionsparser; Backup via Teleporter, Restore
  **verweigert v5 `.tar.gz`** (nur v6-CLI-Import); der DNS-Reload im Restore
  bewusst *nicht* fehlerverschluckt (`set -e` vor `RESTORE_OK`).
  **CLI-Falle (v6):** `pihole` schickt jeden unbekannten Subcommand in `helpFunc`
  — und die endet mit **Exit 0**. Ein Kommando, das es in der laufenden
  Generation nicht gibt, meldet also *Erfolg*. v6 kennt `restartdns` nicht mehr
  (nur `reloaddns`/`reloadlists`), v5 kennt `reloaddns` nicht. Deshalb wählt
  `piholeRestartCommand` per **Fähigkeits-Probe** (`pihole --help | grep -q
  reloaddns`) statt per Exit-Code; der Restore nutzt fest `reloaddns` (v6-only).
  Für neue `pihole`-Subcommands gilt dieselbe Regel: Exit-Code ≠ Beweis.
- **`homeassistant_service.dart`** — HA als Docker-Container (bewusst, nicht HA
  OS). tar-Exit 1 auf laufendem HA = Warnung (nur rc>1 = Fehler). Restore per
  `trap` (Container kommt auch bei tar-Fehler zurück) + `.State.Running`-Check.
- **`system_service.dart`** — „System (Pi)"-Karte. `systemPendingCommand`
  simuliert `apt-get -s full-upgrade` (muss zur echten Aktion passen).
  `lowDisk` gate auf *absoluten* freien Platz (1-TB-Disk bei 94% warnt nicht).
  **SD-Gesundheit:** `systemStorageCommand` (no-sudo Probe: /proc/mounts +
  `journalctl -k`-Fehlerzählung) → `parseStorageHealth` → `StorageHealth`
  (`warning` = Root nur-lesend ODER ≥5 Kernel-I/O-Fehler; nur `/` zählt —
  ein bewusst read-only /boot darf nicht false-positiven). Fließt in
  `SystemHealth.warning`/`summary` und den Alerts-Wrapper ein.
- **`pi_connect.dart`** — Raspberry Pi Connect (Bookworm+). **User-Service**:
  jeder Befehl mit `XDG_RUNTIME_DIR=/run/user/$(id -u)`, **nie sudo**. `signin`
  läuft **detached** (`setsid … &`, sleep, cat) — sonst hängt der SSH-Call. Doku
  deckt Headless-/SSH-Verhalten nicht ab → Parser tolerant, **Gerätecheck nötig**.
- **`tailscale.dart`** — VPN/Mesh, **System-Service** (einfacher als Pi Connect).
  `up` detached (Login-URL). „up" = hat 100.x-Tailnet-IP. down/logout via sudo.

## 5. On-Pi-Automatik (`auto_update.dart`, `alerts.dart`, `files.dart`, `notifications.dart`)

**Kern-Entscheidung:** Automatik läuft als **systemd-Timer auf dem Pi**, *kein*
Android-Hintergrunddienst (v0.20.0-Absturz-Lektion). Reine Builder → POSIX-Shell.

- **`auto_update.dart`** — geplante apt-Updates (`pi-tool-autoupdate.timer`).
  Wrapper: `DEBIAN_FRONTEND=noninteractive` + `--force-confold` (kein
  conffile-Hänger), sichert evcc vorher, **self-heal** (startet evcc neu falls es
  starb), schreibt Status-Datei. Marker `AUTOUPDATE_INSTALLED/REMOVED`.
- **`scheduled_backup.dart`** — geplante Backups (`pi-tool-backup.timer`, spiegelt
  `auto_update.dart`). Wrapper sichert **evcc** (Konfig + `/var/lib/evcc`) und
  **Pi-hole** (Teleporter `pihole -a -t`/`pihole-FTL --teleporter`), beide
  presence-gated, mit **Rotation** (`keep` neueste behalten). **Atomar:** tar nach
  `.part` → `mv` bei Erfolg, Rotation NUR nach Erfolg + spezifischer Glob (ein
  fehlgeschlagenes tar darf kein gutes Backup verdrängen — Review-Fund; derselbe
  Härtungsschritt auch in `auto_update.dart`). Quoted `<<'WRAP'`,
  Status-Datei `/var/lib/pi-tool/backup.status`, Marker `BACKUP_TIMER_INSTALLED/
  REMOVED` über `_runRootScriptExpectMarker`. Pro-Feature. HA bewusst NICHT im
  Timer (Docker-/config-Discovery zu fragil für unbeaufsichtigt).
- **`alerts.dart`** — 30-Min-Health-Check → **ntfy**-Push (backend-frei) bei
  Platte ≥90% / Temp ≥75° / totem Dienst / anstehenden Updates. **Debounce** via
  `alerts.last` (Push nur bei Änderung). **Heredoc-Regel**: ntfy-Server/-Topic
  sind `shSingleQuote`d und landen in einem **quoted** Heredoc (`<<'WRAP'`) → kein
  Install-Zeit-Expand von `$(reboot)`. Blöcke nie zusammenlegen/entquoten.
  **Topic-Invariante (v0.63.0):** ntfy kennt kein Konto — das Topic *ist* das
  Passwort, wer es errät liest den Health-Feed mit. Deshalb `generateNtfyTopic()`
  (`pi-tool-` + 14 Zeichen aus einem 31er-Alphabet ohne Verwechsler `0/o`,
  `1/l/i` ≈ 69 Bit, `Random.secure`) — das Sheet belegt bei leerem Topic damit
  vor, ein Würfel-Button würfelt neu, und `isWeakNtfyTopic()` (< 16 Zeichen oder
  < 8 verschiedene Zeichen) markiert erratbare Namen im Sheet **und** als
  Warnzeile auf der Automatik-Karte (`_AutomationTile.warning`) — Bestandsnutzer
  öffnen das Sheet sonst nie wieder. Beides rein/testbar; nie durch ein
  Freitext-Feld ohne Vorbelegung ersetzen.
- **`files.dart`** — Datei-Browser über den normalen Exec-Kanal (kein SFTP → der
  `FakeSshRunner`-Seam deckt ihn ab). `head -c 512K | base64` (Server-seitiges
  Limit gegen OOM bei riesigen Dateien). **Löschen** (`buildDeleteCommand`,
  `rm -f`/`-rf` mit `--` + Quoting) und **Upload** (`buildUploadScript`, base64 →
  atomar `mv -f`, Marker `UPLOAD_OK`, Limit `kFileUploadLimit` 8 MB, via
  `EvccUpdater.uploadFile`) laufen als Root. **Download**
  (`EvccUpdater.downloadFile`, ohne sudo — Backups sind bewusst 0644): erst
  `buildFileSizeCommand` (Abbruch VOR dem Transfer bei > `kBackupDownloadLimit`
  48 MB), dann `buildDownloadFileCommand` (base64) mit Längen-Verifikation
  (Truncation = Fehler). Aufs Handy via `fileSaver`-Seam (Default: Temp-Datei
  über dart:io + share_plus-Teilen-Dialog — kein path_provider nötig).
  **Bearbeiten:** `isProbablyTextFile` (NUL-Byte oder >5 % C0-Control = binär;
  UTF-8-Umlaute zählen nicht) + `kFileEditLimit` (256 KB) entscheiden, ob die
  Vorschau einen „Bearbeiten"-Knopf zeigt; der reicht an den bestehenden
  Config-Editor weiter (atomarer Write + Backup, sudo-fähig).
- **`ssh_keys.dart`** — **client-seitige** SSH-Key-Erzeugung. `generateSshKey`
  (Ed25519 via `cryptography`, rein Dart) → privater Key als **openssh-key-v1**-
  PEM (selbst kodiert; Korrektheit per Round-Trip getestet: `SSHKeyPair.fromPem`
  lädt ihn) + `authorized_keys`-Zeile. Der **private Key entsteht im Handy und
  verlässt es nie** — nur der Public Key geht auf den Pi (`buildInstallAuthorizedKeyScript`,
  idempotent, `~/.ssh` 700/600, Marker `KEY_INSTALLED`, **kein** Root).
  Kommentar wird sanitisiert (kein `authorized_keys`-Zeilen-Injection).
  `EvccUpdater.installSshKey` orchestriert; `_setupSshKey` installiert per
  Passwort-Login und **verifiziert dann End-to-End** (`verifyKeyAuth` öffnet eine
  Key-only-Verbindung + Marker) — **erst bei Erfolg** wird auf Key-Auth
  umgestellt/persistiert (Marker-Disziplin: kein falscher „Erfolg"); lehnt der
  Pi den Key ab, bleibt das Profil auf Passwort mit klarer Meldung. Passwort
  bleibt für sudo. Privater Key nur in `FlutterSecureStorage`, nie geloggt.
  **Einstiegspunkt ist pro-Pi, nicht global:** ein Inline-Button im
  `_ConnectionCard`-Key-Panel (sichtbar, solange das SSH-Key-Segment aktiv und
  noch kein Key hinterlegt ist — `onSetupKey`), NICHT mehr im ⋮-Menü. `_setupSshKey`
  ist gegen den leeren-Key-Fall abgesichert (baut die Install-Verbindung immer
  explizit als Passwort-Auth, unabhängig vom gewählten Segment) und idempotent
  (bricht ab, sobald ein Key vorhanden ist). Die `_ConnectionCard` ist
  **einklappbar** (`expanded`/`onToggleExpanded`, State `_connExpanded`): Default
  eingeklappt, sobald `_credsComplete()` (Host + passendes Secret) erfüllt ist,
  und automatisch nach erfolgreicher Verbindung — so frisst v. a. das große
  PEM-Feld keinen Platz. Host-wechselnde Aktionen (`_useTailscaleIp`,
  `_useHomeHost`, `_remoteAccessViaTailscale`) klappen wieder auf, damit der neue
  Host sichtbar ist. `_connExpanded` ist reine UI-Laufzeit-State, NICHT persistiert.
- **`systemd_services.dart`** — extra **erkannte** systemd-Dienste (AdGuard Home,
  Node-RED, Zigbee2MQTT): `SystemdService`-Deskriptoren + `parseSystemdState`
  (`systemctl show -p LoadState -p ActiveState` → installed/active). Detection
  fügt pro Dienst eine `SYSD:<unit>`-Probe in den Batch; erkannte Dienste werden
  Karten (Web öffnen / Logs / `restartSystemdUnit`). **Bewusst KEIN Install** —
  die Installer sind projektspezifisch (curl|sh); die App erkennt + verwaltet
  nur. Log-Unit-Mapping in `buildServiceLogsCommand` (`adguard`→`AdGuardHome`).
- **`docker_containers.dart`** — Container-Übersicht. `dockerPsSudoCommand`
  (`docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}|{{.Image}}'`, sudo)
  + `parseDockerPs` (Pipe-Format wie die evcc-Docker-Probe; Fehler-/Daemon-Zeilen
  ohne Pipe → leer). `buildDockerRestartCommand`/`buildDockerLogsCommand`
  (Name shell-gequotet). `EvccUpdater.dockerContainers/restartDockerContainer/
  fetchDockerLogs`; `_DockerSheet` (Liste + pro Container Neustart/Logs → nutzt
  `_LiveLogSheet`). System-Karten-Aktion; leer, wenn Docker fehlt.
- **`storage_explorer.dart`** — „Was frisst meinen Platz?". `buildStorageProbe`
  = sudo `du -x -b -d1` (Unterordner) + `find -maxdepth 1 -type f` (Dateien) in
  Markern; `parseStorageBreakdown` → nach Größe sortierte `DiskEntry`s (Query-
  Total verworfen); `formatBytes`-Helper. `EvccUpdater.diskUsage` orchestriert;
  `_StorageExplorerSheet` (Drill-down, holt jede Ebene selbst). **Achtung:**
  Namen `parseDiskUsage`/`DiskUsage` gehören zu `system_service.dart` (Root-FS-
  Health) — NICHT verwechseln, daher der eigene Name.
- **`_LiveLogSheet`** (`ui_widgets.dart`) — Service-Logs mit „Live"-Schalter:
  `Timer.periodic` (3 s) re-fetcht `fetchServiceLogs` (Polling, kein PTY/Dienst),
  Timer wird in `dispose` abgebrochen.
- **`security_check.dart`** — Nur-Lesen-Audit. `buildSecurityProbe` = **ein**
  `sudo sh -c`-Probe (Skript via `shSingleQuote` sicher gequotet) mit Section-
  Markern (`__SEC_SSHD__/UNATT/F2B/PORTS__`); `parseSecurityReport` macht daraus
  fünf Ampel-`SecurityFinding`s (SSH-Root-Login, Passwort-Login, Auto-Updates,
  fail2ban, offene Ports). **Nichts wird verändert**; Unbekanntes degradiert zu
  `info` (nie falsches ok/warn). `EvccUpdater.runSecurityCheck` orchestriert;
  `_SecurityReportSheet` rendert (System-Karten-Aktion).
- **`app_launcher.dart` + native `MainActivity`** — `AppLauncher`-Seam (Default
  `ChannelAppLauncher` über MethodChannel `pi_tool/launcher`): öffnet eine andere
  installierte App per `getLaunchIntentForPackage` (Play-Store-URL-Fallback via
  `ACTION_VIEW`). Für den **Tailscale-Fernzugriff-Helfer** (`_remoteAccessViaTailscale`):
  Tailnet-IP als Host vorbelegen + Tailscale-App öffnen. **Liegt im ⋮-App-Bar-Menü**
  (IMMER gelistet für vorhersehbare Menüstruktur; deaktiviert mit Hinweis, solange
  `_tailscaleIp` unbekannt ist), NICHT auf der Tailscale-Karte — Fernzugriff
  ist genau dann sinnvoll, wenn man NICHT verbunden ist; die Karte ist offline
  unerreichbar. Die zuletzt gesehene Tailnet-IP wird pro Profil persistiert
  (`Profile.tailscaleIp`, von `_rememberTailscaleIp` bei Detection gesetzt), damit
  der Helfer den Host auch offline vorbelegen kann. Symmetrisch dazu merkt sich
  `_rememberLanHost` die Heim-/LAN-Adresse (`Profile.lanHost`, jeder Nicht-Tailnet-
  Host beim Verbinden) — steht der Host auf einer Tailnet-Adresse, bietet das
  ⋮-Menü „Zurück auf Heim-IP" (`_useHomeHost`) als Ein-Tap-Undo. „Tailnet" erkennt
  `isTailnetHost` (in `tailscale.dart`): `100.`-Präfix (CGNAT) ODER `*.ts.net`-
  MagicDNS — so überschreibt ein MagicDNS-Login die Heim-IP nicht. **Android lässt keine App
  ein fremdes/System-VPN selbst einschalten** — bewusst KEIN eigener VPN-Client
  (v0.20.0-Native-Lektion). Manifest: `<queries><package com.tailscale.ipn>` für
  Package-Sichtbarkeit (Android 11+). Seam injizierbar für Tests.
- **`file_pick.dart` + native `MainActivity`** — lokale Dateiauswahl fürs Upload.
  **Bewusst KEIN Picker-Plugin:** `file_picker` bringt sein eigenes altes
  Kotlin-Gradle-Plugin mit und scheitert am AGP-9-/Built-in-Kotlin-Setup (und es
  gibt kein stabiles file_picker mit win32 ^6). Stattdessen ein winziger
  Android-SAF-Picker (`ACTION_OPEN_DOCUMENT`) **in der App** (`MainActivity.kt`,
  MethodChannel `pi_tool/filepicker`) → nutzt das projekteigene Kotlin/AGP.
  `FilePickerService`-Seam (`ChannelFilePicker` real, injizierbar für Tests).
- **`notifications.dart`** — **schlafender**, plugin-freier Kern für
  Update-Benachrichtigungen (`summarizeUpdates` + geseamter `UpdateCheckRunner`);
  bewusst **dauerhaft nicht** als Android-Hintergrunddienst verdrahtet. Grund:
  Update-Push existiert bereits architekturkonform — der On-Pi-Health-Alert-Timer
  pusht „N Updates verfuegbar" via ntfy (`alerts.dart`). Ein Android-Background-
  Check wäre redundant **und** verstieße gegen die „kein Android-Hintergrunddienst
  für Automatik"-Invariante (v0.20.0-Lektion). Der Kern bleibt getestete Reserve
  für künftige *Vordergrund*-Nutzung.

> **Heredoc-Regel für On-Pi-Skripte:** Dart-`$var` interpoliert *vor* der Shell;
> Dart-`\$` wird literales `$` für die Shell. Alles, was zur Shell-Laufzeit
> expandieren soll, muss in einem **quoted** Heredoc stehen, sonst expandiert die
> installierende Shell es zur Install-Zeit.

## 6. State & Infrastruktur

- **`profiles.dart`** — `Profile` (ein Pi) + `AppConfig` (Profil-Liste + alle
  globalen Settings, u. a. `consoleHistory` und `customCommands` = eigene
  Konsolen-Schnellbefehle). `parseAppConfig` ist tolerant (jeder Decode-Fehler →
  `AppConfig.initial`). `backupBeforeUpdate` default **ON** (`!= false`).
  `AppConfigStore` (Key `app_config_v1`) migriert einmalig aus den 14 Legacy-Flat-
  Keys und **löscht sie danach** (kein Klartext-Credential-Rest). Alles
  (Passwörter, PEM-Keys) nur in `FlutterSecureStorage` (Keystore).
- **`settings_store.dart`** — Legacy-Migrationsquelle, `HistoryStore`,
  `SecureHostKeyStore`. Passwort-Feld ist dual: SSH+sudo (Passwort-Modus) bzw.
  nur sudo (Key-Modus).
- **`entitlement.dart`** — **schlafendes Freemium**: `DormantEntitlement` = jeder
  ist Pro (Sideload-Nutzer verlieren nichts vor dem Play-Launch). Pro-Features:
  `backups`, `console`, `cleanup`, `multiPi`, `automation` (geplante Updates +
  Health-Alerts), `files` (Dateien-Tab) (+ 1-Profil-Limit); die Paywall-Liste in
  `_showPaywall` muss dazu passen. Echte Play-
  Billing-Impl wird später hinter `EntitlementService` gesteckt. Gate-Punkte nie
  mit `!isPro` inlinen — immer über den Seam / `_proGate`.
- **`demo.dart`** — **Demo-Modus**: `DemoSshRunner implements SshRunner` liefert
  kanned Kommando-Ausgaben (Detection-Batch + Datei-/Terminal-Befehle) plus ein
  Demo-`EvccApiClient`. Injiziert über `buildDemoUpdater()` (die einzige
  `runnerFactory`-Stelle) — EINE Klasse füllt alle Tabs mit Beispieldaten, ohne
  echten Pi/Socket. In `main.dart`: `_demoMode` (in-memory wie `_connected`) swappt
  `_updater`/`_apiClient` auf die Demo-Instanzen (`_startDemo`), zurück via
  `_restoreRealBackend` (jeder echte Connect / Profilwechsel / Cred-Edit /
  `_exitDemo`). Pro ist im Demo offen über **`_unlocked = _isPro || _demoMode`** —
  alle Gate-Sites lesen `_unlocked`, nie mehr roh `_isPro`. Löst die Play-
  „LoginWall"-Prüfung ohne Demo-SSH-Server.
  **Play-Invariante (nicht verhandelbar):** Ohne eingerichteten Pi muss der
  Einstieg „Demo ausprobieren" **auffällig und ohne Scrollen sichtbar** sein —
  gefüllter Knopf mit Key `demoEntry`, **vor** „Pi im WLAN suchen", plus
  Erklärzeile `demoEntryHint`. Er versteckt sich erst, wenn das Profil
  **wirklich nutzbar** ist — `_connected || _credsComplete()` (Host **und** das
  Geheimnis des Auth-Modus), beobachtet über `Listenable.merge([_host,
  _password, _privateKey])`. **Nicht** auf „Host-Feld nicht leer" zurückbauen:
  ein Tipp auf ein Gerät in der WLAN-Suche füllt nur den Host, und genau dadurch
  verschwand der Einstieg mitten im Ablauf (Googles Screenshot zu Code 115:
  „Host set to 192.168.97.1", kein Weg mehr in die App). Daran hängt die
  Play-Erklärung **App-Zugriff = „kein Teil ist zugangsbeschränkt"**: ohne diesen
  Weg wirkt das Verbindungsformular wie eine Login-Wand. **Zweimal passiert:**
  v0.60.0 (19.07.2026, es gab den Demo-Modus noch nicht) und v0.63.0/Code 114
  (26.07.2026 — v0.62.0 hatte den Einstieg zum leisen Textlink an dritter Stelle
  degradiert; auf dem kleinen Prüfer-Display lag er unter der Falz, der Beleg
  „LoginWall.png" zeigt genau das). Ein Test in `dispatch_test.dart` pinnt seit
  v0.63.1 Position und Sichtbarkeit auf 360×640 fest — nicht aufweichen, ohne die
  Play-Erklärung mit zu ändern (siehe `store/launch-kit.md`).
- **`early_adopter.dart`** — Marker fürs künftige Pro-**Grandfathering**:
  `AppConfig.firstSeenVersionCode` wird beim Start **einmalig** gestempelt
  (`_stampFirstSeenMarker`, best-effort, **nach** dem Unlock, ohne `setState` —
  nichts im Boot-/Lock-Pfad). Sentinel `0` = Bestandsnutzer (erkannt via
  `disclaimerAccepted`/`lastSeenVersion`); `isGrandfathered(fs, paywallVC) = fs <
  paywallVC`. Noch **kein** Gating — reines Aufzeichnen (Play-Billing-Zukunft).
- **`profile_transfer.dart`** — verschlüsselter Profil-Export/-Import (Gerätewechsel):
  die AppConfig-JSON wird mit **AES-256-GCM** unter einem **PBKDF2-HMAC-SHA256**-
  Schlüssel (aus einer User-Passphrase) versiegelt. Rein Dart (`cryptography`,
  kein Native-Plugin, nichts im Startpfad). Enthält Zugangsdaten → authentifizierte
  Verschlüsselung + bewusst langsame KDF (`kExportKdfIterations`); Import cappt die
  Iterationen (`_kMaxKdfIterations`) gegen DoS-Dateien. UI in den Einstellungen,
  Export via `fileSaver`-Seam, Import via SAF-Picker.
- **`session.dart`** — reine Sitzungs-/Tab-Gating-Logik (v0.57): `kTab*`-
  Konstanten, `isGatedTab`/`tabAllowed`/`tabAfterDisconnect`. Details im
  UI-Shell-Abschnitt („Verbundene Sitzung").
- **`language.dart`** — reine Sprach-Auflösung (v0.58): `localeForLanguageMode`
  + `resolveSystemLocale` (Englisch-Fallback). Siehe „Sprache" im UI-Abschnitt.
- **`l10n.dart`** — `context.l10n`-Extension auf die generierten
  `AppLocalizations` (Quellen: `lib/l10n/app_{de,en}.arb`; Generat gitignored).
- **`update_check.dart`** — Self-Update-Check (nur Sideload-Kanal) + evcc-/HA-
  Versionsproben, alle fail-soft (Fehler → null). `isNewerVersion` numerisch.
  **`installChannelFor(PackageInfo.installerStore)` → `InstallChannel`** setzt
  „nur Sideload" durch: bei `com.android.vending` (bzw. dem Legacy-Installer
  `com.google.android.feedback`) unterbleiben Banner UND Netz-Check, und „Auf
  Update prüfen" verweist auf die Play-Seite. Grund: Play verlangt Updates über
  Play, und Play App Signing re-signiert das Bundle — die anders signierte
  GitHub-APK ließe sich über eine Play-Version gar nicht installieren. Alles
  nicht sicher als Play Erkannte gilt als Sideload (dort IST der Hinweis der
  einzige Update-Pfad). Kein Native-Code nötig — `installerStore` kommt aus dem
  ohnehin genutzten `package_info_plus`.
- **`evcc_api.dart`** — read-only `GET /api/state`. `followRedirects = false`
  (kein Bounce durch einen Impersonator), nie Credentials, defensiver Parser.
- **`network_scan.dart`** — „Pi finden": TCP-Port-22-Sweep des /24 (bewusst
  kein mDNS: kein Plugin, kein Multicast-Lock).
- **`keep_alive.dart`** — Android-Foreground-Service (hält den Prozess bei langen
  SSH-Aktionen am Leben; führt **keinen** eigenen Code aus). Best-effort, darf die
  Aktion nie brechen.
- **`authenticator.dart`** — App-Lock (Biometrie/PIN, `local_auth`). Fail-closed.

## 7. UI-Shell (`main.dart`, `ui_widgets.dart` (part), `kyth_splash.dart`)

Ein großer `StatefulWidget` (`_UpdaterPageState`) hält allen State und rendert das
**Cockpit**: `NavigationBar` + `IndexedStack`, 4 Tabs **Verwaltung / Automatik /
Terminal / Dateien** (Tab 0 hieß bis v0.56 „Dienste"). `ui_widgets.dart` ist ein
`part of '../main.dart'` (teilt sich `kGreen/kBlack/kCard` ohne Re-Import —
nicht in einen Import „aufräumen").

**Verbundene Sitzung (v0.57, `session.dart`):** „Verbindung herstellen" setzt
`_connected` — ein **gemerkter, geprüfter Zustand, KEIN gehaltener Socket**
(Aktionen verbinden weiter pro Aktion, `_withConnection` unverändert). Die reine
Gating-Logik (`kTab*`-Konstanten, `isGatedTab`/`tabAllowed`/`tabAfterDisconnect`)
lebt in `lib/src/session.dart` (unit-getestet). Automatik/Terminal/Dateien sowie
die SSH-Aktionen „Pi neu starten/herunterfahren" im ⋮-Menü sind bis dahin
gesperrt (ausgegraut + Hinweis). `_connected` fällt auf `false` bei:
Profilwechsel (`_resetDetectionForNewPi`), Zugangsdaten-Edit
(`_invalidateConnTest`), Verbindungs-Fehlern (`connection`/`auth`/
`hostKeyChanged` im `_guard`-Catch) und **nach „Pi herunterfahren"** — mit
Snap-Back auf Tab Verwaltung. `_beginBusy` fasst `_connected` bewusst NICHT an.
In-Memory, nie persistiert (Kaltstart = getrennt; Resume löst kein SSH aus).
Bewusster Gate-Bypass: der „Log"-Sprung der Running-Bar öffnet den Terminal-Tab
auch ohne Sitzung (laufende Aktion → Log muss sichtbar sein).

**Gate-Reihenfolge in `build()`** (load-bearing): `_booting` (neutraler
Splash-Ersatz) → `_locked` (Lock-Screen) → `!_disclaimerAccepted`
(Ablehnen = App beenden) → einmaliges „Was ist neu?" (post-frame) → Shell
(deren Tab-Gate siehe „Verbundene Sitzung" oben).

**Theme:** Hell/System/Dunkel wählbar (`themeModeNotifier`, „Design"-Umschalter).
Das App-Theme baut das öffentliche `buildAppTheme(Brightness, {fontFamily})` —
Single Source of Truth, auch vom Screenshot-Generator (`test/screenshots.dart`)
genutzt; `kGreen` aliast `KythWordmark.kWordmarkGreen`. **Ausnahme:** der
`_LockScreen` (Fingerprint-Startscreen direkt nach dem dunklen Splash-Video) ist
per `Theme(data: buildAppTheme(Brightness.dark))`-Wrapper **fest dunkel** —
unabhängig vom App-Theme, damit kein heller Blitz erscheint.

**Sprache (v0.58, l10n):** komplette UI-Schicht Deutsch/Englisch via Flutter
`gen-l10n`: `lib/l10n/app_{de,en}.arb` (~500 Keys; generierte
`app_localizations*.dart` sind **gitignored**, entstehen bei `flutter pub get`),
Zugriff über die `context.l10n`-Extension (`lib/src/l10n.dart`). Reine
Auflösungslogik in `lib/src/language.dart`: `localeForLanguageMode`
(`AppConfig.languageMode` `'system'|'de'|'en'` → forced Locale oder null) und
`resolveSystemLocale` (**Englisch-Fallback** für alle Nicht-DE-Geräte);
verdrahtet über `localeNotifier` + `localeResolutionCallback` in
`EvccPiToolApp`. Tests pinnen `Locale('de')` in ihren MaterialApp-Helpern,
damit deutsche Text-Finder stabil bleiben. **Tier 2 (offen):** Meldungen der
Logik-Schicht (`evcc_updater`-Exceptions, gestreamte Log-Zeilen) sind bewusst
noch Deutsch (kein `BuildContext`; vermischt mit rohem Befehls-Output) — Spec:
`docs/superpowers/specs/2026-07-15-app-lokalisierung-design.md`.

**Aktions-Protokoll (jede der ~30 Aktionen):**
`if (_busy) return;` → `_prepare()` (validieren → `SshConfig` bauen →
`_lastConfig` merken → persistieren → `_beginBusy()` setzt `_busy` synchron,
**kein Doppeltipp-Fenster**) → **`_lastAction` VOR dem ersten `_guard`** (damit
Host-Key-Retry *diese* Aktion wiederholt) → SSH-Arbeit **in `_guard`** (das
`finally` setzt `_busy`/`_busyMessage` zurück, beendet Keep-Alive).
- `_guard` ist der **einzige** Fehler-Handler. Generische Fehler bleiben (redigiert)
  nur im Log, die Überschrift bleibt generisch.
- **Geteilte Leisten über allen Tabs** (weil Aktionen aus jedem Tab starten): die
  **Running-Bar** (Fortschritt + `_busyMessage` + „Log"-Sprung + Abbrechen) ist an
  `_busyMessage != null` gekoppelt (nicht `_busy`) → zeigt echte SSH-Arbeit, nicht
  während ein Bestätigen-Dialog `_busy` hält; die **Host-Key-Leiste**; der
  **Status-Banner**.
- **Achtung:** Flows, die an eine Page/Sheet übergeben (`_browseFiles`,
  `_guidedSetup`), müssen `_busy` nach `_prepare()` selbst freigeben — sonst
  UI-Deadlock. Mehrphasige Flows (Liste→Auswahl→Bestätigen→Aktion) rufen vor dem
  zweiten `_guard` erneut `_beginBusy()`.
- **Profile:** Umschalter in der App-Leiste (`Key('profileSwitcher')`, neutrales
  Server-Icon — *keine* Farbe, die wie Status-LED wirkt); pro Zeile ⋮
  (umbenennen/löschen). Wechsel ruft `_resetDetectionForNewPi()` (nichts leckt
  zwischen Pis).
- **Multi-Pi-Überblick:** `_MultiPiDashboardPage` (in `ui_widgets.dart`) zeigt
  eine Ampel-Zeile pro Profil (grün / amber = Updates·Warnung / rot = nicht
  erreichbar). `_showMultiPiDashboard` friert die Profil-Liste ein (aktives
  Profil aus den Live-Controllern via `_currentProfile()`) und übergibt
  `_probePi`. Die Page **probt sequenziell** (`_probePi` baut per
  `_configForProfile` eine `SshConfig` — `port` ist String → `int.tryParse`,
  `pi`-Default — und ruft `detectServices`), **fail-soft** (jeder Fehler →
  `reachable:false`, kein Abbruch der übrigen), abbrechbar durch Verlassen der
  Page (`_cancelled`), mit Refresh-Action. Eintrag im ⋮-Menü nur bei
  `_profiles.length > 1`, Pro-gated (`ProFeature.multiPi` via `_proGate`).
  **Bulk-Update:** App-Leisten-Knopf „Alle aktualisieren" iteriert sequenziell
  über die erreichbaren Pis MIT Updates (`update`-Callback = `_updatePiSystem` →
  `upgradeSystem` pro Profil), **fail-soft** (ein Fehler stoppt die übrigen
  nicht), Status pro Zeile, danach Re-Probe.
- **Karten:** nicht-installierte Dienste (außer `system`) werden zu
  `_AddableService`-Picker-Einträgen, nie Karten. `_ServiceCard`-⋮ hat stabiles
  `ValueKey('menu-${id}')`. Pro-Aktionen zeigen Free-Nutzern ein Schloss, der Tap
  feuert trotzdem (Gate in der Callback via `_proGate` → `_showPaywall`).
- **Onboarding:** `_SetupGuidePage` (in `ui_widgets.dart`) erklärt Einsteigern die
  Pi-Einrichtung per Raspberry Pi Imager (SSH/Benutzer/WLAN). Erreichbar via
  `_openSetupGuide()` aus dem ⋮-Menü **und** als Link auf dem Verbindungs-Screen,
  solange das Host-Feld leer ist (neben „Pi im WLAN suchen").
- **Dateien-Tab:** `_FilesView` (in `ui_widgets.dart`) = eingebetteter Browser
  (durchsuchen/vorschau/hochladen/löschen). Config via `_filesConfig()` (leise,
  ohne `_busy` — Tab zeigt sonst einen „erst verbinden"-Platzhalter); Pro-gated
  (`_filesPlaceholder` für Free). Datei-Ops (`_filesList/_filesOpen/_filesUpload/
  _filesDelete`) verbinden pro Aktion selbst (wie der frühere Browser, ohne
  `_guard`); `_filesUpload` nutzt den `FilePickerService`-Seam. Der View
  serialisiert Taps gegen doppelte Verbindungen.
- **Terminal/Konsole:** `interactiveCommandHint` (commands.dart) fängt TUI-Befehle
  (htop/vi/less/`-f`) ab und zeigt eine Alternative, statt „Error opening
  terminal" — die Konsole hat kein PTY.
- **`kyth_splash.dart`**: `splashDoneNotifier` (default `true`, damit Tests/Hot-
  Reload nie blockieren); der Lock wartet darauf, bevor die Biometrie kommt.
- **`kyth_wordmark.dart`** — `KythWordmark`, die Corporate-Wortmarke nach Spec
  (`KYTH-Wortmarke.md`): `KYTH` in **Bricolage Grotesque** ExtraBold (Variable-
  Font, gebündelt unter `assets/fonts/`, OFL — kein Google-Fonts-Call; Gewicht
  via `FontVariation('wght', …)`), enges Basis-Kerning mit extra-engem **Y-T**,
  optionalem Produktwort in 400 (un-verengt) und **grünem Glow-Punkt**. Kerning
  ist pro Glyph als trailing `letterSpacing` (em×fontSize) kodiert; das H trägt
  +0.04em als „margin-left" des Punkts. Glow nur auf dunklem Grund (hell:
  Buchstaben `#0A0A0B`, Punkt bleibt grün, kein Shadow). **Der Punkt nutzt das
  App-Grün `#1FD65F`** (bewusste Angleichung an `kGreen` statt Spec-`#22C55E`,
  Eigentümer-Entscheidung 2026-07), damit App, Launcher-Icon und Marke ein Grün
  teilen. Eingesetzt in den zwei **Marken-Credits** (Lock-Screen, Footer-Link);
  Legal-/Copyright-Prosa bleibt bewusst Fließtext. OFL-Lizenz wird lazy über
  `LicenseRegistry` (in `main()`) auf der Lizenzseite ausgewiesen.

## 8. Tests & CI

- **Seams / Fakes:** `FakeSshRunner` (skriptet Antworten pro exaktem Befehl,
  synthetisiert den Detection-Batch aus Einzel-Probes → per-Command-Tests
  überlebten die Batch-Umstellung), `FakeEvccUpdater` (überschreibt jede von der
  UI genutzte Methode — neue Methode = hier überschreiben, sonst
  `UnimplementedError`), `_FakeStore`, `_FakeEntitlement`, `_FakeKeepAlive`,
  `FakeSecureStorage`, `FakeHostKeyStore`.
- **Zwei Netze:** *innen* Command-Contract-Tests (exakte Befehlsstrings +
  Quote-Fuzzing mit `';reboot;'`), *außen* UI-Dispatch (echte `UpdaterPage`,
  Tab→Aktion→Fake asserted; `useTallScreen` weil das ListView off-screen nicht
  baut). Pins u.a.: Passwort nur als erste stdin-Zeile, nie im Befehl; evcc-Update
  sichert erst; Free-Nutzer erreichen den Pi nie.
- **CI** (`.github/workflows/build.yml`): ein Job — analyze → test → signieren →
  **fat APK** (arm64+armeabi-v7a) + AAB → **Signing-Material löschen, bevor**
  Dritt-Actions laufen → APK-Artefakt + auf `v*`-Tag GitHub-Release. Actions
  SHA-gepinnt, Secret nur im Signing-Step, Tag ohne Keystore = harter Fehler.
- **Release-Notes:** Der Schritt „Compose release notes" liest den **fastlane-
  Changelog** des aktuellen versionCode (`fastlane/…/{de-DE,en-US}/changelogs/
  <code>.txt`, `<code>` = `+NN` aus der pubspec-Version) in `RELEASE_NOTES.md`
  und übergibt ihn als `body_path`. So **listet jedes Release die konkreten
  Änderungen** (kuratierter Changelog zuerst, darunter die auto-generierte
  Commit-Liste). ⇒ Den fastlane-Changelog pro Release **immer** pflegen.

## 9. Verteilung & Recht

- `fastlane/metadata/**` — **einzige** Textquelle für Store-Listing (Titel ohne
  „evcc"/„Pi-hole" → Markenrecht). IzzyOnDroid zieht sie automatisch + das
  signierte APK aus den Releases (HRB-unabhängig).
- `store/**` — Play-Playbook (Data-Safety = „keine Daten", Foreground-Service-
  Deklaration Pflicht), `launch-kit.md`, `izzyondroid-rfp.md`.
- `docs/**` — GitHub-Pages: Landing + `privacy.html` + `impressum.html` (URLs im
  Play-Listing verankert — nicht umbenennen; kein Google-Fonts/Tracking).
  Ausgeliefert unter der **Custom Domain `pi-tool.kyth.systems`** (`docs/CNAME`,
  DNS-CNAME in Cloudflare auf `profex1337.github.io`, **DNS-only** — proxied
  kann GitHub kein Zertifikat ausstellen). Die Domain gehört KYTH und ist damit
  unabhängig von Repo-Owner und -Name: Pages wird bei Transfer/Rename **nicht**
  weitergeleitet, die Rechts-URLs sind aber in Play hinterlegt und in jedem
  ausgelieferten Build verdrahtet (`main.dart` `kPrivacyUrl`/`kImpressumUrl`/
  `kAgbUrl`). Beim Org-Transfer muss das Cloudflare-Target auf
  `kyth-systems.github.io` wechseln; die alte `profex1337.github.io`-Adresse
  wird nur bis dahin von Pages per 301 weitergeleitet (Alt-Installationen!).
- **HRB eingetragen** (2026: Amtsgericht Nürnberg, HRB 46313) — die UG ist keine
  „i.G." mehr, die Haftungsbeschränkung greift. Der Launch-Blocker „Haftung"
  ist damit weg; Impressum/Datenschutz führen HRB + Registergericht.

## Ein neuen Dienst hinzufügen (Kurzrezept)

1. `lib/src/services/<name>.dart`: Befehlsstrings + reine Parser + (falls nötig)
   Root-Skripte mit Markern; jede Interpolation via `shSingleQuote`, Heredocs
   quoted. **Test zuerst** (`test/<name>_test.dart`).
2. Detection-Probe in den Batch in `detectServices` (evcc_updater.dart) + Karte
   bauen; Orchestrierungs-Methoden über `_runRootScriptExpectMarker`.
3. `FakeEvccUpdater` um die neuen Methoden erweitern; UI-Dispatch-Test.
4. UI: Karte im `_serviceCards`-Switch bzw. `_AddableService`-Picker; Pro-Features
   über `_proGate`.
5. Version bumpen, `whats_new.dart` ergänzen, **diese Doku aktualisieren**,
   analyze+test grün, main-Build, taggen.
