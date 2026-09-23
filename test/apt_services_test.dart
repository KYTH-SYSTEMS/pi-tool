import 'dart:convert';
import 'dart:io';

import 'package:evcc_updater/src/commands.dart' show shSingleQuote;
import 'package:evcc_updater/src/services/apt_services.dart';
import 'package:evcc_updater/src/services/stack_wiring.dart';
import 'package:flutter_test/flutter_test.dart';

AptService _svc(String id) => knownAptServices.firstWhere((s) => s.id == id);

/// The shell for the real-bash groups: `bash` on Linux/macOS (CI). On Windows
/// `bash` may be the WSL launcher, so it only runs with an explicit Git Bash
/// (PITOOL_TEST_BASH=C:\Program Files\Git\bin\bash.exe).
final String? _bash =
    Platform.isWindows ? Platform.environment['PITOOL_TEST_BASH'] : 'bash';

/// A path the sandbox bash understands (Git Bash wants /c/... on Windows).
String _posix(String p) {
  final s = p.replaceAll(r'\', '/');
  final m = RegExp(r'^([A-Za-z]):/').firstMatch(s);
  return m == null ? s : '/${m.group(1)!.toLowerCase()}/${s.substring(3)}';
}

/// Runs [script] like the app does (`bash -s`, script on stdin). [out] is
/// stdout only (the marker check), [all] adds stderr for failure reasons.
Future<({int code, String out, String all})> _runBash(String script) async {
  final p = await Process.start(_bash!, ['-s']);
  final out = p.stdout.transform(utf8.decoder).join();
  final err = p.stderr.transform(utf8.decoder).join();
  p.stdin.add(utf8.encode(script));
  await p.stdin.close();
  final code = await p.exitCode;
  final o = await out;
  return (code: code, out: o, all: '$o${await err}');
}

void main() {
  group('parseAptServiceVersions', () {
    test('maps installed packages to their versions', () {
      const out = 'grafana installed 13.1.0\n'
          'influxdb installed 1.8.10-1\n';
      final m = parseAptServiceVersions(out);
      expect(m, {'grafana': '13.1.0', 'influxdb': '1.8.10-1'});
    });

    test('skips rc-state and missing packages', () {
      const out = 'grafana config-files 13.0.2\n'
          'influxdb2 installed 2.7.6\n';
      final m = parseAptServiceVersions(out);
      expect(m, {'influxdb2': '2.7.6'});
    });

    test('empty on no output (none of the packages known)', () {
      expect(parseAptServiceVersions(''), isEmpty);
      expect(parseAptServiceVersions('dpkg-query: no packages found'), isEmpty);
    });
  });

  group('knownAptServices', () {
    test('grafana + influxdb descriptors carry unit and web port', () {
      final grafana = knownAptServices.firstWhere((s) => s.id == 'grafana');
      // Enterprise + the legacy Pi package run the same grafana-server unit.
      expect(grafana.packages,
          containsAll(['grafana', 'grafana-enterprise', 'grafana-rpi']));
      expect(grafana.unit, 'grafana-server');
      expect(grafana.webPort, 3000);

      final influx = knownAptServices.firstWhere((s) => s.id == 'influxdb');
      expect(influx.packages, containsAll(['influxdb', 'influxdb2']));
      expect(influx.unit, 'influxdb');
    });

    test('mosquitto is a known service with unit + no web UI', () {
      final m = knownAptServices.firstWhere((s) => s.id == 'mosquitto');
      expect(m.packages, contains('mosquitto'));
      expect(m.unit, 'mosquitto');
      expect(m.webPort, isNull); // an MQTT broker, no web UI
    });
  });

  group('installable services', () {
    test('only services with an install script are offered for install', () {
      final ids = knownInstallableServices.map((s) => s.id).toSet();
      expect(ids, containsAll(['grafana', 'influxdb', 'mosquitto']));
      // Every installable service actually carries a script.
      for (final s in knownInstallableServices) {
        expect(s.installScript, isNotNull);
        expect(s.installScript, isNotEmpty);
      }
    });

    test('grafana install uses the current key + repo and enables the unit', () {
      final s = knownAptServices.firstWhere((s) => s.id == 'grafana');
      expect(s.installScript, contains('apt.grafana.com'));
      // Current official key is the full keyring, stored armored (no dearmor).
      expect(s.installScript, contains('gpg-full.key'));
      expect(s.installScript, contains('grafana.asc'));
      expect(s.installScript, contains('install -y grafana'));
      expect(s.installScript, contains('grafana-server'));
    });

    test('influxdb install uses the current (non-compat) key + fingerprint', () {
      final s = knownAptServices.firstWhere((s) => s.id == 'influxdb');
      expect(s.installScript, contains('repos.influxdata.com'));
      // The _compat key is legacy (old distros only); Pi OS Bookworm needs the
      // regular key, verified by fingerprint before trusting it.
      expect(s.installScript, contains('influxdata-archive.key'));
      expect(s.installScript, isNot(contains('_compat')));
      expect(s.installScript,
          contains('24C975CBA61A024EE1B631787C3D57159FC2F927'));
      expect(s.installScript, contains('influxdb2'));
      expect(s.installScript, contains('systemctl enable --now influxdb'));
    });

    test('mosquitto install is a plain apt install of the broker', () {
      final s = knownAptServices.firstWhere((s) => s.id == 'mosquitto');
      expect(s.installScript, contains('install -y mosquitto'));
      expect(s.installScript, contains('systemctl enable --now mosquitto'));
    });

    test('every apt call that runs dpkg switches the pty off', () {
      // Without this, dpkg paints "(Reading database ... 5% … 100%" per package
      // and floods the log over SSH (see stripProgressNoise). Guard test: a new
      // install script must not silently reintroduce the noise.
      for (final s in knownInstallableServices) {
        for (final line in s.installScript!.split('\n')) {
          if (!line.contains('apt-get')) continue;
          if (!RegExp(r'\b(install|upgrade|remove|purge|autoremove)\b')
              .hasMatch(line)) {
            continue; // `apt-get update` runs no dpkg
          }
          expect(line, contains('-o Dpkg::Use-Pty=0'),
              reason: '${s.id}: "$line" would flood the log');
        }
      }
    });

    // Critic 2j: after an uninstall that keeps the config, a reinstall of a
    // newer package finds the user's (changed) conffiles. dpkg would ask —
    // and, the script arriving on stdin, read the rest of the script as the
    // answer. Keep the user's file, never ask, never read stdin.
    test('apt installs keep changed conffiles without asking', () {
      for (final s in knownInstallableServices) {
        for (final line in s.installScript!.split('\n')) {
          if (!line.contains('apt-get') || !line.contains(' install ')) {
            continue;
          }
          expect(line, contains('-o Dpkg::Options::=--force-confdef'),
              reason: '${s.id}: "$line"');
          expect(line, contains('-o Dpkg::Options::=--force-confold'),
              reason: '${s.id}: "$line"');
        }
      }
    });

    test('no apt call can read the script from stdin', () {
      for (final s in knownInstallableServices) {
        for (final line in s.installScript!.split('\n')) {
          if (!line.contains('apt-get')) continue;
          expect(line.trimRight(), endsWith('</dev/null'),
              reason: '${s.id}: "$line" could swallow the script tail');
        }
        expect(s.installScript, isNot(matches(RegExp(r'exec\s*<\s*/dev/null'))));
      }
    });

    test('apt waits for a running unattended-upgrade instead of failing', () {
      for (final s in knownInstallableServices) {
        for (final line in s.installScript!.split('\n')) {
          if (!line.contains('apt-get') || !line.contains(' install ')) {
            continue;
          }
          expect(line, contains('-o DPkg::Lock::Timeout=120'),
              reason: '${s.id}: "$line"');
        }
      }
    });
  });

  group('buildAptServiceUninstallScript', () {
    String build(String id, {required bool purge}) =>
        buildAptServiceUninstallScript(_svc(id), purge: purge);

    final all = [
      for (final s in knownAptServices)
        for (final purge in [false, true])
          (id: s.id, purge: purge, script: build(s.id, purge: purge)),
    ];

    test('marker is exported and does not overlap INSTALL_OK', () {
      expect(aptServiceRemovedMarker, 'APTSVC_REMOVED_OK');
      // _runRootScriptExpectMarker checks with contains().
      expect(aptServiceRemovedMarker, isNot(contains('INSTALL_OK')));
    });

    test('runs under set -e, non-interactive, C locale', () {
      for (final c in all) {
        final lines = c.script.split('\n');
        expect(lines.first, 'set -e', reason: '${c.id}/${c.purge}');
        expect(c.script, contains('export DEBIAN_FRONTEND=noninteractive'));
        expect(c.script, contains('export LC_ALL=C'));
      }
    });

    test('the marker is the very last line and printed exactly once', () {
      for (final c in all) {
        expect(c.script.trimRight().split('\n').last,
            'echo $aptServiceRemovedMarker',
            reason: '${c.id}/${c.purge}');
        expect(aptServiceRemovedMarker.allMatches(c.script), hasLength(1));
      }
    });

    test('never exec </dev/null (it would cut the script off stdin)', () {
      for (final c in all) {
        expect(c.script, isNot(matches(RegExp(r'exec\s*<\s*/dev/null'))),
            reason: '${c.id}/${c.purge}');
      }
    });

    test('never autoremove', () {
      for (final c in all) {
        expect(c.script, isNot(contains('autoremove')));
      }
    });

    test('every apt-get: own </dev/null, lock timeout, no pty noise', () {
      for (final c in all) {
        for (final line in c.script.split('\n')) {
          if (!line.contains('apt-get ')) continue;
          expect(line, contains('</dev/null'), reason: '${c.id}: "$line"');
          expect(line, contains('-o DPkg::Lock::Timeout=120'),
              reason: '${c.id}: "$line"');
          if (!line.contains(' -s ')) {
            expect(line, contains('-o Dpkg::Use-Pty=0'),
                reason: '${c.id}: "$line"');
          }
        }
      }
    });

    test('heredocs (if any) are quoted', () {
      for (final c in all) {
        expect(c.script, isNot(matches(RegExp(r'<<-?\s*[A-Za-z_]'))),
            reason: '${c.id}/${c.purge}');
      }
    });

    test('every refusal is one UNINSTALL_REFUSED line followed by exit 3', () {
      for (final c in all) {
        final lines = c.script.split('\n');
        var n = 0;
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains('UNINSTALL_REFUSED')) continue;
          n++;
          expect(lines[i].trim(), startsWith('echo "UNINSTALL_REFUSED: '),
              reason: '${c.id}: "${lines[i]}"');
          expect(lines[i + 1].trim(), 'exit 3',
              reason: '${c.id}: "${lines[i]}"');
        }
        expect(n, greaterThanOrEqualTo(3), reason: '${c.id}/${c.purge}');
      }
    });

    test('German user texts with real umlauts', () {
      final s = build('mosquitto', purge: false);
      expect(s, contains('nichts geändert'));
      expect(s, contains('würde'));
      expect(s, isNot(contains('geaendert')));
    });

    test('all guards run before the first change', () {
      for (final c in all) {
        final s = c.script;
        final lastGuard = s.lastIndexOf('UNINSTALL_REFUSED');
        final firstChange = [
          s.indexOf('systemctl disable'),
          s.indexOf(' remove -y'),
          s.indexOf(' purge -y'),
          s.indexOf('rm -rf'),
        ].where((i) => i >= 0).reduce((a, b) => a < b ? a : b);
        expect(lastGuard, lessThan(firstChange), reason: '${c.id}/${c.purge}');
        // The apt dry run (and its extra-package check) precedes all of it.
        expect(s.indexOf(' -s '), lessThan(firstChange));
        expect(s.indexOf('apt-mark hold'), lessThan(firstChange));
      }
    });

    test('removes all installed card packages; the companions only on purge',
        () {
      for (final c in all) {
        final svc = _svc(c.id);
        final setLine =
            c.script.split('\n').firstWhere((l) => l.startsWith('set -- '));
        for (final p in svc.packages) {
          expect(setLine, contains(shSingleQuote(p)), reason: c.id);
        }
        // Keep mode leaves the client tools (mosquitto_pub, influx) for
        // scripts that talk to another broker / InfluxDB Cloud.
        for (final p in svc.footprint.companions) {
          expect(setLine,
              c.purge ? contains(shSingleQuote(p)) : isNot(contains(p)),
              reason: '${c.id}/${c.purge}: $p');
          if (!c.purge) {
            expect(c.script, isNot(contains(p)),
                reason: '${c.id}: $p must not be touched on keep');
          }
        }
      }
      expect(_svc('influxdb').footprint.companions, contains('influxdb2-cli'));
      expect(
          _svc('mosquitto').footprint.companions, contains('mosquitto-clients'));
    });

    test('never removes shared packages', () {
      for (final c in all) {
        final setLine =
            c.script.split('\n').firstWhere((l) => l.startsWith('set -- '));
        for (final shared in [
          'curl',
          'wget',
          'gnupg',
          'ca-certificates',
          'adduser',
          'ucf',
          'docker',
        ]) {
          expect(setLine, isNot(contains("'$shared")), reason: c.id);
        }
      }
    });

    test('status-based dpkg checks (rc, not-installed, unknown)', () {
      for (final c in all) {
        expect(c.script, contains(r"dpkg-query -W -f='${db:Status-Status}'"));
        expect(c.script, isNot(matches(RegExp(r'dpkg-query -W [a-z"$]'))),
            reason: 'a bare dpkg-query -W also matches rc/not-installed');
      }
    });

    test('keep: plain remove of installed packages, config + data stay', () {
      for (final id in ['grafana', 'influxdb', 'mosquitto']) {
        final s = build(id, purge: false);
        expect(s, contains(' remove -y "\${pkgs[@]}"'), reason: id);
        expect(s, isNot(contains(' purge -y')), reason: id);
        // rc packages are already "removed" — nothing to do for them.
        expect(s, contains('""|not-installed|config-files) ;;'), reason: id);
        expect(s, isNot(contains('rm -rf')), reason: id);
        expect(s, isNot(contains('/etc/apt/')), reason: id);
        expect(s, isNot(contains('/var/backups/pi-tool/')), reason: id);
        expect(s, isNot(contains('.influxdbv2')), reason: id);
        expect(s, isNot(contains('mv -f')), reason: id);
        expect(s, isNot(contains(evccInfluxBlockMarker)), reason: id);
      }
    });

    test('purge: purge incl. rc leftovers, then config, data, backups', () {
      for (final id in ['grafana', 'influxdb', 'mosquitto']) {
        final svc = _svc(id);
        final s = build(id, purge: true);
        expect(s, contains(' purge -y "\${pkgs[@]}"'), reason: id);
        expect(s, isNot(contains(' remove -y')), reason: id);
        expect(s, contains('""|not-installed) ;;'), reason: id);
        for (final p in svc.footprint.purgePaths) {
          expect(s, contains(shSingleQuote(p)), reason: '$id: $p');
        }
        for (final b in svc.footprint.backupPrefixes) {
          // Only the config editor's exact `<prefix><YYYYmmdd-HHMMSS>.bak`.
          expect(
              s,
              contains("/var/backups/pi-tool/${shSingleQuote(b)}"
                  '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-'
                  '[0-9][0-9][0-9][0-9][0-9][0-9].bak'),
              reason: '$id: $b');
        }
        // Precise: never the whole backup dir, never an open-ended glob.
        expect(s, isNot(contains('rm -rf -- /var/backups')));
        expect(s, isNot(contains("'/var/backups/pi-tool'")));
        expect(s, isNot(contains("-'*.bak")), reason: id);
      }
      expect(_svc('grafana').footprint.purgePaths,
          containsAll(['/etc/grafana', '/var/lib/grafana']));
      expect(_svc('influxdb').footprint.purgePaths,
          containsAll(['/etc/influxdb', '/var/lib/influxdb']));
      expect(_svc('mosquitto').footprint.purgePaths,
          containsAll(['/etc/mosquitto', '/var/lib/mosquitto']));
    });

    // Config-editor backups carry only the basename. influxdb.conf also names
    // Telegraf's telegraf.d/influxdb.conf, mosquitto.conf a Docker broker's
    // config — those backups belong to someone else. Only basenames that on a
    // Pi can only be this service's file qualify.
    test('backup prefixes are limited to basenames unique to the service', () {
      expect(_svc('grafana').footprint.backupPrefixes,
          ['config-grafana.ini-', 'config-grafana-server-']);
      expect(_svc('influxdb').footprint.backupPrefixes, ['config-influxdb2-']);
      expect(_svc('mosquitto').footprint.backupPrefixes, isEmpty);
      for (final c in all) {
        expect(c.script, isNot(contains('influxdb.conf')), reason: c.id);
        expect(c.script, isNot(contains('mosquitto.conf')), reason: c.id);
      }
      // No prefix → no backup line at all (and the script still builds).
      final m = build('mosquitto', purge: true);
      expect(m, isNot(contains('/var/backups/pi-tool/')));
      expect(m.trimRight().split('\n').last, 'echo $aptServiceRemovedMarker');
    });

    test('purge: removes the app-added apt source + keyring unless siblings '
        'from the same repo are still installed', () {
      final g = build('grafana', purge: true);
      expect(g, contains("'/etc/apt/sources.list.d/grafana.list'"));
      expect(g, contains("'/etc/apt/keyrings/grafana.asc'"));
      expect(g, isNot(contains('.ucf-')), reason: 'no ucf-managed list');
      expect(g, contains("'loki'"));
      expect(g, contains('keep_repo=1'));
      expect(g.indexOf('keep_repo=1'),
          lessThan(g.indexOf("'/etc/apt/sources.list.d/grafana.list'")));

      final i = build('influxdb', purge: true);
      expect(i, contains("'/etc/apt/sources.list.d/influxdata.list'"));
      expect(i, contains("'/etc/apt/sources.list.d/influxdata.list'.ucf-*"));
      expect(i, contains("'/etc/apt/keyrings/influxdata-archive.gpg'"));
      expect(i, contains("'telegraf'"));
      // The keyring package's postrm drops the list even on remove, so it
      // only goes along when no sibling needs the repo.
      expect(i, contains("pkgs+=('influxdata-archive-keyring')"));
      expect(i.indexOf('if [ "\$keep_repo" = 0 ]'),
          lessThan(i.indexOf("pkgs+=('influxdata-archive-keyring')")));

      // Mosquitto comes from the distro: no source to touch.
      expect(build('mosquitto', purge: true), isNot(contains('/etc/apt/')));
    });

    test('disables the unit before apt (leftover links / SysV script) and '
        're-enables it when apt fails', () {
      for (final c in all) {
        final s = c.script;
        expect(s, contains('systemctl disable "\$UNIT"'));
        expect(s, isNot(contains('disable --now')),
            reason: 'a lock timeout would leave the service stopped');
        final apt = s.indexOf(c.purge ? ' purge -y' : ' remove -y');
        expect(s.indexOf('systemctl disable "\$UNIT"'), lessThan(apt));
        expect(s, contains('systemctl enable "\$UNIT"'));
        expect(s.indexOf('systemctl enable "\$UNIT"'), greaterThan(apt));
      }
    });

    test('verifies before the marker: no card package installed, unit not '
        'enabled, not running', () {
      for (final c in all) {
        final s = c.script;
        final marker = s.lastIndexOf(aptServiceRemovedMarker);
        final checks = [
          s.lastIndexOf('for p in "\$@"; do'),
          s.indexOf('systemctl is-enabled "\$UNIT" 2>/dev/null || true)" = enabled'),
          s.indexOf('if systemctl is-active --quiet "\$UNIT"'),
        ];
        for (final i in checks) {
          expect(i, greaterThan(0), reason: '${c.id}/${c.purge}');
          expect(i, lessThan(marker), reason: '${c.id}/${c.purge}');
        }
        final apt = s.indexOf(c.purge ? ' purge -y' : ' remove -y');
        expect(checks.first, greaterThan(apt));
      }
    });

    test('influxdb purge takes back the stack wiring: evcc.yaml before any '
        'removal, CLI profile after the data is gone', () {
      final s = build('influxdb', purge: true);
      final unwire = s.indexOf(buildEvccInfluxUnwireScriptPart());
      final cli = s.indexOf(buildInfluxCliProfileCleanupScriptPart());
      expect(unwire, greaterThan(0));
      expect(cli, greaterThan(0));
      expect(s.indexOf(' -s '), lessThan(unwire));
      expect(unwire, lessThan(s.indexOf('systemctl disable "\$UNIT"')));
      expect(s.indexOf('rm -rf'), lessThan(cli));
      expect(cli, lessThan(s.lastIndexOf(aptServiceRemovedMarker)));
    });

    test('only influxdb purge touches evcc.yaml or the influx CLI profile',
        () {
      for (final c in all) {
        if (c.id == 'influxdb' && c.purge) continue;
        expect(c.script, isNot(contains(evccInfluxBlockMarker)),
            reason: '${c.id}/${c.purge}');
        expect(c.script, isNot(contains('.influxdbv2')),
            reason: '${c.id}/${c.purge}');
        expect(c.script, isNot(contains('systemctl restart evcc')),
            reason: '${c.id}/${c.purge}');
      }
    });

    test('evcc consumers get a hint, nothing is changed for them', () {
      expect(build('influxdb', purge: false), contains("grep -q '^influx:'"));
      expect(build('mosquitto', purge: false), contains("grep -q '^mqtt:'"));
      expect(build('grafana', purge: false), isNot(contains('/etc/evcc.yaml')));
    });

    test('rm -rf only ever gets constant, quoted paths', () {
      for (final c in all) {
        for (final line in c.script.split('\n')) {
          if (!line.contains('rm -rf')) continue;
          expect(line, isNot(contains(r'$')), reason: '${c.id}: "$line"');
          expect(line.trim(), startsWith("rm -rf -- '/"));
        }
      }
    });

    test('every Dart value is shell-quoted (no injection)', () {
      const evil = AptService(
        id: 'evil',
        name: r"Böse'$(reboot)",
        packages: [r"pkg'$(reboot)"],
        unit: r'unit"; reboot; "',
        footprint: AptUninstallFootprint(
          companions: [r'comp`reboot`'],
          purgePaths: [r"/opt/x'$(reboot)"],
          purgeLinks: [r'/etc/systemd/system/a b.service'],
          aptSourceList: r"/etc/apt/sources.list.d/e'$(reboot).list",
          aptKeyring: r'/etc/apt/keyrings/$(reboot).gpg',
          repoKeyringPackage: r"kr'$(reboot)",
          repoSiblings: [r"sib'$(reboot)"],
          backupPrefixes: [r"config-e'$(reboot)-"],
          evccConfigKey: r"k'$(reboot)",
        ),
      );
      for (final purge in [false, true]) {
        final s = buildAptServiceUninstallScript(evil, purge: purge);
        for (final v in [
          evil.name,
          evil.unit,
          ...evil.packages,
        ]) {
          expect(s, contains(shSingleQuote(v)));
        }
        if (purge) {
          for (final v in [
            ...evil.footprint.companions,
            ...evil.footprint.purgePaths,
            ...evil.footprint.purgeLinks,
            evil.footprint.aptSourceList!,
            evil.footprint.aptKeyring!,
            evil.footprint.repoKeyringPackage!,
            ...evil.footprint.repoSiblings,
            ...evil.footprint.backupPrefixes,
          ]) {
            expect(s, contains(shSingleQuote(v)));
          }
        }
        // Outside of '…' quoting no command substitution survives: drop
        // comments and the '\'' idiom, strip every quoted span, look for the
        // payload.
        final code = s
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('#'))
            .join('\n')
            .replaceAll(r"'\''", '');
        final unquoted = code.replaceAll(RegExp(r"'[^']*'"), "''");
        expect(unquoted, isNot(contains('reboot')), reason: 'purge=$purge');
      }
    });

    test('refuses to build with an unsafe purge path', () {
      AptService withPath(String p) => AptService(
            id: 'x',
            name: 'X',
            packages: const ['x'],
            unit: 'x',
            footprint: AptUninstallFootprint(purgePaths: [p]),
          );
      for (final bad in ['/', '/etc', 'etc/x', '/etc/../x', '/var/lib/', '']) {
        expect(
            () => buildAptServiceUninstallScript(withPath(bad), purge: true),
            throwsArgumentError,
            reason: bad);
      }
      expect(buildAptServiceUninstallScript(withPath('/etc/x'), purge: true),
          contains("'/etc/x'"));
    });
  });

  // The real script in a real bash (fed on stdin, like `sudo -S bash -s`),
  // against a sandbox: every absolute /etc, /var, /root path points into a
  // temp dir, dpkg-query/apt-get/systemctl are stubs backed by state files.
  group('buildAptServiceUninstallScript in bash', () {
    late Directory tmp;
    late String root; // posix form of tmp
    late String state;

    String read(String rel) => File('${tmp.path}/$rel').readAsStringSync();
    bool exists(String rel) =>
        FileSystemEntity.typeSync('${tmp.path}/$rel') !=
        FileSystemEntityType.notFound;
    void write(String rel, String content) {
      final f = File('${tmp.path}/$rel');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    void pkg(String name, String status, {String want = 'install'}) {
      write('state/status/$name', '$status\n');
      write('state/want/$name', '$want\n');
    }

    String status(String name) =>
        exists('state/status/$name') ? read('state/status/$name').trim() : '';
    String aptLog() => exists('state/log') ? read('state/log') : '';

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('aptsvc');
      root = _posix(tmp.path);
      state = '$root/state';
      write('bin/dpkg-query', r'''#!/bin/bash
for a; do p=$a; done
case "$*" in *Status-Want*) d=want ;; *) d=status ;; esac
[ -f "$STUB/status/$p" ] || { echo "dpkg-query: no packages found matching $p" >&2; exit 1; }
cat "$STUB/$d/$p" 2>/dev/null || echo install
''');
      write('bin/apt-get', r'''#!/bin/bash
echo "apt-get $*" >> "$STUB/log"
sim=0; verb=""; skip=0; pkgs=()
for a; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -o) skip=1 ;;
    -s) sim=1 ;;
    -y) ;;
    remove|purge) verb=$a ;;
    *) pkgs+=("$a") ;;
  esac
done
if [ "$sim" = 1 ]; then
  for p in "${pkgs[@]}"; do
    if [ "$verb" = purge ]; then echo "Purg $p [1.0]"; else echo "Remv $p [1.0]"; fi
  done
  if [ -f "$STUB/sim_extra" ]; then echo "Remv $(cat "$STUB/sim_extra"):arm64 [2.0]"; fi
  exit 0
fi
if [ -f "$STUB/apt_fail" ]; then
  echo "E: Could not get lock /var/lib/dpkg/lock-frontend" >&2; exit 100
fi
for p in "${pkgs[@]}"; do
  if [ "$verb" = purge ]; then echo not-installed > "$STUB/status/$p"
  else echo config-files > "$STUB/status/$p"; fi
done
''');
      write('bin/systemctl', r'''#!/bin/bash
echo "systemctl $*" >> "$STUB/log"
q=0; args=()
for a; do case "$a" in --quiet) q=1 ;; *) args+=("$a") ;; esac; done
cmd=${args[0]}; u=${args[1]}
case "$cmd" in
  is-enabled) s=$(cat "$STUB/enabled.$u" 2>/dev/null || true); echo "$s"; [ "$s" = enabled ] ;;
  is-active) s=$(cat "$STUB/active.$u" 2>/dev/null || echo inactive); [ "$q" = 1 ] || echo "$s"; [ "$s" = active ] ;;
  disable) [ -f "$STUB/enabled.$u" ] && echo disabled > "$STUB/enabled.$u"; true ;;
  enable) echo enabled > "$STUB/enabled.$u" ;;
  stop) echo inactive > "$STUB/active.$u" ;;
  cat) [ -f "$STUB/unit.$u" ] ;;
  restart)
    if [ "$u" = evcc ] && [ -f "$STUB/evcc_needs_influx" ] && ! grep -q '^influx:' "$ROOT/etc/evcc.yaml"; then
      echo failed > "$STUB/active.evcc"
    else
      echo active > "$STUB/active.$u"
    fi ;;
esac
exit $?
''');
      write('bin/sleep', '#!/bin/sh\nexit 0\n');
      for (final b in ['dpkg-query', 'apt-get', 'systemctl', 'sleep']) {
        if (!Platform.isWindows) {
          Process.runSync('chmod', ['+x', '${tmp.path}/bin/$b']);
        }
      }
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    /// Builds the script, points it into the sandbox and runs it.
    Future<({int code, String out, String all})> run(String id,
        {required bool purge}) {
      final script = buildAptServiceUninstallScript(_svc(id), purge: purge)
          .replaceAllMapped(
              RegExp(r'''(^|[\s'"=])/(etc|var|root)/''', multiLine: true),
              (m) => '${m[1]}$root/${m[2]}/');
      return _runBash('export PATH=${shSingleQuote('$root/bin')}:"\$PATH"\n'
          'export STUB=${shSingleQuote(state)} ROOT=${shSingleQuote(root)}\n'
          '$script');
    }

    const userYaml = 'site:\n  title: Zuhause\n';
    const ourBlock = '\n'
        '# Von Pi-Tool ergaenzt (Monitoring-Stack):\n'
        'influx:\n'
        '  url: http://localhost:8086\n'
        '  database: evcc\n'
        '  org: pi-tool\n'
        '  token: secret-token\n';

    void influxPi() {
      pkg('influxdb2', 'installed');
      pkg('influxdb2-cli', 'installed');
      pkg('influxdata-archive-keyring', 'installed');
      write('state/enabled.influxdb', 'enabled');
      write('state/active.influxdb', 'active');
      write('state/unit.evcc', '');
      write('state/active.evcc', 'active');
      write('etc/evcc.yaml', '$userYaml${ourBlock}loadpoints: []\n');
      write('etc/influxdb/config.toml', 'bolt-path = "x"\n');
      write('var/lib/influxdb/influxd.bolt', 'data');
      write('etc/default/influxdb2', '');
      write('etc/apt/sources.list.d/influxdata.list', 'deb x\n');
      write('etc/apt/keyrings/influxdata-archive.gpg', 'k');
      write('root/.influxdbv2/configs',
          '[pitool]\n  url = "http://localhost:8086"\n  active = true\n');
      write('var/backups/pi-tool/config-influxdb2-20260101-000000.bak', '');
      write('var/backups/pi-tool/evcc.yaml.wire-20260101-000000', '');
    }

    test('keep: package goes to rc, unit disabled, everything else stays',
        () async {
      influxPi();
      final r = await run('influxdb', purge: false);
      expect(r.code, 0, reason: r.all);
      expect(r.out.trimRight().split('\n').last, aptServiceRemovedMarker);
      expect(status('influxdb2'), 'config-files');
      // The `influx` CLI stays for scripts against another InfluxDB.
      expect(status('influxdb2-cli'), 'installed');
      expect(aptLog(), contains('remove -y influxdb2\n'));
      expect(aptLog(), isNot(contains('influxdb2-cli')));
      expect(status('influxdata-archive-keyring'), 'installed');
      expect(read('state/enabled.influxdb'), contains('disabled'));
      expect(read('etc/evcc.yaml'), '$userYaml${ourBlock}loadpoints: []\n');
      for (final f in [
        'etc/influxdb/config.toml',
        'var/lib/influxdb/influxd.bolt',
        'etc/apt/sources.list.d/influxdata.list',
        'root/.influxdbv2/configs',
      ]) {
        expect(exists(f), isTrue, reason: f);
      }
      expect(aptLog(), isNot(contains('restart evcc')));
      expect(r.out, contains('Hinweis'));
    });

    test('keep is idempotent: a retry after a full run succeeds, no apt call',
        () async {
      influxPi();
      expect((await run('influxdb', purge: false)).code, 0);
      File('${tmp.path}/state/log').deleteSync();
      final r = await run('influxdb', purge: false);
      expect(r.code, 0, reason: r.all);
      expect(r.out.trimRight().split('\n').last, aptServiceRemovedMarker);
      expect(aptLog(), isNot(contains(' remove ')));
    });

    test('purge: full rollback incl. evcc.yaml block, source, CLI profile',
        () async {
      influxPi();
      final r = await run('influxdb', purge: true);
      expect(r.code, 0, reason: r.all);
      expect(r.out.trimRight().split('\n').last, aptServiceRemovedMarker);
      for (final p in ['influxdb2', 'influxdb2-cli', 'influxdata-archive-keyring']) {
        expect(status(p), 'not-installed', reason: p);
      }
      // Only our block is gone — byte for byte the user's file again.
      expect(read('etc/evcc.yaml'), '${userYaml}loadpoints: []\n');
      final bak = Directory('${tmp.path}/var/backups/pi-tool')
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .where((n) => n.startsWith('evcc.yaml.unwire-'))
          .toList();
      expect(bak, hasLength(1));
      expect(read('var/backups/pi-tool/${bak.single}'), contains('influx:'));
      expect(aptLog(), contains('systemctl restart evcc'));
      for (final f in [
        'etc/influxdb',
        'var/lib/influxdb',
        'etc/default/influxdb2',
        'etc/apt/sources.list.d/influxdata.list',
        'etc/apt/keyrings/influxdata-archive.gpg',
        'root/.influxdbv2',
        'var/backups/pi-tool/config-influxdb2-20260101-000000.bak',
      ]) {
        expect(exists(f), isFalse, reason: f);
      }
      // evcc's own backups are not InfluxDB's to delete.
      expect(exists('var/backups/pi-tool/evcc.yaml.wire-20260101-000000'),
          isTrue);
    });

    test('purge is idempotent: a retry finds nothing left and succeeds',
        () async {
      influxPi();
      expect((await run('influxdb', purge: true)).code, 0);
      final r = await run('influxdb', purge: true);
      expect(r.code, 0, reason: r.all);
      expect(r.out.trimRight().split('\n').last, aptServiceRemovedMarker);
      expect(read('etc/evcc.yaml'), '${userYaml}loadpoints: []\n');
    });

    test('purge after keep clears the rc leftovers and the kept companion',
        () async {
      influxPi();
      expect((await run('influxdb', purge: false)).code, 0);
      expect(status('influxdb2-cli'), 'installed');
      final r = await run('influxdb', purge: true);
      expect(r.code, 0, reason: r.all);
      expect(status('influxdb2'), 'not-installed');
      expect(status('influxdb2-cli'), 'not-installed');
      expect(exists('var/lib/influxdb'), isFalse);
    });

    test('purge leaves config-editor backups of same-named foreign files',
        () async {
      influxPi();
      // Telegraf's /etc/telegraf/telegraf.d/influxdb.conf and a user script
      // /home/pi/influxdb2-export.sh, both edited in the app.
      const foreign = [
        'var/backups/pi-tool/config-influxdb.conf-20260101-000000.bak',
        'var/backups/pi-tool/config-influxdb2-export.sh-20260101-000000.bak',
      ];
      for (final f in foreign) {
        write(f, 'x');
      }
      final r = await run('influxdb', purge: true);
      expect(r.code, 0, reason: r.all);
      for (final f in foreign) {
        expect(exists(f), isTrue, reason: f);
      }
      // /etc/default/influxdb2's own backup still goes.
      expect(exists('var/backups/pi-tool/config-influxdb2-20260101-000000.bak'),
          isFalse);
    });

    test('mosquitto keep: broker removed, mosquitto-clients stays', () async {
      pkg('mosquitto', 'installed');
      pkg('mosquitto-clients', 'installed');
      write('state/enabled.mosquitto', 'enabled');
      final r = await run('mosquitto', purge: false);
      expect(r.code, 0, reason: r.all);
      expect(r.out.trimRight().split('\n').last, aptServiceRemovedMarker);
      expect(status('mosquitto'), 'config-files');
      expect(status('mosquitto-clients'), 'installed');
      expect(aptLog(), isNot(contains('mosquitto-clients')));
    });

    test('purge keeps the repo while telegraf still needs it', () async {
      influxPi();
      pkg('telegraf', 'installed');
      final r = await run('influxdb', purge: true);
      expect(r.code, 0, reason: r.all);
      expect(status('influxdata-archive-keyring'), 'installed');
      expect(exists('etc/apt/sources.list.d/influxdata.list'), isTrue);
      expect(exists('etc/apt/keyrings/influxdata-archive.gpg'), isTrue);
      expect(status('telegraf'), 'installed');
    });

    test('evcc rejecting the change: yaml restored, refused, nothing removed',
        () async {
      influxPi();
      write('state/evcc_needs_influx', '');
      final r = await run('influxdb', purge: true);
      expect(r.code, 3, reason: r.all);
      expect(r.out, contains('UNINSTALL_REFUSED: '));
      expect(r.out, isNot(contains(aptServiceRemovedMarker)));
      expect(read('etc/evcc.yaml'), '$userYaml${ourBlock}loadpoints: []\n');
      expect(status('influxdb2'), 'installed');
      expect(read('state/enabled.influxdb'), 'enabled');
      expect(exists('var/lib/influxdb/influxd.bolt'), isTrue);
      expect(aptLog(), isNot(contains(' purge -y')));
    });

    test('apt would take other packages along: refused before any change',
        () async {
      influxPi();
      write('state/sim_extra', 'my-dashboard');
      for (final purge in [false, true]) {
        final r = await run('influxdb', purge: purge);
        expect(r.code, 3, reason: r.all);
        expect(r.out, contains('UNINSTALL_REFUSED: '));
        expect(r.out, contains('my-dashboard'));
        expect(status('influxdb2'), 'installed');
        expect(read('state/enabled.influxdb'), 'enabled');
        expect(read('etc/evcc.yaml'), contains('influx:'));
        expect(aptLog(), isNot(contains('-y')));
        expect(aptLog(), isNot(contains('systemctl disable')));
      }
    });

    test('a held package is refused before any change', () async {
      pkg('mosquitto', 'installed', want: 'hold');
      write('state/enabled.mosquitto', 'enabled');
      final r = await run('mosquitto', purge: false);
      expect(r.code, 3, reason: r.all);
      expect(r.out, contains('UNINSTALL_REFUSED: '));
      expect(r.out, contains('apt-mark unhold'));
      expect(status('mosquitto'), 'installed');
      expect(aptLog(), isNot(contains('systemctl disable')));
    });

    test('apt failing (lock): no marker, autostart restored', () async {
      pkg('mosquitto', 'installed');
      pkg('mosquitto-clients', 'installed');
      write('state/enabled.mosquitto', 'enabled');
      write('state/apt_fail', '');
      final r = await run('mosquitto', purge: false);
      expect(r.code, isNot(0));
      expect(r.out, isNot(contains(aptServiceRemovedMarker)));
      expect(read('state/enabled.mosquitto').trim(), 'enabled');
    });

    test('mosquitto purge: broker + clients + files gone, mosquitto.conf '
        'backups stay (the name is ambiguous), no evcc.yaml change', () async {
      pkg('mosquitto', 'installed');
      pkg('mosquitto-clients', 'installed');
      write('state/enabled.mosquitto', 'enabled');
      write('etc/mosquitto/mosquitto.conf', 'listener 1883\n');
      write('var/lib/mosquitto/mosquitto.db', 'x');
      write('var/backups/pi-tool/config-mosquitto.conf-20260101-000000.bak', '');
      write('var/backups/pi-tool/config-evcc.yaml-20260101-000000.bak', '');
      write('etc/evcc.yaml', 'mqtt:\n  broker: localhost:1883\n');
      final r = await run('mosquitto', purge: true);
      expect(r.code, 0, reason: r.all);
      expect(r.out.trimRight().split('\n').last, aptServiceRemovedMarker);
      expect(status('mosquitto'), 'not-installed');
      expect(status('mosquitto-clients'), 'not-installed');
      expect(exists('etc/mosquitto'), isFalse);
      expect(exists('var/lib/mosquitto'), isFalse);
      // Could as well be a Docker broker's ~/mosquitto/config/mosquitto.conf.
      expect(
          exists('var/backups/pi-tool/config-mosquitto.conf-20260101-000000.bak'),
          isTrue);
      expect(exists('var/backups/pi-tool/config-evcc.yaml-20260101-000000.bak'),
          isTrue);
      expect(read('etc/evcc.yaml'), 'mqtt:\n  broker: localhost:1883\n');
      expect(r.out, contains('Hinweis'));
    });

    test('grafana keep on a Pi where only grafana-enterprise is installed',
        () async {
      pkg('grafana-enterprise', 'installed');
      pkg('grafana', 'config-files');
      write('state/enabled.grafana-server', 'enabled');
      write('etc/grafana/grafana.ini', '');
      final r = await run('grafana', purge: false);
      expect(r.code, 0, reason: r.all);
      expect(status('grafana-enterprise'), 'config-files');
      expect(aptLog(), contains('remove -y grafana-enterprise'));
      expect(aptLog(), isNot(contains('remove -y grafana ')));
      expect(exists('etc/grafana/grafana.ini'), isTrue);
    });
  }, skip: _bash == null ? 'needs bash (PITOOL_TEST_BASH on Windows)' : false);
}
