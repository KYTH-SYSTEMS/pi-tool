import 'dart:convert';
import 'dart:io';

import 'package:evcc_updater/src/commands.dart' show shSingleQuote;
import 'package:evcc_updater/src/services/stack_wiring.dart';
import 'package:flutter_test/flutter_test.dart';

/// `bash` on Linux/macOS (CI); on Windows only an explicit Git Bash
/// (PITOOL_TEST_BASH), since `bash` there may be the WSL launcher.
final String? _bash =
    Platform.isWindows ? Platform.environment['PITOOL_TEST_BASH'] : 'bash';

String _posix(String p) {
  final s = p.replaceAll(r'\', '/');
  final m = RegExp(r'^([A-Za-z]):/').firstMatch(s);
  return m == null ? s : '/${m.group(1)!.toLowerCase()}/${s.substring(3)}';
}

void main() {
  group('buildStackWiringScript', () {
    final s = buildStackWiringScript();

    test('ends in the success marker and checks its preconditions', () {
      expect(s, contains('WIRE_OK'));
      expect(s, contains('command -v influx'));
      expect(s, contains('systemctl is-active influxdb'));
    });

    test('influx setup uses the fixed org/bucket and a generated password',
        () {
      expect(s, contains('-o pi-tool'));
      expect(s, contains('-b evcc'));
      // The admin password is generated ON the Pi, never app-supplied.
      expect(s, contains('/dev/urandom'));
    });

    test('the token never crosses the wire back (no echo of \$tok)', () {
      // Everything secret is used on the Pi only: evcc.yaml + Grafana
      // provisioning. The log must never carry the token.
      expect(s, isNot(contains(r'echo "$tok"')));
      expect(s, isNot(contains(r'echo $tok')));
    });

    test('evcc.yaml: only appends when no influx block exists, with backup '
        'and restore-on-failure', () {
      expect(s, contains("grep -q '^influx:' /etc/evcc.yaml"));
      expect(s, contains('/var/backups/pi-tool'));
      // A failing evcc restart restores the previous config.
      expect(s, contains(r'cp "$bak" /etc/evcc.yaml'));
      expect(s, contains('systemctl restart evcc'));
    });

    test('grafana: datasource + dashboard provisioning, then restart', () {
      expect(s, contains('/etc/grafana/provisioning/datasources/'));
      expect(s, contains('/etc/grafana/provisioning/dashboards/'));
      expect(s, contains('/var/lib/grafana/dashboards'));
      expect(s, contains('version: Flux'));
      expect(s, contains('systemctl restart grafana-server'));
    });

    test('heredocs are quoted (no shell expansion inside the dashboard)', () {
      expect(s, contains("<<'WRAP'"));
    });

    test('missing grafana or docker-evcc degrade to a skip, not a failure',
        () {
      expect(s, contains('[ -d /etc/grafana ]'));
      expect(s, contains('[ -f /etc/evcc.yaml ]'));
    });

    // --- audit 2026-08-15: honesty of the final verdict ---------------------

    test('a skipped half ends in WIRE_PARTIAL, never in a plain WIRE_OK', () {
      // Both halves must be wired for WIRE_OK; the flags decide.
      expect(s, contains('evcc_wired=0'));
      expect(s, contains('grafana_wired=0'));
      expect(s, contains('WIRE_PARTIAL'));
      expect(s, contains(r'if [ "$evcc_wired" = "1" ] && [ "$grafana_wired" = "1" ]'));
      // WIRE_OK must sit INSIDE that condition, not at the tail.
      expect(s.indexOf(r'if [ "$evcc_wired"'), lessThan(s.lastIndexOf('WIRE_OK')));
    });

    test('an evcc without a systemd unit is named as such, not as "rejected"',
        () {
      // Docker-evcc with a mounted /etc/evcc.yaml used to run into the restart
      // error and be reported as "evcc akzeptiert die Aenderung nicht".
      expect(s, contains('systemctl cat evcc'));
      expect(s.indexOf('systemctl cat evcc'),
          lessThan(s.indexOf('systemctl restart evcc')));
    });

    test('no backup, no change: a failed cp aborts before touching evcc.yaml',
        () {
      expect(s, contains(r'if ! cp /etc/evcc.yaml "$bak"'));
      expect(s.indexOf(r'if ! cp /etc/evcc.yaml "$bak"'),
          lessThan(s.indexOf('>> /etc/evcc.yaml')));
    });

    test('waits before believing systemctl is-active (Restart=always masks a '
        'crash loop)', () {
      expect(s, contains('sleep 5'));
      expect(s.indexOf('sleep 5'),
          lessThan(s.indexOf(r'if [ "$(systemctl is-active evcc)" = "active" ]')));
    });

    test('a missing trailing newline cannot glue the block onto the last line',
        () {
      expect(s, contains('tail -c 1 /etc/evcc.yaml'));
    });

    test('grafana writes and the restart are checked, not assumed', () {
      expect(s, contains('Konnte die Grafana-Datenquelle nicht schreiben'));
      expect(s, contains('if ! systemctl restart grafana-server'));
      expect(s, contains('[ ! -s /var/lib/grafana/dashboards/pitool-evcc.json ]'));
    });
  });

  group('grafanaEvccDashboardJson', () {
    final raw = grafanaEvccDashboardJson();
    final dash = jsonDecode(raw) as Map<String, dynamic>;

    test('is valid JSON with the pinned uid and title', () {
      expect(dash['uid'], 'pitool-evcc');
      expect(dash['title'], contains('evcc'));
    });

    test('covers the evcc power measurements + battery SoC', () {
      final panels = (dash['panels'] as List).cast<Map<String, dynamic>>();
      final queries = panels
          .expand((p) => (p['targets'] as List).cast<Map<String, dynamic>>())
          .map((t) => t['query'].toString())
          .join('\n');
      for (final m in [
        'gridPower',
        'pvPower',
        'homePower',
        'chargePower',
        'batterySoc'
      ]) {
        expect(queries, contains('"$m"'), reason: 'missing panel for $m');
      }
      // Every query reads the provisioned bucket.
      expect(queries, contains('from(bucket: "evcc")'));
    });

    test('panels point at the provisioned datasource', () {
      final panels = (dash['panels'] as List).cast<Map<String, dynamic>>();
      for (final p in panels) {
        expect((p['datasource'] as Map)['uid'], 'pitool-influx');
      }
    });

    test('contains no heredoc terminator (would break the wrapper)', () {
      expect(raw.split('\n').any((l) => l.trim() == 'WRAP'), isFalse);
    });
  });

  group('wiring markers are shared with the uninstall', () {
    test('the wiring appends exactly the block marker the unwire looks for',
        () {
      final s = buildStackWiringScript();
      expect(s, contains('echo "$evccInfluxBlockMarker"'));
      expect(evccInfluxBlockMarker, startsWith('# '));
      // ASCII only: grep -F under LC_ALL=C must match it byte for byte.
      expect(evccInfluxBlockMarker.codeUnits.every((c) => c < 128), isTrue);
    });

    test('the wiring creates the CLI profile the cleanup removes', () {
      expect(buildStackWiringScript(), contains('-n $stackCliProfile '));
      expect(buildInfluxCliProfileCleanupScriptPart(),
          contains(shSingleQuote(stackCliProfile)));
    });
  });

  group('buildEvccInfluxUnwireScriptPart', () {
    final s = buildEvccInfluxUnwireScriptPart();

    test('acts only on the Pi-Tool-marked block', () {
      expect(s, contains(shSingleQuote(evccInfluxBlockMarker)));
      expect(s, contains(r'grep -qxF "$wire_marker" /etc/evcc.yaml'));
      // A user's own influx: block is never a trigger.
      expect(s, isNot(contains("grep -q '^influx:'")));
    });

    test('timestamped backup under /var/backups/pi-tool before the change',
        () {
      expect(
          s,
          contains(r'unwire_bak="/var/backups/pi-tool/evcc.yaml.unwire-'
              r'$(date +%Y%m%d-%H%M%S)"'));
      expect(s, contains(r'cp -p /etc/evcc.yaml "$unwire_bak"'));
      expect(s.indexOf(r'cp -p /etc/evcc.yaml "$unwire_bak"'),
          lessThan(s.indexOf(r'mv -f "$unwire_tmp" /etc/evcc.yaml')));
    });

    test('evcc is restarted only when installed and running, and a config '
        'it rejects is rolled back', () {
      final restart = s.indexOf('systemctl restart evcc');
      expect(restart, greaterThan(0));
      expect(s.indexOf('systemctl cat evcc'), lessThan(restart));
      expect(s.indexOf('systemctl is-active --quiet evcc'), lessThan(restart));
      // Restart=always reports "active" at once even for a crash loop.
      expect(s.indexOf('sleep 5'), greaterThan(restart));
      final rollback = s.indexOf(r'cp -p "$unwire_bak" /etc/evcc.yaml');
      expect(rollback, greaterThan(s.indexOf('sleep 5')));
      expect(s.indexOf('UNINSTALL_REFUSED', rollback), greaterThan(rollback));
    });

    test('every refusal is one UNINSTALL_REFUSED line followed by exit 3', () {
      final lines = s.split('\n');
      var n = 0;
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('UNINSTALL_REFUSED')) continue;
        n++;
        expect(lines[i].trim(), startsWith('echo "UNINSTALL_REFUSED: '));
        expect(lines[i + 1].trim(), 'exit 3');
      }
      expect(n, 2);
    });

    test('atomic replace next to the file, owner and mode kept', () {
      expect(s, contains('mktemp /etc/.pitool-evcc.XXXXXX'));
      expect(s, contains(r'chmod --reference=/etc/evcc.yaml "$unwire_tmp"'));
      expect(s, contains(r'chown --reference=/etc/evcc.yaml "$unwire_tmp"'));
    });

    test('never reads stdin, no unquoted heredoc, no token in the log', () {
      expect(s, isNot(matches(RegExp(r'exec\s*<\s*/dev/null'))));
      expect(s, isNot(matches(RegExp(r'<<-?\s*[A-Za-z_]'))));
      expect(s, isNot(contains(r'$tok')));
      expect(s, isNot(contains('rm -rf')));
    });
  });

  group('buildInfluxCliProfileCleanupScriptPart', () {
    final s = buildInfluxCliProfileCleanupScriptPart();

    test('touches only the root CLI config, only with our profile in it', () {
      expect(s, contains('/root/.influxdbv2/configs'));
      expect(s, isNot(contains('rm -rf')));
      // The directory only goes when it is empty.
      expect(s, contains('rmdir /root/.influxdbv2'));
      expect(s, isNot(matches(RegExp(r'exec\s*<\s*/dev/null'))));
    });
  });

  // The fragments in a real bash against a sandbox (/etc, /var, /root point
  // into a temp dir; systemctl and sleep are stubs), fed on stdin like the
  // app's `sudo -S bash -s`.
  group('stack unwire in bash', () {
    late Directory tmp;
    late String root;

    String read(String rel) => File('${tmp.path}/$rel').readAsStringSync();
    bool exists(String rel) =>
        FileSystemEntity.typeSync('${tmp.path}/$rel') !=
        FileSystemEntityType.notFound;
    void write(String rel, String content) {
      final f = File('${tmp.path}/$rel');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    String log() => exists('state/log') ? read('state/log') : '';
    List<String> backups() => exists('var/backups/pi-tool')
        ? Directory('${tmp.path}/var/backups/pi-tool')
            .listSync()
            .map((e) => e.uri.pathSegments.last)
            .toList()
        : const [];

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('unwire');
      root = _posix(tmp.path);
      write('bin/systemctl', r'''#!/bin/bash
echo "systemctl $*" >> "$STUB/log"
q=0; args=()
for a; do case "$a" in --quiet) q=1 ;; *) args+=("$a") ;; esac; done
u=${args[1]}
case "${args[0]}" in
  cat) [ -f "$STUB/unit.$u" ] ;;
  is-active) s=$(cat "$STUB/active.$u" 2>/dev/null || echo inactive); [ "$q" = 1 ] || echo "$s"; [ "$s" = active ] ;;
  restart)
    if [ -f "$STUB/needs_influx" ] && ! grep -q '^influx:' "$ROOT/etc/evcc.yaml"; then
      echo failed > "$STUB/active.$u"
    else
      echo active > "$STUB/active.$u"
    fi ;;
esac
exit $?
''');
      write('bin/sleep', '#!/bin/sh\nexit 0\n');
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['+x', '${tmp.path}/bin/systemctl']);
        Process.runSync('chmod', ['+x', '${tmp.path}/bin/sleep']);
      }
      Directory('${tmp.path}/state').createSync();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<({int code, String out})> run(String fragment) async {
      final script = fragment.replaceAllMapped(
          RegExp(r'''(^|[\s'"=])/(etc|var|root)/''', multiLine: true),
          (m) => '${m[1]}$root/${m[2]}/');
      final p = await Process.start(_bash!, ['-s']);
      final out = p.stdout.transform(utf8.decoder).join();
      final err = p.stderr.transform(utf8.decoder).join();
      p.stdin.add(utf8.encode('set -e\n'
          'export PATH=${shSingleQuote('$root/bin')}:"\$PATH"\n'
          'export STUB=${shSingleQuote('$root/state')} '
          'ROOT=${shSingleQuote(root)}\n'
          '$script\necho FRAGMENT_DONE\n'));
      await p.stdin.close();
      final code = await p.exitCode;
      return (code: code, out: '${await out}${await err}');
    }

    const head = 'site:\n  title: Zuhause\n';
    const block = '\n'
        '# Von Pi-Tool ergaenzt (Monitoring-Stack):\n'
        'influx:\n'
        '  url: http://localhost:8086\n'
        '  database: evcc\n'
        '  org: pi-tool\n'
        '  token: abc\n';
    const tail = 'loadpoints:\n  - title: Garage\n';

    void evccRunning() {
      write('state/unit.evcc', '');
      write('state/active.evcc', 'active');
    }

    test('removes exactly the marked block, backs up, restarts evcc',
        () async {
      evccRunning();
      write('etc/evcc.yaml', '$head$block$tail');
      final r = await run(buildEvccInfluxUnwireScriptPart());
      expect(r.code, 0, reason: r.out);
      expect(r.out, contains('FRAGMENT_DONE'));
      expect(read('etc/evcc.yaml'), '$head$tail');
      final b = backups().where((n) => n.startsWith('evcc.yaml.unwire-'));
      expect(b, hasLength(1));
      expect(read('var/backups/pi-tool/${b.single}'), '$head$block$tail');
      expect(log(), contains('systemctl restart evcc'));
      // No temp file left next to the config.
      expect(
          Directory('${tmp.path}/etc')
              .listSync()
              .map((e) => e.uri.pathSegments.last),
          ['evcc.yaml']);
    });

    test('block at the end of the file (as the wiring leaves it)', () async {
      evccRunning();
      write('etc/evcc.yaml', '$head$block');
      final r = await run(buildEvccInfluxUnwireScriptPart());
      expect(r.code, 0, reason: r.out);
      expect(read('etc/evcc.yaml'), head);
    });

    test('a hand-extended block (comments, blank lines, extra keys) goes as '
        'a whole, the next section stays', () async {
      evccRunning();
      const edited = '\n'
          '# Von Pi-Tool ergaenzt (Monitoring-Stack):\n'
          'influx:\n'
          '  url: http://localhost:8086\n'
          '  # own note\n'
          '\n'
          '  database: evcc\n'
          '# col-0 comment inside the mapping\n'
          '  insecure: true\n';
      write('etc/evcc.yaml', '$head$edited\n# about loadpoints\n$tail');
      final r = await run(buildEvccInfluxUnwireScriptPart());
      expect(r.code, 0, reason: r.out);
      expect(read('etc/evcc.yaml'), '$head\n# about loadpoints\n$tail');
    });

    test("a user's own influx block is left alone: no backup, no restart",
        () async {
      evccRunning();
      const own = 'influx:\n  url: http://nas:8086\n';
      write('etc/evcc.yaml', '$head$own$tail');
      final r = await run(buildEvccInfluxUnwireScriptPart());
      expect(r.code, 0, reason: r.out);
      expect(read('etc/evcc.yaml'), '$head$own$tail');
      expect(backups(), isEmpty);
      expect(log(), isNot(contains('restart')));
    });

    test('evcc not running (or only rc): block removed, evcc not started',
        () async {
      write('etc/evcc.yaml', '$head$block$tail');
      write('state/unit.evcc', '');
      write('state/active.evcc', 'inactive');
      var r = await run(buildEvccInfluxUnwireScriptPart());
      expect(r.code, 0, reason: r.out);
      expect(read('etc/evcc.yaml'), '$head$tail');
      expect(log(), isNot(contains('restart')));

      // evcc removed with "keep" (no unit): the yaml is cleaned all the same.
      File('${tmp.path}/state/unit.evcc').deleteSync();
      write('etc/evcc.yaml', '$head$block$tail');
      r = await run(buildEvccInfluxUnwireScriptPart());
      expect(r.code, 0, reason: r.out);
      expect(read('etc/evcc.yaml'), '$head$tail');
      expect(log(), isNot(contains('restart')));
    });

    test('evcc not coming back: yaml restored, refused with exit 3', () async {
      evccRunning();
      write('state/needs_influx', '');
      write('etc/evcc.yaml', '$head$block$tail');
      final r = await run(buildEvccInfluxUnwireScriptPart());
      expect(r.code, 3, reason: r.out);
      expect(r.out, contains('UNINSTALL_REFUSED: '));
      expect(r.out, isNot(contains('FRAGMENT_DONE')));
      expect(read('etc/evcc.yaml'), '$head$block$tail');
      expect(read('state/active.evcc').trim(), 'active');
    });

    test('no evcc.yaml at all: nothing to do', () async {
      final r = await run(buildEvccInfluxUnwireScriptPart());
      expect(r.code, 0, reason: r.out);
      expect(r.out, contains('FRAGMENT_DONE'));
      expect(backups(), isEmpty);
    });

    test('CLI profile: a file with only our profile goes with its dir',
        () async {
      write(
          'root/.influxdbv2/configs',
          '[pitool]\n  url = "http://localhost:8086"\n  token = "t"\n'
              '  org = "pi-tool"\n  active = true\n'
              '# \n# [eu-central]\n#   url = "https://example.invalid"\n');
      final r = await run(buildInfluxCliProfileCleanupScriptPart());
      expect(r.code, 0, reason: r.out);
      expect(exists('root/.influxdbv2'), isFalse);
    });

    test('CLI profile: other profiles stay, only ours goes', () async {
      write(
          'root/.influxdbv2/configs',
          '[cloud]\n  url = "https://example.invalid"\n  active = true\n'
              '[pitool]\n  url = "http://localhost:8086"\n  token = "t"\n'
              '[other]\n  url = "http://nas:8086"\n');
      final r = await run(buildInfluxCliProfileCleanupScriptPart());
      expect(r.code, 0, reason: r.out);
      expect(
          read('root/.influxdbv2/configs'),
          '[cloud]\n  url = "https://example.invalid"\n  active = true\n'
          '[other]\n  url = "http://nas:8086"\n');
    });

    test('CLI profile: a config without ours is not touched', () async {
      const own = '[default]\n  url = "http://localhost:8086"\n';
      write('root/.influxdbv2/configs', own);
      final r = await run(buildInfluxCliProfileCleanupScriptPart());
      expect(r.code, 0, reason: r.out);
      expect(read('root/.influxdbv2/configs'), own);
    });
  }, skip: _bash == null ? 'needs bash (PITOOL_TEST_BASH on Windows)' : false);
}
