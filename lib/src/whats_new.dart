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
