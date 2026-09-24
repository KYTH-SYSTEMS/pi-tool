import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'alerts.dart';
import 'auto_update.dart';
import 'commands.dart';
import 'docker_containers.dart';
import 'eol_sources.dart';
import 'files.dart';
import 'dartssh2_runner.dart';
import 'host_key.dart';
import 'parsing.dart';
import 'pi_job.dart';
import 'scheduled_backup.dart';
import 'security_check.dart';
import 'ssh_keys.dart';
import 'storage_explorer.dart';
import 'services/apt_services.dart';
import 'services/homeassistant_service.dart';
import 'services/pi_connect.dart';
import 'services/tailscale.dart';
import 'services/pi_service.dart';
import 'services/pihole_service.dart';
import 'services/stack_wiring.dart';
import 'services/system_service.dart';
import 'settings_store.dart';
import 'systemd_services.dart';
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

  /// A Pi-Job keeps running on the Pi while the app no longer follows it
  /// (the user stopped following, or the connection went away). Not a
  /// failure — see [JobException].
  jobDetached,

  /// Another Pi-Job (or the on-Pi auto-update) holds the Pi; nothing was
  /// started. See [JobException].
  jobBusy,
}

/// A failure during the update, carrying a user-facing German [message].
class EvccUpdateException implements Exception {
  final UpdateErrorKind kind;
  final String message;

  const EvccUpdateException(this.kind, this.message);

  @override
  String toString() => 'EvccUpdateException($kind): $message';
}

/// Why the app stopped following a job that runs on.
enum JobDetachReason { userStopped, connectionLost }

/// A Pi-Job outcome that is not a plain failure: the job runs on without the
/// app ([UpdateErrorKind.jobDetached]) or another job holds the Pi
/// ([UpdateErrorKind.jobBusy]). Callers must never read either as success —
/// nor as "stopped".
class JobException extends EvccUpdateException {
  const JobException(
    super.kind,
    super.message, {
    this.ref,
    this.jobKind,
    this.reason,
    this.startConfirmed = true,
    this.since,
  });

  /// The job concerned: the detached one, or the one that holds the Pi. Null
  /// when unknown (the on-Pi auto-update, a guard refusal).
  final JobRef? ref;

  /// Kind of that job — also when there is no [ref] (e.g. `autoupdate`).
  final String? jobKind;

  /// jobDetached only.
  final JobDetachReason? reason;

  /// jobDetached: false when the connection ended before the job confirmed
  /// its start — then it is unclear whether it runs.
  final bool startConfirmed;

  /// jobBusy: since when the other job runs, if known.
  final DateTime? since;
}

/// Result of [EvccUpdater.upgradeSystem].
class SystemUpgradeResult {
  const SystemUpgradeResult({this.listsIncomplete = false});

  /// `apt-get update` failed for at least one source: the upgrade ran with
  /// partly outdated package lists.
  final bool listsIncomplete;
}

/// A job that ended with an exit code, with its complete log.
class JobRunResult {
  const JobRunResult({required this.ref, required this.rc, required this.log});
  final JobRef ref;
  final int rc;
  final String log;
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

  EvccUpdater({
    required this.runnerFactory,
    this.hostKeyStore,
    String Function()? webPasswordGenerator,
    String Function()? jobIdGenerator,
    this.jobWatchdog = const Duration(seconds: 60),
  })  : _webPassword = webPasswordGenerator ?? generateWebPassword,
        _jobId = jobIdGenerator ?? generateJobId;

  /// Makes the Pi-hole web password (injectable so tests see a known one).
  final String Function() _webPassword;

  /// Makes Pi-Job ids (injectable so tests know the job commands).
  final String Function() _jobId;

  /// A job run that produces no output at all — not even the follower's
  /// heartbeat (every ~15 s) — for this long is treated as a lost connection:
  /// covers a silently dropped WLAN and an `execute` that never returns.
  final Duration jobWatchdog;

  /// Connections on which a Pi-Job command was issued. Keyed per runner (not
  /// a flag on the instance) so a concurrent action cannot reset it.
  final Expando<bool> _jobTouched = Expando<bool>('pi-job');

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
  /// [confirmFirstUse] is called on the first connection to a host with THAT
  /// host and the presented SHA256 fingerprint; return true to trust +
  /// proceed, false to abort. When null, first use is trusted automatically
  /// (legacy TOFU).
  factory EvccUpdater.real({
    Future<bool> Function(String host, String fingerprint)? confirmFirstUse,
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
  /// The real run (not [dryRun]) is a Pi-Job: it keeps running on the Pi when
  /// the connection drops; [onJobStarted] fires once the Pi confirmed the
  /// start. A dry run stays a plain read-only probe.
  Future<UpdateSummary> run({
    required SshConfig config,
    required bool fullUpgrade,
    required bool dryRun,
    required void Function(String line) onLog,
    void Function(JobRef ref)? onJobStarted,
  }) {
    if (!dryRun) {
      return _runEvccJob(
          config: config,
          fullUpgrade: fullUpgrade,
          onLog: onLog,
          onJobStarted: onJobStarted);
    }
    return _withConnection<UpdateSummary>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Verbunden. Starte ${dryRun ? 'Probelauf' : 'Update'} …');

        // A dry run changes nothing — no job, no lock, no sources rewrite.
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

  /// The real evcc apt update: version before (read-only, foreground), then
  /// the package change as a Pi-Job (`evcc-update`). The summary comes from
  /// the job's own markers — service state and version after — so a success
  /// needs the RC line AND an active evcc.
  Future<UpdateSummary> _runEvccJob({
    required SshConfig config,
    required bool fullUpgrade,
    required void Function(String line) onLog,
    void Function(JobRef ref)? onJobStarted,
  }) =>
      _withConnection<UpdateSummary>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Verbunden. Starte Update …');
          log('\$ $versionQuery');
          final v = await runner.run(versionQuery);
          final before = parseInstalledVersion(v.stdout);
          if (before == null) {
            throw const EvccUpdateException(
              UpdateErrorKind.packageMissing,
              'evcc ist auf dem Pi nicht installiert (apt-Paket fehlt).',
            );
          }
          final r = await _runJob(runner, log, config,
              kind: jobKindEvccUpdate,
              payload: buildEvccUpdatePayload(fullUpgrade: fullUpgrade),
              onJobStarted: onJobStarted);
          final o = evaluateJob(jobKindEvccUpdate, r.rc, r.log);
          if (r.rc != 0) {
            throw EvccUpdateException(UpdateErrorKind.unknown, o.message);
          }
          if (o.evccActive != true) {
            throw const EvccUpdateException(
              UpdateErrorKind.serviceInactive,
              'evcc-Dienst ist nach dem Update nicht aktiv '
              '(systemctl is-active ≠ active).',
            );
          }
          if (o.listsIncomplete) log(_listsIncompleteNote);
          final summary = summarize(
            before: before,
            after: o.evccVersion,
            dryRun: false,
            fullUpgrade: fullUpgrade,
            alreadyNewest: o.alreadyNewest,
          );
          log(summary.message);
          return summary;
        },
      );

  static const String _listsIncompleteNote =
      'Hinweis: Nicht alle Paketlisten ließen sich laden – das Update lief '
      'mit teils veralteten Listen. Details oben im Log.';

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
        await _fixEolSources(runner, log, config);

        final result = await runner.run(
          installShellCommand,
          stdin: await _rootStdin(
              runner, config, buildInstallScript(channel: channel)),
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
        if (result.exitCode == null) {
          throw const EvccUpdateException(
              UpdateErrorKind.unknown, _resultUnknown);
        }
        if (result.exitCode != 0) {
          final cause = _aptFailureCause(combined);
          throw EvccUpdateException(
            UpdateErrorKind.unknown,
            cause != null
                ? 'Installation fehlgeschlagen — $cause'
                : 'Installation fehlgeschlagen (Exit ${result.exitCode}). '
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
          ('APTAGE', systemAptAgeCommand),
          ('EVCC_V', versionQuery),
          ('EVCC_SVC', serviceStatus),
          ('PIHOLE_V', piholeVersionCommand),
          ('PIHOLE_S', piholeStatusCommand),
          ('HA_VERSION', haVersionProbe),
          ('PICONNECT', piConnectStatusCommand),
          ('TAILSCALE', tailscaleStatusCommand),
          // Subnet-router state for the Tailscale card (all read-only).
          ('TS_LAN', lanRoutesCommand),
          ('TS_PREFS', tailscalePrefsCommand),
          ('TS_SELF', tailscaleSelfCommand),
          ('TS_FWD', tailscaleForwardingProbe),
          ('APTSVC', aptServicesQuery),
          for (final u in units) ('UNIT:$u', 'systemctl is-active $u'),
          for (final svc in knownSystemdServices)
            ('SYSD:${svc.unit}', systemdStateCommand(svc.unit)),
          ('OS', systemOsCommand),
          ('TEMP', systemTempCommand),
          ('DISK', systemDiskCommand),
          ('MEM', systemMemCommand),
          ('UPTIME', systemUptimeCommand),
          ('STORAGE', systemStorageCommand),
          // The latest Pi-Job (world-readable job.status + boot id), no sudo.
          ('JOB', jobStatusProbe),
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
        final pendingCount = pending ?? 0;
        final aptUpgrades = parseAptUpgrades(sec['PENDING'] ?? '');
        // The simulation reads the LOCAL index and never refreshes it, so its
        // "nothing pending" is only worth something while that index is recent
        // — otherwise every apt card would claim a currency nobody checked.
        final aptAge = parseAptListsAgeSeconds(sec['APTAGE'] ?? '');
        final aptKnown = pending != null && isAptIndexFresh(aptAge);

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

        // ---- extra systemd services (AdGuard Home, Node-RED, Zigbee2MQTT) ----
        // Detected + managed only (their installers are bespoke — no install).
        for (final svc in knownSystemdServices) {
          final st = parseSystemdState(sec['SYSD:${svc.unit}'] ?? '');
          if (!st.installed) continue;
          out.add(ServiceStatus(
            id: svc.id,
            name: svc.name,
            installed: true,
            active: st.active,
            detail: 'systemd · Dienst ${st.active ? 'aktiv' : 'inaktiv'}',
            webPort: svc.webPort,
          ));
        }

        // ---- Raspberry Pi Connect (official remote access) ----
        // Needs Bookworm+; when incompatible we still emit an (absent) entry so
        // the UI can show it greyed with the reason instead of hiding it.
        final pcCompatible = isPiConnectCompatible(sec['OS'] ?? '');
        final pc = parsePiConnectStatus(sec['PICONNECT'] ?? '');
        if (pc.installed) {
          // "active" (green LED) = signed in. The on/off sub-state isn't
          // reliably parseable across rpi-connect versions, so we don't gate on
          // it (was falsely reporting "inaktiv" on a running, signed-in node).
          // rpi-connect is an apt package → surface a pending apt upgrade like
          // the other apt cards (handle both the lite and the full package).
          String? pcPkg;
          for (final p in const ['rpi-connect-lite', 'rpi-connect']) {
            if (aptUpgrades.any((u) => u == p || u.startsWith('$p:'))) {
              pcPkg = p;
              break;
            }
          }
          out.add(ServiceStatus(
            id: 'piconnect',
            name: 'Raspberry Pi Connect',
            installed: true,
            active: pc.signedIn,
            version: pc.signedIn ? 'angemeldet' : 'nicht angemeldet',
            detail: pc.signedIn ? 'Angemeldet' : 'Nicht angemeldet',
            updateAvailable: pcPkg != null,
            updateKnown: aptKnown,
            aptPackage: pcPkg ?? 'rpi-connect-lite',
          ));
        } else {
          out.add(ServiceStatus.absent('piconnect', 'Raspberry Pi Connect',
              compatible: pcCompatible));
        }

        // ---- Tailscale (VPN/mesh, official installer, any OS) ----
        final ts = parseTailscaleStatus(sec['TAILSCALE'] ?? '');
        if (ts.installed) {
          final tsUpdate = aptUpgrades
              .any((u) => u == 'tailscale' || u.startsWith('tailscale:'));
          out.add(ServiceStatus(
            id: 'tailscale',
            name: 'Tailscale',
            installed: true,
            active: ts.up,
            version: ts.up ? ts.ip : null,
            detail: ts.up ? 'Verbunden · ${ts.ip}' : 'Getrennt',
            updateAvailable: tsUpdate,
            updateKnown: aptKnown,
            aptPackage: 'tailscale',
            routes: ts.up ? _subnetRoutes(sec) : null,
          ));
        } else {
          out.add(ServiceStatus.absent('tailscale', 'Tailscale'));
        }

        // ---- System (always present) ----
        final health = SystemHealth(
          tempC: parseTemperatureC(sec['TEMP'] ?? ''),
          disk: parseDiskUsage(sec['DISK'] ?? ''),
          memAvailableMb: parseMemAvailableMb(sec['MEM'] ?? ''),
          uptime: (sec['UPTIME'] ?? '').trim(),
          storage: parseStorageHealth(sec['STORAGE'] ?? ''),
        );
        out.add(ServiceStatus(
          id: 'system',
          name: 'System (Pi)',
          installed: true,
          version: parseOsPrettyName(sec['OS'] ?? ''),
          active: true,
          updateAvailable: pendingCount > 0,
          updateKnown: aptKnown,
          detail: pendingCount > 0
              ? '$pendingCount Updates verfügbar'
              : aptKnown
                  ? 'aktuell'
                  : aptIndexStaleDetail(aptAge),
          health: health.summary,
          healthWarning: health.warning,
          // Transient: ServiceStatus.toJson leaves it out of the cache.
          job: parseJobStatus(sec['JOB'] ?? ''),
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
    if (isDpkgInterrupted(combined)) {
      // Not our failure and not fixable by retrying: apt refuses every install
      // until the half-finished dpkg run is completed. Say so, and name the
      // one-tap remedy the System card offers.
      throw const EvccUpdateException(UpdateErrorKind.unknown, _dpkgInterrupted);
    }
    // No exit status: the channel ended mid-command. Never a success.
    if (checkExit && r.exitCode == null) {
      throw const EvccUpdateException(UpdateErrorKind.unknown, _resultUnknown);
    }
    if (checkExit && r.exitCode != 0) {
      final cause = _aptFailureCause(combined);
      throw EvccUpdateException(
        UpdateErrorKind.unknown,
        cause != null
            ? '$failMsg — $cause'
            : '$failMsg (Exit ${r.exitCode}). Details im Log.',
      );
    }
  }

  static const String _dpkgInterrupted = dpkgInterruptedMessage;

  /// A foreground command whose channel ended without an exit status: it may
  /// have stopped anywhere. Never reported as success.
  static const String _resultUnknown =
      'Verbindung während der Aktion abgerissen – Ergebnis unbekannt. '
      'Details im Log.';

  /// The cause of a failed apt/dpkg run in words the user can act on, or null
  /// when the output shows none of the known ones (then: "Details im Log").
  /// Shared with the Pi-Job evaluation (pi_job.dart).
  static String? _aptFailureCause(String output) => aptFailureCause(output);

  /// Points dead package sources of end-of-life releases (Raspbian/Debian
  /// jessie, stretch, buster) at the official archive before an action that
  /// installs or upgrades packages — see eol_sources.dart. Prints nothing on a
  /// healthy Pi. Never fails the action itself: if it could not help, apt names
  /// the dead source and [_aptFailureCause] turns that into the message. Only a
  /// rejected sudo password stops here, as it would stop the action anyway.
  Future<void> _fixEolSources(
      SshRunner runner, void Function(String) log, SshConfig config) async {
    final r = await runner.run(
      eolSourcesShellCommand,
      stdin: await _rootStdin(runner, config, eolSourcesFixScript),
      onOutput: (chunk) {
        final t = chunk.trimRight();
        if (t.isNotEmpty) log(t);
      },
    );
    if (isSudoPasswordFailure('${r.stdout}\n${r.stderr}')) {
      throw const EvccUpdateException(UpdateErrorKind.sudo,
          'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
    }
  }

  /// Updates Pi-hole (core/web/FTL) via `pihole -up` — as a Pi-Job
  /// (`pihole-update`), so a dropped connection does not stop it.
  Future<void> updatePihole({
    required SshConfig config,
    required void Function(String line) onLog,
    void Function(JobRef ref)? onJobStarted,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Aktualisiere Pi-hole …');
          final r = await _runJob(runner, log, config,
              kind: jobKindPiholeUpdate,
              payload: buildPiholeUpdatePayload(),
              onJobStarted: onJobStarted);
          _requireJobSuccess(log, r);
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

  /// Installs Tailscale via the official installer + enables the daemon. Root.
  /// Cheap reachability check: connect, run `true`, done. Used by the
  /// home/tailnet fallback and to PROVE that this phone reaches the tailnet
  /// before the app claims the remote access is set up.
  ///
  /// Returns false instead of throwing — "not reachable" is an answer, not an
  /// error. The one exception is [HostKeyChangedException]: a changed host key
  /// is a security event and must never be flattened into "unreachable".
  Future<bool> probeConnection({
    required SshConfig config,
    void Function(String line)? onLog,
  }) async {
    try {
      await _withConnection<void>(
        config: config,
        onLog: onLog ?? (_) {},
        body: (runner, log) async {
          await runner.run('true');
        },
      );
      return true;
    } on EvccUpdateException catch (e) {
      // _withConnection already translated the raw HostKeyChangedException into
      // this kind. Everything else ("no route", auth, timeout) legitimately
      // means "not reachable" — a changed host key does not.
      if (e.kind == UpdateErrorKind.hostKeyChanged) rethrow;
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> installTailscale({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Installiere Tailscale …');
          await _fixEolSources(runner, log, config);
          await _runRootScriptExpectMarker(runner, log, config,
              script: tailscaleInstallScript,
              successMarker: 'TAILSCALE_INSTALLED',
              failMsg: 'Installation von Tailscale fehlgeschlagen');
        },
      );

  /// Runs `tailscale up` (as root) and returns the login URL to open, or null
  /// when it connected without needing re-auth.
  Future<String?> tailscaleUp({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<String?>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Verbinde mit Tailscale …');
          final r = await runner.run(installShellCommand,
              stdin: await _rootStdin(runner, config, tailscaleUpScript));
          // A rejected sudo password yields no login URL — don't report that as
          // "already connected"; surface it as a real auth error.
          var combined = '${r.stdout}\n${r.stderr}';
          if (isSudoPasswordFailure(combined)) {
            throw const EvccUpdateException(UpdateErrorKind.sudo,
                'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
          }
          var out = r.stdout;
          // Has to log in again but carries non-default settings (a shared home
          // network, say): the bare `up` refuses and names the flags it wants.
          // Restate exactly those — nothing changes, the login goes ahead.
          final restate = parseTailscaleUpRestateFlags(combined);
          if (restate != null) {
            log('Tailscale verlangt die bestehenden Einstellungen – '
                'wiederhole mit ${restate.join(' ')} …');
            final again = await runner.run(installShellCommand,
                stdin: await _rootStdin(
                    runner, config, buildTailscaleUpScript(restate)));
            out = again.stdout;
            combined = '${again.stdout}\n${again.stderr}';
          }
          final url = parseTailscaleAuthUrl(out);
          if (url != null) return url; // needs a browser login
          // No login URL: it must have connected — verify via the marker, else
          // surface the failure instead of reporting a phantom "connected".
          if (!combined.contains('TS_UP_OK')) {
            // The message points to the log — so the output has to be there.
            final detail = combined.trim();
            if (detail.isNotEmpty) log(detail);
            throw const EvccUpdateException(
                UpdateErrorKind.unknown,
                'Tailscale konnte nicht verbinden (Details im Log) – läuft der '
                'Dienst (tailscaled)? Ggf. neu installieren.');
          }
          return null;
        },
      );

  /// Uninstalls a service the app manages: 'evcc' (apt), 'homeassistant'
  /// (the app's container), 'piconnect', 'tailscale' or an apt service from
  /// [knownAptServices]. [purge] false keeps configuration and data, so a
  /// reinstall picks them up; true removes them too. Each script checks first
  /// and refuses (`UNINSTALL_REFUSED: …`, nothing changed) when the removal
  /// would be unsafe or incomplete — that reason becomes the message.
  Future<void> uninstallService({
    required SshConfig config,
    required String id,
    required bool purge,
    required void Function(String line) onLog,
  }) {
    final apt = knownAptServices.where((s) => s.id == id).firstOrNull;
    if (apt == null &&
        !const ['evcc', 'homeassistant', 'piconnect', 'tailscale']
            .contains(id)) {
      return Future.error(
          ArgumentError.value(id, 'id', 'nicht deinstallierbar'));
    }
    const overTailnet = EvccUpdateException(
        UpdateErrorKind.unknown,
        'Die Verbindung läuft über Tailscale und würde beim Entfernen '
        'abreißen – bitte über die Heimnetz-Adresse verbinden.');
    // Checked before connecting: the session would cut itself off.
    if (id == 'tailscale' && isTailnetHost(config.host)) {
      return Future.error(overTailnet);
    }
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        final String name, script, marker;
        switch (id) {
          case 'evcc':
            (name, script, marker) = (
              'evcc',
              buildEvccUninstallScript(purge: purge),
              evccRemovedMarker
            );
          case 'homeassistant':
            (name, script, marker) = (
              'Home Assistant',
              buildHomeAssistantUninstallScript(purge: purge),
              homeAssistantRemovedMarker
            );
          case 'piconnect':
            final user =
                config.username.trim().isEmpty ? 'pi' : config.username.trim();
            try {
              script = buildPiConnectUninstallScript(user: user, purge: purge);
            } on ArgumentError {
              throw EvccUpdateException(
                  UpdateErrorKind.unknown,
                  'Der Benutzername „$user" lässt sich nicht sicher an das '
                  'Skript übergeben – Pi Connect bitte von Hand entfernen.');
            }
            (name, marker) = ('Raspberry Pi Connect', piConnectRemovedMarker);
          case 'tailscale':
            // Also when the session arrives through the tailnet under a home
            // address (a shared home network): sudo hides SSH_CONNECTION, so
            // it is read without sudo first.
            final probe = await runner.run(tailscaleSessionProbe);
            if (isTailnetClient(probe.stdout.trim())) {
              // Under a home address, through the shared home network — so
              // "use the home address" would be no advice at all.
              throw const EvccUpdateException(
                  UpdateErrorKind.unknown, tailscaleSessionRefusal);
            }
            (name, script, marker) = (
              'Tailscale',
              buildTailscaleUninstallScript(purge: purge),
              tailscaleRemovedMarker
            );
          default:
            (name, script, marker) = (
              apt!.name,
              buildAptServiceUninstallScript(apt, purge: purge),
              aptServiceRemovedMarker
            );
        }
        log(purge
            ? 'Entferne $name samt Konfiguration und Daten …'
            : 'Entferne $name – Konfiguration und Daten bleiben …');
        await _runRootScriptExpectMarker(runner, log, config,
            script: script,
            successMarker: marker,
            failMsg: '$name konnte nicht deinstalliert werden');
      },
    );
  }

  /// The Tailscale node's subnet-router state from the detection sections.
  /// Unreadable prefs (an unusual build) fall back to "whatever is approved
  /// counts as offered" — a pending approval is then simply not visible.
  static SubnetRoutes _subnetRoutes(Map<String, String> sec) {
    final self = sec['TS_SELF'] ?? '';
    final approved = parseApprovedRoutes(self) ?? const <String>[];
    return SubnetRoutes(
      lan: parseLanSubnets(sec['TS_LAN'] ?? ''),
      advertised: parseAdvertisedRoutes(sec['TS_PREFS'] ?? '') ?? approved,
      approved: approved,
      mine: parseAppRoutes(sec['TS_FWD'] ?? ''),
      machine: parseTailnetMachineName(self) ?? '',
    );
  }

  /// Shares the Pi's home network into the tailnet (subnet router): switches on
  /// IPv4 forwarding and ADDS the home network to the advertised routes — a
  /// route set by hand stays. Returns the home network(s). The route still has
  /// to be approved in the Tailscale console unless it was approved before.
  Future<List<String>> tailscaleShareLan({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<List<String>>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          final (:lan, :advertised, :mine, exitNode: _) =
              await _readRouteState(runner);
          if (lan.isEmpty) {
            throw const EvccUpdateException(
                UpdateErrorKind.unknown,
                'Kein Heimnetz gefunden – der Pi hat keine private '
                'IPv4-Adresse (10.x, 172.16–31.x, 192.168.x).');
          }
          log('Gebe das Heimnetz ${lan.join(', ')} über Tailscale frei …');
          final routes = routesWithLan(advertised, lan);
          await _runRootScriptExpectMarker(runner, log, config,
              script: buildTailscaleAdvertiseScript(routes, mine: [
                for (final r in routes)
                  if (lan.contains(r) || mine.contains(r)) r,
              ]),
              successMarker: tailscaleRoutesMarker,
              failMsg: 'Heimnetz konnte nicht freigegeben werden');
          return lan;
        },
      );

  /// Stops sharing the home network: removes it from the advertised routes
  /// (other routes stay) and, once none are left, the app's forwarding file.
  Future<void> tailscaleUnshareLan({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          final (:lan, :advertised, :mine, :exitNode) =
              await _readRouteState(runner);
          log('Beende die Freigabe des Heimnetzes …');
          // The current home network AND whatever the app added before — the
          // Pi may have moved networks since. Routes set by hand stay.
          await _runRootScriptExpectMarker(runner, log, config,
              script: buildTailscaleAdvertiseScript(
                  routesWithoutLan(advertised, [...lan, ...mine]),
                  keepForwarding: exitNode),
              successMarker: tailscaleRoutesMarker,
              failMsg: 'Freigabe des Heimnetzes konnte nicht beendet werden');
        },
      );

  /// Fresh read right before a route change — never the (possibly cached)
  /// card state. Unreadable prefs count as "nothing advertised".
  Future<
      ({
        List<String> lan,
        List<String> advertised,
        List<String> mine,
        bool exitNode,
      })> _readRouteState(SshRunner runner) async {
    final r = await runner.run(detectShellCommand,
        stdin: '${buildDetectBatch([
              ('TS_LAN', lanRoutesCommand),
              ('TS_PREFS', tailscalePrefsCommand),
              ('TS_FWD', tailscaleForwardingProbe),
            ])}\n');
    final sec = splitDetectSections(r.stdout);
    final prefs = sec['TS_PREFS'] ?? '';
    return (
      lan: parseLanSubnets(sec['TS_LAN'] ?? ''),
      advertised: parseAdvertisedRoutes(prefs) ?? const <String>[],
      mine: parseAppRoutes(sec['TS_FWD'] ?? ''),
      exitNode: parseAdvertisesExitNode(prefs),
    );
  }

  /// Disconnects (`tailscale down`) or logs out (`tailscale logout`). Root.
  Future<void> tailscaleSet({
    required SshConfig config,
    required bool logout,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('\$ tailscale ${logout ? 'logout' : 'down'}');
          final r = await runner.run(
              logout ? tailscaleLogoutCommand : tailscaleDownCommand,
              stdin: '${config.password}\n', onOutput: (c) {
            final t = c.trimRight();
            if (t.isNotEmpty) log(t);
          });
          final out = '${r.stdout}${r.stderr}'.trim();
          if (isSudoPasswordFailure(out)) {
            throw const EvccUpdateException(UpdateErrorKind.sudo,
                'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
          }
          if (r.exitCode == null) {
            throw const EvccUpdateException(
                UpdateErrorKind.unknown, _resultUnknown);
          }
          if (r.exitCode != 0) {
            throw EvccUpdateException(
                UpdateErrorKind.unknown,
                'tailscale ${logout ? 'logout' : 'down'} fehlgeschlagen '
                '(Exit ${r.exitCode}). Details im Log.');
          }
          if (out.isNotEmpty) log(out);
        },
      );

  /// Installs Raspberry Pi Connect (headless/lite) + enables linger. Root.
  Future<void> installPiConnect({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Installiere Raspberry Pi Connect …');
          await _runRootScriptExpectMarker(runner, log, config,
              script: piConnectInstallScript,
              successMarker: 'PICONNECT_INSTALLED',
              failMsg: 'Installation von Pi Connect fehlgeschlagen');
        },
      );

  /// Starts sign-in and returns the verify URL (open it in a browser + log in
  /// with the Raspberry Pi ID). No sudo — it's a user service.
  Future<String?> piConnectSignin({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<String?>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Starte Anmeldung bei Pi Connect …');
          final r = await runner.run(piConnectSigninCommand);
          return parseSigninUrl(r.stdout);
        },
      );

  /// Turns Pi Connect on / off (user service, no sudo).
  Future<void> piConnectSet({
    required SshConfig config,
    required bool on,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('\$ rpi-connect ${on ? 'on' : 'off'}');
          final r = await runner.run(
              on ? piConnectOnCommand : piConnectOffCommand,
              onOutput: (c) {
                final t = c.trimRight();
                if (t.isNotEmpty) log(t);
              });
          final out = '${r.stdout}${r.stderr}'.trim();
          log(out.isEmpty
              ? 'Fertig (Fernzugriff ${on ? 'aktiviert' : 'pausiert'}).'
              : out);
        },
      );

  /// Signs the Pi out of Pi Connect (user service, no sudo).
  Future<void> piConnectSignout({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('\$ rpi-connect signout');
          final r = await runner.run(piConnectSignoutCommand, onOutput: (c) {
            final t = c.trimRight();
            if (t.isNotEmpty) log(t);
          });
          final out = '${r.stdout}${r.stderr}'.trim();
          if (out.isNotEmpty) log(out);
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

  /// Uploads local [bytes] to a remote [path] (root). Content is base64-encoded
  /// and written atomically; success requires the UPLOAD_OK marker.
  Future<void> uploadFile({
    required SshConfig config,
    required String path,
    required Uint8List bytes,
    required void Function(String line) onLog,
  }) {
    final b64 = base64.encode(bytes);
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Lade hoch: $path …');
        await _runRootScriptExpectMarker(runner, log, config,
            script: buildUploadScript(path: path, base64Content: b64),
            successMarker: 'UPLOAD_OK',
            failMsg: 'Hochladen fehlgeschlagen');
      },
    );
  }

  /// Downloads a (world-readable) file — e.g. a backup archive — to raw bytes.
  /// The size is checked FIRST so an oversized file never starts transferring,
  /// and the decoded length is verified afterwards (truncation = error).
  Future<Uint8List> downloadFile({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) =>
      _withConnection<Uint8List>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Lade herunter: $path …');
          final s = await runner.run(buildFileSizeCommand(path));
          final size = int.tryParse(s.stdout.trim());
          if (size == null) {
            throw const EvccUpdateException(UpdateErrorKind.unknown,
                'Datei nicht gefunden oder nicht lesbar.');
          }
          if (size > kBackupDownloadLimit) {
            throw EvccUpdateException(
                UpdateErrorKind.unknown,
                'Datei zu groß (${(size / (1024 * 1024)).ceil()} MB, max '
                '${kBackupDownloadLimit ~/ (1024 * 1024)} MB).');
          }
          final r = await runner.run(buildDownloadFileCommand(path));
          final Uint8List bytes;
          try {
            bytes = base64.decode(r.stdout.replaceAll(RegExp(r'\s'), ''));
          } catch (_) {
            throw const EvccUpdateException(UpdateErrorKind.unknown,
                'Übertragung fehlgeschlagen (keine gültigen Daten).');
          }
          if (bytes.length != size) {
            throw const EvccUpdateException(UpdateErrorKind.unknown,
                'Übertragung unvollständig – bitte erneut versuchen.');
          }
          return bytes;
        },
      );

  /// Deletes a remote file or directory (root). No marker — a clean exit with no
  /// sudo rejection is success.
  Future<void> deleteRemotePath({
    required SshConfig config,
    required String path,
    required bool isDir,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Lösche: $path …');
          final r = await runner.run(
              buildDeleteCommand(path: path, isDir: isDir),
              stdin: '${config.password}\n');
          final out = '${r.stdout}${r.stderr}';
          if (isSudoPasswordFailure(out)) {
            throw const EvccUpdateException(
                UpdateErrorKind.sudo, 'sudo-Passwort abgelehnt.');
          }
          if (r.exitCode == null) {
            throw const EvccUpdateException(
                UpdateErrorKind.unknown, _resultUnknown);
          }
          if (r.exitCode != 0) {
            // Redact: raw remote output can echo the password on a NOPASSWD Pi,
            // and this message becomes the (otherwise un-redacted) status banner.
            throw EvccUpdateException(
                UpdateErrorKind.unknown,
                out.trim().isEmpty
                    ? 'Löschen fehlgeschlagen.'
                    : redactPassword(out.trim(), config.password));
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

  /// Installs the scheduled-backup timer (evcc + Pi-hole, rotation). Root.
  Future<void> enableScheduledBackup({
    required SshConfig config,
    required String onCalendar,
    required int keep,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Richte geplante Backups ein …');
          await _runRootScriptExpectMarker(runner, log, config,
              script: buildScheduledBackupInstallScript(
                  onCalendar: onCalendar, keep: keep),
              successMarker: 'BACKUP_TIMER_INSTALLED',
              failMsg: 'Einrichten der geplanten Backups fehlgeschlagen');
        },
      );

  /// Removes the scheduled-backup timer again. Root.
  Future<void> disableScheduledBackup({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Deaktiviere geplante Backups …');
          await _runRootScriptExpectMarker(runner, log, config,
              script: buildScheduledBackupRemoveScript(),
              successMarker: 'BACKUP_TIMER_REMOVED',
              failMsg: 'Entfernen der geplanten Backups fehlgeschlagen');
        },
      );

  Future<ScheduledBackupStatus> readScheduledBackupStatus({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<ScheduledBackupStatus>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          final r = await runner.run(scheduledBackupStatusCommand);
          return parseScheduledBackupStatus(r.stdout);
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
            stdin: await _rootStdin(runner, config, buildCleanupScript()),
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
  /// Returns the web password it set, or null when one already existed. The
  /// password travels only inside the script on stdin — never through the log.
  Future<String?> installPihole({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<String?>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Installiere Pi-hole … (unbeaufsichtigt, dauert ein paar Minuten)');
          final pw = _webPassword();
          // Marker: the multi-step installer runs under `set -e`, so INSTALL_OK
          // is only reached if every step succeeded (a half-run install, incl.
          // a signal-killed channel with exitCode == null, fails here).
          final out = await _runRootScriptExpectMarker(runner, log, config,
              script:
                  '${buildPiholeInstallScript(webPassword: pw)}\necho INSTALL_OK',
              successMarker: 'INSTALL_OK',
              failMsg: 'Pi-hole-Installation fehlgeschlagen');
          log('Pi-hole installiert – Einrichtung im Browser unter /admin.');
          return out.contains(piholePasswordSetMarker) ? pw : null;
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
          // crash would otherwise be reported as success). Running only: a
          // container in its restart loop is listed by plain `docker ps` too.
          var verify = await runner.run(dockerListRunningCommand);
          if (isDockerPermissionError('${verify.stdout}\n${verify.stderr}')) {
            verify = await runner.run(dockerListRunningSudoCommand,
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
          sudo ? dockerListRunningSudoCommand : dockerListRunningCommand,
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

  /// Completes a dpkg run that was killed mid-way: `dpkg --configure -a`,
  /// `apt-get -f install` (unpacked packages whose new dependencies never
  /// arrived), `dpkg --configure -a` again — as a Pi-Job (`package-repair`).
  /// Until this has run, apt refuses EVERY install on that Pi — see
  /// [isDpkgInterrupted]. Upgrades nothing by itself.
  Future<void> repairPackageState({
    required SshConfig config,
    required void Function(String line) onLog,
    void Function(JobRef ref)? onJobStarted,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Repariere den Paketzustand …');
          final r = await _runJob(runner, log, config,
              kind: jobKindPackageRepair,
              payload: buildPackageRepairPayload(),
              onJobStarted: onJobStarted);
          _requireJobSuccess(log, r);
        },
      );

  /// Refreshes the package index only (`apt-get update`) — installs nothing.
  /// Detection simulates against that index and never refreshes it, so once it
  /// ages past [kAptIndexMaxAge] the app stops claiming to know a service's
  /// currency; this is the one-tap remedy behind that hint.
  Future<void> refreshAptIndex({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<void>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Paketlisten aktualisieren …');
          await _fixEolSources(runner, log, config);
          // Same tolerance as the upgrade path: one flaky third-party repo must
          // not sink a refresh that updated everything else.
          await _sudoCommand(runner, log, config,
              'LC_ALL=C sudo -S apt-get update -qq', 'apt-get update',
              checkExit: false);
          log('Paketlisten aktualisiert.');
        },
      );

  /// Whole-system upgrade as a Pi-Job (`system-upgrade`): EOL-source fix,
  /// repair chain, list refresh (tolerant, but reported as
  /// [SystemUpgradeResult.listsIncomplete]), `apt-get full-upgrade` — all
  /// non-interactive, on the Pi, independent of this connection.
  Future<SystemUpgradeResult> upgradeSystem({
    required SshConfig config,
    required void Function(String line) onLog,
    void Function(JobRef ref)? onJobStarted,
  }) =>
      _withConnection<SystemUpgradeResult>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('System-Upgrade (alle Pakete) …');
          final r = await _runJob(runner, log, config,
              kind: jobKindSystemUpgrade,
              payload: buildSystemUpgradePayload(),
              onJobStarted: onJobStarted);
          final o = _requireJobSuccess(log, r);
          return SystemUpgradeResult(listsIncomplete: o.listsIncomplete);
        },
      );

  /// Updates a single apt [package] (Grafana, InfluxDB, Tailscale, …) as a
  /// Pi-Job (`package-update`): tolerant list refresh, then `--only-upgrade`
  /// so a not-installed package is never pulled in. [package] comes from our
  /// own descriptors and is validated as a package name anyway.
  Future<void> updateAptPackage({
    required SshConfig config,
    required String package,
    required void Function(String line) onLog,
    void Function(JobRef ref)? onJobStarted,
  }) {
    final String payload;
    try {
      payload = buildPackageUpdatePayload(package);
    } on ArgumentError {
      return Future.error(EvccUpdateException(UpdateErrorKind.unknown,
          'Ungültiger Paketname „$package" – nichts gestartet.'));
    }
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Aktualisiere $package …');
        final r = await _runJob(runner, log, config,
            kind: jobKindPackageUpdate,
            payload: payload,
            onJobStarted: onJobStarted);
        _requireJobSuccess(log, r);
      },
    );
  }

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
        await _fixEolSources(runner, log, config);
        // Marker: the install scripts run under `set -e`, so INSTALL_OK prints
        // only on full success (guards against a partially-run root install).
        await _runRootScriptExpectMarker(runner, log, config,
            script: '$script\necho INSTALL_OK',
            successMarker: 'INSTALL_OK',
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
          sudo ? dockerListRunningSudoCommand : dockerListRunningCommand,
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
      stdin: sudo ? await _rootStdin(runner, config, script) : '$script\n',
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
    if (result.exitCode == null) {
      throw const EvccUpdateException(UpdateErrorKind.unknown, _resultUnknown);
    }
    if (result.exitCode != 0) {
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
  Future<String> _runRootScriptExpectMarker(
    SshRunner runner,
    void Function(String) log,
    SshConfig config, {
    required String script,
    required String successMarker,
    required String failMsg,
  }) async {
    final result = await runner.run(
      installShellCommand,
      stdin: await _rootStdin(runner, config, script),
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
      // An uninstall script that refused changed nothing and says why — that
      // reason is the message, not a pointer to the log.
      final refusal = parseUninstallRefusal(combined);
      if (refusal != null) {
        throw EvccUpdateException(UpdateErrorKind.unknown, refusal);
      }
      final cause = _aptFailureCause(combined);
      throw EvccUpdateException(UpdateErrorKind.unknown,
          cause != null ? '$failMsg — $cause' : '$failMsg (Details im Log).');
    }
    return combined;
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
      stdin: await _rootStdin(runner, config, script),
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
          stdin: await _rootStdin(runner, config, buildBackupScript()),
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
        // Marker discipline: a destructive tar-over-/ must never look successful
        // when killed mid-run (exitCode == null). The evcc-active post-check
        // below additionally catches a restored-but-broken config.
        await _runRootScriptExpectMarker(runner, log, config,
            script: buildRestoreScript(path),
            successMarker: 'RESTORE_OK',
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
        if (result.exitCode == null) {
          throw const EvccUpdateException(
              UpdateErrorKind.unknown, _resultUnknown);
        }
        // A non-zero restart command (e.g. an undetected sudo rejection) must
        // not be swallowed — otherwise the old instance keeps running and
        // is-active still reports 'active', a false "Dienst läuft wieder".
        if (result.exitCode != 0) {
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
          // Cap output server-side so a high-volume command (or a runaway like
          // `cat /dev/urandom`) can't exhaust memory — head closing the pipe
          // also stops the producer.
          final exec = '{ ${prep.exec} ; } 2>&1 | head -c 262144';
          final result = await runner.run(
            exec,
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
        _checkPowerGuard(combined, 'Neustart');
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

  /// Powers the Pi off. Like [reboot], the SSH connection drops as a result and
  /// that is treated as success; a rejected sudo password (no disconnect) is
  /// reported. Unlike a reboot, the Pi stays OFF until physically powered on.
  /// Installs [publicKeyLine] into the connecting user's `~/.ssh/authorized_keys`
  /// (no root). The private key stays on the phone; success needs the
  /// `KEY_INSTALLED` marker (not just exit 0).
  Future<void> installSshKey({
    required SshConfig config,
    required String publicKeyLine,
    required void Function(String line) onLog,
  }) {
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Installiere den öffentlichen Schlüssel …');
        final result =
            await runner.run(buildInstallAuthorizedKeyScript(publicKeyLine));
        final combined = '${result.stdout}${result.stderr}';
        if (!combined.contains('KEY_INSTALLED')) {
          throw const EvccUpdateException(
            UpdateErrorKind.unknown,
            'Schlüssel-Installation nicht bestätigt. Details im Log.',
          );
        }
        log('Öffentlicher Schlüssel installiert.');
      },
    );
  }

  /// Restarts a systemd unit (sudo). Non-zero exit surfaces an error.
  Future<void> restartSystemdUnit({
    required SshConfig config,
    required String unit,
    required void Function(String line) onLog,
  }) {
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Starte $unit neu …');
        final r = await runner.run(
            'LC_ALL=C sudo -S systemctl restart ${shSingleQuote(unit)}',
            stdin: '${config.password}\n');
        final combined = '${r.stdout}\n${r.stderr}';
        if (isSudoPasswordFailure(combined)) {
          throw const EvccUpdateException(UpdateErrorKind.sudo,
              'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
        }
        if (r.exitCode != 0) {
          throw EvccUpdateException(UpdateErrorKind.unknown,
              'Neustart von $unit fehlgeschlagen. Details im Log.');
        }
      },
    );
  }

  /// Lists all Docker containers (running + stopped). Empty if Docker isn't
  /// installed; a rejected sudo password is surfaced.
  Future<List<DockerContainer>> dockerContainers({
    required SshConfig config,
    required void Function(String line) onLog,
  }) {
    return _withConnection<List<DockerContainer>>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Lese Docker-Container …');
        final r =
            await runner.run(dockerPsSudoCommand, stdin: '${config.password}\n');
        if (isSudoPasswordFailure('${r.stdout}\n${r.stderr}')) {
          throw const EvccUpdateException(UpdateErrorKind.sudo,
              'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
        }
        return parseDockerPs(r.stdout);
      },
    );
  }

  /// Restarts one container by name (sudo). Non-zero exit surfaces an error.
  Future<void> restartDockerContainer({
    required SshConfig config,
    required String name,
    required void Function(String line) onLog,
  }) {
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Starte Container $name neu …');
        final r = await runner.run(buildDockerRestartCommand(name),
            stdin: '${config.password}\n');
        final combined = '${r.stdout}\n${r.stderr}';
        if (isSudoPasswordFailure(combined)) {
          throw const EvccUpdateException(UpdateErrorKind.sudo,
              'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
        }
        if (r.exitCode != 0) {
          throw EvccUpdateException(UpdateErrorKind.unknown,
              'Neustart von $name fehlgeschlagen. Details im Log.');
        }
      },
    );
  }

  /// Updates ANY container from the Docker overview by name: compose-managed
  /// ones via `docker compose pull` + `up -d` of just that service, plain ones
  /// via image-pull + recreate with the same rollback net as the evcc path
  /// (old container renamed, restored on a crashing start). Refused: Pi-Tool's
  /// own rollback containers and digest-pinned images. Experimental — the
  /// recreate reconstructs `docker run` from `docker inspect` (whitelist).
  Future<void> updateDockerContainer({
    required SshConfig config,
    required String name,
    required void Function(String line) onLog,
  }) async {
    if (name.endsWith('-evccpitool-old')) {
      throw const EvccUpdateException(
        UpdateErrorKind.unknown,
        'Das ist ein Pi-Tool-Rollback-Container — er ist die Rückfalllinie '
        'des letzten Updates und wird nicht selbst aktualisiert.',
      );
    }
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        final inspectCmd = dockerInspectJsonSudoCommand(name);
        log('\$ $inspectCmd');
        final inspect =
            await runner.run(inspectCmd, stdin: '${config.password}\n');
        if (isSudoPasswordFailure('${inspect.stdout}\n${inspect.stderr}')) {
          throw const EvccUpdateException(UpdateErrorKind.sudo,
              'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
        }
        final obj = firstInspectObject(inspect.stdout);
        if (obj == null) {
          throw EvccUpdateException(UpdateErrorKind.unknown,
              'Konnte den Container "$name" nicht inspizieren.');
        }

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
                  '';
          if (image.isEmpty) {
            throw EvccUpdateException(UpdateErrorKind.unknown,
                'Konnte das Image von "$name" nicht ermitteln.');
          }
          if (image.contains('@sha256:')) {
            throw const EvccUpdateException(
              UpdateErrorKind.unknown,
              'Das Image ist per Digest gepinnt (@sha256:…) und kann nicht '
              'automatisch aktualisiert werden – bitte in der Container-'
              'Definition ein Image-Tag setzen und manuell neu ziehen.',
            );
          }
          log('Container ohne docker compose – aktualisiere per Image-Pull + '
              'Neuanlage. Der alte Container bleibt als Backup erhalten.');
          script = dockerRunRecreateScript(
            name: name,
            image: image,
            runCommand: buildDockerRunCommand(obj, image: image),
          );
        }

        await _runRootScript(runner, log, config,
            sudo: true,
            script: script,
            failMsg: 'Container-Update fehlgeschlagen');

        // The recreate script verifies internally; the compose path doesn't —
        // probe either way so "fertig" always means "läuft".
        final probe = await runner.run(buildDockerRunningProbe(name),
            stdin: '${config.password}\n');
        final state = probe.stdout.trim();
        if (state != 'true') {
          // compose may legitimately rename the container (v1 `proj_svc_1` →
          // v2 `proj-svc-1`), so "not found" there is not proof of failure —
          // the script itself already failed hard on a real error (set -e).
          final vanished = state.isEmpty;
          if (compose != null && vanished) {
            log('Hinweis: Container "$name" ist unter diesem Namen nicht mehr '
                'zu finden — docker compose benennt ihn beim Neuanlegen '
                'gelegentlich um. Bitte in der Übersicht nachsehen.');
            return;
          }
          throw EvccUpdateException(
            UpdateErrorKind.serviceInactive,
            'Container "$name" läuft nach dem Update nicht. Details im Log.',
          );
        }
        log('Container "$name" aktualisiert und läuft.');
      },
    );
  }

  /// Last 200 log lines of a container.
  Future<String> fetchDockerLogs({
    required SshConfig config,
    required String name,
    required void Function(String line) onLog,
  }) {
    return _withConnection<String>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        final r = await runner.run(buildDockerLogsCommand(name),
            stdin: '${config.password}\n');
        return '${r.stdout}${r.stderr}';
      },
    );
  }

  /// Read-only disk-usage analysis of [path] (sudo). Returns the biggest
  /// subdirectories + files at that level; a rejected sudo password is surfaced.
  Future<List<DiskEntry>> diskUsage({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) {
    return _withConnection<List<DiskEntry>>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Analysiere Speicher in $path …');
        final r = await runner.run(
          buildStorageProbe(path),
          stdin: '${config.password}\n',
        );
        if (isSudoPasswordFailure('${r.stdout}\n${r.stderr}')) {
          throw const EvccUpdateException(
            UpdateErrorKind.sudo,
            'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
          );
        }
        return parseStorageBreakdown(r.stdout, queryPath: path);
      },
    );
  }

  /// Opens a throwaway connection using ONLY [config]'s private key and runs a
  /// marker command — proves the Pi actually accepts the new key BEFORE the UI
  /// switches a profile to key auth. Returns false (or throws) if key auth is
  /// rejected; the caller must keep password auth in that case.
  Future<bool> verifyKeyAuth({
    required SshConfig config,
    required void Function(String line) onLog,
  }) {
    return _withConnection<bool>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        final r = await runner.run('echo SSH_KEY_AUTH_OK');
        return '${r.stdout}${r.stderr}'.contains('SSH_KEY_AUTH_OK');
      },
    );
  }

  /// Read-only security audit: runs [buildSecurityProbe] (sudo, no mutation) and
  /// returns the parsed findings. A rejected sudo password is surfaced.
  Future<List<SecurityFinding>> runSecurityCheck({
    required SshConfig config,
    required void Function(String line) onLog,
  }) {
    return _withConnection<List<SecurityFinding>>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Prüfe Sicherheitseinstellungen …');
        final result = await runner.run(
          buildSecurityProbe(),
          stdin: '${config.password}\n',
        );
        final combined = '${result.stdout}\n${result.stderr}';
        if (isSudoPasswordFailure(combined)) {
          throw const EvccUpdateException(
            UpdateErrorKind.sudo,
            'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
          );
        }
        return parseSecurityReport(result.stdout);
      },
    );
  }

  /// Wires the monitoring stack (InfluxDB → evcc.yaml → Grafana dashboard) in
  /// one root script — see stack_wiring.dart for why it is a single script
  /// (the access token never leaves the Pi). Marker-gated; fail-soft for
  /// missing parts, hard fail with evcc.yaml rollback on a rejected config.
  Future<StackWiringOutcome> wireMonitoringStack({
    required SshConfig config,
    required void Function(String line) onLog,
  }) =>
      _withConnection<StackWiringOutcome>(
        config: config,
        onLog: onLog,
        body: (runner, log) async {
          log('Verdrahte Monitoring-Stack (InfluxDB → evcc → Grafana) …');
          // Three-way marker instead of the usual two: WIRE_PARTIAL means the
          // script skipped a half on purpose (Docker-evcc / no Grafana) — that
          // must reach the user as a partial result, not as green success.
          final buf = StringBuffer();
          final result = await runner.run(
            installShellCommand,
            stdin: await _rootStdin(runner, config, buildStackWiringScript()),
            onOutput: (chunk) {
              buf.write(chunk);
              final t = chunk.trimRight();
              if (t.isNotEmpty) log(t);
            },
          );
          final combined = '$buf\n${result.stdout}\n${result.stderr}';
          if (isSudoPasswordFailure(combined)) {
            throw const EvccUpdateException(UpdateErrorKind.sudo,
                'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
          }
          if (combined.contains('WIRE_OK')) return StackWiringOutcome.wired;
          if (combined.contains('WIRE_PARTIAL')) {
            return StackWiringOutcome.partial;
          }
          throw const EvccUpdateException(UpdateErrorKind.unknown,
              'Stack-Verdrahtung fehlgeschlagen. Details im Log.');
        },
      );

  /// Applies one [SecurityFix] as root (marker-gated). The root-login fix is
  /// refused when the app itself is connected as root — the fix would lock
  /// this very login out on the next connect. Returns the new Pi-hole web
  /// password for [SecurityFix.piholePassword] when it set one, else null.
  Future<String?> fixSecurity({
    required SshConfig config,
    required SecurityFix fix,
    required void Function(String line) onLog,
  }) async {
    if (fix == SecurityFix.rootLogin &&
        config.username.trim().toLowerCase() == 'root') {
      throw const EvccUpdateException(
        UpdateErrorKind.unknown,
        'Du bist als root verbunden — diesen Login abzuschalten würde dich '
        'aussperren. Lege zuerst einen eigenen Benutzer an.',
      );
    }
    return _withConnection<String?>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Wende Sicherheits-Fix an …');
        if (fix == SecurityFix.piholePassword) {
          final pw = _webPassword();
          final out = await _runRootScriptExpectMarker(runner, log, config,
              script: buildPiholeSetPasswordScript(pw),
              successMarker: piholePasswordDoneMarker,
              failMsg: 'Pi-hole-Passwort konnte nicht gesetzt werden');
          return out.contains(piholePasswordSetMarker) ? pw : null;
        }
        if (fix != SecurityFix.rootLogin) {
          await _fixEolSources(runner, log, config); // installs a package
        }
        await _runRootScriptExpectMarker(runner, log, config,
            script: buildSecurityFixScript(fix),
            successMarker: 'SECFIX_OK',
            failMsg: 'Sicherheits-Fix fehlgeschlagen');
        log('Sicherheits-Fix angewendet.');
        return null;
      },
    );
  }

  Future<void> shutdown({
    required SshConfig config,
    required void Function(String line) onLog,
  }) {
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Fahre den Pi herunter …');
        log('\$ $shutdownCommand');
        var combined = '';
        int? exitCode;
        var disconnected = false;
        try {
          final result = await runner.run(
            shutdownCommand,
            stdin: '${config.password}\n',
            onOutput: (chunk) {
              final t = chunk.trimRight();
              if (t.isNotEmpty) log(t);
            },
          );
          combined = '${result.stdout}\n${result.stderr}';
          exitCode = result.exitCode;
        } catch (_) {
          // poweroff drops the SSH connection — expected, treat as success.
          disconnected = true;
        }
        if (isSudoPasswordFailure(combined)) {
          throw const EvccUpdateException(
            UpdateErrorKind.sudo,
            'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
          );
        }
        _checkPowerGuard(combined, 'Herunterfahren');
        // A real poweroff either drops the connection (caught above) or returns
        // exit 0. A non-zero exit WITHOUT a disconnect (e.g. sudoers forbids
        // `poweroff`) means the Pi did not shut down — surface it.
        if (!disconnected && exitCode != null && exitCode != 0) {
          throw EvccUpdateException(
            UpdateErrorKind.unknown,
            'Herunterfahren fehlgeschlagen (Exit $exitCode). Details im Log.',
          );
        }
        log('Der Pi fährt herunter – er bleibt aus, bis du ihn wieder einschaltest.');
      },
    );
  }

  // -------------------------------------------------------------------------
  // Pi-Jobs (see pi_job.dart)
  // -------------------------------------------------------------------------

  /// Re-follows a job started earlier (by this app or another phone): streams
  /// its full log from the start and evaluates it exactly like the live run.
  /// A job that ended with an error is an outcome ([JobOutcome.success]
  /// false), not an exception. Throws when the Pi no longer knows the job,
  /// when it was lost (reboot), or [JobException] when following stops again.
  Future<JobOutcome> followJob({
    required SshConfig config,
    required String jobId,
    required void Function(String line) onLog,
    void Function(JobRef ref)? onJobStarted,
  }) {
    if (!isValidJobId(jobId)) {
      return Future.error(ArgumentError.value(jobId, 'jobId'));
    }
    return _withConnection<JobOutcome>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        if (_cancelRequested) {
          throw const EvccUpdateException(
              UpdateErrorKind.cancelled, 'Abgebrochen.');
        }
        log('Lese den Pi-Job mit (ID $jobId) …');
        _jobTouched[runner] = true;
        final run = await _driveJob(runner, log,
            command: jobFollowCommand(jobId),
            stdin: buildJobFollowStdin(password: config.password, id: jobId),
            id: jobId,
            onJobStarted: onJobStarted);
        if (run is JobRunRc) {
          final o = evaluateJob(run.kind ?? 'unknown', run.rc, run.log);
          log(o.message);
          return o;
        }
        final kind = switch (run) {
          JobRunLost(:final kind) => kind,
          JobRunDetached(:final kind) => kind,
          _ => null,
        };
        throw _jobRunError(run, JobRef(id: jobId, kind: kind ?? 'unknown'));
      },
    );
  }

  /// Starts a Pi-Job and follows it to its end. Returns the exit code and the
  /// complete log (evaluate it with [evaluateJob]); every other ending is
  /// thrown — see [_jobRunError]. The password goes only into stdin, in front
  /// of the sentinel; the payload never contains it.
  Future<JobRunResult> _runJob(
    SshRunner runner,
    void Function(String) log,
    SshConfig config, {
    required String kind,
    required String payload,
    void Function(JobRef ref)? onJobStarted,
  }) async {
    // Never start a job after the user asked to stop.
    if (_cancelRequested) {
      throw const EvccUpdateException(
          UpdateErrorKind.cancelled, 'Abgebrochen.');
    }
    final id = _jobId();
    if (!isValidJobId(id)) {
      throw const EvccUpdateException(UpdateErrorKind.unknown,
          'Interner Fehler: ungültige Job-ID – nichts gestartet.');
    }
    final ref = JobRef(id: id, kind: kind);
    final stdin = buildJobStartStdin(
        password: config.password, id: id, kind: kind, payload: payload);
    log('Starte ${jobKindLabel(kind)} als Hintergrund-Job auf dem Pi '
        '(ID $id) …');
    _jobTouched[runner] = true;
    final run = await _driveJob(runner, log,
        command: jobStartCommand(id),
        stdin: stdin,
        id: id,
        onJobStarted: onJobStarted);
    if (run is JobRunRc) return JobRunResult(ref: ref, rc: run.rc, log: run.log);
    throw _jobRunError(run, ref);
  }

  /// Runs a launcher/follower command, streams the job's log live (control
  /// lines filtered out), reports STARTED via [onJobStarted], and classifies
  /// the run. Never throws for transport trouble: a timeout, a dead channel,
  /// a closed client or a watchdog stall all end as "no terminal line" —
  /// the job itself is on the Pi and unaffected.
  Future<JobRun> _driveJob(
    SshRunner runner,
    void Function(String) log, {
    required String command,
    required String stdin,
    required String id,
    void Function(JobRef ref)? onJobStarted,
  }) async {
    final merged = StringBuffer();
    var started = false;
    final clock = Stopwatch()..start();
    var lastOutput = Duration.zero;

    void onChunk(String chunk) {
      lastOutput = clock.elapsed; // heartbeats count: the channel is alive
      merged.write(chunk);
      for (final raw in chunk.split('\n')) {
        final line = raw.trimRight();
        if (line.trim().isEmpty) continue;
        if (isJobControlLine(line, id)) {
          if (!started && line.startsWith('PITOOL_JOB_STARTED $id')) {
            started = true;
            final k = line.split(' ').length > 2 ? line.split(' ')[2] : '';
            log('Läuft jetzt als Hintergrund-Job auf dem Pi – ein '
                'Verbindungsabbruch stoppt ihn nicht.');
            onJobStarted
                ?.call(JobRef(id: id, kind: isValidJobKind(k) ? k : 'unknown'));
          }
          continue;
        }
        log(line);
      }
    }

    // Future.sync: a runner that throws synchronously ends up here too.
    final runF = Future<CommandResult>.sync(
        () => runner.run(command, stdin: stdin, onOutput: onChunk));
    // Whatever happens to runF after we stopped waiting must not surface as
    // an unhandled error.
    unawaited(runF.then<void>((_) {}, onError: (Object _) {}));
    final stalled = Completer<CommandResult?>();
    final tick = Duration(
        milliseconds: (jobWatchdog.inMilliseconds ~/ 4).clamp(50, 5000));
    final timer = Timer.periodic(tick, (_) {
      if (clock.elapsed - lastOutput >= jobWatchdog && !stalled.isCompleted) {
        stalled.complete(null);
      }
    });

    CommandResult? result;
    try {
      result = await Future.any<CommandResult?>([runF, stalled.future]);
      if (result == null) {
        log('Keine Antwort vom Pi seit ${jobWatchdog.inSeconds} s – '
            'Verbindung gilt als abgerissen.');
        try {
          await runner.close().timeout(const Duration(seconds: 5));
        } catch (_) {
          // Best effort; _withConnection closes again.
        }
      }
    } catch (e) {
      // TimeoutException, SSHError, StateError, SocketException, …: the
      // channel is gone. What arrived so far decides.
      log('Verbindung zum Pi-Job unterbrochen ($e).');
      result = null;
    } finally {
      timer.cancel();
    }

    if (result != null) {
      return classifyJobRun(
          stdout: result.stdout,
          stderr: result.stderr,
          exitCode: result.exitCode,
          id: id);
    }
    return classifyJobRun(
        stdout: stripJobHeartbeats(merged.toString(), id),
        stderr: '',
        exitCode: null,
        id: id);
  }

  /// The user-facing error for every job ending except an exit code.
  EvccUpdateException _jobRunError(JobRun run, JobRef ref) {
    final label = jobKindLabel(ref.kind);
    switch (run) {
      case JobRunRc():
        return const EvccUpdateException(
            UpdateErrorKind.unknown, 'Interner Fehler (Job-Ergebnis).');
      case JobRunLost():
        return EvccUpdateException(
            UpdateErrorKind.unknown,
            'Der Pi-Job ($label) wurde auf dem Pi unterbrochen (Neustart oder '
            'Absturz) – der Paketzustand kann unvollständig sein. '
            'System-Karte → ⋮ → „Paketzustand reparieren".');
      case JobRunBusy(:final otherId, :final kind, :final since):
        if (kind == 'autoupdate') {
          return const JobException(
              UpdateErrorKind.jobBusy,
              'Auf dem Pi laufen gerade die automatischen Updates – bitte in '
              'ein paar Minuten erneut versuchen. Es wurde nichts gestartet.',
              jobKind: 'autoupdate');
        }
        final at = since == null ? '' : ', seit ${_hhmm(since)}';
        return JobException(
          UpdateErrorKind.jobBusy,
          'Auf dem Pi läuft noch ein Pi-Job (${jobKindLabel(kind ?? '')}$at) '
          '– bitte warten, bis er fertig ist. Es wurde nichts gestartet.',
          ref: otherId == null
              ? null
              : JobRef(id: otherId, kind: kind ?? 'unknown'),
          jobKind: kind,
          since: since,
        );
      case JobRunNoStart():
        return const EvccUpdateException(
            UpdateErrorKind.unknown,
            'Hintergrund-Job konnte nicht gestartet werden – es wurde nichts '
            'verändert.');
      case JobRunUnknown():
        return const EvccUpdateException(
            UpdateErrorKind.unknown,
            'Job nicht mehr auf dem Pi vorhanden – sein Ergebnis lässt sich '
            'nicht mehr abrufen.');
      case JobRunSudoFailure():
        return const EvccUpdateException(UpdateErrorKind.sudo,
            'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?');
      case JobRunBadHeader():
        return const EvccUpdateException(UpdateErrorKind.unknown,
            'Pi-Tool-Startkopf fehlt – der Job wurde nicht gestartet.');
      case JobRunDetached(:final started):
        final reason = _cancelRequested
            ? JobDetachReason.userStopped
            : JobDetachReason.connectionLost;
        final head = reason == JobDetachReason.userStopped
            ? 'Mitlesen beendet'
            : 'Verbindung abgerissen';
        return JobException(
          UpdateErrorKind.jobDetached,
          started
              ? '$head – der Pi-Job ($label) läuft auf dem Pi weiter. Das '
                  'Ergebnis zeigt die Job-Anzeige'
                  '${reason == JobDetachReason.userStopped ? '.' : ' beim nächsten Verbinden.'}'
              : '$head – ob der Job gestartet ist, zeigt die Job-Anzeige beim '
                  'nächsten Verbinden.',
          ref: ref,
          jobKind: ref.kind,
          reason: reason,
          startConfirmed: started,
        );
    }
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Evaluates a finished job; throws its message unless it succeeded.
  JobOutcome _requireJobSuccess(void Function(String) log, JobRunResult r) {
    final o = evaluateJob(r.ref.kind, r.rc, r.log);
    if (!o.success) {
      throw EvccUpdateException(
          r.rc == 0 && o.evccActive == false
              ? UpdateErrorKind.serviceInactive
              : UpdateErrorKind.unknown,
          o.message);
    }
    log(o.message);
    return o;
  }

  /// Maps the on-Pi reboot/poweroff guard's refusals ([jobPowerGuard]).
  static void _checkPowerGuard(String output, String action) {
    if (output.contains(jobRefusedRunningMarker)) {
      throw JobException(
          UpdateErrorKind.jobBusy,
          '$action abgelehnt: Auf dem Pi läuft noch ein Pi-Job (z. B. ein '
          'Update) – das würde ihn mitten in der Paketinstallation abbrechen. '
          'Bitte warten, bis er fertig ist.');
    }
    if (output.contains(jobRefusedBootMarker)) {
      throw EvccUpdateException(
          UpdateErrorKind.unknown,
          '$action abgelehnt: Ein Kernel-/Firmware-Update ist nur halb '
          'installiert – so startet der Pi womöglich nicht mehr. Erst '
          'System-Karte → ⋮ → „Paketzustand reparieren" ausführen.');
    }
  }

  /// Opens the connection, runs [body], and maps any SSH/IO failure to an
  /// [EvccUpdateException]. The runner is always closed afterwards.
  /// Whether sudo on this Pi asks for a password — probed once per connection
  /// (see [_sudoNeedsPassword]). Null = not asked yet.
  bool? _sudoNeedsPw;

  /// Asks sudo itself instead of assuming. Cached for the connection: the
  /// answer cannot change mid-session in any way that matters, and one probe
  /// per root script would be pure noise on the wire.
  Future<bool> _sudoNeedsPassword(SshRunner runner) async {
    final cached = _sudoNeedsPw;
    if (cached != null) return cached;
    final r = await runner.run(sudoNoPasswordProbe);
    // No exit status = no answer. Guessing "needs a password" would hand a
    // NOPASSWD Pi the password as the first line of a root `bash -s`.
    if (r.exitCode == null) {
      throw const EvccUpdateException(UpdateErrorKind.unknown, _resultUnknown);
    }
    return _sudoNeedsPw = r.exitCode != 0;
  }

  /// stdin for a root script: password first only when sudo will consume it.
  Future<String> _rootStdin(
          SshRunner runner, SshConfig config, String script) async =>
      buildRootStdin(
        sudoNeedsPassword: await _sudoNeedsPassword(runner),
        password: config.password,
        script: script,
      );

  Future<T> _withConnection<T>({
    required SshConfig config,
    required void Function(String line) onLog,
    required Future<T> Function(SshRunner runner, void Function(String) log)
        body,
  }) async {
    final runner = runnerFactory(config);
    _active = runner;
    _cancelRequested = false;
    _sudoNeedsPw = null; // a fresh connection re-asks
    // The one seam every log line passes through — so the pty progress painting
    // apt/dpkg emit (see [stripProgressNoise]) is filtered once here, for every
    // action and every consumer of the log, instead of at each call site. Only
    // the display is cleaned: parsing keeps working on the raw command output.
    void log(String s) {
      final clean = stripProgressNoise(s);
      // A chunk that was nothing but painting is dropped, not logged as blank.
      if (clean.trim().isEmpty && s.trim().isNotEmpty) return;
      onLog(redactPassword(clean, config.password));
    }

    try {
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
      // requested cancel as cancelled regardless of how the body finished —
      // except after a Pi-Job: its result came with positive proof (RC line),
      // and a cancel there only ever stopped the following.
      if (_cancelRequested && _jobTouched[runner] != true) {
        throw const EvccUpdateException(
            UpdateErrorKind.cancelled, 'Abgebrochen.');
      }
      return result;
    } catch (e) {
      // A job that runs on (or a busy Pi) is never "Abgebrochen." — that
      // would claim the update stopped while dpkg keeps working. Same for any
      // verdict reached after a job command went out.
      if (e is JobException) rethrow;
      if (_jobTouched[runner] == true && e is EvccUpdateException) rethrow;
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
      // Keep the raw exception in the (redacted) log stream; the user-facing
      // headline stays short and points at the log for details.
      if (e is SSHError) {
        log('SSH-Fehler: $e');
        throw const EvccUpdateException(
            UpdateErrorKind.unknown, 'SSH-Fehler – Details im Terminal-Log.');
      }
      log('Unerwarteter Fehler: $e');
      throw const EvccUpdateException(UpdateErrorKind.unknown,
          'Unerwarteter Fehler – Details im Terminal-Log.');
    } finally {
      _active = null;
      await runner.close();
    }
  }
}
