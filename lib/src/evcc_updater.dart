import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'alerts.dart';
import 'auto_update.dart';
import 'commands.dart';
import 'files.dart';
import 'dartssh2_runner.dart';
import 'host_key.dart';
import 'parsing.dart';
import 'services/apt_services.dart';
import 'services/homeassistant_service.dart';
import 'services/pi_service.dart';
import 'services/pihole_service.dart';
import 'services/system_service.dart';
import 'settings_store.dart';
import 'ssh_runner.dart';

/// Categories of failure surfaced to the user with a clear message.
enum UpdateErrorKind {
  connection,
  auth,
  sudo,
  serviceInactive,
  packageMissing,
  hostKeyChanged,
  cancelled,
  unknown,
}

/// A failure during the update, carrying a user-facing German [message].
class EvccUpdateException implements Exception {
  final UpdateErrorKind kind;
  final String message;

  const EvccUpdateException(this.kind, this.message);

  @override
  String toString() => 'EvccUpdateException($kind): $message';
}

/// Result of a successful evcc installation.
class InstallResult {
  final String version;
  final bool serviceActive;

  const InstallResult({required this.version, required this.serviceActive});
}

/// How evcc is installed on a given Pi, with the facts needed to update it.
class InstallDetection {
  final InstallKind kind;

  /// apt: the installed package version + service state.
  final String? aptVersion;
  final bool serviceActive;

  /// docker: the running evcc container, and whether docker needs sudo here.
  final EvccDocker? container;
  final bool dockerNeedsSudo;

  const InstallDetection({
    required this.kind,
    this.aptVersion,
    this.serviceActive = false,
    this.container,
    this.dockerNeedsSudo = false,
  });
}

/// Builds the [SshRunner] for a given config (injected so tests can fake SSH).
typedef SshRunnerFactory = SshRunner Function(SshConfig config);

/// Orchestrates the validated evcc update sequence over SSH.
class EvccUpdater {
  final SshRunnerFactory runnerFactory;

  /// Used by [forgetHostKey] to re-trust a changed host key. The same store
  /// instance is wired into the real runner so reads/writes stay consistent.
  final HostKeyStore? hostKeyStore;

  EvccUpdater({required this.runnerFactory, this.hostKeyStore});

  /// The connection of the action currently in flight, so [cancel] can close
  /// it. Set in [_withConnection]; null between actions. Actions are serialized
  /// by the UI (one at a time), so a single handle is enough.
  SshRunner? _active;
  bool _cancelRequested = false;

  /// Cancels the in-flight SSH action by closing its connection. The running
  /// action then completes with [UpdateErrorKind.cancelled]. No-op when idle.
  Future<void> cancel() async {
    _cancelRequested = true;
    try {
      await _active?.close();
    } catch (_) {
      // Best-effort: closing a half-open connection may itself throw.
    }
  }

  /// Production updater backed by the real dartssh2 adapter.
  /// [confirmFirstUse] is called on the first connection to a host with the
  /// presented SHA256 fingerprint; return true to trust + proceed, false to
  /// abort. When null, first use is trusted automatically (legacy TOFU).
  factory EvccUpdater.real({
    Future<bool> Function(String fingerprint)? confirmFirstUse,
  }) {
    final store = SecureHostKeyStore();
    return EvccUpdater(
      runnerFactory: (config) => Dartssh2Runner(config,
          hostKeyStore: store, confirmFirstUse: confirmFirstUse),
      hostKeyStore: store,
    );
  }

  /// Forgets the trusted host key for [config] so the next connect re-trusts
  /// (TOFU) the current key. Use after the user confirms a changed key is legit.
  Future<void> forgetHostKey(SshConfig config) async {
    await hostKeyStore?.remove(hostKeyId(config.host, config.port));
  }

  /// Runs the update (or a dry-run probe) and returns a result summary.
  ///
  /// Streams every command and its output to [onLog] (with the password
  /// redacted). Throws [EvccUpdateException] on any failure.
  Future<UpdateSummary> run({
    required SshConfig config,
    required bool fullUpgrade,
    required bool dryRun,
    required void Function(String line) onLog,
  }) {
    return _withConnection<UpdateSummary>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Verbunden. Starte ${dryRun ? 'Probelauf' : 'Update'} …');

        final steps = buildUpdateSteps(fullUpgrade: fullUpgrade, dryRun: dryRun);
        String? before;
        String? after;
        var upgradeOutput = '';

        for (var i = 0; i < steps.length; i++) {
          final step = steps[i];
          log('\$ ${step.command}');

          final result = await runner.run(
            step.command,
            stdin: step.needsSudoPassword ? '${config.password}\n' : null,
            onOutput: (chunk) {
              final trimmed = chunk.trimRight();
              if (trimmed.isNotEmpty) log(trimmed);
            },
          );
          final combined = '${result.stdout}\n${result.stderr}';

          if (step.needsSudoPassword && isSudoPasswordFailure(combined)) {
            throw const EvccUpdateException(
              UpdateErrorKind.sudo,
              'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
            );
          }

          // A non-zero UPGRADE step (held dpkg lock, full disk, broken deps)
          // must be a hard error — otherwise version-before == version-after and
          // the run is falsely reported as "already current". Scoped to the
          // upgrade step (i == 2): `apt-get update` (i == 1) can legitimately
          // exit non-zero when an unrelated third-party repo is unreachable, and
          // that must not block an otherwise-fine evcc upgrade.
          if (i == 2 && result.exitCode != null && result.exitCode != 0) {
            throw EvccUpdateException(
              UpdateErrorKind.unknown,
              '${step.label} fehlgeschlagen (Exit ${result.exitCode}). '
              'Details im Log.',
            );
          }

          switch (i) {
            case 0:
              before = parseInstalledVersion(result.stdout);
              if (before == null) {
                throw const EvccUpdateException(
                  UpdateErrorKind.packageMissing,
                  'evcc ist auf dem Pi nicht installiert (apt-Paket fehlt).',
                );
              }
            case 2:
              upgradeOutput = combined;
            case 3:
              if (!dryRun && !isServiceActive(result.stdout)) {
                throw const EvccUpdateException(
                  UpdateErrorKind.serviceInactive,
                  'evcc-Dienst ist nach dem Update nicht aktiv '
                  '(systemctl is-active ≠ active).',
                );
              }
            case 4:
              after = parseInstalledVersion(result.stdout);
          }
        }

        final summary = summarize(
          before: before,
          after: after,
          dryRun: dryRun,
          fullUpgrade: fullUpgrade,
          alreadyNewest: isAlreadyNewest(upgradeOutput),
        );
        log(summary.message);
        return summary;
      },
    );
  }

  /// Installs evcc on a freshly-configured Pi: adds the official apt repo,
  /// installs the package and enables the service — all as root via one
  /// `sudo -S bash -s` call (password fed as the first stdin line, never on the
  /// command line). Then verifies the installed version and service state.
  ///
  /// Experimental: built from evcc's official docs but not validated against a
  /// fresh Pi end-to-end. Throws [EvccUpdateException] on failure.
  Future<InstallResult> install({
    required SshConfig config,
    required void Function(String line) onLog,
    String channel = 'stable',
  }) {
    return _withConnection<InstallResult>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Installiere evcc … (Repo einrichten + Paket installieren, '
            'das dauert ein paar Minuten)');

        final result = await runner.run(
          installShellCommand,
          stdin: '${config.password}\n${buildInstallScript(channel: channel)}\n',
          onOutput: (chunk) {
            final trimmed = chunk.trimRight();
            if (trimmed.isNotEmpty) log(trimmed);
          },
        );
        final combined = '${result.stdout}\n${result.stderr}';

        if (isSudoPasswordFailure(combined)) {
          throw const EvccUpdateException(
            UpdateErrorKind.sudo,
            'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
          );
        }
        if (result.exitCode != null && result.exitCode != 0) {
          throw EvccUpdateException(
            UpdateErrorKind.unknown,
            'Installation fehlgeschlagen (Exit ${result.exitCode}). '
            'Details im Log.',
          );
        }

        final versionResult = await runner.run(versionQuery);
        final version = parseInstalledVersion(versionResult.stdout);
        if (version == null) {
          throw const EvccUpdateException(
            UpdateErrorKind.packageMissing,
            'Installation lief durch, aber evcc ist nicht auffindbar.',
          );
        }

        final serviceResult = await runner.run(serviceStatus);
        final active = isServiceActive(serviceResult.stdout);

        log('evcc $version installiert, Dienst ${active ? 'aktiv' : 'inaktiv'}.');
        return InstallResult(version: version, serviceActive: active);
      },
    );
  }

  /// Detects how evcc is installed on the Pi (apt package, Docker container, or
  /// neither) using only read-only probes. Used to pick the right update path.
  ///
  /// apt wins when the package is present. Otherwise it lists running
  /// containers — first without sudo, then via `sudo -S docker ps` if the
  /// daemon denies access — and reports a Docker install when an evcc container
  /// is running. Nothing is changed.
  Future<InstallDetection> detectInstall({
    required SshConfig config,
    required void Function(String line) onLog,
    bool allowSudoForDocker = true,
  }) {
    return _withConnection<InstallDetection>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Erkenne Installationsart …');

        final dpkg = await runner.run(versionQuery);
        final aptVersion = parseInstalledVersion(dpkg.stdout);
        if (aptVersion != null) {
          final svc = await runner.run(serviceStatus);
          log('Gefunden: evcc $aptVersion als apt-Paket.');
          return InstallDetection(
            kind: InstallKind.apt,
            aptVersion: aptVersion,
            serviceActive: isServiceActive(svc.stdout),
          );
        }

        // No apt package — look for a running evcc Docker container.
        var listing = await runner.run(dockerListCommand);
        var needsSudo = false;
        // Retry via sudo only when explicitly allowed — the silent launch check
        // must never send the sudo password without a user action.
        if (allowSudoForDocker &&
            isDockerPermissionError('${listing.stdout}\n${listing.stderr}')) {
          needsSudo = true;
          listing = await runner.run(
            dockerListSudoCommand,
            stdin: '${config.password}\n',
          );
          if (isSudoPasswordFailure('${listing.stdout}\n${listing.stderr}')) {
            throw const EvccUpdateException(
              UpdateErrorKind.sudo,
              'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
            );
          }
        }

        final container = parseEvccDocker(listing.stdout);
        if (container != null) {
          log('Gefunden: evcc im Docker-Container "${container.name}".');
          return InstallDetection(
            kind: InstallKind.docker,
            container: container,
            dockerNeedsSudo: needsSudo,
          );
        }

        log('Weder ein evcc-apt-Paket noch ein evcc-Docker-Container gefunden.');
        return const InstallDetection(kind: InstallKind.unknown);
      },
    );
  }

  /// Detects ALL known services (evcc, Pi-hole, System) in one SSH session and
  /// returns their status for the service cards. Read-only; never sends the sudo
  /// password unless [allowSudoForDocker] permits the docker-permission retry.
  Future<List<ServiceStatus>> detectServices({
    required SshConfig config,
    required void Function(String line) onLog,
    bool allowSudoForDocker = true,
    void Function()? onConnected, // fired after connect, before the probes
  }) {
    return _withConnection<List<ServiceStatus>>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        onConnected?.call(); // progressive UI: "Verbunden" before the probes
        log('Erkenne Dienste …');
        final out = <ServiceStatus>[];

        // ONE round-trip for every read-only probe (was ~13 sequential calls —
        // slow over high-latency links like Tailscale). is-active for ALL known
        // apt-service units is cheap, so probe them all here too.
        final units = knownAptServices.map((s) => s.unit).toList();
        final probes = <(String, String)>[
          ('DOCKER', dockerListCommand),
          ('PENDING', systemPendingCommand),
          ('EVCC_V', versionQuery),
          ('EVCC_SVC', serviceStatus),
          ('PIHOLE_V', piholeVersionCommand),
          ('PIHOLE_S', piholeStatusCommand),
          ('HA_VERSION', haVersionProbe),
          ('APTSVC', aptServicesQuery),
          for (final u in units) ('UNIT:$u', 'systemctl is-active $u'),
          ('OS', systemOsCommand),
          ('TEMP', systemTempCommand),
          ('DISK', systemDiskCommand),
          ('MEM', systemMemCommand),
          ('UPTIME', systemUptimeCommand),
        ];
        final batch = await runner.run(detectShellCommand,
            stdin: '${buildDetectBatch(probes)}\n');
        final sec = splitDetectSections(batch.stdout);

        // ---- Docker (shared by evcc-docker + Home Assistant) ----
        // sudo retry only if the daemon denied access and it's allowed.
        var dockerPs = sec['DOCKER'] ?? '';
        if (allowSudoForDocker && isDockerPermissionError(dockerPs)) {
          final sd = await runner.run(dockerListSudoCommand,
              stdin: '${config.password}\n');
          if (isSudoPasswordFailure('${sd.stdout}\n${sd.stderr}')) {
            log('sudo-Passwort abgelehnt – Docker-Dienste konnten nicht '
                'erkannt werden.');
          }
          dockerPs = sd.stdout;
        }

        // ---- pending apt upgrades (shared by evcc-apt + System) ----
        // Simulated full-upgrade: pending count + which packages have an update
        // in the local index. Trust it (updateKnown) only when it parsed.
        final pending = parsePendingUpdates(sec['PENDING'] ?? '');
        final aptKnown = pending != null;
        final pendingCount = pending ?? 0;
        final aptUpgrades = parseAptUpgrades(sec['PENDING'] ?? '');

        // ---- evcc (apt or docker) ----
        final aptV = parseInstalledVersion(sec['EVCC_V'] ?? '');
        if (aptV != null) {
          final active = isServiceActive(sec['EVCC_SVC'] ?? '');
          out.add(ServiceStatus(
            id: 'evcc',
            name: 'evcc',
            installed: true,
            version: aptV,
            active: active,
            updateAvailable:
                aptUpgrades.any((p) => p == 'evcc' || p.startsWith('evcc:')),
            updateKnown: aptKnown,
            detail: 'apt · Dienst ${active ? 'aktiv' : 'inaktiv'}',
          ));
        } else {
          final c = parseEvccDocker(dockerPs);
          out.add(c != null
              ? ServiceStatus(
                  id: 'evcc',
                  name: 'evcc',
                  installed: true,
                  version: c.image,
                  active: true,
                  detail: 'Docker · ${c.name}')
              : ServiceStatus.absent('evcc', 'evcc'));
        }

        // ---- Pi-hole ----
        final pver = parsePiholeVersion(sec['PIHOLE_V'] ?? '');
        if (pver != null) {
          final blocking = isPiholeBlocking(sec['PIHOLE_S'] ?? '');
          out.add(ServiceStatus(
            id: 'pihole',
            name: 'Pi-hole',
            installed: true,
            version: pver.version,
            active: blocking,
            updateAvailable: pver.updateAvailable,
            updateKnown: pver.latestKnown,
            detail: blocking ? 'Blocking aktiv' : 'Blocking aus',
          ));
        } else {
          out.add(ServiceStatus.absent('pihole', 'Pi-hole'));
        }

        // ---- Home Assistant (Docker container) ----
        // Prefer the REAL version from /config/.HA_VERSION over the image tag
        // ("stable" isn't comparable) so currency can be reconciled vs GitHub.
        final ha = parseHomeAssistant(dockerPs);
        final haRealVersion = parseHaVersion(sec['HA_VERSION'] ?? '');
        out.add(ha != null
            ? ServiceStatus(
                id: 'homeassistant',
                name: 'Home Assistant',
                installed: true,
                version: haRealVersion ?? ha.version,
                active: true,
                detail: 'Docker · ${ha.name}')
            : ServiceStatus.absent('homeassistant', 'Home Assistant'));

        // ---- extra apt services (Grafana, InfluxDB, …) ----
        final extraVersions = parseAptServiceVersions(sec['APTSVC'] ?? '');
        for (final svc in knownAptServices) {
          final pkg = svc.packages
              .firstWhere(extraVersions.containsKey, orElse: () => '');
          if (pkg.isEmpty) continue;
          final active = isServiceActive(sec['UNIT:${svc.unit}'] ?? '');
          out.add(ServiceStatus(
            id: svc.id,
            name: svc.name,
            installed: true,
            version: extraVersions[pkg],
            active: active,
            updateAvailable:
                aptUpgrades.any((u) => u == pkg || u.startsWith('$pkg:')),
            updateKnown: aptKnown,
            detail: 'apt · $pkg · Dienst ${active ? 'aktiv' : 'inaktiv'}',
            webPort: (svc.id == 'influxdb' && pkg != 'influxdb2')
                ? null
                : svc.webPort,
            aptPackage: pkg,
          ));
        }

        // ---- System (always present) ----
        final health = SystemHealth(
          tempC: parseTemperatureC(sec['TEMP'] ?? ''),
          disk: parseDiskUsage(sec['DISK'] ?? ''),
          memAvailableMb: parseMemAvailableMb(sec['MEM'] ?? ''),
          uptime: (sec['UPTIME'] ?? '').trim(),
        );
        out.add(ServiceStatus(
          id: 'system',
          name: 'System (Pi)',
          installed: true,
          version: parseOsPrettyName(sec['OS'] ?? ''),
          active: true,
          updateAvailable: pendingCount > 0,
          updateKnown: aptKnown,
          detail: pendingCount > 0 ? '$pendingCount Updates verfügbar' : 'aktuell',
          health: health.summary,
          healthWarning: health.lowDisk,
        ));

        log('Erkannt: ${out.where((s) => s.installed).map((s) => s.name).join(', ')}.');
        return out;
      },
    );
  }

  /// Runs one sudo command, streaming output; maps a rejected password / non-zero
  /// exit to a clear [EvccUpdateException]. Used by the Pi-hole + System actions.
  Future<void> _sudoCommand(
    SshRunner runner,
    void Function(String) log,
    SshConfig config,
    String command,
    String failMsg, {
    bool checkExit = true,
  }) async {
    log('\$ $command');
    final r = await runner.run(
      command,
      stdin: '${config.password}\n',
      onOutput: (c) {
        final t = c.trimRight();
        if (t.isNotEmpty) log(t);
      },
    );
    final combined = '${r.stdout}\n${r.stderr}';
    if (isSudoPasswordFailure(combined)) {
      throw const EvccUpdateException(
        UpdateErrorKind.sudo,
        'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
      );
    }
    if (checkExit && r.exitCode != null && r.exitCode != 0) {
      throw EvccUpdateException(
        UpdateErrorKind.unknown,
        '$failMsg (Exit ${r.exitCode}). Details im Log.',
      );
    }
  }

  /// Updates Pi-hole (core/web/FTL) via `pihole -up`.
  Future<void> updatePihole({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Aktualisiere Pi-hole …');
          await _sudoCommand(runner, log, config, piholeUpdateCommand,
              'Pi-hole-Update fehlgeschlagen');
          log('Pi-hole ist aktuell.');
        },
      );

  /// Rebuilds the Pi-hole blocklists (gravity).
  Future<void> updatePiholeGravity({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Aktualisiere Blocklisten (gravity) …');
          await _sudoCommand(runner, log, config, piholeGravityCommand,
              'Gravity-Update fehlgeschlagen');
          log('Blocklisten aktualisiert.');
        },
      );

  /// Restarts the Pi-hole DNS resolver.
  Future<void> restartPiholeDns({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          await _sudoCommand(runner, log, config, piholeRestartCommand,
              'DNS-Neustart fehlgeschlagen');
          log('Pi-hole-DNS neu gestartet.');
        },
      );

  /// Exports a Pi-hole Teleporter backup on the Pi. Returns the archive path.
  Future<String> backupPihole({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<String>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Sichere Pi-hole (Teleporter) …');
          final path = await _runRootScriptCapturing(runner, log, config,
              script: buildPiholeBackupScript(),
              failMsg: 'Pi-hole-Backup fehlgeschlagen');
          log('Backup gespeichert: $path');
          return path;
        },
      );

  /// Backs up the Home Assistant config directory (tar). Returns the path.
  Future<String> backupHomeAssistant({
    required SshConfig config,
    required void Function(String line) onLog,
  }) {
    return _withConnection<String>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        // Locate the container + its /config bind source (docker may need sudo).
        var listing = await runner.run(dockerListCommand);
        var sudo = false;
        if (isDockerPermissionError('${listing.stdout}\n${listing.stderr}')) {
          sudo = true;
          listing = await runner.run(dockerListSudoCommand,
              stdin: '${config.password}\n');
          if (isSudoPasswordFailure('${listing.stdout}\n${listing.stderr}')) {
            throw const EvccUpdateException(UpdateErrorKind.sudo,
                'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
          }
        }
        final ha = parseHomeAssistant(listing.stdout);
        if (ha == null) {
          throw const EvccUpdateException(
              UpdateErrorKind.unknown, 'Kein Home-Assistant-Container gefunden.');
        }
        final inspectCmd = sudo
            ? dockerInspectJsonSudoCommand(ha.name)
            : dockerInspectJsonCommand(ha.name);
        final inspect = await runner.run(inspectCmd,
            stdin: sudo ? '${config.password}\n' : null);
        if (sudo &&
            isSudoPasswordFailure('${inspect.stdout}\n${inspect.stderr}')) {
          throw const EvccUpdateException(UpdateErrorKind.sudo,
              'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
        }
        final cfg = homeAssistantConfigPath(inspect.stdout);
        if (cfg == null) {
          throw const EvccUpdateException(UpdateErrorKind.unknown,
              'Konnte das /config-Verzeichnis nicht ermitteln.');
        }
        log('Sichere Home Assistant (/config: $cfg) …');
        final path = await _runRootScriptCapturing(runner, log, config,
            script: buildHomeAssistantBackupScript(cfg),
            failMsg: 'Home-Assistant-Backup fehlgeschlagen');
        log('Backup gespeichert: $path');
        return path;
      },
    );
  }

  /// Lists one service's backups under /var/backups/pi-tool (newest first).
  Future<List<String>> listServiceBackups({
    required SshConfig config,
    required String servicePrefix,
    required void Function(String line) onLog,
  }) =>
      _withConnection<List<String>>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          final r = await runner.run(serviceBackupListCommand(servicePrefix));
          return parseServiceBackupList(r.stdout);
        },
      );

  /// Deletes one backup archive (root owns the backup dir → sudo).
  Future<void> deleteServiceBackup({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) => _sudoCommand(runner, log, config,
            serviceBackupDeleteCommand(path), 'Löschen fehlgeschlagen'),
      );

  /// Restores a Pi-hole Teleporter backup. Only v6 `.zip` archives can be
  /// imported via CLI — a v5 `.tar.gz` is refused with a clear message (its
  /// import exists only in the web UI).
  Future<void> restorePiholeBackup({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) async {
    if (!path.endsWith('.zip')) {
      throw const EvccUpdateException(
        UpdateErrorKind.unknown,
        'Dieses Backup stammt von Pi-hole v5 (.tar.gz) und kann nur über die '
        'Web-Oberfläche importiert werden (Einstellungen → Teleporter).',
      );
    }
    await _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Stelle Pi-hole-Backup wieder her …');
        await _runRootScriptExpectMarker(runner, log, config,
            script: buildPiholeRestoreScript(path),
            successMarker: 'RESTORE_OK',
            failMsg: 'Pi-hole-Wiederherstellung fehlgeschlagen');
        log('Pi-hole wiederhergestellt.');
      },
    );
  }

  /// Restores a Home Assistant config backup: stop container → extract the tar
  /// into /config → start (the start is trap-guaranteed). The container + its
  /// /config path are discovered like in [backupHomeAssistant].
  Future<void> restoreHomeAssistantBackup({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) {
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        var listing = await runner.run(dockerListCommand);
        var sudo = false;
        if (isDockerPermissionError('${listing.stdout}\n${listing.stderr}')) {
          sudo = true;
          listing = await runner.run(dockerListSudoCommand,
              stdin: '${config.password}\n');
          if (isSudoPasswordFailure('${listing.stdout}\n${listing.stderr}')) {
            throw const EvccUpdateException(UpdateErrorKind.sudo,
                'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
          }
        }
        final ha = parseHomeAssistant(listing.stdout);
        if (ha == null) {
          throw const EvccUpdateException(
              UpdateErrorKind.unknown, 'Kein Home-Assistant-Container gefunden.');
        }
        final inspectCmd = sudo
            ? dockerInspectJsonSudoCommand(ha.name)
            : dockerInspectJsonCommand(ha.name);
        final inspect = await runner.run(inspectCmd,
            stdin: sudo ? '${config.password}\n' : null);
        if (sudo &&
            isSudoPasswordFailure('${inspect.stdout}\n${inspect.stderr}')) {
          throw const EvccUpdateException(UpdateErrorKind.sudo,
              'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
        }
        final cfg = homeAssistantConfigPath(inspect.stdout);
        if (cfg == null) {
          throw const EvccUpdateException(UpdateErrorKind.unknown,
              'Konnte das /config-Verzeichnis nicht ermitteln.');
        }
        log('Stelle Home-Assistant-Backup wieder her (/config: $cfg) …');
        await _runRootScriptExpectMarker(runner, log, config,
            script: buildHomeAssistantRestoreScript(
                archivePath: path, configPath: cfg, containerName: ha.name),
            successMarker: 'RESTORE_OK',
            failMsg: 'Home-Assistant-Wiederherstellung fehlgeschlagen');
        log('Home Assistant wiederhergestellt.');
      },
    );
  }

  /// Installs the on-Pi systemd timer for scheduled automatic updates
  /// ([onCalendar] from [autoUpdateOnCalendar]). Runs as root.
  Future<void> enableAutoUpdate({
    required SshConfig config,
    required String onCalendar,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Richte automatische Updates ein …');
          await _runRootScriptExpectMarker(runner, log, config,
              script: buildAutoUpdateInstallScript(onCalendar: onCalendar),
              successMarker: 'AUTOUPDATE_INSTALLED',
              failMsg: 'Einrichten der automatischen Updates fehlgeschlagen');
        },
      );

  /// Removes the scheduled-update timer again. Runs as root.
  Future<void> disableAutoUpdate({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Deaktiviere automatische Updates …');
          await _runRootScriptExpectMarker(runner, log, config,
              script: buildAutoUpdateRemoveScript(),
              successMarker: 'AUTOUPDATE_REMOVED',
              failMsg: 'Deaktivieren der automatischen Updates fehlgeschlagen');
        },
      );

  /// Lists a remote directory (root, so any path works). No writes.
  Future<List<DirEntry>> listDir({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) =>
      _withConnection<List<DirEntry>>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          final r = await runner.run(buildListDirCommand(path),
              stdin: '${config.password}\n');
          return parseDirListing(r.stdout);
        },
      );

  /// Reads a remote file's raw bytes (base64 over the channel).
  Future<Uint8List> readFileBytes({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) =>
      _withConnection<Uint8List>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          final r = await runner.run(buildReadFileCommand(path),
              stdin: '${config.password}\n');
          try {
            return base64.decode(r.stdout.replaceAll(RegExp(r'\s'), ''));
          } catch (_) {
            throw const EvccUpdateException(UpdateErrorKind.unknown,
                'Datei konnte nicht gelesen werden (Rechte? Binärdatei?).');
          }
        },
      );

  /// Reads a config file (root). Returns its text (or the error text).
  Future<String> readConfigFile({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) =>
      _withConnection<String>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          final r = await runner.run(buildConfigReadCommand(path),
              stdin: '${config.password}\n');
          final combined = '${r.stdout}\n${r.stderr}';
          if (isSudoPasswordFailure(combined)) {
            throw const EvccUpdateException(UpdateErrorKind.sudo,
                'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
          }
          // Empty stdout means the read failed (missing/no rights) or the file
          // is empty — either way, do NOT hand back the stderr as "content"
          // (it must never be saved back as the config).
          if (r.stdout.isEmpty) {
            throw const EvccUpdateException(UpdateErrorKind.unknown,
                'Datei konnte nicht gelesen werden (fehlt, leer oder keine '
                'Rechte).');
          }
          return r.stdout;
        },
      );

  /// Saves [content] to a config file (root), backing up the old one first.
  /// Content is transferred base64-encoded, so any bytes are safe.
  Future<void> saveConfigFile({
    required SshConfig config,
    required String path,
    required String content,
    required void Function(String line) onLog,
  }) {
    final b64 = base64.encode(utf8.encode(content));
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Speichere $path …');
        await _runRootScriptExpectMarker(runner, log, config,
            script: buildConfigWriteScript(path: path, base64Content: b64),
            successMarker: 'CONFIG_SAVED',
            failMsg: 'Speichern fehlgeschlagen');
      },
    );
  }

  /// Fetches the recent logs for a service (journalctl or docker logs, chosen
  /// by [buildServiceLogsCommand]). Sudo is piped when needed.
  Future<String> fetchServiceLogs({
    required SshConfig config,
    required String id,
    required String detail,
    required void Function(String line) onLog,
  }) {
    final spec = buildServiceLogsCommand(id: id, detail: detail);
    return _withConnection<String>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Logs: $id …');
        final r = await runner.run(
          spec.command,
          stdin: spec.sudo ? '${config.password}\n' : null,
        );
        return r.stdout.isNotEmpty ? r.stdout : r.stderr;
      },
    );
  }

  /// Installs the on-Pi health-check timer that pushes ntfy alerts. Root.
  Future<void> enableAlerts({
    required SshConfig config,
    required String ntfyServer,
    required String ntfyTopic,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Richte Health-Alerts ein …');
          await _runRootScriptExpectMarker(runner, log, config,
              script: buildAlertsInstallScript(
                  ntfyServer: ntfyServer, ntfyTopic: ntfyTopic),
              successMarker: 'ALERTS_INSTALLED',
              failMsg: 'Einrichten der Health-Alerts fehlgeschlagen');
        },
      );

  /// Removes the health-alerts timer. Root.
  Future<void> disableAlerts({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Deaktiviere Health-Alerts …');
          await _runRootScriptExpectMarker(runner, log, config,
              script: buildAlertsRemoveScript(),
              successMarker: 'ALERTS_REMOVED',
              failMsg: 'Deaktivieren der Health-Alerts fehlgeschlagen');
        },
      );

  /// Reads whether the alerts timer is active + last check. No sudo.
  Future<AlertsStatus> readAlertsStatus({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<AlertsStatus>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          final r = await runner.run(alertsStatusCommand);
          return parseAlertsStatus(r.stdout);
        },
      );

  /// Sends a one-off test push to verify the ntfy destination. No sudo.
  Future<void> sendTestAlert({
    required SshConfig config,
    required String ntfyServer,
    required String ntfyTopic,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Sende Test-Benachrichtigung …');
          await runner.run(buildTestAlertCommand(
              ntfyServer: ntfyServer, ntfyTopic: ntfyTopic));
        },
      );

  /// Reads whether the scheduled-update timer is active, its next run and last
  /// result. No sudo.
  Future<AutoUpdateStatus> readAutoUpdateStatus({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<AutoUpdateStatus>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          final r = await runner.run(autoUpdateStatusCommand);
          return parseAutoUpdateStatus(r.stdout);
        },
      );

  /// Frees disk space (apt autoremove/clean, dangling docker images, journal
  /// >7d) and returns the freed bytes. Conservative on purpose — see
  /// [buildCleanupScript].
  Future<int> cleanupSystem({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<int>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Räume auf (apt, Docker-Images, Journal) …');
          final result = await runner.run(
            installShellCommand,
            stdin: '${config.password}\n${buildCleanupScript()}\n',
            onOutput: (chunk) {
              final t = chunk.trimRight();
              if (t.isNotEmpty) log(t);
            },
          );
          final combined = '${result.stdout}\n${result.stderr}';
          if (isSudoPasswordFailure(combined)) {
            throw const EvccUpdateException(UpdateErrorKind.sudo,
                'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
          }
          final freed = parseCleanupFreed(combined);
          if (freed == null) {
            throw const EvccUpdateException(UpdateErrorKind.unknown,
                'Aufräumen fehlgeschlagen (Details im Log).');
          }
          return freed;
        },
      );

  /// Installs Pi-hole unattended (experimental — see buildPiholeInstallScript).
  Future<void> installPihole({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Installiere Pi-hole … (unbeaufsichtigt, dauert ein paar Minuten)');
          await _runRootScript(runner, log, config,
              sudo: true,
              script: buildPiholeInstallScript(),
              failMsg: 'Pi-hole-Installation fehlgeschlagen');
          log('Pi-hole installiert – Einrichtung im Browser unter /admin.');
        },
      );

  /// Installs Home Assistant as a Docker container, unattended (installs Docker
  /// first if missing). Experimental — see buildHomeAssistantInstallScript.
  Future<void> installHomeAssistant({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Installiere Home Assistant (Docker) … (dauert ein paar Minuten)');
          await _runRootScript(runner, log, config,
              sudo: true,
              script: buildHomeAssistantInstallScript(),
              failMsg: 'Home-Assistant-Installation fehlgeschlagen');
          // `docker run -d` returns 0 once the daemon accepts the container, so
          // verify it is actually running (port clash / missing privileges /
          // crash would otherwise be reported as success).
          var verify = await runner.run(dockerListCommand);
          if (isDockerPermissionError('${verify.stdout}\n${verify.stderr}')) {
            verify = await runner.run(dockerListSudoCommand,
                stdin: '${config.password}\n');
          }
          if (parseHomeAssistant(verify.stdout) == null) {
            throw const EvccUpdateException(
              UpdateErrorKind.serviceInactive,
              'Home Assistant läuft nach der Installation nicht (siehe '
              'Terminal-Log) – evtl. Port-Konflikt (8123) oder fehlende '
              'Docker-Rechte.',
            );
          }
          log('Home Assistant läuft – Einrichtung im Browser unter Port '
              '$homeAssistantPort.');
        },
      );

  /// Updates the Home Assistant container: pull the latest of its current tag
  /// and recreate it (reconstructed from `docker inspect`, so the user's mounts
  /// stay; HA state lives in the bound /config volume, so no data is lost). The
  /// old container is kept as a rollback. Experimental.
  Future<void> updateHomeAssistant({
    required SshConfig config,
    required void Function(String line) onLog,
  }) {
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        // Locate the HA container (the daemon may require sudo).
        var listing = await runner.run(dockerListCommand);
        var sudo = false;
        if (isDockerPermissionError('${listing.stdout}\n${listing.stderr}')) {
          sudo = true;
          listing = await runner.run(dockerListSudoCommand,
              stdin: '${config.password}\n');
          if (isSudoPasswordFailure('${listing.stdout}\n${listing.stderr}')) {
            throw const EvccUpdateException(UpdateErrorKind.sudo,
                'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
          }
        }
        final ha = parseHomeAssistant(listing.stdout);
        if (ha == null) {
          throw const EvccUpdateException(
            UpdateErrorKind.unknown,
            'Kein Home-Assistant-Container gefunden.',
          );
        }
        log('Home-Assistant-Container "${ha.name}" (${ha.image}).');

        final inspectCmd = sudo
            ? dockerInspectJsonSudoCommand(ha.name)
            : dockerInspectJsonCommand(ha.name);
        log('\$ $inspectCmd');
        final inspect = await runner.run(inspectCmd,
            stdin: sudo ? '${config.password}\n' : null);
        if (sudo &&
            isSudoPasswordFailure('${inspect.stdout}\n${inspect.stderr}')) {
          throw const EvccUpdateException(UpdateErrorKind.sudo,
              'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
        }
        final obj = firstInspectObject(inspect.stdout);
        if (obj == null) {
          throw const EvccUpdateException(
            UpdateErrorKind.unknown,
            'Konnte den Home-Assistant-Container nicht inspizieren.',
          );
        }

        // Compose-managed HA: update via `docker compose` so the project stays
        // intact (recreating it as a plain `docker run` would orphan it and can
        // drop named volumes). Otherwise rebuild an equivalent `docker run`.
        final compose = composeInfoFromInspect(obj);
        final String script;
        if (compose != null) {
          log('Aktualisiere via docker compose in ${compose.workingDir} '
              '(Dienst ${compose.service}) …');
          script = dockerComposeUpdateScript(compose);
        } else {
          final image =
              ((obj['Config'] is Map) ? (obj['Config'] as Map)['Image'] : null)
                      ?.toString() ??
                  ha.image;
          if (image.contains('@sha256:')) {
            throw const EvccUpdateException(
              UpdateErrorKind.unknown,
              'Das Image ist per Digest gepinnt (@sha256:…) und kann nicht '
              'automatisch aktualisiert werden – bitte ein Image-Tag setzen.',
            );
          }
          script = dockerRunRecreateScript(
            name: ha.name,
            image: image,
            runCommand: buildDockerRunCommand(obj, image: image),
          );
        }
        await _runRootScript(runner, log, config,
            sudo: sudo,
            script: script,
            failMsg: 'Home-Assistant-Update fehlgeschlagen');

        final verify = await runner.run(
          sudo ? dockerListSudoCommand : dockerListCommand,
          stdin: sudo ? '${config.password}\n' : null,
        );
        if (parseHomeAssistant(verify.stdout) == null) {
          throw const EvccUpdateException(
            UpdateErrorKind.serviceInactive,
            'Home-Assistant-Container läuft nach dem Update nicht. Der '
            'vorherige Container wurde als Backup behalten.',
          );
        }
        log('Fertig – Home Assistant läuft wieder.');
      },
    );
  }

  /// Whole-system upgrade: refresh lists (tolerant) then `apt-get full-upgrade`.
  Future<void> upgradeSystem({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('System-Upgrade (alle Pakete) …');
          // apt-get update may exit non-zero on a flaky third-party repo —
          // tolerate it (checkExit:false) so a fine upgrade isn't blocked.
          await _sudoCommand(runner, log, config,
              'LC_ALL=C sudo -S apt-get update -qq', 'apt-get update',
              checkExit: false);
          await _sudoCommand(runner, log, config,
              'LC_ALL=C sudo -S apt-get full-upgrade -y',
              'System-Upgrade fehlgeschlagen');
          log('System aktualisiert.');
        },
      );

  /// Updates a single apt [package] (Grafana, InfluxDB, …): tolerant list
  /// refresh, then `--only-upgrade` so a not-installed package is never pulled
  /// in. [package] comes from our own [knownAptServices] descriptors.
  Future<void> updateAptPackage({
    required SshConfig config,
    required String package,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Aktualisiere $package …');
          await _sudoCommand(runner, log, config,
              'LC_ALL=C sudo -S apt-get update -qq', 'apt-get update',
              checkExit: false);
          await _sudoCommand(
              runner,
              log,
              config,
              'LC_ALL=C sudo -S apt-get install --only-upgrade -y $package',
              '$package-Update fehlgeschlagen');
          log('$package ist aktuell.');
        },
      );

  /// Installs an on-demand apt service (Grafana, InfluxDB, Mosquitto, …) by
  /// running its [AptService.installScript] as root: it sets up the official
  /// apt repo, installs the package and enables the unit. Experimental — the
  /// scripts follow each project's documented install but aren't validated
  /// against every Pi OS release. Throws on failure.
  Future<void> installAptService({
    required SshConfig config,
    required AptService service,
    required void Function(String line) onLog,
  }) {
    final script = service.installScript;
    if (script == null) {
      throw EvccUpdateException(UpdateErrorKind.unknown,
          '${service.name} kann nicht installiert werden.');
    }
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Installiere ${service.name} … (kann ein paar Minuten dauern)');
        await _runRootScript(runner, log, config,
            sudo: true,
            script: script,
            failMsg: '${service.name}-Installation fehlgeschlagen');
        log('${service.name} installiert.');
      },
    );
  }

  /// Updates a Docker-deployed evcc. Inspects the container once: if it's
  /// compose-managed, it pulls + recreates the evcc service via `docker compose`
  /// (project/file pinned, v1 fallback); otherwise it reconstructs an equivalent
  /// `docker run` from the inspect data and recreates the container, keeping the
  /// old one (renamed) as a rollback — volumes are reused, so no data is lost.
  /// Experimental: not validated against a real Docker host. Throws on failure.
  Future<void> updateDocker({
    required SshConfig config,
    required InstallDetection detection,
    required void Function(String line) onLog,
  }) {
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        final container = detection.container;
        if (container == null) {
          throw const EvccUpdateException(
            UpdateErrorKind.unknown,
            'Kein evcc-Docker-Container erkannt.',
          );
        }
        final sudo = detection.dockerNeedsSudo;
        log('evcc-Container "${container.name}" (${container.image}).');

        final inspectCmd = sudo
            ? dockerInspectJsonSudoCommand(container.name)
            : dockerInspectJsonCommand(container.name);
        log('\$ $inspectCmd');
        final inspect = await runner.run(
          inspectCmd,
          stdin: sudo ? '${config.password}\n' : null,
        );
        if (sudo &&
            isSudoPasswordFailure('${inspect.stdout}\n${inspect.stderr}')) {
          throw const EvccUpdateException(
            UpdateErrorKind.sudo,
            'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
          );
        }
        final obj = firstInspectObject(inspect.stdout);
        if (obj == null) {
          throw const EvccUpdateException(
            UpdateErrorKind.unknown,
            'Konnte den Docker-Container nicht inspizieren.',
          );
        }

        final compose = composeInfoFromInspect(obj);
        final String script;
        if (compose != null) {
          log('Aktualisiere via docker compose in ${compose.workingDir} '
              '(Dienst ${compose.service}) …');
          script = dockerComposeUpdateScript(compose);
        } else {
          log('Container ohne docker compose – aktualisiere per Image-Pull + '
              'Neuanlage. Der alte Container bleibt als Backup erhalten.');
          final image =
              ((obj['Config'] is Map) ? (obj['Config'] as Map)['Image'] : null)
                      ?.toString() ??
                  container.image;
          if (image.contains('@sha256:')) {
            throw const EvccUpdateException(
              UpdateErrorKind.unknown,
              'Das Image ist per Digest gepinnt (@sha256:…) und kann nicht '
              'automatisch aktualisiert werden – bitte in der Container-'
              'Definition ein Image-Tag setzen und manuell neu ziehen.',
            );
          }
          script = dockerRunRecreateScript(
            name: container.name,
            image: image,
            runCommand: buildDockerRunCommand(obj, image: image),
          );
        }

        await _runRootScript(runner, log, config,
            sudo: sudo, script: script, failMsg: 'Docker-Update fehlgeschlagen');

        final verify = await runner.run(
          sudo ? dockerListSudoCommand : dockerListCommand,
          stdin: sudo ? '${config.password}\n' : null,
        );
        if (parseEvccDocker(verify.stdout) == null) {
          throw const EvccUpdateException(
            UpdateErrorKind.serviceInactive,
            'evcc-Container läuft nach dem Update nicht. Der vorherige Container '
            'wurde als Backup (Suffix "-evccpitool-old") behalten.',
          );
        }
        log('Fertig – evcc-Container läuft wieder.');
      },
    );
  }

  /// Runs a multi-line root [script] via `bash -s` (or `sudo -S bash -s`),
  /// streaming output and mapping a rejected sudo password / non-zero exit to a
  /// clear error. Shared by the compose and `docker run` update paths.
  Future<void> _runRootScript(
    SshRunner runner,
    void Function(String) log,
    SshConfig config, {
    required bool sudo,
    required String script,
    String failMsg = 'Vorgang fehlgeschlagen',
  }) async {
    final shell = sudo ? installShellCommand : 'bash -s';
    final result = await runner.run(
      shell,
      stdin: sudo ? '${config.password}\n$script\n' : '$script\n',
      onOutput: (chunk) {
        final t = chunk.trimRight();
        if (t.isNotEmpty) log(t);
      },
    );
    final combined = '${result.stdout}\n${result.stderr}';
    if (sudo && isSudoPasswordFailure(combined)) {
      throw const EvccUpdateException(
        UpdateErrorKind.sudo,
        'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
      );
    }
    if (result.exitCode != null && result.exitCode != 0) {
      throw EvccUpdateException(
        UpdateErrorKind.unknown,
        '$failMsg (Exit ${result.exitCode}). Details im Log.',
      );
    }
  }

  /// Runs a DESTRUCTIVE root [script] that must print [successMarker] to count
  /// as successful. Stricter than [_runRootScript]: a missing marker is a
  /// failure even when the exit code is null (remote killed by a signal or the
  /// connection torn down mid-run) — for a half-done restore we must never
  /// report success. The marker is only ever reached at the end of the happy
  /// path (the scripts run under `set -e`).
  Future<void> _runRootScriptExpectMarker(
    SshRunner runner,
    void Function(String) log,
    SshConfig config, {
    required String script,
    required String successMarker,
    required String failMsg,
  }) async {
    final result = await runner.run(
      installShellCommand,
      stdin: '${config.password}\n$script\n',
      onOutput: (chunk) {
        final t = chunk.trimRight();
        if (t.isNotEmpty) log(t);
      },
    );
    final combined = '${result.stdout}\n${result.stderr}';
    if (isSudoPasswordFailure(combined)) {
      throw const EvccUpdateException(UpdateErrorKind.sudo,
          'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
    }
    final ok = combined.contains(successMarker) &&
        !(result.exitCode != null && result.exitCode != 0);
    if (!ok) {
      throw EvccUpdateException(
          UpdateErrorKind.unknown, '$failMsg (Details im Log).');
    }
  }

  /// Runs a root [script] (always sudo) and returns the `BACKUP_OK <path>` it
  /// printed. Throws [failMsg] on a rejected password / non-zero exit / no
  /// marker. Used by the on-demand Pi-hole + Home Assistant backups.
  Future<String> _runRootScriptCapturing(
    SshRunner runner,
    void Function(String) log,
    SshConfig config, {
    required String script,
    required String failMsg,
  }) async {
    final result = await runner.run(
      installShellCommand,
      stdin: '${config.password}\n$script\n',
      onOutput: (chunk) {
        final t = chunk.trimRight();
        if (t.isNotEmpty) log(t);
      },
    );
    final combined = '${result.stdout}\n${result.stderr}';
    if (isSudoPasswordFailure(combined)) {
      throw const EvccUpdateException(UpdateErrorKind.sudo,
          'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
    }
    final path = parseServiceBackupPath(combined);
    if (path == null || (result.exitCode != null && result.exitCode != 0)) {
      throw EvccUpdateException(
          UpdateErrorKind.unknown, '$failMsg (Details im Log).');
    }
    return path;
  }

  /// Snapshots the evcc config + database into a timestamped archive on the Pi
  /// (under /var/backups/evcc/) before an update. Returns the archive path, or
  /// null when there was nothing to back up (e.g. a fresh install — not an
  /// error). Throws [EvccUpdateException] on a real failure (rejected sudo, tar
  /// error) so the caller can surface it and stop the update.
  Future<String?> backup({
    required SshConfig config,
    required void Function(String line) onLog,
  }) {
    return _withConnection<String?>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Erstelle Backup (Config + Datenbank) …');
        final result = await runner.run(
          installShellCommand,
          stdin: '${config.password}\n${buildBackupScript()}\n',
          onOutput: (chunk) {
            final t = chunk.trimRight();
            if (t.isNotEmpty) log(t);
          },
        );
        final combined = '${result.stdout}\n${result.stderr}';
        if (isSudoPasswordFailure(combined)) {
          throw const EvccUpdateException(
            UpdateErrorKind.sudo,
            'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
          );
        }
        final path = parseBackupPath(combined);
        if (path != null) {
          log('Backup gespeichert: $path');
          return path;
        }
        if (combined.contains('EVCC_BACKUP_EMPTY')) {
          log('Backup: nichts zu sichern gefunden (frische Installation?).');
          return null;
        }
        throw EvccUpdateException(
          UpdateErrorKind.unknown,
          'Backup fehlgeschlagen (Exit ${result.exitCode}). Details im Log.',
        );
      },
    );
  }

  /// Lists the evcc backup archives present on the Pi, newest first (no sudo).
  Future<List<String>> listBackups({
    required SshConfig config,
    required void Function(String line) onLog,
  }) {
    return _withConnection<List<String>>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        final r = await runner.run(listBackupsCommand);
        final list = parseBackupList(r.stdout);
        log('${list.length} Backup(s) gefunden.');
        return list;
      },
    );
  }

  /// Restores a previously created backup [path]: stops evcc, extracts the
  /// archive back to `/`, restarts evcc. Throws on a rejected sudo password or
  /// any failure. Rejects a path outside the backup dir as defense-in-depth.
  Future<void> restoreBackup({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) async {
    if (!path.startsWith('$evccBackupDir/') || !path.endsWith('.tar.gz')) {
      throw const EvccUpdateException(
        UpdateErrorKind.unknown,
        'Ungültiger Backup-Pfad.',
      );
    }
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Stelle Backup wieder her: $path …');
        await _runRootScript(runner, log, config,
            sudo: true,
            script: buildRestoreScript(path),
            failMsg: 'Wiederherstellung fehlgeschlagen');
        // `systemctl start` returns 0 as soon as the process forks, so verify
        // evcc actually stayed up (a restored config that crashes on start must
        // not be reported as a clean restore).
        final svc = await runner.run(serviceStatus);
        if (!isServiceActive(svc.stdout)) {
          throw const EvccUpdateException(
            UpdateErrorKind.serviceInactive,
            'Backup eingespielt, aber evcc läuft danach nicht (siehe Log) – '
            'evtl. eine defekte Konfiguration im Backup.',
          );
        }
        log('Backup wiederhergestellt – evcc läuft.');
      },
    );
  }

  /// Restarts the evcc service and verifies it comes back active.
  Future<void> restartService({
    required SshConfig config,
    required void Function(String line) onLog,
  }) {
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Starte evcc-Dienst neu …');
        log('\$ $serviceRestartCommand');
        final result = await runner.run(
          serviceRestartCommand,
          stdin: '${config.password}\n',
          onOutput: (chunk) {
            final t = chunk.trimRight();
            if (t.isNotEmpty) log(t);
          },
        );
        if (isSudoPasswordFailure('${result.stdout}\n${result.stderr}')) {
          throw const EvccUpdateException(
            UpdateErrorKind.sudo,
            'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
          );
        }
        // A non-zero restart command (e.g. an undetected sudo rejection) must
        // not be swallowed — otherwise the old instance keeps running and
        // is-active still reports 'active', a false "Dienst läuft wieder".
        if (result.exitCode != null && result.exitCode != 0) {
          throw EvccUpdateException(
            UpdateErrorKind.unknown,
            'Neustart fehlgeschlagen (Exit ${result.exitCode}). Details im Log.',
          );
        }
        final svc = await runner.run(serviceStatus);
        if (!isServiceActive(svc.stdout)) {
          throw const EvccUpdateException(
            UpdateErrorKind.serviceInactive,
            'evcc-Dienst ist nach dem Neustart nicht aktiv.',
          );
        }
        log('evcc-Dienst läuft wieder.');
      },
    );
  }

  /// Reboots the Pi. The SSH connection drops as a result — that's treated as
  /// success. A rejected sudo password (no disconnect) is reported.
  /// Runs a free-form console command on the Pi in a one-off SSH session and
  /// returns its combined stdout+stderr. A `sudo …` command gets the Pi password
  /// piped in (see [buildConsoleExec]); everything else runs verbatim. Output is
  /// streamed to [onLog] line by line (password-redacted). The user is
  /// responsible for what they run — this is a raw shell, not a guarded action.
  Future<String> runConsoleCommand({
    required SshConfig config,
    required String command,
    required void Function(String line) onLog,
  }) =>
      _withConnection<String>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('\$ $command');
          final prep = buildConsoleExec(command);
          final result = await runner.run(
            prep.exec,
            stdin: prep.sudo ? '${config.password}\n' : null,
            onOutput: (chunk) {
              final t = chunk.trimRight();
              if (t.isNotEmpty) log(t);
            },
          );
          if (prep.sudo &&
              isSudoPasswordFailure('${result.stdout}\n${result.stderr}')) {
            throw const EvccUpdateException(UpdateErrorKind.sudo,
                'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
          }
          return '${result.stdout}${result.stderr}';
        },
      );

  Future<void> reboot({
    required SshConfig config,
    required void Function(String line) onLog,
  }) {
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Starte den Pi neu …');
        log('\$ $rebootCommand');
        var combined = '';
        int? exitCode;
        var disconnected = false;
        try {
          final result = await runner.run(
            rebootCommand,
            stdin: '${config.password}\n',
            onOutput: (chunk) {
              final t = chunk.trimRight();
              if (t.isNotEmpty) log(t);
            },
          );
          combined = '${result.stdout}\n${result.stderr}';
          exitCode = result.exitCode;
        } catch (_) {
          // The reboot drops the SSH connection — expected, treat as success.
          disconnected = true;
        }
        if (isSudoPasswordFailure(combined)) {
          throw const EvccUpdateException(
            UpdateErrorKind.sudo,
            'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
          );
        }
        // A real reboot either drops the connection (caught above) or returns
        // exit 0. A non-zero exit WITHOUT a disconnect (e.g. sudoers forbids
        // `reboot`) means the Pi did not reboot — surface it, don't fake success.
        if (!disconnected && exitCode != null && exitCode != 0) {
          throw EvccUpdateException(
            UpdateErrorKind.unknown,
            'Neustart fehlgeschlagen (Exit $exitCode). Details im Log.',
          );
        }
        log('Neustart ausgelöst – der Pi ist gleich kurz offline.');
      },
    );
  }

  /// Opens the connection, runs [body], and maps any SSH/IO failure to an
  /// [EvccUpdateException]. The runner is always closed afterwards.
  Future<T> _withConnection<T>({
    required SshConfig config,
    required void Function(String line) onLog,
    required Future<T> Function(SshRunner runner, void Function(String) log)
        body,
  }) async {
    final runner = runnerFactory(config);
    _active = runner;
    _cancelRequested = false;
    void log(String s) => onLog(redactPassword(s, config.password));

    try {
      log('Verbinde mit ${config.username}@${config.host}:${config.port} …');
      await runner.connect();
      // A cancel that arrived during the connect handshake must stop here —
      // before the (possibly destructive) body runs — since closing a not-yet-
      // established connection can't abort the handshake itself.
      if (_cancelRequested) {
        throw const EvccUpdateException(
            UpdateErrorKind.cancelled, 'Abgebrochen.');
      }
      final result = await body(runner, log);
      // Closing the connection mid-command doesn't always make run() throw —
      // dartssh2 ends the channel stream normally, so a single-command action
      // would otherwise return a partial result and look "successful". Treat a
      // requested cancel as cancelled regardless of how the body finished.
      if (_cancelRequested) {
        throw const EvccUpdateException(
            UpdateErrorKind.cancelled, 'Abgebrochen.');
      }
      return result;
    } catch (e) {
      // A user-requested cancel closed the connection mid-action; whatever low
      // -level error that surfaced (socket/SSH) is reported as a clean cancel.
      if (_cancelRequested) {
        throw const EvccUpdateException(
            UpdateErrorKind.cancelled, 'Abgebrochen.');
      }
      if (e is EvccUpdateException) rethrow;
      if (e is HostKeyDeclinedException) {
        throw const EvccUpdateException(
          UpdateErrorKind.connection,
          'Host-Schlüssel nicht bestätigt – Verbindung abgebrochen. Es wurde '
          'kein Passwort gesendet.',
        );
      }
      if (e is HostKeyChangedException) {
        throw EvccUpdateException(
          UpdateErrorKind.hostKeyChanged,
          'Der SSH-Host-Key von ${e.host} hat sich geändert! Entweder wurde der '
          'Pi neu aufgesetzt – oder jemand täuscht ihn vor. Aus Sicherheit '
          'wurde KEIN Passwort gesendet.\nNeuer Fingerprint: ${e.presented}',
        );
      }
      if (e is SSHAuthError) {
        throw const EvccUpdateException(
          UpdateErrorKind.auth,
          'Anmeldung fehlgeschlagen – Benutzer/Passwort bzw. SSH-Key prüfen.',
        );
      }
      if (e is SSHKeyDecodeError) {
        throw const EvccUpdateException(
          UpdateErrorKind.auth,
          'Privater SSH-Key ungültig oder falsche Passphrase.',
        );
      }
      if (e is SocketException) {
        throw const EvccUpdateException(
          UpdateErrorKind.connection,
          'Verbindung fehlgeschlagen – IP/Port korrekt, Pi online im Netz?',
        );
      }
      if (e is TimeoutException) {
        throw const EvccUpdateException(
          UpdateErrorKind.connection,
          'Zeitüberschreitung – Pi nicht erreichbar.',
        );
      }
      if (e is SSHError) {
        throw EvccUpdateException(UpdateErrorKind.unknown, 'SSH-Fehler: $e');
      }
      throw EvccUpdateException(
          UpdateErrorKind.unknown, 'Unerwarteter Fehler: $e');
    } finally {
      _active = null;
      await runner.close();
    }
  }
}
