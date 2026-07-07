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
│ UI-Shell        main.dart + ui_widgets.dart (part) + splash  │  Cockpit, 3 Tabs
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
  **verweigert v5 `.tar.gz`** (nur v6-CLI-Import); `pihole restartdns` im Restore
  bewusst *nicht* fehlerverschluckt.
- **`homeassistant_service.dart`** — HA als Docker-Container (bewusst, nicht HA
  OS). tar-Exit 1 auf laufendem HA = Warnung (nur rc>1 = Fehler). Restore per
  `trap` (Container kommt auch bei tar-Fehler zurück) + `.State.Running`-Check.
- **`system_service.dart`** — „System (Pi)"-Karte. `systemPendingCommand`
  simuliert `apt-get -s full-upgrade` (muss zur echten Aktion passen).
  `lowDisk` gate auf *absoluten* freien Platz (1-TB-Disk bei 94% warnt nicht).
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
- **`alerts.dart`** — 30-Min-Health-Check → **ntfy**-Push (backend-frei) bei
  Platte ≥90% / Temp ≥75° / totem Dienst / anstehenden Updates. **Debounce** via
  `alerts.last` (Push nur bei Änderung). **Heredoc-Regel**: ntfy-Server/-Topic
  sind `shSingleQuote`d und landen in einem **quoted** Heredoc (`<<'WRAP'`) → kein
  Install-Zeit-Expand von `$(reboot)`. Blöcke nie zusammenlegen/entquoten.
- **`files.dart`** — Datei-Browser über den normalen Exec-Kanal (kein SFTP → der
  `FakeSshRunner`-Seam deckt ihn ab). `head -c 512K | base64` (Server-seitiges
  Limit gegen OOM bei riesigen Dateien).
- **`notifications.dart`** — **schlafender**, plugin-freier Kern für
  Update-Benachrichtigungen; bewusst *nicht* verdrahtet (v0.20.0-Lektion — kein
  ungetesteter Native-Code im Startpfad).

> **Heredoc-Regel für On-Pi-Skripte:** Dart-`$var` interpoliert *vor* der Shell;
> Dart-`\$` wird literales `$` für die Shell. Alles, was zur Shell-Laufzeit
> expandieren soll, muss in einem **quoted** Heredoc stehen, sonst expandiert die
> installierende Shell es zur Install-Zeit.

## 6. State & Infrastruktur

- **`profiles.dart`** — `Profile` (ein Pi) + `AppConfig` (Profil-Liste + alle
  globalen Settings). `parseAppConfig` ist tolerant (jeder Decode-Fehler →
  `AppConfig.initial`). `backupBeforeUpdate` default **ON** (`!= false`).
  `AppConfigStore` (Key `app_config_v1`) migriert einmalig aus den 14 Legacy-Flat-
  Keys und **löscht sie danach** (kein Klartext-Credential-Rest). Alles
  (Passwörter, PEM-Keys) nur in `FlutterSecureStorage` (Keystore).
- **`settings_store.dart`** — Legacy-Migrationsquelle, `HistoryStore`,
  `SecureHostKeyStore`. Passwort-Feld ist dual: SSH+sudo (Passwort-Modus) bzw.
  nur sudo (Key-Modus).
- **`entitlement.dart`** — **schlafendes Freemium**: `DormantEntitlement` = jeder
  ist Pro (Sideload-Nutzer verlieren nichts vor dem Play-Launch). Pro-Features:
  `backups`, `console`, `cleanup`, `multiPi` (+ 1-Profil-Limit). Echte Play-
  Billing-Impl wird später hinter `EntitlementService` gesteckt. Gate-Punkte nie
  mit `!isPro` inlinen — immer über den Seam / `_proGate`.
- **`update_check.dart`** — Self-Update-Check (nur Sideload-Kanal) + evcc-/HA-
  Versionsproben, alle fail-soft (Fehler → null). `isNewerVersion` numerisch.
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
**Cockpit**: `NavigationBar` + `IndexedStack`, 3 Tabs **Dienste / Automatik /
Terminal**. `ui_widgets.dart` ist ein `part of '../main.dart'` (teilt sich
`kGreen/kBlack/kCard` ohne Re-Import — nicht in einen Import „aufräumen").

**Gate-Reihenfolge in `build()`** (load-bearing): `_booting` (neutraler
Splash-Ersatz) → `_locked` (Lock-Screen) → `!_disclaimerAccepted`
(Ablehnen = App beenden) → einmaliges „Was ist neu?" (post-frame) → Shell.

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
- **Karten:** nicht-installierte Dienste (außer `system`) werden zu
  `_AddableService`-Picker-Einträgen, nie Karten. `_ServiceCard`-⋮ hat stabiles
  `ValueKey('menu-${id}')`. Pro-Aktionen zeigen Free-Nutzern ein Schloss, der Tap
  feuert trotzdem (Gate in der Callback via `_proGate` → `_showPaywall`).
- **`kyth_splash.dart`**: `splashDoneNotifier` (default `true`, damit Tests/Hot-
  Reload nie blockieren); der Lock wartet darauf, bevor die Biometrie kommt.

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

## 9. Verteilung & Recht

- `fastlane/metadata/**` — **einzige** Textquelle für Store-Listing (Titel ohne
  „evcc"/„Pi-hole" → Markenrecht). IzzyOnDroid zieht sie automatisch + das
  signierte APK aus den Releases (HRB-unabhängig).
- `store/**` — Play-Playbook (Data-Safety = „keine Daten", Foreground-Service-
  Deklaration Pflicht), `launch-kit.md`, `izzyondroid-rfp.md`.
- `docs/**` — GitHub-Pages: Landing + `privacy.html` + `impressum.html` (URLs im
  Play-Listing verankert — nicht umbenennen; kein Google-Fonts/Tracking).
- **Launch liegt bis zum HRB auf Eis** (Haftung, UG i.G.).

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
