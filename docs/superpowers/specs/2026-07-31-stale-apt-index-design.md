# Veralteter apt-Index: „aktuell" war eine Lüge

Stand: 2026-07-31. Gefunden beim Nachstellen auf einem echten Pi
(`192.168.178.125`, Debian 13 trixie).

## Befund

Die Update-Anzeige aller apt-gestützten Karten hängt an einer Simulation gegen
den **lokalen** Paket-Index des Pi:

```
Karte „Pi Connect" (amberne LED + „Update" im ⋮)
  ⇐ status.updateAvailable                  ui_widgets.dart:1362, main.dart:3844
  ⇐ pcPkg != null                           evcc_updater.dart:546
  ⇐ aptUpgrades enthält rpi-connect(-lite)  evcc_updater.dart:533
  ⇐ parseAptUpgrades("Inst …"-Zeilen)       system_service.dart:192
  ⇐ LC_ALL=C apt-get -s full-upgrade        system_service.dart:12
```

Die App führt bei der Erkennung **nie** ein `apt-get update` aus — das passiert
nur, wenn man ein Update tatsächlich anstößt (`commands.dart:421`). Ist der
Index veraltet, meldet die App korrekt eine veraltete Wahrheit.

Gemessen auf dem Test-Pi:

| | Kandidat laut apt | Simulation (= was die App sieht) |
|---|---|---|
| vorher (Index ~10 Tage alt) | `2.12.1` | `0 upgraded` → kein Update |
| nach `apt-get update` | `2.12.2` | `Inst rpi-connect-lite [2.12.1] (2.12.2 …)` |

**Warum der Index veraltete, obwohl `apt-daily.timer` lief:** Der Timer feuerte,
aber `unattended-upgrades` ist nicht installiert und ohne
`APT::Periodic::Update-Package-Lists "1"` aktualisiert `apt-daily` nichts. Auf
einem Standard-Raspberry-Pi-OS ist ein wochenalter Index der Normalfall.

**Schwere:** Nicht die eine Karte. Die System-Karte meldete „aktuell", während
27 Updates + 8 neue Pakete anstanden — darunter Debian-**Sicherheits**updates
(`bind9-libs`, `libnss3`, samba) und ein Kernel-Sprung 6.18.34 → 6.18.39. Ein
grünes Häkchen über einem Pi mit offenen Lücken ist schlimmer als gar keine
Anzeige.

**Betroffen:** evcc(apt), Grafana, InfluxDB, Mosquitto, Pi Connect, Tailscale,
System. Nicht betroffen: Home Assistant und evcc-über-GitHub-Gegenprobe, weil
die gegen die echte Release-Version prüfen.

## Entscheidung

Nicht bei jeder Erkennung `apt-get update` fahren (sudo-Passwort + 5–30 s
Wartezeit + Mirror-Traffic bei jedem App-Start — bricht das „eine Runde, nur
lesend"-Prinzip der Erkennung). Stattdessen: **das Alter mitlesen, ehrlich sein,
einen Knopf anbieten.** Schwelle **3 Tage** (Stefan, 2026-07-31): trifft den
echten Fehlerfall, bleibt bei gepflegten Pis still. 24 h wäre bei den meisten
Pis ein Dauerhinweis und würde ignoriert.

## Umsetzung

**1. Neue Sonde `APTAGE` im Detect-Batch.** Alter **auf dem Pi** gerechnet, nicht
gegen die Handy-Uhr (Uhrzeit-/Zeitzonen-Abweichung würde das Ergebnis kippen):

```sh
expr $(date +%s) - $(stat -c %Y /var/lib/apt/lists)
```

Kein sudo, world-readable. Dazu der reine Parser
`parseAptListsAgeSeconds(String) → int?`.

**Fail-safe:** nicht lesbar/parsebar → `null` → gilt als *unbekannt*, nicht als
frisch (wie `isPiConnectCompatible`). Wer Aktualität nicht belegen kann,
behauptet sie nicht.

**2. Ein Flag statt sieben Sonderfällen.** In der Erkennung entsteht
`aptFresh = age != null && age < 3 Tage`; alle apt-gestützten Karten bekommen
`updateKnown: aptKnown && aptFresh`.

Mit an Bord, sonst Regression: `applyLatestEvccVersion` setzt `updateKnown: true`
bisher nur, wenn GitHub eine *neuere* Version meldet. Bei „du bist aktuell"
bleibt das Flag unberührt — mit dem neuen Gating verlöre evcc sein berechtigtes
„Aktuell ✓". Also bei jedem *gelungenen* Vergleich setzen, egal wie er ausgeht.
Home Assistant macht das bereits so.

**3. UI.** Die System-Karte erklärt den Zustand einmal im Detailtext
(„Paketlisten N Tage alt — Stand unbekannt") und bekommt im ⋮-Menü
**„Paketlisten aktualisieren"** (`sudo -S apt-get update`, danach neu erkennen),
nach dem Handler-Pflichtmuster aus CLAUDE.md. Nicht Pro-gated — Hygiene, kein
Feature.

Bewusst **nicht** auf jeder betroffenen Karte wiederholt: sechs Karten mit
demselben Satz wären eine Warnungswand. Die Karten hören schlicht auf, „Aktuell
✓" zu behaupten, und bieten weiter „Aktualisieren" an.

**4. Tests.** Parser-Tests fürs Alter; Erkennungstest, dass ein alter Index
`updateKnown` über alle Karten kippt; Test für die evcc-Korrektur;
Dispatch-Test für ⋮ → „Paketlisten aktualisieren"; Demo-Modus liefert einen
frischen `APTAGE`-Abschnitt, damit die Demo grün bleibt.

**5. Doku + Release.** ARCHITECTURE (neue Sonde + Gating), `whats_new.dart`,
fastlane-Changelog `121.txt` de/en → v0.63.7+121.
