/// Pure construction of the SSH command sequence that updates evcc on a Pi.
///
/// No I/O happens here so the exact commands can be unit-tested without a real
/// SSH connection. The sequence mirrors the facts validated against the real
/// evcc-Pi on 2026-06-28.
library;

import 'dart:convert';

/// A single command in the update sequence.
class SshStep {
  /// Short human-readable label shown in the live log.
  final String label;

  /// The exact shell command to run on the Pi.
  final String command;

  /// Whether the sudo password must be fed to this command via stdin.
  ///
  /// The password is written to the command's stdin (for `sudo -S`) instead of
  /// being embedded in [command], so it can never end up in the command string
  /// or the visible log.
  final bool needsSudoPassword;

  const SshStep({
    required this.label,
    required this.command,
    required this.needsSudoPassword,
  });
}

/// How evcc is installed on the Pi.
enum InstallKind { apt, docker, unknown }

/// Reads the installed version of the `evcc` package (no sudo needed).
const String versionQuery =
    r"dpkg-query -W -f='${db:Status-Status} ${Version}' evcc";

/// Lists running containers as `name|image` lines (no sudo).
const String dockerListCommand = "docker ps --format '{{.Names}}|{{.Image}}'";

/// Same, but via sudo for hosts where the user isn't in the `docker` group.
const String dockerListSudoCommand =
    "LC_ALL=C sudo -S docker ps --format '{{.Names}}|{{.Image}}'";

/// A running evcc Docker container (its name + image).
class EvccDocker {
  final String name;
  final String image;
  const EvccDocker({required this.name, required this.image});
}

/// docker-compose project metadata read off a container's labels.
class DockerComposeInfo {
  final String workingDir;
  final String configFile;
  final String service;

  /// The compose project name (`com.docker.compose.project`). Empty if unknown.
  /// Pinned with `-p` so the update can never spawn a duplicate project.
  final String project;

  const DockerComposeInfo({
    required this.workingDir,
    required this.configFile,
    required this.service,
    this.project = '',
  });
}

/// Wraps [s] in single quotes, safely escaping any embedded single quote so the
/// value cannot break out of the quoting in a shell command (`'\''` idiom).
String shSingleQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// Finds the evcc container in a `name|image`-per-line listing. Prefers an
/// **image** match (the reliable signal) and only falls back to a name match,
/// so a sibling container like `evcc-db` (image `postgres`) is never mistaken
/// for the evcc install. Returns null when none is present.
EvccDocker? parseEvccDocker(String dockerPs) {
  final entries = <EvccDocker>[];
  for (final line in dockerPs.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final parts = t.split('|');
    if (parts.length < 2) continue;
    entries.add(EvccDocker(name: parts[0].trim(), image: parts[1].trim()));
  }
  for (final e in entries) {
    if (e.image.toLowerCase().contains('evcc')) return e;
  }
  // Name fallback only on an EXACT match (a `--name evcc` container with a
  // non-evcc image) — a substring match would wrongly pick siblings like
  // `evcc-db` / `evcc-grafana`.
  for (final e in entries) {
    if (e.name.toLowerCase() == 'evcc') return e;
  }
  return null;
}

/// Whether docker output indicates the user lacks daemon access (so the command
/// should be retried via sudo). Distinct from "docker not installed".
bool isDockerPermissionError(String output) {
  final o = output.toLowerCase();
  return o.contains('permission denied') &&
          (o.contains('docker daemon') || o.contains('docker.sock')) ||
      o.contains('cannot connect to the docker daemon');
}

/// `docker inspect <name>` — the full container JSON (parsed in Dart). Used for
/// both compose-label detection and `docker run` reconstruction.
String dockerInspectJsonCommand(String container) =>
    'docker inspect ${shSingleQuote(container)}';

/// sudo variant of [dockerInspectJsonCommand].
String dockerInspectJsonSudoCommand(String container) =>
    'LC_ALL=C sudo -S ${dockerInspectJsonCommand(container)}';

/// Decodes `docker inspect` output (a JSON array, or a bare object) and returns
/// the first container object, or null on empty/garbage.
Map<String, dynamic>? firstInspectObject(String json) {
  try {
    final decoded = jsonDecode(json.trim());
    if (decoded is List) {
      final first = decoded.firstWhere((e) => e is Map, orElse: () => null);
      return first == null ? null : Map<String, dynamic>.from(first as Map);
    }
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return null;
  } catch (_) {
    return null;
  }
}

/// Builds a validated [DockerComposeInfo] or null. The working dir must be an
/// absolute path and the service must match compose's charset — anything odd
/// falls through to a non-compose path rather than into a shell script (the
/// escaping in [dockerComposeUpdateScript] is the primary protection; this
/// rejects obviously-tampered labels early).
DockerComposeInfo? _composeInfo({
  required String workingDir,
  required String configFile,
  required String service,
  String project = '',
}) {
  if (workingDir.isEmpty || service.isEmpty) return null;
  final validService = RegExp(r'^[A-Za-z0-9._-]+$');
  if (!workingDir.startsWith('/') || !validService.hasMatch(service)) {
    return null;
  }
  return DockerComposeInfo(
    workingDir: workingDir,
    configFile: configFile,
    service: service,
    project: project,
  );
}

/// Reads the docker-compose labels off a full `docker inspect` object. Returns
/// null for a plain `docker run` container (no compose labels).
DockerComposeInfo? composeInfoFromInspect(Map<String, dynamic> container) {
  final config = container['Config'];
  final labels = (config is Map && config['Labels'] is Map)
      ? Map<String, dynamic>.from(config['Labels'] as Map)
      : <String, dynamic>{};
  String lab(String k) => (labels[k] ?? '').toString().trim();
  return _composeInfo(
    workingDir: lab('com.docker.compose.project.working_dir'),
    configFile: lab('com.docker.compose.project.config_files'),
    service: lab('com.docker.compose.service'),
    project: lab('com.docker.compose.project'),
  );
}

/// The root/bash script that updates a compose-managed evcc: pull the image,
/// then recreate only the evcc service in its project directory.
///
/// Pins the project (`-p`) and config file(s) (`-f`, comma-separated supported)
/// so a custom project name/filename can't make `up -d` spawn a *second*
/// container. Falls back to the v1 standalone binary when the v2 plugin is
/// absent. Every interpolated value is shell-escaped against label tampering.
String dockerComposeUpdateScript(DockerComposeInfo info) {
  final dir = shSingleQuote(info.workingDir);
  final svc = shSingleQuote(info.service);
  final opts = <String>[];
  if (info.project.isNotEmpty) {
    opts.addAll(['-p', shSingleQuote(info.project)]);
  }
  for (final cf in info.configFile.split(',')) {
    final f = cf.trim();
    if (f.isNotEmpty) opts.addAll(['-f', shSingleQuote(f)]);
  }
  final dc = opts.isEmpty ? r'$DC' : '\$DC ${opts.join(' ')}';
  return '''
set -e
cd $dir
if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi
$dc pull $svc
$dc up -d $svc
''';
}

/// Environment variables that are pure image/base defaults — dropped when
/// reconstructing a `docker run` (the new image supplies its own; re-passing a
/// stale value could clobber it). Note: other `Config.Env` entries may also be
/// image-baked defaults, but re-passing them is harmless for evcc.
const _imageDefaultEnv = {'PATH'};

/// Restart-policy names accepted verbatim. Anything else (incl. tampered/odd
/// values) is dropped rather than interpolated raw — defense-in-depth.
const _allowedRestart = {'always', 'unless-stopped', 'on-failure'};

/// Label key prefixes that are image- or infra-owned, not user `-l` flags —
/// these are not re-passed when reconstructing a `docker run`.
const _infraLabelPrefixes = [
  'com.docker.',
  'org.opencontainers.',
  'org.label-schema.',
];

/// Reconstructs an equivalent `docker run -d …` command from a full
/// `docker inspect` object, preserving name, restart policy, privileges/devices
/// /capabilities/groups (serial-meter setups), port bindings, bind/volume
/// mounts, log options, user env, user labels and a non-default network.
/// [image] overrides the image reference (e.g. to pin a freshly-pulled tag).
String buildDockerRunCommand(Map<String, dynamic> container, {String? image}) {
  final config = (container['Config'] is Map)
      ? Map<String, dynamic>.from(container['Config'] as Map)
      : <String, dynamic>{};
  final host = (container['HostConfig'] is Map)
      ? Map<String, dynamic>.from(container['HostConfig'] as Map)
      : <String, dynamic>{};

  final name =
      (container['Name'] ?? '').toString().replaceFirst(RegExp(r'^/'), '');
  final img = (image ?? config['Image'] ?? '').toString();
  final networkMode = (host['NetworkMode'] ?? '').toString();
  final hostNetwork = networkMode == 'host';

  final args = <String>['docker', 'run', '-d'];
  if (name.isNotEmpty) args.addAll(['--name', shSingleQuote(name)]);

  // Restart policy — whitelisted names only.
  final rp = (host['RestartPolicy'] is Map)
      ? Map<String, dynamic>.from(host['RestartPolicy'] as Map)
      : <String, dynamic>{};
  final rpName = (rp['Name'] ?? '').toString();
  if (_allowedRestart.contains(rpName)) {
    final retries = rp['MaximumRetryCount'];
    if (rpName == 'on-failure' && retries is int && retries > 0) {
      args.addAll(['--restart', 'on-failure:$retries']);
    } else {
      args.addAll(['--restart', rpName]);
    }
  }

  if (host['Privileged'] == true) args.add('--privileged');

  // Published ports are discarded under host networking, so skip them there.
  if (!hostNetwork && host['PortBindings'] is Map) {
    final pb = Map<String, dynamic>.from(host['PortBindings'] as Map);
    for (final entry in pb.entries) {
      final cport = entry.key; // e.g. "7070/tcp"
      final num = cport.split('/').first;
      final proto = cport.endsWith('/udp') ? '/udp' : '';
      final bindings = entry.value;
      if (bindings is List) {
        for (final b in bindings) {
          if (b is Map) {
            var hostIp = (b['HostIp'] ?? '').toString();
            if (hostIp.contains(':')) hostIp = '[$hostIp]'; // IPv6
            final hostPort = (b['HostPort'] ?? '').toString();
            final spec = hostIp.isNotEmpty
                ? '$hostIp:$hostPort:$num$proto'
                : '$hostPort:$num$proto';
            args.addAll(['-p', shSingleQuote(spec)]);
          }
        }
      }
    }
  }

  // Devices / groups / capabilities — essential for USB/RS485 serial meters.
  final devices = host['Devices'];
  if (devices is List) {
    for (final d in devices) {
      if (d is Map) {
        final onHost = (d['PathOnHost'] ?? '').toString();
        if (onHost.isEmpty) continue;
        final inC = (d['PathInContainer'] ?? onHost).toString();
        final perms = (d['CgroupPermissions'] ?? '').toString();
        final spec = perms.isEmpty ? '$onHost:$inC' : '$onHost:$inC:$perms';
        args.addAll(['--device', shSingleQuote(spec)]);
      }
    }
  }
  for (final g in (host['GroupAdd'] is List ? host['GroupAdd'] as List : [])) {
    args.addAll(['--group-add', shSingleQuote(g.toString())]);
  }
  for (final c in (host['CapAdd'] is List ? host['CapAdd'] as List : [])) {
    args.addAll(['--cap-add', shSingleQuote(c.toString())]);
  }

  // Log driver/options — Pi users often cap log size to spare the SD card.
  final log = host['LogConfig'];
  if (log is Map) {
    final type = (log['Type'] ?? '').toString();
    if (type.isNotEmpty && type != 'json-file') {
      args.addAll(['--log-driver', shSingleQuote(type)]);
    }
    final opts = log['Config'];
    if (opts is Map) {
      opts.forEach((k, v) =>
          args.addAll(['--log-opt', shSingleQuote('$k=$v')]));
    }
  }

  final binds = host['Binds'];
  if (binds is List) {
    for (final b in binds) {
      args.addAll(['-v', shSingleQuote(b.toString())]);
    }
  }

  final env = config['Env'];
  if (env is List) {
    for (final e in env) {
      final s = e.toString();
      if (_imageDefaultEnv.contains(s.split('=').first)) continue;
      args.addAll(['-e', shSingleQuote(s)]);
    }
  }

  // User labels only — image/infra-owned labels are re-applied by the image.
  final labels = config['Labels'];
  if (labels is Map) {
    labels.forEach((k, v) {
      final key = k.toString();
      if (_infraLabelPrefixes.any(key.startsWith)) return;
      args.addAll(['-l', shSingleQuote('$key=$v')]);
    });
  }

  if (networkMode.isNotEmpty &&
      networkMode != 'default' &&
      networkMode != 'bridge') {
    args.addAll(['--network', shSingleQuote(networkMode)]);
  }

  args.add(shSingleQuote(img));
  return args.join(' ');
}

/// The root/bash script that updates a plain `docker run` container: pull the
/// new image, keep the old container as a rollback by renaming it (never
/// deleting data), then start the recreated container. [runCommand] is the
/// reconstructed `docker run` from [buildDockerRunCommand].
String dockerRunRecreateScript({
  required String name,
  required String image,
  required String runCommand,
}) {
  final n = shSingleQuote(name);
  final backup = shSingleQuote('$name-evccpitool-old');
  final img = shSingleQuote(image);
  // Pull first (a failed pull aborts before anything is touched). Then keep the
  // old container as a rollback by renaming it (never `-v`, so no data loss),
  // create the new one, and if creation fails restore + restart the old one and
  // report failure. A short settle lets an immediately-crashing new container
  // drop out of `docker ps`. `docker run -d` returns 0 the moment the daemon
  // ACCEPTS the container, so we then verify it is actually still running and,
  // if not (crash-on-boot), roll back to the retained old container.
  return '''
set -e
docker pull $img
docker rm -f $backup >/dev/null 2>&1 || true
docker stop $n
docker rename $n $backup
$runCommand || { echo 'Neuanlage fehlgeschlagen – stelle alten Container wieder her.'; docker rm -f $n >/dev/null 2>&1 || true; docker rename $backup $n && docker start $n; exit 1; }
sleep 3
if [ "\$(docker inspect -f '{{.State.Running}}' $n 2>/dev/null)" != "true" ]; then
  echo 'Neuer Container läuft nach dem Start nicht – stelle den alten wieder her.'
  docker rm -f $n >/dev/null 2>&1 || true
  docker rename $backup $n >/dev/null 2>&1 || true
  docker start $n >/dev/null 2>&1 || true
  exit 1
fi
''';
}

/// Queries whether the evcc service is running (no sudo needed).
const String serviceStatus = 'systemctl is-active evcc';

/// Restarts the evcc service (needs sudo).
const String serviceRestartCommand =
    'LC_ALL=C sudo -S systemctl restart evcc';

/// Reboots the Pi (needs sudo). The SSH connection drops as a result.
const String rebootCommand = 'LC_ALL=C sudo -S reboot';

/// Powers the Pi off (needs sudo). The SSH connection drops as a result, and —
/// unlike [rebootCommand] — the Pi stays off until it is physically powered on
/// again.
const String shutdownCommand = 'LC_ALL=C sudo -S poweroff';

/// Builds the ordered update sequence.
///
/// - [fullUpgrade] `false` upgrades only evcc; `true` upgrades the whole system.
/// - [dryRun] `true` makes apt simulate the upgrade without changing anything.
List<SshStep> buildUpdateSteps({
  required bool fullUpgrade,
  required bool dryRun,
}) {
  return [
    const SshStep(
      label: 'Version vorher',
      command: versionQuery,
      needsSudoPassword: false,
    ),
    const SshStep(
      label: 'Paketliste aktualisieren',
      command: 'LC_ALL=C sudo -S apt-get update -qq',
      needsSudoPassword: true,
    ),
    SshStep(
      label: fullUpgrade ? 'System-Upgrade' : 'evcc aktualisieren',
      command: _upgradeCommand(fullUpgrade: fullUpgrade, dryRun: dryRun),
      needsSudoPassword: true,
    ),
    const SshStep(
      label: 'Dienststatus',
      command: serviceStatus,
      needsSudoPassword: false,
    ),
    const SshStep(
      label: 'Version nachher',
      command: versionQuery,
      needsSudoPassword: false,
    ),
  ];
}

/// The remote command that runs the install script as root: `sudo -S bash -s`.
///
/// The caller feeds `<password>\n<script>` to stdin — `sudo -S` consumes the
/// first line as the password, then `bash -s` executes the rest as root. This
/// keeps the password out of the command line entirely.
const String installShellCommand = 'LC_ALL=C sudo -S bash -s';

/// Asks whether sudo needs a password at all, without prompting for one:
/// exit 0 = passwordless (NOPASSWD or a still-valid timestamp).
const String sudoNoPasswordProbe = 'sudo -n true 2>/dev/null';

/// Builds the stdin for [installShellCommand]. `sudo -S` eats the first line as
/// the password — but ONLY when it actually asks. On a passwordless sudo it
/// asks nothing, the line falls through to `bash -s`, and the password gets
/// executed as a command (`bash: line 1: <password>: command not found`, seen
/// in the wild on 2026-07-31). So the password goes in only when it is needed.
String buildRootStdin({
  required bool sudoNeedsPassword,
  required String password,
  required String script,
}) =>
    sudoNeedsPassword ? '$password\n$script\n' : '$script\n';

/// The root install script: official evcc apt-repo setup + package install +
/// service enable. Mirrors https://docs.evcc.io/en/installation/linux.
/// Runs as root (via [installShellCommand]), so it uses no inner `sudo`.
///
/// [channel] selects the apt repo: 'stable' (default) or 'unstable' (nightly).
String buildInstallScript({String channel = 'stable'}) {
  final repo = channel == 'unstable' ? 'unstable' : 'stable';
  return '''
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
setup=\$(mktemp)
curl -1sLf 'https://dl.evcc.io/public/evcc/$repo/setup.deb.sh' -o "\$setup"
bash "\$setup"
rm -f "\$setup"
apt-get update
apt-get install -y evcc
systemctl enable --now evcc
''';
}

/// Root/bash script that snapshots the evcc config + database into a
/// timestamped archive under `/var/backups/evcc/` before an update. The DB path
/// is taken from the config's `dsn:` if set, otherwise probed at the common
/// default locations (it varies by service user). Run via [installShellCommand].
///
/// Prints `EVCC_BACKUP_OK <path>` on success, `EVCC_BACKUP_EMPTY` when there is
/// nothing to back up (not an error), or `EVCC_BACKUP_FAIL` + exit 1 on failure.
String buildBackupScript() {
  return r'''
mkdir -p /var/backups/evcc
chmod 0755 /var/backups/evcc 2>/dev/null || true
ts=$(date +%Y%m%d-%H%M%S)
out="/var/backups/evcc/evcc-backup-$ts.tar.gz"
files=""
if [ -f /etc/evcc.yaml ]; then files="$files /etc/evcc.yaml"; fi
db=""
if [ -f /etc/evcc.yaml ]; then
  db=$(grep -E '^[[:space:]]*dsn:' /etc/evcc.yaml 2>/dev/null | head -n1 | sed 's/.*dsn:[[:space:]]*//')
fi
if [ -z "$db" ] || [ ! -f "$db" ]; then
  for c in /root/.evcc/evcc.db /var/lib/evcc/.evcc/evcc.db /var/lib/evcc/evcc.db /home/*/.evcc/evcc.db; do
    if [ -f "$c" ]; then db="$c"; break; fi
  done
fi
if [ -n "$db" ] && [ -f "$db" ]; then files="$files $db"; fi
if [ -z "$files" ]; then echo "EVCC_BACKUP_EMPTY"; exit 0; fi
if tar -czf "$out" $files; then chmod 0644 "$out" 2>/dev/null || true; echo "EVCC_BACKUP_OK $out"; else echo "EVCC_BACKUP_FAIL"; exit 1; fi
''';
}

/// Where pre-update evcc backups are written (see [buildBackupScript]).
const String evccBackupDir = '/var/backups/evcc';

/// Where on-demand Pi-hole / Home Assistant backups are written.
const String serviceBackupDir = '/var/backups/pi-tool';

/// Extracts the archive path from a service-backup success marker
/// (`BACKUP_OK <path>`), or null when no backup was written.
String? parseServiceBackupPath(String output) {
  const marker = 'BACKUP_OK ';
  for (final line in output.split('\n')) {
    final t = line.trim();
    if (t.startsWith(marker)) {
      final path = t.substring(marker.length).trim();
      if (path.isNotEmpty) return path;
    }
  }
  return null;
}

/// Prepares a free-form console command for one-off SSH execution. A command
/// that STARTS with `sudo` is rewritten to `sudo -S -p ''` so sudo reads the
/// password from stdin (piped by the caller) instead of blocking on a TTY
/// prompt, and its prompt text can't leak into the output. [sudo] tells the
/// caller whether to pipe the password. The command is otherwise passed through
/// verbatim — the user is responsible for what they run.
({String exec, bool sudo}) buildConsoleExec(String command) {
  final t = command.trim();
  if (t == 'sudo' || t.startsWith('sudo ')) {
    final rest = t.substring(4).trim();
    return (exec: rest.isEmpty ? "sudo -S -p ''" : "sudo -S -p '' $rest", sudo: true);
  }
  return (exec: t, sudo: false);
}

/// Returns a German hint when [command] is an interactive/TUI program that can't
/// work in the non-PTY console (no terminal, no keyboard) — else null. The
/// console runs one-off commands over a plain exec channel, so `htop`, editors,
/// pagers and follow-mode (`-f`) would either error ("Error opening terminal:
/// unknown") or hang. We catch these and suggest a non-interactive alternative
/// instead of running them.
String? interactiveCommandHint(String command) {
  final tokens = command.trim().split(RegExp(r'\s+'))..removeWhere((t) => t.isEmpty);
  if (tokens.isEmpty) return null;
  // Skip a leading `sudo` and its options so "sudo htop" is caught too.
  var i = 0;
  if (tokens[i] == 'sudo') {
    i++;
    while (i < tokens.length && tokens[i].startsWith('-')) {
      i++;
    }
  }
  if (i >= tokens.length) return null;
  final prog = tokens[i].split('/').last; // basename
  final args = tokens.sublist(i + 1);
  bool hasFlag(String c) =>
      args.any((t) => t.startsWith('-') && t.contains(c));

  if (args.contains('-f') && (prog == 'tail' || prog == 'journalctl')) {
    return 'Der Folgemodus „-f" hängt in der Konsole (nicht abbrechbar). Lass '
        '„-f" weg — z. B. „${prog == 'journalctl' ? 'journalctl -n 50 --no-pager' : 'tail -n 50 <datei>'}".';
  }
  switch (prog) {
    case 'top':
    case 'atop':
      if (hasFlag('b')) return null; // batch mode (top -bn1) is fine
      return 'htop/top brauchen ein echtes Terminal. Für einen Schnappschuss: '
          '„top -bn1".';
    case 'htop':
    case 'btop':
      return 'htop/top brauchen ein echtes Terminal. Für einen Schnappschuss: '
          '„top -bn1".';
    case 'vi':
    case 'vim':
    case 'nano':
    case 'emacs':
    case 'pico':
      return 'Editoren laufen hier nicht interaktiv. Bearbeite Dateien über den '
          'Datei-Explorer bzw. den Config-Editor.';
    case 'less':
    case 'more':
      return '„$prog" braucht ein Terminal. Nutze „cat" (oder „… | head").';
    case 'man':
      return '„man" braucht ein Terminal. Nutze „<befehl> --help".';
    case 'watch':
      return '„watch" läuft hier nicht dauerhaft. Setz den Befehl einmalig ab.';
    case 'ssh':
    case 'telnet':
      return 'Interaktive Sitzungen (ssh/telnet) sind in der Konsole nicht '
          'möglich.';
    default:
      return null;
  }
}

/// Lists one service's backups under /var/backups/pi-tool, newest first. No
/// sudo: the dir is 0755 and the archives 0644 (see the backup scripts).
String serviceBackupListCommand(String servicePrefix) =>
    'ls -1t /var/backups/pi-tool/${shSingleQuote(servicePrefix)}-backup-* '
    '2>/dev/null';

/// Parses [serviceBackupListCommand] output into archive paths (newest first).
List<String> parseServiceBackupList(String lsOutput) => lsOutput
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.endsWith('.tar.gz') || l.endsWith('.zip'))
    .toList();

/// Deletes one backup archive (root owns the dir, so sudo). `--` stops option
/// parsing; the path is single-quoted against injection.
String serviceBackupDeleteCommand(String path) =>
    'LC_ALL=C sudo -S rm -f -- ${shSingleQuote(path)}';

/// Root script that frees disk space, conservatively: apt autoremove + clean,
/// DANGLING docker images only (a container/system prune would delete the
/// stopped `…-evccpitool-old` rollback containers we deliberately keep), and
/// journal older than 7 days. Reports `CLEANUP_OK <before> <after>` (available
/// bytes on / before/after) for [parseCleanupFreed]. Steps are best-effort so
/// e.g. a Pi without docker still cleans apt + journal.
String buildCleanupScript() => r'''
export DEBIAN_FRONTEND=noninteractive
before=$(df -B1 --output=avail / | tail -1 | tr -d ' ')
apt-get autoremove -y 2>&1 || true
apt-get clean 2>&1 || true
docker image prune -f 2>&1 || true
journalctl --vacuum-time=7d 2>&1 || true
after=$(df -B1 --output=avail / | tail -1 | tr -d ' ')
echo "CLEANUP_OK $before $after"
''';

/// Freed bytes from the `CLEANUP_OK <before> <after>` marker (clamped at 0),
/// or null when the marker is missing (script failed).
int? parseCleanupFreed(String output) {
  for (final line in output.split('\n')) {
    final t = line.trim();
    if (!t.startsWith('CLEANUP_OK ')) continue;
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length < 3) return null;
    final before = int.tryParse(parts[1]);
    final after = int.tryParse(parts[2]);
    if (before == null || after == null) return null;
    final freed = after - before;
    return freed > 0 ? freed : 0;
  }
  return null;
}

/// Shell that runs the batched detection script (fed via stdin). LC_ALL=C for
/// stable parsing, and distinct from the plain `bash -s` used elsewhere.
const String detectShellCommand = 'LC_ALL=C bash -s';

/// Reads a config file as root (many live under /etc, root-owned).
String buildConfigReadCommand(String path) =>
    // LC_ALL=C so a rejected sudo password is detected (isSudoPasswordFailure is
    // English-only) instead of falling through to "file missing/no rights".
    "LC_ALL=C sudo -S -p '' cat ${shSingleQuote(path)}";

/// Root script that backs the current [path] up (under /var/backups/pi-tool),
/// then overwrites it with [base64Content]. Base64 sidesteps ALL shell-quoting
/// / injection issues with arbitrary file content (b64 is only `A-Za-z0-9+/=`).
/// Prints `CONFIG_SAVED` on success.
String buildConfigWriteScript({
  required String path,
  required String base64Content,
}) {
  final p = shSingleQuote(path);
  return '''
set -e
mkdir -p /var/backups/pi-tool
if [ -f $p ]; then
  cp $p "/var/backups/pi-tool/config-\$(basename $p)-\$(date +%Y%m%d-%H%M%S).bak"
  ls -1t "/var/backups/pi-tool/config-\$(basename $p)-"* 2>/dev/null | tail -n +6 | xargs -r rm -f -- || true
fi
# Write to a temp file, then atomically rename over the target so a mid-write
# failure (full disk, killed) never leaves a truncated live config. Preserve
# the original's owner/mode first (a fresh inode would reset them to root+umask).
d=\$(dirname $p)
tmp=\$(mktemp "\$d/.pitool-cfg.XXXXXX")
printf '%s' '$base64Content' | base64 -d > "\$tmp"
if [ -f $p ]; then
  chmod --reference=$p "\$tmp" 2>/dev/null || true
  chown --reference=$p "\$tmp" 2>/dev/null || true
fi
mv -f "\$tmp" $p
echo CONFIG_SAVED
''';
}

/// The right "show recent logs" command for a detected service: `docker logs`
/// for a container (with a sudo fallback), the whole journal for the System
/// card, or `journalctl -u <unit>` otherwise. Sudo is piped (journals + the
/// docker fallback usually need root). [id] is the service id, [detail] its
/// detected detail line (`Docker · NAME` for containers).
({String command, bool sudo}) buildServiceLogsCommand({
  required String id,
  required String detail,
}) {
  const dockerPrefix = 'Docker · ';
  if (detail.startsWith(dockerPrefix)) {
    final name = detail.substring(dockerPrefix.length).trim();
    final q = shSingleQuote(name);
    return (
      command: 'docker logs --tail 200 $q 2>&1 || '
          "sudo -S -p '' docker logs --tail 200 $q 2>&1",
      sudo: true,
    );
  }
  if (id == 'system') {
    return (
      command: "sudo -S -p '' journalctl -n 200 --no-pager 2>&1",
      sudo: true,
    );
  }
  const units = {
    'pihole': 'pihole-FTL',
    'grafana': 'grafana-server',
    'adguard': 'AdGuardHome',
  };
  // evcc, influxdb, mosquitto, nodered, zigbee2mqtt already match their unit.
  final unit = units[id] ?? id;
  return (
    command:
        "sudo -S -p '' journalctl -u ${shSingleQuote(unit)} -n 200 --no-pager 2>&1",
    sudo: true,
  );
}

const String _detectMarker = '@@PT@@';

/// Builds ONE shell script that runs every read-only detection probe, each
/// preceded by a unique section marker, so the whole detection is a single SSH
/// round-trip instead of ~13. [probes] is (sectionKey, command) pairs. Each
/// command's stderr is merged and failures are swallowed, so one missing tool
/// doesn't abort the rest. Parse the result with [splitDetectSections].
String buildDetectBatch(List<(String key, String command)> probes) {
  final b = StringBuffer();
  for (final (key, cmd) in probes) {
    // A leading blank line guarantees the marker sits on its own line even if
    // the previous command's output had no trailing newline.
    b.writeln('echo');
    b.writeln('echo $_detectMarker$key$_detectMarker');
    b.writeln('{ $cmd ; } 2>&1 || true');
  }
  return b.toString();
}

/// Splits [buildDetectBatch] output back into sectionKey → content.
Map<String, String> splitDetectSections(String output) {
  final map = <String, String>{};
  String? key;
  final buf = <String>[];
  void flush() {
    final k = key;
    if (k != null) map[k] = buf.join('\n').trim();
    buf.clear();
  }

  for (final line in output.split('\n')) {
    final t = line.trim();
    if (t.length > _detectMarker.length * 2 &&
        t.startsWith(_detectMarker) &&
        t.endsWith(_detectMarker)) {
      flush();
      key = t.substring(_detectMarker.length, t.length - _detectMarker.length);
    } else if (key != null) {
      buf.add(line);
    }
  }
  flush();
  return map;
}

/// Lists existing evcc backups, newest first. No sudo: the dir + archives are
/// created by root with a standard umask, so they're world-readable.
const String listBackupsCommand =
    'ls -1t /var/backups/evcc/*.tar.gz 2>/dev/null';

/// Parses [listBackupsCommand] output into archive paths (newest first).
List<String> parseBackupList(String lsOutput) => lsOutput
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.endsWith('.tar.gz'))
    .toList();

/// Root/bash script (run via [installShellCommand]) that restores [archivePath]:
/// stop evcc, extract the archive back to `/`, restart evcc. The backup stores
/// relative paths (tar strips the leading `/`), so `-C /` puts every file back
/// in its original location (e.g. /etc/evcc.yaml + the database).
String buildRestoreScript(String archivePath) {
  final a = shSingleQuote(archivePath);
  return '''
set -e
if [ ! -f $a ]; then echo "Backup nicht gefunden."; exit 1; fi
systemctl stop evcc 2>/dev/null || true
tar -xzf $a -C /
systemctl start evcc
echo RESTORE_OK
''';
}

String _upgradeCommand({required bool fullUpgrade, required bool dryRun}) {
  if (fullUpgrade) {
    return dryRun
        ? 'LC_ALL=C sudo -S apt-get full-upgrade --dry-run'
        : 'LC_ALL=C sudo -S apt-get full-upgrade -y';
  }
  return dryRun
      ? 'LC_ALL=C sudo -S apt-get install --only-upgrade --dry-run evcc'
      : 'LC_ALL=C sudo -S apt-get install --only-upgrade -y evcc';
}
