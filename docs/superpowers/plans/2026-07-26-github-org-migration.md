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
| 1 | ✅ **2026-07-30 erledigt** — **DNS:** `CNAME pi-tool.kyth.systems → profex1337.github.io`, in Cloudflare **DNS-only (graue Wolke)**; proxied kann GitHub kein Zertifikat ausstellen | **Stefan** |
| 2 | ✅ **2026-07-30 erledigt** — Custom domain gesetzt (`docs/CNAME` committet, Commit `9b1541e`), Zertifikat `approved`, `https_enforced: true` | ich (`gh api`) |
| 3 | ✅ **2026-07-30 erledigt** — `privacy.html`, `impressum.html`, `agb.html` + Landing liefern je `200` über HTTPS; die alte `profex1337.github.io`-URL antwortet mit `301` auf die neue Domain | ich |
| 4 | ✅ **2026-07-30 erledigt** — **App-Release v0.63.4+118** mit den neuen URLs (`kPrivacyUrl`/`kImpressumUrl`/`kAgbUrl`) + README/`store/`/ARCHITECTURE/fastlane-Changelog `118.txt` | ich |
| 5 | ✅ **2026-07-31 erledigt** — Play Console: Datenschutz-URL + Website-URL auf `pi-tool.kyth.systems`; jüngstes AAB (v0.63.5+119) ausgerollt | **Stefan** |
| 6 | ✅ **2026-07-31 erledigt** — Transfer nach `KYTH-SYSTEMS` + Rename → **`KYTH-SYSTEMS/pi-tool`**, öffentlich geblieben | ich (`gh api`) |
| 7 | ✅ **2026-07-31 erledigt** — Nacharbeiten (siehe unten) | ich |
| 8 | ✅ **2026-07-31 erledigt — aber anders als geplant:** kein Stub-Repo, sondern die **User-Site** `profex1337/profex1337.github.io` (Begründung unten) | ich |

**Zur Umbenennung** (Stefans Entscheidung 2026-07-19: die App heißt „Pi-Tool", „evcc"
nur noch nominativ): sie vergrößert den Radius — jeder `evcc-pi-tool`-String in Code und
Docs ändert sich mit (`kReleasesUrl`, `UpdateChecker.repo`, README/`docs/`/`store/`,
`LICENSE`, `test/update_check_test.dart`). Genau deshalb gehören die Rechts-URLs vorher
auf die eigene Domain: die ist gegen Transfer **und** Umbenennung immun. Der interne
Dart-Package-Name bleibt `evcc_updater` (nicht nutzersichtbar).

**Zu Schritt 8 — der Plan war falsch, die Ausführung weicht bewusst ab.** Alle bis
v0.63.3 installierten Versionen haben die `profex1337.github.io`-URLs fest eingebacken.
Der Plan sah dafür ein **Stub-Repo `evcc-pi-tool`** vor. Genau das hätte aber GitHubs
Repo-Redirect `profex1337/evcc-pi-tool → KYTH-SYSTEMS/pi-tool` sofort gekillt — und
damit den **In-App-Update-Check jeder bereits installierten Version**, die den Pfad
`api.github.com/repos/profex1337/evcc-pi-tool/releases/latest` abfragt (nachgemessen:
antwortet mit `301`). Das Stub-Repo hätte also die Rechts-Links gerettet und dafür den
einzigen Weg gekappt, auf dem Alt-Installationen sich selbst auf eine Version mit
korrekten Links heben.

Stattdessen liegen die Weiterleitungen in der **User-Site**
`profex1337/profex1337.github.io` unter dem Pfad `/evcc-pi-tool/`. GitHub bedient
User-Site-Pfade nur, solange **kein** Projekt-Repo dieses Namens existiert — also genau
dann, wenn der Repo-Redirect intakt bleibt. Beides funktioniert damit gleichzeitig
(verifiziert: alte Rechts-URLs `200`, API-Redirect `301`, Custom Domain `200`).

**Daraus die Dauerregel:** unter `profex1337` **nie** ein Repo `evcc-pi-tool` anlegen.

Schritt 1 und 2 kosten die alten URLs nichts: die alte
`profex1337.github.io`-Adresse bleibt bis zum Transfer erreichbar, danach
übernimmt die Custom Domain. Nutzer alter App-Versionen laufen also nie ins
Leere — genau das ist der Zweck der Reihenfolge.

## Nacharbeiten nach dem Transfer (Schritt 7)

- ✅ **Repo-Secrets: haben den Transfer entgegen der Annahme überlebt** — alle
  fünf (`KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`,
  `PLAY_SERVICE_ACCOUNT_JSON`) sind in `KYTH-SYSTEMS/pi-tool` unverändert
  vorhanden, inklusive Zeitstempel. Nichts neu zu setzen. (Repo-Secrets wandern
  mit; nur Environment-/Org-Secrets tun es nicht.)
- ✅ **Actions:** in der Org aktiv (`enabled: true`, `allowed_actions: all`).
  Die Repo-Voreinstellung für `GITHUB_TOKEN` steht zwar auf `read`, aber
  `build.yml` fordert `permissions: contents: write` explizit an — das sticht
  die Voreinstellung, Releases funktionieren.
- ✅ **Lokales Remote** umgestellt:
  `git remote set-url origin https://github.com/KYTH-SYSTEMS/pi-tool.git`
- ✅ **`gh` CLI:** `profex1337` ist `admin` in der Org — Transfer, Rename und
  Secrets-Zugriff liefen ohne Zusatzrechte.
- ✅ **Code-Referenzen auf den alten Owner** nachgezogen:
  - `lib/src/update_check.dart` → `UpdateChecker(owner: 'KYTH-SYSTEMS',
    repo: 'pi-tool')`; `lib/main.dart` → `kReleasesUrl`.
  - `docs/*.html` (Footer-Links), `store/community-posts.md`,
    `store/izzyondroid-rfp.md`, `test/update_check_test.dart` (Fixtures).
  - CI-Artefakte in `build.yml` mitumbenannt: `pi-tool-apk` /
    `pi-tool-playstore-aab` (+ README und `store/play/listing.md`). **Ältere
    Runs behalten die alten Namen `evcc-pi-tool-*`** — beim Suchen alter AABs
    daran denken.
  - `LICENSE` bleibt bewusst bei „Stefan Grasse (profex1337)": der GitHub-Handle
    hat sich nicht geändert, nur der Repo-Eigentümer. Den Rechteinhaber auf die
    UG umzuschreiben wäre eine juristische Entscheidung, keine Umzugs-Nacharbeit.
- ✅ **Pages geprüft:** Custom Domain ist mitgewandert (`cname:
  pi-tool.kyth.systems`, Zertifikat `approved`, `https_enforced: true`), alle
  vier Seiten liefern `200`.
- ⚠️ **Offen (Cloudflare, nur Stefan):** der DNS-CNAME zeigt weiterhin auf
  `profex1337.github.io` und sollte auf `kyth-systems.github.io` wechseln.
  Funktional derzeit unkritisch — alle `*.github.io` zeigen auf dieselben
  Pages-IPs, die Zuordnung läuft über den Host-Header und den `docs/CNAME` des
  neuen Repos. Sauber ist es trotzdem nicht, und seit es unter `profex1337`
  eine echte User-Site gibt, zeigt das Target auf eine Site, die die Domain
  gar nicht beansprucht.
- **Alte APK-Downloadlinks** aus GitHub-Releases werden von GitHub
  weitergeleitet — kein Handlungsbedarf.

## Was GitHub von allein richtig macht

Nicht überplanen — folgendes ist durch GitHub-Weiterleitungen abgedeckt und braucht
keine Maßnahme: `git remote`/clone, Releases samt APK-Downloadlinks, Issues/PRs/Stars/
Tags und der In-App-Update-Check (die GitHub-API folgt dem Repo-Redirect; `_defaultGetJson`
folgt Redirects). Das eine, was NICHT mitzieht, ist Pages — und genau daran hängen die
Rechts-URLs.

## Wenn ohne eigene Domain umgezogen werden soll

Machbar, aber dann gilt: **Play-Console-URL im selben Zug ändern** und die
Weiterleitung von `profex1337.github.io/evcc-pi-tool/` nach dem Transfer
tatsächlich testen. Und: unter `profex1337` **nie wieder** ein Repo namens
`evcc-pi-tool` anlegen — das killt die Weiterleitung sofort. Nutzer alter
App-Versionen behalten in diesem Fall dauerhaft tote Rechts-Links; das ist der
Grund, warum die Domain-Variante empfohlen ist.

## Status

**Abgeschlossen am 2026-07-31.** Das Repo lebt als `KYTH-SYSTEMS/pi-tool`.
Nachgemessener Endzustand:

| Prüfung | Ergebnis |
|---|---|
| `pi-tool.kyth.systems/{privacy,impressum,agb,index}.html` | `200` |
| `profex1337.github.io/evcc-pi-tool/*.html` (Alt-Installationen ≤ v0.63.3) | `200` (Weiterleitung über die User-Site) |
| `api.github.com/repos/profex1337/evcc-pi-tool/releases/latest` (Update-Check ≤ v0.63.5) | `301` → neues Repo |
| Repo-Sichtbarkeit / Secrets / Actions | public / alle 5 vorhanden / aktiv |

Einzige Restaufgabe: der Cloudflare-CNAME (siehe ⚠️ oben) — kosmetisch.
