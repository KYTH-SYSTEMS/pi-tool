# ntfy-Topic-Härtung + Rechtstexte (Compliance-Prüfung 0.62.0+113)

**Stand:** 26.07.2026 · umgesetzt in **v0.63.0+114**
**Auslöser:** Prüfung der App-Rechtstexte aus der Rechts-/Compliance-Ablage der
KYTH. Systems UG. Impressum/DSE insgesamt in Ordnung (§ 5 DDG, HRB 46313, beide
GF, kein Tracking) — ein echter Fund plus Nachträge.

## Das Problem (der eigentliche Fund)

ntfy kennt **kein Konto und keine Authentifizierung**: „Since there is no
sign-up, the topic is essentially a password, so pick something that's not
easily guessable" (docs.ntfy.sh/publish). Wer den Topic-Namen kennt oder errät,
abonniert ihn und liest den Health-Feed mit — **welche Dienste auf dem Pi laufen
und welche Updates offen sind**. Das ist eine Aufklärungskarte, kein Formalfehler.

Vorher: Das Topic-Feld war ein leeres Freitextfeld, Hint `mein-pi-a7Xk` (12
Zeichen), Helper „Frei wählbar, aber schwer erratbar wählen." — der Hinweis nannte
weder den Grund noch bot er einen sicheren Weg an. Der bequeme Weg (kurzer Name)
war der unsichere.

## Entscheidungen

| Frage | Entscheidung | Warum |
| --- | --- | --- |
| Zufallstopic | **Vorbelegen + Würfel-Knopf** | Der Default-Pfad muss der sichere sein. Wer nichts tut, bekommt ~69 Bit. |
| Bestandsnutzer | **Warnzeile auf der Automatik-Karte** | Wer die Alerts einmal eingerichtet hat, öffnet das Sheet nie wieder — genau der Risikofall. |
| Erzwingen? | **Nein** | Eigene Topics (z. B. selbst gehosteter ntfy mit Auth) bleiben erlaubt; es wird gewarnt, nicht blockiert. |

## Umsetzung

- `alerts.dart` (rein, testbar):
  - `generateNtfyTopic([Random])` → `pi-tool-` + 14 Zeichen aus 31er-Alphabet
    (lowercase+Ziffern **ohne** `0/o`, `1/l/i`, damit man es abtippen kann)
    ≈ 69 Bit, 22 Zeichen — innerhalb von ntfys `[-_A-Za-z0-9]` und 64-Zeichen-Limit.
    Produktion nutzt `Random.secure()`, Tests injizieren `Random(seed)`.
  - `isWeakNtfyTopic(String)` → `< 16 Zeichen` **oder** `< 8 verschiedene Zeichen`.
    **Bewusst grob und in Richtung Warnung verzerrt:** eine Fehlwarnung kostet
    einen Tipp, ein übersehener Fall einen öffentlich lesbaren Health-Feed. Sie
    erkennt den realistischen Fall (`pi`, `evcc`, `mein-pi`) — sie kann *nicht*
    beurteilen, ob ein langer Name eine erratbare Wortkombination ist. Leeres
    Topic = nicht „schwach" (nichts eingerichtet, nichts zu warnen).
- `_AlertsSheet`: Vorbelegung bei leerem Topic, Würfel-Button (`casino_outlined`)
  im Suffix, Warnblock über dem Feld (öffentlich lesbar → Zufallsname nehmen),
  Live-Zeile „leicht zu erraten", solange das getippte Topic schwach ist.
- `_AutomationTile.warning`: optionale zweite Untertitel-Zeile in Warnfarbe;
  Health-Alerts-Karte zeigt sie bei aktivem schwachem Topic.
- Tests: 11 neue in `alerts_test.dart` (Format/Alphabet/Kollisionen/Quoting im
  Install-Skript), 4 in `dispatch_test.dart` (Vorbelegung wird auch installiert,
  Würfeln, Live-Markierung, Kartenwarnung).

## Rechtstexte (`docs/privacy.html`, Stand 30.06. → 26.07.2026)

1. **Neuer Abschnitt „Health-Alerts über ntfy"** (DE + EN): wer sendet (der Pi,
   nicht das Handy — die App richtet es aber ein und schickt die Testnachricht),
   was übertragen wird (Topic + Meldungstext: Speicher, Temperatur, SD-Fehler,
   Namen toter Dienste, *Anzahl* Updates; keine Zugangsdaten), Empfänger und
   Zwischenspeicherung bei ntfy.sh (12 h nach eigenen Angaben, IP-Logs zur
   Missbrauchsbegrenzung), **der Hinweis auf öffentlich lesbare Topics**,
   Rechtsgrundlage Art. 6 Abs. 1 lit. b/f und Widerruf (Timer wird entfernt).
2. **Neuer Abschnitt „Berechtigungen der App"**: `INTERNET`, `USE_BIOMETRIC`
   (Android prüft, die App bekommt nur bestätigt/abgebrochen — keine
   biometrischen Daten), `POST_NOTIFICATIONS` (nur damit die Benachrichtigung des
   Vordergrunddienstes angezeigt werden darf — kein Push-Dienst, keine Token,
   kein Firebase), `FOREGROUND_SERVICE(_DATA_SYNC)`.
3. **GitHub-Abruf korrigiert:** zusätzlich `home-assistant/core` — und zwar nur,
   wenn Home Assistant auf dem Pi erkannt wurde (`_reconcileEvcc`).
4. **„Rechtsgrundlage" nachgezogen:** der Satz „außer GitHub keine Daten an
   Dritte" war mit ntfy nicht mehr korrekt.

## Offen (nicht in diesem Release)

- **USt-IdNr.:** läuft über die Steuerkanzlei, vom BZSt noch nicht erteilt. § 5
  DDG verlangt sie, **sobald sie vorliegt** → dann ins `docs/impressum.html`
  (Anbieter-Block) nachtragen. Bis dahin ist das Fehlen korrekt, deshalb wurde
  das Impressum hier **nicht** angefasst (kein neuer Snapshot nötig).
- **Data Safety in der Play Console:** Bewertung + empfohlene Antwort stehen in
  `store/play/listing.md` — Ergebnis: bleibt „No data collected/shared", weil die
  App selbst nicht zu ntfy spricht (SSH → `curl` auf dem Pi, auch beim Test) und
  die Übermittlung nutzer-initiiert an ein selbst gewähltes Ziel geht. Erst
  ändern, wenn die App direkt mit ntfy spricht.
- **Legal-Ablage:** `docs/privacy.html` hat sich geändert → neuer Snapshot unter
  `Pi-Tool\Datenschutz\`. `impressum.html` und `agb.html` sind unverändert.
