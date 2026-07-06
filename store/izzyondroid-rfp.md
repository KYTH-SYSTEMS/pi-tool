# IzzyOnDroid — Request for Packaging (fertig zum Einstellen)

**HRB-unabhängig:** IzzyOnDroid zieht die signierte APK direkt aus den GitHub-Releases.
Kein Entwicklerkonto, keine D-U-N-S, kein Handelsregister nötig.

## So einstellen
1. GitLab-Account anlegen (falls nicht vorhanden): https://gitlab.com
2. Neues Issue im IzzyOnDroid-Tracker: **https://gitlab.com/IzzyOnDroid/repo/-/issues/new**
   → Vorlage „Request for Packaging (RFP)" wählen.
3. Untenstehenden Text einfügen und abschicken.

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
  künftig automatisch aus neuen GitHub-Releases.
- Nutzer fügen einfach das IzzyOnDroid-Repo in ihrem F-Droid-Client hinzu und
  finden „Pi-Tool".
