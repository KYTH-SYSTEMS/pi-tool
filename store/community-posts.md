# Community-Posts (fertige Entwürfe)

Stand: 2026-07-29. Der größte Reichweiten-Hebel für Pi-Tool liegt **nicht** in der
Play-Suche — die Suchmenge nach „evcc" & Co. ist winzig —, sondern dort, wo die
Zielgruppe ohnehin sitzt. Play verstärkt danach über Bewertungen und
Installationsrate. Reihenfolge und fertige Texte stehen hier; Hintergrund in
`launch-kit.md`.

## Reihenfolge und Hausregeln

1. **evcc GitHub Discussions → 💬 General** — Kernzielgruppe, überwiegend
   deutschsprachig. **Nicht** in „#️⃣ Announcements": die Kategorie gehört den
   Maintainern. Eine „Show and tell"-Kategorie gibt es dort nicht (geprüft
   2026-07-29).
2. **Photovoltaikforum.com** — größte deutsche PV/Speicher-Community.
3. **GoingElectric.de** — EV-Forum, dieselben Leute in anderer Ecke; kurz halten.
4. **r/selfhosted** — international, mag Eigenbau, verlangt offene
   Entwickler-Kennzeichnung. Regeln im Sidebar vorher prüfen (Reddit ließ sich
   nicht automatisiert auslesen).
5. **Mastodon** (#selfhosted #raspberrypi #evcc) — billig, wohlwollendes Publikum.

**Drei Regeln, an denen es sonst scheitert:**
- **Erste Zeile: „Ich bin der Entwickler."** Ohne das gilt der Post als Spam.
- **Nicht denselben Text überall einkopieren** — Foren erkennen das sofort.
- **Auf Antworten antworten.** Der Thread danach bringt die Installationen, nicht
  der Post. Deshalb auch nicht alles am selben Tag posten.

**Timing:** erst posten, wenn das jeweils aktuelle Release live ist — sonst
sehen die Leute im Store einen anderen Stand als beschrieben.

---

## 1. evcc GitHub Discussions (General)

**Titel:** Pi-Tool: Android-App, um evcc & Co. auf dem Pi per SSH zu aktualisieren (inoffiziell)

```
Hi zusammen,

vorweg: Ich bin der Entwickler, und das Ding ist inoffiziell — es hat mit dem
evcc-Projekt nichts zu tun und ist auch kein Ersatz für die offizielle App.

Mich hat gestört, dass ich für ein evcc-Update jedes Mal den Laptop aufklappe,
mich per SSH auf den Pi hänge und apt tippe. Also hab ich mir eine kleine
Android-App gebaut, die genau das vom Handy aus macht. Inzwischen kann sie
etwas mehr:

- evcc aktualisieren (erkennt selbst, ob apt oder Docker), Live-Status,
  Backup von Config + DB vor dem Update, Wiederherstellen
- daneben Pi-hole, Home Assistant, Grafana/InfluxDB/Mosquitto, AdGuard,
  Node-RED, Zigbee2MQTT — je nachdem, was auf dem Pi läuft
- Automatik läuft als systemd-Timer auf dem Pi, nicht als Hintergrunddienst
  auf dem Handy: geplante Updates mit Selbstheilung, nächtliche Backups,
  Health-Alerts per ntfy
- evcc.yaml direkt bearbeiten (atomar, mit Backup), Terminal, Dateibrowser

Was sie nicht ist: eine Lade-Steuerung. Dafür gibt's die offizielle evcc-App.

Technisch: reines SSH, kein Backend, kein Konto, keine Cloud, keine Werbung,
kein Tracking. Zugangsdaten bleiben verschlüsselt auf dem Gerät, Host-Key wird
beim ersten Verbinden bestätigt (TOFU). Code ist offen (MIT).

Play Store: https://play.google.com/store/apps/details?id=systems.kyth.pitool
Quellcode + APK: https://github.com/KYTH-SYSTEMS/pi-tool

Wer's ohne Pi anschauen will: auf dem ersten Bildschirm gibt's einen
Demo-Modus mit Beispieldaten.

Warnung, ehrlich gesagt: Die App setzt auf deine Anweisung sudo-Befehle auf
dem Pi ab. Backups schaden nie.

Über Rückmeldungen freue ich mich — vor allem, wenn was nicht funktioniert.
```

---

## 2. Photovoltaikforum

**Titel:** evcc vom Handy aus aktualisieren – kleine Android-App (inoffiziell, Eigenbau)

```
Moin,

ich bin der Entwickler und das ist Eigenbau, kein offizielles evcc-Ding.

Der Auslöser war simpel: Für jedes evcc-Update den Rechner hochfahren und per
SSH auf den Pi — das nervt irgendwann. Jetzt macht das eine Android-App: Pi
auswählen, verbinden, sie erkennt selbst was läuft, und dann ein Tap.

Sie kann inzwischen auch Pi-hole, Home Assistant, Grafana/InfluxDB/Mosquitto
und ein paar mehr, macht vor dem evcc-Update automatisch ein Backup (Config +
DB) und kann es auch wieder zurückspielen. Zeitgesteuerte Updates und
nächtliche Backups laufen als systemd-Timer auf dem Pi selbst — das Handy muss
also nicht mitspielen. Und wenn die Platte volläuft oder ein Dienst stirbt,
kommt eine Push-Nachricht per ntfy.

Kostenlos, keine Werbung, kein Tracking, kein Konto, kein Server von mir. Alles
läuft über eure eigene SSH-Verbindung. Quellcode ist offen (MIT).

https://play.google.com/store/apps/details?id=systems.kyth.pitool

Im Play Store gibt's einen Demo-Modus, damit man ohne Pi reinschauen kann.

Was ich noch nicht kann und was ihr euch wünscht: immer her damit.
```

---

## 3. GoingElectric

**Titel:** Android-App: evcc & Pi-hole auf dem Raspberry Pi per SSH aktualisieren

```
Hallo zusammen,

Eigenbau, ich bin der Entwickler, inoffiziell.

Ich wollte evcc nicht mehr jedes Mal per SSH vom Laptop aktualisieren, also
gibt's jetzt eine Android-App dafür: verbinden, sie erkennt was auf dem Pi
läuft, ein Tap pro Dienst. Mit Backup vor dem evcc-Update, optional
zeitgesteuert per systemd-Timer auf dem Pi, plus Push-Warnung wenn die Platte
volläuft oder ein Dienst weg ist.

Kostenlos, ohne Werbung/Tracking/Konto, Quellcode offen (MIT), läuft
ausschließlich über eure eigene SSH-Verbindung.

https://play.google.com/store/apps/details?id=systems.kyth.pitool

Demo-Modus ist drin, man kann's also ohne Pi anschauen. Feedback gern.
```

---

## 4. r/selfhosted

**Titel:** I got tired of SSHing into my Pi to update evcc and Pi-hole, so I built an Android app for it

```
Dev here, this is my own project — free, no ads, no tracking, no account, no
backend of mine. Source is MIT on GitHub.

The itch: every update of my self-hosted stuff meant opening the laptop, SSHing
into the Pi and typing apt commands. Now it's a phone app: connect, it detects
what's actually running on the box, and each service gets a card with the
actions that make sense for it.

Currently handles evcc, Pi-hole, Home Assistant, Grafana, InfluxDB, Mosquitto,
AdGuard Home, Node-RED, Zigbee2MQTT, plain Docker containers and the OS itself
(apt full-upgrade, reboot, health readout, SD-card check).

Two design decisions people here might care about:

- No backend, no account, nothing phones home. It is literally an SSH client
  with a UI. Credentials stay in the Android keystore, host keys are pinned on
  first connect.
- Automation runs as systemd timers on the Pi, not as a background service on
  the phone. Scheduled updates (with a backup + self-heal), nightly backups
  with rotation, and health alerts pushed via ntfy. Your phone can be off.

Also does config editing (atomic, with backup), a file browser and a terminal.

https://github.com/KYTH-SYSTEMS/pi-tool
https://play.google.com/store/apps/details?id=systems.kyth.pitool

There's a demo mode on the first screen if you want to poke around without a Pi.

Fair warning: it runs sudo commands on your box when you tell it to. Keep
backups.
```

---

## 5. Mastodon

```
Ich wollte nicht mehr jedes Mal den Laptop aufklappen, nur um evcc auf dem
Raspberry Pi zu aktualisieren. Also: Android-App, reines SSH, kein Backend,
kein Konto, kein Tracking. Erkennt selbst was läuft — evcc, Pi-hole, Home
Assistant, Docker & Co. Automatik läuft als systemd-Timer auf dem Pi, nicht auf
dem Handy. Quelloffen (MIT).

https://play.google.com/store/apps/details?id=systems.kyth.pitool

#selfhosted #raspberrypi #evcc #homeassistant #pihole
```

---

## Wenn sich der Funktionsumfang ändert

Die Texte nennen konkrete Dienste und Eigenschaften. Bei größeren Änderungen am
Funktionsumfang hier mitziehen — sonst versprechen die Entwürfe beim nächsten
Posten etwas anderes als die App kann.
