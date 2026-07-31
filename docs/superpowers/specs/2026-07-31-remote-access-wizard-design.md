# „Fernzugriff einrichten" — ein Knopf statt einer Schnitzeljagd

Stand: 2026-07-31. Idee von Stefan: nach dem lokalen Verbinden ein Knopf, der
den Fernzugriff einrichtet.

## Ziel

Pi-Tool soll von unterwegs **vollständig** funktionieren — alle Karten, Updates,
Backups —, nicht nur „irgendein Zugang zum Pi". Das entscheidet die Technik:
**Tailscale**, weil es dem Handy eine Route zum Pi gibt, auf der unser SSH läuft.
Raspberry Pi Connect wurde verworfen: Es liefert eine Shell im Browser, aber
keinen Weg, auf dem die App selbst den Pi erreicht.

## Ausgangslage: ~80 % liegt schon im Code

Vorhanden und unverändert nutzbar:

| Baustein | Ort |
|---|---|
| `tailscaleInstallScript` (offizieller Installer, Marker `TAILSCALE_INSTALLED`) | `services/tailscale.dart` |
| `tailscaleUpScript` (detached, druckt Login-URL, bestätigt mit `TS_UP_OK`) | `services/tailscale.dart` |
| `parseTailscaleAuthUrl`, `parseTailscaleIp`, `isTailnetHost` | `services/tailscale.dart` |
| Profilfelder `tailscaleIp` **und** `lanHost` samt Persistenz | `profiles.dart` |
| `_rememberTailscaleIp`, `_rememberLanHost`, `_useTailscaleIp` | `main.dart` |

Fehlt: die **Verkettung** und der ehrliche Abschluss-Beweis. Heute verteilt sich
der Ablauf auf Dienst-Picker → Karte → Browser → ⋮-Menü, also drei Orte und
sechs Schritte, von denen der Nutzer die Reihenfolge kennen muss.

## Entscheidungen

1. **Technik: Tailscale** (siehe Ziel).
2. **Umschalten: automatisch mit Rückfall.** Kein manueller Schalter — der wäre
   genau der Schwachpunkt, den das ⋮-Menü heute schon hat.
3. **Pro-Feature** über `_proGate` + Schloss-Hinweis, wie „Aufräumen". Schläft
   derzeit durch `DormantEntitlement`, ist also für alle frei, aber sauber
   markiert, falls der Pro-Schalter später umgelegt wird.

## Der Knopf

**Sichtbarkeit:** eigene Karte im Verwaltungs-Tab, **nur** solange verbunden UND
`profil.tailscaleIp` leer. Danach verschwindet sie. Nicht ins ⋮-Menü — das ist
voll, und dort verstecken sich die Tailscale-Funktionen heute schon.

**Ablauf** (geführter Dialog mit Fortschritt):

```
1. Tailscale installiert?     aus der Erkennung, kein Extra-Call
2. falls nein: installieren   tailscaleInstallScript
3. tailscale up               -> Login-URL ODER TS_UP_OK (schon angemeldet)
4. Browser öffnen             Nutzer bestätigt einmal mit seinem Konto
5. Tailnet-IP holen + merken  tailscale ip -4 -> profil.tailscaleIp
6. Handy-Seite BEWEISEN       Testverbindung auf die 100.x-Adresse
```

**Schritt 6 ist der Kern.** Tailscale auf dem Pi allein nützt nichts: Das Handy
muss dieselbe Tailnet-Mitgliedschaft haben (Tailscale-App, gleiches Konto). Das
kann die App nicht erledigen — also behauptet sie den Erfolg nicht, sondern
misst ihn. Testverbindung erfolgreich ⇒ „Fernzugriff steht". Sonst: Play-Store-
Link, der Hinweis „mit demselben Konto anmelden" und ein Knopf zum Erneut-Prüfen.
Ohne diesen Schritt hielte sich der Nutzer für fertig und merkte es erst
unterwegs.

**Zustände, die der Wizard abdecken muss:** nicht installiert · installiert aber
abgemeldet · installiert und bereits angemeldet (Schritt 3 liefert dann direkt
`TS_UP_OK`, kein Browser nötig) · `tailscale up` liefert weder URL noch
`TS_UP_OK` ⇒ **klarer Fehler**, niemals „verbunden".

## Automatischer Rückfall beim Verbinden

Neues Profilfeld `lastGoodHost`. Eine **reine Funktion** baut die Reihenfolge:

```dart
List<String> remoteAccessCandidates({
  required String lanHost,
  required String tailscaleIp,
  required String lastGood,
})
```

Der erste Kandidat bekommt einen kurzen Timeout (~4 s, über eine `SshConfig`-
Kopie — das Feld `timeout` existiert bereits), der letzte den vollen. Nach
Erfolg wird `lastGoodHost` fortgeschrieben.

**Ist nur eine Adresse bekannt, bleibt alles exakt wie heute** — niemand ohne
Fernzugriff bezahlt Wartezeit für ein Feature, das er nicht nutzt.

`isTailnetHost` verhindert weiterhin, dass eine 100.x-Adresse je als Heim-Adresse
gemerkt wird.

## Nicht-Ziele

- **Kein Portforwarding, kein DynDNS.** Ein offener SSH-Port ins Internet ist
  genau das, was der Sicherheits-Check der App anprangert — das können wir nicht
  mit der anderen Hand anbieten.
- **Kein Hintergrunddienst** (Invariante, v0.20.0-Lektion).
- **Nichts auf dem Handy installieren oder anmelden.** Kann die App nicht, also
  verspricht sie es nicht.

## Bekannte Kosten

- Tailscale braucht ein Konto (Google/GitHub/Microsoft). Kostenlose Stufe: 100
  Geräte — für die Zielgruppe irrelevant, aber es ist ein fremdes Konto mehr.
- Der Installer ist `curl … | sh` von tailscale.com. Das ist der offizielle Weg
  und im Repo bereits gängige Praxis; als bewusst eingegangenes Risiko notiert.
- Ein Netzwechsel kostet beim ersten Verbinden einen Fehlversuch (~4 s).

## Tests

- `remoteAccessCandidates` rein: beide Adressen bekannt · nur eine · `lastGood`
  leer oder zeigt auf eine Adresse, die es nicht mehr gibt.
- Runner-Test: erster Host schlägt fehl, zweiter klappt ⇒ verbunden **und**
  `lastGoodHost` fortgeschrieben.
- Dispatch-Test durch den ganzen Wizard mit `FakeEvccUpdater` (install → up →
  URL geöffnet → IP im Profil).
- Fehlerfall: weder URL noch `TS_UP_OK` ⇒ Fehlermeldung, kein falscher Erfolg.
- Fall „schon angemeldet": kein Browser, direkt zu Schritt 5.
