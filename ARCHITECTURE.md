# Pi-Tool — Architektur

> Referenz-Doku der App. **Bei architektur-relevanten Änderungen mitpflegen**
> (siehe `CLAUDE.md`). Stand: `main` nach v0.71.0.

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
│ UI-Shell        main.dart + ui_widgets.dart (part) + splash, │  Cockpit, 4 Tabs
│                 app_lock.dart                                │  App-Sperre
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
  - **dartssh2 `^4.1.0` ist eine Sicherheits-Untergrenze, keine Vorliebe**
    (v0.71.0): Bis 2.22.5 kamen die Key-Exchange-Geheimnisse aus
    `dart:math`-`Random()` (32-Bit-Seed) statt aus `Random.secure()` — wer den
    Handshake mitschneidet, kann die Sitzungsschlüssel offline durchprobieren.
    Behoben ab 3.0.1; **nie wieder unter 3.0.1 auflösen** (Kommentar an der
    Abhängigkeit in `pubspec.yaml`). Vor jedem dartssh2-Upgrade den
    Ende-zu-Ende-Test gegen einen echten SSH-Partner laufen lassen (§8).
  - **Feste Cipher-Reihenfolge** (`_algorithms`): ChaCha20-Poly1305, dann
    AES-256/128-CTR, AES-GCM zuletzt — bewusst nicht die Standard-Reihenfolge
    der Bibliothek. Deren AES-GCM ist reines Dart und brauchte im
    Integrationstest 31 s für 6,9 MB, ChaCha20-Poly1305 und AES-CTR unter 2 s
    (bei einem Backup-Download der Unterschied zwischen Sekunden und Minuten).
    ChaCha20 bietet jedes OpenSSH seit 6.5 an, CTR deckt Älteres ab.
  - **`LineBuffer`**: `onOutput` bekommt nur *ganze Zeilen* → die zeilenweise
    `redactPassword`-Maskierung kann nicht durch einen über zwei Netz-Chunks
    gesplitteten Geheimwert ausgehebelt werden. Rohe Chunks nie direkt streamen.
    Arbeitet in **einem Durchlauf** über den Chunk: die Kosten wachsen mit der
    Ausgabe, nicht mit ihrem Quadrat (das Abschneiden der Zeile vom Rest kopierte
    den Rest einmal pro Zeile — 16 s für 940.000 kurze Zeilen).
  - **Ausgabe wird als Strom dekodiert** (`Utf8ChunkDecoder`), nicht je
    SSH-Paket: SSH schneidet an Byte-Grenzen, ein Mehrbyte-Zeichen kann über
    zwei Pakete laufen. Einzeln dekodiert wurden beide Hälften zu U+FFFD — und
    der Config-Editor schrieb das zurück in die Datei. Der Dekoder hält ein
    unvollständiges Zeichen zurück, bis es komplett ist; Bytes, die gar kein
    UTF-8 sind, werden U+FFFD statt eines Wurfs, und ein am Stream-Ende
    abgeschnittenes Zeichen wird bei `close()` gemeldet statt verschluckt.
    Reihenfolge je Kanal: Bytes → `Utf8ChunkDecoder` → Ergebnispuffer +
    `LineBuffer`.
  - **TOFU**: `checkAndRecordHostKey` bricht den Handshake ab (gibt `false`),
    bevor je ein Passwort gesendet wird — sowohl bei geändertem Key als auch bei
    abgelehntem First-Use. Ein abgelehnter First-Use speichert den Key **nicht**.
    **Ein gespeicherter Fingerprint, der sich nicht lesen lässt, ist kein
    First-Use:** Wirft der `HostKeyStore` beim Lesen (Secure Storage wirft für
    einen Wert, den es nicht entschlüsseln kann, statt „nichts gespeichert" zu
    antworten, §6 `settings_store.dart`), wird der Key abgelehnt wie ein
    geänderter — sonst vertraute die App, wer gerade antwortet, und überschriebe
    den Pin. `connect()` wirft dann `HostKeyChangedException` mit
    `stored: null`; daran erkennt `_withConnection` den Fall (§2
    „Fehler-Mapping"). Kein Passwort wird gesendet; „Neuen Key vertrauen"
    (vergessen, dann wie beim First-Use bestätigen) ist der Weg weiter.
  - `SshConfig.timeout` begrenzt drei Dinge je für sich: TCP-Connect,
    Auth-Handshake und — pro Befehl — das Warten, bis der Pi Kanal und
    exec-Anfrage bestätigt hat (s. u. „Start eines Befehls"). Die kurzen
    Fristen der Proben (4 s, 8 s, 12 s) gelten damit auch für den Start jedes
    Befehls auf diesen Verbindungen.
    `commandTimeout` ist ein **Inaktivitäts**-Timeout (lange apt/docker-Läufe,
    die weiter streamen, dürfen laufen). `keepAliveInterval: 20s` verhindert,
    dass NAT/Router die Session in ruhigen dpkg-Phasen killen.
    **Die Handshake-Frist zählt nur aktive Zeit** (`withinActiveTime` über
    `_handshakeClock`): Solange der First-Use-Fingerprint-Dialog offen ist,
    steht die Uhr — das ist die Zeit des Nutzers, nicht die des Pi. Wer den
    Fingerprint wirklich vergleicht, bekäme sonst „Pi nicht erreichbar" für
    einen Pi, der sofort geantwortet hat.
  - `run()` drainiert die Streams via `asFuture()` (feuert nach *allen*
    Kanaldaten) — so geht kein letzter Chunk (z.B. eine kurze Versionsausgabe)
    verloren.
  - **Start eines Befehls ist befristet:** `client.execute()` wartet, bis der
    Pi Kanal und exec-Anfrage bestätigt hat — vorher hört nichts zu, und das
    Inaktivitäts-Timeout läuft noch nicht. dartssh2 beendet dieses Warten bei
    einem Transportfehler und bei `close()`, aber über eine Leitung, die
    lautlos gestorben ist, kommt keins von beiden, bevor der TCP-Stack aufgibt.
    `run()` begrenzt es deshalb mit `SshConfig.timeout` (`withinOrDiscard`;
    eine Sitzung, die danach doch noch aufgeht, wird wieder geschlossen) und
    wirft **`CommandNotStartedException`** — eine `TimeoutException` eigenen
    Typs: Soweit diese Seite es weiß, lief der Befehl nie an. Wer einen
    Verbindungsabriss sonst als Wirkung des Befehls liest (Reboot, Shutdown),
    darf diesen Fall nicht so lesen (§2 „Null-Exit").
  - **stdin läuft unter dem Inaktivitäts-Timeout, nicht unter der
    Connect-Frist:** Die Eingabe wird in 32-KiB-Stücken an den Kanal gegeben
    (`inPieces` über `session.stdin.addStream`) und zusammen mit stdout und
    stderr erwartet. dartssh2 nimmt das nächste Stück erst, wenn das Fenster
    der Gegenseite Platz hat, und jedes genommene Stück zählt wie Ausgabe. Ein
    Upload, den der Pi nicht mehr annimmt, endet so nach `commandTimeout`;
    ein langsamer, der sich noch bewegt, läuft weiter (ein Upload dauert
    legitim Minuten und druckt nichts — die kurze Connect-Frist wäre die
    falsche Grenze).
  - **`close()` ist best-effort und begrenzt**: Client und Socket werden
    nacheinander geschlossen, je höchstens `closeWait` (3 s), Fehler werden
    geschluckt. Nach einem Socket-Fehler (WLAN weg, Connection reset) liefert
    dart:io beim Schließen denselben Fehler noch einmal — aus dem `finally` der
    Aktion heraus ersetzte er deren Ergebnis („Pi-Job läuft weiter", „Ergebnis
    unbekannt") durch einen rohen Socket-Fehler. Schließen bestimmt nie mit, was
    eine Aktion meldet. `close()` beendet außerdem einen noch laufenden
    `connect()` sofort (`_closeSignal`), statt die Handshake-Frist abzuwarten.
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
  **Erkannt wird zeilenweise, an sudos eigenen Zeilen — nicht als Teilstring
  der ganzen Ausgabe:** eine Zeile, die mit „Sorry, try again." **endet**
  (hinter dem Prompt von `sudo -S` steht kein Zeilenumbruch), oder eine Zeile,
  die „sudo: N incorrect password attempt(s)" **ist** (auch hinter sudos
  Standard-Prompt). Die Wörter allein kommen auch in Nutzdaten vor — sudos
  Journal-Eintrag lautet „pi : 3 incorrect password attempts ; TTY=…" —, und
  das ist keine Ablehnung. Wo stdout Nutzdaten trägt (`readConfigFile`,
  `readFileBytes`, `listDir`), wird **nur stderr** geprüft. Die Konsole führt
  beide Ströme zusammen (`2>&1 | head -c`), prüft also die gemeinsame Ausgabe
  — und nur, wenn ein Passwort mitgeschickt wurde.
- **Redaction**: `_withConnection` wickelt jedes `onLog` in `redactPassword` —
  **dieselbe Stelle** filtert auch das apt/dpkg-Fortschrittsgemalte
  (`stripProgressNoise`, siehe §3). Eine Naht für alle Aktionen; Parser sehen
  weiterhin die rohe Ausgabe.
  **Maskiert wird das ganze Wort um einen Treffer:** Steht das Passwort in
  einer längeren Folge aus Buchstaben und Ziffern, wird die ganze Folge zu
  **einer** Maske fester Breite („********pi" für `raspberrypi` zeigte, wo das
  Passwort endet — beim alten Standardpasswort das Passwort selbst). Treffer,
  die sich berühren oder überlappen, teilen sich eine Maske; aus einem
  geteilten Log lassen sich so weder Position noch Länge noch Anzahl ablesen.
  Betrifft nur die Anzeige.
- **Passwort nur, wenn sudo danach fragt** (v0.64.1): `sudo -S` frisst die erste
  stdin-Zeile als Passwort — **aber nur, wenn es fragt**. Bei NOPASSWD-sudo (oder
  noch gültigem Timestamp) fragt es nicht, die Zeile fällt durch zu `bash -s` und
  das Passwort wird als Befehl ausgeführt (`bash: line 1: ****: command not
  found` — real gesehen am 2026-07-31). Deshalb einmal pro Verbindung
  `sudoNoPasswordProbe` (`sudo -n true`), Ergebnis für die Verbindung gecacht
  (`Expando _sudoNeedsPw` pro Runner — auf der Instanz entschiede sonst die
  Antwort der Verbindung zu einem anderen Pi, die daneben lief, ob das Passwort
  vor ein Root-Skript kommt), und die stdin baut `buildRootStdin`.
  **Fail-safe:** Probe nicht erfolgreich ⇒
  Passwort wird mitgeschickt. Betrifft die Skript-Pfade (`bash -s`) **und die
  Konsole** (`runConsoleCommand`, v0.71.0): Ein frei eingegebenes `sudo …`
  bekommt das Passwort nur auf stdin, wenn die Probe sagt, dass sudo es liest.
  Auf einem NOPASSWD-Pi erreichte die Zeile sonst das Programm — `sudo bash`
  führte sie als Root-Befehlszeile aus, `sudo tee <datei>` schrieb sie in die
  Datei. Die festen Einzelbefehle der App (`_sudoCommand`: `sudo -S apt-get …`
  u. ä.) schicken die Zeile weiterhin ohne Probe mit — dahinter steht kein
  Interpreter, der sie von stdin ausführen würde. **Pi-Jobs** brauchen die
  Probe nicht: ihr Bootstrap verwirft alles vor einer Sentinel-Zeile (s. u.).
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
  - **Früher Abbruch ≠ unklarer Start:** Endet der Launcher mit Exit 1–127
    (außer 3 = `jobStartUnclearExit` und 97 = `jobBadHeaderExit`) **ohne jede
    Kontrollzeile**, kam das Job-Skript nie zur Arbeit (der Nutzer darf kein
    sudo: 1; sudo oder bash fehlt: 127; falsche Argumente: 2) —
    `classifyJobRun` liefert `JobRunEarlyExit(exitCode)`, und die Aktion endet
    mit „Hintergrund-Job konnte nicht gestartet werden (Exit n) – es wurde
    nichts gestartet. Details im Log." als gewöhnliche
    `EvccUpdateException`: kein Eintrag in der Job-Leiste, die Sitzung bleibt.
    Kein Exit-Status, 0, 3 und 128+n (per Signal beendet, möglicherweise nach
    der Übergabe an systemd) bleiben „Start unklar". Beim Mitlesen
    (`followJob`) beweist ein früher Abbruch des Followers nichts über den Job
    und zählt wie bisher als unklar.
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
    (`PITOOL_APT_UPDATE_RC` → `listsIncomplete`). Es läuft mit
    `-o APT::Update::Error-Mode=any`: Ohne die Option endet apt auch dann mit
    0, wenn ein Download scheiterte und die alten Listen in Gebrauch bleiben —
    das Upgrade fände nichts, und die App meldete „System aktualisiert." ohne
    den Hinweis. Ein apt, das die Option nicht kennt (laut Code-Kommentar vor
    2.1.16, also Buster), ignoriert sie. Der Exit-Status fließt nur in die
    Markerzeile, nichts davon beendet die Payload; apts Ausgabe wird gesammelt
    und nach dem Lauf gedruckt. Nach einem sauberen Lauf setzt die Payload den
    Zeitstempel der Paketlisten wie `systemAptRefreshCommand` (§4).
  - **Payloads enthalten keine Geheimnisse** (Tier 1 erfüllt das; Tests prüfen
    es). Installs, Uninstall, Docker/HA, Restores bleiben bewusst im
    Vordergrund — für sie gilt die Null-Exit-Regel unten.
- **Null-Exit = kein Erfolg** (v0.70.0): `_sudoCommand` (mit `checkExit`),
  `_runRootScript`, `install()` und die übrigen verändernden Einzelbefehle
  werten `exitCode == null` als „Verbindung während der Aktion abgerissen –
  Ergebnis unbekannt". Dasselbe gilt für `refreshAptIndex` (§4) sowie
  `listDir` und `readFileBytes` (§5 `files.dart`). Ausnahmen: Reboot/Shutdown
  (Abriss = erwartet — **nicht** aber `CommandNotStartedException`, §1: Hat
  der Pi den Befehl nie angenommen, spricht nichts dafür, dass er
  herunterfährt; die Aktion meldet dann keinen ausgelösten Neustart) und
  lesende Probes. Die **Erkennung** zählt nicht zu den ungeprüften Probes:
  Sie wird am Endmarker ihres Batches gemessen, nicht am Exit-Status (§3
  „Detection-Batch"). Ohne Exit-Prüfung bleibt die sudo-Docker-Liste
  **innerhalb** der Erkennung (der Rückfall bei verweigertem Docker-Socket) —
  ein Abriss genau dort liest sich als „kein Container". Die sudo-Probe wirft
  bei `null`, statt „Passwort nötig" zu raten.
- **Reboot/Shutdown-Sperre** (`jobPowerGuard`, v0.70.0): `rebootCommand`/
  `shutdownCommand` sind `sudo -S sh -c '<guard>; exec reboot|poweroff'`. Der
  Guard lehnt mit Exit 75 und einem Marker ab, in dieser Reihenfolge:
  `PITOOL_REFUSED_JOB_RUNNING`, solange der Job-Lock gehalten wird;
  `PITOOL_REFUSED_AUTOUPDATE_RUNNING`, solange das On-Pi-Auto-Update läuft
  (§5); `PITOOL_REFUSED_BOOT_INCOMPLETE`, solange `rpikernelhack`-Diversionen
  existieren (Buster/Bullseye-Kernel halb konfiguriert → `/boot` leer). Das
  Auto-Update wird **vor** der Diversion gefragt: Während ein Upgrade läuft,
  ist eine Diversion dessen Zwischenstand und kein Anlass zum Reparieren.
  Gelesen wird `systemctl show -p ActiveState --value
  pi-tool-autoupdate.service` (`active|activating|deactivating|reloading` =
  läuft) statt `is-active` — die oneshot-Unit ist für ihren ganzen Lauf
  „activating", und darauf antwortet `is-active` mit Nein. Ein Pi ohne die
  Unit meldet „inactive", einer ohne systemd nichts: beides erlaubt. Fehlt
  die Lock-Datei (nie ein Job), ist der Neustart erlaubt. Die Ablehnung wegen
  des Auto-Updates erreicht die UI als `JobException(jobBusy)` ohne
  `ref`/`jobKind` (gelbes Banner mit dem Text der Logik-Schicht: „…
  abgelehnt: Auf dem Pi laufen gerade die automatischen Updates – …").
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
  Minuten erneut"). Parser in `eol_sources.dart`. `isAptLocked` zählt nur apts
  **Fehlerzeilen** (`E: …`; `Error: …` ist dasselbe Präfix ausgeschrieben,
  wie es das `apt`-Frontend von apt 3 druckt — aus apts Quelltext, nicht
  gemessen): Mit `DPkg::Lock::Timeout` meldet apt während des Wartens
  „Waiting for cache lock: Could not get lock …"; ein Lauf, der die Sperre
  danach bekam und aus anderem Grund scheiterte, war nicht ausgesperrt.
- **EOL-Paketquellen zuerst umstellen** (`_fixEolSources`, v0.67.1): **jede**
  Aktion, die Pakete installiert oder aktualisiert (evcc-Update außer Probelauf,
  evcc-Install, Tailscale, Grafana/InfluxDB/Mosquitto, Paketlisten,
  System-Upgrade, Einzelpaket-Update, Sicherheits-Fixes fail2ban/Auto-Updates,
  seit v0.71.0 auch die **Pi-hole-** und die **Home-Assistant-Installation** —
  Pi-holes Installer ruft `apt-get update` selbst auf und verwirft die Ausgabe,
  Dockers Installationsskript installiert über apt),
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
  - `_runRootScript`: prüft nur Sudo-Ablehnung + Exit-Code und gibt die
    Ausgabe des Skripts zurück (die Docker-Updates lesen daraus
    `PITOOL_IMAGE_UNCHANGED`, §3).
  - `_runRootScriptExpectMarker`: für **destruktive** Skripte (Restore,
    Config-Save, Timer-Install/Remove) — Erfolg braucht den Marker **und**
    keinen Nonzero-Exit; fehlender Marker = Fehler, **auch bei Exit-Code null**
    (Signal-Kill / Verbindung mitten im Lauf abgerissen → ein halb erledigter
    Restore darf nie als Erfolg gemeldet werden). Skripte laufen unter `set -e`,
    der Marker steht nur am Happy-Path-Ende.
  - `_runRootScriptCapturing`: zusätzlich `BACKUP_OK <pfad>`-Parsing.
  - **Ablehnungs-Zeilen** (`commands.dart`): Ein Skript, das **vor** jeder
    Änderung ablehnt, druckt genau eine Zeile mit deutschem Grund und endet mit
    Exit 3 — `UNINSTALL_REFUSED: <Grund>` (`parseUninstallRefusal`, §4
    „Deinstallieren") bzw. seit v0.71.0 **`INSTALL_REFUSED: <Grund>`**
    (`installRefusedPrefix`/`parseInstallRefusal`; heute die 64-Bit-Guards für
    Home Assistant und InfluxDB, §4). `_runRootScript` (Install-Zeile) und
    `_runRootScriptExpectMarker` (beide) machen den Grund zur Fehlermeldung
    statt „Details im Log". Erkannt wird nur eine Zeile, die mit dem Präfix
    **beginnt** — das Install-Präfix ist ein Teilstring des Uninstall-Präfixes.
- **Cancel**: `cancel()` markiert **jede** offene Verbindung als abgebrochen
  und schließt sie danach (`_open`, eine Menge statt eines einzelnen Handles:
  die UI serialisiert Aktionen hinter `_busy`, aber der Dateien-Tab listet und
  zeigt daneben — mit einem Handle erreichte „Abbrechen" nur die zuletzt
  geöffnete Verbindung, und die zuerst geschlossene nahm das Handle mit).
  **Der Abbruch-Zustand gilt je Verbindung** (`Expando _cancelled` pro Runner,
  wie `_jobTouched`; ebenso `_sudoNeedsPw` und `_rootWorkSent`): Mit einem
  Flag auf der Instanz löschte eine Verbindung, die direkt hinter „Abbrechen"
  aufging (Dateien-Tab), die Anforderung — die abgebrochene Aktion meldete
  dann, was ihre geschlossene Verbindung hinterließ, und ein Job, bei dem nur
  das Mitlesen beendet wurde, las sich als „Verbindung abgerissen". Eine
  Verbindung, die nach dem Cancel öffnet, ist weder abgebrochen noch löscht
  sie etwas.
  `_withConnection` prüft den Zustand seiner Verbindung (1) nach connect — ein
  Cancel im Handshake
  muss vor dem (evtl. destruktiven) body stoppen — und (2) nach dem body, weil
  ein Schließen mitten im Befehl `run()` **nicht** immer werfen lässt (dartssh2
  beendet den Stream normal → ein Teil­ergebnis sähe erfolgreich aus).
  **Nach einem Job-Start heißt Cancel nur „nicht mehr mitlesen"**: der Job
  läuft weiter, Ergebnis `jobDetached` (Grund `userStopped`), nie `cancelled`.
  **Cancel schließt nur die Verbindung — er stoppt nichts auf dem Pi**
  (Entwurfsgrenze): Ein Root-Skript im Vordergrund, das der Pi schon hat,
  läuft weiter, bis eines seiner Kommandos auf die geschlossene Ausgabe
  schreibt — stille Skripte laufen zu Ende, gesprächige (apt, dpkg) enden
  mittendrin. Unabhängig von der Verbindung sind nur Pi-Jobs. Die Meldung sagt
  das: `_cancelledError` liefert „Abgebrochen – die Verbindung wurde getrennt.
  Ein Schritt, der auf dem Pi bereits lief, kann dort noch zu Ende laufen.",
  sobald auf der Verbindung Root-Arbeit hinausging (`_rootWorkSent`, gesetzt
  in `_rootStdin`, in `_runRootScript` ohne sudo und in `_sudoCommand`); sonst
  bleibt es bei „Abgebrochen.". Die Konsole und einzelne sudo-Aufrufe
  außerhalb dieser drei Stellen sind nicht markiert.
- **Fehler-Mapping** nur im `catch` von `_withConnection`: HostKeyDeclined →
  connection, HostKeyChanged → hostKeyChanged (mit Fingerprint),
  **`SSHAuthAbortError` → connection** („Verbindung vor der Anmeldung
  getrennt": sshd hat die Verbindung fallen lassen oder sie riss im Handshake,
  bevor der Pi Zugangsdaten beurteilt hat — dartssh2 führt das unter seinen
  Auth-Fehlern, „Passwort prüfen" schickte den Nutzer aber in die falsche
  Richtung; die Prüfung steht deshalb **vor** der auf `SSHAuthError`),
  Auth/KeyDecode → auth, Socket → connection, sonst unknown.
  **Ein Timeout ist nur vor und während des Verbindens ein
  Verbindungsfehler.** Wirft der body nach gelungenem connect eine
  `TimeoutException` (10 min ohne Ausgabe, 15 s ohne Start eines Befehls, §1),
  war der Pi erreichbar und arbeitet möglicherweise noch — etwa ein tar über
  ein großes Verzeichnis, das lange nichts druckt. Dafür gibt es den eigenen
  `UpdateErrorKind.outputTimeout` („Seit 10 min keine Ausgabe – die Aktion
  läuft möglicherweise auf dem Pi weiter, Ergebnis unbekannt."; die Dauer
  kommt aus der Exception, sonst `commandTimeout`), und `_guard` behält die
  Sitzung (§7). **`HostKeyChangedException` mit `stored == null`** (der
  gespeicherte Fingerprint ließ sich nicht lesen, §1) wird ebenfalls zu
  `hostKeyChanged`, aber mit eigenem Text („Der gespeicherte SSH-Host-Key von
  … ließ sich nicht lesen – ob der Pi derselbe ist, lässt sich so nicht
  prüfen …") — eine echte Änderung trägt immer den gespeicherten Wert. Der Runner
  wird immer im `finally` geschlossen, und das `finally` **schluckt Fehler von
  `close()`**: das Schließen einer schon toten Verbindung kann werfen und
  ersetzte sonst, was die Aktion gemeldet hat (ein Job, der weiterläuft; ein
  unbekanntes Ergebnis; auch ein fertiges).
- **Config lesen nur mit Beleg** (`readConfigFile`, v0.71.0): Der Editor
  schreibt zurück, was er bekommen hat. Deshalb gilt ein `cat` ohne Exit 0 als
  nicht vollständig gelesen (ein Speichern würde die Datei kürzen), und eine
  Ausgabe mit U+FFFD — Bytes, die kein UTF-8 sind, etwa eine ISO-8859-1-Datei —
  wird abgelehnt („nicht UTF-8-kodiert – in der App nicht bearbeitbar"), weil
  Speichern das Ersatzzeichen dauerhaft über die Bytes schriebe. Eine
  sudo-Ablehnung wird hier nur in stderr gesucht — stdout ist die Datei, und
  eine Datei kann genau die Zeilen enthalten, die sudo druckt.
- **Erfolg nur mit Exit-Status, auch ohne sudo** (v0.71.0): `sendTestAlert`
  wertet `curl` aus (kein Exit-Status = Ergebnis unbekannt; Exit ≠ 0 wirft mit
  curls eigener Meldung, die auch im Log steht) — eine funktionierende
  SSH-Verbindung ist kein zugestellter Push. `piConnectSet`/`piConnectSignout`
  brechen bei fehlendem Exit-Status ab; ein Exit ≠ 0 wird vorerst nur im Log
  genannt, weil nicht gemessen ist, welche Exit-Codes `rpi-connect` bei
  harmlosen Wiederholungen (schon an, schon aus) liefert.
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
  in `mktemp` + `mv -fT` (atomar; `-T`: ein Verzeichnis am Ziel ist ein Fehler,
  kein Ort, in den verschoben wird), `chmod/chown --reference` vorher (Rechte
  erhalten). **Ein Symlink wird durchgeschrieben** (`readlink -f`, die
  Temp-Datei liegt neben dem echten Ziel): Auf den Link selbst umbenannt,
  ersetzte die neue Datei den Link, und die Datei dahinter bliebe, wie sie
  war. Ein `trap … EXIT` räumt die Temp-Datei bei jedem Fehlschlag weg.
  Rotiert Backups **je Datei** (neueste 5; der Glob ist das
  Zeitstempel-Muster `config-<basename>-JJJJMMTT-HHMMSS.bak`, damit `evcc.yaml`
  die Sicherungen von `evcc.yaml-old` weder mitzählt noch löscht; gelöscht wird
  zeilenweise statt per `xargs`, das Namen an Leerzeichen trennt), Marker
  `CONFIG_SAVED`.
- **evcc-Backup** (`buildBackupScript`, läuft über `installShellCommand`):
  Archiv `/var/backups/evcc/evcc-backup-<zeit>.tar.gz` aus `/etc/evcc.yaml`
  (falls vorhanden) und der Datenbank. **Reihenfolge der Datenbank-Kandidaten:**
  der `dsn:`-Wert der Config, wenn er eine vorhandene Datei nennt (gelesen ohne
  umschließende Anführungszeichen, ohne nachgestellten Kommentar und ohne CR;
  nennt er keine Datei, gibt es eine Hinweiszeile, die den Wert nie ausgibt),
  sonst `/var/lib/evcc/evcc.db`, `/var/lib/evcc/.evcc/evcc.db`,
  `/root/.evcc/evcc.db`, zuletzt `/home/*/.evcc/evcc.db`. Die Datenbank des
  Dienstes steht vor `/root`: die Migration des Pakets kopiert `/root/.evcc`
  dorthin und lässt das Original liegen — neben einer aktiven Datenbank ist
  `/root` ein veralteter Rest. Ohne Dienst-Datenbank kommt `/root` vor einem
  Home-Verzeichnis (eine alte Installation, die noch als root läuft, hat ihre
  Daten dort). Mit der Datenbank werden vorhandene **`-wal`/`-shm`/`-journal`**
  archiviert (evcc läuft weiter; im WAL-Modus stehen bestätigte Schreibvorgänge
  bis zum nächsten Checkpoint in `<db>-wal`). Die Dateiliste steht in den
  Positionsparametern (Pfade mit Leerzeichen bleiben ein Argument).
  **Atomar:** tar schreibt nach `.part`, erst `mv -f` macht daraus das Archiv;
  ein gescheiterter Lauf lässt nichts zurück, liegengebliebene `.part` räumt
  der nächste Lauf weg. **tar-Exit 1** („file changed as we read it") zählt
  als geschriebenes Archiv, erst Exit ≥ 2 ist ein Fehler. Danach **Rotation auf
  die 10 neuesten** `evcc-backup-*.tar.gz` (zeilenweise). Ausgabe:
  `EVCC_BACKUP_OK <pfad>`, `EVCC_BACKUP_EMPTY` (nichts zu sichern, kein Fehler)
  oder `EVCC_BACKUP_FAIL` + Exit 1.
- **evcc-Restore** (`buildRestoreScript`, Marker `RESTORE_OK` als letzte Zeile,
  über `_runRootScriptExpectMarker`): **Vorprüfung** — das Archiv muss sich
  vollständig auflisten lassen (`tar -tzf`), bevor irgendetwas geändert wird;
  ein abgeschnittenes Archiv stoppt weder evcc noch überschreibt es die Hälfte
  der Dateien. Danach wird zuerst ein **`trap … EXIT`** gesetzt, der evcc
  wieder startet, wenn ein späterer Schritt abbricht (tar, volle Platte,
  geschlossener Kanal), und erst dann evcc gestoppt. Für jede `*.db` im Archiv
  werden die auf dem Pi liegenden `<db>-wal`/`-shm`/`-journal` **entfernt**,
  sofern das Archiv sie nicht selbst mitbringt — neben der zurückgespielten
  Datei würde SQLite sie auf die falsche Datenbank anwenden. Dann
  `tar -xzf … -C /`, Trap lösen, evcc starten. Ob evcc danach wirklich läuft,
  prüft `restoreBackup` anschließend selbst (`systemctl start` meldet schon
  beim Fork Erfolg).
  **Welche Pfade entpackt werden dürfen**, entscheidet `isEvccRestorePath`
  (`restoreBackup` lehnt alles andere als „Ungültiger Backup-Pfad." ab): ein
  `.tar.gz` direkt in `/var/backups/evcc`, oder ein evcc-Archiv der
  On-Pi-Timer mit exaktem Namen,
  `/var/backups/pi-tool/(sched|autoupdate)-evcc-<8 Ziffern>-<6 Ziffern>.tar.gz`
  (§5 — `/etc/evcc.yaml` und `/var/lib/evcc`, relativ zu `/` abgelegt wie die
  eigenen Archive, also unverändert wiederherstellbar).
  **Invariante: nichts anderes aus `/var/backups/pi-tool` wird je nach `/`
  entpackt** — die Pi-hole- und Home-Assistant-Archive daneben haben einen
  anderen Aufbau.
- **Backup-Listen** (`listBackupsCommand`, `serviceBackupListCommand`):
  `sh -c 'ls -1t <Muster> 2>/dev/null'` in der Login-Sitzung, ohne sudo (die
  Verzeichnisse sind 0755, die Archive 0644). evcc listet die eigenen Archive
  und die der beiden Timer (`sched-evcc-*`, `autoupdate-evcc-*`), die
  Dienst-Liste `<dienst>-backup-*` und `sched-<dienst>-*` (der Backup-Timer
  schreibt das für Pi-hole). `sh`, weil eine Login-Shell wie zsh bei mehreren
  Mustern die ganze Zeile verweigert, sobald eines keinen Treffer hat; unter
  `sh` listet `ls` die Treffer der übrigen. Das Dienst-Präfix steht einfach
  gequotet im einfach gequoteten `sh -c`-Wort. `BackupOrigin` (`app`,
  `scheduled`, `autoUpdate`) und `backupOrigin(path)` — entschieden am
  Dateinamen-Präfix `sched-`/`autoupdate-` — dienen nur der Kennzeichnung im
  Sheet („Geplantes Backup", „Vor automatischem Update").
- **Detection-Batch**: `buildDetectBatch`/`splitDetectSections` bündeln alle
  Probes der Erkennung (derzeit knapp 30) in **eine** SSH-Runde
  (`@@PT@@key@@PT@@`-Marker, `{ cmd ; } 2>&1 || true` isoliert einzelne
  Fehlschläge). Ausgeführt via `detectShellCommand` (`LC_ALL=C bash -s`).
  **Der Batch ist eine Gruppe `{ … } </dev/null` und endet mit dem Endmarker
  `@@PT@@__END__@@PT@@`** (`detectEndKey`). Die Gruppe: Das Skript kommt auf
  bashs stdin, und bash liest eine Gruppe bis zur schließenden Klammer, bevor
  es etwas davon ausführt — eine Probe, die stdin liest (etwa ein Wrapper um
  `docker exec -i`), bekommt so nichts statt der Zeilen, die ihr folgen, den
  Endmarker eingeschlossen. Der Endmarker: Schließt der Kanal vorher (der Pi
  fährt herunter, die Sitzung wurde beendet), kommen nur die Abschnitte bis
  dahin an, und ein fehlender Abschnitt läse sich wie „nicht installiert" —
  auf den Karten und in ihrem Cache. `detectServices` wirft deshalb ohne
  Endmarker `UpdateErrorKind.unknown` („Ergebnis unbekannt"); der Exit-Status
  wird bewusst **nicht** gewertet (er reist hinter der Ausgabe und kann hinter
  einem Batch verloren gehen, der fertig wurde). Vorher loggt es „Erkennung
  unvollständig: N von M Abschnitten angekommen (zuletzt KEY), Exit-Status
  X." und, falls die Shell selbst etwas auf stderr gedruckt hat, „Meldung der
  Shell: …" (auf 300 Zeichen gekürzt) — nicht nach einem Abbruch durch den
  Nutzer. Aufrufer behalten dann, was sie hatten: `_refreshServices` den
  Stand auf dem Bildschirm, `_probePi` meldet den Pi als nicht erreichbar, der
  Umzugshelfer endet, bevor er am Ziel etwas installiert. `_readRouteState`
  (§4 Tailscale) nutzt denselben Builder und prüft denselben Endmarker.
- **Docker**: `parseEvccDocker` bevorzugt Image-Match, Name-Fallback nur
  *exakt* `evcc` (sonst würde `evcc-db` fälschlich gewählt). `buildDockerRunCommand`
  rekonstruiert `docker run` aus `docker inspect` mit Whitelist bei Restart-Policy
  und erhält devices/caps/privileged (USB/RS485-Zähler!), dazu `--cap-drop`,
  `--security-opt` (ohne das `label=disable`, das der Daemon bei
  `--privileged`/`--pid=host`/`--ipc=host` selbst anhängt), `--tmpfs`,
  `--shm-size` (nur abweichend von den 64 MiB des Daemons), `--sysctl`, die
  Speicher-, CPU- und pids-Limits und den pid-Modus — jeweils nur, wenn der
  Wert von dem abweicht, was der Daemon selbst einträgt.
  **Was sich nicht verlustfrei nachbauen lässt, wird abgelehnt statt
  weggelassen** (`dockerRecreateRefusal(inspect)`; der Updater fragt über
  `_requireRecreatable` nach der Digest-Pin-Prüfung, **bevor** etwas gezogen
  oder gestoppt wird; nie für Compose-Container, die Compose selbst neu
  anlegt): `--rm` (Docker löscht den Container, sobald er stoppt — es bliebe
  kein Rollback), `--mount`-Einträge, mehr als ein Netzwerk, eine feste
  IP-Adresse, ein vom Nutzer gesetzter Netzwerk-Alias (Hostname, Containername
  und 12-stellige Kurz-IDs zählen nicht — die trägt der Daemon bzw. ein
  früheres Neuanlegen selbst ein) und ein eigenes seccomp-Profil (gespeichert
  ist dessen JSON; zurückgereicht suchte das docker-CLI eine Datei dieses
  Namens). Der deutsche Grund wird zur Fehlermeldung.
  `dockerRunRecreateScript`: `pull` zuerst → **Vergleich**: Ist die Image-ID,
  aus der der Container erzeugt wurde, gleich der ID, auf die das Tag jetzt
  zeigt, druckt das Skript `PITOOL_IMAGE_UNCHANGED`
  (`dockerImageUnchangedMarker`) und endet mit Exit 0, ohne den Container
  anzufassen. Verglichen wird das Image des Containers, nicht das Tag vor dem
  Pull — ein von Hand oder von einem zurückgerollten Update gezogenes Image
  ist für den Container noch neu; nicht lesbare IDs gelten nie als gleich. →
  sonst alten Container zu `<name>-evccpitool-old` **umbenennen**
  (Rollback, nie `-v` löschen) → neu starten → nach dem Warten muss
  `{{.State.Status}}|{{.RestartCount}}` exakt **`running|0`** sein, sonst
  zurückrollen. (`.State.Running` bleibt `true`, solange ein Container mit
  `always`/`unless-stopped`/`on-failure` in seiner Neustart-Schleife hängt — bis
  v0.68.x griff der Rollback dort nie.) Die Dart-seitige Nachprüfung nach
  Install/Update nutzt `dockerListRunningCommand` (`--filter status=running`),
  die Erkennung die ungefilterte Liste **mit Zustand**, damit ein
  Crash-Loop-evcc sichtbar bleibt, aber nicht als laufend gilt:
  `dockerListStateCommand` (`name|image|state`; `{{.State}}` kam mit Docker
  20.10 — ein älterer Client scheitert am Template, dann antwortet die
  schlichte Liste ohne Zustand; die sudo-Variante legt **ein** sudo um beide
  Versuche, `LC_ALL=C sudo -S sh -c "…"`). `dockerContainerState` liest die
  dritte Spalte: `restarting` setzt auf der Karte `ServiceStatus.health` =
  „⚠ Container startet neu" (mit `healthWarning`),
  `created`/`paused`/`removing`/`exited`/`dead` ergeben „⚠ Container-Zustand:
  …" mit dem Zustandswort; die Karte ist dann „inaktiv". (Die Liste ist ein
  `docker ps` ohne `-a`: Gestoppte Container stehen gar nicht darin, praktisch
  kommen `restarting` und `paused` vor.) Eine fehlende oder unbekannte dritte
  Spalte behauptet nichts — die Karte bleibt „aktiv". `detail` bleibt
  „Docker · NAME", weil `buildServiceLogsCommand` den Containernamen daraus
  liest; das Cache-Format ist unverändert. Der geparkte Container bekommt
  **`--restart=no`** (v0.69.0;
  vorher kam er mit `always` nach jedem Neustart wieder hoch — und eine gerade
  deinstallierte Karte mit ihm); die ursprüngliche Policy wird vorab per
  `docker inspect` gelesen und beim Rollback zurückgesetzt.
  **Ergebnis der drei Update-Wege** (`updateDocker`, `updateHomeAssistant`,
  `updateDockerContainer`): `DockerUpdateOutcome` (`updated`, `tagCurrent`,
  `pinnedTagCurrent`). Meldet das Skript den Marker, entfällt die
  Nachprüfung, es gibt keinen Verlaufseintrag, und `main.dart` zeigt über
  `_tagCurrentText` `statusImageTagCurrent` bzw. — bei einem versionsfesten
  Tag (`isVersionPinnedImage`: `:2026.6.3`, `:v1.27`, `:16-alpine`; eine
  neuere Version gibt es dort erst mit einem anderen Tag) —
  `statusImageTagPinnedCurrent`. Der Compose-Weg kennt diese Meldung nicht.
- **evcc-Installation** (`buildInstallScript`): folgt dem Muster der
  apt-Dienste — `DPkg::Lock::Timeout=120`, `aptNoPty`,
  `--force-confdef/--force-confold`, und jedes `apt-get` bekommt sein eigenes
  `</dev/null`. Das Skript kommt auf stdin (`bash -s`): dpkgs conffile-Frage
  oder ein `read` im postinst von evcc nähme sonst die nächste Skriptzeile als
  Antwort.
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
  Zustand, nur Tailscale, übersteht die Cache-Runde; `health` = zweite Zeile
  der Karte: auf der System-Karte die Vitalwerte, auf Docker-Karten der
  Hinweis, dass der Container gelistet ist, aber nicht läuft, §3 „Docker").
  `updateAvailable` ist nur bei
  `updateKnown == true` aussagekräftig (Tri-State: Docker-evcc / nicht-gepinnte
  HA-Tags zeigen „Aktualisieren" statt falsch „Aktuell"). Reconciler
  `applyLatestEvccVersion` (nur apt-evcc, gegen stalen lokalen apt-Index) /
  `applyLatestHomeAssistantVersion` (nur calver-vs-calver). **Beide setzen bei
  jedem GELUNGENEN Vergleich `updateKnown=true`** — auch bei „du bist aktuell";
  genau das rettet das „Aktuell ✓", wenn der apt-Index zu alt ist (unten).
  **Ausnahme Nightly-evcc:** Verglichen wird gegen das neueste
  **Stable**-Release. Eine Nightly-Installation (Version mit Suffix oder dem
  Stable-Release voraus, `_isStableEvccBuild`) übernimmt nur ein gefundenes
  Update; „nicht älter als Stable" ist kein Wissen über sie — `updateKnown`
  bleibt dann, wie der apt-Index es hinterlassen hat.
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
  **Der Refresh setzt den Zeitstempel selbst** (`systemAptRefreshCommand`,
  v0.71.0): apt ändert die mtime von `/var/lib/apt/lists` nur, wenn eine
  Indexdatei ersetzt oder entfernt wird. Antworten alle Quellen mit „Hit"
  (eingefrorenes EOL-Archiv, ruhige Woche), blieb das gemessene Alter stehen und
  die Karten sagten direkt nach einem gelungenen Refresh weiter „Stand
  unbekannt". Der Befehl führt `apt-get update -qq` aus und macht danach — nur
  nach **sauberem** Lauf — `touch /var/lib/apt/lists`. Sauber = Exit 0 **und**
  kein fehlgeschlagener Download: apt endet auch mit 0, wenn Quellen nicht
  erreichbar waren („Failed to fetch", die alten Listen bleiben in Gebrauch);
  ein Stempel gäbe dann einen veralteten Index als frisch aus. Ausgabe und
  Exit-Status von apt werden unverändert durchgereicht. Denselben Stempel
  unter derselben Bedingung setzen die Pi-Job-Payloads (`pitool_update_lists`,
  §2) und der Alerts-Wrapper bei seinem täglichen Refresh (§5); der
  Auto-Update-Wrapper setzt ihn nicht.
  **`refreshAptIndex` toleriert einzelne scheiternde Quellen, aber nicht jeden
  Ausgang:** kein Exit-Status = „Ergebnis unbekannt", und ein Exit ≠ 0 mit
  gehaltener apt-Sperre (`isAptLocked`, §2) = „Paketlisten nicht aktualisiert
  – auf dem Pi läuft gerade eine andere Paketinstallation …" — der Lauf hat
  dann nie begonnen. `_sudoCommand` gibt dafür das `CommandResult` zurück.
  **Detailzeile der System-Karte** (`systemUpdateDetail`): „N Updates
  verfügbar" / „aktuell" / „Paketlisten N Tage alt — Stand unbekannt" /
  „Paketlisten-Stand unbekannt" — und als eigener Fall „Update-Prüfung
  fehlgeschlagen — Stand unbekannt", wenn die Simulation keine
  Zusammenfassungszeile lieferte: Dann sind nicht die Paketlisten das Problem
  (ein frischer Index las sich als „Paketlisten 0 Tage alt"), und
  „Paketlisten aktualisieren" hülfe nicht. `aptSimulationError` holt apts
  erste Fehlerzeile dafür ins Log.
- **`stack_wiring.dart`** (v0.66.0) — verdrahtet den Monitoring-Stack in
  **einem** Root-Skript (Marker `WIRE_OK`): InfluxDB-Setup (Org `pi-tool`,
  Bucket `evcc`; Admin-Passwort wird AUF dem Pi generiert), Token via
  `influx auth create --json`, `influx:`-Block in `evcc.yaml` (nur wenn keiner
  existiert; Backup + automatischer Rückbau, falls evcc den Restart verweigert),
  Grafana-Provisioning (Flux-Datasource `pitool-influx` + Dashboard
  `grafanaEvccDashboardJson`, gequotetes Heredoc). **Invariante: das Token
  verlässt den Pi nie** — deshalb ein Skript statt mehrerer Runden; nichts
  App-seitiges wird interpoliert. Fehlendes Grafana/`evcc.yaml`
  = Skip mit Meldung (Fälle unten); handeingerichtetes InfluxDB ohne
  Root-CLI-Config = ehrlicher Fehler. Einstieg: Grafana-Karte ⋮ → „Mit evcc verdrahten".
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
  übersprungen — Fälle unten).
  `wireMonitoringStack` gibt entsprechend `StackWiringOutcome.wired|partial`
  zurück, die UI meldet Teilerfolg **amber statt grün** — sonst stünde ein
  grünes „verdrahtet" über einem dauerhaft leeren Dashboard. Ebenfalls dort:
  Docker-evcc wird an `systemctl cat evcc` erkannt (früher als „Konfiguration
  abgelehnt" fehlgedeutet), ohne gelungenes Backup wird die `evcc.yaml` gar
  nicht angefasst, und nach dem Restart wird 5 s gewartet, weil
  `Restart=always` einen Absturz sonst als „active" maskiert.
  **Wiederholter Lauf und eigener Block:** Der Block, den die Verdrahtung
  schreibt, beginnt mit `evccInfluxBlockMarker`. Steht diese Zeile direkt über
  `influx:` (Shell-Funktion `own_block`, dieselbe Bedingung wie in der
  Rücknahme), zählt evcc als verdrahtet — weitere Läufe enden in `WIRE_OK`,
  ohne evcc.yaml oder evcc anzufassen. Ein `influx:`-Block ohne Marker ist der
  eigene des Nutzers und zählt nicht.
  **Token erst beim Schreiben** (`make_token`): Es entsteht unmittelbar, bevor
  evcc.yaml oder die Grafana-Datenquelle geschrieben wird, einmal für beide;
  scheitert das, endet der Lauf mit `WIRE_FAIL`, bevor eine Datei angefasst
  ist. Ein Lauf ohne Schreibstelle legt so kein unbenutztes Token in InfluxDB
  ab. Ist Grafana installiert, wird die Datenquelle weiter bei jedem Lauf mit
  einem frischen Token überschrieben.
  **Fälle für `WIRE_PARTIAL`:** evcc ohne systemd-Unit (Docker-evcc, mit oder
  ohne `/etc/evcc.yaml`), ein eigener `influx:`-Block des Nutzers, kein
  Grafana — und ein apt-evcc **ohne `/etc/evcc.yaml`** (Konfiguration über die
  evcc-Weboberfläche): Dort wird bewusst keine evcc.yaml angelegt (wie evcc
  eine neue Datei neben dieser Konfiguration behandelt, ist nicht gemessen);
  die Meldung nennt URL, Org und Bucket. Alle „selbst eintragen"-Fälle hängen
  `token_hint` an (Token in der InfluxDB-Weboberfläche anlegen, das Passwort
  für `pitool` vorher auf dem Pi setzen) — das Token der Verdrahtung wird
  weiterhin nie ausgegeben.
  **Ablehnung „Block aus einem anderen Backup":** Trägt die evcc.yaml den
  markierten Block, fehlt aber `/root/.influxdbv2/configs`, und hat evcc eine
  systemd-Unit, endet das Skript **vor** `influx setup` mit zwei
  Meldungszeilen und `WIRE_FAIL`, ohne etwas zu ändern. Hintergrund: Das
  evcc-Backup enthält die evcc.yaml; nach einem Restore auf einem neu
  aufgesetzten Pi oder nach dem Umzugshelfer gehört das Token im Block zu
  einer anderen Datenbank — als „bereits verdrahtet" gezählt stünde `WIRE_OK`
  über einem evcc, das nichts schreibt. Die Prüfung steht vor dem Setup, weil
  der Fall danach von einem echten zweiten Lauf nicht mehr zu unterscheiden
  ist.
- **Umzugshelfer** (v0.66.0, `_migrateToOtherPi` in main.dart — reine
  Orchestrierung vorhandener Bausteine, kein neues Skript): frische Backups
  auf dem Quell-Pi (`backup` + `backupPihole`) → `downloadFile` aufs Handy →
  auf dem Ziel-Profil `detectServices`, fehlendes installieren (`install`/
  `installPihole`) → `uploadFile` an die erwarteten Backup-Pfade →
  `restoreBackup`/`restorePiholeBackup`. Quell-Pi bleibt unangetastet; nur
  apt-evcc zieht um (Docker-evcc hat hier keinen Restore-Pfad). System-Karte ⋮,
  Pro-gated. Braucht ein zweites Profil mit Host.
  **Pi-hole v5 zieht nicht um:** Ist das Backup der Quelle kein `.zip` (ein
  v5-`.tar.gz` lässt sich nur über die Pi-hole-Weboberfläche importieren),
  endet der Lauf mit `errorMigratePiholeV5`, **bevor** am Ziel Pi-hole
  installiert wird — sonst stünde dort ein frisches Pi-hole ohne die Daten
  und hinter einem Passwort. evcc ist zu diesem Zeitpunkt schon umgezogen.
  Wurde Pi-hole am Ziel neu installiert, das Backup aber nicht eingespielt,
  zeigt der Helfer nach dem Guard einmalig das Web-Passwort des Ziels
  (`_showPiholePassword(pw, onPi:)`); nach gelungenem Restore nicht — der
  ersetzt die ganze Konfiguration samt Passwort durch die der Quelle. Eine
  unvollständige Erkennung des Ziels (kein Endmarker, §3) beendet den Lauf,
  bevor dort etwas installiert wird. Der Monitoring-Stack zieht nicht mit um;
  bringt die evcc.yaml den InfluxDB-Block der alten Verdrahtung mit, lehnt
  die Verdrahtung am Ziel ihn ab und nennt im Log, was zu löschen ist (s. o.).
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
  `test/service_links_test.dart` (jede Karten-id braucht einen Eintrag; **jedes
  `appPackage` muss in `<queries>` des Manifests stehen** — ohne Eintrag liefert
  `getLaunchIntentForPackage` ab Android 11 `null`, und „Offizielle App" landete
  trotz installierter App immer im Play-Eintrag).
  In derselben Datei baut die reine Funktion **`piWebUrl`** jede
  „Web öffnen"-Adresse der Karten — also die Oberfläche auf dem Pi, nicht die
  Projekt-Links — über `Uri`: Ein IPv6-Literal bekommt die eckigen Klammern;
  einen Host oder Port, den `Uri` nicht nimmt, reicht sie wie getippt weiter
  (das Öffnen scheitert dann sichtbar, ein Wurf aus einem Knopf täte das
  nicht). Pi-hole-Links sind immer `http`; `_uiScheme` (der HTTPS-Schalter der
  Einstellungen) gilt nur für evcc. Geöffnet wird über den Seam
  `UpdaterPage.urlOpener` (Default `url_launcher`, externe Anwendung);
  `_openUrl` meldet `snackCouldNotOpenLink` auch für eine Adresse, die sich
  nicht parsen lässt.
- **`apt_services.dart`** — Grafana/InfluxDB/Mosquitto. **Supply-Chain:**
  InfluxDB prüft den GPG-**Fingerprint** vor dem Vertrauen; Grafana speichert den
  armored Key ohne dearmor (aktueller offizieller Flow).
  **InfluxDB nur 64-Bit** (v0.71.0): InfluxDatas Repo führt `influxdb2` für
  arm64 und amd64, nicht für armhf. Der Guard steht vor Keyring und Quelle und
  lehnt mit `INSTALL_REFUSED: …` (Exit 3, §2) ab, wenn die 64-Bit-Architektur
  des **laufenden Kernels** (`uname -m` → arm64/amd64) weder dpkgs eigene noch
  eine Fremdarchitektur (`dpkg --print-foreign-architectures`) ist. Bewusst
  enger als „armhf ablehnen": die 32-Bit-Images von Raspberry Pi OS tragen
  arm64 seit Bookworm als Fremdarchitektur ein, apt kann dort `influxdb2:arm64`
  nehmen (hängt nur an curl, `influxd` ist ein statisches Binary). Abgelehnt
  wird nur, was nicht laufen kann: ein 32-Bit-Kernel oder ein dpkg ohne
  64-Bit-Architektur. Eine nicht lesbare dpkg-Architektur ist keine Ablehnung.
  Dass die Installation über die Fremdarchitektur tatsächlich durchläuft, ist
  an keinem Pi gemessen.
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
  **Auch das Backup wählt die Generation nicht per Exit-Code** (v0.71.0,
  `buildPiholeBackupScript` und der Timer-Wrapper in §5): v6 beantwortet
  `pihole -a -t` mit seinem Hilfetext und Exit 0 und schreibt nichts — der
  Rückfall `… || pihole-FTL --teleporter` wurde so nie erreicht. Deshalb läuft
  zuerst die v5-CLI, und `pihole-FTL --teleporter` nur, wenn danach **kein
  `*.tar.gz` entstanden ist**. Im manuellen Backup (Skript auf stdin) bekommen
  beide Aufrufe ihr eigenes `</dev/null`.
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
  und überschreibt sie). Im Umzugshelfer wird das Passwort nur angezeigt, wenn
  der Teleporter-Restore am Ziel nicht stattfand — sonst bringt der die
  Einstellungen der Quelle samt Passwort mit (s. o. „Umzugshelfer").
- **`homeassistant_service.dart`** — HA als Docker-Container (bewusst, nicht HA
  OS). tar-Exit 1 auf laufendem HA = Warnung (nur rc>1 = Fehler). Restore per
  `trap` (Container kommt auch bei tar-Fehler zurück); vor `RESTORE_OK` muss
  `{{.State.Status}}|{{.RestartCount}}` exakt `running|0` sein.
  Der Trap wird **vor** `docker stop` gesetzt: Ein Abbruch schließt den Kanal,
  `docker stop` stoppt den Container noch und stirbt beim Schreiben seines
  Namens (SIGPIPE), `set -e` beendet das Skript genau dort — mit dem Trap erst
  nach dem Stop bliebe HA aus (und wegen `--restart=unless-stopped` auch über
  Neustarts hinweg). Der Trap-String ist **einfach gequotet** und liest den
  Containernamen aus der Variablen `ha_name`. **Regel:** Ein mit
  `shSingleQuote` gequoteter Wert gehört nie in einen doppelt gequoteten
  String — dort würden `$(…)` und Backticks schon beim Setzen des Traps
  ausgewertet, was immer `shSingleQuote` darum gelegt hat.
  **Backup:** tar läuft mit `--exclude=./backups --exclude=./tmp_backups`
  (Home Assistants eigene Backups — jedes enthält die Konfiguration und, wenn
  dort nicht abgeschaltet, die Datenbank noch einmal). Der Container wird
  weder gestoppt noch pausiert; die Recorder-Datenbank
  `home-assistant_v2.db` wird im laufenden Betrieb kopiert und kann im Archiv
  inkonsistent sein. Beides steht als zwei Zeilen im Log, vor tar. Archive
  aus älteren Versionen enthalten `backups/` noch; ihr Restore ist
  unverändert. Zu den Rechten des Archivs: §5 „Backups sind bewusst 0644".
  **Fortschritt** (`_haTarProgress`, in Backup und Restore):
  `--checkpoint=25600 --checkpoint-action=exec='echo "Home Assistant: … MiB
  verarbeitet"'` — eine Zeile je 250 MiB Archivdaten vor der Kompression,
  damit das Inaktivitäts-Timeout (§1) ein arbeitendes tar nicht abschneidet.
  Bewusst `exec` statt `echo`: Mit `echo` schreibt tar selbst auf den
  SSH-Kanal; ist der weg (Abbruch, Verbindungsverlust), wird tar mitten im
  Entpacken per SIGPIPE beendet bzw. endet mit Status 2. Mit `exec` scheitert
  nur die Kind-Shell, und tar endet wie ohne die Option. **Regel: tar in
  diesen Skripten nie direkt auf den Kanal schreiben lassen.** Nur diese
  beiden tar-Aufrufe melden Fortschritt; die des evcc-Backups und -Restores
  (`commands.dart`) und der Timer-Wrapper sind weiter still.
  **Install nur 64-Bit** (v0.71.0): Home Assistant veröffentlicht seinen
  Container nur für arm64 und amd64 (32-Bit-Builds endeten mit 2025.12), und
  Docker zieht für die Architektur des installierten Systems — ein 64-Bit-Kernel
  unter einem 32-Bit-Raspberry-Pi-OS hilft nicht. Das Install-Skript lehnt
  deshalb auf jeder anderen dpkg-Architektur mit `INSTALL_REFUSED: …` (Exit 3,
  §2) ab, **bevor** Docker installiert wird. Nicht abgelehnt: eine unbekannte
  Architektur (kein dpkg) und ein System, das schon einen Container
  `homeassistant` hat — mit dem verfährt das Skript wie bisher (läuft er,
  passiert nichts; ist er gestoppt, wird er gestartet).
  **Zeitzone:** `TZ` des neuen Containers ist die Zone des Pi — aus
  `readlink /etc/localtime` (der Teil hinter `zoneinfo/`), sonst aus
  `/etc/timezone`, sonst UTC; zulässig sind nur `[A-Za-z0-9_+/-]` ohne
  führenden Slash. Bewusst ohne `timedatectl` und mit dem Link vor
  `/etc/timezone`. Das Skript loggt „Zeitzone des Containers: …". Gesetzt
  wird sie einmal, hier: Ein Update legt den Container mit der Umgebung neu
  an, die er schon hat (`Config.Env`).
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
  läuft **detached** (`setsid … &`, sleep, cat) — sonst hängt der SSH-Call.
  Seine Ausgabe geht in eine **private Temp-Datei** (`mktemp` unter
  `umask 077` — kein fester Name, den ein anderes Konto lesen oder vorab
  belegen könnte) und wird nach dem Ausgeben gelöscht; der detachte Sign-in
  behält seinen offenen Deskriptor. Grund: Wer die Verify-URL öffnet,
  verknüpft den Pi mit seiner eigenen Raspberry Pi ID. Die frühere feste Datei
  `/tmp/pi-tool-signin` wird nicht mehr geschrieben; die Deinstallation räumt
  sie als Altlast weiter weg. Doku
  deckt Headless-/SSH-Verhalten nicht ab → Parser tolerant, **Gerätecheck nötig**.
  `on`/`off`/`signout` werten den Exit-Status aus (§2): fehlt er, ist das
  Ergebnis unbekannt; ein Exit ≠ 0 steht bislang nur als Hinweis im Log.
- **Karten-Regel „der Knopf zeigt, was als Nächstes dran ist"** (v0.64.2): Steht
  ein Update an, ist `actionUpdate` der **Primär-Knopf** — auch auf Pi Connect
  und Tailscale, deren Primär sonst am Anmelde-/Verbindungszustand hängt. Die
  verdrängte Aktion wandert ins ⋮ und kommt danach zurück. Vorher lag das Update
  dort nur als `_CardAction`, sichtbar allein an der ambernen LED — zu leise
  (real übersehen: Pi Connect 2.12.1 → 2.12.2 hinter „Web öffnen").
  **Gegenstück `primaryIsUpdate`** (`_ServiceCard`, Default `true`): Das
  deaktivierte „Aktuell" ersetzt den Primär-Knopf nur dort, wo dieser Knopf das
  Update **ist**. Pi Connect und Tailscale übergeben `s.updateAvailable`, die
  erkannten systemd-Dienste (Primär = Neustart) `false` — ohne anstehendes
  Update bleibt dort die Zustands-Aktion der Primär-Knopf. Sonst verschwände bei
  frischem apt-Index und ohne Update genau die Aktion, um die es geht:
  „Anmelden" bzw. „Verbinden"/„Trennen" wären nirgends erreichbar (der Zustand
  direkt nach einer Installation über die App).
- **`tailscale.dart`** — VPN/Mesh, **System-Service** (einfacher als Pi Connect).
  Install = offizieller Installer (`curl … | sh`) unter **`set -o pipefail`**
  (sonst zählt nur der Exit von `sh`: fehlendes curl/abgebrochener Download =
  leeres Skript, Exit 0, Marker = Phantom-Erfolg); der Marker folgt erst nach
  `command -v tailscale`. Tote EOL-Quellen stellt vorher `_fixEolSources` um.
  `up` detached (Login-URL). down/logout via sudo.
  **„Trennen" und „Abmelden" über eine Tailnet-Sitzung werden abgelehnt**
  (`tailscaleSet`): dieselbe Vorprüfung wie beim Deinstallieren —
  `isTailnetHost(host)`, dann `tailscaleSessionProbe`/`isTailnetClient` auf
  dem nicht-sudo gelesenen `$SSH_CONNECTION` (greift auch unter der
  Heimnetz-Adresse, wenn der Pi das Heimnetz freigibt) — mit einer Meldung,
  die die Aktion nennt; ausgeführt wird nichts. Ein Logout kappte genau diese
  Sitzung und nähme den Pi aus dem Tailnet; `tailscale down` lehnt das CLI in
  dem Fall selbst ab („aborted, no changes made"), was vorher als „Exit 1"
  ankam.
  **„Verbunden" ist der Backend-Zustand, nicht die Adresse** (v0.71.0,
  `parseTailscaleStatus(out, self: …)`): `tailscale ip -4` druckt die Adresse
  aus der letzten Netzkarte, egal in welchem Zustand das Backend ist, und
  `tailscale down` behält diese Karte — ein gestoppter Knoten hat sein 100.x
  noch (die Karte blieb nach „Trennen" auf „Verbunden · 100.x" und bot weiter
  „Trennen" an). Maßgeblich ist `BackendState` aus der ohnehin gelesenen Probe
  `TS_SELF` (`tailscale status --json --peers=false`; der Batch ist
  unverändert): **`Running` und `Starting` = verbunden** (`Starting` ist ein
  `tailscale up`, das gerade greift — der Zustand, den das Up-Skript schon als
  verbunden meldet; ein Pi ohne Internet bleibt dort, während er es weiter
  versucht), **`NeedsLogin` = „Nicht angemeldet"** (`needsLogin`; „Verbinden"
  führt dort zu einem Login), jeder andere Zustand = „Getrennt". Nur ohne
  `BackendState` (Client zu alt für die Probe, Daemon antwortet nicht)
  entscheidet wie früher die Adresse. Ein Knoten, der `Running` ist, aber keine
  IPv4-Adresse nennt, steht als „Verbunden" ohne Adresse da.
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
  sein, der Rest nur präfixförmig). Das frische Lesen (`_readRouteState`)
  zählt nur **mit Endmarker** (§3): Nicht lesbare Prefs gelten als „nichts
  angeboten", und das folgende Root-Skript schreibt die Routenliste neu — aus
  einem abgeschnittenen Lesen fielen von Hand gesetzte Routen und ein
  Exit-Node weg. Ohne Endmarker endet die Aktion mit „Ergebnis unbekannt",
  bevor etwas geändert ist. Die sysctl-Datei trägt als Merker
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
  **Router-Standardbereiche:** `routerDefaultSubnets` (Fritzbox `192.168.178.0/24`,
  `192.168.0.0/24`, `192.168.1.0/24`, Speedport `192.168.2.0/24`) und
  `routerDefaultRoutes(routes)` — nur der exakte /24. Ist ein freigegebener
  (`RouteShare.active`/`pending`) bzw. ein freizugebender Bereich darunter,
  steht der Hinweis `tsLanSameRange[Evcc]` auf der Karte und in beiden Dialogen
  (`_tailscaleShareLan`, `_offerLanShare`): Aus einem Netz mit demselben Bereich
  geht die Adresse je nach Betriebssystem des Geräts nicht in den Tunnel
  (belegt am 25.09.2026 mit einem iPhone; deshalb „unter Umständen").
  **evcc über das Tailnet:** `evccTailnetUrl(scheme, tailnetIp, port)` baut die
  Adresse der evcc-Oberfläche auf der 100.x des Pi (nur IPv4 aus 100.64.0.0/10,
  sonst null; leerer Port = 7070) aus `_uiScheme`/`_uiPort`. Die Karte zeigt sie
  bei verbundenem Tailscale + installiertem evcc; ⋮ „evcc-Adresse teilen"
  reicht sie über den Seam `UpdaterPage.textSharer` (Default `share_plus`) an
  das Teilen-Blatt — frei, kein Pro-Schalter, kein SSH (also ohne
  `_prepare`/`_guard`), im Demo-Modus ausgeblendet. Lange Hinweise stehen in
  `_ServiceCard.notes` (ohne Zeilengrenze; `liveLines` kürzt nach
  `liveMaxLines`).
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

## 5. On-Pi-Automatik (`auto_update.dart`, `alerts.dart`, `on_pi_wrapper.dart`, `files.dart`, `notifications.dart`)

**Kern-Entscheidung:** Automatik läuft als **systemd-Timer auf dem Pi**, *kein*
Android-Hintergrunddienst (v0.20.0-Absturz-Lektion). Reine Builder → POSIX-Shell.

- **`auto_update.dart`** — geplante apt-Updates (`pi-tool-autoupdate.timer`).
  Der Wrapper (`#!/bin/bash`, `DEBIAN_FRONTEND=noninteractive`) sichert evcc
  vorher und aktualisiert dann **mit den Bausteinen einer Pi-Job-Payload**
  (`aptBuildingBlocks()` aus `pi_job.dart`: EOL-Quellen umstellen, das
  Optionen-Array `O` mit `Use-Pty=0`, `DPkg::Lock::Timeout=300` und
  `--force-confdef/--force-confold` (kein conffile-Hänger),
  `pitool_wait_apt_locks`, `pitool_repair`): Reparaturkette → `apt-get update`
  mit `APT::Update::Error-Mode=any` → `apt-get full-upgrade`. **Wer diese
  Bausteine in `pi_job.dart` oder `eol_sources.dart` ändert, ändert den
  Wrapper — `wrapperGeneration` erhöhen.** Danach **self-heal** (startet evcc
  neu, falls es vorher lief und danach nicht mehr) und die Statuszeile.
  Marker `AUTOUPDATE_INSTALLED/REMOVED`.
  Die evcc-Sicherung vor dem Upgrade (`autoupdate-evcc-<zeit>.tar.gz` unter
  `/var/backups/pi-tool`, nur wenn das Paket evcc installiert ist) folgt
  denselben Regeln wie der Backup-Wrapper (nur vorhandene Pfade, tar-Exit 1
  zählt, `.part` → `mv`, Rotation auf 5 nur nach Erfolg). Statuszeile
  `/var/lib/pi-tool/autoupdate.status`:
  `<zeit> ok|fehler(rc=N)[; paketlisten-fehler(rc=N)][; evcc-neustart][; backup-fehler(rc=N)]`
  — `ok`/`fehler` für das Upgrade, **`paketlisten-fehler`**, wenn die
  Paketlisten nicht (alle) geladen wurden (das Upgrade lief dann gegen alte
  Listen; „ok" verschwiege sonst, dass nichts Neues geprüft wurde),
  `evcc-neustart` nach einem Self-Heal und **`backup-fehler`**, wenn die
  Sicherung vor dem Upgrade nicht geschrieben werden konnte.
  **Weitere Dateien auf dem Pi:** `/var/lib/pi-tool/autoupdate.log` (0600
  root, die letzten 200 Zeilen des jüngsten Laufs, mit jedem Lauf ersetzt —
  die Ursache hinter einem `fehler(rc=N)`; nur root, weil apt die
  Paketquellen nennt und eine Quelle Zugangsdaten tragen kann; im Dateien-Tab
  lesbar, weil der mit sudo liest) und `/var/lib/pi-tool/autoupdate.setup`
  (Epoch-Sekunden der letzten Einrichtung, s. u.).
  **Unit:** `Wants=`/`After=network-online.target` (ein nach dem Boot
  nachgeholter Lauf startete sonst vor dem Netz), `KillMode=mixed`,
  `TimeoutStopSec=30min`; der Wrapper hat einen SIGTERM-Handler (bewusst kein
  `trap '' TERM` — ein ignoriertes Signal erbten apt, dpkg und alles, was ein
  Maintainer-Skript startet). Ein `systemctl stop` oder ein Neustart während
  eines Laufs signalisiert so nur den Wrapper und gibt ihm bis zu 30 Minuten,
  statt apt und dpkg sofort zu beenden — dasselbe Muster wie der
  Pi-Job-Wrapper (s. u.). Folge: Ein Reboot oder Shutdown wartet in dieser
  Zeit auf den Lauf, und der Pi ist so lange nicht erreichbar. Der Handler ist
  in der Sandbox geprüft; dass systemd tatsächlich so lange wartet, ist aus
  dessen Dokumentation abgeleitet und **nicht an einem Pi gemessen**. Aus der
  App heraus werden Neustart und Herunterfahren währenddessen abgelehnt (§2),
  und der Pi-Job-Launcher meldet BUSY.
  **Einrichten startet nie sofort ein Upgrade:** Ein `Persistent=true`-Timer
  feuert beim Start sofort, wenn seit seinem letzten Lauf einer fällig war —
  nach einer Pause, oder wenn die neue Uhrzeit zwischen letztem Lauf und
  jetzt liegt. Das Install-Skript löscht deshalb systemds Stempel
  (`timerStampPath`) und stoppt den Timer **vor** dem `daemon-reload` (der
  Stempel zuerst: lässt er sich nicht löschen, läuft der alte Timer weiter),
  und es schreibt seine eigene Zeit nach `autoupdate.setup`. Der Wrapper tut
  nichts, wenn er binnen fünf Minuten danach gestartet wird (genug für einen
  Start, der erst auf `network-online` wartet; ein in diese Minuten geplanter
  Lauf entfällt ebenfalls). Was systemd nach dem Löschen des Stempels wirklich
  tut, unterscheidet sich zwischen seinen Versionen und ist **nicht an einem
  Gerät gemessen** — deshalb die zweite Sicherung im Wrapper.
  `buildAutoUpdateInstallScript` prüft `onCalendar` mit `checkOnCalendar`.
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
  Die Archive — `sched-evcc-<zeit>.tar.gz` und `sched-pihole-<zeit>.zip` bzw.
  `.tar.gz` unter `/var/backups/pi-tool` — stehen in den Backup-Listen der
  evcc- und der Pi-hole-Karte und lassen sich dort wiederherstellen,
  herunterladen und löschen (§3 „Backup-Listen", „evcc-Restore"; ein
  Pi-hole-v5-`.tar.gz` bleibt Sache der Pi-hole-Weboberfläche). Das
  evcc-Archiv des Timers enthält `/etc/evcc.yaml` und ganz `/var/lib/evcc`;
  eine Datenbank außerhalb davon (eigener `dsn`, altes `/root/.evcc`) ist
  nicht darin. `buildScheduledBackupInstallScript` prüft `onCalendar` mit
  `checkOnCalendar`.
  **Wrapper-Regeln (seit v0.71.0 unverändert, also seit Generation 2):**
  - **tar bekommt nur vorhandene Pfade** (Positionsparameter): Das evcc-Paket
    liefert keine `/etc/evcc.yaml` — ein in der Weboberfläche eingerichtetes
    evcc hat nie eine —, und **ein** Pfad, den tar nicht findet, lässt das ganze
    Archiv scheitern (Exit 2, die Statuszeile sagte trotzdem „ok").
  - **tar-Exit 1** („file changed as we read it", evcc läuft weiter) zählt als
    geschriebenes Archiv; erst Exit ≥ 2 ist ein Fehler.
  - **Pi-hole nicht per Exit-Code** (§4 `pihole_service.dart`): erst die
    v5-CLI, `pihole-FTL --teleporter` nur, wenn kein `*.tar.gz` entstand. Ist
    Pi-hole da, aber nichts entstanden, steht `pihole(kein-archiv)` im Status.
  - **Statuszeile nennt Fehler zuerst** und wird in der App unverändert
    angezeigt: `<zeit> ok: evcc pihole`, `<zeit> ok: nichts` (nichts zu sichern)
    oder `<zeit> fehler: evcc(tar-rc=2); ok: pihole`. Fehler-Kürzel:
    `evcc(tar-rc=N)`, `pihole(kein-archiv)`, `pihole(nicht-gespeichert)`.
- **`alerts.dart`** — 30-Min-Health-Check → **ntfy**-Push (backend-frei) bei
  Platte ≥90% / Temp ≥75° / totem Dienst / anstehenden Updates.
  **Debounce nach Problemklasse:** `alerts.last` hält den md5 der **Klassen**
  `disk`, `temp`, `ro`, `ioerr`, `svc:<name>`, `updates` — nicht des
  Meldungstexts. Ein Wert, der sich oberhalb seiner Schwelle bewegt (91 → 93
  Prozent, 3 → 5 Updates), ist dasselbe Problem und pusht nicht erneut;
  gepusht wird, wenn sich die **Menge** der Probleme ändert.
  **Dienste** gelten als aus bei `failed` und `inactive`, bei `activating` nur
  mit `SubState=auto-restart` — ein Dienst, der gerade startet (Neustart,
  bootender Pi), ist kein Ausfall, einer, den systemd immer wieder neu
  startet, schon.
  **`alerts.last` wird nur nach
  zugestelltem Push geschrieben** (v0.71.0; `curl -fsS --connect-timeout 10
  --max-time 30 … -- "$URL/$TOPIC"` — `-f` macht einen HTTP-Fehler zum
  Exit-Code, `--` steht vor der URL): ein
  gescheiterter Push (kein DNS/Internet, HTTP-Fehler) wird beim nächsten Lauf
  erneut versucht, statt als gesendet zu gelten; die Zeitlimits begrenzen die
  oneshot-Unit, die kein eigenes Start-Timeout hat. Das Install-Skript löscht
  `alerts.last` — ein neues Ziel hat von den aktuellen Problemen noch nichts
  gehört.
  **Die Paketlisten frischt der Wrapper selbst auf** — „N Updates verfuegbar"
  zählt gegen den lokalen Index, und den erneuert auf einem Standard-Pi
  niemand (§4): als **letzter** Schritt (so kann er einen Push weder verzögern
  noch verlieren), wenn `/var/lib/apt/lists` älter als 24 h ist, höchstens
  einmal je 24 h (`/var/lib/pi-tool/alerts.aptupdate` markiert den Versuch,
  was immer daraus wurde), mit `timeout -k 10 120 apt-get -o
  DPkg::Lock::Timeout=0 update -qq` (gibt sofort auf, statt sich hinter einen
  anderen apt-Lauf zu stellen). Ein sauberer Lauf stempelt
  `/var/lib/apt/lists` wie `systemAptRefreshCommand`, die Karten der App sehen
  den Refresh also auch; die nächste Prüfung zählt gegen die neuen Listen.
  **ntfy-Server:** nur `http`/`https`. Ohne Schema wird `http://`
  vorangestellt (was curl für so einen Wert annimmt — ein Ziel, das heute
  funktioniert, funktioniert weiter); jedes andere Schema und ein leerer Wert
  sind ein `ArgumentError` in `buildAlertsInstallScript` und
  `buildTestAlertCommand`, dessen Text den Wert **nicht** enthält (er wird
  geloggt, und das Feld kann Zugangsdaten oder einen `ntfy://`-Link samt Topic
  tragen).
  Die Test-Nachricht (`buildTestAlertCommand`, `curl -fsS --max-time
  15`) entfernt Leerraum aus Server und Topic und prüft den Server wie das
  Install-Skript und wird am Exit-Status gemessen (§2).
  **Das Ziel steht nicht im Wrapper** (Regel in `on_pi_wrapper.dart` unten):
  ntfy-Server und -Topic liegen in **`/usr/local/lib/pi-tool-alerts.conf`**
  (`alertsDestinationPath`; root, 0600, unter `umask 077` in einem eigenen
  Heredoc geschrieben). Der Wrapper liest die Datei per `.` ein, das
  Remove-Skript löscht sie mit. **Heredoc-Regel**: ntfy-Server/-Topic
  sind `shSingleQuote`d und landen in einem **quoted** Heredoc (`<<'WRAP'`) → kein
  Install-Zeit-Expand von `$(reboot)`. Das Install-Skript hat drei solche
  Blöcke (Wrapper-Kopf, `.conf`, Wrapper-Rumpf) — nie zusammenlegen/entquoten.
  **Topic-Invariante (v0.63.0):** ntfy kennt kein Konto — das Topic *ist* das
  Passwort, wer es errät liest den Health-Feed mit. Deshalb `generateNtfyTopic()`
  (`pi-tool-` + 14 Zeichen aus einem 31er-Alphabet ohne Verwechsler `0/o`,
  `1/l/i` ≈ 69 Bit, `Random.secure`), ein Würfel-Button würfelt neu, und
  `isWeakNtfyTopic()` (< 16 Zeichen oder
  < 8 verschiedene Zeichen) markiert erratbare Namen im Sheet **und** als
  Warnzeile auf der Automatik-Karte (`_AutomationTile.warning`, beurteilt am
  Topic des aktiven Pi) — Bestandsnutzer
  öffnen das Sheet sonst nie wieder. Beides rein/testbar; nie durch ein
  Freitext-Feld ohne Vorbelegung ersetzen.
  **Das Topic gehört zum Pi, nicht zur App** (`Profile.alertsNtfyServer`/
  `alertsNtfyTopic`, §6). Vorbelegung des Sheets: der Wert des Profils, sonst
  der app-weite Altwert (`effectiveNtfyDestination`), sonst — wenn der Pi
  Alerts als aktiv meldet, die App aber kein Topic für ihn kennt (von einem
  anderen Gerät oder vor einer Neuinstallation eingerichtet) — **leer mit
  Hinweis** (`wAlertsTopicUnknown`; ein erfundenes Topic neben „aktiv" ginge
  als das des Pi durch), sonst ein generiertes. Gespeichert wird im Profil
  **vor** der Installation (das Topic, an das der Pi von da an pusht, darf
  nicht verloren gehen, wenn die App mittendrin verschwindet); im Demo wird
  nichts ins Profil geschrieben. In den Log-Zeilen von Test-Push und
  Installation ist das Topic maskiert (`_maskNtfyTopic` in `main.dart`).
- **Remove-Skripte der drei Timer** (`buildAutoUpdateRemoveScript`,
  `buildScheduledBackupRemoveScript`, `buildAlertsRemoveScript`) laufen unter
  **`set -e`**: ein scheiterndes `rm` (Root nur-lesend) endet ohne Marker, statt
  „entfernt" zu melden. Nur das `systemctl disable --now` davor ist tolerant.
  Alle drei löschen auch **systemds Stempel des Timers** (`timerStampPath` =
  `/var/lib/systemd/timers/stamp-<unit>.timer`): Bliebe er liegen, startete
  ein später wieder eingerichteter `Persistent=true`-Timer seinen Job im
  Moment des Einrichtens. Der Stempel wird nur gelöscht, nie per `touch`
  angefasst — seine mtime bedeutet „letzter Lauf". Von den
  **Install**-Skripten löscht ihn nur das der automatischen Updates (s. o.);
  die von Alerts und Backup lassen einen laufenden Timer in Ruhe.
- **`on_pi_wrapper.dart`** (v0.71.0) — **Generations-Stempel der
  On-Pi-Wrapper**. Ein Wrapper (`/usr/local/lib/pi-tool-autoupdate.sh`,
  `…/pi-tool-backup.sh`, `…/pi-tool-alerts.sh`) wird beim Einrichten seines
  Timers auf den Pi geschrieben und **bleibt dort**: Eine Korrektur in der App
  erreicht einen Pi erst, wenn dieser Timer neu eingerichtet wird. Deshalb:
  - Jeder Wrapper trägt als **zweite Zeile** (direkt nach dem Shebang)
    `wrapperStampLine` = `# pi-tool-wrapper <wrapperGeneration>`. Aktuell
    Generation **3**. Generation 2 = v0.71.0 (tar nur mit vorhandenen Pfaden,
    Pi-hole-Export nicht per Exit-Code, Statuszeile nennt Fehler, Alerts erst
    nach Zustellung gemerkt). Generation 3 = Alerts-Wrapper mit eigenem
    Paketlisten-Refresh, Debounce nach Problemklasse und Ziel aus der
    Root-Datei; Auto-Update-Wrapper mit den Pi-Job-Bausteinen,
    Paketlisten-Meldung, Log, SIGTERM-Handler und der Sperre direkt nach dem
    Einrichten. Der Backup-Wrapper ist seit 2 unverändert — **die Nummer ist
    geteilt**, sein Sheet zeigt nach einem App-Update also denselben Hinweis.
    Wrapper von vor v0.71.0 tragen keinen Stempel.
  - Jede Status-Probe (`autoUpdateStatusCommand`,
    `scheduledBackupStatusCommand`, `alertsStatusCommand`) hängt
    `wrapperProbeHead` + Unit + `wrapperProbeTail` an und meldet eine Zeile
    **`WRAPPER current|old|none`** (`grep -qxF` auf die ganze Stempelzeile; ohne
    sudo, die Wrapper sind für alle lesbar).
  - `parseWrapperOutdated` → Feld **`wrapperOutdated`** in den drei
    Status-Records (`AutoUpdateStatus`, `ScheduledBackupStatus`,
    `AlertsStatus`). Nur `old` zählt: ein fehlender Wrapper oder eine Probe ohne
    die Zeile (unlesbare Datei, abgeschnittene Antwort) ist nicht „veraltet" —
    es gibt nichts zu erneuern bzw. nichts Bekanntes.
  - Das Sheet eines **aktiven** Timers mit älterem Wrapper zeigt
    `wrapperOutdatedHint` (Key `wrapperOutdatedHint`) und nennt den Knopf, der
    ihn erneuert („Zeitplan ändern", bei den Health-Alerts „Aktualisieren").
  - **Regel: `wrapperGeneration` erhöhen, sobald sich das Verhalten eines
    Wrappers ändert** (und im Kommentar der Konstante festhalten, was die
    Generation ausmacht) — sonst erfährt kein Bestands-Pi von der Korrektur.
    Das gilt auch für Änderungen an den apt-Bausteinen in `pi_job.dart` und
    an `eol_sources.dart`, die der Auto-Update-Wrapper einbettet.
  - **Regel: nichts Geheimes in einen Wrapper.** Weil die Status-Proben die
    Stempelzeile ohne sudo lesen, bleiben die Wrapper für alle lesbar. Was nur
    root sehen darf, bekommt eine eigene Datei — heute das ntfy-Ziel der
    Alerts (`pi-tool-alerts.conf`, 0600).
  - **`checkOnCalendar`** lässt nur die Zeitpläne durch, die die App baut
    (`[Ddd ]*-*-* HH:MM:SS`), sonst `ArgumentError`. Der Wert landet ungequotet
    in einer Timer-Unit innerhalb eines Heredocs eines Root-Skripts — ein
    Zeilenumbruch darin könnte den Heredoc beenden oder eine Direktive
    ergänzen; die Install-Builder der automatischen Updates und der geplanten
    Backups verlassen sich deshalb nicht allein auf ihre Aufrufer.
    **`timerStampPath(unit)`** nennt systemds Stempeldatei eines
    `Persistent=true`-Timers (s. o. „Remove-Skripte").
- **`files.dart`** — Datei-Browser über den normalen Exec-Kanal (kein SFTP → der
  `FakeSshRunner`-Seam deckt ihn ab).
  **Listen** (`buildListDirCommand`): `LC_ALL=C sudo -S -p '' find -H <dir>
  -mindepth 1 -maxdepth 1 -printf '%Y\t%f\0'` — ein Datensatz `<typ>\t<name>`
  je Eintrag, NUL-terminiert (ein Name darf alles andere enthalten, auch einen
  Zeilenumbruch) und ungetrimmt (getrimmt nennte er in den Pfaden von Öffnen
  und Löschen eine andere Datei). `%Y` ist der Typ **hinter** einem Symlink:
  Verlinkte Ordner wie `/bin` auf einem merged-usr-System lassen sich öffnen
  (`ls -p` markierte sie als Datei); `-H` folgt einem Link nur, wenn er das
  angefragte Verzeichnis ist. Meldungen von sudo und find bleiben auf stderr
  und können nie als Eintrag erscheinen. Braucht GNU find. `listDir` wirft bei
  abgelehntem sudo-Passwort, fehlendem Exit-Status und nicht lesbarem
  Verzeichnis; ein Exit ≠ 0 **mit** gelisteten Einträgen (find konnte einzelne
  nicht untersuchen, etwa einen FUSE-Mount, der root abweist) wird toleriert,
  finds Meldung geht ins Log.
  **Lesen** (`buildReadFileCommand`): `LC_ALL=C sudo -S -p '' bash -c 'set -o
  pipefail; head -c 524288 -- "$1" | base64' bash <pfad>` (Server-seitiges
  Limit gegen OOM bei riesigen Dateien). Mit `pipefail` ist ein gescheitertes
  Lesen (fehlt, ist ein Verzeichnis, I/O-Fehler) der Status des Befehls —
  vorher kam eine nicht lesbare Datei als leere an. bash, wie die
  Root-Skripte: nicht jedes `sh` (dash) kennt `pipefail`. `readFileBytes`
  wirft bei abgelehntem Passwort, fehlendem Exit-Status und Exit ≠ 0; ein
  leeres Ergebnis ist damit wirklich eine leere Datei.
  **Löschen** (`buildDeleteCommand`,
  `rm -f`/`-rf` mit `--` + Quoting) und **Upload** (`buildUploadScript`, base64 →
  `mktemp` im Zielordner → atomar `mv -fT`, Marker `UPLOAD_OK`, Limit
  `kFileUploadLimit` 8 MB, via
  `EvccUpdater.uploadFile`) laufen als Root. Upload-Regeln: Eine **neue** Datei
  gehört root, 0644. Eine **ersetzte** Datei übernimmt Besitzer und Modus
  (`chown`, dann `chmod --reference`) direkt von mktemps 0600 aus, nie über
  0644 — der neue Inhalt einer 0600-Datei (eine `.env` eines Dienst-Nutzers)
  wäre sonst zwischendurch für alle lesbar. Ein **Verzeichnis am Ziel wird
  abgelehnt** (Meldung, Exit 1, kein `UPLOAD_OK`; `mv -fT` als Rückfallnetz —
  ohne `-T` verschöbe `mv` die Temp-Datei hinein und meldete Erfolg).
  `trap 'rm -f "$tmp"' EXIT` räumt die Temp-Datei bei einem Fehlschlag weg.
  **Download**
  (`EvccUpdater.downloadFile`, ohne sudo — Backups sind bewusst 0644): erst
  `buildFileSizeCommand` (Abbruch VOR dem Transfer bei > `kBackupDownloadLimit`
  48 MB), dann `buildDownloadFileCommand` (base64) mit Längen-Verifikation
  (Truncation = Fehler). Aufs Handy via `fileSaver`-Seam (Default:
  `shareTemporaryFile` in `main.dart` — Temp-Datei über dart:io +
  share_plus-Teilen-Dialog, kein path_provider nötig). Die Temp-Datei wird
  gelöscht, sobald `share()` zurückkehrt, auch nach einem Fehler; die Kopie,
  die share_plus selbst in seinem Cache-Ordner anlegt, bleibt bis zum nächsten
  Teilen (laut dessen Quelltext, nicht gemessen) — ein heruntergeladenes
  Backup liegt dort unverschlüsselt.
  **„Backups sind bewusst 0644" — bekannte, bewusste Grenze beim
  Home-Assistant-Archiv:** Die Backup-Skripte der App legen ihre Archive 0644
  in einem 0755-Verzeichnis ab, damit der Download ohne sudo auskommt
  (`buildFileSizeCommand` und `buildDownloadFileCommand` lesen als
  SSH-Nutzer). Das gilt auch für das
  Home-Assistant-Archiv (`chmod 0644` in `buildHomeAssistantBackupScript`, bis
  zu fünf Generationen). Es enthält `/config` und damit `.storage/auth` — von
  Home Assistant selbst privat (0600) geschrieben, laut dessen Quelltext —
  sowie `secrets.yaml`; im Archiv kann beides jeder lokale Benutzer und
  Dienst-Account des Pi lesen. Ein 0600-Archiv bräuchte eine sudo-Variante
  des Downloads (neue Builder, Passwort auf stdin, Erkennung einer
  sudo-Ablehnung) und ist bewusst nicht umgesetzt.
  **Bearbeiten:** `isProbablyTextFile` (NUL-Byte oder >5 % C0-Control = binär;
  UTF-8-Umlaute zählen nicht) + `kFileEditLimit` (256 KB) entscheiden, ob die
  Vorschau einen „Bearbeiten"-Knopf zeigt; der reicht an den bestehenden
  Config-Editor weiter (atomarer Write + Backup, sudo-fähig). Der Editor liest
  über `readConfigFile` (§2: nur mit Exit 0, nur UTF-8). `_ConfigEditorPage`
  fragt per `PopScope` nach, bevor ungespeicherte Änderungen verloren gehen
  (Zurück-Geste, Systemtaste, Pfeil der App-Leiste → „Verwerfen" / „Weiter
  bearbeiten"); Speichern poppt direkt mit dem Text. Beim Sperren der App
  bleibt der Editor unter der Sperrschicht offen und behält seinen Text (§6
  `app_lock.dart`).
- **`ssh_keys.dart`** — **client-seitige** SSH-Key-Erzeugung. `generateSshKey`
  (Ed25519 via `cryptography`, rein Dart) → privater Key als **openssh-key-v1**-
  PEM (selbst kodiert; Korrektheit per Round-Trip getestet: `SSHKeyPair.fromPem`
  lädt ihn) + `authorized_keys`-Zeile. Der **private Key entsteht im Handy und
  verlässt es nie** — nur der Public Key geht auf den Pi (`buildInstallAuthorizedKeyScript`,
  idempotent, `~/.ssh` 700/600, Marker `KEY_INSTALLED`, **kein** Root). Eine
  letzte Zeile der `authorized_keys` ohne Zeilenende wird vor dem Anhängen
  beendet — sonst würde der Key Teil dieser Zeile und nie akzeptiert.
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
  Digest-Pin-Ablehnung, `dockerRecreateRefusal` (§3 „Docker") und
  `dockerRunRecreateScript` (Rollback-Netz) — und prüft danach via
  `buildDockerRunningProbe` (`{{eq .State.Status "running"}}`), dass wirklich
  etwas läuft. Ein Tag ohne neueres Image endet vorher als
  `DockerUpdateOutcome.tagCurrent` bzw. `pinnedTagCurrent`, ohne dass der
  Container angefasst wurde (§3).
  Eigene `-evccpitool-old`-Rollback-Container werden verweigert
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
  Health) — NICHT verwechseln, daher der eigene Name. Ein gescheiterter
  Drill-down lässt Liste und Pfad stehen (an `/` gibt es keinen Weg nach oben
  — eine durch den Fehler ersetzte Liste ließe nichts zum Antippen) und zeigt
  darüber Ordner und Grund („/var/log: …") mit `wRetry` darunter. Der Grund ist
  `EvccUpdateException.message` für klassifizierte Fehler;
  `UpdateErrorKind.unknown` und jeder andere Fehler zeigen `wLoadFailedPerms`,
  weil der Drill-down ohne Log läuft (`onLog: (_) {}`) und das „Details im
  Log" des Updaters ins Leere wiese.
- **`_LiveLogSheet`** (`ui_widgets.dart`) — Service-Logs mit „Live"-Schalter:
  `Timer.periodic` (3 s) re-fetcht `fetchServiceLogs` (Polling, kein PTY/Dienst),
  Timer wird in `dispose` abgebrochen. Das Sheet öffnet am neuesten Eintrag
  und bleibt beim Mitlesen dort, solange niemand hochgescrollt hat (`_atEnd`,
  24 px Toleranz). Ein gescheiterter Abruf lässt das letzte Log stehen und
  zeigt darüber `wLogRefreshFailed`; der nächste gelungene Abruf nimmt die
  Zeile weg. **Unter der App-Sperre pausiert das Polling**
  (`AppLockLayer.maybeOf(context)?.locked`) — jeder Abruf ist ein SSH-Login —
  und läuft nach dem Entsperren weiter; ohne eingeschaltete App-Sperre pollt
  es wie bisher auch im Hintergrund. Die Grenze des Polling-Ansatzes steht
  unter „Bekannte Grenzen".
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
  Die Skripte für fail2ban und Auto-Updates kommen über stdin (`sudo -S bash
  -s`) und halten denselben Vertrag wie die übrigen Root-Skripte: **jedes
  `apt-get` bekommt sein eigenes `</dev/null`**, Installationen laufen mit
  `--force-confdef/--force-confold` — eine conffile-Rückfrage von dpkg läse
  sonst den Rest des Skripts als Antwort und bräche ohne Marker ab.
  Invarianten: Passwort-Login-Abschalten wird NIE angeboten (ohne bewiesenen
  Key-Login = Aussperr-Risiko); der rootLogin-Fix läuft als **Drop-in** unter
  `sshd_config.d/`, `sshd -t` VOR dem Reload, Effekt via `sshd -T` verifiziert,
  bei Abweichung automatischer Rückbau — und `fixSecurity` verweigert ihn ganz,
  wenn die App selbst als root verbunden ist. Nach jedem Fix läuft der Check
  neu (Befund wird sichtbar grün statt nur Toast).
  **Raspbian-Quelle (32-Bit Raspberry Pi OS):** Dort kommen die Pakete aus der
  Origin „Raspbian", `unattended-upgrades` ist aber das unveränderte
  Debian-Paket — sein Origins-Pattern nennt nur `origin=Debian`, es läuft und
  installiert nichts. Die Probe (ruft dafür `apt-cache policy` und einen
  vollen `apt-config dump` auf) druckt in `__SEC_UNATT__` die Zeile
  `raspbian-origin-uncovered`, wenn diese Origin in Gebrauch ist, apt-config
  lesbar war **und** kein Pattern Raspbian einschließt — auf jedem anderen
  System druckt sie nichts. Der Parser nimmt die Zeile vor der Urteilsbildung
  heraus: Sie kann nur „unattended-upgrades läuft." in den Warn-Befund „…
  installiert aber keine Updates aus der Paketquelle Raspbian …" verwandeln
  (fixbar über `SecurityFix.autoUpdates`); ein Abschnitt, der sonst nichts
  enthält, bleibt „Konnte nicht ermittelt werden." (info, kein Fix). Der Fix
  schreibt bei `o=Raspbian` zusätzlich
  `/etc/apt/apt.conf.d/51pitool-unattended-origins` (0644, quoted Heredoc —
  `${distro_codename}` muss wörtlich in der Datei ankommen) mit nur
  `"origin=Raspbian,codename=${distro_codename},label=Raspbian"`; listet
  `apt-config` den Eintrag danach nicht, wird die Datei wieder entfernt, und
  es gibt keinen Marker. Das Archiv der Raspberry Pi Foundation bleibt bewusst
  draußen: Kernel-, Firmware- und Bootloader-Pakete bleiben ein manuelles
  Update, auf 32- und 64-Bit. Nicht an einem 32-Bit-Pi gemessen.
  **fail2ban muss oben bleiben:** `enable --now` kehrt zurück, sobald der
  Serverprozess geforkt ist; ein Server, der kein Log zum Lesen findet, endet
  einen Moment später. Der Fix beobachtet die Unit deshalb 10 s (fünf Proben)
  und meldet `SECFIX_OK` nur, wenn sie aktiv bleibt — sonst Journal-Auszug
  und Exit 1. Nur wenn sie nicht aktiv ist **und** `/var/log/auth.log` fehlt
  (Bookworm ohne rsyslog), installiert er `python3-systemd`, schreibt
  `/etc/fail2ban/jail.d/pitool-sshd.local` (`[sshd]`, `enabled = true`,
  `backend = systemd`), startet neu und beobachtet erneut; ein Drop-in, das
  dieser Lauf geschrieben hat und das nicht half, wird wieder entfernt. Ein
  fail2ban, das gestartet ist, bleibt, wie es ist. Das Skript hat damit drei
  `apt-get`-Aufrufe, jeder mit `</dev/null`.
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
  (v0.20.0-Native-Lektion). Manifest: `<queries>` nennt **jede** App, die die
  Karten öffnen — `com.tailscale.ipn`, `io.evcc.android`,
  `io.homeassistant.companion.android` (Package-Sichtbarkeit, Android 11+; der
  Test in `service_links_test.dart` gleicht die Tabelle gegen das Manifest ab,
  §4). Seam injizierbar für Tests.
- **`file_pick.dart` + native `MainActivity`** — lokale Dateiauswahl fürs Upload.
  **Bewusst KEIN Picker-Plugin:** `file_picker` bringt sein eigenes altes
  Kotlin-Gradle-Plugin mit und scheitert am AGP-9-/Built-in-Kotlin-Setup (und es
  gibt kein stabiles file_picker mit win32 ^6). Stattdessen ein winziger
  Android-SAF-Picker (`ACTION_OPEN_DOCUMENT`) **in der App** (`MainActivity.kt`,
  MethodChannel `pi_tool/filepicker`) → nutzt das projekteigene Kotlin/AGP.
  `FilePickerService`-Seam (`ChannelFilePicker` real, injizierbar für Tests).
  Lehnt die native Seite eine Datei über dem Limit ab (Fehlercode `too_large`),
  zeigt `_pickFailureText` die Meldung mit dem Limit (`snackFileTooLarge`)
  statt eines bloßen „fehlgeschlagen" — für den Upload und den Profil-Import.
  Die native Seite liest die gewählte Datei **auf einem eigenen Thread**,
  nicht im ActivityResult-Callback: Ein Cloud-Provider lädt herunter, während
  sein Stream gelesen wird, und auf dem Main-Thread fröre das die App ein
  (ANR). Gelesen wird höchstens das Upload-Limit plus ein Byte, unabhängig
  davon, ob der Provider eine Größe meldet (`too_large`); jedes `Throwable` —
  auch ein `OutOfMemoryError` — wird zu `read_failed`; die Antwort geht genau
  einmal und auf dem UI-Thread hinaus. `pending` bleibt gesetzt, bis sie
  draußen ist: Ein zweites `pickFile` währenddessen bekommt `busy`. Das
  Verhalten eines echten Cloud-Providers ist nicht an einem Gerät gemessen.
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
  (laufendes Auto-Update — gelesen als `systemctl show -p ActiveState --value
  pi-tool-autoupdate.service`, weil die oneshot-Unit für ihren ganzen Lauf
  „activating" ist und `is-active` darauf mit Nein antwortet; ein Pi ohne die
  Unit oder ohne systemd ist nicht betroffen — oder gehaltener Lock →
  `PITOOL_JOB_BUSY`), räumt
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
  (Passwörter, PEM-Keys) nur in `FlutterSecureStorage` (Keystore) — über
  **`kSecureStorage`**, den einen Speicher aller Stores (s. u.
  `settings_store.dart`). `AppConfigStore.reset()` löscht alles Gespeicherte
  (für den Fehlerzustand beim Laden, §7 „Laden vor Speichern").
  Die Felder mit eigener Geschichte:
  - **`Profile.autoConnect`** — dieser Pi verbindet beim App-Start von selbst
    (Ablauf in §7 „Verbundene Sitzung"). Default `false`: eine Verbindung
    erlaubt sudo-fähige Befehle, also Entscheidung je Pi und keine globale
    Einstellung. Schalter `autoConnectSwitch` in der `_ConnectionCard`;
    `_setAutoConnect` nimmt es beim Einschalten allen anderen Profilen weg —
    höchstens **ein** Profil trägt es (zwei würden beim Start um das Host-Feld
    konkurrieren).
  - **`Profile.cachedServices`** — die letzte Erkennung dieses Pi als rohes
    JSON (`ServiceStatus.toJson`, keine Zugangsdaten), geschrieben von
    `_currentProfile()` aus `_services`. Beim App-Start füllt `_applyProfile`
    daraus `_services` und setzt `_servicesFromCache`; solange das gilt und
    keine Sitzung besteht, steht über den Karten der Hinweis `wCachedState`
    („Stand von vorhin") — ein gemerkter Stand wird nie als aktuell ausgegeben.
    Jede echte Erkennung, die die Karten ersetzt, hebt das auf
    (`_servicesFromCache = false`): `_testConnection`, `_refreshServices` (das
    Neulesen nach einer Aktion), `_checkRemoteAccess` und `_tailscaleCheckLan`
    — auch ohne Sitzung. Umgekehrt macht das Bearbeiten eines Verbindungsfelds
    die Karten auf dem Bildschirm wieder zum gemerkten Stand
    (`_invalidateConnTest`: sie wurden von der Adresse gelesen, wie sie war).
    Mit Sitzung oder Testergebnis endet dabei auch die Sitzung; ohne beides
    (Sitzung schon durch Herunterfahren oder Verbindungsverlust beendet) wird
    nur das Flag gesetzt. Auch
    ein **Profilwechsel** zeigt den gemerkten Stand des Ziel-Profils:
    `_resetDetectionForNewPi()` läuft **vor** `_applyProfile()` (Wechseln,
    Hinzufügen, Löschen des aktiven Profils, Import) — in umgekehrter
    Reihenfolge leerte der Reset die gerade geladenen Karten, und das folgende
    Speichern auch deren Cache. **Demo-Karten werden nie gespeichert:** im Demo
    schreibt `_currentProfile()` den zuvor gemerkten Stand (`_storedCards`)
    zurück, sonst kämen die Beispieldaten nach einem Neustart als „Stand von
    vorhin" wieder.
  - **`AppConfig.reviewPrompt`** (v0.71.0) — Zähler der Bewertungs-Anfrage
    (`ReviewPromptState`, siehe `review_prompt.dart` unten); tolerant dekodiert,
    Fehlendes zählt als „nie vermerkt".
  - **`Profile.alertsNtfyServer` / `Profile.alertsNtfyTopic`** — das ntfy-Ziel
    der Health-Alerts **dieses** Pi, so wie zuletzt aus dieser App
    eingerichtet; Teil des verschlüsselten Exports.
    `AppConfig.alertsNtfyServer`/`alertsNtfyTopic` bleiben nur als Rückfall
    für Profile ohne eigenes Ziel (geladen und gespeichert, wie sie sind; ein
    neues Ziel geht ins Profil). Zwei reine Helfer: `effectiveNtfyDestination`
    (Wert des Profils, sonst der app-weite) und `profilesForImport` — ein
    importiertes Profil ohne eigenes Topic bekommt das app-weite der
    **exportierenden** App mit, denn der Rückfall der importierenden ist ein
    anderer. Das Topic wirkt wie ein Passwort und darf nie in eine Log-Zeile
    (§5 `alerts.dart`).
  - **Entfernt:** `AppConfig.autoCheck` und `AppConfig.notifyUpdates` (nie
    gelesen und von der UI nie gesetzt). Gespeichertes JSON mit diesen
    Schlüsseln lädt weiterhin.
- **`settings_store.dart`** — Legacy-Migrationsquelle, `HistoryStore`,
  `SecureHostKeyStore`. Passwort-Feld ist dual: SSH+sudo (Passwort-Modus) bzw.
  nur sudo (Key-Modus).
  **Ein Secure Storage für alle Stores (Sicherheits-Invariante):**
  `kSecureStorage` = `FlutterSecureStorage` mit `kSecureStorageOptions` =
  `AndroidOptions(resetOnError: false)`. Mit dem Plugin-Default (`true`) wird
  ein Wert, der sich nicht entschlüsseln lässt, gelöscht und als „nicht
  gespeichert" gelesen, und ein Keystore-Schlüssel, der nicht mehr passt,
  nimmt alle Daten mit — die App sähe einen Erststart und speicherte eine
  leere Konfiguration über Profile, Passwörter und SSH-Keys. Mit dem Flag aus
  erreicht der Fehler Dart als Exception, und das Gespeicherte bleibt, wie es
  ist (Start: §7 „Laden vor Speichern"; Host-Keys: §1 „TOFU").
  **Nie ein nacktes `FlutterSecureStorage()` in `lib/` konstruieren:** Das
  Plugin behält die Optionen des Aufrufs, der den Speicher geöffnet hat, für
  den Rest des Prozesses — ein einziger Store mit dem Default brächte das
  stille Löschen für alle zurück. Die Begründung hängt an
  flutter_secure_storage 10.3.1 (`pubspec.lock`): Dort wird `resetOnError`
  nur in Fehlerpfaden gelesen (`handleStorageError`, zwei Stellen in
  `handleKeyMismatch`, der catch-Block in `FlutterSecureStoragePlugin`) und
  ist kein Teil von Speichername, Key-Alias oder Cipher-Wahl — **bei einem
  Plugin-Upgrade erneut prüfen.**
  **Rücksetzweg** (`resetSecureStorage`): `deleteAll()`; wirft auch das (der
  Speicher ging gar nicht erst auf, sein Schlüssel passt nicht mehr), folgt
  ein Aufruf mit `resetOnError: true` — das Plugin verwirft dann Daten und
  Schlüssel und behält diese Einstellung, bis die App neu startet. Gelöscht
  wird alles im Secure Storage: Profile, Legacy-Schlüssel, Verlauf und die
  gepinnten Host-Keys.
  **`HistoryStore.add`/`clear`** laufen über eine Future-Kette nacheinander
  (`add` ist Lesen-Anhängen-Schreiben; ein zweiter Aufruf läse die Liste
  sonst, bevor der erste geschrieben hat). `add` scheitert, wenn sich die
  gespeicherte Liste nicht lesen lässt, und schreibt dann nichts — ein
  unlesbarer Verlauf ist kein leerer.
- **`history.dart`** — reines Modell des Aktions-Verlaufs („Update-Verlauf"):
  `HistoryEntry` (`when`, `text`, optional `profile` = Name des Pi, auf dem die
  Aktion lief; JSON-Schlüssel `profile`, weggelassen, wenn leer), `capHistory`
  (höchstens 30 Einträge, die
  ältesten fallen heraus), `parseHistory`/`encodeHistory` (tolerant: alles
  Unerwartete → leere Liste), `formatTimestamp` (ohne intl-Abhängigkeit) und
  `historySubtitle` (zweite Zeile einer Verlaufszeile: die Zeit, bei mehreren
  Profilen dahinter der Pi).
  Persistiert wird über `HistoryStore` in `settings_store.dart` (Key
  `history_v1`). `_addHistory` schluckt einen Schreibfehler (ein Eintrag, der
  sich nicht speichern lässt, macht aus einer gelungenen Aktion keinen
  Fehler); `_showHistory` meldet einen nicht lesbaren Verlauf als solchen
  (`snackHistoryUnreadable`, mit „Leeren" als Aktion) statt als leeren.
- **`entitlement.dart`** — **schlafendes Freemium**: `DormantEntitlement` = jeder
  ist Pro (Sideload-Nutzer verlieren nichts vor dem Play-Launch). Pro-Features:
  `backups`, `console`, `cleanup`, `multiPi`, `automation` (geplante Updates +
  Health-Alerts), `files` (Dateien-Tab) (+ 1-Profil-Limit); die Paywall-Liste in
  `_showPaywall` muss dazu passen. Echte Play-
  Billing-Impl wird später hinter `EntitlementService` gesteckt. Gate-Punkte nie
  mit `!isPro` inlinen — immer über den Seam / `_proGate`. Der Enum
  `ProFeature` ist heute nur die dokumentierte Liste (außerhalb von
  `entitlement.dart` liest ihn allein `entitlement_test.dart`); die Gates
  fragen `_unlocked`. Was vor dem Einschalten von Billing am Gating zu klären
  ist (Fernzugriff ohne Schloss und Paywall-Zeile, Profil-Import am
  1-Profil-Limit vorbei, `_isPro` startet mit `true`), steht in
  `store/pro-flip-runbook.md`.
- **`demo.dart`** — **Demo-Modus**: `DemoSshRunner implements SshRunner` liefert
  kanned Kommando-Ausgaben (Detection-Batch + Datei-/Terminal-Befehle) plus ein
  Demo-`EvccApiClient`. Das kanned Erkennungs-Dokument **muss mit dem
  Endmarker enden** (§3 „Detection-Batch") — ohne ihn gälte es als
  abgeschnitten, und das Demo zeigte keine Karten; die Datei-Liste antwortet
  im Format von `buildListDirCommand` (NUL-Datensätze, §5).
  Injiziert über `buildDemoUpdater()` (die einzige
  `runnerFactory`-Stelle) — EINE Klasse füllt alle Tabs mit Beispieldaten, ohne
  echten Pi/Socket. In `main.dart`: `_demoMode` (in-memory wie `_connected`) swappt
  `_updater`/`_apiClient` auf die Demo-Instanzen (`_startDemo`), zurück via
  `_restoreRealBackend` (jeder echte Connect / Profilwechsel / Cred-Edit /
  `_exitDemo`). Pro ist im Demo offen über **`_unlocked = _isPro || _demoMode`** —
  alle Gate-Sites lesen `_unlocked`, nie mehr roh `_isPro`. Löst die Play-
  „LoginWall"-Prüfung ohne Demo-SSH-Server.
  **Das Demo hängt nicht an den Verbindungsfeldern** (v0.71.0; auf einer
  frischen Installation sind sie leer): `_prepare()` und `_filesConfig()`
  liefern im Demo die feste `_demoConfig` — ohne Feldvalidierung, ohne
  Speichern; `_prepare(real: true)` ist dem echten Verbinden vorbehalten, das
  immer die eingegebenen Felder meint. **Demo-Daten bleiben im Demo:** die
  Beispielkarten werden nicht als `cachedServices` gespeichert (s. o.),
  Demo-Aktionen schreiben keinen Verlauf (`_addHistory` ist dort ein No-op —
  und zählen damit auch nicht für die Bewertungs-Anfrage), und „Web öffnen"
  auf einer Demo-Karte sagt nur, dass es keine Weboberfläche gibt
  (`_demoHasNoWebUi`), statt nach einem Host zu fragen. Die Demo-Persona hat
  ein verbundenes Tailscale (Beispiel-Adresse 100.101.102.103, kein
  freigegebenes Heimnetz), damit die Karte die evcc-Adresse zeigt; „Diese IP
  als Host übernehmen" und „evcc-Adresse teilen" fehlen dort — die Adresse
  gehört zu keinem Pi und darf weder ins Profil noch zu anderen Leuten. Gemeinsamer Ausstieg
  ist `_leaveDemo()` (echtes Backend zurück, Beispielkarten vom Bildschirm, der
  zuvor gemerkte Stand des Profils kommt als gemerkter Stand wieder) — über
  „Beenden", einen Tastendruck in den Zugangsdaten (`_invalidateConnTest`) und
  jedes echte Verbinden; das Demo endet dabei **beim Start** des Verbindens,
  nicht erst bei dessen Erfolg, damit seine Sitzung die Tabs nicht gegen einen
  Pi offen hält, der noch nicht geantwortet hat.
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
  Verschlüsselung + bewusst langsame KDF (`kExportKdfIterations` = 600 000,
  der OWASP-Wert für diese KDF); Import cappt die
  Iterationen (`_kMaxKdfIterations`) gegen DoS-Dateien. Eine Datei trägt ihre
  eigene Rundenzahl — Exporte bis v0.71.0 (200 000) lassen sich weiter
  importieren. `kExportMinPassphraseLength` = 10 gilt nur im Export-Dialog.
  Ab `_kIsolateKdfIterations` (2000) wird der Schlüssel per `Isolate.run`
  abgeleitet (ohne die Pausen von `DartPbkdf2`), damit die UI nicht steht;
  gibt es kein zweites Isolate, wird inline gerechnet. Wie lange die Ableitung
  auf einem Handy dauert, ist nicht gemessen. UI in den Einstellungen,
  Export via `fileSaver`-Seam, Import via SAF-Picker; der Passphrase-Dialog
  (`_PassphraseDialog`) ist scrollbar, damit beide Felder bei offener Tastatur
  erreichbar bleiben.
- **`session.dart`** — reine Sitzungs-/Tab-Gating-Logik (v0.57): `kTab*`-
  Konstanten, `isGatedTab`/`tabAllowed`/`tabAfterDisconnect`. Details im
  UI-Shell-Abschnitt („Verbundene Sitzung").
- **`language.dart`** — reine Sprach-Auflösung (v0.58): `localeForLanguageMode`
  + `resolveSystemLocale` (Englisch-Fallback). Siehe „Sprache" im UI-Abschnitt.
- **`l10n.dart`** — `context.l10n`-Extension auf die generierten
  `AppLocalizations` (Quellen: `lib/l10n/app_{de,en}.arb`; Generat gitignored).
- **`update_check.dart`** — Self-Update-Check (nur Sideload-Kanal) + evcc-/HA-
  Versionsproben. Der stille Check beim App-Start (`checkForUpdate`) und die
  beiden Versionsproben sind fail-soft (Fehler → null). Die **manuelle** Prüfung
  („Auf Update prüfen") nutzt `checkForUpdateOrThrow`: dort heißt `null` nur
  „geprüft, nichts Neueres"; offline, Timeout, eine Nicht-200-Antwort (GitHubs
  Rate-Limit ist 403/429), kaputtes JSON oder eine Antwort ohne Tag **werfen**,
  und `_checkUpdatesNow` zeigt `snackUpdateCheckFailed` statt „Aktuell".
  Der Adapter `githubGetJson` hat **5 s Connect-Limit** (DNS, TCP, TLS — ohne
  `connectionTimeout` läuft das, bis das Betriebssystem aufgibt) und **10 s für
  die ganze Anfrage einschließlich Body**; der Client wird mit `force`
  geschlossen, damit ein aufgegebener Lesevorgang endet. Aufrufer warten darauf
  mit gesperrter UI (Verbinden, jede Erkennung, vor dem evcc-Update).
  `isNewerVersion` numerisch.
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
  Der Adapter `evccGetJson` begrenzt die **ganze** Anfrage auf 10 s (Connect,
  Header und Body — die Einzellimits ließen den Body offen). `parseEvccState`
  liest die **verschachtelte** Form zuerst und fällt auf den flachen Schlüssel
  älterer evcc-Versionen zurück: `grid.power` (seit 0.133.0) vor `gridPower`,
  `battery.soc`/`battery.power` (seit 0.301.0) vor `batterySoc`/`batteryPower`.
  „Batterie konfiguriert" folgt evccs eigener Oberfläche: `batteryConfigured`,
  wo es noch existiert (bis 0.124.x), sonst eine nicht leere `battery`-Liste
  (ab 0.125.0) bzw. ein nicht leeres `battery.devices` (ab 0.301.0). Die Tests
  tragen je Form eine Antwort.
- **`network_scan.dart`** — „Pi finden": TCP-Port-22-Sweep des /24 (bewusst
  kein mDNS: kein Plugin, kein Multicast-Lock). **Nur lokale Netze:**
  `localIPv4s` liefert `(interface, address)`-Paare, `lanAddresses` lässt
  VPN-, Mobilfunk- und CLAT-Schnittstellen nach Namenspräfix weg (`tun`,
  `tap`, `ppp`, `wg`, `ipsec`, `rmnet`, `ccmni`, `wwan`, `v4-`) sowie
  100.64.0.0/10 und 192.0.0.0/24 nach Adresse — ein Sweep dort wären 253
  Verbindungsversuche in ein Tailnet oder ein Mobilfunknetz. Eine
  Schnittstelle, die die Liste nicht kennt, wird wie bisher durchsucht.
  `findSshHosts` hat dafür den injizierbaren Seam `addresses`.
- **`keep_alive.dart`** — Android-Foreground-Service (hält den Prozess bei langen
  SSH-Aktionen am Leben; führt **keinen** eigenen Code aus). Best-effort, darf die
  Aktion nie brechen. `KeepAliveService.begin(message, {required channelName,
  required channelDescription})`: Die Texte des Benachrichtigungskanals
  kommen aus der l10n (`keepAliveChannelName`/`keepAliveChannelDescription`);
  sie wirken nur, wenn Android den Kanal `pi_tool_action` erstmals anlegt —
  Bestandsinstallationen behalten den deutschen Namen. In `main.dart` zählt
  `_keepAliveHolds`, wer den Dienst gerade hält (`_keepAliveBegin`/
  `_keepAliveEnd`, von `_guard` und vom Sammellauf im Multi-Pi-Überblick
  benutzt): Gestoppt wird erst, wenn der letzte Halter endet.
- **`authenticator.dart`** — App-Lock (Biometrie/PIN, `local_auth`). Fail-closed.
- **`app_lock.dart`** — **die App-Sperre liegt über dem Navigator**, sie ist
  keine Route. (Früher war der Sperrbildschirm der Inhalt der Home-Route, und
  beim Sperren wurden alle anderen Routen gepoppt. Zwei Mängel: Ein Dialog,
  Sheet oder eine Seite, die eine Aktion danach öffnete, lag über dem
  Sperrbildschirm; und das Poppen warf weg, was offen war — ungespeicherten
  Text im Config-Editor, das nur einmal gezeigte Pi-hole-Passwort, ein
  laufendes Update mehrerer Pis.)
  - **`AppLockScope`** sitzt über `MaterialApp`: hält den `AppLockController`
    und ist ein `WidgetsBindingObserver`, der sich **vor** der `WidgetsApp`
    registriert — System-Zurück kommt zuerst hier an.
  - **`AppLockLayer`** sitzt in `MaterialApp.builder` um den Navigator: ein
    `Stack` aus zwei Fokus-Bereichen, deren Knoten der Controller besitzt
    (`FocusScope.withExternalFocusNode`): „App lock: Navigator" mit
    `Offstage(Navigator)` und „App lock: lock screen" — gesperrt der
    Sperrbildschirm in einem **eigenen `ScaffoldMessenger`** (auf dem der App
    zeigte er ein darunter ausgelöstes Snackbar samt Aktion), sonst ein leeres
    `SizedBox`. Der Navigator bleibt immer im Baum: Gesperrt ist er nicht
    gemalt, nicht hit-getestet, nicht im Semantik-Baum und nimmt keinen Fokus;
    jede Route behält ihren Zustand, und eine während der Sperre gepushte
    Route landet einfach darunter. Die Schicht hat bewusst keinen eigenen
    Zustand und macht keinen Plattform-Aufruf — ein Fehler dort hinterließe
    eine dauerhaft gesperrte App.
  - **Wann gesperrt und wie authentifiziert wird, bleibt in der Seite.**
    `_UpdaterPageState` findet den Controller in `initState` über
    `AppLockLayer.maybeOf(context)` (nur unter einer Schicht, die wirklich im
    Baum ist) und meldet über den Setter von `_locked`: **zuerst**
    `_appLock.locked`, dann die Screenshot-Policy — die Schicht folgt
    `_locked`, was immer der Plattform-Seam tut. `_engageLock()` ist die eine
    Stelle, die sperrt. **Regel für neuen Code:** `_locked` und `_lockEnabled`
    nur über ihre Setter schreiben.
  - **Fokus und Tastatur:** `_AppLockScopeState._onLockChanged` schaltet die
    beiden Bereiche **in dem Aufruf, der sperrt oder entsperrt** — nicht mit
    dem nächsten Build: Die App sperrt im Hintergrund, wo kein Frame gezeichnet
    wird, und bis dahin erreichten Tab und Leertaste einer Hardware-Tastatur
    noch die oberste Route (bei offenen Einstellungen schalteten sie die
    Sperre aus). Beim Sperren gibt ein fokussiertes Feld oder Bedienelement
    den Fokus ab (die Tastatur schließt), der Navigator-Bereich wird
    geschlossen (`canRequestFocus = false`), der Sperrbildschirm bekommt den
    Fokus. Beim Entsperren umgekehrt; der Fokus landet auf der obersten
    Route, nicht in dem Textfeld, das ihn hatte — die Bildschirmtastatur
    bleibt unten. **Regel:** Das Unfocus beim Sperren muss einen Knoten
    überspringen, der selbst ein `FocusScopeNode` ist — ein Unfocus auf dem
    Scope einer Route lässt den Navigator diese Route vergessen, und das
    Entsperren könnte den Fokus nicht dorthin zurückgeben.
  - **System-Zurück bei gesperrter App** — zwei Wege: (1)
    `AppLockScope.didPopRoute` ruft `SystemNavigator.pop()` und gibt `true`
    zurück (Zurück verlässt die App, wie auf einem Sperrbildschirm, statt zu
    poppen, was verborgen darunter liegt); das ist der Pfad, auf dem Android
    noch `Activity.onBackPressed` aufruft, den `FlutterFragmentActivity`
    unbedingt weiterreicht. (2) Solange gesperrt ist, bekommt die Plattform
    `SystemNavigator.setFrameworkHandlesBack(false)`, und die
    `NavigationNotification` des Navigators wird von einem Listener in der
    Schicht zurückgehalten; mit dem Entsperren geht der zuletzt gemeldete Wert
    hinaus. Grund: Eine Predictive-Back-Geste verfolgt jede Page-Route als
    eigener Binding-Observer (`PredictiveBackPageTransitionsBuilder` ist in
    Flutter 3.44.4 der Android-Default), und kein Observer kann einen anderen
    zurückhalten. **Aus dem Framework-Quelltext abgeleitet und in
    Widget-Tests geprüft, nicht an einem Gerät gemessen** — Predictive Back
    bei gesperrter App hängt allein an diesem Plattform-Flag (s. „Bekannte
    Grenzen").
  - **Zeitgrenze für `_suppressLock`** (die Sperre ist ausgesetzt, solange
    der System-Dateiwähler offen ist — sonst kehrte man vom Auswählen einer
    Datei auf den Sperrbildschirm zurück): `_suppressedSince` wird gestempelt,
    wenn die App mit ausgesetzter Sperre nach `paused`/`hidden` geht; auf dem
    Rückweg (`inactive` oder `resumed`) sperrt sie, wenn `_kSuppressLockLimit`
    (5 Minuten) vergangen ist oder die Uhr rückwärts lief (injizierbare
    `UpdaterPage.clock`). Das ist der eine Fall, in dem die Sperre außerhalb
    von `paused`/`hidden` greift. `_filesUpload` verwirft eine Auswahl, die
    zurückkommt, während gesperrt ist; der Profil-Import braucht das nicht —
    sein Passphrase-Dialog wartet unter der Sperre. **Nicht gemessen:** Dass
    die Antwort des Pickers **nach** dem Lifecycle-Wechsel eintrifft, ist aus
    dem Engine-Quelltext abgeleitet. Liefert ein Gerät die Antwort zuerst, ist
    die Aussetzung schon aufgehoben, wenn die Lifecycle-Ereignisse des
    Rückwegs kommen, und die App sperrt bei jeder Rückkehr aus dem Picker.
  - **Was unter der Sperre passiert:** Ein Snackbar, das während der Sperre
    ausgelöst wird, erscheint darunter und kann beim Entsperren schon
    abgelaufen sein. Eine Netzwerksuche („Pi im WLAN suchen"), die
    währenddessen fertig wird, zeigt ihr Ergebnis nach dem Entsperren. Ein
    Live-Log pausiert sein Polling (§5). „Was ist neu?" wird erst eingeplant,
    wenn nicht gesperrt ist (§7).
  - **Eine Seite ohne Sperrschicht** (direkt gepumpte `UpdaterPage`, wie in
    den meisten Widget-Tests und in `test/screenshots.dart`) behält das
    frühere Verhalten: Sperrbildschirm in ihrer Route und `popUntil` beim
    Sperren. Tests des Sperrverhaltens, wie es ausgeliefert wird, pumpen
    `EvccPiToolApp(home: UpdaterPage(...), splash: false)`
    (`test/app_lock_test.dart`, §8).
- **`secure_screen.dart` + native `MainActivity`** (v0.65.0) — `SecureScreen`-Seam
  (Default `ChannelSecureScreen` über MethodChannel `pi_tool/secure`, Methode
  `setSecure`; kein Plugin) schaltet Androids `FLAG_SECURE` zur Laufzeit. Das
  Flag sperrt Screenshots und Bildschirmaufnahmen und leert die
  Recents-Vorschau. Bis v0.64.x galt es app-weit; seitdem ist es **eingegrenzt**
  auf die Ansichten, in denen Zugangsdaten stehen können — **Sperrbildschirm
  und aufgeklappte Zugangsdaten-Karte**: `_applyScreenshotPolicy()` in
  `main.dart` setzt `_locked || _connExpanded`. Dienst-Karten, Logs (Passwörter
  sind dort redigiert), Terminal, Dateien und Config-Editor sind bewusst frei,
  damit Nutzer die App zeigen können (Meldung 2026-08-12).
  **Invarianten:** `MainActivity.onCreate` setzt das Flag **immer zuerst** — die
  App ist geschützt, bevor Dart läuft; der Kanal lockert nur. Ein fehlendes
  Argument zählt nativ als `secure = true`, ein Kanal-Fehler wird in Dart
  geschluckt: das Flag bleibt dann, wie es war, und der Startzustand ist
  „gesperrt". **Angewendet wird die Policy ausschließlich über die Setter von
  `_locked` und `_connExpanded`** (v0.71.0; die Werte liegen in
  `_lockedValue`/`_connExpandedValue`): Jeder Schreibzugriff zieht das Flag
  nach — das Sperren (Lifecycle `paused`/`hidden`), der Entsperrversuch, das
  Auf-/Zuklappen der Karte über ihren Kopf **und** die Änderungen, die die App
  von sich aus vornimmt (Einklappen nach erfolgreichem Verbinden bzw. im Demo;
  Aufklappen durch `_useTailscaleIp`, `_useHomeHost`,
  `_remoteAccessViaTailscale`, `_exitDemo`; Profilwechsel und Start über
  `_applyProfile`). `_loadSettings` setzt die Sperre **vor** `_applyProfile`:
  ein eingerichtetes Profil klappt die Karte ein, und für sich allein hieße das
  auf dem Weg zum Sperrbildschirm einen Moment lang „Screenshots erlaubt".
  **Regel für neuen Code:** `_locked` und `_connExpanded` nur über die Setter
  schreiben, nie die `…Value`-Felder direkt; `_applyScreenshotPolicy()` hat
  außer den beiden Settern keinen Aufrufer und bekommt auch keinen. Seam
  injizierbar für Tests (`UpdaterPage.secureScreen`).
  **Recents-Vorschau bei eingeschalteter App-Sperre** — zweiter Seam
  `RecentsPreview` (`setRecentsHidden(bool)`; `ChannelSecureScreen`
  implementiert ihn auf demselben Kanal, Methode `setRecentsHidden`, Argument
  `hidden`; injizierbar als `UpdaterPage.recentsPreview`): Die Sperre greift,
  wenn die App schon im Hintergrund ist, und Android hat das Bild für die
  App-Übersicht dann bereits aufgenommen — `FLAG_SECURE` kommt dafür zu spät.
  Mit eingeschalteter Sperre wird das Bild deshalb ganz abgeschaltet
  (`Activity.setRecentsScreenshotEnabled(!hidden)`); Screenshots bleiben
  möglich. Die Plattform bietet das **ab Android 13 (API 33)**. **Darunter
  ändert der Aufruf nichts:** Unter Android 12 und älter kann die Übersicht
  den letzten Bildschirm zeigen, obwohl die App gesperrt ist. `_lockEnabled`
  ist dafür ein Setter über `_lockEnabledValue` und ruft den Seam nur bei
  einer **Änderung** — eine Installation ohne Sperre macht den Aufruf nie.
  Nativ hinter `SDK_INT >= 33` und `try/catch (Throwable)`; in `onCreate` kam
  nichts hinzu. Wie die Übersicht auf einem Gerät tatsächlich aussieht, ist
  nicht gemessen.
- **`review_prompt.dart` + native `MainActivity`** (v0.71.0) —
  **Bewertungs-Anfrage an Google Play.** Reine, Flutter-freie Entscheidung
  (`shouldRequestReview`) über dem Zustand `ReviewPromptState` (`successes`,
  `firstSuccessAt`, `lastAskedAt`, `asks`; persistiert als
  `AppConfig.reviewPrompt`) plus Seam `ReviewRequester` (Default
  `ChannelReviewRequester` über MethodChannel **`pi_tool/review`**, Methode
  `requestReview`).
  - **Wann gefragt wird:** nur in einem **Play-Build** (`InstallChannel.play` —
    die Karte kann nirgends sonst erscheinen; bis die Plattform den Kanal
    nennt, gilt Sideload, „unbekannt" fragt also nie), **nie im Demo-Modus**,
    **nie über dem Sperrbildschirm** (`_locked`), frühestens nach
    `kReviewMinSuccesses` = **3 gelungenen Aktionen und** `kReviewMinAge` =
    **3 Tagen** seit der ersten, höchstens alle `kReviewCooldown` = **120
    Tage**, insgesamt `kReviewMaxAsks` = **dreimal**. Eine zurückgestellte Uhr
    löst nie eine Anfrage aus.
  - **Zähl-Einheit ist der Verlaufseintrag:** `_addHistory` (eine Aktion, die
    wirklich etwas getan hat; im Demo ein No-op) ruft `recordSuccess` und setzt
    `_reviewCheckDue`. Geprüft wird erst, wenn die Aktion beendet ist — im
    `finally` von `_guard` über `_maybeAskForReview`, und nur für einen Erfolg,
    den **diese** Aktion vermerkt hat. Nichts davon läuft im Startpfad.
  - **Play entscheidet allein und meldet nichts zurück** (Kontingent, schon
    bewertet, kein Play Store auf dem Gerät): `true` vom Kanal heißt nur „die
    Anfrage hat Play erreicht", nie „die Karte wurde gezeigt". Deshalb wird die
    Anfrage **vor dem Absenden vermerkt** (`recordAsk` + Speichern) — eine
    Karte, die Play verschluckt, darf nicht bei der nächsten Aktion erneut
    angefragt werden.
  - **Keine vorgeschaltete „Gefällt dir die App?"-Frage** — zu filtern, wer
    bewerten darf, schließen Plays Richtlinien aus.
  - **Nativ:** Googles Review-Bibliothek `com.google.android.play:review`
    direkt (`ReviewManagerFactory` → `requestReviewFlow` → `launchReviewFlow`),
    **kein Plugin**: `in_app_review` wendet `kotlin-android` an — das Muster, an
    dem schon `file_picker` am Kotlin-Setup dieses Projekts gescheitert ist
    (Begründung im Kommentar in `MainActivity.kt`; in `build.gradle.kts`
    bewusst das schlichte Java-Artefakt ohne `-ktx`). Jeder native Fehlerpfad
    endet in `false`, ein Kanal-Fehler wird in Dart geschluckt: die Anfrage
    darf die App nie stören.
  - Seams in `UpdaterPage` für die Tests: `reviewRequester`, `installChannel`,
    `clock` (§8).

## 7. UI-Shell (`main.dart`, `ui_widgets.dart` (part), `kyth_splash.dart`)

Ein großer `StatefulWidget` (`_UpdaterPageState`) hält allen State und rendert das
**Cockpit**: `NavigationBar` + `IndexedStack`, 4 Tabs **Verwaltung / Automatik /
Terminal / Dateien** (Tab 0 hieß bis v0.56 „Dienste"). `ui_widgets.dart` ist ein
`part of '../main.dart'` (teilt sich `kGreen/kBlack/kCard` ohne Re-Import —
nicht in einen Import „aufräumen").

**Aufbau der App** (`EvccPiToolApp`): `AppLockScope` → `MaterialApp`, in dessen
`builder` `KythSplashGate` → `AppLockLayer` → Navigator liegen (Splash über
Sperre über allen Routen — wie zu der Zeit, als beides Teil der Home-Route
war); `home` ist die `UpdaterPage`. Die zwei optionalen Parameter `home` und
`splash` sind für Tests (eine Seite mit gefälschten Kollaborateuren gegen die
echte Verdrahtung, ohne Splash-Video); die Produktion ruft weiter
`const EvccPiToolApp()`. Die Sperre selbst: §6 `app_lock.dart`.

**Verbundene Sitzung (v0.57, `session.dart`):** „Verbindung herstellen" setzt
`_connected` — ein **gemerkter, geprüfter Zustand, KEIN gehaltener Socket**
(Aktionen verbinden weiter pro Aktion, `_withConnection` unverändert). Die reine
Gating-Logik (`kTab*`-Konstanten, `isGatedTab`/`tabAllowed`/`tabAfterDisconnect`)
lebt in `lib/src/session.dart` (unit-getestet). Automatik/Terminal/Dateien sowie
die SSH-Aktionen „Pi neu starten/herunterfahren" im ⋮-Menü sind bis dahin
gesperrt (ausgegraut + Hinweis). Das Tab-Gate allein genügt nicht: der
`IndexedStack` baut auch verdeckte Tabs, und `_FilesView` listet, sobald er
existiert. Er wird deshalb **nur mit Sitzung gebaut** (`_connected`, das auch
das Demo setzt) — sonst meldete sich die App schon mit einem gespeicherten
Profil per SSH an und sendete das sudo-Passwort, ohne dass jemand „Verbinden"
getippt hat. `_connected` fällt auf `false` bei:
Profilwechsel (`_resetDetectionForNewPi`), Zugangsdaten-Edit
(`_invalidateConnTest`), Verbindungs-Fehlern (`connection`/`auth`/
`hostKeyChanged` im `_guard`-Catch; ein geänderter Host-Key in einer
Datei-Operation über `_fileOpFailed`) und **nach „Pi herunterfahren"** — mit
Snap-Back auf Tab Verwaltung. **Nicht** bei `outputTimeout` (§2: der Pi war
erreichbar, das Ergebnis ist nur unbekannt). `_beginBusy` fasst `_connected`
bewusst NICHT an.
In-Memory, nie persistiert: jeder Kaltstart beginnt getrennt, ein Resume löst
kein SSH aus (`didChangeAppLifecycleState` speichert und sperrt nur).
**Auto-Verbinden (v0.65.0):** Trägt das aktive Profil `Profile.autoConnect`,
stellt der Kaltstart die Sitzung selbst her — `_loadSettings` ruft nach dem
ersten Frame `_testConnection()`, also den gewöhnlichen Handler samt `_guard`
und Host-Key-Prüfung. Bedingungen: `!_locked` (**nie an der App-Sperre vorbei**
— ist die Sperre aktiv, wird auch nach dem Entsperren nicht nachgeholt),
`_credsComplete()`, `!_busy`, `!_connected`. Genau einmal pro App-Start; ein
späterer Profilwechsel bleibt manuelles Verbinden. Bis die Erkennung landet,
zeigen die Karten den gemerkten Stand (`Profile.cachedServices`, §6).
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
Splash-Ersatz) → `_loadFailed` (Fehlerzustand mit „Erneut versuchen" und
„Gespeicherte Daten zurücksetzen", fest dunkel wie der Lock-Screen) →
Lock-Screen **in der Route nur, wenn die Seite keine Sperrschicht hat**
(`_locked && _appLock == null`) → `!_disclaimerAccepted`
(Ablehnen = App beenden) → einmaliges „Was ist neu?" (post-frame; nur
eingeplant, solange nicht gesperrt ist — Popup und „gesehen"-Vermerk warten
auf das Entsperren) → Shell
(deren Tab-Gate siehe „Verbundene Sitzung" oben). Mit der Sperrschicht — also
in der ausgelieferten App — wird die Shell **unter** der Sperre gebaut, auch
bei einem gesperrten Kaltstart (§6 `app_lock.dart`).

**Laden vor Speichern** (v0.71.0): Bis `_loadSettings` gelungen ist, steht im
State nur der eingebaute Default — und Lifecycle-Ereignisse oder `dispose`
können so früh kommen. `_persistSettings()` ist deshalb ein **No-op, solange
`_loaded` nicht gesetzt ist**; sonst überschriebe ein frühes Speichern die
gespeicherten Profile mit einem leeren „Standard". Wirft der Store beim Laden
(Keystore-Fehler erreichen Dart als `PlatformException`), endet der Start im
Zustand `_loadFailed` statt für immer im Boot-Platzhalter: nichts wird
geschrieben — das Gespeicherte kann intakt und nur gerade unlesbar sein —, und
`_retryLoadSettings` liest erneut. Der Fehlerzustand hat eine zweite,
destruktive Aktion für einen Speicher, der unlesbar bleibt: „Gespeicherte
Daten zurücksetzen" (`_resetStoredData` → nach einer Bestätigung, die nennt,
was verloren geht, `AppConfigStore.reset()` → `resetSecureStorage`, §6; danach
liest die App neu wie bei einem Erststart). Der Dialog nennt den Fall, dass
App-Daten von einem anderen Handy übertragen wurden — sie lassen sich ohne
dessen Keystore-Schlüssel nicht entschlüsseln (die Extraktionsregeln in §9
schließen eine solche Übertragung ab Android 12 aus). Scheitert auch das
Zurücksetzen, verweist die Meldung auf das Löschen der App-Daten in den
Android-Einstellungen.

**Theme:** Hell/System/Dunkel wählbar (`themeModeNotifier`, „Design"-Umschalter).
Das App-Theme baut das öffentliche `buildAppTheme(Brightness, {fontFamily})` —
Single Source of Truth, auch vom Screenshot-Generator (`test/screenshots.dart`)
genutzt; `kGreen` aliast `KythWordmark.kWordmarkGreen`. **Ausnahme:** der
`_LockScreen` (Fingerprint-Startscreen direkt nach dem dunklen Splash-Video) ist
per `Theme(data: buildAppTheme(Brightness.dark))`-Wrapper **fest dunkel** —
unabhängig vom App-Theme, damit kein heller Blitz erscheint.

**Sprache (v0.58, l10n):** komplette UI-Schicht Deutsch/Englisch via Flutter
`gen-l10n`: `lib/l10n/app_{de,en}.arb` (~670 Keys; generierte
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
- **`_prepare()` startet nur aus der Ruhe:** Es liefert auch dann `null`, wenn
  `_busy` schon gesetzt ist — der zentrale Schutz für Handler, die seit ihrem
  eigenen `if (_busy) return;` auf einen Dialog gewartet haben. `_run` hält
  `_busy` während des Release-Notes-Schritts selbst und gibt es deshalb
  unmittelbar vor `_prepare()` zurück (kein `await` dazwischen, also keine
  Lücke).
- **Im Demo** liefert `_prepare()` die feste `_demoConfig` (keine
  Feldvalidierung, kein Speichern, §6 `demo.dart`); `_prepare(real: true)`
  gehört dem echten Verbinden.
- **Auch die Adress-Vorprobe läuft im `_guard`** (v0.71.0): `_testConnection`
  ruft `_pickReachableHost` (Heim-/Tailnet-Adresse sondieren) **innerhalb** des
  Guards. Die Probe kann werfen — `probeConnection` reicht einen gewechselten
  Host-Key durch (§4) —, und außerhalb gäbe nichts `_busy` frei, und die
  Host-Key-Leiste erschiene nie. `_lastConfig` nennt während einer Probe die
  **sondierte** Adresse (auch bei der Tailnet-Probe in `_checkRemoteAccess`),
  damit „Neuen Key vertrauen" den richtigen Eintrag vergisst — das ist nicht
  unbedingt die Adresse im Host-Feld. Ein Host, der keiner der beiden gemerkten
  Adressen entspricht, wurde absichtlich getippt und wird unverändert benutzt.
- **Abbrechen in der UI:** `_cancel` setzt zusätzlich ein eigenes
  `_cancelRequested` (zurückgesetzt in `_beginBusy`). Der Abbruch-Zustand des
  Updaters gehört zu der Verbindung, die beim Tippen offen war — die nächste
  weiß nichts davon (§2 „Cancel"); das Flag der UI
  deckt Abläufe mit mehreren Verbindungen oder noch ohne Verbindung ab: die
  Vorprobe (`probeConnection` meldet einen abgebrochenen Versuch als „nicht
  erreichbar" — ohne das Flag liefe das Verbinden nach „Abbrechen" weiter) und
  den Release-Abruf vor dem evcc-Update (dort gibt es noch keine Verbindung,
  die sich schließen ließe; nach einem gescheiterten Abruf gibt es auch keinen
  Bestätigen-Dialog, das Update startete sonst ungefragt).
- **`_statusOk` ist kein Erfolgssignal einer einzelnen Aktion:** es trägt noch
  das Ergebnis der vorigen. Wer nach dem Guard weitermachen will, führt den
  Erfolg über eine lokale Variable aus dem Guard-Body heraus
  (`_setupRemoteAccess`, `_tailscaleUp` — „keine Login-URL" heißt sonst auch
  „der Body hat geworfen"). Die Neuerkennung nach `tailscale up` läuft im
  Guard, damit die App gesperrt bleibt, bis die Karten wieder die des Pi sind.
- **Bewertungs-Anfrage:** das `finally` von `_guard` ruft nach dem Freigeben
  von `_busy` `_maybeAskForReview`, wenn die Aktion einen Verlaufseintrag
  geschrieben hat (§6 `review_prompt.dart`).
- **Geteilte Leisten über allen Tabs** (weil Aktionen aus jedem Tab starten): die
  **Running-Bar** (Fortschritt + `_busyMessage` + „Log"-Sprung + Abbrechen) ist an
  `_busyMessage != null` gekoppelt (nicht `_busy`) → zeigt echte SSH-Arbeit, nicht
  während ein Bestätigen-Dialog `_busy` hält; die **Host-Key-Leiste**; der
  **Status-Banner**. `_guard` setzt `_busyMessage` für **jede** Aktion —
  `backgroundMessage`, sonst ein Text, den der Handler vorher selbst gesetzt
  hat (das Verbinden), sonst `busyDefault`; an `backgroundMessage` hängt nur
  noch der Keep-Alive. `_stopLabelFits` misst, ob der beschriftete
  Stopp-Knopf neben „Log" der Meldung noch 64 dp lässt; sonst wird er zum
  `IconButton` mit der Beschriftung als Tooltip („Abbrechen" wie „Nicht mehr
  mitlesen"; der „Log"-Sprung bleibt Text).
- **Rückmeldung dort, wo der Nutzer hinsieht:** Was entsteht, während ein
  Sheet offen ist, wird **im Sheet** gezeigt — ein Snack läge darunter.
  `_AlertsSheet` bekommt keinen Snack-Callback: `onTest` liefert ein
  Ergebnis-Record, das als Statuszeile erscheint (und in den sichtbaren
  Bereich gescrollt wird), das fehlende Topic ist `errorText` am Feld; der
  Sperr-Schalter in `_openSettings` zeigt seinen Fehler als Subtitle. Ist das
  Sheet inzwischen zu, fällt die Meldung auf einen Snack zurück.
  **Konvention für Dialoge:** Ein `AlertDialog` mit einer `Column` als Inhalt
  ist `scrollable: true` (Passphrase, Pi-hole-Passwort, Host-Key-Vertrauen),
  damit auf kleinen Displays und bei großer Schrift nichts abgeschnitten
  wird. **Tap-Ziele und Semantik:** `_legalLink` und der ntfy-Link haben ein
  48-dp-Ziel; der aktive Status der drei Automatik-Sheets nutzt `_themeGreen`
  (lesbar auch im hellen Theme); das Verbunden-Icon und die Multi-Pi-Ampel
  tragen Semantik-Labels.
- **Achtung:** Flows, die nach `_prepare()` an eine Page/ein Sheet übergeben
  (heute `_guidedSetup` mit seinem Auswahl-Sheet), müssen `_busy` selbst
  freigeben — sonst UI-Deadlock. Mehrphasige Flows
  (Liste→Auswahl→Bestätigen→Aktion) rufen vor dem zweiten `_guard` erneut
  `_beginBusy()`.
- **Profile:** Umschalter in der App-Leiste (`Key('profileSwitcher')`, neutrales
  Server-Icon — *keine* Farbe, die wie Status-LED wirkt); pro Zeile ⋮
  (umbenennen/löschen). Wechsel ruft `_resetDetectionForNewPi()` (nichts leckt
  zwischen Pis — der Reset umfasst auch die Live-Werte `_evccLive` und die nur
  im Speicher gehaltene `_remoteAccessPhase`) und **danach** `_applyProfile()`,
  das den gemerkten Kartenstand des Ziel-Profils lädt (§6). Der **Import**
  übernimmt vorher die Live-Eingaben des aktiven Profils (`_currentProfile()`,
  wie Wechseln und Hinzufügen) — das Speichern danach schreibt das verlassene
  Profil so, wie es in der Liste steht — und wird nicht angewendet, wenn
  während Dateiauswahl, Passphrase und Entschlüsselung eine Aktion gestartet
  wurde (`_busy`). Die importierten Profile gehen durch `profilesForImport`
  (ntfy-Ziel, §6).
- **Multi-Pi-Überblick:** `_MultiPiDashboardPage` (in `ui_widgets.dart`) zeigt
  eine Ampel-Zeile pro Profil (grün / amber = Updates·Warnung / rot = nicht
  erreichbar). `_showMultiPiDashboard` friert die Profil-Liste ein (aktives
  Profil aus den Live-Controllern via `_currentProfile()`) und übergibt
  `_probePi`. Die Page **probt sequenziell** (`_probePi` baut per
  `_configForProfile` eine `SshConfig` — `port` ist String → `int.tryParse`,
  `pi`-Default — und ruft `detectServices`), **fail-soft** (jeder Fehler →
  `reachable:false`, kein Abbruch der übrigen), abbrechbar durch Verlassen der
  Page (`_cancelled`), mit Refresh-Action. Eintrag im ⋮-Menü nur bei
  `_profiles.length > 1`, Pro-gated (über `_proGate`; `multiPi` in der
  `ProFeature`-Liste).
  **Bulk-Update:** App-Leisten-Knopf „Alle aktualisieren" iteriert sequenziell
  über die erreichbaren Pis MIT Updates (`update`-Callback = `_updatePiSystem` →
  `upgradeSystem` pro Profil), **fail-soft** (ein Fehler stoppt die übrigen
  nicht), Status pro Zeile, danach Re-Probe. Der Callback liefert
  **`PiUpdateOutcome`** (`ok`, `note`) statt eines `bool`: Eine `JobException`
  (der Pi-Job läuft ohne die App weiter, oder der Pi ist mit einem anderen
  beschäftigt) ist weder Erfolg noch Fehlschlag — die Zeile zeigt dann amber
  den Satz aus `_jobExceptionText` in voller Länge (er endet mit der Anweisung,
  wo sich der Job mitlesen lässt) statt „Update fehlgeschlagen". „Neu prüfen"
  (`_recheck`) leert die Ergebniszeilen, weil sie Vorrang vor dem Probe-Ergebnis
  haben und die neue Prüfung sonst unsichtbar bliebe; die automatische Re-Probe
  nach dem Sammellauf lässt sie stehen. Der Sammellauf läuft hinter **einem**
  Keep-Alive um den ganzen Lauf (`onBulkStart`/`onBulkEnd` an
  `_MultiPiDashboardPage`, verdrahtet mit `_keepAliveBegin`/`_keepAliveEnd`,
  Benachrichtigungstext `busySystemUpgrade`) — nicht einer je Pi: Android 12+
  schränkt das Starten eines Vordergrunddienstes aus dem Hintergrund ein, ein
  Stopp zwischen zwei Pis könnte endgültig sein. `_updateAll` klammert und
  probt danach neu, `_updateEach` ist die Schleife. Einen Bestätigungsdialog
  hat der Sammellauf nicht.
- **Karten:** nicht-installierte Dienste (außer `system`) werden zu
  `_AddableService`-Picker-Einträgen, nie Karten. `_ServiceCard`-⋮ hat stabiles
  `ValueKey('menu-${id}')`. Pro-Aktionen zeigen Free-Nutzern ein Schloss, der Tap
  feuert trotzdem (Gate in der Callback via `_proGate` → `_showPaywall`).
  `_CardAction.lockedHint` (nicht null = der Eintrag ist ausgegraut, nicht
  antippbar und trägt die Hinweiszeile): „Pi neu starten" und „Pi
  herunterfahren" der System-Karte setzen ihn, solange `_connected` falsch
  ist — wie die gleichen Einträge im App-Menü; eine gemerkte Karte ist keine
  Sitzung.
- **Onboarding:** `_SetupGuidePage` (in `ui_widgets.dart`) erklärt Einsteigern die
  Pi-Einrichtung per Raspberry Pi Imager (SSH/Benutzer/WLAN). Erreichbar via
  `_openSetupGuide()` aus dem ⋮-Menü **und** als Link auf dem Verbindungs-Screen
  unter „Pi im WLAN suchen". Beide stehen dort nur, solange der Pi **unbekannt**
  ist (kein gemerktes `lanHost`/`tailscaleIp` = nie erfolgreich verbunden); bei
  einem bekannten Pi kommt nur die Suche zurück, wenn die letzte Verbindung
  scheiterte (`_connectionOk == false` — die Adresse kann sich geändert haben).
  Das ⋮-Menü behält die Suche immer. Vom Demo-Einstieg unabhängig.
- **Dateien-Tab:** `_FilesView` (in `ui_widgets.dart`) = eingebetteter Browser
  (durchsuchen/vorschau/hochladen/löschen). **Gebaut nur mit Sitzung**
  (`_connected`, siehe „Verbundene Sitzung") und mit einer Config aus
  `_filesConfig()` (leise, ohne `_busy`; im Demo `_demoConfig`) — sonst steht
  der „erst verbinden"-Platzhalter; Pro-gated (`_filesPlaceholder` für Free).
  Der `ValueKey` des Views enthält Profil, Host, Port **sowie Demo- und
  Sitzungszustand**: eine Demo-Liste steht nie für die eines echten Pi und
  umgekehrt, und ein Wechsel listet neu. Datei-Ops (`_filesList/_filesOpen/
  _filesUpload/_filesDelete`) verbinden pro Aktion selbst (wie der frühere
  Browser, ohne `_guard`) — sie laufen damit **neben** einer `_busy`-Aktion,
  weshalb der Updater alle offenen Verbindungen führt (§2 „Cancel");
  `_filesUpload` nutzt den `FilePickerService`-Seam. Der View serialisiert Taps
  gegen doppelte Verbindungen.
  Ihren Teil der Fehlerbehandlung übernimmt **`_fileOpFailed`**: Die Meldung
  der Logik-Schicht geht ins Log und wird angezeigt (als Snack; die Liste
  zeigt ihren Fehler an Ort und Stelle). Ein geänderter Host-Key wird
  behandelt wie in `_guard` — Banner, `_hostKeyIssue`, Sitzung beendet,
  `_lastAction` = Verbinden (die „Neuen Key vertrauen"-Leiste verbindet neu,
  was immer die Operation war). `onUpload` bekommt die geladene Liste mit:
  Eine Datei gleichen Namens verlangt eine destruktive Bestätigung (der Upload
  ersetzt sie als root, ohne Weg zurück), ein Ordner gleichen Namens wird
  abgelehnt — beides, bevor etwas zum Pi geht.
- **Terminal/Konsole:** `interactiveCommandHint` (commands.dart) fängt TUI-Befehle
  (htop/vi/less/`-f`) ab und zeigt eine Alternative, statt „Error opening
  terminal" — die Konsole hat kein PTY. `runConsoleCommand` kappt die Ausgabe
  serverseitig: `{ <befehl>⏎} 2>&1 | head -c 262144` — die schließende Klammer
  steht auf einer **eigenen Zeile** (nach ` ; }` verschluckte ein Kommentar im
  Befehl die Klammer, und ein abschließendes `&` oder `;` war ein Syntaxfehler);
  der Demo-Runner parst genau diese Form. Das Passwort für `sudo …` kommt nur
  auf stdin, wenn sudo danach fragt (§2).
- **`kyth_splash.dart`**: `splashDoneNotifier` (default `true`, damit Tests/Hot-
  Reload nie blockieren); der Lock wartet darauf, bevor die Biometrie kommt.
  `KythSplashGate` sitzt in `MaterialApp.builder` um die `AppLockLayer` (s. o.
  „Aufbau der App").
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
  überlebten die Batch-Umstellung; wie der echte Batch trägt der
  synthetisierte das stderr einer Probe in ihrem Abschnitt und den Endmarker
  am Schluss; `stdinsByCommand` führt **jedes** stdin je Befehl — alle
  Root-Skripte laufen unter demselben Befehl), `FakeEvccUpdater` (überschreibt
  jede von der
  UI genutzte Methode — neue Methode = hier überschreiben, sonst
  `UnimplementedError`; `diskByPath`/`diskErrors` und `logError` für den
  Speicherplatz-Explorer und das Live-Log), `_FakeStore`, `_FakeEntitlement`,
  `_FakeKeepAlive` (hält die Kanal-Texte fest),
  `FakeSecureStorage`, `FakeHostKeyStore`. `UpdaterPage` nimmt dafür optional
  u. a. `historyStore` (Verlauf beobachten ohne Secure Storage),
  `reviewRequester`, `installChannel`, `clock`, `urlOpener` und
  `recentsPreview` entgegen — die Tests der
  Bewertungs-Anfrage brauchen so weder einen Plattform-Kanal noch einen
  `PackageInfo`-Mock. `_readyNoOffer` in `dispatch_test.dart` ist die
  eingerichtete Config mit weggeklicktem Fernzugriff-Angebot, für
  Layout-Tests auf schmaler Fläche.
- **App-Sperre:** `test/app_lock_test.dart` pumpt `EvccPiToolApp(home:
  UpdaterPage(...), splash: false)` — die Sperre, wie die App sie verdrahtet:
  was sie mit offenen Routen macht, was darunter erreichbar ist, was
  System-Zurück tut, dazu die Recents-Vorschau und die Zeitgrenze für den
  Dateiwähler. Die übrigen Widget-Tests pumpen `UpdaterPage` direkt und sehen
  damit das Verhalten **ohne** Sperrschicht (§6 `app_lock.dart`).
- **Zwei Netze:** *innen* Command-Contract-Tests (exakte Befehlsstrings +
  Quote-Fuzzing mit `';reboot;'`), *außen* UI-Dispatch (echte `UpdaterPage`,
  Tab→Aktion→Fake asserted; `useTallScreen` weil das ListView off-screen nicht
  baut). Pins u.a.: Passwort nur als erste stdin-Zeile, nie im Befehl; evcc-Update
  sichert erst; Free-Nutzer erreichen den Pi nie.
- **Pi-Jobs:** `pi_job_test.dart` (Builder, `classifyJobRun`-Tabelle inkl.
  „Exit 0 ohne RC", fremde id, kaputte rc, früher Abbruch; `parseJobStatus`;
  `evaluateJob`),
  `pi_job_bash_test.dart` (echtes bash; die Gruppe um Launcher, Wrapper und
  Follower **nur Linux/CI** — Git Bash hat weder
  flock noch setsid): Start→Mitlesen→RC, Launcher getötet → Job läuft zu Ende,
  BUSY, zurückgelassener Hintergrundprozess hält keinen Lock, LOST, abgeschnittener
  Launcher führt nichts aus, Passwortzeile wird nie ausgeführt, Rechte, umask der
  Payload, Neustart-Sperre. Zwei weitere Gruppen laufen auf der geteilten
  Sandbox (s. u.) auch unter Git Bash: das laufende Auto-Update per
  `ActiveState` für Launcher und Power-Guard, und die Paketlisten im
  Job-Payload. `FakeSshRunner`-Tests für jede Job-Aktion (Abriss/
  Cancel/Watchdog nach STARTED → `jobDetached`, nie „Abgebrochen."). E2E auf
  einem echten Pi: `dart run tool/pi_job_dump.dart <dir>` schreibt Launcher,
  Follower, Guard und eine harmlose Payload (echo/sleep) samt Befehlen.
- **SSH-Adapter Ende-zu-Ende** (v0.71.0): `test/ssh_integration_test.dart`
  lässt den echten `Dartssh2Runner` gegen einen **echten SSH-Partner** laufen —
  `tool/ssh_test_server.py`, ein lokaler asyncssh-Server, der Befehle in einer
  lokalen bash ausführt. Alles andere in der Suite fälscht den `SshRunner`;
  nur hier wird der dartssh2-Transport selbst geprüft: Key-Exchange, TOFU
  (First-Use, geänderter und abgelehnter Key, Fingerprint-Dialog frisst die
  Handshake-Frist nicht), Passwort- und Key-Login (mit einem von der App
  erzeugten Key), exec mit stdin/stdout/stderr und Exit-Status, große Ausgabe
  in ganzen Zeilen, ein über zwei Pakete geteiltes Mehrbyte-Zeichen, ein
  TCP-Reset mitten im Befehl (kein Exit-Status, `close()` bleibt still). Die
  beiden letzten beantwortet der Server selbst (`pitool-test split-utf8` /
  `reset`), weil sie Kontrolle über die Leitung brauchen. Ein drittes
  Server-Kommando, `pitool-test freeze <s>` (antwortet <s> Sekunden lang gar
  nicht — wie eine Leitung, die lautlos gestorben ist), trägt die Fälle „die
  Gegenseite antwortet nicht mehr": eine unbeantwortete exec-Anfrage endet
  als `CommandNotStartedException`; `close()` beendet ein `run()`, dessen
  exec-Anfrage noch offen ist oder dessen stdin noch unterwegs ist (der
  Cancel-Pfad — für dartssh2-Upgrades festgehalten); stdin, das die
  Gegenseite nicht nimmt, endet unter dem Inaktivitäts-Timeout; ein
  langsamer Upload, der sich noch bewegt, wird nicht gekappt. **Übersprungen ohne
  `PITOOL_TEST_SSHD_PYTHON`** (Pfad zu einem Python 3 mit `asyncssh`; unter
  Windows zusätzlich `PITOOL_TEST_BASH`) — die CI führt ihn nicht aus.
  **Vor jedem dartssh2-Upgrade laufen lassen** (§1). Die reinen Bausteine
  (`LineBuffer`, `Utf8ChunkDecoder`, `withinActiveTime`, `withinOrDiscard`,
  `inPieces`, `resolveExitCode`)
  testet `dartssh2_runner_test.dart` ohne Server.
- **Skripte in echter bash gegen einen Sandbox-Pi** (v0.71.0 ausgebaut):
  geprüft wird, was die Skripte auf der Platte hinterlassen und melden, nicht
  welche Teilstrings die Builder enthalten.
  **`test/on_pi_sandbox.dart`** ist die geteilte Sandbox — ein Helfer, kein
  Test: `PiSandbox` (der `PATH` enthält **nur** `bin/`, also Durchreicher für
  die schlichten Werkzeuge und die Stubs des Tests; absolute Pi-Pfade werden
  in die Sandbox umgebogen), `needsBash`, `needsDash`/`sandboxDash` und
  `heredocBody` (der Rumpf eines Heredocs aus einem Install-Skript, also das,
  was auf dem Pi in der Datei landet). Darauf laufen die drei Timer-Wrapper
  samt Install- und Remove-Skripten (`alerts_test.dart`,
  `auto_update_test.dart`, `scheduled_backup_test.dart`,
  `on_pi_wrapper_test.dart`), die Sicherheits-Probe und ihre Fixes
  (`security_check_test.dart`), Home-Assistant-Install, -Backup und -Restore
  (`homeassistant_service_test.dart`: echtes tar, docker als Stub, Fälle mit
  geschlossenem Kanal), die Stack-Verdrahtung (`stack_wiring_test.dart`),
  `piConnectSigninCommand` (`pi_connect_test.dart`), die Key-Installation
  (`ssh_keys_test.dart`), das Schreiben von Configs samt echtem Symlink
  (`commands_test.dart`; unter Git Bash über `MSYS=winsymlinks:…`) und zwei
  Gruppen von `pi_job_bash_test.dart`. Die `#!/bin/sh`-Wrapper und alles, was
  die App über `sh -c` schickt, laufen zusätzlich unter **dash**, wo eines
  installiert ist: dash ist das `/bin/sh` eines Pi, unter Git Bash ist
  `/bin/sh` eine bash und ließe Bashismen durchgehen.
  Eigene Sandboxes gleicher Bauart: `test/backup_scripts_test.dart`
  (evcc-Backup und -Restore, Backup-Listen, Restore der Timer-Archive nach
  einem echten Wrapper-Lauf, Pi-hole-Teleporter, HA-Restore, Timer-Wrapper
  und Remove-Skripte, Config-Sicherungen — `tar`, `pihole`, `pihole-FTL`,
  `curl`, `systemctl`, `docker` als Stubs), `test/install_arch_guard_test.dart`
  (die Installskripte für Home Assistant, InfluxDB und evcc),
  `test/files_test.dart` (Listen, Lesen, Upload), `test/install_detect_test.dart`
  (`buildDetectBatch`) und `_DetectBox` in `test/evcc_updater_test.dart` (der
  Batch, den der Updater wirklich schickt, gegen Stub-Kommandos), dazu
  bash-Gruppen in `commands_test.dart` (`dockerRunRecreateScript`),
  `system_service_test.dart`
  (Paketlisten-Refresh), `tailscale_test.dart` (Status-Proben je
  Backend-Zustand) und `evcc_updater_test.dart` (Konsolen-Wrapper). Linux/CI
  nimmt `bash`; unter Windows laufen die Gruppen nur mit `PITOOL_TEST_BASH`
  (Pfad zu Git Bash — ein bloßes `bash` kann dort der WSL-Starter sein).
  **Regel für jede Sandbox: das Stub-Verzeichnis IM Skript vor den `PATH`
  setzen** (`export PATH='<sandbox>/bin'…` als erste Zeile dessen, was die bash
  ausführt — allein oder vor `$PATH`), nicht nur über die Prozess-Umgebung —
  und in bashs eigener Schreibweise (`/c/…`, nicht `C:/…`): bash trennt
  `PATH` an jedem Doppelpunkt, auch am Laufwerksbuchstaben, und die Stubs
  landeten doch hinter den Verzeichnissen des Starters.
  Git Bashs Starter stellt eigene Verzeichnisse (mit echtem
  `curl`, `sh`, `gpg`, `uname`) **vor** einen geerbten `PATH`; ein echtes
  Binary gleichen Namens gewinnt dann gegen den Stub. Beim Entwickeln des
  Home-Assistant-Guards hat ein Sandbox-Lauf unter Windows so statt der Stubs
  das echte `curl` und `sh` erreicht und Dockers Installationsskript
  heruntergeladen und gestartet. Stubs für Kommandos, die stdin lesen könnten
  (apt, dpkg, docker), leeren stdin — wie unter `sudo -S bash -s` verschluckt
  ein Aufruf ohne eigenes `</dev/null` dann den Rest des Skripts, und der
  Marker bleibt aus.
- **Bewertungs-Anfrage:** `review_prompt_test.dart` (Entscheidung und
  Persistenz), `review_ask_test.dart` (Verdrahtung in der Seite: gefragt wird
  nach der Aktion, die die Schwelle erreicht; Sideload und Demo fragen nie,
  eine gescheiterte Aktion zählt nicht).
- **l10n:** `l10n_keys_test.dart` erzwingt denselben Schlüsselsatz in
  `app_de.arb` und `app_en.arb` — und für `app_de.arb`, dass jedes öffnende
  `„` von `“` geschlossen wird, nicht von einem ASCII-Anführungszeichen.
- **CI** (`.github/workflows/build.yml`): ein Job — (auf Tag: Tag-Name gegen
  die pubspec-Version prüfen) → analyze → test → (auf Tag: Store-Texte gegen die
  Play-Limits prüfen) → signieren → **fat APK** (arm64+armeabi-v7a) + AAB →
  **Signing-Material löschen, bevor** Dritt-Actions laufen → APK-Artefakt → auf
  `v*`-Tag GitHub-Release → **Play-Upload**. Actions SHA-gepinnt, Secrets nur im
  jeweiligen Step, Tag ohne Keystore = harter Fehler.
- **Tag == Version** (Schritt „Require tag to match the pubspec version",
  direkt nach dem Checkout): Der Tag-Name muss `v` + pubspec-Version (Teil vor
  dem `+`) sein, sonst bricht der Lauf ab, bevor etwas gebaut wird. Sonst hinge
  nichts die beiden zusammen: Das GitHub-Release trägt den Tag-Namen, APK/AAB
  und Changelog aber Version und versionCode aus `pubspec.yaml`. Ein Tag auf
  einem Commit ohne Versions-Bump ergäbe ein falsch benanntes öffentliches
  Release, der Play-Upload scheiterte danach am schon verwendeten versionCode,
  und Sideload-Installationen — deren Update-Check den Tag-Namen vergleicht
  (`update_check.dart`) — sähen dauerhaft ein Update-Banner.
- **Pull Requests** (gegen `main`): analyze + test + Debug-APK (arm64) als
  Compile-Check; veröffentlicht und signiert wird nie etwas. Fork- und
  Dependabot-PRs bekommen ohnehin keine Secrets. Ein PR aus einem Branch
  **dieses** Repos bekommt sie — deshalb schließen die drei Signier-Schritte
  (Keystore anlegen, App Bundle bauen, AAB-Artefakt hochladen) das Ereignis
  `pull_request` ausdrücklich aus, sonst entstünde aus ungeprüftem PR-Code
  ein signiertes Release-AAB.
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
  `play_validate` → `validate_only`). Mit `play_dry_run` laufen GitHub-Release
  und `play_release` auf **keiner** Ref — auch nicht, wenn der Lauf von Hand auf
  einer Tag-Ref gestartet wird (`gh workflow run --ref v…`; beide Schritte
  tragen `&& !inputs.play_dry_run`). Die **Einmal-Einrichtung** der Google-Seite
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
- **Ein Build für beide Kanäle:** Play-AAB und GitHub-APK entstehen aus
  demselben Code ohne Flavor. Googles Review-Bibliothek
  (`com.google.android.play:review`, §6) ist eine gewöhnliche
  Gradle-Abhängigkeit und steckt damit **auch in der GitHub-APK**. Aufgerufen
  wird sie dort nie: `shouldRequestReview` verlangt `InstallChannel.play`, und
  der Kanal kommt aus `PackageInfo.installerStore` — alles nicht sicher als
  Play Erkannte gilt als Sideload (§6 `update_check.dart`). Der Satz „ohne
  proprietäre/Google-Bibliotheken" in `store/launch-kit.md` §7 beschreibt den
  Stand vor dieser Abhängigkeit. Die Datenschutzerklärung nennt die
  Bewertungs-Anfrage in einem eigenen Abschnitt.
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
  damit kein Flutter-Upgrade sie stillschweigend abschaltet.
  `isShrinkResources` ist dort nicht gesetzt — das heißt **nicht** „aus": Das
  Flutter-Gradle-Plugin (3.44.4) schaltet das Ressourcen-Shrinking für den
  Release-Build einer App mit ein (außer mit `-Pshrink=false`), und nichts
  setzt es zurück. Eine Ressource, die nur zur Laufzeit per Namen gesucht wird,
  fehlt deshalb allein im Release-Build und braucht einen `tools:keep`-Eintrag
  (`res/raw/keep.xml`; eine solche Datei hat die App heute nicht). Speicher- und
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
- **Keine App-Daten verlassen das Gerät** (Sicherheits-Invariante): Neben
  `android:allowBackup="false"` setzt das Manifest
  `android:dataExtractionRules="@xml/data_extraction_rules"` (ab Android 12
  gelesen, darunter ignoriert). Die Regeldatei
  `android/app/src/main/res/xml/data_extraction_rules.xml` schließt `root`,
  `file`, `database`, `sharedpref` und `external` aus Cloud-Backup **und**
  Gerät-zu-Gerät-Transfer aus — die Domains einzeln, weil ein Ausschluss von
  `root` die anderen nicht abdeckt. Grund: Bei targetSdk ≥ 31 schaltet
  `allowBackup=false` laut Android-Dokumentation den Gerät-zu-Gerät-Transfer
  nicht auf den Geräten jedes Herstellers ab; übertragen würde Chiffrat ohne den Keystore-Schlüssel,
  das sich auf dem neuen Handy nicht lesen lässt (der Fehlerzustand beim
  Laden, §7). Die vier `device_*`-Domains fehlen bewusst: Weder die App noch
  ihre Plugins legen etwas im device-protected Storage ab — ein Plugin, das
  damit anfängt, braucht vier weitere Ausschlüsse. Die Datei ist aus dem
  Manifest referenziert, das Ressourcen-Shrinking behält sie also ohne
  `tools:keep`. Nicht an einem Gerät geprüft.
- **Vor dem Anheben auf targetSdk 37** (heute fest `targetSdk = 36` in
  `android/app/build.gradle.kts`): Ab Android 17 wird der Zugriff aufs lokale
  Netz für Apps mit targetSdk ≥ 37 erzwungen; mit targetSdk 36 ist er über
  `INTERNET` implizit erlaubt. Betroffen ist der Kern der App — SSH zum Pi,
  der /24-Scan („Pi finden") und der evcc-HTTP-Abruf sind ausgehende
  Verbindungen zu LAN-Adressen. Vor dem Sprung nötig: die Berechtigung
  `ACCESS_LOCAL_NETWORK` deklarieren, sie **zur Laufzeit vor dem Verbinden und
  vor dem Scan anfragen**, die Ablehnung behandeln (eigener Fehlertext statt
  „Pi nicht erreichbar") und die Datenschutzerklärung ergänzen. Quelle:
  Android-Dokumentation zur Local-Network-Permission; nicht an einem
  Android-17-Gerät geprüft.

## Bekannte Grenzen (bewusst offen)

Jeder Punkt ist eine Entscheidung, kein übersehener Fehler.

- **Das Live-Log pollt** (§5 `_LiveLogSheet`): Jeder 3-s-Abruf ist eine neue
  SSH-Sitzung. Auf der System-Karte (`journalctl -n 200`) protokollieren
  sshd, PAM und sudo jede dieser Sitzungen in genau dem Journal, das
  angezeigt wird — das Fenster füllt sich mit den Einträgen der App (wie
  schnell, ist nicht an einem Pi gemessen). Dienst-Logs (`-u <unit>`,
  `docker logs`) betrifft das nicht. Ein einzelner `journalctl -f`-Strom
  bräuchte einen Lauf-Modus ohne Pufferung und einen Abbruch je Strom.
- **Der Video-Controller des Splash wird nach dem Splash nicht freigegeben**
  (`kyth_splash.dart`): `KythSplashGate` umschließt die App für die ganze
  Laufzeit und gibt den `VideoPlayerController` nur in `dispose()` frei, im
  Betrieb also nie. Der Mehrverbrauch ist konstant und nicht gemessen.
- **Die Exit-Codes von `rpi-connect on`/`off`/`signout`** werden über einen
  fehlenden Exit-Status hinaus nicht gewertet (§2, §4 `pi_connect.dart`):
  Nicht gemessen ist, welche Codes `rpi-connect` bei harmlosen Wiederholungen
  (schon an, schon aus) liefert.
- **Predictive Back bei gesperrter App** hängt allein am Plattform-Flag
  `SystemNavigator.setFrameworkHandlesBack(false)` (§6 `app_lock.dart`);
  nicht an einem Gerät gemessen. Zwei Dart-seitige Absicherungen sind möglich
  und nicht umgesetzt: ein nicht-prädiktiver `PageTransitionsBuilder` für
  Android in `buildAppTheme`, oder ein an die Sperre gebundener Pop-Eintrag,
  den ein `NavigatorObserver` auf jeder Route registriert.

Weitere bewusste Grenzen stehen an ihrer Stelle: „Abbrechen" stoppt nichts auf
dem Pi (§2 „Cancel"); das Home-Assistant-Archiv ist 0644 (§5 `files.dart`);
die Recents-Vorschau unter Android 12 und älter (§6 `secure_screen.dart`);
der Backup-Wrapper teilt die Generationsnummer der beiden anderen (§5
`on_pi_wrapper.dart`).

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
   App — deren Package dann auch in `<queries>` des Manifests) und
   `..._projectLinkActions(<id>)` ans Ende der `actions` — Eintrag und
   Manifest erzwingt der Guard-Test ohnehin.
5. Ändert der Dienst einen On-Pi-Wrapper (Timer-Backup, Auto-Update, Alerts):
   `wrapperGeneration` erhöhen (§5), sonst bleibt der alte Wrapper auf
   Bestands-Pis unbemerkt.
6. Version bumpen, `whats_new.dart` ergänzen, **diese Doku aktualisieren**,
   analyze+test grün, main-Build, taggen.
