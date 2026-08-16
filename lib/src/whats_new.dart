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
  '0.67.0': [
    'The evcc card now shows live values directly on the management tab: PV, '
        'grid and house consumption, plus battery level and the loadpoint that '
        'is charging. Until now these were only available from the menu.',
    'If the evcc API does not answer — different port, login enabled, evcc '
        'offline — the card stays unchanged. No error is raised for it, and '
        'detection itself is unaffected.',
    'The ⋮ menu has a "GitHub" entry leading straight to the project.',
    'Both changes come from reports in the GitHub issue tracker.',
  ],
  '0.66.3': [
    'Last item from the self-audit, a long-standing one: when a restart in the '
        'Docker overview failed, visibly nothing happened — the spinner turned, '
        'then silence. The app now says what went wrong, and the error lands '
        'in the log as well.',
  ],
  '0.66.2': [
    'I put the big update through a systematic audit against itself — before '
        'any of you would hit it. Sixteen findings; the important ones are '
        'fixed here.',
    'The migration helper would have failed at its core case: on a fresh '
        'target Pi the backup directory did not exist, so the upload aborted — '
        'after the services had already been installed there. Fixed.',
    'The stack wiring now tells the truth: if a half is skipped (evcc in '
        'Docker, no Grafana) it says "only partly wired" instead of a green '
        'tick above an empty dashboard. And an evcc without a systemd service '
        'is recognized as such instead of "configuration rejected".',
    'Container updates now run in the normal flow with progress, cancel and '
        'background protection — Android could previously freeze the app '
        'mid-recreate. A recreated container also keeps its command, user and '
        'hostname now.',
    'The security check no longer reports a green "running" when '
        'unattended-upgrades is installed but switched off.',
  ],
  '0.66.0': [
    'The biggest update yet — five new abilities at once.',
    'Monitoring at the push of a button: the Grafana card now wires up the '
        'whole stack — set up InfluxDB, connect evcc, provision a ready-made '
        'Grafana dashboard. Charts from minute one instead of empty services.',
    'Security check with "Fix": install fail2ban, enable automatic security '
        'updates, disable root login — one tap, with a safety net (rolled '
        'back automatically if anything is off).',
    'Migration helper: "Move to another Pi" carries evcc + Pi-hole and their '
        'backups to a new Pi. The old one stays untouched.',
    'The Docker overview can now update any container — with the same '
        'rollback net as the evcc update.',
    'And the evcc card shows the full release notes — readable without '
        'starting an update.',
  ],
  '0.65.2': [
    'Another wish from the same user: every service card now leads to the '
        'project behind it.',
    'A card\'s ⋮ menu has "Project website" — and for evcc, Home Assistant and '
        'Tailscale also "Official app", which opens the app if you have it and '
        'its Play listing if you don\'t. Where a project ships no official app, '
        'none is claimed.',
    '"Open web" stays what it was: the interface on your own Pi.',
  ],
  '0.65.1': [
    'Thanks again to the same user: the log no longer drowns in noise while '
        'installing or updating.',
    'apt had dpkg paint a progress bar for a terminal that is not there — some '
        'twenty lines of "(Reading database ... 5% ... 10% ..." per package. '
        'Those are no longer produced at all, and whatever a third-party '
        'installer still sends is filtered out. Every real message stays.',
  ],
  '0.65.0': [
    'Thanks to the user who sent the first detailed feedback — this release is '
        'almost entirely his suggestions.',
    'One Pi can now connect by itself at startup. The switch sits with the '
        'credentials, exactly one Pi may use it, and it never runs past the '
        'app lock.',
    'The app no longer opens empty: it shows the last known state of your Pi '
        'right away — clearly marked as remembered — and replaces it once the '
        'real detection lands.',
    'Screenshots work again. They used to be blocked everywhere because the '
        'connection screen can show passwords. Now only that screen and the '
        'lock screen are protected; the rest of the app is yours to share.',
    'Pi-hole install: /etc/pihole stayed owned by root, so Pi-hole could not '
        'write to it and the permissions had to be fixed by hand. It is handed '
        'over properly now.',
  ],
  '0.64.5': [
    'The remote-access entry is now a slim row instead of a large card — and '
        'you can dismiss it with ✕. It then stays gone, restarts included. Not '
        'everyone wants remote access, and until now there was simply no way to '
        'say so.',
    'If you change your mind later, "Set up remote access" lives in the ⋮ menu '
        'of the Tailscale card. During the setup itself the full explanation '
        'stays — that is where it helps.',
  ],
  '0.64.4': [
    '"Try the demo" disappears for good again — but only once a connection to '
        'your Pi has actually succeeded. Before, it keyed on whether the fields '
        'looked filled in, which is not the same thing and left people facing a '
        'wall.',
    'Remote access no longer claims the Tailscale app is missing from your '
        'phone. It can only measure whether your phone reaches the Pi, and that '
        'also fails when Tailscale is installed but the VPN is switched off. '
        'One button now covers both: it opens Tailscale, or the Play Store if '
        'it really is missing.',
    'And the setup says up front that it takes two sides — Pi and phone. You '
        'used to find that out only after the check.',
  ],
  '0.64.3': [
    'Fixed: "Try the demo" disappeared as soon as host and password were '
        'filled in, because the Pi then counted as configured. Anyone who '
        'mistyped something — or just wanted to look around — was left facing '
        'a wall with no way past it. The entry now stays until a connection is '
        'actually established.',
    'The footer now has "Rate the app" — if Pi-Tool is useful to you, a Play '
        'Store rating is the single most helpful thing you can give it. Ratings '
        'are how anyone else finds it in the first place.',
  ],
  '0.64.2': [
    'When Raspberry Pi Connect or Tailscale has an update waiting, the card\'s '
        'main button now reads "Update" — the same as evcc, Pi-hole, Grafana '
        'and the rest. It used to keep saying "Open web" or "Connect" while the '
        'update hid in the ⋮ menu behind a small amber light. The displaced '
        'action lives in ⋮ meanwhile and returns once the update is done.',
  ],
  '0.64.1': [
    'If an apt or dpkg run on the Pi was ever killed mid-way (power cut, '
        'cancelled update), apt refuses every further install — including '
        'updates that have nothing to do with it. The app now names that '
        'instead of just reporting "Exit 100", and clears it up: System card → '
        '⋮ → "Repair package state".',
    'Also fixed: on Pis whose sudo needs no password, a "command not found" '
        'showed up in the log. The app was sending the password even though '
        'sudo never asked for it — it now asks first and sends it only when '
        'it is actually needed.',
  ],
  '0.64.0': [
    'Remote access in one button: while you are connected to your Pi, the app '
        'sets up access from anywhere — install Tailscale, sign in, confirm the '
        'login in your browser. It then checks whether your phone actually '
        'reaches the Pi over the tailnet, and reports success only once it has '
        'measured it.',
    'If your phone is still missing the Tailscale app, the app says so instead '
        'of claiming "done" — otherwise you would find out on the road, where '
        'nothing can be fixed.',
    'And you never switch addresses again: connecting tries the home address '
        'first and falls back to the tailnet IP. With only one known address '
        'nothing is probed at all, so nobody pays for a feature they do not use.',
  ],
  '0.63.7': [
    'The update display no longer claims "up to date" when it cannot possibly '
        'know. It reads the state from the Pi\'s package index — and a stock '
        'Raspberry Pi OS often leaves that untouched for weeks. Older than '
        'three days, and you now get "state unknown" instead of a green check, '
        'plus "Refresh package lists" in the System card\'s ⋮ menu.',
    'Why it matters: a reassuring "up to date" could sit on top of a Pi with '
        'security updates already waiting. It affected every apt-managed card '
        '— Pi Connect, Tailscale, Grafana, InfluxDB, Mosquitto and System.',
  ],
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
  '0.67.0': [
    'Die evcc-Karte zeigt die Live-Werte jetzt direkt auf dem Verwaltungs-Tab: '
        'PV, Netz und Hausverbrauch, dazu Batterie-Ladestand und der Ladepunkt, '
        'der gerade lädt. Bisher lagen diese Werte nur im Menü.',
    'Antwortet die evcc-API nicht — anderer Port, Anmeldung aktiv, evcc '
        'offline — bleibt die Karte unverändert. Es gibt dafür keine '
        'Fehlermeldung, die Erkennung selbst ist davon unberührt.',
    'Das ⋮-Menü enthält einen Eintrag „GitHub", der direkt zum Projekt führt.',
    'Beides geht auf Meldungen aus dem GitHub-Issue-Tracker zurück.',
  ],
  '0.66.3': [
    'Letzter Punkt aus der Selbstprüfung, eine Altlast: Scheiterte in der '
        'Docker-Übersicht ein Neustart, passierte sichtbar gar nichts — der '
        'Spinner drehte kurz, dann Stille. Jetzt sagt die App, was schiefging, '
        'und der Fehler steht auch im Log.',
  ],
  '0.66.2': [
    'Ich habe das große Update noch einmal systematisch gegen sich selbst '
        'geprüft — bevor es jemand von euch findet. Sechzehn Befunde, hier '
        'sind die wichtigsten behoben.',
    'Der Umzugshelfer wäre in seinem Kernfall gescheitert: Auf einem frischen '
        'Ziel-Pi fehlte das Backup-Verzeichnis, der Upload brach ab — nachdem '
        'die Dienste dort schon installiert waren. Behoben.',
    'Die Stack-Verdrahtung sagt jetzt die Wahrheit: Wird eine Hälfte '
        'übersprungen (evcc im Docker, kein Grafana), steht da „nur teilweise '
        'verdrahtet" statt eines grünen Hakens über einem leeren Dashboard. '
        'Und ein evcc ohne systemd-Dienst wird als solches erkannt, statt als '
        '„Konfiguration abgelehnt".',
    'Container-Updates laufen jetzt im normalen Ablauf mit Fortschritt, '
        'Abbrechen und Hintergrund-Absicherung — vorher konnte Android die App '
        'mitten im Neuanlegen einfrieren. Außerdem behält ein neu angelegter '
        'Container jetzt Kommando, Benutzer und Hostname.',
    'Der Sicherheits-Check meldet kein grünes „läuft" mehr, wenn '
        'unattended-upgrades zwar installiert, aber abgeschaltet ist.',
  ],
  '0.66.0': [
    'Das größte Update bisher — fünf neue Fähigkeiten auf einmal.',
    'Monitoring auf Knopfdruck: Die Grafana-Karte verdrahtet den Stack jetzt '
        'komplett — InfluxDB einrichten, evcc anschließen, fertiges Dashboard '
        'in Grafana. Charts ab Minute eins statt leerer Dienste.',
    'Sicherheits-Check mit „Beheben": fail2ban installieren, automatische '
        'Sicherheitsupdates aktivieren, Root-Login abschalten — ein Tap, mit '
        'Netz und doppeltem Boden (wird bei Problemen zurückgenommen).',
    'Umzugshelfer: „Auf anderen Pi umziehen" bringt evcc + Pi-hole samt '
        'Backups auf einen neuen Pi. Der alte bleibt unverändert.',
    'Die Docker-Übersicht kann jetzt jeden Container aktualisieren — mit '
        'demselben Rollback-Netz wie beim evcc-Update.',
    'Und die evcc-Karte zeigt die vollständigen Release-Notes — lesbar, ohne '
        'ein Update zu starten.',
  ],
  '0.65.2': [
    'Wieder ein Wunsch aus der Rückmeldung desselben Nutzers: Von jeder '
        'Dienst-Karte kommst du jetzt zum Projekt dahinter.',
    'Im ⋮-Menü einer Karte findest du „Projekt-Website" — und bei evcc, Home '
        'Assistant und Tailscale zusätzlich „Offizielle App". Die öffnet die '
        'App direkt, wenn du sie hast, sonst ihren Play-Eintrag. Wo es keine '
        'offizielle App gibt, steht auch keine da.',
    '„Web öffnen" bleibt, was es war: die Oberfläche auf deinem Pi.',
  ],
  '0.65.1': [
    'Schon wieder Dank an denselben Nutzer: Das Log ist beim Installieren und '
        'Aktualisieren nicht mehr zugemüllt.',
    'apt hat dpkg bisher einen Fortschrittsbalken für ein Terminal malen '
        'lassen, das es hier gar nicht gibt — pro Paket rund zwanzig Zeilen '
        '„(Reading database ... 5% ... 10% ...". Die entstehen jetzt gar nicht '
        'mehr, und was ein fremder Installer trotzdem schickt, filtert die App '
        'heraus. Die echten Meldungen bleiben alle stehen.',
  ],
  '0.65.0': [
    'Danke an den Nutzer, von dem die erste ausführliche Rückmeldung kam — '
        'diese Version besteht fast komplett aus seinen Vorschlägen.',
    'Ein Pi kann sich beim Start jetzt von allein verbinden. Der Schalter sitzt '
        'bei den Zugangsdaten; genau ein Pi darf es sein, und an der App-Sperre '
        'vorbei passiert es nie.',
    'Die App öffnet nicht mehr leer: Sie zeigt sofort den zuletzt bekannten '
        'Stand deines Pi — deutlich als Erinnerung gekennzeichnet — und '
        'ersetzt ihn, sobald die echte Erkennung durch ist.',
    'Screenshots gehen wieder. Bisher waren sie überall gesperrt, weil auf dem '
        'Verbindungsbildschirm Passwörter stehen können. Gesperrt ist jetzt nur '
        'noch genau dort und auf dem Sperrbildschirm — den Rest der App darfst '
        'du zeigen und teilen.',
    'Pi-hole-Installation: Das Verzeichnis /etc/pihole blieb dem Benutzer root '
        'zugeordnet, sodass Pi-hole nicht hineinschreiben konnte und man die '
        'Rechte von Hand nachziehen musste. Wird jetzt korrekt übergeben.',
  ],
  '0.64.5': [
    'Der Fernzugriff-Einstieg ist jetzt eine schmale Zeile statt einer großen '
        'Karte — und du kannst ihn mit ✕ wegtippen. Dann ist er dauerhaft weg, '
        'auch nach einem Neustart. Nicht jeder will Fernzugriff, und bisher gab '
        'es schlicht keine Möglichkeit, das zu sagen.',
    'Wer es sich später anders überlegt, findet „Fernzugriff einrichten" im '
        '⋮-Menü der Tailscale-Karte. Während der Einrichtung selbst bleibt die '
        'ausführliche Erklärung stehen — dort hilft sie.',
  ],
  '0.64.4': [
    '„Demo ausprobieren" verschwindet wieder ganz — aber erst, wenn eine '
        'Verbindung zu deinem Pi tatsächlich einmal gestanden hat. Vorher hing '
        'das daran, ob die Felder ausgefüllt aussahen; das ist nicht dasselbe '
        'und hat schon Nutzer vor eine Wand laufen lassen.',
    'Beim Fernzugriff behauptet die App nicht mehr, die Tailscale-App fehle auf '
        'dem Handy. Sie kann nur messen, ob dein Handy den Pi erreicht — und '
        'das schlägt auch fehl, wenn Tailscale installiert, das VPN aber aus '
        'ist. Ein Knopf deckt jetzt beides ab: Er öffnet Tailscale, oder den '
        'Play Store, falls es wirklich fehlt.',
    'Und die Einrichtung sagt gleich zu Beginn, dass zwei Seiten dazugehören — '
        'Pi und Handy. Bisher erfuhr man das erst nach der Prüfung.',
  ],
  '0.64.3': [
    'Behoben: „Demo ausprobieren" verschwand, sobald Host und Passwort '
        'ausgefüllt waren — der Pi galt dann als eingerichtet. Wer sich '
        'vertippt hatte oder nur schauen wollte, stand vor einer Wand ohne '
        'Ausweg. Der Einstieg bleibt jetzt, bis eine Verbindung wirklich steht.',
    'Unten in der Fußzeile liegt jetzt „App bewerten" — falls dir Pi-Tool hilft, '
        'ist eine Bewertung im Play Store das, was der App am meisten bringt. '
        'Sie ist der Grund, warum andere sie überhaupt finden.',
  ],
  '0.64.2': [
    'Steht bei Raspberry Pi Connect oder Tailscale ein Update an, heißt der '
        'Hauptknopf der Karte jetzt „Aktualisieren" — wie bei evcc, Pi-hole, '
        'Grafana und den anderen. Bisher stand dort weiter „Web öffnen" bzw. '
        '„Verbinden", und das Update versteckte sich im ⋮-Menü hinter einer '
        'kleinen gelben Lampe. Die verdrängte Aktion findest du solange im '
        '⋮-Menü; nach dem Update ist sie wieder am gewohnten Platz.',
  ],
  '0.64.1': [
    'Wurde auf dem Pi einmal ein apt- oder dpkg-Lauf abgewürgt (Stromausfall, '
        'abgebrochenes Update), verweigert apt danach jede weitere '
        'Installation — auch Updates, die nichts damit zu tun haben. Die App '
        'nennt das jetzt beim Namen statt nur „Exit 100" zu melden, und räumt '
        'es auf: System-Karte → ⋮ → „Paketzustand reparieren".',
    'Außerdem behoben: Auf Pis, deren sudo kein Passwort verlangt, tauchte im '
        'Log ein „command not found" auf. Die App schickte das Passwort mit, '
        'obwohl sudo gar nicht danach fragte — jetzt fragt sie vorher nach und '
        'schickt es nur, wenn es gebraucht wird.',
  ],
  '0.64.0': [
    'Fernzugriff mit einem Knopf: Bist du mit deinem Pi verbunden, richtet die '
        'App den Zugriff von unterwegs komplett ein — Tailscale installieren, '
        'anmelden, Login im Browser bestätigen. Danach prüft sie nach, ob dein '
        'Handy den Pi über das Tailnet wirklich erreicht, und meldet Erfolg '
        'erst, wenn sie ihn gemessen hat.',
    'Fehlt auf dem Handy noch die Tailscale-App, sagt die App genau das statt '
        '„fertig" zu behaupten — sonst merkst du es erst unterwegs, wo du nichts '
        'mehr reparieren kannst.',
    'Und du musst nie wieder umschalten: Beim Verbinden probiert die App zuerst '
        'die Heim-Adresse und fällt sonst auf die Tailnet-IP zurück. Wer nur '
        'eine Adresse hat, merkt davon nichts — dort wird gar nicht gesucht.',
  ],
  '0.63.7': [
    'Die Update-Anzeige sagt nicht mehr „aktuell", wenn sie es gar nicht wissen '
        'kann. Sie liest den Stand aus dem Paketverzeichnis des Pi — und das '
        'erneuert ein Raspberry Pi OS von sich aus oft wochenlang nicht. Ist es '
        'älter als drei Tage, steht jetzt „Stand unbekannt" statt eines grünen '
        'Hakens, und die System-Karte bietet im ⋮-Menü „Paketlisten '
        'aktualisieren" an.',
    'Warum das zählt: Vorher konnte ein beruhigendes „aktuell" über einem Pi '
        'stehen, auf dem längst Sicherheitsupdates warteten. Betroffen waren '
        'alle per apt gepflegten Karten — Pi Connect, Tailscale, Grafana, '
        'InfluxDB, Mosquitto und System.',
  ],
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
