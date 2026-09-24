# Pi-Tool — Architektur

> Referenz-Doku der App. **Bei architektur-relevanten Änderungen mitpflegen**
> (siehe `CLAUDE.md`). Stand: v0.70.x.

Pi-Tool ist eine Flutter-**Android**-App, die einen Raspberry Pi (oder jedes
Debian/Linux-Gerät) **per SSH** verwaltet: Dienste erkennen, installieren,
aktualisieren, sichern/wiederherstellen, überwachen, konfigurieren — und
Fernzugriff einrichten. Verteilung über **Google Play** (Produktions-Spur, Upload
durch die CI) und als signiertes APK über GitHub Releases (Sideload).
**Kein F-Droid/IzzyOnDroid** — IzzyOnDroid hat 2026-07-12 unter seiner KI-Policy
abgelehnt (`store/launch-kit.md` §7). Interner Dart-Paketname: `evcc_updater`,
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
  - **Exit-Code** (v0.70.0): dartssh2 schließt stdout schon bei CHANNEL_EOF;
    `exit-status` kann danach kommen. `run()` wartet deshalb nach dem Drain
    bis zu 3 s per `session.waitForExit`. `exitCode == null` heißt danach
    verlässlich: Verbindung weg oder Prozess per Signal beendet — und das ist
    in den Vordergrund-Seams **nie** Erfolg (§2).
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
- **Redaction**: `_withConnection` wickelt jedes `onLog` in `redactPassword` —
  **dieselbe Stelle** filtert auch das apt/dpkg-Fortschrittsgemalte
  (`stripProgressNoise`, siehe §3). Eine Naht für alle Aktionen; Parser sehen
  weiterhin die rohe Ausgabe.
- **Passwort nur, wenn sudo danach fragt** (v0.64.1): `sudo -S` frisst die erste
  stdin-Zeile als Passwort — **aber nur, wenn es fragt**. Bei NOPASSWD-sudo (oder
  noch gültigem Timestamp) fragt es nicht, die Zeile fällt durch zu `bash -s` und
  das Passwort wird als Befehl ausgeführt (`bash: line 1: ****: command not
  found` — real gesehen am 2026-07-31). Deshalb einmal pro Verbindung
  `sudoNoPasswordProbe` (`sudo -n true`), Ergebnis für die Verbindung gecacht,
  und die stdin baut `buildRootStdin`. **Fail-safe:** Probe nicht erfolgreich ⇒
  Passwort wird mitgeschickt. Betrifft die Skript-Pfade (`bash -s`); bei
  einfachen Befehlen verwirft der Befehl die Zeile ohnehin. **Pi-Jobs** brauchen
  die Probe nicht: ihr Bootstrap verwirft alles vor einer Sentinel-Zeile (s. u.).
- **Pi-Jobs** (v0.70.0, `pi_job.dart`, Protokoll in §5): paketverändernde
  **Updates** laufen nicht mehr im Vordergrund des SSH-Kanals, sondern als
  Hintergrund-Job auf dem Pi — System-Update, evcc-apt-Update (echter Lauf,
  nicht der Probelauf), Einzelpaket-Update, Paketreparatur, `pihole -up`.
  Anlass: ein Buster-Pi-3 bootete nach einem In-App-Systemupdate nicht mehr —
  der eigene 10-min-Inaktivitäts-Timeout hatte den Kanal während des stillen
  Kernel-Entpackens geschlossen, dpkg starb zwischen preinst (verschiebt
  Kernel/DTBs aus `/boot`) und postinst. Seam: `_runJob` → `_driveJob` →
  `classifyJobRun` → `evaluateJob`. Invarianten:
  - **Erfolg nur mit Beweis:** Zeile `PITOOL_JOB_RC <eigene id> <n>` plus die
    Marker der Job-Art (`evaluateJob`, dieselbe Auswertung beim späteren
    Mitlesen). Exit 0 ohne RC, fremde id, leere/kaputte rc → nie Erfolg.
  - **Abriss ≠ Abbruch:** nach `PITOOL_JOB_STARTED` wird jede Transportstörung
    (Timeout, SSH-Fehler, Watchdog: 60 s ohne Ausgabe inkl. Heartbeat, auch
    ein hängendes `execute`) zu `JobException(jobDetached)`; `_withConnection`
    reicht `JobException` und alles nach einem Job-Befehl (`_jobTouched`, pro
    Runner) **vor** dem Cancel-/Timeout-/SSH-Mapping durch. Nie „Abgebrochen."
    für einen Job, der weiterläuft.
  - **Bootstrap mit Sentinel** (`jobBootstrap`): `sudo -S bash -c '<liest bis
    #PITOOL-BEGIN>' pitool pitool-job-start '<id>'`. Eine Passwortzeile, die
    sudo nicht wollte, landet in einer Variablen und wird verworfen — nie
    ausgeführt. Die id steht in argv (kein Geheimnis; der Demo-Runner braucht
    sie), das Passwort nur auf stdin, nie in Payload/Log/Dateien.
  - **Abgeschnitten = nichts:** Launcher, Follower und Payload sind Funktionen,
    die erst die letzte Zeile aufruft — ein abgerissener Transfer ist ein
    Syntaxfehler. Payload base64 + Bytelänge im Launcher.
  - **Nicht-interaktiv:** Wrapper exportiert `DEBIAN_FRONTEND=noninteractive`,
    `UCF_FORCE_CONFFOLD=1`, `APT_LISTCHANGES_FRONTEND=none`,
    `NEEDRESTART_MODE=l`; apt mit `--force-confdef --force-confold`,
    `Use-Pty=0`, `Lock::Timeout`; vorher die Reparaturkette
    (`dpkg --configure -a`, `apt-get -f install`, `--configure -a`) und ein
    eigenes Warten auf die apt-Locks (Buster-apt ignoriert Lock::Timeout).
    `apt-get update` bleibt tolerant, wird aber gemeldet
    (`PITOOL_APT_UPDATE_RC` → `listsIncomplete`).
  - **Payloads enthalten keine Geheimnisse** (Tier 1 erfüllt das; Tests prüfen
    es). Installs, Uninstall, Docker/HA, Restores bleiben bewusst im
    Vordergrund — für sie gilt die Null-Exit-Regel unten.
- **Null-Exit = kein Erfolg** (v0.70.0): `_sudoCommand` (mit `checkExit`),
  `_runRootScript`, `install()` und die übrigen verändernden Einzelbefehle
  werten `exitCode == null` als „Verbindung während der Aktion abgerissen –
  Ergebnis unbekannt". Ausnahmen: Reboot/Shutdown (Abriss = erwartet) und
  lesende Probes. Die sudo-Probe wirft bei `null`, statt „Passwort nötig" zu
  raten.
- **Reboot/Shutdown-Sperre** (`jobPowerGuard`, v0.70.0): `rebootCommand`/
  `shutdownCommand` sind `sudo -S sh -c '<guard>; exec reboot|poweroff'`. Der
  Guard lehnt ab (Exit 75, Marker `PITOOL_REFUSED_JOB_RUNNING` bzw.
  `PITOOL_REFUSED_BOOT_INCOMPLETE`), solange der Job-Lock gehalten wird oder
  `rpikernelhack`-Diversionen existieren (Buster/Bullseye-Kernel halb
  konfiguriert → `/boot` leer). Fehlt die Lock-Datei (nie ein Job), ist der
  Neustart erlaubt.
- **Abgebrochener dpkg-Lauf** (`isDpkgInterrupted`): danach verweigert apt
  **jede** Installation auf diesem Pi. Der Fehler nennt Ursache und Ausweg statt
  nur „Exit 100"; `repairPackageState` (System-Karte ⋮ → „Paketzustand
  reparieren") führt `dpkg --configure -a` aus.
- **apt-Fehlerursachen** (`_aptFailureCause`, v0.67.1): `_sudoCommand`,
  `_runRootScriptExpectMarker` und `install()` hängen bei einem Fehlschlag die
  Ursache in Klartext an statt nur „Details im Log" — abgebrochener dpkg-Lauf,
  **tote Paketquelle** (`parseDeadAptSource`: „… Release' no longer has / does
  not have a Release file", nennt URL + Suite) und **gehaltene apt-Sperre**
  (`isAptLocked`, z. B. unattended-upgrades nach dem Boot → „in ein paar
  Minuten erneut"). Parser in `eol_sources.dart`.
- **EOL-Paketquellen zuerst umstellen** (`_fixEolSources`, v0.67.1): **jede**
  Aktion, die Pakete installiert oder aktualisiert (evcc-Update außer Probelauf,
  evcc-Install, Tailscale, Grafana/InfluxDB/Mosquitto, Paketlisten,
  System-Upgrade, Einzelpaket-Update, Sicherheits-Fixes fail2ban/Auto-Updates),
  führt vorher `eolSourcesFixScript` als root aus (`eolSourcesShellCommand` =
  `installShellCommand` + ignoriertes Argument, damit Logs/Tests den Schritt
  unterscheiden). Anlass: Raspbian Buster liegt seit 2025 nur noch auf
  `legacy.raspbian.org`, Debian Buster/Stretch auf `archive.debian.org`; die
  alten URLs liefern 404 und **eine** tote Quelle lässt jedes `apt-get update`
  mit Exit 100 scheitern (Tailscale-Install auf einem Buster-Pi, 2026-09-23).
  Tolerant: scheitert die Umstellung, läuft die Aktion trotzdem und apt nennt
  die Quelle (s. o.); nur ein abgelehntes sudo-Passwort bricht ab. Probelauf
  und Sicherheits-Check (nur lesend) ändern nichts. Pi Connect bewusst ohne
  (erst ab Bookworm).
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
  **Nach einem Job-Start heißt Cancel nur „nicht mehr mitlesen"**: der Job
  läuft weiter, Ergebnis `jobDetached` (Grund `userStopped`), nie `cancelled`.
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
- **Detection-Batch**: `buildDetectBatch`/`splitDetectSections` bündeln ~14
  Probes in **eine** SSH-Runde (`@@PT@@key@@PT@@`-Marker, `{ cmd ; } 2>&1 || true`
  isoliert einzelne Fehlschläge). Ausgeführt via `detectShellCommand`
  (`LC_ALL=C bash -s`).
- **Docker**: `parseEvccDocker` bevorzugt Image-Match, Name-Fallback nur
  *exakt* `evcc` (sonst würde `evcc-db` fälschlich gewählt). `buildDockerRunCommand`
  rekonstruiert `docker run` aus `docker inspect` mit Whitelist bei Restart-Policy
  und erhält devices/caps/privileged (USB/RS485-Zähler!). `dockerRunRecreateScript`:
  `pull` zuerst → altes Container zu `<name>-evccpitool-old` **umbenennen**
  (Rollback, nie `-v` löschen) → neu starten → nach dem Warten muss
  `{{.State.Status}}|{{.RestartCount}}` exakt **`running|0`** sein, sonst
  zurückrollen. (`.State.Running` bleibt `true`, solange ein Container mit
  `always`/`unless-stopped`/`on-failure` in seiner Neustart-Schleife hängt — bis
  v0.68.x griff der Rollback dort nie.) Die Dart-seitige Nachprüfung nach
  Install/Update nutzt `dockerListRunningCommand` (`--filter status=running`),
  die Erkennung weiter das ungefilterte `docker ps`, damit ein Crash-Loop-evcc
  sichtbar bleibt. Der geparkte Container bekommt **`--restart=no`** (v0.69.0;
  vorher kam er mit `always` nach jedem Neustart wieder hoch — und eine gerade
  deinstallierte Karte mit ihm); die ursprüngliche Policy wird vorab per
  `docker inspect` gelesen und beim Rollback zurückgesetzt.
- **apt ohne Pty** (v0.65.1): `Dpkg::Use-Pty` steht per Default auf true, auch
  wenn kein Terminal hängt (Debian #860931) — dpkg malt dann pro Paket ~20×
  „(Reading database … N%". Deshalb trägt **jeder** apt-Aufruf, der dpkg
  startet, `aptNoPty` (`-o Dpkg::Use-Pty=0`); `apt-get update` und `--dry-run`
  brauchen es nicht. Fremde Installer (Pi-hole, evcc-`setup.deb.sh`) bekommen
  den Schalter nicht — deren Rest fängt **`stripProgressNoise`** im Log-Seam ab:
  `\r` → Zeilenumbruch, reine Fortschrittszeilen raus (locale-unabhängig, also
  auch „(Lese Datenbank …"), Zusammenfassungen bleiben. Guard-Tests in
  `commands_test.dart`/`apt_services_test.dart` verhindern Rückfall.
- **`eol_sources.dart`** (v0.67.1) — `eolSourcesFixScript` (bash): stellt
  Zeilen in `/etc/apt/sources.list` + `sources.list.d/*.list` um, deren Quelle
  ein offizieller Raspbian-/Debian-Server ist, deren Suite zu jessie/stretch/
  buster gehört, deren alte URL **nachweislich** keine Release-Datei mehr
  liefert **und** deren Archiv-Ziel sie liefert (`curl`, sonst `wget`; ohne
  Netz wird nichts angefasst). Gibt es die Suite auch im Archiv nicht mehr
  (`stretch-updates`), wird die Zeile auskommentiert. Optionen (`[signed-by=…]`)
  bleiben, Kommentarzeilen und Drittquellen unberührt, idempotent. Sicherung
  nach `/var/backups/pi-tool/apt-sources/` (nicht nach `sources.list.d/`, apt
  würde über die Zusatzdatei meckern), Schreiben atomar per `mv`. Liest die
  Dateien, nie stdin (läuft über `bash -s`), kein Heredoc, endet mit `|| true`.
  Archive geprüft 2026-09-23: gleiche Signaturschlüssel, kein `Valid-Until`.
  Verhaltenstest in `eol_sources_test.dart` führt das echte Skript in bash mit
  `curl`-Stub aus (CI/Linux; unter Windows übersprungen — `bash` kann dort der
  WSL-Starter sein).
- **`parseInstalledVersion`** liefert Version nur bei dpkg-Status exakt
  `installed` (ein `rc`-Zustand trägt noch eine Version → sonst falscher Update-
  Vorschlag). `isAlreadyNewest` nutzt Negative-Lookbehind (`10 upgraded` matcht
  nicht `0 upgraded`), `kept back` ⇒ nicht „aktuell".

## 4. Service-Katalog (`services/*.dart`)

Flutter-freier Dienst-Katalog (siehe `design/2026-06-30-multi-service.md`). Pro
Dienst nur: Befehlsstrings, Root-Skripte, reine Parser. Orchestrierung
(Verbindung, Passwort-Piping, Marker) liegt bewusst in `evcc_updater.dart`.

- **`pi_service.dart`** — `ServiceStatus` (Modell; `routes` = Subnet-Router-
  Zustand, nur Tailscale, übersteht die Cache-Runde). `updateAvailable` ist nur bei
  `updateKnown == true` aussagekräftig (Tri-State: Docker-evcc / nicht-gepinnte
  HA-Tags zeigen „Aktualisieren" statt falsch „Aktuell"). Reconciler
  `applyLatestEvccVersion` (nur apt-evcc, gegen stalen lokalen apt-Index) /
  `applyLatestHomeAssistantVersion` (nur calver-vs-calver). **Beide setzen bei
  jedem GELUNGENEN Vergleich `updateKnown=true`** — auch bei „du bist aktuell";
  genau das rettet das „Aktuell ✓", wenn der apt-Index zu alt ist (unten).
  `compatible=false` → Karte ausgegraut mit Grund (z.B. Pi Connect < Bookworm).
- **Frische des apt-Index ist eine Sicherheits-Invariante** (`system_service.dart`,
  v0.63.7): `systemPendingCommand` simuliert gegen den **lokalen** Index und
  frischt ihn nie auf — auf einem Standard-Pi läuft `apt-daily` ohne
  `APT::Periodic::Update-Package-Lists "1"` ins Leere, der Index wird also
  wochenalt. Deshalb misst die Probe `APTAGE` (`systemAptAgeCommand`) das Alter
  **auf dem Pi** (`expr $(date +%s) - $(stat -c %Y /var/lib/apt/lists)` — gegen
  die Handy-Uhr zu rechnen bräche bei Zeitversatz), und `aptKnown` gilt nur mit
  `isAptIndexFresh` (< `kAptIndexMaxAge`, 3 Tage). Alter unbekannt ⇒ **nicht**
  frisch (Fail-safe). Ohne das meldete die System-Karte ein grünes „aktuell"
  über einem Pi mit 27 offenen Updates inkl. Sicherheitsfixes. Gegenmittel für
  Nutzer: `refreshAptIndex` (⋮ → „Paketlisten aktualisieren").
- **`stack_wiring.dart`** (v0.66.0) — verdrahtet den Monitoring-Stack in
  **einem** Root-Skript (Marker `WIRE_OK`): InfluxDB-Setup (Org `pi-tool`,
  Bucket `evcc`; Admin-Passwort wird AUF dem Pi generiert), Token via
  `influx auth create --json`, `influx:`-Block in `evcc.yaml` (nur wenn keiner
  existiert; Backup + automatischer Rückbau, falls evcc den Restart verweigert),
  Grafana-Provisioning (Flux-Datasource `pitool-influx` + Dashboard
  `grafanaEvccDashboardJson`, gequotetes Heredoc). **Invariante: das Token
  verlässt den Pi nie** — deshalb ein Skript statt mehrerer Runden; nichts
  App-seitiges wird interpoliert. Fehlendes Grafana/`evcc.yaml` (Docker-evcc)
  = Skip mit Meldung; handeingerichtetes InfluxDB ohne Root-CLI-Config =
  ehrlicher Fehler. Einstieg: Grafana-Karte ⋮ → „Mit evcc verdrahten".
  `EvccUpdater.wireMonitoringStack` orchestriert. **E2E-validiert am
  2026-08-15 auf dem Test-Pi (Debian 13/trixie, evcc 0.313.3):** Installs +
  Wiring liefen im ersten Anlauf (`WIRE_OK`), evcc schreibt real in den
  Bucket, alle fünf Panel-Measurements (gridPower/pvPower/homePower/
  chargePower/batterySoc) existieren in evccs echtem Schema, Grafana 13
  lädt das Provisioning fehlerfrei. Das Token tauchte in keiner Ausgabe auf.
  **Ehrlichkeits-Invariante (v0.66.2, aus dem Audit):** Das Skript läuft
  bewusst OHNE `set -e`, deshalb endet jede Schreib-/Restart-Stelle explizit
  (`WIRE_FAIL; exit 1`). Am Ende entscheiden `evcc_wired`/`grafana_wired`
  zwischen **`WIRE_OK`** (beide Hälften) und **`WIRE_PARTIAL`** (eine bewusst
  übersprungen — Docker-evcc ohne `/etc/evcc.yaml`, kein Grafana).
  `wireMonitoringStack` gibt entsprechend `StackWiringOutcome.wired|partial`
  zurück, die UI meldet Teilerfolg **amber statt grün** — sonst stünde ein
  grünes „verdrahtet" über einem dauerhaft leeren Dashboard. Ebenfalls dort:
  Docker-evcc wird an `systemctl cat evcc` erkannt (früher als „Konfiguration
  abgelehnt" fehlgedeutet), ohne gelungenes Backup wird die `evcc.yaml` gar
  nicht angefasst, und nach dem Restart wird 5 s gewartet, weil
  `Restart=always` einen Absturz sonst als „active" maskiert.
- **Umzugshelfer** (v0.66.0, `_migrateToOtherPi` in main.dart — reine
  Orchestrierung vorhandener Bausteine, kein neues Skript): frische Backups
  auf dem Quell-Pi (`backup` + `backupPihole`) → `downloadFile` aufs Handy →
  auf dem Ziel-Profil `detectServices`, fehlendes installieren (`install`/
  `installPihole`) → `uploadFile` an die erwarteten Backup-Pfade →
  `restoreBackup`/`restorePiholeBackup`. Quell-Pi bleibt unangetastet; nur
  apt-evcc zieht um (Docker-evcc hat hier keinen Restore-Pfad). System-Karte ⋮,
  Pro-gated. Braucht ein zweites Profil mit Host.
- **Live-Werte auf der evcc-Karte** (v0.67.0, GitHub-Issue #22) — `evccCardLines`
  (`evcc_api.dart`) formatiert aus `EvccState` maximal **zwei** Zeilen: Site
  (PV/Netz/Haus) und Batterie/Ladepunkt; **leer, wenn nichts messbar ist** —
  die Karte darf keine leere Zeile bekommen. Der interessante Ladepunkt ist der
  ladende, sonst der erste verbundene. Gefüllt wird über `_refreshEvccLive` im
  Anschluss an eine erfolgreiche Erkennung: lokales HTTP, **fail-soft und
  stumm** (anderer Port/Login/offline ⇒ `_evccLive = null`, Karte wie zuvor,
  kein Fehlerbanner über einer sonst gelungenen Erkennung). Widget-Tests dürfen
  deshalb **nie** den echten `EvccApiClient` verwenden — `page()` in
  `dispatch_test.dart` injiziert einen sofort scheiternden Fake, sonst macht
  jeder Test echtes Netz-I/O.
- **`service_links.dart`** (v0.65.2) — statische Tabelle „wo lebt das Projekt":
  Website je Karten-id und, **nur wo es sie wirklich gibt**, die offizielle App
  (Package + Play-Eintrag: evcc, Home Assistant, Tailscale). Speist die zwei
  ⋮-Einträge „Projekt-Website"/„Offizielle App" (`_projectLinkActions`); die App
  wird über `AppLauncher` geöffnet, Play nur als Fallback. Bewusst Tabelle statt
  Erkennung — der Dienst-Katalog ist endlich, nichts kann pro Pi driften. Kein
  Drittanbieter-App-Link (sonst wäre „offiziell" gelogen); die System-Karte hat
  keinen Eintrag (der Pi ist keine Anwendung). Guard-Test:
  `test/service_links_test.dart` (jede Karten-id braucht einen Eintrag).
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
  **Install + Web-Passwort (v0.69.0):** Die App belegt `setupVars.conf` vor,
  damit der offizielle Installer ohne TTY läuft — das zählt dort als
  *Aktualisierung* (`check_fresh_install`), und `pihole setpassword` läuft nur
  bei Frischinstallationen. Pi-hole v6 verlangt ohne Passwort **keine
  Anmeldung** (Doku api/auth) → bis v0.68.x installierte die App eine für das
  ganze Heimnetz offene Weboberfläche/API. Seitdem setzt das Install-Skript ein
  von der App erzeugtes Passwort (`generateWebPassword`, 16 Zeichen, lesbares
  Alphabet), **nur wenn** `pihole-FTL --config -q webserver.api.pwhash` gelingt
  und leer ist (unlesbar = Finger weg, nie ein vorhandenes überschreiben), und
  meldet `PIHOLE_PW_SET`. Das Passwort reist nur im Skript über stdin, nie durch
  Log, Verlauf oder Profil; `_showPiholePassword` zeigt es einmalig (nicht per
  Danebentippen schließbar). Die Vorbelegung unterbleibt, wenn schon eine
  `pihole.toml` existiert (sonst migriert FTL aus der frischen `setupVars.conf`
  und überschreibt sie). Im Umzugshelfer wird das Passwort nicht angezeigt — der
  folgende Teleporter-Restore bringt die Einstellungen der Quelle mit.
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
- **Karten-Regel „der Knopf zeigt, was als Nächstes dran ist"** (v0.64.2): Steht
  ein Update an, ist `actionUpdate` der **Primär-Knopf** — auch auf Pi Connect
  und Tailscale, deren Primär sonst am Anmelde-/Verbindungszustand hängt. Die
  verdrängte Aktion wandert ins ⋮ und kommt danach zurück. Vorher lag das Update
  dort nur als `_CardAction`, sichtbar allein an der ambernen LED — zu leise
  (real übersehen: Pi Connect 2.12.1 → 2.12.2 hinter „Web öffnen").
- **`tailscale.dart`** — VPN/Mesh, **System-Service** (einfacher als Pi Connect).
  Install = offizieller Installer (`curl … | sh`) unter **`set -o pipefail`**
  (sonst zählt nur der Exit von `sh`: fehlendes curl/abgebrochener Download =
  leeres Skript, Exit 0, Marker = Phantom-Erfolg); der Marker folgt erst nach
  `command -v tailscale`. Tote EOL-Quellen stellt vorher `_fixEolSources` um.
  `up` detached (Login-URL). „up" = hat 100.x-Tailnet-IP. down/logout via sudo.
  `remoteAccessCandidates` ordnet die Verbindungsversuche: Heim-Adresse zuerst
  (schnell, ohne VPN), es sei denn das Tailnet hat zuletzt geantwortet; ein
  `lastGood`, das zu keiner der beiden bekannten Adressen passt, ist veraltet
  (Pi hat eine neue LAN-IP) und wird ignoriert. **Unter zwei bekannten Adressen
  wird gar nicht sondiert** — ein Pi ohne Fernzugriff darf keine Latenz für ein
  Feature zahlen, das er nicht nutzt.
  **Heimnetz freigeben (Subnet Router, v0.68.0)** — Opt-in über das ⋮ der Karte
  bzw. als optionaler Schritt nach dem **ersten** Fernzugriff-Beweis
  (`_offerLanShare`). Zustand kommt aus drei No-sudo-Proben im Detection-Batch
  (`TS_LAN` = `ip -4 route show`, `TS_PREFS` = `tailscale debug prefs` →
  `AdvertiseRoutes`, `TS_SELF` = `tailscale status --json --peers=false` →
  `Self.AllowedIPs` minus eigene Adressen/Exit-Routen = **freigegeben**, dieselbe
  Regel wie tailscaleds approved-routes-Metrik) → `SubnetRoutes`/`RouteShare`
  (`unavailable/off/pending/active`) auf `ServiceStatus.routes`, nur bei `up`.
  Heimnetz = `scope link`-Routen der Default-Route-Schnittstelle(n), nur RFC 1918
  (`parseLanSubnets`/`isPrivateIpv4Prefix`). Änderung = Root-Skript
  `buildTailscaleAdvertiseScript` mit Marker: eigene sysctl-Datei
  **`/etc/sysctl.d/99-pi-tool-tailscale.conf`** (nur `net.ipv4.ip_forward`; IPv6-
  Weiterleitung bewusst nicht — unnötig für IPv4-Routen, kappt sonst RA-basierte
  Adressen), dann **`tailscale set --advertise-routes`** (nie `up`: verlangt alle
  Nicht-Default-Flags). Vor jeder Änderung frisch gelesen, **zusammengeführt**
  statt überschrieben (`routesWithLan`/`routesWithoutLan` — von Hand gesetzte
  Routen bleiben, auch IPv6/öffentliche: nur die App-eigenen müssen RFC 1918
  sein, der Rest nur präfixförmig). Die sysctl-Datei trägt als Merker
  `# routes=…` die **von der App gesetzten** Routen (`parseAppRoutes`, Probe
  `TS_FWD`) — so bleibt eine alte Route nach einem Netzwechsel (neuer Router)
  als „unsere" sichtbar und beendbar (`SubnetRoutes.mine`, `sharedLan` =
  angeboten ∩ (Heimnetz ∪ mine); „freigeben" erscheint, solange das AKTUELLE
  Heimnetz fehlt). „Beenden" löscht die Datei erst ohne Restroute **und** ohne
  Exit-Node (der braucht die Weiterleitung auch) und lässt den Laufzeitwert
  stehen (Docker braucht ihn); `tailscale logout` nimmt sie gleich mit (Logout
  setzt die Prefs samt Routen zurück). Demo-Aktionen merken sich keine
  Adressen (`_rememberLanHost`/`_rememberTailscaleIp` brechen im Demo ab). Die Bestätigung in der
  Tailscale-Konsole kann die App nicht leisten (kein API-Key) — fehlt sie, erklärt
  `_reportLanShare` den Schritt als Popup mit Direktlink (`kTailscaleMachinesUrl`).
  **Folge für `up`:** Ein Knoten in `NeedsLogin` (Schlüssel abgelaufen) mit
  gesetzter Route verweigert ein nacktes `tailscale up` („requires mentioning all
  non-default flags") und nennt den erwarteten Befehl. `tailscaleUp` wiederholt
  dann mit genau diesen Flags (`parseTailscaleUpRestateFlags`, nur schlichte
  `--flag[=wert]`-Tokens inkl. `_`, einzeln `shSingleQuote`t) — sonst liefe „Verbinden"
  nach Monaten ins Leere. Nach `tailscale logout` sind die Routen weg (Tailscale
  löscht das Profil); die Karte bietet dann wieder „freigeben" an.
- **Fernzugriff-Karte (v0.64.0, `main.dart`)** — verkettet Installation, `up`
  und Browser-Login und **misst danach den Erfolg**, statt ihn zu behaupten:
  `EvccUpdater.probeConnection` verbindet sich vom **Handy** aus auf die
  Tailnet-IP. Ohne diesen Beweis hält sich der Nutzer für fertig und merkt es
  erst unterwegs. Der Beweis wird als `Profile.remoteAccessProven` persistiert,
  damit die Karte endgültig verschwindet statt zum Dauer-Hinweis zu werden.
  Zwei Phasen = zwei Handler, weil zwischen Login und Prüfung auf eine Handlung
  **außerhalb** der App gewartet wird; ein modaler Wizard müsste dafür `_busy`
  halten oder loslassen — beides bricht das Handler-Pflichtmuster.
  **Invariante:** `probeConnection` liefert `false` für die gewöhnlichen
  Fehlschläge, reicht aber `UpdateErrorKind.hostKeyChanged` **durch** — ein
  gewechselter Host-Key darf nie zu „nicht erreichbar" verflacht werden.
  **Nicht-Ziel:** kein Portforwarding/DynDNS — offene SSH-Ports ins Internet
  sind genau das, was der Sicherheits-Check der App anprangert.
- **Deinstallieren (v0.69.0)** — ⋮ jeder Karte, deren Dienst die App selbst
  installieren kann: evcc (nur apt), Home Assistant (nur der App-Container
  `homeassistant`), Pi Connect, Tailscale, Grafana/InfluxDB/Mosquitto. Ein
  Einstieg `EvccUpdater.uninstallService(id, purge)` wählt den Builder
  (`buildEvccUninstallScript`, `buildHomeAssistantUninstallScript`,
  `buildPiConnectUninstallScript`, `buildTailscaleUninstallScript`,
  `buildAptServiceUninstallScript` mit `AptUninstallFootprint` je Dienst).
  Dialog `_askUninstall`: Häkchen **„Auch Konfiguration und Daten löschen"**,
  Standard AUS = Programm weg, Konfiguration/Daten bleiben, die bestehende
  Installation übernimmt sie wieder; AN = kompletter Rückbau inkl. eigener
  apt-Quelle/Keyring und der dienstspezifischen Pi-Tool-Sicherungen (nie
  „vollständig" versprechen: Config-Editor-Backups fremder Basenames bleiben).
  **Skript-Vertrag:** läuft über `installShellCommand` (Skript auf **stdin**:
  nie `exec </dev/null`, jedes apt/dpkg/interaktive Kommando bekommt sein
  eigenes `</dev/null`), `set -e`, `DPkg::Lock::Timeout=120`, **Guards zuerst**
  — unsicher oder unvollständig → genau eine Zeile `UNINSTALL_REFUSED: <Grund>`
  + Exit 3, vorher ist nichts verändert (`parseUninstallRefusal`; der Grund wird
  in `_runRootScriptExpectMarker` zur Meldung statt „Details im Log").
  Idempotent (Wiederholung nach Teillauf: `rc`/fehlend = erledigt), statusbasierte
  dpkg-Prüfungen, `apt-mark hold` und ein **gescheiterter** apt-Probelauf sind
  Ablehnungen (vorher verschluckt; bei Tailscale-Purge hätte das abgemeldet,
  bevor apt scheitert), nie `autoremove`, nie geteilte Pakete, nie Docker; Abschluss-
  prüfung vor dem Marker (`*_REMOVED_OK`, ohne `INSTALL_OK`-Teilstring). Wichtige
  Guards: apt-Simulation darf nichts Zusätzliches entfernen; evcc-Purge
  verweigert bei einem Docker-evcc, der die Daten einbindet; HA nur exakt der
  App-Container (kein Compose, `/config` = `/opt/homeassistant/config`, kein
  weiterer HA-Container); Tailscale verweigert, wenn die Sitzung über das Tailnet
  läuft — in Dart per `isTailnetHost(host)` und `isTailnetClient` auf dem
  **nicht-sudo** gelesenen `$SSH_CONNECTION` (sudo verschluckt es), im Skript
  als Rückfallnetz. InfluxDB-Purge entfernt nur den Pi-Tool-markierten
  influx-Block aus evcc.yaml (Sicherung `evcc.yaml.unwire-*`, Rollback wenn evcc
  danach nicht läuft). apt-Dienste: „Behalten" entfernt nur die Kartenpakete,
  Client-Tools (`mosquitto-clients`, `influxdb2-cli`) nimmt erst der Purge mit;
  Config-Editor-Sicherungen löscht der Purge nur für eindeutige Basenames
  (grafana.ini, grafana-server, influxdb2) mit exaktem Zeitstempel-Muster.
  Tailscale-Behalten lässt die Weiterleitungsdatei stehen (Prefs behalten das
  freigegebene Heimnetz); die Sitzungs-Ablehnung unterscheidet Tailnet-Host
  („Heimnetz-Adresse nutzen") und Route über die Heimnetz-Adresse
  (`tailscaleSessionRefusal`). Pi Connect startet vorher laufende User-Units neu,
  wenn apt scheitert. HA zählt nur das Core-Image als HA (`_haCoreImageRe`) —
  Begleiter wie der Matter-Server blockieren weder, noch halten sie die Karte.
  Am echten Pi belegt (2026-09-23, .125/Trixie): Tailscale Behalten → App-
  Neuinstallation (derselbe Knoten-Zustand) und Purge, ohne Beifang für
  Pi-hole/Docker/HA. Neue On-Pi-Dateien:
  `/var/lib/pi-tool/piconnect-linger` (Install merkt, wem die App Linger
  einschaltete — nur dort schaltet Purge es aus, und auch dann nicht, wenn andere
  User-Dienste des Users es brauchen), `/var/lib/pi-tool/evcc-purge.pending`
  (unterbrochener evcc-Purge). Nach Erfolg: feste Dienste werden
  `ServiceStatus.absent` (→ „Dienst hinzufügen"), apt-Dienste fliegen aus
  `_services`; Tailscale setzt `_tailscaleIp`/`_remoteAccessProven`/Tailnet-
  `_lastGoodHost` zurück; `_scheduleSave` nach der Neuerkennung, sonst brächte der
  Offline-Stand die Karte zurück. `_lastAction` öffnet den Dialog neu (Häkchen
  AUS) — ein Purge wird nie ungefragt wiederholt. **Nie im Demo-Modus** (das
  Demo-Backend liefert keinen Marker). Installationsskripte der apt-Dienste
  tragen seitdem `--force-confdef/--force-confold` + `</dev/null`, damit eine
  Neuinstallation nach „Behalten" nie an geänderten conffiles nachfragt.
  **Bewusst nicht:** Pi-hole — oft der DNS (und DHCP) des ganzen Netzes; ein
  Rückbau braucht erst eine Vorprüfung auf DHCP/Self-DNS/Tailnet-DNS. (Die
  frühere zweite Hürde — die Vorbelegung überschrieb bei einer Neuinstallation
  eine behaltene `pihole.toml` — ist seit v0.69.0 behoben.) Docker-evcc (kein Install-Pfad); die Docker-Engine;
  nur erkannte Dienste (AdGuard, Node-RED, Zigbee2MQTT); System-Karte.

## 5. On-Pi-Automatik (`auto_update.dart`, `alerts.dart`, `files.dart`, `notifications.dart`)

**Kern-Entscheidung:** Automatik läuft als **systemd-Timer auf dem Pi**, *kein*
Android-Hintergrunddienst (v0.20.0-Absturz-Lektion). Reine Builder → POSIX-Shell.

- **`auto_update.dart`** — geplante apt-Updates (`pi-tool-autoupdate.timer`).
  Wrapper: `DEBIAN_FRONTEND=noninteractive` + `--force-confold` (kein
  conffile-Hänger), sichert evcc vorher, stellt tote EOL-Quellen um
  (`eolSourcesFixScript` — bash, daher `#!/bin/bash` statt `#!/bin/sh`; greift
  erst bei neu eingerichtetem Timer), **self-heal** (startet evcc neu falls es
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
  fetchDockerLogs`; `_DockerSheet` (Liste + pro Container Neustart/Logs/
  **Aktualisieren** → nutzt `_LiveLogSheet`). System-Karten-Aktion; leer, wenn
  Docker fehlt. **Generisches Container-Update (v0.66.0):**
  `updateDockerContainer` fährt für JEDEN Container denselben Weg wie das
  evcc-Docker-Update — Compose-Label → `dockerComposeUpdateScript`, sonst
  Digest-Pin-Ablehnung + `dockerRunRecreateScript` (Rollback-Netz) — und prüft
  danach via `buildDockerRunningProbe` (`{{.State.Running}}`), dass wirklich
  etwas läuft. Eigene `-evccpitool-old`-Rollback-Container werden verweigert
  (und im Sheet-Menü gar nicht erst angeboten — dort fehlt seit v0.66.2 auch
  „Neu starten", das nur ein veraltetes Duplikat hochgefahren hätte). **Das
  Update läuft NICHT im Sheet:** das Sheet schließt sich und gibt den Namen
  zurück, die eigentliche Arbeit läuft in `_updateContainer` durch `_guard`
  (Running-Bar, Abbrechen, Keep-Alive) — ein Pull+Recreate dauert Minuten, und
  ohne Vordergrunddienst kann Android die App mitten im Recreate einfrieren
  (Audit 2026-08-15). `buildDockerRunCommand` überträgt seit v0.66.2 auch
  `User`, `Hostname` (nur wenn nicht die Container-ID), `ExtraHosts`,
  `Entrypoint` und `Cmd` — fehlten sie, lief der Container danach still mit
  anderem Kommando oder als root weiter, gemeldet als Erfolg.
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
- **`security_check.dart`** — Audit + One-Tap-Fixes. `buildSecurityProbe` = **ein**
  `sudo sh -c`-Probe (Skript via `shSingleQuote` sicher gequotet) mit Section-
  Markern (`__SEC_SSHD__/UNATT/F2B/PORTS/PIHOLE__`); `parseSecurityReport` macht
  daraus fünf Ampel-`SecurityFinding`s (SSH-Root-Login, Passwort-Login,
  Auto-Updates, fail2ban, offene Ports) plus **„Pi-hole-Weboberfläche"**, wenn
  Pi-hole da ist (v0.69.0: leerer `webserver.api.pwhash` = warn; ausgegeben wird
  nur das Urteil, nie der Hash). Deren Fix `SecurityFix.piholePassword` läuft
  über `buildPiholeSetPasswordScript` statt `buildSecurityFixScript` (braucht das
  erzeugte Passwort; ist inzwischen eins gesetzt, ändert er nichts). **Die Prüfung verändert nichts**; Unbekanntes
  degradiert zu `info` (nie falsches ok/warn). `EvccUpdater.runSecurityCheck`
  orchestriert; `_SecurityReportSheet` rendert (System-Karten-Aktion).
  **„Beheben" (v0.66.0):** `securityFixFor` mappt fixbare Befunde auf
  `SecurityFix` (fail2ban, autoUpdates, rootLogin); `buildSecurityFixScript`
  liefert das Root-Skript (Marker `SECFIX_OK`, apt mit `Dpkg::Use-Pty=0`).
  Invarianten: Passwort-Login-Abschalten wird NIE angeboten (ohne bewiesenen
  Key-Login = Aussperr-Risiko); der rootLogin-Fix läuft als **Drop-in** unter
  `sshd_config.d/`, `sshd -t` VOR dem Reload, Effekt via `sshd -T` verifiziert,
  bei Abweichung automatischer Rückbau — und `fixSecurity` verweigert ihn ganz,
  wenn die App selbst als root verbunden ist. Nach jedem Fix läuft der Check
  neu (Befund wird sichtbar grün statt nur Toast).
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

### Pi-Jobs — On-Pi-Protokoll (`pi_job.dart`, v0.70.0)

Ein Job ist kein Timer, sondern eine einmalige **transiente systemd-Unit**
(`pi-tool-job-<id>`; ohne systemd `setsid -f`). Dateien:

| Pfad | Inhalt |
|---|---|
| `/var/lib/pi-tool/jobs/` (0700 root) | Basis; `lock` = globaler Ausschluss-Lock |
| `…/jobs/<id>/` (0700) | `kind`, `payload.sh` → per Umbenennen beansprucht als `payload.run`, `run.sh` (konstanter Wrapper), `log` (0600), `started`, `alive` (Lebenszeichen-Lock), `rc` |
| `/var/lib/pi-tool/job.status` (0644) | eine Zeile `<id> <kind> <running\|done\|lost> <rc\|-> <start> <end\|-> <boot_id>`, ohne Log-Inhalt — die Erkennung liest sie ohne sudo |

- **Launcher** (`pitool-job-start <id>`): BUSY-Prüfung **vor** jedem Schreiben
  (laufender Auto-Update-Timer oder gehaltener Lock → `PITOOL_JOB_BUSY`), räumt
  auf die neuesten 10 Job-Verzeichnisse auf (nie ein lebendes), schreibt den
  Job, startet `systemd-run --unit=pi-tool-job-<id> -p KillMode=mixed
  -p TimeoutStopSec=30min -p IgnoreSIGPIPE=no -p RuntimeMaxSec=<6h|2h>`. Meldet
  systemd-run einen Fehler, obwohl PID 1 die Unit angelegt hat
  (`LoadState=loaded`), wird **nicht** zusätzlich per setsid gestartet. Wartet
  zählerbasiert (keine Uhr-Differenzen — Pi ohne RTC) auf `started`; kommt
  nichts, nimmt er die Payload per `mv` zurück: gelingt das, lief nichts
  (`PITOOL_JOB_NOSTART`), sonst hat der Wrapper sie schon und er wartet weiter.
  Dann `PITOOL_JOB_STARTED <id> <kind>` und direkt der Follower.
- **Wrapper** (`run.sh`, konstant): beansprucht die Payload, loggt nach `log`,
  nimmt den globalen Lock (`flock -w 5` — kurze Proben von Launcher/Guard sehen
  nicht wie ein laufender Job aus) und den Job-eigenen `alive`-Lock, setzt die
  feste Umgebung, schreibt `started` + job.status, fängt SIGTERM ab (lässt die
  Payload zu Ende laufen) und startet die Payload mit `umask 022` und **ohne**
  die Lock-fds (`8>&- 9>&-`): ein zurückgelassener Prozess hält keinen Lock.
  rc per tmp+rename (Fallback tmpfs), job.status atomar, Exit immer 0.
- **Follower** (`pitool-job-follow <id>`, auch direkt nach dem Start): streamt
  `log` ab Offset 0, Heartbeat `PITOOL_JOB_HB` alle ~15 s auf **stderr**,
  RC/LOST als letzte Zeile auf **stdout** (nie vor den letzten Log-Bytes).
  `alive`-Lock frei und kein rc → `PITOOL_JOB_LOST` und job.status `lost` (nur
  wenn die Zeile noch diesen Job meint). Stirbt der Kanal, stirbt nur der
  Follower (SIGPIPE) — nie der Job.
- **Erkennung:** Sektion `JOB` (`jobStatusProbe`, ohne sudo) → `PiJobStatus`
  am System-Eintrag (`ServiceStatus.job`, **transient**, nicht im Cache);
  `running` mit anderer boot_id = `interrupted` (Neustart mitten im Job).

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

**Pi-Jobs in der Oberfläche** (v0.70.0): Job-Aktionen reichen `onJobStarted`
durch → `_busyJob`; ab dann zeigt die Running-Bar **„Nicht mehr mitlesen"**
(neutral) statt des roten „Abbrechen" — Stoppen des Mitlesens stoppt nie den
Job. `_guard` fängt `JobException` **vor** `EvccUpdateException`: gelbes
Banner (`_statusWarn`, `_statusOk` bleibt `false`), lokalisierter Text je Grund
(`_jobExceptionText`), Eintrag in `_detachedJobs` (Schlüssel
`host:port:user`, nur im Speicher); `_connected=false` nur bei
`connectionLost`. Die **Job-Leiste** (`_jobBar`) zeigt `_jobToFollow`: ein laut
Erkennung laufender Job oder ein zurückgelassener — außer die Erkennung sah
genau diesen schon enden. „Mitlesen" = `_followJob` (Handler-Muster,
`followJob` → dieselbe Auswertung wie live → Status, History,
`_refreshServices`). Die System-Karte zeigt zustandslos den letzten Job aus
`job.status` (`_lastJobLine`: „beendet" ist bewusst keine Erfolgsbehauptung;
unterbrochen → Hinweis auf „Paketzustand reparieren"). Kein automatisches
Mitlesen beim Verbinden.

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
  `_openSetupGuide()` aus dem ⋮-Menü **und** als Link auf dem Verbindungs-Screen
  unter „Pi im WLAN suchen". Beide stehen dort nur, solange der Pi **unbekannt**
  ist (kein gemerktes `lanHost`/`tailscaleIp` = nie erfolgreich verbunden); bei
  einem bekannten Pi kommt nur die Suche zurück, wenn die letzte Verbindung
  scheiterte (`_connectionOk == false` — die Adresse kann sich geändert haben).
  Das ⋮-Menü behält die Suche immer. Vom Demo-Einstieg unabhängig.
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
- **Pi-Jobs:** `pi_job_test.dart` (Builder, `classifyJobRun`-Tabelle inkl.
  „Exit 0 ohne RC", fremde id, kaputte rc; `parseJobStatus`; `evaluateJob`),
  `pi_job_bash_test.dart` (**echtes bash, nur Linux/CI** — Git Bash hat weder
  flock noch setsid): Start→Mitlesen→RC, Launcher getötet → Job läuft zu Ende,
  BUSY, zurückgelassener Hintergrundprozess hält keinen Lock, LOST, abgeschnittener
  Launcher führt nichts aus, Passwortzeile wird nie ausgeführt, Rechte, umask der
  Payload, Neustart-Sperre. `FakeSshRunner`-Tests für jede Job-Aktion (Abriss/
  Cancel/Watchdog nach STARTED → `jobDetached`, nie „Abgebrochen."). E2E auf
  einem echten Pi: `dart run tool/pi_job_dump.dart <dir>` schreibt Launcher,
  Follower, Guard und eine harmlose Payload (echo/sleep) samt Befehlen.
- **l10n:** `l10n_keys_test.dart` erzwingt denselben Schlüsselsatz in
  `app_de.arb` und `app_en.arb`.
- **CI** (`.github/workflows/build.yml`): ein Job — analyze → test → (auf Tag:
  Store-Texte gegen die Play-Limits prüfen) → signieren → **fat APK**
  (arm64+armeabi-v7a) + AAB → **Signing-Material löschen, bevor** Dritt-Actions
  laufen → APK-Artefakt → auf `v*`-Tag GitHub-Release → **Play-Upload**. Actions
  SHA-gepinnt, Secrets nur im jeweiligen Step, Tag ohne Keystore = harter Fehler.
- **Play-Upload** (`fastlane/Fastfile`, Lane `play_release`): `supply` lädt auf
  `v*`-Tag den signierten AAB in die **Produktions-Spur mit Status `completed`
  (= 100 % Rollout, kein Draft)** und dazu die Texte aus `fastlane/metadata/**`
  (Titel, Kurz-/Langbeschreibung, Changelog des versionCode).
  **Bilder/Screenshots sind ausgeschlossen** (`skip_upload_images` +
  `skip_upload_screenshots`) — die bleiben Handarbeit in der Console und dürfen
  von einem automatischen Lauf nicht überschrieben/geleert werden. Der
  Service-Account-Key kommt als **rohes JSON** aus dem Secret
  `PLAY_SERVICE_ACCOUNT_JSON` in die Umgebung (`json_key_data`) und landet nie im
  Workspace; der Step läuft **nach** dem Keystore-Löschen und **nach** dem
  GitHub-Release (ein Google-Ausfall darf die Sideload-Nutzer nicht ihr APK
  kosten). Fehlt das Secret, bleibt es bei einer Warnung. Trockenlauf ohne
  Veröffentlichung: Workflow manuell mit `play_dry_run = true` starten (Lane
  `play_validate` → `validate_only`). Die **Einmal-Einrichtung** der Google-Seite
  (Dienstkonto, Berechtigungen, Secret) steht in `store/play-ci-publishing.md`.
- **Store-Text-Vorprüfung:** Weil ein Tag ungebremst an alle Nutzer geht, prüft
  die CI **vor** dem Bauen: Changelog `<versionCode>.txt` muss in **beiden**
  Sprachen existieren und die Play-Zeichenlimits müssen halten (Titel 30, Kurz
  80, Lang 4000, Changelog 500 — die Langbeschreibungen liegen bei ~3995, es ist
  also praktisch keine Luft mehr). Verletzung = roter Build, bevor irgendwas
  veröffentlicht ist.
- **Release-Notes:** Der Schritt „Compose release notes" liest den **fastlane-
  Changelog** des aktuellen versionCode (`fastlane/…/{de-DE,en-US}/changelogs/
  <code>.txt`, `<code>` = `+NN` aus der pubspec-Version) in `RELEASE_NOTES.md`
  und übergibt ihn als `body_path`. So **listet jedes Release die konkreten
  Änderungen** (kuratierter Changelog zuerst, darunter die auto-generierte
  Commit-Liste). ⇒ Den fastlane-Changelog pro Release **immer** pflegen.

## 9. Verteilung & Recht

- `fastlane/metadata/**` — **einzige** Textquelle für Store-Listing (Titel ohne
  „evcc"/„Pi-hole" → Markenrecht). **Play liest sie direkt:** die CI schiebt
  Titel/Beschreibungen/Changelog beim Release per `supply` ins Listing (§8) —
  eine Änderung hier ist nach dem nächsten Tag live, nicht nur Doku.
- `store/**` — Play-Playbook (Data-Safety = „keine Daten", Foreground-Service-
  Deklaration Pflicht), `launch-kit.md`; `izzyondroid-rfp.md` ist nur noch
  **Historie** (Kanal abgelehnt, siehe oben) — nicht als To-do lesen.
- `docs/**` — GitHub-Pages: Landing + `privacy.html` + `impressum.html` (URLs im
  Play-Listing verankert — nicht umbenennen; kein Google-Fonts/Tracking).
  Ausgeliefert unter der **Custom Domain `pi-tool.kyth.systems`** (`docs/CNAME`,
  DNS-CNAME in Cloudflare, **DNS-only** — proxied kann GitHub kein Zertifikat
  ausstellen). Die Domain gehört KYTH und ist damit unabhängig von Repo-Owner
  und -Name — genau deshalb hat der Org-Transfer (2026-07-31, siehe unten) die
  Rechts-URLs nicht angefasst: Pages wird bei Transfer/Rename **nicht**
  weitergeleitet, die URLs sind aber in Play hinterlegt und in jedem
  ausgelieferten Build verdrahtet (`main.dart` `kPrivacyUrl`/`kImpressumUrl`/
  `kAgbUrl`).
- **Repo-Heimat (seit 2026-07-31): `KYTH-SYSTEMS/pi-tool`.** Zwei Altlasten
  bleiben dauerhaft zu beachten:
  - **Unter `profex1337` nie wieder ein Repo `evcc-pi-tool` anlegen.** Jede
    installierte Version ≤ v0.63.5 fragt den Update-Check über
    `api.github.com/repos/profex1337/evcc-pi-tool/releases/latest` ab und lebt
    von GitHubs Repo-Redirect (301). Ein Repo dieses Namens killt den Redirect
    sofort — und damit den Update-Pfad dieser Installationen.
  - Die alten Pages-Pfade `profex1337.github.io/evcc-pi-tool/*.html` (in
    Builds ≤ v0.63.3 als Rechts-Links verdrahtet) bedient die **User-Site**
    `profex1337/profex1337.github.io` per Weiterleitung — bewusst als User-Site
    und nicht als Stub-Repo, weil nur so der Repo-Redirect oben überlebt.
- **HRB eingetragen** (2026: Amtsgericht Nürnberg, HRB 46313) — die UG ist keine
  „i.G." mehr, die Haftungsbeschränkung greift. Der Launch-Blocker „Haftung"
  ist damit weg; Impressum/Datenschutz führen HRB + Registergericht.

### Play-Qualitätsanforderungen (Fristen 2027)

Google Play hat am 2026-08-26 technische Schwellen angekündigt (Play-Console-
Hilfe 17492799). Stand der Prüfung an v0.67.0 (2026-08-27):

- **Ab Februar 2027** gelten Grenzen für dynamischen Speicher (Anonymous RSS +
  Swap, 90. Perzentil über 28 Tage, je RAM-Klasse und App-Zustand), für
  Bitmap-Speicher (>200 MB in Background/User-perceived Services, >400 MB im
  Cached-Zustand) und für die DEX-Optimierung (min. 25 % Shrinking/
  Optimization/Obfuscation, **erst ab 10 MB DEX**). Unser DEX misst 2,7 MB, die
  DEX-Regel greift also nicht; R8 läuft trotzdem und ist in
  `android/app/build.gradle.kts` per `isMinifyEnabled = true` festgenagelt,
  damit kein Flutter-Upgrade sie stillschweigend abschaltet. Speicher- und
  Bitmap-Werte gibt es nur als Feldmessung in **Android Vitals** — vor Anfang
  2027 einmal nachsehen, besonders für den Foreground-Service-Zustand während
  langer SSH-Aktionen (§6).
- **Ab April 2027** müssen Apps **mit Nutzer-Login** den Anmeldezustand beim
  Gerätewechsel über die Restore Credentials API wiederherstellen. Pi-Tool hat
  kein Konto (kein OAuth/Firebase/Google Sign-In) — nur SSH-Zugangsdaten zum
  eigenen Pi und den Biometrie-App-Lock —, ist also nicht betroffen.
  `android:allowBackup="false"` bleibt damit unangetastet; der Gerätewechsel
  läuft weiter über den verschlüsselten Profil-Export (`profile_transfer.dart`,
  §6). **Sobald Pro ein echtes Konto bekommt, kippt das:** Restore Credentials
  gehört dann in den Login-Entwurf, nicht in die Nachrüstung.

## Ein neuen Dienst hinzufügen (Kurzrezept)

1. `lib/src/services/<name>.dart`: Befehlsstrings + reine Parser + (falls nötig)
   Root-Skripte mit Markern; jede Interpolation via `shSingleQuote`, Heredocs
   quoted. **Test zuerst** (`test/<name>_test.dart`).
2. Detection-Probe in den Batch in `detectServices` (evcc_updater.dart) + Karte
   bauen; Orchestrierungs-Methoden über `_runRootScriptExpectMarker`.
3. `FakeEvccUpdater` um die neuen Methoden erweitern; UI-Dispatch-Test.
4. UI: Karte im `_serviceCards`-Switch bzw. `_AddableService`-Picker; Pro-Features
   über `_proGate`. Kann die App ihn installieren, braucht er auch einen
   Deinstallations-Builder nach dem Skript-Vertrag in §4 und
   `..._uninstallActions(s)` im ⋮. **Eintrag in `service_links.dart`** (Website, ggf. offizielle
   App) und `..._projectLinkActions(<id>)` ans Ende der `actions` — der Guard-Test
   erzwingt es ohnehin.
5. Version bumpen, `whats_new.dart` ergänzen, **diese Doku aktualisieren**,
   analyze+test grün, main-Build, taggen.
