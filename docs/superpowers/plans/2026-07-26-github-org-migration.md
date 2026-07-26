# Runbook: Repo-Umzug zu `KYTH-SYSTEMS`

Stand: 2026-07-26. Ausgangslage: die App ist **live in Google Play**
(`systems.kyth.pitool`, v0.62.0). Das ändert das Risiko dieses Umzugs
grundlegend — vor dem Launch war er folgenlos, jetzt hängt eine
Play-Compliance-Anforderung daran.

## Das eine echte Problem

Der Umzug selbst ist trivial (ein Klick). Gefährlich ist **eine einzige URL**:

```
https://profex1337.github.io/evcc-pi-tool/privacy.html
```

Diese Adresse ist

1. die in der **Play Console hinterlegte Datenschutz-URL** — Play verlangt, dass
   sie erreichbar ist. Eine tote Datenschutz-URL ist ein Policy-Verstoß und kann
   zur Entfernung der App führen;
2. **fest in der App verdrahtet** (`lib/main.dart`: `kPrivacyUrl`,
   `kImpressumUrl`, `kAgbUrl`) — und zwar in **jeder bereits installierten
   Version**. Nutzer, die nie updaten, behalten die alte URL für immer;
3. in `README.md`, `docs/*.html` und den fastlane-Metadaten referenziert.

GitHub legt beim Transfer zwar Weiterleitungen für **Repository**-URLs an, aber
für **Pages** ist das nicht verlässlich: `profex1337.github.io` bleibt Stefans
persönliche Nutzer-Domain, und die Weiterleitung fällt weg, sobald dort je wieder
ein Repo gleichen Namens existiert. Auf diese Weiterleitung darf eine
Rechts-URL nicht angewiesen sein.

## Empfehlung: erst eigene Domain, dann umziehen

Statt die Rechts-URLs von einem GitHub-Benutzernamen abhängig zu lassen, hängt
man sie **einmalig an eine eigene Domain** — dann ist dieser Umzug (und jeder
künftige) für die Nutzer folgenlos. KYTH besitzt `kyth.systems`, also:

**`https://pi-tool.kyth.systems/privacy.html`**

Danach ist der Eigentümer des Repos für die URL egal.

### Reihenfolge (wichtig — nicht vertauschen)

| # | Schritt | Wer |
|---|---------|-----|
| 1 | **DNS:** `CNAME pi-tool.kyth.systems → profex1337.github.io` anlegen | **Stefan** |
| 2 | In den Repo-Settings → Pages die **Custom domain** `pi-tool.kyth.systems` eintragen (legt die Datei `docs/CNAME` an), „Enforce HTTPS" aktivieren, bis das Zertifikat steht | **Stefan** (oder ich per `gh api`, sobald DNS steht) |
| 3 | Prüfen: alle drei Seiten (`privacy.html`, `impressum.html`, `agb.html`) über die neue Domain erreichbar, HTTPS gültig | ich |
| 4 | **App-Release** mit den neuen URLs (`kPrivacyUrl`/`kImpressumUrl`/`kAgbUrl`) + README/`docs/`/fastlane nachziehen | ich |
| 5 | In der **Play Console** die Datenschutz-URL auf die neue Domain umstellen | **Stefan** |
| 6 | Erst **jetzt** die Organisation `KYTH-SYSTEMS` anlegen und das Repo transferieren | **Stefan** |
| 7 | Nacharbeiten (siehe unten) | ich |

Schritt 1 und 2 kosten die alten URLs nichts: die alte
`profex1337.github.io`-Adresse bleibt bis zum Transfer erreichbar, danach
übernimmt die Custom Domain. Nutzer alter App-Versionen laufen also nie ins
Leere — genau das ist der Zweck der Reihenfolge.

## Nacharbeiten nach dem Transfer (Schritt 7)

- **Repo-Secrets werden NICHT mit übertragen.** In `KYTH-SYSTEMS/evcc-pi-tool`
  neu setzen, sonst schlägt der nächste signierte Release-Build fehl:
  `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`
  (Inhalte siehe Keystore-Ablage — **nicht** im Repo).
- **Actions** in der neuen Org freischalten (Org-Policy kann Actions
  standardmäßig blockieren) und prüfen, dass `GITHUB_TOKEN` Release-Rechte hat.
- **Lokales Remote** umstellen:
  `git remote set-url origin https://github.com/KYTH-SYSTEMS/evcc-pi-tool.git`
- **`gh` CLI:** `profex1337` braucht Owner-/Admin-Rechte in der Org, sonst
  scheitern `gh secret set` / `gh release`.
- **Code-Referenzen auf den alten Owner** nachziehen:
  - `lib/src/update_check.dart` → `UpdateChecker(owner: 'profex1337', …)`
    (Default-Parameter). Der GitHub-API-Redirect nach einem Transfer fängt das
    zwar ab — `_defaultGetJson` folgt Redirects —, aber verlassen sollte man
    sich darauf nicht.
  - `lib/main.dart` → `kReleasesUrl`.
  - `README.md` (Badges/Links), `docs/index.html`, `store/*`, fastlane-Metadaten.
- **Pages neu prüfen:** nach dem Transfer muss die Custom Domain in den
  Settings des NEUEN Repos noch stehen (GitHub trägt sie meist mit, aber
  kontrollieren) — und der DNS-CNAME zeigt weiterhin auf
  `profex1337.github.io`; nach dem Transfer sollte er auf
  `kyth-systems.github.io` geändert werden.
- **Alte APK-Downloadlinks** aus GitHub-Releases werden von GitHub
  weitergeleitet — kein Handlungsbedarf.

## Wenn ohne eigene Domain umgezogen werden soll

Machbar, aber dann gilt: **Play-Console-URL im selben Zug ändern** und die
Weiterleitung von `profex1337.github.io/evcc-pi-tool/` nach dem Transfer
tatsächlich testen. Und: unter `profex1337` **nie wieder** ein Repo namens
`evcc-pi-tool` anlegen — das killt die Weiterleitung sofort. Nutzer alter
App-Versionen behalten in diesem Fall dauerhaft tote Rechts-Links; das ist der
Grund, warum die Domain-Variante empfohlen ist.

## Status

Offen — wartet auf Stefans Entscheidung (eigene Domain ja/nein) und auf die
Schritte, die Konto-/DNS-Zugriff brauchen. Nichts davon ist dringend: der
Umzug ist Kosmetik/Ordnung, kein Blocker für irgendetwas.
