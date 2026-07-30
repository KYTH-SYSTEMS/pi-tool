# Play-Upload aus der CI — Einmal-Einrichtung

Ziel: `v*`-Tag → CI lädt den signierten AAB **und** die Store-Texte nach Google
Play (Produktions-Spur, 100 % Rollout). Die Mechanik steht in `ARCHITECTURE.md`
§8; hier nur die Google-Seite, die man **einmal** klickt.

## 1. Dienstkonto in Google Cloud

1. <https://console.cloud.google.com> → Projekt wählen oder erstellen
   (z. B. `pi-tool-publishing`).
2. „APIs und Dienste" → „APIs und Dienste aktivieren" → **Google Play Android
   Developer API** aktivieren.
3. „IAM und Verwaltung" → „Dienstkonten" → **Dienstkonto erstellen**
   (Name z. B. `play-publisher`). GCP-Rollen leer lassen — die eigentlichen
   Rechte kommen aus der Play Console (Schritt 2).
4. Dienstkonto öffnen → Reiter „Schlüssel" → **Schlüssel hinzufügen → JSON** →
   Datei herunterladen. Diese Datei ist ein Veröffentlichungs-Schlüssel:
   **nicht** ins Repo, nicht in Chats, nicht in Logs. (`.gitignore` blockt
   `play-service-account*.json` und `fastlane/*.json` als zweites Netz.)

## 2. Play Console: Zugriff für das Dienstkonto

1. Play Console → **Nutzer und Berechtigungen** → „Neue Nutzer einladen".
2. E-Mail = Adresse des Dienstkontos (`…@….iam.gserviceaccount.com`).
3. App-Zugriff auf **Pi-Tool** beschränken (kein Kontoweit-Zugriff), dann diese
   Berechtigungen setzen:
   - „App-Informationen ansehen (schreibgeschützt)"
   - „App-Präsenz im Play Store verwalten" → für Titel/Beschreibungen/Changelog
   - „Produktionsversionen veröffentlichen, Geräte ausschließen und Play App
     Signing verwenden" → für den AAB in die Produktions-Spur
4. Play Console → Einstellungen → **API-Zugriff**: das Cloud-Projekt aus
   Schritt 1 verknüpfen, falls noch nicht verknüpft.

Neue Rechte brauchen ein paar Minuten (im Extremfall bis 24 h), bis die API sie
sieht — ein `403` direkt nach dem Einladen heißt also nicht zwingend „falsch
konfiguriert".

## 3. GitHub-Secret setzen

```bash
gh secret set PLAY_SERVICE_ACCOUNT_JSON < /pfad/zu/play-service-account.json
```

(alternativ GitHub → Settings → Secrets and variables → Actions). Ohne dieses
Secret bleibt alles wie vorher: GitHub-Release wird gebaut, der Play-Schritt
wird mit einer Warnung übersprungen.

## 4. Trockenlauf — vor dem nächsten echten Tag

```bash
gh workflow run build.yml -f play_dry_run=true
gh run watch "$(gh run list --workflow build.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

Das baut den AAB und lässt die Play-API Bundle **und** Texte prüfen
(`validate_only`), ohne etwas zu veröffentlichen. Grün = Zugangsdaten, Rechte
und Texte passen.

**Wichtig:** `validate_only` prüft auch die Eindeutigkeit des versionCode. Steht
in `pubspec.yaml` noch die bereits veröffentlichte Version, endet der Lauf mit
`Version code <N> has already been used` — das ist **kein** Konfigurationsfehler,
sondern der Beweis, dass Auth und Rechte funktionieren (so verifiziert am
2026-07-30 mit Code 119). Voll grün wird der Trockenlauf erst nach dem
Versions-Bump; genau dann lohnt er sich also: **nach dem Bump, vor dem Tag.**

## 5. Ab dann

`v*`-Tag → GitHub-Release + Play-Upload. Google prüft danach noch (Review), dann
geht die Version an 100 % der Nutzer. Die Release-Regeln (Changelog in beiden
Sprachen, Zeichenlimits) stehen in `CLAUDE.md`.

## Typische Fehler

| Meldung | Ursache |
|---|---|
| `403 The caller does not have permission` | Rechte aus Schritt 2 fehlen oder sind noch nicht propagiert; Cloud-Projekt nicht verknüpft |
| `Version code … has already been used` | versionCode in `pubspec.yaml` nicht gebumpt |
| `Package not found: systems.kyth.pitool` | Dienstkonto hat keinen Zugriff auf **diese** App |
| Text-Limit-Fehler | zeigt die Vorprüfung „Check store texts against Play limits" schon vor dem Bauen, mit Datei und Zeichenzahl |
