# Pi-Tool (inoffiziell) — Raspberry-Pi-Cockpit

Schlanke **Android-App** (clean minimal, Hell/Dunkel/System), die deine
**self-hosted Dienste auf dem Raspberry Pi per SSH** installiert, aktualisiert,
sichert, überwacht und wieder entfernt — plus **Fernzugriff** einrichten und
**Dateien** verwalten.
Ein **Cockpit mit vier Tabs** (Verwaltung · Automatik · Terminal · Dateien):
„Verbindung herstellen" erkennt automatisch, was läuft, und zeigt pro Dienst eine
Karte — [evcc](https://evcc.io), Pi-hole, Home Assistant, Grafana, InfluxDB,
Mosquitto und das **ganze System** (alle Pakete via `apt full-upgrade`). Du
verbindest dich **bewusst** und bleibst mit dem Pi verbunden, bis du das Profil
wechselst; erst dann sind Automatik, Terminal und Dateien freigeschaltet. IP +
Pi-Zugang eintragen, tippen, fertig. Verteilung über **Google Play** und als
**APK über GitHub Releases**.

**[➜ Bei Google Play installieren](https://play.google.com/store/apps/details?id=systems.kyth.pitool)**

> Noch **kein Pi**? Die App hat eine eingebaute Schritt-für-Schritt-Anleitung
> („Pi einrichten", per Raspberry Pi Imager: SSH + Benutzer + WLAN).

> ⚠️ Hinweis: Die App führt mit deinem eingegebenen Passwort `sudo`-Befehle
> (`apt`, `pihole`, `systemctl`, ggf. `docker compose`) auf dem Pi aus. Nutze
> sie nur für Geräte, die dir gehören.
>
> ℹ️ **Inoffizielles, unabhängiges** Tool, nicht mit den genannten Projekten (evcc,
> Pi-hole, Home Assistant, Grafana, Tailscale u. a.) verbunden; Namen werden nur
> beschreibend zur Kompatibilität genannt, Marken gehören ihren Inhabern.
> Für die tägliche Lade-Steuerung gibt es die
> [offizielle evcc-App](https://play.google.com/store/apps/details?id=io.evcc.android).

## Funktionen

- **Cockpit mit vier Tabs** — unten umschaltbar: **Verwaltung** (Karten + „+ Dienst
  hinzufügen"), **Automatik** (geplante Updates + Health-Alerts), **Terminal**
  (eigene Befehle) und **Dateien** (Datei-Browser). Der aktive Pi steht oben in der
  Leiste (antippen zum Umschalten/Hinzufügen/Umbenennen). Eine laufende Aktion
  wird auf jedem Tab als Fortschrittsleiste mit „Abbrechen" angezeigt.
- **Bewusst verbinden** — „Verbindung herstellen" baut eine Sitzung zum aktiven Pi
  auf, die bleibt, bis du das Profil wechselst. **Automatik, Terminal und Dateien**
  sind bis dahin dezent gesperrt (ausgegraut) und werden erst nach dem Verbinden
  freigeschaltet. So ist immer klar, wann die App den Pi wirklich kontaktiert.
- **Beim Start automatisch verbinden** — Schalter in der Zugangsdaten-Karte,
  pro Pi und standardmäßig aus. Genau ein Pi kann das: Beim Einschalten wird es
  bei den anderen abgeschaltet. Verbunden wird nur beim App-Start, nicht beim
  späteren Profilwechsel — und nie an der App-Sperre vorbei: Ist sie aktiv,
  bleibt es beim Verbinden von Hand. Bis eine Erkennung vorliegt, zeigt die App
  die Karten des letzten bekannten Stands, gekennzeichnet als „Stand von
  vorhin".
- **Demo-Modus** — „Demo ausprobieren" auf dem Verbindungs-Bildschirm zeigt die
  ganze App mit Beispieldaten (alle Tabs, alle Pro-Features), **ohne** einen echten
  Raspberry Pi — zum Kennenlernen, und damit App-Reviewer die App ohne Gerät prüfen können.
- **Deutsch & Englisch** — die Oberfläche folgt automatisch der Handy-Sprache;
  in den Einstellungen jederzeit fest umschaltbar (System / Deutsch / English).
- **Dienste auto-erkennen** — „Verbindung herstellen" findet evcc, Pi-hole,
  Home Assistant und das System in *einer* SSH-Sitzung und zeigt pro Dienst eine
  Karte (Status, Version, Aktualisieren/Installieren, „Oberfläche öffnen").
  Reißt die Verbindung mitten in der Erkennung ab, meldet die App das als
  unbekanntes Ergebnis, statt einen halben Stand zu zeigen — fehlende Dienste
  sähen sonst aus wie „nicht installiert". Ein Docker-Container (evcc, Home
  Assistant), der in einer Neustart-Schleife hängt oder pausiert ist, steht
  als „inaktiv" mit einem Hinweis auf der Karte.
- **evcc aktualisieren** — erkennt automatisch, ob evcc als **apt-Paket**
  oder im **Docker-Container** läuft, und nimmt den passenden Weg.
- **Pi-hole** — aktualisieren (`pihole -up`), Blocklisten erneuern (`pihole -g`),
  DNS neustarten, installieren (experimentell), `/admin` öffnen.
- **Home Assistant** — als **Docker-Container** installieren (installiert bei
  Bedarf zuerst Docker, experimentell) und aktualisieren (Image-Pull + Neuanlage,
  Daten im `/config`-Volume bleiben erhalten; Details und Grenzen unter
  [Docker-Installation](#was-die-app-macht)), Web-UI auf Port 8123 öffnen. Bei
  der Installation bekommt der Container die Zeitzone des Pi; ein Update
  behält die Umgebung, die der Container hat.
- **AdGuard Home, Node-RED & Zigbee2MQTT** — werden erkannt, wenn sie als
  systemd-Dienst laufen: eigene Karte mit Weboberfläche öffnen, Logs und
  Neustart. (Installation überlässt die App bewusst dir.)
- **Grafana, InfluxDB & Mosquitto** — werden automatisch erkannt, wenn per apt
  installiert: eigene Karte mit Update (apt `--only-upgrade`) und Web-UI
  (Grafana :3000, InfluxDB v2 :8086; Mosquitto ist ein MQTT-Broker ohne Web-UI).
- **Zu den Projekten springen** — jede Dienst-Karte führt über ihr ⋮-Menü zur
  **Website des Projekts** und, wo es sie wirklich gibt, zur **offiziellen App**
  (evcc, Home Assistant, Tailscale). Die App wird direkt geöffnet, wenn sie
  installiert ist, sonst öffnet sich ihr Play-Eintrag. Nicht zu verwechseln mit
  „Web öffnen" — das ist die Oberfläche auf deinem Pi.
- **Dienst hinzufügen** — der Hauptbildschirm zeigt nur **installierte** Dienste
  als Karte; ein „+ Dienst hinzufügen"-Knopf öffnet eine Auswahl **aller noch
  nicht installierten** Dienste (evcc, Pi-hole, Home Assistant, Grafana,
  InfluxDB, Mosquitto) und installiert den gewählten (experimentell). So bleibt
  die Übersicht schlank, egal wie viele Dienste unterstützt werden.
  Home Assistant (Container) und InfluxDB 2 gibt es nur für 64-Bit
  (arm64/amd64): Auf einem System, auf dem sie nicht laufen können, lehnt die
  App die Installation mit Begründung ab, bevor sie etwas einrichtet.
- **Dienste deinstallieren** — im ⋮ jeder Karte, deren Dienst die App auch
  installieren kann (evcc per apt, Home Assistant, Pi Connect, Tailscale,
  Grafana, InfluxDB, Mosquitto). Standard: Das Programm verschwindet,
  Konfiguration und Daten bleiben — eine spätere Neuinstallation übernimmt sie.
  Mit dem Häkchen „Auch Konfiguration und Daten löschen" gibt es den kompletten
  Rückbau samt eigener Paketquelle. Vorher prüft das Skript, ob das sicher geht
  (etwa: apt würde nichts anderes mitnehmen, die Verbindung läuft nicht über das
  zu entfernende Tailscale) und bricht sonst mit einem Grund ab, ohne etwas zu
  ändern. Pi-hole bewusst noch nicht: Es ist oft der DNS des ganzen Netzes.
- **Fernzugriff mit einem Knopf einrichten** — bist du mit dem Pi verbunden,
  bietet die Verwaltung „Fernzugriff einrichten" an: Die App installiert
  Tailscale auf dem Pi, startet die Anmeldung und öffnet den Login im Browser.
  Danach **prüft sie nach, ob dieses Handy den Pi über das Tailnet wirklich
  erreicht** — sie meldet Erfolg erst, wenn sie ihn gemessen hat. Fehlt auf dem
  Handy noch die Tailscale-App, sagt sie genau das (samt Store-Link); Android
  erlaubt keiner App, ein fremdes VPN für dich einzurichten. Ab dann wählt die
  App beim Verbinden selbst die richtige Adresse: erst die Heim-IP, sonst die
  Tailnet-IP — kein manuelles Umschalten mehr. Bewusst **kein Portforwarding**:
  offene SSH-Ports ins Internet sind genau das, was der Sicherheits-Check der
  App anprangert.
- **Heimnetz über Tailscale freigeben** — auf Wunsch macht die App den Pi zum
  *Subnet Router*: „Heimnetz freigeben" im ⋮ der Tailscale-Karte (oder als
  optionaler letzter Schritt des Fernzugriff-Helfers) schaltet die
  IPv4-Weiterleitung ein und bietet das Heimnetz des Pi (z. B. `192.168.178.0/24`)
  im Tailnet an. Unterwegs erreichst du dann auch Geräte ohne Tailscale —
  Wallbox, Wechselrichter, Router — unter ihrer gewohnten IP. Tailscale verteilt
  die Route erst nach einer Bestätigung in der Tailscale-Konsole; fehlt sie,
  erklärt ein Popup den Schritt und öffnet die Konsole, „Heimnetz-Freigabe
  prüfen" liest den Stand danach neu. Die Karte zeigt, ob die Freigabe aktiv oder
  noch offen ist; „Heimnetz-Freigabe beenden" nimmt sie zurück (von Hand gesetzte
  Routen bleiben). Bewusst Opt-in: Die Freigabe gilt für alle Geräte im Tailnet.
  Liegt das Heimnetz in einem Bereich, mit dem Router ausgeliefert werden
  (`192.168.178.0/24`, `192.168.0.0/24`, `192.168.1.0/24`, `192.168.2.0/24`),
  weisen Karte und Freigabe-Dialog darauf hin: Aus einem Netz mit demselben
  Bereich ist das Heimnetz über Tailscale unter Umständen nicht erreichbar.
- **evcc-Adresse über Tailscale** — ist Tailscale verbunden und evcc auf dem Pi
  installiert, zeigt die Tailscale-Karte die Adresse der evcc-Oberfläche über
  die Tailnet-Adresse des Pi (z. B. `http://100.x.y.z:7070`). Sie funktioniert
  aus jedem Netz und ohne Heimnetz-Freigabe, weil evcc auf dem Pi selbst läuft.
  „evcc-Adresse teilen" im ⋮ der Karte gibt sie weiter — für alle, die evcc im
  Browser oder in der evcc-App nutzen und Pi-Tool nicht haben.
- **Fernzugriff mit einem Tap (Tailscale)** — im ⋮-Menü liegt „Fernzugriff:
  Tailscale öffnen" (erreichbar, wenn du unterwegs und nicht verbunden bist): es
  setzt die zuletzt gemerkte Tailnet-IP (100.x) des Pi als Host und öffnet die
  Tailscale-App zum VPN-Einschalten. (Android erlaubt keiner App, ein fremdes VPN
  selbst zu aktivieren — daher öffnen statt schalten.) Zurück zuhause bringt dich
  „Zurück auf Heim-IP" mit einem Tap wieder auf die automatisch gemerkte
  LAN-Adresse.
- **Fernzugriff einrichten** — **Raspberry Pi Connect** (offiziell, ab Raspberry
  Pi OS Bookworm; per Link mit der Raspberry Pi ID anmelden) und **Tailscale**
  (VPN/Mesh, per Login-Link verbinden). Beides installieren/verbinden/trennen
  direkt in der App; die Tailnet-IP (100.x) lässt sich mit einem Tap ins
  Host-Feld übernehmen — so erreichst du den Pi von überall. „Trennen" und
  „Abmelden" lehnt die App ab, solange die Verbindung zum Pi selbst über
  Tailscale läuft (sie würde dabei abreißen). Beide Karten
  **melden verfügbare apt-Updates**: Steht eines an, wird „Aktualisieren" zum
  Hauptknopf der Karte (die sonstige Aktion rückt ins ⋮-Menü) — dieselbe Regel
  wie bei evcc, Pi-hole, Grafana, InfluxDB und Mosquitto: *Der Knopf zeigt, was
  als Nächstes dran ist.*
- **Geplante Backups** — nächtliche evcc- + Pi-hole-Sicherung mit Rotation als
  On-Pi-systemd-Timer (Pro). Die Archive stehen in den Backup-Listen der evcc-
  und der Pi-hole-Karte, gekennzeichnet als „Geplantes Backup", und lassen sich
  dort wiederherstellen, herunterladen und löschen. Das evcc-Archiv des Timers
  enthält `/etc/evcc.yaml` und `/var/lib/evcc`; eine Datenbank an einem anderen
  Ort ist nicht darin.
- **Automatik** (läuft autonom auf dem Pi, **kein** Handy-Hintergrunddienst) —
  **geplante Updates** per systemd-Timer (mit evcc-Sicherung + Selbstheilung) und
  **Health-Alerts** als Push via [ntfy](https://ntfy.sh) bei voller Platte,
  totem Dienst, Hitze oder anstehenden Updates.
  - *Geplante Updates:* Der Lauf schließt vorher eine unterbrochene
    Paketinstallation ab, wartet auf andere apt-Läufe und lädt die
    Paketlisten. Die Zeile zum letzten Lauf nennt das Ergebnis in Kürzeln:
    `ok` oder `fehler(rc=N)`, dazu `paketlisten-fehler(rc=N)` (die Paketlisten
    wurden nicht vollständig geladen), `evcc-neustart` (evcc lief nach dem
    Update nicht mehr und wurde neu gestartet) und `backup-fehler(rc=N)` (die
    evcc-Sicherung vor dem Update wurde nicht geschrieben). Die Ursache eines
    Fehlers steht in `/var/lib/pi-tool/autoupdate.log` auf dem Pi (über den
    Dateien-Tab lesbar). Die evcc-Sicherung vor dem Update erscheint in der
    Backup-Liste der evcc-Karte als „Vor automatischem Update". Ein Neustart
    oder Herunterfahren während eines Laufs wartet auf dessen Ende, höchstens
    30 Minuten — so lange ist der Pi nicht erreichbar; aus der App heraus
    werden beide in dieser Zeit abgelehnt. Das Einrichten oder Ändern des
    Zeitplans startet kein Update; ein Lauf, der in die fünf Minuten danach
    fällt, entfällt.
  - *Health-Alerts:* Das ntfy-Thema ist faktisch das Passwort (ntfy kennt
    kein Konto), deshalb schlägt die App ein langes Zufallsthema vor und warnt
    vor leicht erratbaren Namen. Das Thema wird **je Pi** gespeichert und
    reist im Profil-Export mit; sind auf einem Pi Alerts aktiv, ohne dass die
    App das Thema kennt, bleibt das Feld leer, und der Dialog sagt das. Ein
    Problem wird einmal gemeldet, bis sich die Menge der Probleme ändert —
    nicht bei jeder Änderung eines Messwerts. Ein Dienst, der gerade startet,
    gilt nicht als ausgefallen. Für die Meldung „Updates verfügbar" lädt der
    Timer die Paketlisten einmal täglich selbst. Das Ergebnis der
    Test-Benachrichtigung erscheint im Dialog.
  - Die Timer-Skripte liegen auf dem Pi: Änderungen aus einer neueren
    App-Version gelten erst, wenn der jeweilige Timer neu eingerichtet wird —
    läuft noch ein älteres Skript, weist der Dialog des Timers darauf hin.
- **Dateien** — der Datei-Browser deines Pi im eigenen Tab: Ordner durchsuchen,
  Dateien ansehen (Vorschau), **Textdateien direkt bearbeiten** (atomar mit
  Backup; Binärdateien bleiben schreibgeschützt), **vom Handy hochladen** und
  löschen — alles über die normale SSH-Sitzung, ohne SFTP-Server. Ein Upload
  fragt nach, bevor er eine Datei gleichen Namens ersetzt, und übernimmt dann
  deren Besitzer und Rechte; einen Ordner gleichen Namens ersetzt er nicht.
  Verlinkte Ordner (etwa `/bin`) lassen sich öffnen. Fehler nennen die Ursache
  (abgelehntes sudo-Passwort, nicht lesbare Datei, Pi nicht erreichbar) statt
  einer leeren Liste oder „Leere Datei".
- **Config-Editor** — Konfigdateien (z. B. `evcc.yaml`) direkt in der App
  bearbeiten; gespeichert wird **atomar mit automatischem Backup** (die fünf
  neuesten je Datei bleiben). Bearbeitet werden nur UTF-8-Dateien; wer den
  Editor mit ungespeicherten Änderungen verlässt, wird vorher gefragt. Ist die
  Datei ein Symlink, bleibt der Link erhalten — geschrieben wird die Datei
  dahinter.
- **Terminal** — eigene Befehle direkt per SSH auf dem Pi absetzen (`sudo` wird
  unterstützt; das Pi-Passwort geht nur dann über stdin an sudo, wenn sudo
  danach fragt), Ausgabe live, mit
  **Verlauf + Schnellbefehlen** (vorgefertigt **und eigene** anlegbar).
  Interaktive Programme (htop, Editoren, `-f`)
  bekommen einen Hinweis mit Alternative statt eines kryptischen Fehlers. Auf
  eigene Gefahr — freie Befehle laufen mit deinen Rechten auf dem Pi.
- **System** — alle Pakete aktualisieren (`apt full-upgrade`), Pi neustarten,
  Pi herunterfahren (mit Sicherheitsabfrage — der Pi bleibt danach aus).
  Neustart und Herunterfahren setzen eine bestehende Verbindung voraus; auf
  einer Karte mit dem „Stand von vorhin" sind beide Einträge ausgegraut.
- **Sicherheits-Check mit „Beheben"** — Nur-Lesen-Prüfung mit Ampel: SSH-Root-
  Login, Passwort- vs. Key-Login, automatische Sicherheitsupdates, fail2ban,
  offene Ports, dazu — wenn vorhanden — ob die Pi-hole-Weboberfläche ein
  Passwort hat. Fixbare Befunde tragen einen „Beheben"-Knopf (fail2ban
  installieren, Auto-Updates aktivieren, Root-Login abschalten — als Drop-in,
  mit `sshd -t` geprüft und bei Problemen automatisch zurückgenommen — sowie ein
  zufälliges Pi-hole-Passwort setzen, das einmalig angezeigt wird); danach
  läuft die Prüfung neu. Das Abschalten des Passwort-Logins bleibt bewusst
  Handarbeit (Aussperr-Risiko ohne bewiesenen Key-Login). Auf einem 32-Bit
  Raspberry Pi OS erkennt die Prüfung, wenn `unattended-upgrades` zwar läuft,
  die Paketquelle „Raspbian" aber nicht einschließt und deshalb nichts
  installiert; „Beheben" ergänzt sie (Kernel-, Firmware- und
  Bootloader-Pakete bleiben ein manuelles Update). Der fail2ban-Fix meldet
  Erfolg erst, wenn fail2ban danach auch weiterläuft, und stellt es auf
  Systemen ohne `/var/log/auth.log` (Bookworm ohne rsyslog) auf das
  systemd-Journal um.
- **Speicherplatz-Explorer** — „Was frisst meinen Platz?": größte Ordner/Dateien
  nach Größe, zum Reinzoomen antippbar. Lässt sich ein Ordner nicht lesen,
  bleibt die Liste stehen, und der Abruf lässt sich wiederholen.
- **Docker-Übersicht** — alle Container (laufend/gestoppt) mit Status + Image;
  pro Container neustarten, Logs ansehen und **aktualisieren** (Image-Pull +
  Neuanlage mit Rollback; Compose-Container via `docker compose`, experimentell).
  Zeigt das Tag kein neueres Image, wird nichts neu angelegt, und die App sagt
  das. Container, die sich nicht verlustfrei nachbauen lassen, lehnt sie mit
  Begründung ab, bevor etwas gezogen wird (Details unter
  [Docker-Installation](#was-die-app-macht)).
- **Live-Logs** — die Log-Ansicht hat einen „Live"-Schalter, der die Ausgabe
  alle paar Sekunden neu lädt (Polling, kein Hintergrunddienst). Sie öffnet am
  neuesten Eintrag; schlägt ein Abruf fehl, bleibt der letzte Stand stehen und
  ist als solcher gekennzeichnet. Bei eingeschalteter App-Sperre pausiert das
  Nachladen, solange die App gesperrt ist.
- **Pi-Gesundheit** — die System-Karte zeigt Temperatur, freien Speicher, RAM
  und Uptime; bei knappem Speicher (<1 GB frei — oder ≥90 % belegt **und**
  zugleich <5 GB frei) warnt sie, bevor ein Update daran scheitert.
- **SD-Karten-Check** — warnt bei den klassischen Anzeichen einer sterbenden
  SD-Karte: nur-lesend gewordenes Root-Dateisystem oder gehäufte I/O-Fehler im
  Kernel-Log. Fließt auch in die Health-Alerts ein (Push via ntfy).
- **Monitoring-Stack verdrahten** — die Grafana-Karte kann den Stack in einem
  Rutsch scharf schalten: InfluxDB einrichten (Org `pi-tool`, Bucket `evcc`),
  Zugriffs-Token auf dem Pi erzeugen (verlässt ihn nie), `influx:`-Block in die
  `evcc.yaml` (mit Backup und automatischem Rückbau bei Ablehnung) und in
  Grafana Datenquelle + fertiges evcc-Dashboard provisionieren. Charts ab
  Minute eins statt leerer Dienste (experimentell). Ein zweiter Lauf lässt
  eine bereits verdrahtete `evcc.yaml` unverändert. Hat evcc keine `evcc.yaml`
  (Einrichtung über die evcc-Weboberfläche), legt die App keine an und nennt,
  was dort einzutragen ist.
- **Umzugshelfer** — „Auf anderen Pi umziehen" (System-Karte): frische Backups
  von evcc + Pi-hole, aufs Handy geholt, auf dem Ziel-Profil fehlende Dienste
  installiert und die Backups eingespielt. Der Quell-Pi bleibt unverändert
  (experimentell; apt-evcc und Pi-hole). Pi-hole v5 zieht nicht mit um — sein
  Backup lässt sich nur über die Pi-hole-Weboberfläche importieren; am Ziel
  wird dann kein Pi-hole installiert, evcc zieht trotzdem um. Wurde Pi-hole am
  Ziel neu installiert, das Backup aber nicht eingespielt, zeigt die App
  einmalig das Web-Passwort des Ziels. Der Monitoring-Stack zieht nicht mit
  um: Bringt die `evcc.yaml` den InfluxDB-Block der alten Verdrahtung mit,
  muss er am Ziel vor „Mit evcc verdrahten" gelöscht werden — die Verdrahtung
  sagt das im Log.
- **Release-Notes** — die evcc-Karte zeigt die vollständigen GitHub-Release-
  Notes der neuesten Version im ⋮ — lesbar, ohne ein Update zu starten.
- **Probelauf** (`--dry-run`) — zeigt gefahrlos, ob ein Update verfügbar ist.
- **Backup vor Update** — sichert vor einem apt-Update automatisch `evcc.yaml` +
  die Datenbank als zeitgestempeltes Archiv auf dem Pi (abschaltbar); schlägt es
  fehl, wird der Fehler angezeigt und das Update gestoppt. Automatische
  Rotation: die zehn neuesten evcc-Backups unter `/var/backups/evcc/` bleiben,
  ältere werden beim nächsten Backup gelöscht.
- **evcc-Backups verwalten** — „Backups verwalten" im ⋮ der evcc-Karte listet
  die evcc-Backups auf dem Pi. Antippen stellt eines wieder her: Archiv
  prüfen, evcc stoppen, entpacken, neu starten (mit Sicherheitsabfrage; ein
  beschädigtes Archiv wird abgelehnt, bevor etwas geändert ist). Die Symbole
  daneben laden ein Backup aufs Handy oder löschen es vom Pi. In der Liste
  stehen auch die Archive der Timer auf dem Pi, gekennzeichnet als „Geplantes
  Backup" bzw. „Vor automatischem Update". Ein evcc-Backup auf Knopfdruck gibt
  es nicht: Archive entstehen vor einem Update (Schalter „Backup vor Update"),
  durch die beiden Timer oder im Umzugshelfer.
- **Pi-hole- & Home-Assistant-Backup** — Pi-hole per Teleporter-Export (offizielles,
  importierbares Format), Home Assistant als Tar des `/config`-Verzeichnisses;
  landet unter `/var/backups/pi-tool/` auf dem Pi. **Wiederherstellen und
  Verwalten direkt in der App** (Pi-hole-Import via `pihole-FTL --teleporter`,
  nur v6; HA: Container stoppen → entpacken → starten). Automatische Rotation:
  die letzten 5 Backups je Dienst bleiben. Das Home-Assistant-Archiv enthält
  `/config` ohne `backups/` und `tmp_backups/` (Home Assistants eigene
  Backups). Der Container läuft während der Sicherung weiter; die
  Verlaufsdatenbank `home-assistant_v2.db` wird dabei im laufenden Betrieb
  kopiert und kann im Archiv inkonsistent sein. Bei einem großen `/config`
  melden Backup und Restore ihren Fortschritt im Log.
- **Backups aufs Handy** — jedes Backup (evcc, Pi-hole, Home Assistant) lässt
  sich aus der Verwaltung herunterladen und per Teilen-Dialog sichern
  (Dateien, Drive, …) — so überleben Backups auch einen SD-Karten-Ausfall.
  Grenze: 48 MB je Archiv.
- **Aufräumen** — die System-Karte gibt Speicher frei (apt autoremove/clean,
  ungenutzte Docker-Images, Journal >7 Tage) und zeigt, wie viel frei wurde.
- **Updates laufen auf dem Pi weiter** — System-Update, evcc-Update,
  Paket-Updates, Pi-hole-Update und „Paketzustand reparieren" laufen als
  **Pi-Job** (eigene systemd-Unit auf dem Pi). Reißt die Verbindung ab, wird
  die App geschlossen oder stürzt ab, läuft das Update trotzdem zu Ende — ein
  mittendrin abgebrochenes Update kann einen Raspberry Pi unbootbar machen. Die
  App meldet das gelb („läuft auf dem Pi weiter"), eine **Job-Leiste mit
  „Mitlesen"** zeigt später das vollständige Log und das echte Ergebnis, die
  System-Karte den letzten Job. Erfolg meldet die App nur mit Beleg vom Pi;
  eine abgerissene Verbindung gilt bei keiner Aktion als Erfolg. Neustart und
  Herunterfahren werden abgelehnt, solange ein Job läuft, die automatischen
  Updates auf dem Pi laufen oder ein Kernel-Update nur halb installiert ist.
  Lässt sich ein Job gar nicht erst starten, meldet die App das mit dem
  Exit-Code — es wurde dann nichts gestartet.
- **Paketzustand reparieren** — wurde ein apt-/dpkg-Lauf einmal abgewürgt
  (Stromausfall, abgebrochenes Update), verweigert apt danach **jede**
  Installation. Die App erkennt das, sagt es im Klartext statt „Exit 100" und
  räumt es über die System-Karte auf (`dpkg --configure -a`,
  `apt-get -f install`) — als Pi-Job.
- **Ältere Raspbian-/Debian-Versionen** — die Paketquellen von Buster, Stretch
  und Jessie wurden von den regulären Servern ins offizielle Archiv verschoben
  (`legacy.raspbian.org`, `archive.debian.org`); die alten Adressen liefern 404
  und lassen jede Installation scheitern. Vor jeder Installation und jedem
  Update stellt die App solche Quellen automatisch um (mit Sicherung und
  Log-Eintrag). Scheitert apt trotzdem, nennt die Fehlermeldung die betroffene
  Quelle bzw. eine gerade laufende andere Paketinstallation.
- **„Aktuell"-Anzeige** — bei evcc/Pi-hole/System zeigt die Karte „Aktuell", wenn
  keine neue Version ansteht (statt „Aktualisieren"); erzwingen geht über das ⋮-Menü.
  **Aber nur, wenn der Paket-Index des Pi frisch ist:** die apt-gestützten Karten
  rechnen gegen den lokalen Index, und der wird auf einem Standard-Raspberry-Pi-OS
  oft wochenlang nicht erneuert. Ist er älter als drei Tage, sagt die App „Stand
  unbekannt" statt „Aktuell" — lieber keine Auskunft als eine falsche. Die
  System-Karte bietet dann im ⋮-Menü **„Paketlisten aktualisieren"**; läuft
  auf dem Pi gerade eine andere Paketinstallation oder reißt die Verbindung
  dabei ab, meldet die App das als Fehler. Auch ein System-, evcc- oder
  Paket-Update lädt die Paketlisten neu; gelingt das, gilt ihr Stand danach
  wieder als frisch. Schlägt die Update-Prüfung selbst
  fehl, steht auf der System-Karte „Update-Prüfung fehlgeschlagen — Stand
  unbekannt". Eine evcc-Installation aus dem nightly-Kanal gilt nicht schon
  deshalb als „Aktuell", weil sie neuer ist als das Stable-Release.
- **Abbrechen** — eine laufende Aktion lässt sich abbrechen (schließt die
  SSH-Verbindung). Ein Schritt, der auf dem Pi bereits als root lief, kann
  dort noch zu Ende laufen — die App sagt das dann. Läuft bereits ein Pi-Job,
  heißt der Knopf **„Nicht mehr mitlesen"**: die App hört auf mitzulesen, der
  Job läuft auf dem Pi weiter. Bleibt eine Aktion zehn Minuten ohne Ausgabe,
  meldet die App „keine Ausgabe … Ergebnis unbekannt" statt „Pi nicht
  erreichbar" und behält die Sitzung.
- **Verbindung herstellen** — Host/Zugang in Sekunden prüfen, ohne etwas zu ändern.
- **evcc installieren** auf einem frischen Pi (offizielles apt-Repo).
- **evcc-Status (Live)** — die evcc-Karte zeigt die aktuellen Werte direkt auf
  dem Verwaltungs-Tab (PV, Netz, Hausverbrauch sowie Batterie-Ladestand und
  Ladepunkt), gelesen aus der evcc-Web-API. Das vollständige Bild inklusive
  aller Ladepunkte liegt im App-⋮ unter „evcc-Status (Live)". Rein lesend.
- **Pi im WLAN suchen** — findet im selben WLAN Geräte mit offenem
  SSH-Port und übernimmt die IP per Tippen. Durchsucht werden nur lokale
  Netze, nicht ein VPN (Tailscale) oder das Mobilfunknetz. Wird beim ersten
  Start und nach „Profil hinzufügen" (solange noch kein Host eingetragen ist)
  prominent als Knopf angeboten; sonst jederzeit über das ⋮-Menü.
- **Updates im Hintergrund** — lange Aktionen (Update/Installation) laufen über
  einen Vordergrunddienst weiter, auch wenn du die App in den Hintergrund legst
  oder den Bildschirm ausschaltest (Benachrichtigung „Pi-Tool …"). Das gilt
  auch für „Alle aktualisieren" im Überblick über mehrere Pis.
- **Mehrere Pi-Profile** — pro Pi ein benanntes Profil, schnell umschaltbar.
- **Alle Pis auf einen Blick** — „Alle Pis (Überblick)" im ⋮-Menü (ab zwei
  Profilen) prüft jeden Pi der Reihe nach und zeigt eine Ampel: grün (alles gut),
  amber (Updates/Warnung), rot (nicht erreichbar). Fail-soft — ein toter Pi
  blockiert die anderen nicht. **Alle auf einmal aktualisieren** per Update-Knopf
  (nacheinander, fail-soft, Fortschritt pro Zeile).
- **Profil-Export/-Import** — alle Profile (inkl. Zugangsdaten) als
  **passphrase-verschlüsselte** Datei (AES-256-GCM) sichern und auf einem neuen
  Handy importieren. Für den Gerätewechsel. Die Passphrase braucht mindestens
  10 Zeichen; die Schlüsselableitung ist bewusst rechenaufwendig (600 000
  PBKDF2-Runden). Exporte älterer Versionen lassen sich weiter importieren.
- **SSH-Key mit einem Tap** — im Verbindungsformular auf „SSH-Key" tippen (wenn
  noch keiner hinterlegt ist) und „SSH-Key automatisch einrichten" wählen: erzeugt
  ein Ed25519-Schlüsselpaar **auf dem Handy**, hinterlegt den Public Key (einmalig
  per Passwort-Login) in `~/.ssh/authorized_keys` und stellt das Profil auf
  Key-Login um. Der private Schlüssel verlässt das Handy nie (nur verschlüsselt
  im Android Keystore). Pro Pi, direkt am Profil — nicht im globalen Menü.
- **SSH-Key- oder Passwort-Login**, **App-Sperre** (Biometrie/PIN),
  **stable/nightly**-Kanal, **Update-Verlauf** (bei mehreren Profilen mit dem
  Namen des Pi), **In-App-Update-Hinweis**.
- **Dienst-/System-Aktionen:** evcc-Dienst neustarten, Pi neustarten,
  Terminal-Log teilen.

## Was die App macht

Beim Tippen auf **„evcc aktualisieren"** erkennt die App zuerst die
Installationsart und nimmt dann den passenden Weg:

**apt-Installation** (Standard auf dem Pi):

1. Version vorher: `dpkg-query -W -f='${Version}' evcc`
2. Ab hier als **Pi-Job** auf dem Pi (läuft weiter, auch wenn die Verbindung
   abreißt): veraltete Paketquellen umstellen, eine unterbrochene
   Paketinstallation abschließen (`dpkg --configure -a`, `apt-get -f install`),
   `apt-get update`, dann `apt-get install --only-upgrade -y evcc` (bei
   aktiviertem Schalter **„Komplettes System-Upgrade"** stattdessen
   `apt-get full-upgrade -y`) — nicht-interaktiv, Rückfragen zu
   Konfigurationsdateien behalten die eigene Version.
3. `systemctl is-active evcc` → erwartet `active`
4. Version nachher → Diff wird gemeldet („evcc 0.310.0 → 0.311.0 aktualisiert"
   bzw. „war schon aktuell").

Der Dienst startet beim apt-Upgrade automatisch neu. Mit **„Probelauf (ändert
nichts)"** läuft die Sequenz mit `--dry-run` im Vordergrund — nichts wird
verändert.

**Docker-Installation** — läuft evcc in einem Container, aktualisiert die App
ihn passend zum Setup:
- **docker compose**: `docker compose pull` → `up -d` im Projektverzeichnis,
  mit gepinntem Projekt (`-p`) und Compose-Datei(en) (`-f`), damit kein
  Doppel-Container entsteht; fällt automatisch auf das v1-Binary
  `docker-compose` zurück, wenn das v2-Plugin fehlt.
- **`docker run`** (ohne compose): zieht das neue Image und legt den Container
  **aus `docker inspect` rekonstruiert** neu an (Ports, Volumes, Env,
  Restart-Policy, Netzwerk sowie `--device`/`--privileged`/`--group-add` für
  USB-/RS485-Zähler; außerdem `--cap-drop`, `--security-opt`, `--tmpfs`,
  `--shm-size`, `--sysctl`, die Speicher-, CPU- und pids-Limits und der
  pid-Modus). Der alte Container wird dabei nur **umbenannt**
  (`<name>-evccpitool-old`, geparkt ohne Autostart), nie gelöscht — schlägt die
  Neuanlage fehl oder hängt der neue Container in einer Neustart-Schleife, wird
  der alte mit seiner ursprünglichen Restart-Policy automatisch zurückgerollt.
  Zeigt das Tag nach dem Pull kein neueres Image, bleibt der Container
  unangetastet, und die App meldet das — bei einem versionsfesten Tag (z. B.
  `:2026.6.3`) mit dem Hinweis, dass eine neuere Version ein anderes Tag
  braucht. **Abgelehnt** wird das Update mit Begründung, bevor etwas gezogen
  wird, für Container mit `--rm`, `--mount`-Einträgen, mehreren Netzwerken,
  fester IP-Adresse, selbst gesetztem Netzwerk-Alias, eigenem seccomp-Profil
  oder einem per Digest gepinnten Image. **Experimentell**, nicht gegen jede
  Konfiguration getestet.

Dasselbe gilt für das Update des Home-Assistant-Containers und für
„Aktualisieren" in der Docker-Übersicht.

Docker-Befehle laufen bei Bedarf automatisch über `sudo`.

Mit **„Verbindung herstellen"** prüfst du in Sekunden, ob Host/Port/Benutzer/Zugang
stimmen: die App verbindet, erkennt die Installationsart (apt/Docker) und
meldet Version bzw. Container — **ohne irgendetwas zu verändern**.

### evcc-Status (Live)

Die App liest die Werte **direkt aus der evcc-Web-API**
(`GET http://<pi>:7070/api/state`) — rein lesend über HTTP, **kein SSH, keine
Zugangsdaten**. Sie ist robust gegen verschiedene evcc-Versionen (mit/ohne
`result`-Hülle, fehlende Felder).

Zwei Orte, dieselbe Quelle:

- **Auf der evcc-Karte** (Verwaltungs-Tab) stehen nach dem Verbinden zwei
  kompakte Zeilen: PV, Netz und Hausverbrauch sowie — sofern vorhanden —
  Batterie-Ladestand und der Ladepunkt, der gerade lädt. Antwortet die API
  nicht (anderer Port, Anmeldung aktiv, evcc offline), bleibt die Karte
  unverändert; ein Fehler wird dafür **nicht** gemeldet.
- **App-⋮ → „evcc-Status (Live)"** zeigt das vollständige Bild inklusive aller
  Ladepunkte, Fahrzeug-Ladestände und Modi.

### Pi im WLAN suchen

⋮-Menü → **„Pi im WLAN suchen"** scannt das lokale `/24`-Netz nach Geräten
mit offenem **SSH-Port (22)** und listet sie auf — Tippen übernimmt die IP ins
Host-Feld. Funktioniert nur im **selben WLAN**; findet die App nichts, einfach
die IP von Hand eintragen. Gescannt werden nur lokale Netze (WLAN, Ethernet,
der eigene Hotspot) — nicht die Adressen eines VPN wie Tailscale und nicht das
Mobilfunknetz.

### evcc installieren

Über **„+ Dienst hinzufügen" → „evcc"** (Verwaltungs-Tab, nach dem Verbinden)
richtet die App evcc auf einem frisch konfigurierten Pi ein (nach
[offizieller evcc-Doku](https://docs.evcc.io/en/installation/linux)): offizielles
apt-Repo via `setup.deb.sh` hinzufügen → `apt install -y evcc` →
`systemctl enable --now evcc`. Alles läuft als root über **einen** `sudo -S bash
-s`-Aufruf (Passwort als erste stdin-Zeile, **nie** in der Befehlszeile). Danach
zeigt die App **„evcc-Einrichtung öffnen"** → `http://<pi>:7070`. Über die
Einstellungen lässt sich vorab der **nightly-Kanal** (unstable) wählen.

## Installation

**Google Play (empfohlen)** — automatische Updates, kein Sideload-Hinweis:

[play.google.com/store/apps/details?id=systems.kyth.pitool](https://play.google.com/store/apps/details?id=systems.kyth.pitool)

**Sideload (Alternative)** — ohne Google-Konto, direkt vom GitHub-Release:

1. Auf der [Releases-Seite](../../releases) die neueste **`app-release.apk`**
   herunterladen (Handy-Browser genügt, kein GitHub-Account nötig).
2. Beim Öffnen fragt Android nach **„Unbekannte Quellen / Apps aus dieser
   Quelle zulassen"** → erlauben.
3. APK installieren, App öffnen.

> Beide Kanäle laufen unabhängig nebeneinander (unterschiedliche Signatur, siehe
> [Verteilung](#verteilung-google-play-und-sideload)) — ein Wechsel zwischen
> ihnen erfordert Deinstallieren + neu installieren.

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
Biometrie/PIN, Sprache, Backup vor Update, HTTPS + Port der evcc-Oberfläche
(der HTTPS-Schalter gilt nur für evcc; Pi-hole wird immer über http geöffnet),
Design (System/Hell/Dunkel), nightly-Kanal, Profil-Export/-Import, **Support
kontaktieren** (support@kyth.systems). „Beim Start automatisch verbinden" ist
keine globale Einstellung, sondern ein Schalter je Pi in der
Zugangsdaten-Karte.

Alle Eingaben werden **verschlüsselt im Android Keystore** gespeichert
(`flutter_secure_storage`) und automatisch gesichert — einmal eintragen, danach
nur noch tippen. Lässt sich der Speicher beim Start nicht lesen, überschreibt
die App nichts: Sie bietet „Erneut versuchen" und, als letzten Ausweg,
„Gespeicherte Daten zurücksetzen" (löscht Profile, Verlauf und gemerkte
Host-Keys auf dem Handy; auf den Pis ändert sich nichts). Die App-Daten sind
von Cloud-Backup und Gerät-zu-Gerät-Übertragung ausgenommen — der Weg auf ein
neues Handy ist der Profil-Export.

## Sicherheit

- Passwort und SSH-Key liegen **nur verschlüsselt** im Keystore, nie im Klartext.
- Das `sudo`-Passwort wird der Abfrage **über stdin** übergeben (`sudo -S`),
  **nie** als Teil der Befehlszeile — und aus dem sichtbaren Log
  **herausgefiltert**; steht es innerhalb eines längeren Wortes, wird das
  ganze Wort maskiert.
- **Backups liegen auf dem Pi für alle lokalen Benutzer lesbar** (0644), damit
  der Download aufs Handy ohne `sudo` auskommt. Das gilt auch für das
  Home-Assistant-Archiv, das `/config` und damit `.storage/auth` und
  `secrets.yaml` enthält. Eine bewusste Grenze; wer das nicht will, löscht
  das Archiv nach dem Herunterladen über „Backups verwalten".
- Der **Live-Status** nutzt nur lesendes HTTP gegen die evcc-Oberfläche — dabei
  werden **keine** Zugangsdaten gesendet.
- Kein Account, kein Cloud-Backend. Annahme: LAN-Nutzung (zuhause im WLAN).
  Remote optional über **Tailscale-IP** (kein Portforwarding nötig).
- **Bewertungs-Anfrage (nur bei Installation über Google Play):** Nach einer
  gelungenen Aktion kann die App Google Play bitten, dessen Bewertungsdialog
  anzuzeigen — frühestens nach drei gelungenen Aktionen und drei Tagen,
  höchstens alle 120 Tage und insgesamt dreimal, nie im Demo-Modus; ob der
  Dialog erscheint, entscheidet Google Play, und die App erfährt weder das noch
  eine abgegebene Bewertung. Die Sideload-APK fragt nie.
- Optionale **App-Sperre** per Biometrie/PIN. Die Sperre liegt über der ganzen
  App: Offene Dialoge, Sheets und Seiten bleiben darunter erhalten — auch
  ungespeicherter Text im Config-Editor — und sind nach dem Entsperren wieder
  da; nichts, was im Hintergrund aufgeht, erscheint über dem Sperrbildschirm.
  Ein Dateiwähler, der länger als fünf Minuten offen bleibt, hält die App
  nicht entsperrt: Bei der Rückkehr wird gesperrt.
  **Vorschau in der App-Übersicht (Recents):** Ist die Sperre eingeschaltet,
  zeigt die Übersicht **ab Android 13** kein Bild der App. **Unter Android 12
  und älter** kann sie den zuletzt gezeigten Bildschirm weiter zeigen, obwohl
  die App gesperrt ist — Android nimmt das Bild auf, bevor die Sperre greift.
  **Screenshots und Bildschirmaufnahmen** sind unabhängig davon nur dort
  gesperrt, wo Zugangsdaten zu sehen sein können (`FLAG_SECURE`): auf dem
  Sperrbildschirm und bei aufgeklappter Zugangsdaten-Karte. Dienst-Karten,
  Logs, Terminal, Datei-Vorschau und Config-Editor sind seit v0.65.0 **nicht**
  mehr geschützt — was dort steht, kann in einem Screenshot erscheinen und in
  der Recents-Vorschau (dort nicht, wenn die App-Sperre eingeschaltet ist und
  Android 13 oder neuer läuft).
- **Host-Key-Verifizierung (TOFU):** Beim ersten Connect zeigt die App den
  SSH-Fingerprint zur **Bestätigung** an und merkt ihn erst nach Zustimmung;
  danach wird er geprüft. Ändert er sich (möglicher MITM oder neu aufgesetzter
  Pi), **blockiert** die App und sendet kein Passwort — erst nach bewusstem
  „neuen Key vertrauen". Lässt sich ein gemerkter Fingerprint nicht lesen,
  behandelt die App das nicht als ersten Kontakt: Sie meldet es, sendet kein
  Passwort und lässt den Key neu bestätigen.

## Build & Releases (CI)

Build, Signierung und Veröffentlichung laufen komplett in **GitHub Actions** —
lokal ist **keine Android-Toolchain** nötig. Die Mechanik im Detail steht in
[`ARCHITECTURE.md`](ARCHITECTURE.md) §8.

- Workflow: [`.github/workflows/build.yml`](.github/workflows/build.yml)
- Trigger: Push auf `main` (analysiert, testet, baut), Pull Request gegen
  `main` (analysiert, testet, Debug-APK als Compile-Check) und Tag `v*`
  (**veröffentlicht**, siehe unten).
- Schritte: `flutter pub get` → `flutter analyze` → `flutter test` →
  `flutter build apk --release --target-platform android-arm64,android-arm`
  (**fat APK**: arm64 + armeabi-v7a) und `flutter build appbundle --release`
  (**`.aab`** für Google Play), beides signiert mit dem Release-Keystore aus
  den Repo-Secrets.

### Ein neues Release veröffentlichen

> ⚠️ **Jedes `v*`-Tag veröffentlicht automatisch** — als GitHub-Release mit
> `app-release.apk` **und bei Google Play in der Produktions-Spur mit 100 %
> Rollout**. Hochgeladen werden das `.aab` und die Store-Texte aus
> `fastlane/metadata/android/**` (Titel, Kurz- und Langbeschreibung, Changelog);
> es gibt keinen Entwurf und keine Zwischenkontrolle. Screenshots und Grafiken
> im Store bleiben unberührt.

1. Version in `pubspec.yaml` anheben (z. B. `0.8.0+16`) und den Changelog
   `fastlane/metadata/android/{de-DE,en-US}/changelogs/16.txt` anlegen
   (Dateiname = versionCode, der Teil hinter dem `+`). Committen, pushen, den
   main-Build abwarten.
2. Optional der Trockenlauf — er baut das Bundle und lässt es samt Texten von
   der Play-API prüfen, veröffentlicht aber nichts:

   ```bash
   gh workflow run build.yml -f play_dry_run=true
   ```

3. Taggen. Der Tag-Name muss der pubspec-Version entsprechen (`v` + Teil vor
   dem `+`):

   ```bash
   git tag v0.8.0
   git push origin v0.8.0
   ```

Vor dem Bauen prüft der Tag-Lauf, dass Tag und pubspec-Version übereinstimmen,
dass der Changelog des versionCode in **beiden** Sprachen existiert und dass
alle Store-Texte die Play-Limits einhalten (Titel 30, Kurzbeschreibung 80,
Langbeschreibung 4000, Changelog 500 Zeichen). Danach entsteht zuerst das
GitHub-Release mit der APK (Release-Text = der Changelog in beiden Sprachen,
darunter die automatisch erzeugte Commit-Liste), zuletzt der Play-Upload
(`fastlane android play_release`) — ein Ausfall bei Google kostet die
Sideload-Nutzer so nicht ihre APK.

### Benötigte Repo-Secrets

| Secret | Inhalt |
|--------|--------|
| `KEYSTORE_BASE64` | Release-Keystore (`.jks`), base64-kodiert |
| `KEYSTORE_PASSWORD` | Keystore-Passwort |
| `KEY_ALIAS` | Key-Alias (`evcc`) |
| `KEY_PASSWORD` | Key-Passwort |
| `PLAY_SERVICE_ACCOUNT_JSON` | JSON-Schlüssel des Google-Dienstkontos für den Play-Upload |

> Der Keystore wird **nie** ins Repo committet (`.gitignore`). Bewahre die
> `.jks`-Datei + Passwort sicher auf — sie wird für künftige signierte Updates
> gebraucht. Ohne Keystore-Secret bricht ein Tag-Lauf ab; fehlt nur
> `PLAY_SERVICE_ACCOUNT_JSON`, entsteht das GitHub-Release und der Play-Upload
> wird mit einer Warnung übersprungen. Die Einmal-Einrichtung der Google-Seite
> (Dienstkonto, Berechtigungen) steht in
> [`store/play-ci-publishing.md`](store/play-ci-publishing.md).

## Verteilung: Google Play **und** Sideload

Beide Wege funktionieren parallel, ohne sich zu stören:

- **Google Play (seit 26.07.2026 live):**
  [`systems.kyth.pitool`](https://play.google.com/store/apps/details?id=systems.kyth.pitool)
  — veröffentlicht von der **KYTH. Systems UG (haftungsbeschränkt)**. Updates
  kommen automatisch über Play. Das **`.aab`** (App Bundle) und die Store-Texte
  lädt der CI-Lauf jedes `v*`-Tags selbst hoch (Produktions-Spur, 100 %
  Rollout, siehe [Build & Releases](#build--releases-ci)); das Bundle liegt
  zusätzlich als Artifact **`pi-tool-playstore-aab`** am Lauf.
  - Datenschutzerklärung: <https://pi-tool.kyth.systems/privacy.html>
  - Store-Texte: `fastlane/metadata/android/**` (einzige Quelle, geht mit dem
    Tag live). Data-Safety, Foreground-Service-Erklärung und Console-Notizen:
    [`store/play/listing.md`](store/play/listing.md)
- **Sideload (Alternative):** Die signierte **`app-release.apk`** am `v*`-Release —
  laden + installieren direkt, ohne Google-Konto.

> Hinweis: Play nutzt **Play App Signing** (re-signiert das Bundle) — die
> Play-Version hat daher eine **andere Signatur** als die Sideload-APK. Beide
> Kanäle laufen unabhängig nebeneinander; ein Wechsel geht nur über
> Deinstallieren + neu installieren (Profile werden dabei einmal neu eingetragen).

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
- `lib/src/app_lock.dart` — App-Sperre als Schicht über dem Navigator
- `lib/main.dart` — UI

Tests: `flutter test` (reine Logik via TDD, Updater via `FakeSshRunner`,
Widget-Tests mit injizierten Fakes). Zwei Gruppen brauchen etwas von außen und
werden sonst übersprungen:

- **Skripte in echter bash** — die On-Pi-Skripte (Backup, Restore, Timer,
  Installer, Sicherheits-Fixes, Datei-Befehle) laufen gegen einen Sandbox-Pi
  mit Stubs; die gemeinsame Sandbox ist `test/on_pi_sandbox.dart`. Unter Linux
  genügt `bash`; unter Windows den Pfad zu Git Bash setzen
  (`PITOOL_TEST_BASH=C:\Program Files\Git\bin\bash.exe`). Wo ein `dash`
  installiert ist, laufen die `#!/bin/sh`-Skripte zusätzlich darunter.
- **SSH-Integrationstest** — `test/ssh_integration_test.dart` lässt den echten
  SSH-Adapter gegen einen lokalen SSH-Server laufen
  (`tool/ssh_test_server.py`, braucht Python 3 mit `asyncssh`). Aktiv nur mit
  `PITOOL_TEST_SSHD_PYTHON=<pfad zu python>` (unter Windows zusätzlich
  `PITOOL_TEST_BASH`, der Server führt die Befehle in einer bash aus); die CI
  führt ihn nicht aus. Vor jedem Upgrade von `dartssh2` laufen lassen:

  ```bash
  pip install asyncssh
  PITOOL_TEST_SSHD_PYTHON=$(command -v python3) flutter test test/ssh_integration_test.dart
  ```

## Roadmap

- iOS: bewusst später. Die Flutter-Codebasis hält die Tür offen.
- Docker-`run`-Rekonstruktion deckt die gängigen Fälle ab. Was sie nicht
  verlustfrei nachbauen kann (z. B. `--mount`-Einträge, mehrere Netzwerke,
  feste IP-Adressen), übernimmt sie nicht — solche Container lehnt das Update
  mit Begründung ab, statt sie verändert neu anzulegen.
