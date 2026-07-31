/// "Was ist neu?" popup logic + curated per-version highlights. Kept pure so
/// the decision + content are unit-testable; the dialog itself lives in the UI.
library;

/// Show the popup only on an actual UPDATE: the stored last-seen version differs
/// from the current one AND isn't empty. An empty last-seen means a fresh
/// install (or pre-feature first run), where we record silently and don't nag.
bool shouldShowWhatsNew({required String lastSeen, required String current}) =>
    current.isNotEmpty && lastSeen.isNotEmpty && lastSeen != current;

/// Curated highlights for [version] in [languageCode] ('de'/'en'), or null when
/// there's nothing to show (then no popup even if the version changed). English
/// content exists only from v0.58.0 on; older entries fall back to German.
List<String>? whatsNewFor(String version, [String languageCode = 'de']) =>
    languageCode == 'en'
        ? (_whatsNewEn[version] ?? _whatsNew[version])
        : _whatsNew[version];

/// English highlights (from v0.58.0 on). Older versions fall back to German.
const Map<String, List<String>> _whatsNewEn = {
  '0.63.6': [
    'The project has a new home: source code and releases now live at '
        'github.com/KYTH-SYSTEMS/pi-tool instead of a personal account — the app '
        'is published by KYTH. Systems UG, and now the repository sits there '
        'too. Nothing changes for you: the update check and the links in the '
        'menu point at the new location automatically, old addresses redirect.',
  ],
  '0.63.5': [
    '"Restart DNS" on the Pi-hole card really does it again. On Pi-hole v6 the '
        'command the app used no longer exists — and because v6 answers unknown '
        'commands with its help text and a success code, the app reported '
        '"DNS restarted" while the cache was left untouched. It now asks the '
        'installed Pi-hole which command it understands, and says so clearly '
        'when the restart genuinely fails.',
    'Same fix inside the Pi-hole backup restore: the DNS reload after an import '
        'was silently skipped on v6.',
  ],
  '0.63.0': [
    'Health alerts are safer by default: an ntfy topic is effectively a '
        'password — ntfy has no accounts, so anyone who knows or guesses the '
        'name can read your Pi\'s status messages. The app now suggests a long '
        'random topic, offers a dice button for a fresh one, and flags a '
        'guessable topic both in the dialog and on the Automation card.',
    'The privacy policy now describes the ntfy transmission (what leaves your '
        'Pi, to whom, and that topics are public), explains every Android '
        'permission the app requests, and names the Home Assistant version '
        'lookup on GitHub.',
  ],
  '0.62.0': [
    'Raspberry Pi Connect and Tailscale now flag an available update on their '
        'card and offer "Update" right there — just like Grafana, InfluxDB and '
        'Mosquitto. No more checking by hand whether remote access is current.',
    'Updates from Google Play are handled by Play itself: installs from the '
        'Play Store no longer show the in-app download banner for the GitHub '
        'APK (it could not be installed over a Play build anyway). Sideload '
        'installs keep the banner unchanged.',
    'The "Try the demo" entry is more discreet — it now appears only while no '
        'Pi is set up yet, instead of on every visit to the connection screen.',
  ],
  '0.61.0': [
    'New demo mode: tap "Try the demo" on the connection screen to explore the '
        'whole app with sample data — no Raspberry Pi needed. A quick way to see '
        'every feature, including the Pro ones.',
  ],
  '0.60.0': [
    'New Terms of Use: clear, statute-compliant liability instead of a blanket '
        '"no liability", notes on the Pro purchase (sold via Google Play) and an '
        'expanded independence/trademark notice. Reach them via "Terms" at the '
        'bottom of the Management tab.',
  ],
  '0.59.2': [
    'More reliability: failed installs (Pi-hole, Grafana/InfluxDB/Mosquitto), '
        'evcc backup restores, and Tailscale connect/disconnect no longer '
        'report a phantom "success" — a half-run or failed action now surfaces '
        'a clear error instead of looking done.',
  ],
  '0.59.1': [
    'Security hardening from a full review: more robust password redaction in '
        'the log, and extra safeguards for the scripts generated on the Pi '
        '(shell quoting for the ntfy destination). No change to how you use '
        'the app.',
  ],
  '0.59.0': [
    'Polish from a full app review: "Restart Pi" and "Shut down Pi" now follow '
        'the connection model (locked with a hint until you connect), and after '
        'a shutdown the app honestly shows "disconnected" — the Pi is off, '
        'after all. Error banners stay short and point to the terminal log; '
        'several texts were tightened (e.g. the setup guide now names the '
        '"Find Pi on Wi-Fi" button correctly).',
  ],
  '0.58.1': [
    'Small fix: the Settings sheet can now be closed via an × at the top '
        '(it had grown tall enough that only the phone back button worked).',
  ],
  '0.58.0': [
    'Pi-Tool now speaks English: the app follows your phone language '
        '(German/English) automatically. In Settings you can pin the language '
        'to System, German or English anytime.',
  ],
};

const Map<String, List<String>> _whatsNew = {
  '0.63.6': [
    'Das Projekt hat eine neue Heimat: Quellcode und Releases liegen jetzt unter '
        'github.com/KYTH-SYSTEMS/pi-tool statt beim privaten Konto — die App '
        'wird von der KYTH. Systems UG herausgegeben, jetzt ist die Ablage auch '
        'dort. Für dich ändert sich nichts: Der Update-Check und die Links im '
        'Menü zeigen automatisch auf den neuen Ort, alte Adressen leiten weiter.',
  ],
  '0.63.5': [
    '„DNS neu starten" auf der Pi-hole-Karte tut es wieder wirklich. Unter '
        'Pi-hole v6 gibt es den bisher verwendeten Befehl nicht mehr — und weil '
        'v6 auf unbekannte Befehle mit dem Hilfetext und einer Erfolgsmeldung '
        'antwortet, meldete die App „DNS neu gestartet", ohne den Cache '
        'anzufassen. Sie fragt jetzt das installierte Pi-hole, welchen Befehl es '
        'versteht, und sagt es deutlich, wenn der Neustart wirklich scheitert.',
    'Dieselbe Korrektur beim Wiederherstellen eines Pi-hole-Backups: Dort wurde '
        'der DNS-Reload nach dem Import unter v6 stillschweigend übersprungen.',
  ],
  '0.63.0': [
    'Health-Alerts sind ab Werk sicherer: Ein ntfy-Thema ist faktisch das '
        'Passwort — ntfy kennt kein Konto, wer den Namen kennt oder errät, liest '
        'die Statusmeldungen deines Pi mit. Die App schlägt jetzt ein langes '
        'Zufallsthema vor, hat einen Würfel-Knopf für ein neues, und markiert '
        'ein leicht erratbares Thema im Dialog und auf der Automatik-Karte.',
    'Die Datenschutzerklärung beschreibt jetzt die ntfy-Übermittlung (was den '
        'Pi verlässt, an wen, und dass Themen öffentlich lesbar sind), erklärt '
        'alle Android-Berechtigungen der App und nennt die '
        'Home-Assistant-Versionsabfrage bei GitHub.',
  ],
  '0.62.0': [
    'Raspberry Pi Connect und Tailscale melden jetzt auf ihrer Karte, wenn ein '
        'Update verfügbar ist, und bieten direkt „Aktualisieren" an — genau wie '
        'Grafana, InfluxDB und Mosquitto. Kein manuelles Nachsehen mehr, ob der '
        'Fernzugriff aktuell ist.',
    'Updates aus Google Play regelt Play selbst: Installationen aus dem Play '
        'Store zeigen den In-App-Hinweis auf die GitHub-APK nicht mehr an (die '
        'ließe sich über eine Play-Version ohnehin nicht installieren). Bei '
        'Sideload-Installationen bleibt der Hinweis unverändert.',
    'Der Einstieg „Demo ausprobieren" ist dezenter — er erscheint jetzt nur '
        'noch, solange noch kein Pi eingerichtet ist, statt bei jedem Besuch '
        'des Verbindungs-Bildschirms.',
  ],
  '0.61.0': [
    'Neuer Demo-Modus: Tippe auf dem Verbindungs-Bildschirm auf „Demo '
        'ausprobieren" und klick die ganze App mit Beispieldaten durch — ganz '
        'ohne Raspberry Pi. Ideal, um alle Funktionen (inkl. der Pro-Features) '
        'kennenzulernen.',
  ],
  '0.60.0': [
    'Neue Nutzungsbedingungen: klar geregelte, gesetzeskonforme Haftung statt '
        'pauschalem „keine Haftung", Hinweise zum Pro-Kauf (Verkauf über Google '
        'Play) und ein erweiterter Unabhängigkeits-/Markenhinweis. Erreichbar '
        'unten im Tab Verwaltung über „Nutzungsbedingungen".',
  ],
  '0.59.2': [
    'Mehr Verlässlichkeit: Fehlgeschlagene Installationen (Pi-hole, '
        'Grafana/InfluxDB/Mosquitto), evcc-Backup-Wiederherstellungen und '
        'Tailscale-Verbinden/-Trennen melden keinen Schein-Erfolg mehr — ein '
        'halb gelaufener oder gescheiterter Vorgang zeigt jetzt einen klaren '
        'Fehler, statt „fertig" auszusehen.',
  ],
  '0.59.1': [
    'Sicherheits-Härtung aus einem kompletten Review: robusteres Schwärzen '
        'des Passworts im Log und zusätzliche Absicherung der auf dem Pi '
        'erzeugten Skripte (Shell-Quoting fürs ntfy-Ziel). An der Bedienung '
        'ändert sich nichts.',
  ],
  '0.59.0': [
    'Feinschliff aus einem kompletten App-Review: „Pi neu starten" und „Pi '
        'herunterfahren" folgen jetzt dem Verbindungsmodell (bis zum Verbinden '
        'gesperrt, mit Hinweis), und nach dem Herunterfahren zeigt die App '
        'ehrlich „getrennt" — der Pi ist ja aus. Fehler-Banner bleiben kurz '
        'und verweisen aufs Terminal-Log; mehrere Texte wurden präzisiert '
        '(z. B. nennt die Einrichtungs-Anleitung jetzt den richtigen Knopf '
        '„Pi im WLAN suchen").',
  ],
  '0.58.1': [
    'Kleiner Fix: Die Einstellungen lassen sich jetzt über ein × oben im Menü '
        'schließen (das Menü war so hoch geworden, dass nur noch der '
        'Zurück-Button des Handys funktionierte).',
  ],
  '0.58.0': [
    'Pi-Tool spricht jetzt Englisch: Die App folgt automatisch der Sprache '
        'deines Handys (Deutsch/Englisch). In den Einstellungen kannst du die '
        'Sprache jederzeit fest auf System, Deutsch oder English stellen.',
  ],
  '0.57.0': [
    'Klarere Verbindung: Du verbindest dich jetzt bewusst über „Verbindung '
        'herstellen" und bleibst mit diesem Pi verbunden, bis du das Profil '
        'wechselst. Erst danach sind Automatik, Terminal und Dateien '
        'freigeschaltet — vorher sind sie dezent gesperrt. Der Tab „Dienste" '
        'heißt jetzt „Verwaltung". Nebenbei verschwindet die alte „Verbinde '
        'mit …"-Zeile, die beim App-Öffnen fälschlich nach einer laufenden '
        'Verbindung aussah.',
  ],
  '0.56.0': [
    'Mehr Platz für das Wesentliche: Die Zugangsdaten-Karte (Host, Benutzer, '
        'SSH-Key …) klappt jetzt ein, sobald die Daten stehen — und zeigt nur '
        'noch eine kompakte Zeile („pi@192.168.178.64 · SSH-Key"). Vor allem das '
        'große SSH-Key-Feld nimmt so keinen Platz mehr weg. Zum Bearbeiten '
        'einfach auf die Kopfzeile tippen; nach dem Verbinden klappt sie '
        'automatisch zu.',
  ],
  '0.55.1': [
    'Fernzugriff leichter zu finden: „Fernzugriff: Tailscale öffnen" steht jetzt '
        'immer im ⋮-Menü — ausgegraut mit Hinweis, solange die App die '
        'Tailscale-IP deines Pi noch nicht kennt (einmal verbinden genügt). So '
        'ist die Funktion auffindbar und das Menü bleibt vorhersehbar.',
  ],
  '0.55.0': [
    'Fernzugriff robuster: Verbindest du dich über einen Tailscale-MagicDNS-Namen '
        '(*.ts.net), wird deine Heim-IP nicht mehr versehentlich überschrieben — '
        '„Zurück auf Heim-IP" bleibt zuverlässig.',
    'Härtung & Feinschliff: zusätzliche Absicherung der auf dem Pi erzeugten '
        'Timer-Skripte (Shell-Quoting), und der „Pi neu starten"-Dialog ist nicht '
        'mehr rot markiert — ein Neustart löscht keine Daten.',
  ],
  '0.54.0': [
    'SSH-Key einrichten — jetzt direkt beim Pi: Tippst du im Verbindungsformular '
        'auf „SSH-Key" und hast noch keinen hinterlegt, erscheint dort ein Knopf '
        '„SSH-Key automatisch einrichten". Die App erzeugt den Schlüssel, '
        'hinterlegt ihn (einmalig mit deinem Passwort) und stellt das Profil um. '
        'Der Eintrag aus dem ⋮-Menü ist entfallen — die Einrichtung gehört zum '
        'jeweiligen Pi, nicht ins globale Menü.',
  ],
  '0.53.2': [
    'Zurück auf die Heim-IP mit einem Tap: Wenn du über die Tailscale-IP (100.x) '
        'verbunden warst und wieder zuhause im WLAN bist, gibt es im ⋮-Menü jetzt '
        '„Zurück auf Heim-IP" — die App merkt sich deine LAN-Adresse automatisch '
        'und setzt sie zurück. Kein erneutes „Pi suchen" oder Abtippen mehr.',
  ],
  '0.53.1': [
    'Fernzugriff jetzt am richtigen Ort: „Fernzugriff: Tailscale öffnen" liegt '
        'jetzt im ⋮-Menü oben rechts — also genau dann erreichbar, wenn du '
        'unterwegs und NICHT mit dem Pi verbunden bist (dafür ist Fernzugriff ja '
        'da). Die App merkt sich die Tailnet-IP (100.x) deines Pi vom letzten '
        'Mal, setzt sie als Host und öffnet die Tailscale-App zum VPN-Einschalten. '
        'Danach nur noch „Verbindung herstellen".',
  ],
  '0.53.0': [
    'Fernzugriff mit einem Tap: über „Fernzugriff: Tailscale öffnen" setzt die '
        'App die Tailnet-IP (100.x) deines Pi als Host und öffnet die '
        'Tailscale-App, damit du dort das VPN einschaltest. Danach nur noch '
        '„Verbindung herstellen" und du bist von überall auf dem Pi. (Die App '
        'kann das Handy-VPN aus Android-Gründen nicht selbst einschalten — nur '
        'die Tailscale-App öffnen.)',
  ],
  '0.52.0': [
    'Alle Pis auf einmal aktualisieren: Im „Alle Pis"-Überblick gibt es jetzt '
        'oben rechts einen Update-Knopf — er spielt nacheinander auf jedem '
        'erreichbaren Pi mit ausstehenden Updates das System-Update ein. '
        'Fail-soft (ein Fehler stoppt die anderen nicht), Fortschritt pro Zeile.',
  ],
  '0.51.0': [
    'Geplante Backups: Im Automatik-Tab kannst du jetzt nächtliche Backups '
        'einrichten — evcc (Konfig + Daten) und Pi-hole (Teleporter) werden '
        'automatisch gesichert, mit Rotation (alte Backups werden aufgeräumt). '
        'Läuft als Timer auf dem Pi, kein Hintergrunddienst auf dem Handy.',
  ],
  '0.50.0': [
    'Mehr Dienste erkannt: Wenn du AdGuard Home, Node-RED oder Zigbee2MQTT auf '
        'dem Pi hast, erscheinen sie jetzt als eigene Karten — mit Weboberfläche '
        'öffnen, Logs ansehen und Neustart. (Die Installation überlässt die App '
        'bewusst dir; erkannt und verwaltet werden sie automatisch.)',
  ],
  '0.49.0': [
    'Docker-Übersicht: „Docker-Container" (System-Karte) zeigt alle Container '
        '(laufend und gestoppt) mit Status und Image. Pro Container kannst du '
        'neustarten und die Logs ansehen — praktisch, wenn du mehr als die '
        'bekannten Dienste per Docker betreibst.',
  ],
  '0.48.0': [
    'Speicherplatz-Explorer: „Speicherplatz analysieren" (System-Karte) zeigt, '
        'was den Platz frisst — die größten Ordner und Dateien, nach Größe '
        'sortiert. Auf einen Ordner tippen, um hineinzuzoomen.',
    'Live-Logs: In der Log-Ansicht gibt es jetzt einen „Live"-Schalter — die '
        'Logs aktualisieren sich dann alle paar Sekunden von selbst.',
  ],
  '0.47.0': [
    'SSH-Key mit einem Tap: Über „SSH-Key einrichten" (⋮-Menü) erzeugt die App '
        'ein Schlüsselpaar direkt auf dem Handy, hinterlegt den öffentlichen '
        'Schlüssel auf dem Pi und stellt das Profil auf Key-Login um — deutlich '
        'sicherer als Passwort-Login. Der private Schlüssel verlässt das Handy '
        'nie; dein Passwort bleibt für sudo gespeichert.',
  ],
  '0.46.0': [
    'Sicherheits-Check: Die System-Karte hat jetzt einen „Sicherheits-Check" — '
        'eine reine Nur-Lesen-Prüfung mit Ampel: SSH-Root-Login, Passwort- vs. '
        'Key-Login, automatische Sicherheitsupdates, fail2ban und offene Ports. '
        'Die App zeigt nur an und empfiehlt — geändert wird nichts.',
  ],
  '0.45.0': [
    'Dateien bearbeiten: Tippst du im Dateien-Tab auf eine Textdatei, gibt es '
        'jetzt „Bearbeiten" — die Datei öffnet sich im Editor und wird atomar '
        'mit automatischer Sicherung gespeichert (wie schon beim Config-Editor). '
        'Binärdateien bleiben schreibgeschützt.',
    'Eigene Schnellbefehle: In der Konsole kannst du über „Eigene Befehle" '
        'eigene Kommandos anlegen und wieder löschen — sie stehen dann dauerhaft '
        'neben den vorgefertigten Schnellbefehlen.',
  ],
  '0.44.0': [
    'Pi herunterfahren: Neben „Pi neu starten" gibt es jetzt „Pi herunterfahren" '
        '(System-Karte und ⋮-Menü). Achtung — der Pi bleibt danach AUS und ist '
        'erst wieder erreichbar, wenn du ihn physisch neu einschaltest; deshalb '
        'kommt eine deutliche Sicherheitsabfrage.',
  ],
  '0.43.1': [
    'Mehr Platz auf der Startseite: die Fußzeile (Version, Rechtliches) ist '
        'nicht mehr fest angepinnt, sondern hängt jetzt unten an der Liste — der '
        'Dienste-Bereich bekommt die volle Höhe.',
  ],
  '0.43.0': [
    'Feinschliff am Marken-Look: der „KYTH."-Schriftzug erscheint jetzt in der '
        'echten Hausschrift (Bricolage Grotesque, mitgeliefert) mit dem grün '
        'leuchtenden Schlusspunkt — passend zur Website. Rein optisch, keine '
        'Funktionsänderung.',
  ],
  '0.42.0': [
    'Alle Pis auf einen Blick: hast du mehrere Profile, gibt es oben rechts im '
        '⋮-Menü jetzt „Alle Pis (Überblick)" — eine Ampel-Liste, die jeden Pi der '
        'Reihe nach prüft und grün (alles gut), amber (Updates oder Warnung) oder '
        'rot (nicht erreichbar) anzeigt. So siehst du sofort, welcher Pi '
        'Aufmerksamkeit braucht.',
  ],
  '0.41.0': [
    'Profile mitnehmen: In den Einstellungen kannst du jetzt alle Pi-Profile '
        '(inkl. Zugangsdaten) als **verschlüsselte** Datei exportieren und auf '
        'einem neuen Handy importieren — geschützt durch eine Passphrase, die '
        'nur du kennst. Perfekt für den Gerätewechsel.',
  ],
  '0.40.0': [
    'Backups aufs Handy laden: in „Backups verwalten" gibt es jetzt einen '
        'Download-Knopf pro Backup — das Archiv landet über den Teilen-Dialog '
        'auf dem Handy (Dateien, Drive, …). So überlebt dein Backup auch einen '
        'SD-Karten-Tod.',
    'Support: in den Einstellungen gibt es jetzt „Support kontaktieren" — '
        'öffnet deine Mail-App mit unserer Support-Adresse.',
  ],
  '0.39.0': [
    'SD-Karten-Gesundheitscheck: die System-Karte warnt jetzt, wenn das '
        'Dateisystem nur-lesend geworden ist oder sich I/O-Fehler im Kernel-Log '
        'häufen — die klassischen Anzeichen einer sterbenden SD-Karte, bevor '
        'der Pi ausfällt. Auch die Health-Alerts prüfen das mit (dafür einmal '
        'Health-Alerts aus- und wieder einschalten).',
  ],
  '0.38.0': [
    'Aufgeräumte Startseite: „Changelog" und „Auf Update prüfen" sind jetzt oben '
        'rechts im ⋮-Menü; Datenschutz, Impressum und Open-Source-Lizenzen stehen '
        'klein ganz unten unter der Version. Dazu diverse Robustheit aus dem '
        'Audit (destruktive Aktionen rot, deutsche System-Dialoge, gedeckelte '
        'Log-/Terminal-Ausgabe).',
  ],
  '0.37.0': [
    'Robustheit aus einem kompletten App-Audit: Tailscale meldet ein falsches '
        'Passwort jetzt korrekt (statt „verbunden"), der Dateien-Tab lädt beim '
        'Pi-Wechsel automatisch neu, der Upload prüft die Dateigröße schon vorab, '
        'und Passwort-Fehler werden auch auf deutschsprachigen Pis sauber erkannt.',
  ],
  '0.36.0': [
    'Dateien hochladen ist da: im Dateien-Tab oben rechts auf das Upload-Symbol '
        'tippen, eine Datei vom Handy wählen — sie landet im gerade geöffneten '
        'Ordner auf dem Pi.',
  ],
  '0.35.0': [
    'Neuer Tab „Dateien": die Dateien deines Pi durchsuchen, antippen zum '
        'Ansehen und löschen — direkt unten in der Leiste erreichbar. '
        '(Hochladen folgt in Kürze.)',
  ],
  '0.34.0': [
    'Konsole: interaktive Befehle wie „htop", „top", Editoren oder der '
        'Folgemodus „-f" brauchen ein echtes Terminal und liefen bisher nur in '
        'einen Fehler. Jetzt gibt die App einen klaren Hinweis mit passender '
        'Alternative (z. B. „top -bn1") – statt „Error opening terminal".',
  ],
  '0.33.0': [
    'Neu und noch keinen Pi? Es gibt jetzt eine eingebaute Schritt-für-Schritt-'
        'Anleitung „Pi einrichten" (mit Raspberry Pi Imager: SSH, Benutzer, WLAN) '
        '— erreichbar über das ⋮-Menü und direkt auf dem Verbindungs-Screen, '
        'wenn noch kein Pi eingetragen ist.',
  ],
  '0.32.0': [
    'Aktiver Pi immer sichtbar: oben in der Leiste steht jetzt der aktuelle Pi '
        '— auf jedem Tab. Antippen öffnet den Umschalter zum Wechseln, '
        'Hinzufügen und Umbenennen. Die separate Profil-Leiste unten entfällt.',
  ],
  '0.31.0': [
    'Tailscale (VPN/Mesh) als Dienst: installieren, per Login-Link verbinden, '
        'trennen/abmelden. Und der Clou: die Tailnet-IP (100.x) mit einem Tap '
        'ins Host-Feld übernehmen — so erreichst du den Pi von überall, ohne '
        'die Adresse zu suchen.',
  ],
  '0.30.0': [
    'Raspberry Pi Connect (offizieller Fernzugriff) als Dienst: installieren, '
        'per Link anmelden (Raspberry Pi ID), an/aus schalten, Web-Oberfläche '
        'öffnen. Braucht Raspberry Pi OS Bookworm+ — auf älteren Pis wird es '
        'ausgegraut mit Hinweis angezeigt.',
  ],
  '0.29.0': [
    'Laufende Aktionen sind jetzt auf JEDEM Tab sichtbar: ganz oben ein '
        'Fortschrittsbalken mit „läuft …", einem Sprung zum Log und Abbrechen '
        '— egal, von wo du sie gestartet hast.',
    'Health-Alerts-Dialog wird nicht mehr von der Bedienleiste überdeckt; '
        'Feinschliff an Texten (Umlaute) und der Bedienung.',
  ],
  '0.28.0': [
    'Konfiguration bearbeiten: evcc.yaml direkt in der App ändern — mit '
        'automatischer Sicherung vorher (evcc-Karte → „Konfiguration '
        'bearbeiten").',
    'Datei-Browser: durch die Verzeichnisse des Pi navigieren und Dateien '
        'ansehen (Terminal-Tab → „Dateien durchsuchen").',
  ],
  '0.27.0': [
    'Logs ansehen: jede Dienst-Karte hat jetzt „Logs anzeigen" (journald bzw. '
        'docker logs) — praktisch zur Fehlersuche.',
    'Geführtes Setup: „Energie-Monitoring-Stack" (InfluxDB + Grafana + '
        'Mosquitto) in einem Schritt installieren, oben im „Dienst hinzufügen".',
  ],
  '0.26.0': [
    'Health-Alerts: der Pi meldet sich per Push (über ntfy), wenn die Platte '
        'vollläuft, ein Dienst ausfällt, es zu heiß wird oder Updates anstehen '
        '— alle 30 Min., kostenlos und ohne Konto. Automatik-Tab → '
        '„Health-Alerts".',
  ],
  '0.25.0': [
    'Neue Struktur: unten drei Tabs — „Dienste" (deine Karten), „Automatik" '
        '(automatische Updates, bald Health-Alerts) und „Terminal" (die '
        'Konsole). Übersichtlicher, je mehr dazukommt.',
  ],
  '0.24.0': [
    'Automatische Updates: der Pi aktualisiert sich künftig selbst nach '
        'Zeitplan (täglich/wöchentlich). evcc wird vorher gesichert und bei '
        'Problemen automatisch neu gestartet — kein Hintergrunddienst, ein '
        'systemd-Timer läuft direkt auf dem Pi. System-Karte → „Automatische '
        'Updates".',
  ],
  '0.22.0': [
    'Backups komplett: Pi-hole- und Home-Assistant-Backups lassen sich jetzt '
        'direkt in der App wiederherstellen und verwalten (auflisten, löschen); '
        'alte Backups werden automatisch aufgeräumt (die letzten 5 bleiben).',
    'Neu auf der System-Karte: „Aufräumen" gibt Speicher frei (apt, ungenutzte '
        'Docker-Images, altes Journal) und zeigt, wie viel.',
    'Home Assistant zeigt jetzt „Aktuell", wenn es aktuell ist — die echte '
        'Version wird gegen das neueste Release geprüft (nicht mehr immer '
        '„Aktualisieren").',
    'Konsole: Verlauf + Schnellbefehle über das Uhr-Symbol neben der Eingabe '
        '(Verlauf löschbar).',
  ],
  '0.21.15': [
    'Verbindung deutlich schneller: alle Dienst-Prüfungen laufen jetzt in EINER '
        'SSH-Runde statt ~13 nacheinander — vor allem über Tailscale spürbar.',
    'Sofort „Verbunden" anzeigen, die Karten füllen sich direkt danach.',
    'Konsole: eigene Befehle direkt auf dem Pi absetzen (sudo unterstützt).',
  ],
  '0.21.14': [
    'Konsole: eigene Befehle direkt auf dem Pi absetzen (sudo unterstützt) — '
        'statt nur Log jetzt mit Eingabe unten.',
    '„Was ist neu?" nach jedem Update (dieses Fenster) + Nutzungs-Hinweis beim '
        'allerersten Start.',
    '„Dienst hinzufügen": alle installierbaren Dienste an einer Stelle; die '
        'System-Karte steht immer oben.',
    'KYTH-Splash beim Start + „by KYTH."-Branding; Feinschliff im Hell-Modus.',
  ],
};
