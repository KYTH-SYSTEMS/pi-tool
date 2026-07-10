/// "Was ist neu?" popup logic + curated per-version highlights. Kept pure so
/// the decision + content are unit-testable; the dialog itself lives in the UI.
library;

/// Show the popup only on an actual UPDATE: the stored last-seen version differs
/// from the current one AND isn't empty. An empty last-seen means a fresh
/// install (or pre-feature first run), where we record silently and don't nag.
bool shouldShowWhatsNew({required String lastSeen, required String current}) =>
    current.isNotEmpty && lastSeen.isNotEmpty && lastSeen != current;

/// Curated highlights for [version], or null when there's nothing to show (then
/// no popup even if the version changed). Keep only the latest few entries.
List<String>? whatsNewFor(String version) => _whatsNew[version];

const Map<String, List<String>> _whatsNew = {
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
