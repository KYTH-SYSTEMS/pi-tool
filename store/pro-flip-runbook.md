# Runbook: den Pro-Kauf scharf schalten

Stand: 2026-07-26. **Status: bewusst NICHT scharf.** Entscheidung Stefan
(2026-07-26): die App wird erst eine Weile kostenlos angeboten. Dieses Dokument
beschreibt, was zu tun ist, wenn der Kauf später live gehen soll — und was
solange bewusst **nicht** getan wird.

## Warum das Plugin heute NICHT eingebaut wird

`in_app_purchase` ist ein natives Plugin und registriert sich beim App-Start,
also **vor** Dart `main()`. Genau dieser Pfad hat in v0.20.0 einen nativen
Startabsturz verursacht, den kein `try/catch` abfangen konnte. Die App ist jetzt
live bei echten Nutzern. Ein Plugin einzubauen, das monatelang schläft, bringt
null Nutzen und trägt genau dieses Risiko — also kommt es erst in dem Release
mit, in dem der Kauf auch wirklich scharf geht, mit lokalem Release-Build und
Test auf einem echten Gerät.

## Was in der Gratis-Phase trotzdem laufen muss (läuft bereits)

Der **Early-Adopter-Marker** aus v0.61.0. Er schreibt bei jeder Installation
einmalig `AppConfig.firstSeenVersionCode`:

- frische Installation → aktueller versionCode
- Nutzer, der die App schon vorher hatte → Sentinel `0` (`kPreMarkerFirstSeen`)

Ohne diesen Marker gäbe es später keine Möglichkeit mehr festzustellen, wer die
App in der Gratis-Zeit hatte. Logik: `lib/src/early_adopter.dart`, gestempelt in
`main.dart` `_stampFirstSeenMarker()` (best-effort, off dem Boot-Pfad).
Abgesichert durch `test/early_adopter_test.dart` (reine Logik) **und** zwei
Widget-Tests in `test/widget_test.dart`, die beweisen, dass der Marker
tatsächlich bis in den Store durchgeschrieben wird — die Verdrahtung, nicht nur
die Funktion. Diese Tests nicht löschen: sie sind die einzige Absicherung eines
Versprechens, dessen Bruch man erst Monate später merken würde.

## Ablauf beim Scharfschalten

### 1. Vorher entscheiden

- **Paywall-versionCode festlegen.** Alle mit
  `firstSeenVersionCode < PAYWALL_VERSIONCODE` behalten Pro gratis
  (`isGrandfathered`). Das ist der versionCode **des Paywall-Releases selbst**.
- **IARC-Fragebogen prüfen.** Der Fragebogen wurde für eine App **ohne**
  digitale Käufe beantwortet. Kommt ein In-App-Kauf dazu, kann sich die Antwort
  zu „digitale Käufe" ändern → dann ist laut IARC-Terms (Punkt 5) ein **neuer
  Fragebogen** Pflicht. Global Rating ID für den Bestandsfall:
  `a9a55def-8a3d-8414-84d0-3f6b21e9cff5`.
- **Data Safety / Play-Angaben** auf den Kauf hin durchsehen.

### 2. Play Console (nur Stefan)

- In-App-Produkt anlegen: einmaliger Kauf, ~5 €, Produkt-ID festlegen
  (Vorschlag: `pro_unlock`) — die ID ist danach **permanent**.
- Produkt aktivieren, Preise für alle Zielländer prüfen.
- Lizenz-Tester hinterlegen, damit der Kauf ohne echte Zahlung testbar ist.

### 3. Code (ein Release)

- `in_app_purchase` als Dependency aufnehmen; **lokalen Release-Build bauen und
  auf einem echten Gerät starten**, bevor irgendetwas weiter passiert (AGP-9-/
  Kotlin-Kompatibilität, siehe die `file_picker`-Erfahrung).
- Neue Klasse hinter dem bestehenden Seam `EntitlementService`
  (`lib/src/entitlement.dart`) — `isPro()` / `buyPro()` / `restore()`.
  `DormantEntitlement` **nicht löschen**: sie bleibt die Test-Implementierung
  und der Rückfallweg.
- Grandfathering verdrahten: `isPro()` liefert true, wenn der Kauf vorliegt
  **oder** `isGrandfathered(firstSeenVersionCode, paywallVersionCode: …)`.
- Kauf-UI: `_proGate` zeigt heute nur den Schloss-Hinweis — dort den echten
  Kauf-Flow plus „Käufe wiederherstellen" ergänzen.
- Der Demo-Modus schaltet Pro weiterhin frei (`_unlocked = _isPro || _demoMode`)
  — das ist bereits zukunftssicher gebaut.
- Rechtstexte stimmen schon: `docs/agb.html` § 2/§ 3 beschreiben den Kauf über
  Google Play (Merchant of Record: Google Commerce Ltd) inklusive Widerruf;
  `docs/privacy.html` hat den Abschnitt zum Pro-Kauf. Nur prüfen, nicht neu
  schreiben.

### 4. Nicht vergessen

- Die **Sideload-APK unterstützt den Kauf nicht** (steht so in den AGB § 2). Was
  passiert dort nach dem Flip? Heute: alles frei. Nach dem Flip wäre Pro dort
  unkaufbar — entweder Sideload-Builds dauerhaft grandfathern oder im UI klar
  sagen, dass Pro nur über Play geht.
- Eine **Neuinstallation nach dem Flip verliert** den Grandfather-Status (der
  Marker ist rein lokal, kein Backend). Bewusst akzeptiert — im Zweifel über
  Support lösen.
- **Die Play-Erklärung „App-Zugriff" muss beim Flip neu bewertet werden.** Heute
  steht sie korrekt auf **„Nein"** (nichts ist zugangsbeschränkt: Pro schläft,
  alles ist frei, und der Demo-Einstieg zeigt Prüfern die ganze App ohne
  Zugangsdaten). Sobald Funktionen hinter einem Kauf liegen, greift Googles
  Kriterium „Zahlungen … und/oder Zugriffsstufen" — dann entweder auf **„Ja"**
  umstellen und dem Prüfer einen Weg geben (Lizenztester-Konto oder Promo-Code),
  **oder** sicherstellen, dass der Demo-Modus weiterhin *alle* Pro-Funktionen
  ohne Kauf zeigt (`_unlocked = _isPro || _demoMode` tut das heute) und die
  Antwort begründet bei „Nein" belassen. Nicht stillschweigend übergehen — genau
  diese Erklärung hat v0.60.0 die Ablehnung eingebracht.

## Quellen im Code

| Was | Wo |
|---|---|
| Seam + Gating-Logik | `lib/src/entitlement.dart` |
| Grandfathering-Logik | `lib/src/early_adopter.dart` |
| Marker-Stempel | `lib/main.dart` `_stampFirstSeenMarker()` |
| Gate im UI | `lib/main.dart` `_proGate`, `_CardAction.pro`, `_AutomationTile` |
| Design-Spec Marker | `docs/superpowers/specs/2026-07-16-early-adopter-marker-design.md` |
