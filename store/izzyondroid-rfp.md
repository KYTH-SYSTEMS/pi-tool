# IzzyOnDroid — Request for Packaging (ERLEDIGT/ABGELEHNT — nur Historie)

> ⛔ **Dieser Kanal ist zu.** IzzyOnDroid hat die Aufnahme am **2026-07-12** unter
> seiner KI-Policy abgelehnt („the level of LLM assistance used"), Details in
> `launch-kit.md` §7. Das Folgende ist **nicht** mehr umzusetzen — es steht nur
> als Referenz hier. Nicht erneut einreichen.

**HRB-unabhängig:** IzzyOnDroid zieht die signierte APK direkt aus den GitHub-Releases.
Kein Entwicklerkonto, keine D-U-N-S, kein Handelsregister nötig.

## So einstellen (Stand 2026: Prozess von GitLab → **Codeberg** umgezogen!)
> Der alte GitLab-Tracker (`gitlab.com/IzzyOnDroid/repo`) ist **archiviert** — dort NICHT mehr
> einreichen. Aufnahme-Anfragen laufen jetzt über Codeberg.

1. **Codeberg-Account** anlegen (kostenlos): https://codeberg.org
2. Kurz die **App Inclusion Policy** überfliegen: https://izzyondroid.org/docs/ → „App Inclusion Policy".
   (Wir erfüllen sie — siehe „Voraussetzungen" unten.)
3. **Neues Issue** im Tracker öffnen: **https://codeberg.org/IzzyOnDroid/repodata/issues** → „New Issue"
   → falls eine Inclusion-/RFP-Vorlage angeboten wird, diese wählen.
4. Untenstehenden Text einfügen (bzw. damit die Vorlagenfelder ausfüllen) und abschicken.

## Voraussetzungen — bei uns alle erfüllt ✅
- FOSS-Lizenz: **MIT** (`LICENSE` im Repo)
- Signierte Release-APK in **GitHub-Releases** (`app-release.apk`, pro `v*`-Tag)
- **Keine** Tracker / proprietären Libs (kein Firebase/GMS/Ads/Analytics) → exodus-clean
- fastlane-Metadaten im Repo (Titel, Beschreibung, Changelog, Icon, Feature-Grafik)

## Text zum Einfügen
```
### Request for Packaging

**App name:** Pi-Tool (unofficial)
**Package ID:** systems.kyth.pitool
**Source code:** https://github.com/profex1337/evcc-pi-tool
**License:** MIT
**Upstream releases:** GitHub Releases, signed APK asset `app-release.apk` per `v*` tag
**Description:** Manage a Raspberry Pi over SSH — detect, install and update evcc,
Pi-hole, Home Assistant, Grafana, InfluxDB and Mosquitto, plus the whole system;
status/health, backups, console, cleanup, multiple profiles. Unofficial, not
affiliated with evcc or Pi-hole.

**AntiFeatures:** none (no tracking, no ads, no proprietary dependencies).
**Notes:** Fastlane metadata is present under
`fastlane/metadata/android/{en-US,de-DE}/`. The app has no backend; SSH
credentials stay on-device (Android Keystore) and are used only to reach the
user's own Pi.
```

## Danach
- IzzyOnDroid prüft (u. a. exodus-Scan) und nimmt die App auf; Updates zieht er
  künftig automatisch aus neuen GitHub-Releases (per `v*`-Tag).
- Beim ersten Einpflegen wird euer **APK-Signaturschlüssel gepinnt** — künftige
  Updates müssen mit **demselben** Keystore signiert sein (bei uns automatisch über
  den CI-Keystore — also nie verlieren/wechseln).
- Nutzer fügen einfach das IzzyOnDroid-Repo in ihrem F-Droid-Client hinzu und
  finden „Pi-Tool".
