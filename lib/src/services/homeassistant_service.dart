/// Home Assistant service. HA runs here as a Docker **container** — the only
/// flavour you can add to an already-busy multi-service Pi over SSH (HA OS and
/// HA Supervised would take over the whole box). Command strings + pure parsers
/// live here; the SSH orchestration is in evcc_updater.dart. See
/// design/2026-06-30-multi-service.md.
library;

import 'dart:convert';

import '../commands.dart' show shSingleQuote;

/// Official container image (rolling "stable" channel).
const String homeAssistantImage =
    'ghcr.io/home-assistant/home-assistant:stable';

/// Web UI / onboarding port.
const int homeAssistantPort = 8123;

/// Conventional container name the install script creates.
const String homeAssistantContainerName = 'homeassistant';

/// Host directory the install bind-mounts to `/config`: configuration.yaml,
/// .storage, the recorder database and HA's own UI backups.
const String homeAssistantConfigDir = '/opt/homeassistant/config';

/// Last line of [buildHomeAssistantUninstallScript], printed only on success.
const String homeAssistantRemovedMarker = 'HA_REMOVED_OK';

/// A detected Home Assistant Docker container.
class HomeAssistantContainer {
  final String name;
  final String image;
  const HomeAssistantContainer({required this.name, required this.image});

  /// The image tag (e.g. "stable", "2024.6"), or the full image when untagged.
  String get version {
    if (image.contains('@')) return 'digest-pinned'; // …@sha256:<hex>
    final i = image.lastIndexOf(':');
    if (i < 0) return image;
    final tag = image.substring(i + 1);
    // A '/' after the last ':' means it was a registry port, not a tag.
    return tag.contains('/') ? image : tag;
  }
}

/// The Home Assistant **core** image, written so Dart's RegExp and `grep -E`
/// read it the same way: the official `home-assistant/home-assistant` (ghcr.io
/// or Docker Hub `homeassistant/…`), its machine-specific builds
/// (`…/raspberrypi4-64-homeassistant`) and `linuxserver/homeassistant`, each
/// ending in a tag, a digest or nothing. Deliberately NOT the companions that
/// merely carry the name — the Matter Server
/// (`home-assistant-libs/python-matter-server`), Matter Hub, the Supervisor
/// and add-on images: they are not HA, so they must neither show up as the HA
/// card nor block its uninstall or fail its verification. Callers anchor it at
/// the start of a repository path (after a registry prefix). Contains no `'`,
/// so it can sit inside single quotes in the shell.
const String _haCoreImageRe =
    r'(home-?assistant/([a-z0-9_.-]+-)?home-?assistant'
    r'|linuxserver/homeassistant)(:|@|$)';

final _haImage = RegExp('(^|/)$_haCoreImageRe', caseSensitive: false);

/// [parseHomeAssistant]'s test as an ERE over whole
/// `docker ps --format '{{.Names}}|{{.Image}}'` lines, for `grep -iE`: the core
/// image or a conventional name. Case-insensitive there, so a superset of the
/// Dart check (which compares names exactly) — never less.
const String _haShellRe = '^[^|]*[|]([^|]*/)?$_haCoreImageRe'
    '|^(homeassistant|hass|home-assistant)[|]';

/// The `/config` bind-mount source directory from a Home Assistant
/// `docker inspect` (JSON array or bare object). Null when not found.
String? homeAssistantConfigPath(String inspectJson) {
  try {
    final data = jsonDecode(inspectJson);
    final obj = data is List ? (data.isEmpty ? null : data.first) : data;
    if (obj is! Map) return null;
    final mounts = obj['Mounts'];
    if (mounts is List) {
      for (final m in mounts) {
        if (m is Map && m['Destination'] == '/config') {
          final src = m['Source'];
          if (src is String && src.isNotEmpty) return src;
        }
      }
    }
  } catch (_) {
    // malformed inspect → treat as unknown
  }
  return null;
}

/// Root/bash script (sudo shell) that tars the HA config dir [configPath] into
/// the backup dir. Prints `BACKUP_OK <path>` on success.
String buildHomeAssistantBackupScript(String configPath) {
  final src = shSingleQuote(configPath);
  // HA keeps running during the backup, so its DB/.storage files change while
  // tar reads them → GNU tar exits 1 ("file changed as we read it"). That is a
  // WARNING, not a failure (the archive is still written), so exit 1 must not
  // be treated as an error; only exit >1 is a real failure.
  return '''
set -e
mkdir -p /var/backups/pi-tool
chmod 0755 /var/backups/pi-tool 2>/dev/null || true
if [ ! -d $src ]; then echo "BACKUP_FAIL"; exit 1; fi
out="/var/backups/pi-tool/homeassistant-backup-\$(date +%Y%m%d-%H%M%S).tar.gz"
set +e
tar --warning=no-file-changed -czf "\$out" -C $src .
rc=\$?
set -e
if [ "\$rc" -gt 1 ]; then echo "BACKUP_FAIL"; rm -f "\$out"; exit 1; fi
chmod 0644 "\$out" 2>/dev/null || true
ls -1t /var/backups/pi-tool/homeassistant-backup-* 2>/dev/null | tail -n +6 | xargs -r rm -f -- || true
echo "BACKUP_OK \$out"
''';
}

/// Root/bash script (sudo shell) that restores a HA config backup: stop the
/// container, extract the tar into [configPath], start it again. The restart is
/// in a `trap`, so even a failing tar can't leave Home Assistant stopped.
/// Extracts OVER the existing config (no wipe — a wipe on a bad archive would
/// be worse than leftover files).
String buildHomeAssistantRestoreScript({
  required String archivePath,
  required String configPath,
  required String containerName,
}) {
  final a = shSingleQuote(archivePath);
  final c = shSingleQuote(configPath);
  final n = shSingleQuote(containerName);
  // The trap guarantees the container is brought back up if the tar aborts
  // under `set -e` (script exits non-zero, no RESTORE_OK → surfaced). On the
  // happy path we clear the trap and start VISIBLY, then verify the container
  // is actually running before RESTORE_OK — a swallowed start failure would
  // otherwise leave HA down while we report success (it runs with
  // --restart=unless-stopped, so a manual stop persists across reboots).
  return '''
set -e
if [ ! -f $a ]; then echo "RESTORE_FAIL_MISSING"; exit 1; fi
if [ ! -d $c ]; then echo "RESTORE_FAIL_NOCONF"; exit 1; fi
docker stop $n
trap "docker start $n >/dev/null 2>&1 || true" EXIT
tar -xzf $a -C $c
trap - EXIT
docker start $n
sleep 2
# State.Running stays true while an unless-stopped container crash-loops; a
# manual start resets RestartCount, so only 'running|0' is a clean start.
st=\$(docker inspect -f '{{.State.Status}}|{{.RestartCount}}' $n 2>/dev/null || true)
if [ "\$st" != 'running|0' ]; then echo "RESTORE_FAIL_START"; exit 1; fi
echo "RESTORE_OK"
''';
}

/// No-sudo one-liner (for the detection batch) that finds the running HA
/// container and prints its REAL version from /config/.HA_VERSION — the image
/// tag alone (often "stable") isn't a comparable version. Empty when HA isn't
/// running or docker needs sudo (then currency simply stays unknown). Picks the
/// container the way [parseHomeAssistant] does, so a Matter Server listed
/// first can't hide the version.
const String haVersionProbe =
    "hac=\$(docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | "
    "grep -iE '$_haShellRe' | head -n1 | cut -d'|' -f1); "
    '[ -n "\$hac" ] && docker exec "\$hac" cat /config/.HA_VERSION 2>/dev/null '
    '|| true';

/// The HA version (e.g. "2026.6.3") from [haVersionProbe] output, or null.
String? parseHaVersion(String out) {
  final m = RegExp(r'\d{4}\.\d+(?:\.\d+)?').firstMatch(out.trim());
  return m?.group(0);
}

/// Finds the Home Assistant container in
/// `docker ps --format '{{.Names}}|{{.Image}}'` output. Matches by the core
/// image (see [_haCoreImageRe]; companions such as the Matter Server are
/// skipped) or by a conventional container name. Returns null when no HA
/// container is running.
HomeAssistantContainer? parseHomeAssistant(String dockerPs) {
  for (final line in dockerPs.split('\n')) {
    final t = line.trim();
    if (t.isEmpty || !t.contains('|')) continue;
    final parts = t.split('|');
    final name = parts[0].trim();
    final image = parts.length > 1 ? parts[1].trim() : '';
    if (image.isEmpty) continue;
    final isHa = _haImage.hasMatch(image) ||
        name == 'homeassistant' ||
        name == 'hass' ||
        name == 'home-assistant';
    if (isHa) return HomeAssistantContainer(name: name, image: image);
  }
  return null;
}

/// Root/bash script for an unattended Home Assistant **Container** install (run
/// via the sudo shell). Installs Docker via the official convenience script if
/// it is missing, then starts the official image with the recommended flags
/// (host network, privileged for hardware, config bind mount, dbus). Idempotent:
/// a pre-existing `homeassistant` container is left untouched. Experimental —
/// the user finishes onboarding in the browser on port 8123.
String buildHomeAssistantInstallScript() {
  return r'''
set -e
export DEBIAN_FRONTEND=noninteractive
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker nicht gefunden - installiere Docker (get.docker.com) ..."
  setup=$(mktemp)
  curl -fsSL https://get.docker.com -o "$setup"
  sh "$setup"
  rm -f "$setup"
fi
mkdir -p /opt/homeassistant/config
if docker ps -a --format '{{.Names}}' | grep -qx homeassistant; then
  if [ "$(docker inspect -f '{{.State.Running}}' homeassistant 2>/dev/null)" = "true" ]; then
    echo "Container 'homeassistant' laeuft bereits - nichts zu tun."
  else
    echo "Container 'homeassistant' existiert (gestoppt) - starte ihn."
    docker start homeassistant
  fi
  exit 0
fi
docker run -d \
  --name homeassistant \
  --restart=unless-stopped \
  --privileged \
  -e TZ=Europe/Berlin \
  -v /opt/homeassistant/config:/config \
  -v /run/dbus:/run/dbus:ro \
  --network=host \
  ghcr.io/home-assistant/home-assistant:stable
echo "Home Assistant gestartet. Einrichtung im Browser unter Port 8123."
''';
}

/// Root/bash script (sudo shell, run with the marker check) that uninstalls
/// Home Assistant **as this app installs it**: the plain `docker run`
/// container [homeAssistantContainerName] with `/config` on
/// [homeAssistantConfigDir], plus its `-evccpitool-old` update rollback copy.
///
/// Guards first, read-only: Docker must answer; no other HA-like container may
/// exist, running or stopped (the card would stay, or someone else's install
/// is at stake); ours must not be compose-managed and must use the app's
/// config dir. Otherwise one `UNINSTALL_REFUSED: <Grund>` line + exit 3,
/// before anything changed.
///
/// [purge] false removes the containers only: config, data, the image and the
/// app backups stay, so a reinstall picks them up. [purge] true also removes
/// the images, [homeAssistantConfigDir] (HA's own backups live inside it) and
/// the app's `homeassistant-backup-*`. Docker itself always stays: other
/// containers may depend on it, and the app never recorded installing it.
/// Idempotent (a retry after a partial run finds less to do and succeeds);
/// verifies the result, then prints [homeAssistantRemovedMarker] last.
String buildHomeAssistantUninstallScript({required bool purge}) => [
      _haUninstallGuards,
      if (purge) _haRememberImages,
      _haRemoveContainers,
      purge ? _haPurgeData : _haKeepData,
      _haVerifyRemoved,
      if (purge) _haVerifyPurged,
      'echo $homeAssistantRemovedMarker\n',
    ].join();

// The sections below are plain literals like the install script; the only
// interpolation is the constant [_haShellRe] (no user data, no `'`). Tests pin
// the name and paths to the constants above.

const String _haUninstallGuards = r'''
set -e
export DEBIAN_FRONTEND=noninteractive
refuse() { echo "UNINSTALL_REFUSED: $1"; exit 3; }
down="Der Docker-Dienst antwortet nicht – bitte später erneut versuchen."
command -v docker >/dev/null 2>&1 || refuse "Docker wurde nicht gefunden – Home Assistant lässt sich so nicht entfernen."
docker info >/dev/null 2>&1 || refuse "$down"
all=$(docker ps -a --format '{{.Names}}|{{.Image}}') || refuse "$down"
# HA-like exactly as parseHomeAssistant (core image or a conventional name;
# companions like the Matter Server are not HA), but over ALL containers and
# case-insensitive: nothing the card could show slips through. Only ours and
# its rollback copy may match.
'''
    "ha_re='$_haShellRe'\n"
    r'''
foreign=$(printf '%s\n' "$all" | grep -iE "$ha_re" | cut -d'|' -f1 | grep -vx -e homeassistant -e homeassistant-evccpitool-old -e '' | tr '\n' ' ')
foreign=${foreign% }
if [ -n "$foreign" ]; then
  refuse "Weitere Home-Assistant-Container gefunden ($foreign). Pi-Tool entfernt nur seinen eigenen Container „homeassistant“ – bitte die anderen zuerst selbst entfernen."
fi
# Ours must be the app form: plain docker run (no compose project) with /config
# on the app's directory. Anything else was set up by hand.
ours=""
for c in homeassistant homeassistant-evccpitool-old; do
  printf '%s\n' "$all" | grep -q "^$c[|]" || continue
  labels=$(docker container inspect -f '{{range $k, $v := .Config.Labels}}{{println $k}}{{end}}' "$c") || refuse "$down"
  case "$labels" in
    *com.docker.compose.*) refuse "Home Assistant wird über Docker Compose verwaltet – bitte dort entfernen (docker compose down)." ;;
  esac
  src=$(docker container inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' "$c") || refuse "$down"
  [ "$src" = /opt/homeassistant/config ] || refuse "Der Container „${c}“ wurde nicht von Pi-Tool eingerichtet (/config liegt nicht in /opt/homeassistant/config) – bitte selbst entfernen."
  ours="$ours $c"
done
''';

const String _haRememberImages = r'''
imgs=""
for c in $ours; do imgs="$imgs $(docker container inspect -f '{{.Image}}' "$c")"; done
''';

const String _haRemoveContainers = r'''
for c in $ours; do
  echo "Stoppe und entferne den Container $c …"
  # Graceful stop: HA flushes its recorder database before it goes.
  docker stop -t 60 "$c" >/dev/null </dev/null
  docker rm "$c" >/dev/null </dev/null
done
''';

const String _haKeepData = r'''
echo "Konfiguration und Daten bleiben in /opt/homeassistant/config, Image und App-Backups ebenfalls – eine Neuinstallation übernimmt sie."
echo "Docker selbst bleibt installiert."
''';

const String _haPurgeData = r'''
echo "Entferne die Home-Assistant-Images …"
# Without -f: an image some other container still uses stays.
for i in ghcr.io/home-assistant/home-assistant:stable $imgs; do
  docker image rm "$i" >/dev/null 2>&1 </dev/null || true
done
# Older versions an update left untagged carry the HA image's own label.
docker image prune -f --filter label=io.hass.type=core >/dev/null 2>&1 </dev/null || true
echo "Lösche Konfiguration und Daten (/opt/homeassistant/config) …"
rm -rf -- /opt/homeassistant/config
# The parent only when empty: other things may live next to the config.
rmdir /opt/homeassistant 2>/dev/null || true
echo "Lösche die Home-Assistant-Backups der App …"
rm -f -- /var/backups/pi-tool/homeassistant-backup-*
echo "Docker selbst bleibt installiert."
''';

const String _haVerifyRemoved = r'''
for c in homeassistant homeassistant-evccpitool-old; do
  if docker container inspect "$c" >/dev/null 2>&1; then echo "Der Container $c ist noch vorhanden."; exit 1; fi
done
# The card's condition: no HA-like container may still be running.
running=$(docker ps --format '{{.Names}}|{{.Image}}')
left=$(printf '%s\n' "$running" | grep -iE "$ha_re" | cut -d'|' -f1 | tr '\n' ' ')
if [ -n "$left" ]; then echo "Es läuft weiterhin ein Home-Assistant-Container: $left"; exit 1; fi
''';

const String _haVerifyPurged = r'''
if [ -e /opt/homeassistant/config ]; then echo "/opt/homeassistant/config ist noch vorhanden."; exit 1; fi
if ls /var/backups/pi-tool/homeassistant-backup-* >/dev/null 2>&1; then echo "Es liegen noch Home-Assistant-Backups vor."; exit 1; fi
''';
