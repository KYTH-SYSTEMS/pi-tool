import 'dart:io';

import 'package:evcc_updater/src/alerts.dart';
import 'package:evcc_updater/src/auto_update.dart';
import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/docker_containers.dart';
import 'package:evcc_updater/src/eol_sources.dart';
import 'package:evcc_updater/src/evcc_updater.dart';
import 'package:evcc_updater/src/files.dart';
import 'package:evcc_updater/src/pi_job.dart';
import 'package:evcc_updater/src/scheduled_backup.dart';
import 'package:evcc_updater/src/security_check.dart';
import 'package:evcc_updater/src/services/apt_services.dart';
import 'package:evcc_updater/src/services/homeassistant_service.dart';
import 'package:evcc_updater/src/services/pi_connect.dart';
import 'package:evcc_updater/src/services/pihole_service.dart';
import 'package:evcc_updater/src/services/stack_wiring.dart';
import 'package:evcc_updater/src/services/system_service.dart';
import 'package:evcc_updater/src/services/tailscale.dart';
import 'package:evcc_updater/src/ssh_keys.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:evcc_updater/src/storage_explorer.dart';
import 'package:evcc_updater/src/systemd_services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'on_pi_sandbox.dart';

// Every script and every command line the app sends to a Pi, parsed by the
// shell that reads it there. `bash -n`, `sh -n` and `dash -n` on a file: the
// text is read, nothing of it runs — no sandbox is needed for that.
//
// One table ([_scripts]) names them all; a builder that is new in lib/src and
// missing here fails the last test of this file. Parts that are scripts of
// their own are taken out and parsed separately: the argument of `sh -c` /
// `bash -c`, a file an install script writes through a heredoc (by its
// shebang), the command of a `trap`. The same table carries the rule that no
// heredoc opens with an unquoted delimiter.
//
// What a value from the user or the Pi does to these scripts is another
// matter: test/script_quoting_test.dart runs them with such values.

/// Where a text is read on the Pi.
enum _Shell {
  /// Fed to `bash -s` (the root scripts, the detection batch), handed to
  /// `bash -c`, or a file with a bash shebang.
  bash,

  /// A `#!/bin/sh` file or the argument of `sh -c`: dash on a Pi.
  sh,

  /// One command line on the SSH exec channel, read by the login shell —
  /// bash on Raspberry Pi OS. Held to what a POSIX sh reads as well, so that
  /// another login shell does not stumble over it.
  login,
}

class _Script {
  const _Script(this.name, this.shell, this.text, {this.inner = 0});

  /// The builder or constant in lib/, then what it was called with.
  final String name;
  final _Shell shell;
  final String text;

  /// How many `sh -c` / `bash -c` arguments a command line carries.
  final int inner;
}

/// Values a builder has to carry: a plain one, one with everything a shell
/// gives a meaning to (and an umlaut), and one with a line break.
const _values = <(String, String)>[
  ('plain', 'evcc'),
  ('awkward', 'Müll Ordner/it\'s "so" \$(x) `y` \\ ;&|<>*?[]{}~#!'),
  ('line break', "Zeile 1\nZeile 2 'x"),
];

const _id = '0123456789abcdef';

/// [name] once per entry of [_values].
List<_Script> _each(String name, _Shell shell, String Function(String v) build,
        {int inner = 0}) =>
    [
      for (final (tag, v) in _values)
        _Script('$name ($tag)', shell, build(v), inner: inner),
    ];

/// A `docker inspect` object with [v] in every field that reaches the
/// reconstructed `docker run`.
Map<String, dynamic> _container(String v) => {
      'Id': 'f00dfeedf00dfeed',
      'Name': '/$v',
      'Config': {
        'Image': 'img:$v',
        'Hostname': 'host $v',
        'User': 'user $v',
        'Env': ['A=$v'],
        'Labels': {'my.$v': v},
        'Entrypoint': ['entry $v', 'arg $v'],
        'Cmd': ['cmd $v'],
      },
      'HostConfig': {
        'NetworkMode': 'net $v',
        'RestartPolicy': {'Name': 'on-failure', 'MaximumRetryCount': 3},
        'PortBindings': {
          '80$v/udp': [
            {'HostIp': 'ip$v', 'HostPort': 'p$v'}
          ],
        },
        'Devices': [
          {'PathOnHost': '/dev/$v', 'PathInContainer': '/dev/in $v'}
        ],
        'GroupAdd': ['grp $v'],
        'CapAdd': ['cap $v'],
        'CapDrop': ['drop $v'],
        'LogConfig': {
          'Type': 'log $v',
          'Config': {'max-size': v},
        },
        'Binds': ['/data/$v:/data'],
        'SecurityOpt': ['opt $v'],
        'Tmpfs': {'/cache $v': 'size=$v'},
        'Sysctls': {'net.$v': v},
        'Memory': 268435456,
        'NanoCpus': 1500000000,
        'CpusetCpus': 'cpus $v',
        'CpusetMems': 'mems $v',
        'PidMode': 'container:$v',
        'ExtraHosts': ['extra $v'],
      },
    };

/// An apt service whose every field is [v] — as far as the builder's own
/// checks let it through.
AptService _aptService(String v) {
  final file = v.replaceAll('/', '_');
  return AptService(
    id: 'x',
    name: v,
    packages: [v],
    unit: v,
    footprint: AptUninstallFootprint(
      companions: [v],
      purgePaths: ['/etc/$file'],
      purgeLinks: ['/etc/systemd/system/$file'],
      aptSourceList: '/etc/apt/sources.list.d/$file',
      aptKeyring: '/etc/apt/keyrings/$file',
      repoKeyringPackage: v,
      repoSiblings: [v],
      backupPrefixes: [file],
      evccConfigKey: v,
      undoStackWiring: true,
    ),
  );
}

/// What follows the sentinel line of a Pi-Job stdin: the script bash runs.
String _behindSentinel(String stdin) =>
    stdin.substring(stdin.indexOf('$jobSentinel\n') + jobSentinel.length + 1);

/// Every script builder and command constant of lib/src.
List<_Script> _scripts() {
  const login = _Shell.login, bash = _Shell.bash, sh = _Shell.sh;
  final launcher = buildJobLauncherScript(
      id: _id, kind: jobKindSystemUpgrade, payload: buildSystemUpgradePayload());
  return [
    // ---- commands.dart ----------------------------------------------------
    const _Script('versionQuery', login, versionQuery),
    const _Script('dockerListCommand', login, dockerListCommand),
    const _Script('dockerListSudoCommand', login, dockerListSudoCommand),
    const _Script('dockerListRunningCommand', login, dockerListRunningCommand),
    const _Script(
        'dockerListRunningSudoCommand', login, dockerListRunningSudoCommand),
    const _Script('dockerListStateCommand', login, dockerListStateCommand),
    const _Script(
        'dockerListStateSudoCommand', login, dockerListStateSudoCommand,
        inner: 1),
    ..._each('dockerInspectJsonCommand', login, dockerInspectJsonCommand),
    ..._each(
        'dockerInspectJsonSudoCommand', login, dockerInspectJsonSudoCommand),
    ..._each(
        'dockerComposeUpdateScript',
        bash,
        (v) => dockerComposeUpdateScript(DockerComposeInfo(
            workingDir: '/srv/$v',
            configFile: '$v.yml, extra $v.yml',
            service: v,
            project: v))),
    _Script(
        'dockerComposeUpdateScript (no project, no file)',
        bash,
        dockerComposeUpdateScript(const DockerComposeInfo(
            workingDir: '/srv/evcc', configFile: '', service: 'evcc'))),
    ..._each('buildDockerRunCommand', bash,
        (v) => buildDockerRunCommand(_container(v), image: 'img $v')),
    ..._each(
        'dockerRunRecreateScript',
        bash,
        (v) => dockerRunRecreateScript(
            name: v,
            image: 'img $v',
            runCommand: buildDockerRunCommand(_container(v)))),
    const _Script('serviceStatus', login, serviceStatus),
    const _Script('serviceRestartCommand', login, serviceRestartCommand),
    const _Script('jobPowerGuard', sh, jobPowerGuard),
    const _Script('rebootCommand', login, rebootCommand, inner: 1),
    const _Script('shutdownCommand', login, shutdownCommand, inner: 1),
    for (final full in [false, true])
      for (final dry in [false, true])
        for (final step in buildUpdateSteps(fullUpgrade: full, dryRun: dry))
          _Script('buildUpdateSteps (full: $full, dry run: $dry, ${step.label})',
              login, step.command),
    const _Script('installShellCommand', login, installShellCommand),
    const _Script('sudoNoPasswordProbe', login, sudoNoPasswordProbe),
    _Script(
        'buildRootStdin (sudo asks for nothing)',
        bash,
        buildRootStdin(
            sudoNeedsPassword: false,
            password: 'geheim',
            script: buildCleanupScript())),
    for (final channel in ['stable', 'unstable', _values[1].$2])
      _Script('buildInstallScript ($channel)', bash,
          buildInstallScript(channel: channel)),
    for (final purge in [false, true])
      _Script('buildEvccUninstallScript (purge: $purge)', bash,
          buildEvccUninstallScript(purge: purge)),
    _Script('buildBackupScript', bash, buildBackupScript()),
    for (final c in ['sudo', 'sudo journalctl -n 50 --no-pager', 'uptime'])
      _Script('buildConsoleExec ($c)', login, buildConsoleExec(c).exec),
    ..._each('serviceBackupListCommand', login, serviceBackupListCommand,
        inner: 1),
    ..._each('serviceBackupDeleteCommand', login,
        (v) => serviceBackupDeleteCommand('/var/backups/pi-tool/$v.zip')),
    _Script('buildCleanupScript', bash, buildCleanupScript()),
    const _Script('detectShellCommand', login, detectShellCommand),
    ..._each('buildConfigReadCommand', login,
        (v) => buildConfigReadCommand('/etc/$v.yaml')),
    ..._each(
        'buildConfigWriteScript',
        bash,
        (v) => buildConfigWriteScript(
            path: '/etc/$v.yaml', base64Content: 'aGFsbG8K')),
    ..._each(
        'buildServiceLogsCommand (container)',
        login,
        (v) =>
            buildServiceLogsCommand(id: 'evcc', detail: 'Docker · $v').command),
    ..._each('buildServiceLogsCommand (unit)', login,
        (v) => buildServiceLogsCommand(id: v, detail: '').command),
    for (final id in ['system', 'pihole', 'grafana', 'adguard', 'evcc'])
      _Script('buildServiceLogsCommand ($id)', login,
          buildServiceLogsCommand(id: id, detail: 'apt').command),
    _Script(
        'buildDetectBatch (three probes)',
        bash,
        buildDetectBatch(const [
          ('EVCC_V', versionQuery),
          ('STORAGE', systemStorageCommand),
          ('HA_VERSION', haVersionProbe),
        ])),
    _Script('buildDetectBatch (no probe)', bash, buildDetectBatch(const [])),
    const _Script('listBackupsCommand', login, listBackupsCommand, inner: 1),
    ..._each('buildRestoreScript', bash,
        (v) => buildRestoreScript('/var/backups/evcc/$v.tar.gz')),

    // ---- alerts.dart, auto_update.dart, scheduled_backup.dart -------------
    ..._each(
        'buildAlertsInstallScript',
        bash,
        (v) => buildAlertsInstallScript(
            ntfyServer: 'https://ntfy.example/$v', ntfyTopic: v)),
    _Script('buildAlertsRemoveScript', bash, buildAlertsRemoveScript()),
    ..._each(
        'buildTestAlertCommand',
        login,
        (v) => buildTestAlertCommand(
            ntfyServer: 'https://ntfy.example/$v', ntfyTopic: v)),
    const _Script('alertsStatusCommand', login, alertsStatusCommand),
    for (final weekly in [false, true])
      _Script(
          'buildAutoUpdateInstallScript (weekly: $weekly)',
          bash,
          buildAutoUpdateInstallScript(
              onCalendar: autoUpdateOnCalendar(weekly: weekly, hour: 4))),
    _Script('buildAutoUpdateRemoveScript', bash, buildAutoUpdateRemoveScript()),
    const _Script('autoUpdateStatusCommand', login, autoUpdateStatusCommand),
    for (final keep in [1, 7, 999])
      _Script(
          'buildScheduledBackupInstallScript (keep: $keep)',
          bash,
          buildScheduledBackupInstallScript(
              onCalendar: scheduledBackupOnCalendar(hour: 3), keep: keep)),
    _Script('buildScheduledBackupRemoveScript', bash,
        buildScheduledBackupRemoveScript()),
    const _Script(
        'scheduledBackupStatusCommand', login, scheduledBackupStatusCommand),

    // ---- security_check.dart ----------------------------------------------
    _Script('buildSecurityProbe', login, buildSecurityProbe(), inner: 1),
    for (final fix in SecurityFix.values)
      if (fix != SecurityFix.piholePassword)
        _Script('buildSecurityFixScript (${fix.name})', bash,
            buildSecurityFixScript(fix)),

    // ---- files.dart, storage_explorer.dart, ssh_keys.dart ------------------
    ..._each('buildListDirCommand', login,
        (v) => buildListDirCommand('/home/pi/$v')),
    ..._each('buildReadFileCommand', login,
        (v) => buildReadFileCommand('/home/pi/$v'),
        inner: 1),
    ..._each(
        'buildUploadScript',
        bash,
        (v) =>
            buildUploadScript(path: '/home/pi/$v', base64Content: 'aGFsbG8K')),
    ..._each('buildFileSizeCommand', login,
        (v) => buildFileSizeCommand('/var/backups/pi-tool/$v')),
    ..._each('buildDownloadFileCommand', login,
        (v) => buildDownloadFileCommand('/var/backups/pi-tool/$v')),
    for (final isDir in [false, true])
      ..._each('buildDeleteCommand (directory: $isDir)', login,
          (v) => buildDeleteCommand(path: '/home/pi/$v', isDir: isDir)),
    ..._each('buildStorageProbe', login, (v) => buildStorageProbe('/home/$v'),
        inner: 1),
    ..._each('buildInstallAuthorizedKeyScript', login,
        (v) => buildInstallAuthorizedKeyScript('ssh-ed25519 AAAA $v')),

    // ---- docker_containers.dart, systemd_services.dart ---------------------
    const _Script('dockerPsSudoCommand', login, dockerPsSudoCommand),
    ..._each('buildDockerRestartCommand', login, buildDockerRestartCommand),
    ..._each('buildDockerLogsCommand', login, buildDockerLogsCommand),
    ..._each('buildDockerRunningProbe', login, buildDockerRunningProbe),
    for (final svc in knownSystemdServices)
      _Script('systemdStateCommand (${svc.unit})', login,
          systemdStateCommand(svc.unit)),

    // ---- eol_sources.dart, pi_job.dart -------------------------------------
    const _Script('eolSourcesShellCommand', login, eolSourcesShellCommand),
    const _Script('eolSourcesFixScript', bash, eolSourcesFixScript),
    const _Script('jobBootstrap', bash, jobBootstrap),
    _Script('jobStartCommand', login, jobStartCommand(_id), inner: 1),
    _Script('jobFollowCommand', login, jobFollowCommand(_id), inner: 1),
    _Script('buildJobWrapperScript', bash, buildJobWrapperScript()),
    _Script('buildJobLauncherScript', bash, launcher),
    _Script('buildJobFollowerScript', bash, buildJobFollowerScript(id: _id)),
    _Script(
        'buildJobStartStdin (behind the sentinel)',
        bash,
        _behindSentinel(buildJobStartStdin(
            password: 'geheim',
            id: _id,
            kind: jobKindPiholeUpdate,
            payload: buildPiholeUpdatePayload()))),
    _Script('buildJobFollowStdin (behind the sentinel)', bash,
        _behindSentinel(buildJobFollowStdin(password: 'geheim', id: _id))),
    ..._each('buildJobPayload', bash, (v) => buildJobPayload('echo "$v"')),
    _Script('aptBuildingBlocks', bash, aptBuildingBlocks()),
    _Script('buildSystemUpgradePayload', bash, buildSystemUpgradePayload()),
    for (final full in [false, true])
      _Script('buildEvccUpdatePayload (full: $full)', bash,
          buildEvccUpdatePayload(fullUpgrade: full)),
    for (final package in ['grafana', 'influxdb2', 'libstdc++6'])
      _Script('buildPackageUpdatePayload ($package)', bash,
          buildPackageUpdatePayload(package)),
    _Script('buildPackageRepairPayload', bash, buildPackageRepairPayload()),
    _Script('buildPiholeUpdatePayload', bash, buildPiholeUpdatePayload()),
    const _Script('jobStatusProbe', login, jobStatusProbe),

    // ---- services/pihole_service.dart, services/system_service.dart --------
    const _Script('piholeVersionCommand', login, piholeVersionCommand),
    const _Script('piholeStatusCommand', login, piholeStatusCommand),
    const _Script('piholeUpdateCommand', login, piholeUpdateCommand),
    const _Script('piholeGravityCommand', login, piholeGravityCommand),
    const _Script('piholeRestartCommand', login, piholeRestartCommand,
        inner: 1),
    _Script('buildPiholeBackupScript', bash, buildPiholeBackupScript()),
    ..._each('buildPiholeRestoreScript', bash,
        (v) => buildPiholeRestoreScript('/var/backups/pi-tool/$v.zip')),
    _Script('buildPiholeRestoreScript (v5 archive)', bash,
        buildPiholeRestoreScript('/var/backups/pi-tool/a.tar.gz')),
    _Script('buildPiholeInstallScript', bash,
        buildPiholeInstallScript(webPassword: 'Abcdefgh23456789')),
    _Script('buildPiholeSetPasswordScript', bash,
        buildPiholeSetPasswordScript('Abcdefgh23456789')),
    const _Script('systemOsCommand', login, systemOsCommand),
    const _Script('systemPendingCommand', login, systemPendingCommand),
    const _Script('systemAptAgeCommand', login, systemAptAgeCommand),
    const _Script('systemAptRefreshCommand', login, systemAptRefreshCommand,
        inner: 1),
    const _Script('systemUptimeCommand', login, systemUptimeCommand),
    const _Script('systemTempCommand', login, systemTempCommand),
    const _Script('systemDiskCommand', login, systemDiskCommand),
    const _Script('systemMemCommand', login, systemMemCommand),
    const _Script('systemStorageCommand', login, systemStorageCommand),

    // ---- services/homeassistant_service.dart -------------------------------
    ..._each('buildHomeAssistantBackupScript', bash,
        (v) => buildHomeAssistantBackupScript('/opt/$v/config')),
    ..._each(
        'buildHomeAssistantRestoreScript',
        bash,
        (v) => buildHomeAssistantRestoreScript(
            archivePath: '/var/backups/pi-tool/$v.tar.gz',
            configPath: '/opt/$v/config',
            containerName: v)),
    _Script('buildHomeAssistantInstallScript', bash,
        buildHomeAssistantInstallScript()),
    for (final purge in [false, true])
      _Script('buildHomeAssistantUninstallScript (purge: $purge)', bash,
          buildHomeAssistantUninstallScript(purge: purge)),
    const _Script('haVersionProbe', login, haVersionProbe),

    // ---- services/apt_services.dart, services/stack_wiring.dart ------------
    for (final svc in knownAptServices) ...[
      if (svc.installScript != null)
        _Script('installScript (${svc.id})', bash, svc.installScript!),
      for (final purge in [false, true])
        _Script('buildAptServiceUninstallScript (${svc.id}, purge: $purge)',
            bash, buildAptServiceUninstallScript(svc, purge: purge)),
    ],
    for (final purge in [false, true])
      ..._each(
          'buildAptServiceUninstallScript (purge: $purge)',
          bash,
          (v) =>
              buildAptServiceUninstallScript(_aptService(v), purge: purge)),
    _Script('aptServicesQuery', login, aptServicesQuery),
    _Script('buildStackWiringScript', bash, buildStackWiringScript()),
    _Script('buildEvccInfluxUnwireScriptPart', bash,
        buildEvccInfluxUnwireScriptPart()),
    _Script('buildInfluxCliProfileCleanupScriptPart', bash,
        buildInfluxCliProfileCleanupScriptPart()),

    // ---- services/pi_connect.dart ------------------------------------------
    const _Script('piConnectStatusCommand', login, piConnectStatusCommand),
    const _Script('piConnectOnCommand', login, piConnectOnCommand),
    const _Script('piConnectOffCommand', login, piConnectOffCommand),
    const _Script('piConnectSignoutCommand', login, piConnectSignoutCommand),
    const _Script('piConnectSigninCommand', login, piConnectSigninCommand,
        inner: 1),
    const _Script('piConnectInstallScript', bash, piConnectInstallScript),
    for (final user in ['pi', 'stefan.g_1-x'])
      for (final purge in [false, true])
        _Script('buildPiConnectUninstallScript ($user, purge: $purge)', bash,
            buildPiConnectUninstallScript(user: user, purge: purge)),

    // ---- services/tailscale.dart -------------------------------------------
    const _Script('tailscaleInstallScript', bash, tailscaleInstallScript),
    _Script('tailscaleUpScript', bash, tailscaleUpScript),
    ..._each('buildTailscaleUpScript', bash,
        (v) => buildTailscaleUpScript(['--hostname=$v', v])),
    const _Script('tailscaleStatusCommand', login, tailscaleStatusCommand),
    const _Script('tailscaleDownCommand', login, tailscaleDownCommand),
    const _Script('tailscaleLogoutCommand', login, tailscaleLogoutCommand,
        inner: 1),
    const _Script('lanRoutesCommand', login, lanRoutesCommand),
    const _Script('tailscalePrefsCommand', login, tailscalePrefsCommand),
    const _Script('tailscaleSelfCommand', login, tailscaleSelfCommand),
    const _Script('tailscaleForwardingProbe', login, tailscaleForwardingProbe),
    const _Script('tailscaleSessionProbe', login, tailscaleSessionProbe),
    _Script('buildTailscaleAdvertiseScript (no route)', bash,
        buildTailscaleAdvertiseScript(const [])),
    _Script('buildTailscaleAdvertiseScript (no route, exit node)', bash,
        buildTailscaleAdvertiseScript(const [], keepForwarding: true)),
    _Script(
        'buildTailscaleAdvertiseScript (home network and a route by hand)',
        bash,
        buildTailscaleAdvertiseScript(
            const ['192.168.178.0/24', 'fd00:1::/64'],
            mine: const ['192.168.178.0/24'])),
    for (final purge in [false, true])
      _Script('buildTailscaleUninstallScript (purge: $purge)', bash,
          buildTailscaleUninstallScript(purge: purge)),
  ];
}

// ---- the shells ------------------------------------------------------------

/// bash and sh by absolute path, as [sandboxBash] names them.
final ({String bash, String sh}) _shells = () {
  final r =
      Process.runSync(sandboxBash!, ['-c', r'echo "$BASH"; command -v sh']);
  final lines = (r.stdout as String).trim().split('\n');
  if (r.exitCode != 0 || lines.length != 2) {
    throw StateError('shell probe: ${r.stdout}${r.stderr}');
  }
  return (bash: lines[0].trim(), sh: lines[1].trim());
}();

/// The shells that have to accept a text meant for [shell]. Under Git Bash
/// `sh` is a bash, which lets bashisms pass — hence dash where there is one.
List<String> _readers(_Shell shell) => switch (shell) {
      _Shell.bash => [_shells.bash],
      _Shell.sh => [_shells.sh, ?sandboxDash],
      _Shell.login => [_shells.bash, _shells.sh, ?sandboxDash],
    };

late Directory _tmp;
var _written = 0;

/// What the shells of [shell] object to in [text] — empty when each of them
/// parses it. `-n` on a file: read, never run.
String _objections(String text, _Shell shell) {
  final file = File('${_tmp.path}/${_written++}.sh')..writeAsStringSync(text);
  final r = Process.runSync(sandboxBash!, [
    '-c',
    r'f=$0; for s; do "$s" -n "$f" || echo "(says $s)" >&2; done',
    file.path.replaceAll(r'\', '/'),
    ..._readers(shell),
  ]);
  return '${r.stderr}'.trim();
}

// ---- the parts that are scripts of their own -------------------------------

/// The words of a command line as a shell splits them: quotes removed,
/// nothing expanded. [literal] is false for a word with a `$` or a backtick
/// outside single quotes — what it holds is decided by the shell that reads
/// the line.
List<({String text, bool literal})> _words(String line) {
  final words = <({String text, bool literal})>[];
  final word = StringBuffer();
  var open = false, literal = true;
  void end() {
    if (open) words.add((text: word.toString(), literal: literal));
    word.clear();
    open = false;
    literal = true;
  }

  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == "'") {
      final close = line.indexOf("'", i + 1);
      if (close < 0) throw FormatException('open single quote', line, i);
      word.write(line.substring(i + 1, close));
      open = true;
      i = close;
    } else if (c == '"') {
      open = true;
      for (i++;; i++) {
        if (i >= line.length) throw FormatException('open double quote', line);
        final d = line[i];
        if (d == '"') break;
        if (d == r'\' && i + 1 < line.length && r'$`"\'.contains(line[i + 1])) {
          word.write(line[++i]);
          continue;
        }
        if (d == r'$' || d == '`') literal = false;
        word.write(d);
      }
    } else if (c == r'\' && i + 1 < line.length) {
      word.write(line[++i]);
      open = true;
    } else if (c == ' ' || c == '\t' || c == '\n') {
      end();
    } else {
      if (c == r'$' || c == '`') literal = false;
      word.write(c);
      open = true;
    }
  }
  end();
  return words;
}

/// An argument of `sh -c` or `bash -c`.
typedef _Inner = ({bool bash, String text, bool literal});

/// The arguments of `sh -c` and `bash -c` in a command line.
List<_Inner> _inner(String line) {
  final w = _words(line);
  return [
    for (var i = 0; i + 2 < w.length; i++)
      if ((w[i].text == 'sh' || w[i].text == 'bash') && w[i + 1].text == '-c')
        (
          bash: w[i].text == 'bash',
          text: w[i + 2].text,
          literal: w[i + 2].literal
        ),
  ];
}

/// A heredoc opener with a quoted delimiter, and where its body goes:
/// `cat > /usr/local/lib/x.sh <<'WRAP'`.
final RegExp _heredocOpen = RegExp(r'''(>>?)\s*(\S+)\s*<<'(\w+)'\s*$''');

/// The files a script writes through heredocs: target (as written in the
/// script) to content, a `>>` appended to what a `>` began.
Map<String, String> _heredocFiles(String script) {
  final files = <String, String>{};
  final lines = script.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].contains('<<')) continue;
    final m = _heredocOpen.firstMatch(lines[i]);
    if (m == null) throw FormatException('heredoc not understood', lines[i]);
    final end = lines.indexOf(m[3]!, i + 1);
    if (end < 0) throw FormatException('heredoc without its end', lines[i]);
    final body = '${lines.sublist(i + 1, end).join('\n')}\n';
    files[m[2]!] = m[1] == '>>' ? '${files[m[2]!] ?? ''}$body' : body;
    i = end;
  }
  return files;
}

/// The files among [_heredocFiles] that are scripts, with their shebang.
Map<String, String> _shebangs(String script) => {
      for (final f in _heredocFiles(script).entries)
        if (f.value.startsWith('#!')) f.key: f.value.split('\n').first,
    };

/// The commands of the traps a script sets (`trap '…' EXIT`).
List<String> _traps(String script) => [
      for (final line in script.split('\n'))
        if (line.trimLeft().startsWith("trap '")) _words(line.trim())[1].text,
    ];

/// A `<<` followed by an unquoted word. What such a heredoc holds — a value
/// the builder put there included — is expanded by the root shell that runs
/// the script, so no script may open one.
final RegExp _unquotedHeredoc = RegExp(r'<<-?\s*[A-Za-z_]');

void _check(_Script s) {
  expect(_objections(s.text, s.shell), isEmpty, reason: s.text);

  final inner = s.shell == _Shell.login ? _inner(s.text) : const <_Inner>[];
  expect(inner, hasLength(s.inner), reason: s.text);
  for (final i in inner) {
    expect(i.literal, isTrue,
        reason: 'the login shell expands this before it is run: ${i.text}');
    expect(_objections(i.text, i.bash ? _Shell.bash : _Shell.sh), isEmpty,
        reason: i.text);
  }

  expect(_unquotedHeredoc.hasMatch(s.text), isFalse,
      reason: 'a heredoc with an unquoted delimiter');
  for (final file in _heredocFiles(s.text).entries) {
    if (!file.value.startsWith('#!')) continue;
    final shebang = file.value.split('\n').first;
    final shell = switch (shebang) {
      '#!/bin/sh' => _Shell.sh,
      '#!/bin/bash' => _Shell.bash,
      _ => null,
    };
    expect(shell, isNotNull, reason: '${file.key}: $shebang');
    expect(_objections(file.value, shell!), isEmpty,
        reason: '${file.key}\n${file.value}');
  }

  // bash reads the command of a trap when the trap fires — after the script
  // has done its work.
  final own = s.shell == _Shell.login ? _Shell.sh : s.shell;
  for (final command in _traps(s.text)) {
    expect(_objections(command, own), isEmpty, reason: command);
  }
}

/// An [SshRunner] that notes what it is asked to run and answers nothing.
class _Recorder implements SshRunner {
  final sent = <({String command, String? stdin})>[];

  @override
  Future<void> connect() async {}

  @override
  Future<CommandResult> run(String command,
      {String? stdin, void Function(String chunk)? onOutput}) async {
    sent.add((command: command, stdin: stdin));
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<void> close() async {}
}

const _config =
    SshConfig(host: 'pi.invalid', port: 22, username: 'pi', password: 'geheim');

void main() {
  final scripts = _scripts();

  setUpAll(() {
    if (sandboxBash != null) {
      _tmp = Directory.systemTemp.createTempSync('pitool-syntax');
    }
  });
  tearDownAll(() {
    if (sandboxBash != null) _tmp.deleteSync(recursive: true);
  });

  group('read by its shell', () {
    for (final s in scripts) {
      test(s.name, () => _check(s));
    }
  }, skip: needsBash);

  group('the check itself', () {
    test('a text no shell can read is objected to by every one of them', () {
      for (final shell in _Shell.values) {
        final said = _objections('if true; then\necho "offen\n', shell);
        expect('(says '.allMatches(said), hasLength(_readers(shell).length),
            reason: said);
      }
    });

    test('dash objects to what only a bash reads', () {
      expect(_objections('pkgs=(a b)\n', _Shell.bash), isEmpty);
      expect(_objections('pkgs=(a b)\n', _Shell.sh), contains(sandboxDash!));
    }, skip: needsDash);
  }, skip: needsBash);

  group('the parts that are scripts of their own', () {
    test('words are split the way a shell does it', () {
      expect(
          [
            for (final w in _words(
                "LC_ALL=C sudo -S -p '' sh -c 'a '\\''b c'\\'' \$d' x\\ y "
                '"e \\" \\\$f" "\$g"'))
              (w.text, w.literal)
          ],
          [
            ('LC_ALL=C', true),
            ('sudo', true),
            ('-S', true),
            ('-p', true),
            ('', true),
            ('sh', true),
            ('-c', true),
            ("a 'b c' \$d", true),
            ('x y', true),
            ('e " \$f', true),
            ('\$g', false),
          ]);
    });

    test('the arguments of sh -c and bash -c are found', () {
      expect(_inner(rebootCommand).single.text, '$jobPowerGuard; exec reboot');
      expect(_inner(rebootCommand).single.bash, isFalse);
      expect(_inner(jobStartCommand(_id)).single,
          (bash: true, text: jobBootstrap, literal: true));
      // The path arrives as an argument, not as part of the script.
      final read = _inner(buildReadFileCommand("/home/pi/it's here")).single;
      expect(read.text,
          'set -o pipefail; head -c $kFilePreviewLimit -- "\$1" | base64');
      final probe = _inner(buildStorageProbe("/home/it's")).single.text;
      expect(probe, startsWith("echo __DU__; du -x -b -d1 '/home/it'\\''s' "));
    });

    test('the wrappers the install scripts write are found, by their shebang',
        () {
      expect(
          _shebangs(buildAlertsInstallScript(
              ntfyServer: 'https://ntfy.sh', ntfyTopic: 'pi')),
          {'/usr/local/lib/$alertsUnit.sh': '#!/bin/sh'});
      expect(
          _shebangs(buildAutoUpdateInstallScript(
              onCalendar: autoUpdateOnCalendar(weekly: false, hour: 4))),
          {'/usr/local/lib/$autoUpdateUnit.sh': '#!/bin/bash'});
      expect(
          _shebangs(buildScheduledBackupInstallScript(
              onCalendar: scheduledBackupOnCalendar(hour: 3), keep: 7)),
          {'/usr/local/lib/$scheduledBackupUnit.sh': '#!/bin/sh'});
      expect(
          _shebangs(buildJobLauncherScript(
              id: _id, kind: jobKindPiholeUpdate, payload: 'true')),
          {r'"$d/run.sh"': '#!/bin/bash'});
    });

    test('the alerts wrapper is put together from both of its heredocs', () {
      final script = buildAlertsInstallScript(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: 'pi');
      expect(
          _heredocFiles(script)['/usr/local/lib/$alertsUnit.sh'],
          '${heredocBody(script, 'WRAP')}\n'
          '${heredocBody(script, 'WRAP', 2)}\n');
    });

    test('the commands of the traps are found', () {
      expect(_traps(buildRestoreScript('/var/backups/evcc/a.tar.gz')),
          ['systemctl start evcc >/dev/null 2>&1 || true']);
      expect(
          _traps(buildUploadScript(path: '/home/pi/a', base64Content: 'YQ==')),
          [r'rm -f "$tmp"']);
    });
  });

  group('further parts that a shell reads', () {
    test('the destination file the alerts wrapper sources', () {
      for (final (tag, v) in _values) {
        final script = buildAlertsInstallScript(
            ntfyServer: 'https://ntfy.example/$v', ntfyTopic: v);
        final conf = _heredocFiles(script)[alertsDestinationPath]!;
        expect(conf.split('\n'), hasLength(3), reason: tag);
        expect(_objections(conf, _Shell.sh), isEmpty, reason: '$tag\n$conf');
      }
    });

    test('the command tar runs at each checkpoint', () {
      const option = '--checkpoint-action=exec=';
      for (final script in [
        buildHomeAssistantBackupScript('/opt/homeassistant/config'),
        buildHomeAssistantRestoreScript(
            archivePath: '/var/backups/pi-tool/a.tar.gz',
            configPath: '/opt/homeassistant/config',
            containerName: 'homeassistant'),
      ]) {
        final tar = script.split('\n').singleWhere((l) => l.contains(option));
        final exec = _words(tar)
            .singleWhere((w) => w.text.startsWith(option))
            .text
            .substring(option.length);
        expect(exec, startsWith('echo "Home Assistant: '));
        expect(_objections(exec, _Shell.sh), isEmpty, reason: exec);
      }
    });
  }, skip: needsBash);

  // Lines the updater puts together itself, taken from what it sends.
  group('what the updater sends', () {
    late _Recorder runner;
    late EvccUpdater updater;

    setUp(() {
      runner = _Recorder();
      updater = EvccUpdater(runnerFactory: (_) => runner);
    });

    test('the detection batch, with every probe of the app', () async {
      try {
        await updater.detectServices(config: _config, onLog: (_) {});
      } on EvccUpdateException {
        // No answer, so no end marker: the detection ends as "unknown". What
        // it sent is what counts here.
      }
      final batch =
          runner.sent.singleWhere((s) => s.command == detectShellCommand);
      final probes = batch.stdin!.split('\n').where((l) => l.startsWith('{ '));
      expect(probes.length, greaterThan(20));
      for (final probe in [
        versionQuery,
        haVersionProbe,
        jobStatusProbe,
        systemdStateCommand(knownSystemdServices.last.unit),
      ]) {
        expect(probes.where((l) => l.contains(probe)), hasLength(1));
      }
      _check(_Script('detection batch', _Shell.bash, batch.stdin!));
    });

    test('the restart of a systemd unit', () async {
      for (final (_, unit) in _values) {
        await updater.restartSystemdUnit(
            config: _config, unit: unit, onLog: (_) {});
        _check(_Script('restart', _Shell.login, runner.sent.last.command));
      }
    });

    test('the wrapper around a console command', () async {
      for (final command in ['echo hi # Kommentar', 'true &', 'sudo ls;']) {
        await updater.runConsoleCommand(
            config: _config, command: command, onLog: (_) {});
        _check(_Script('console', _Shell.login, runner.sent.last.command));
      }
    });
  }, skip: needsBash);

  // A builder that is added to lib/src and not to the table above would go to
  // a Pi without ever having been read by a shell.
  test('every script builder and command constant of lib/src is in the table',
      () {
    final declared = <String>{};
    final declaration = RegExp(
        r'^(?:(?:const|final) String|String|List<SshStep>|\(\{[^)]*\}\)) '
        r'(\w+)(?: =|\()',
        multiLine: true);
    final shellName = RegExp(r'(Command|Script|ScriptPart|Probe|Payload|Query|'
        r'Batch|Exec|Stdin|Steps|Guard|Bootstrap|Blocks)$');
    for (final file in Directory('lib/src')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      for (final m in declaration.allMatches(file.readAsStringSync())) {
        final name = m[1]!;
        if (!name.startsWith('_') && shellName.hasMatch(name)) {
          declared.add(name);
        }
      }
    }
    // The scan finds what it is meant to find …
    expect(
        declared,
        containsAll([
          'versionQuery',
          'aptServicesQuery',
          'jobPowerGuard',
          'jobBootstrap',
          'buildConsoleExec',
          'buildUpdateSteps',
          'buildRestoreScript',
          'piConnectInstallScript',
          'tailscaleUpScript',
        ]));
    // … and all of it is in the table (an install script of an apt service is
    // a field, listed there as `installScript`).
    final covered = {for (final s in scripts) s.name.split(' ').first};
    expect(declared.difference(covered), isEmpty,
        reason: 'add them to _scripts() in test/script_syntax_test.dart');
  });
}
