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

final _haImage = RegExp(r'home[-_]?assistant', caseSensitive: false);

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
ls -1t /var/backups/pi-tool/homeassistant-backup-* 2>/dev/null | tail -n +6 | xargs -r rm -f --
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
  return '''
set -e
if [ ! -f $a ]; then echo "RESTORE_FAIL_MISSING"; exit 1; fi
if [ ! -d $c ]; then echo "RESTORE_FAIL_NOCONF"; exit 1; fi
docker stop $n
trap "docker start $n >/dev/null 2>&1 || true" EXIT
tar -xzf $a -C $c
echo "RESTORE_OK"
''';
}

/// Finds the Home Assistant container in
/// `docker ps --format '{{.Names}}|{{.Image}}'` output. Matches by image
/// (…home-assistant…) or by a conventional container name. Returns null when
/// no HA container is running.
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
