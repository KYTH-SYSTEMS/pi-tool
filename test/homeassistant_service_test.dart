import 'dart:convert';
import 'dart:io';

import 'package:evcc_updater/src/services/homeassistant_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real bash for the script tests: Git Bash on Windows (never the WSL
/// launcher `bash.exe` may resolve to), plain `bash` elsewhere. Null = skip.
final String? _bash = Platform.isWindows
    ? (File(r'C:\Program Files\Git\bin\bash.exe').existsSync()
        ? r'C:\Program Files\Git\bin\bash.exe'
        : null)
    : 'bash';

/// Fake docker CLI for the uninstall tests. `$1` = state dir, then the docker
/// arguments. Containers are files `$s/c/<name>` (sourced: image, running,
/// config, labels, imageid); every call is appended to `$s/calls`. An argument
/// shape the script is not supposed to use fails loudly (exit 2).
const String _fakeDocker = r'''
s=$1; shift
echo "$*" >> "$s/calls"
if [ -f "$s/down" ]; then echo 'Cannot connect to the Docker daemon' >&2; exit 1; fi
cmd=$1; shift
case "$cmd" in
  info) ;;
  ps)
    all=0; [ "$1" = -a ] && all=1
    for f in "$s"/c/*; do
      [ -f "$f" ] || continue
      . "$f"
      if [ $all = 1 ] || [ "$running" = 1 ]; then echo "${f##*/}|$image"; fi
    done ;;
  container)
    [ "$1" = inspect ] || exit 2
    shift; fmt=
    if [ "$1" = -f ]; then fmt=$2; shift 2; fi
    [ -f "$s/c/$1" ] || { echo "Error: No such container: $1" >&2; exit 1; }
    . "$s/c/$1"
    case "$fmt" in
      '') echo '[]' ;;
      *Labels*) for l in $labels; do echo "$l"; done ;;
      *Mounts*) echo "$config" ;;
      *.Image*) echo "$imageid" ;;
      *) echo "unexpected format: $fmt" >&2; exit 2 ;;
    esac ;;
  stop)
    [ "$1" = -t ] || exit 2
    shift 2
    [ -f "$s/c/$1" ] || exit 1
    echo running=0 >> "$s/c/$1" ;;
  rm) [ -f "$s/c/$1" ] || exit 1; rm "$s/c/$1"
    # Containers queued in appear/ come up now: started by someone else while
    # the uninstall runs, i.e. after the guards and before the verification.
    if [ -d "$s/appear" ]; then mv "$s"/appear/* "$s/c/"; rmdir "$s/appear"; fi ;;
  image) ;;
  *) echo "unexpected docker call: $cmd" >&2; exit 2 ;;
esac
''';

/// Containers that carry "home-assistant" in their image path but are not
/// Home Assistant: the Matter Server the HA docs have Container users run next
/// to it, Matter Hub, and the Supervisor/add-on images of a Supervised install.
const List<String> _companions = [
  'matter-server|ghcr.io/home-assistant-libs/python-matter-server:stable',
  'matter-hub|ghcr.io/t0bst4r/home-assistant-matter-hub:latest',
  'hassio_supervisor|ghcr.io/home-assistant/aarch64-hassio-supervisor:2026.09.1',
  'addon_core_matter_server|ghcr.io/home-assistant/aarch64-addon-matter-server:8.1.0',
];

/// Runs [script] on stdin of a real bash (like the sudo shell does); stdout.
Future<String> _runBash(String script) async {
  final p = await Process.start(_bash!, ['-s']);
  p.stdin.add(utf8.encode('$script\n'));
  await p.stdin.close();
  final out = p.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
  final err = p.stderr.drain<void>();
  final result = await out;
  await err;
  await p.exitCode;
  return result;
}

void main() {
  group('parseHomeAssistant', () {
    test('finds the homeassistant container in docker ps output', () {
      const out = 'pihole|pihole/pihole:latest\n'
          'homeassistant|ghcr.io/home-assistant/home-assistant:stable\n'
          'evcc|evcc/evcc:0.123';
      final c = parseHomeAssistant(out);
      expect(c, isNotNull);
      expect(c!.name, 'homeassistant');
      expect(c.image, 'ghcr.io/home-assistant/home-assistant:stable');
      expect(c.version, 'stable');
    });

    test('matches by image even with a non-standard container name', () {
      final c = parseHomeAssistant(
          'hass|ghcr.io/home-assistant/home-assistant:2024.6');
      expect(c, isNotNull);
      expect(c!.name, 'hass');
      expect(c.version, '2024.6');
    });

    test('untagged image falls back to the full image as version', () {
      final c = parseHomeAssistant(
          'homeassistant|ghcr.io/home-assistant/home-assistant');
      expect(c, isNotNull);
      expect(c!.version, isNotEmpty);
    });

    test('digest-pinned image shows a label, not the raw sha256 hex', () {
      final c = parseHomeAssistant('homeassistant|ghcr.io/home-assistant/'
          'home-assistant@sha256:0123456789abcdef0123456789abcdef0123456789'
          'abcdef0123456789abcdef01');
      expect(c, isNotNull);
      expect(c!.version, 'digest-pinned');
    });

    test('null when no Home Assistant container is present', () {
      expect(
          parseHomeAssistant('evcc|evcc/evcc:latest\npihole|pihole/pihole'),
          isNull);
      expect(parseHomeAssistant(''), isNull);
    });

    test('companion images (Matter Server & Co.) are not Home Assistant', () {
      for (final line in _companions) {
        expect(parseHomeAssistant(line), isNull, reason: line);
      }
      expect(parseHomeAssistant(_companions.join('\n')), isNull);
    });

    test('finds Home Assistant behind a Matter Server listed first', () {
      final c = parseHomeAssistant('${_companions.first}\n'
          'homeassistant|ghcr.io/home-assistant/home-assistant:stable');
      expect(c, isNotNull);
      expect(c!.name, 'homeassistant');
      expect(c.image, homeAssistantImage);
    });

    test('recognises the Docker Hub, machine-specific and linuxserver images',
        () {
      for (final image in [
        'homeassistant/home-assistant:2026.9',
        'docker.io/homeassistant/home-assistant:stable',
        'homeassistant/raspberrypi4-64-homeassistant:stable',
        'ghcr.io/home-assistant/aarch64-homeassistant:2026.9.1',
        'lscr.io/linuxserver/homeassistant:latest',
        'linuxserver/homeassistant',
      ]) {
        // A name outside the fallback list: only the image can match.
        expect(parseHomeAssistant('ha|$image')?.image, image, reason: image);
      }
    });
  });

  group('haVersionProbe in bash', () {
    /// Runs the probe against a docker stub: `ps` lists [ps], `exec` answers
    /// only inside the container named `homeassistant`.
    Future<String?> probe(List<String> ps) async {
      final listing = ps.map((l) => "'$l'").join(' ');
      return parseHaVersion(await _runBash(
          'docker() { case "\$1" in\n'
          "  ps) printf '%s\\n' $listing ;;\n"
          '  exec) [ "\$2" = homeassistant ] || { echo "OCI runtime exec '
          'failed" >&2; return 126; }; echo 2026.9.2 ;;\n'
          'esac; }\n'
          '$haVersionProbe'));
    }

    test('reads the version from the HA container, not a Matter Server', () async {
      expect(
          await probe([
            ..._companions,
            'homeassistant|ghcr.io/home-assistant/home-assistant:stable',
          ]),
          '2026.9.2');
    });

    test('stays empty when only companions run', () async {
      expect(await probe(_companions), isNull);
    });
  }, skip: _bash == null ? 'needs bash (Git Bash on Windows)' : false);

  group('buildHomeAssistantInstallScript', () {
    final s = buildHomeAssistantInstallScript();

    test('runs the official container with host network + /config volume', () {
      expect(s, contains('ghcr.io/home-assistant/home-assistant:stable'));
      expect(s, contains('--name homeassistant'));
      expect(s, contains('--network=host'));
      expect(s, contains(':/config'));
      expect(s, contains('--restart=unless-stopped'));
    });

    test('installs Docker when missing and is idempotent', () {
      expect(s, contains('get.docker.com'));
      expect(s, contains('grep -qx homeassistant'));
    });
  });

  group('buildHomeAssistantUninstallScript', () {
    final keep = buildHomeAssistantUninstallScript(purge: false);
    final purge = buildHomeAssistantUninstallScript(purge: true);
    final both = {'keep': keep, 'purge': purge};

    test('root-script contract: set -e first, stdin untouched, no autoremove',
        () {
      both.forEach((mode, s) {
        expect(s.trimLeft(), startsWith('set -e\n'), reason: mode);
        expect(s, contains('export DEBIAN_FRONTEND=noninteractive'),
            reason: mode);
        // The script arrives on stdin (`sudo -S bash -s`): redirecting the
        // shell's own stdin would silently drop everything after that line.
        expect(s, isNot(matches(RegExp(r'exec\s+0?<'))), reason: mode);
        expect(s, isNot(contains('<<')), reason: mode);
        expect(s, isNot(contains('autoremove')), reason: mode);
      });
    });

    test('never touches Docker itself or any package', () {
      both.forEach((mode, s) {
        for (final banned in [
          'apt-get',
          'dpkg',
          'systemctl',
          '/var/lib/docker',
          'docker.list',
          'keyrings',
          'docker system',
          'docker volume',
          'docker network',
          'container prune',
          'groupdel',
        ]) {
          expect(s, isNot(contains(banned)), reason: '$mode: $banned');
        }
      });
    });

    test('a refusal is one UNINSTALL_REFUSED line and exit 3', () {
      both.forEach((mode, s) {
        expect(s, contains('refuse() { echo "UNINSTALL_REFUSED: \$1"; exit 3; }'),
            reason: mode);
        expect('UNINSTALL_REFUSED'.allMatches(s), hasLength(1), reason: mode);
      });
    });

    test('all guards run before the first change', () {
      both.forEach((mode, s) {
        final lastGuard = s.lastIndexOf('refuse ');
        expect(lastGuard, greaterThan(0), reason: mode);
        final firstChange = s.indexOf('docker stop');
        expect(firstChange, greaterThan(lastGuard), reason: mode);
        for (final step in ['docker rm', 'docker image', 'rm -rf', 'rm -f', 'rmdir']) {
          final i = s.indexOf(step);
          if (i >= 0) expect(i, greaterThan(lastGuard), reason: '$mode: $step');
        }
      });
    });

    test('guards: usable docker, only the app-form container, no compose, '
        'app config dir', () {
      both.forEach((mode, s) {
        expect(s, contains('command -v docker'), reason: mode);
        expect(s, contains('docker info'), reason: mode);
        // ALL containers, not only running ones: a stopped foreign HA could
        // come back, and our own rollback copy is stopped.
        expect(s, contains("docker ps -a --format '{{.Names}}|{{.Image}}'"),
            reason: mode);
        // Mirrors parseHomeAssistant (core image or conventional name); the
        // bash test below checks both agree line by line.
        expect(s, contains('home-?assistant/'), reason: mode);
        expect(s, contains('linuxserver/homeassistant'), reason: mode);
        expect(s, contains('homeassistant|hass|home-assistant'), reason: mode);
        expect(s, contains('$homeAssistantContainerName-evccpitool-old'),
            reason: mode);
        expect(s, contains('com.docker.compose.'), reason: mode);
        expect(s, contains('.Destination "/config"'), reason: mode);
        expect(s, contains(homeAssistantConfigDir), reason: mode);
      });
    });

    test('stops gracefully so the recorder database is not cut mid-write', () {
      both.forEach((mode, s) {
        expect(s, contains('docker stop -t 60'), reason: mode);
        expect(s, isNot(contains('docker rm -f')), reason: mode);
      });
    });

    test('mutating docker calls cannot eat the script from stdin', () {
      both.forEach((mode, s) {
        for (final line in s.split('\n')) {
          if (RegExp(r'docker (stop|rm|image)').hasMatch(line)) {
            expect(line, contains('</dev/null'), reason: '$mode: $line');
          }
        }
      });
    });

    test('keep leaves config, data, the image and the app backups alone', () {
      expect(keep, isNot(contains('rm -rf')));
      expect(keep, isNot(contains('rmdir')));
      expect(keep, isNot(contains('docker image')));
      expect(keep, isNot(contains('/var/backups/pi-tool')));
    });

    test('purge removes exactly the app-made config dir, images and HA backups',
        () {
      expect(purge, contains('rm -rf -- $homeAssistantConfigDir\n'));
      // The parent only if nothing else lives there.
      expect(purge, contains('rmdir /opt/homeassistant 2>/dev/null || true'));
      expect(purge,
          contains('rm -f -- /var/backups/pi-tool/homeassistant-backup-*\n'));
      expect(purge, contains('docker image rm'));
      expect(purge, contains(homeAssistantImage));
      expect(purge, isNot(contains('/var/backups/pi-tool/*')));
      expect(purge, isNot(contains('rm -rf -- /opt/homeassistant\n')));
    });

    test('every rm/rmdir works on a literal path, never on a shell variable',
        () {
      both.forEach((mode, s) {
        for (final line in s.split('\n')) {
          final t = line.trimLeft();
          if (t.startsWith('rm ') || t.startsWith('rmdir ')) {
            expect(t, isNot(contains(r'$')), reason: '$mode: $t');
          }
        }
      });
    });

    test('verifies the result, then prints the marker as the very last line',
        () {
      both.forEach((mode, s) {
        final lines = s.trimRight().split('\n');
        expect(lines.last, 'echo $homeAssistantRemovedMarker', reason: mode);
        expect(homeAssistantRemovedMarker.allMatches(s), hasLength(1),
            reason: mode);
        // The card condition: no HA-like container may still be running.
        final verify = s.indexOf("docker ps --format '{{.Names}}|{{.Image}}'");
        expect(verify, greaterThan(s.indexOf('docker rm')), reason: mode);
      });
      expect(purge.indexOf('[ -e $homeAssistantConfigDir ]'),
          greaterThan(purge.indexOf('rm -rf')));
    });

    test('the marker cannot be mistaken for an install marker', () {
      expect(homeAssistantRemovedMarker, 'HA_REMOVED_OK');
      expect(homeAssistantRemovedMarker, isNot(contains('INSTALL_OK')));
    });

    test('targets the same container name and config dir the install uses', () {
      final install = buildHomeAssistantInstallScript();
      expect(install, contains('--name $homeAssistantContainerName'));
      expect(install, contains('-v $homeAssistantConfigDir:/config'));
      expect(install, contains('mkdir -p $homeAssistantConfigDir'));
      expect(install, contains(homeAssistantImage));
    });
  });

  // The real script, fed to `bash -s` on stdin exactly like the sudo shell
  // does, against a stub docker and a sandbox standing in for /opt and
  // /var/backups/pi-tool. Deterministic and offline.
  group('buildHomeAssistantUninstallScript in bash', () {
    late Directory tmp;
    late String root; // forward slashes: usable by Dart and by bash

    String cfgDir() => '$root/opt/homeassistant/config';

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ha_uninstall');
      root = tmp.path.replaceAll(r'\', '/');
      Directory('$root/state/c').createSync(recursive: true);
      File('$root/docker.sh').writeAsStringSync(_fakeDocker);
      Directory('${cfgDir()}/.storage').createSync(recursive: true);
      File('${cfgDir()}/configuration.yaml').writeAsStringSync('default_config:\n');
      File('${cfgDir()}/home-assistant_v2.db').writeAsStringSync('db');
      Directory('$root/backups').createSync();
      for (final f in [
        'homeassistant-backup-20260901-120000.tar.gz',
        'homeassistant-backup-20260902-120000.tar.gz',
        'pihole-backup-20260901-120000.zip',
        'config-configuration.yaml-20260901-120000.bak',
      ]) {
        File('$root/backups/$f').writeAsStringSync('x');
      }
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    void container(
      String name, {
      String image = homeAssistantImage,
      bool running = true,
      String? config,
      List<String> labels = const [],
      String id = 'sha256:1111',
      bool appearsDuringRun = false, // comes up with the first `docker rm`
    }) {
      final dir = Directory(
          '$root/state/${appearsDuringRun ? 'appear' : 'c'}')
        ..createSync(recursive: true);
      File('${dir.path}/$name').writeAsStringSync("image='$image'\n"
          'running=${running ? 1 : 0}\n'
          "config='${config ?? cfgDir()}'\n"
          "labels='${labels.join(' ')}'\n"
          "imageid='$id'\n");
    }

    /// The app's install, updated once: running container + stopped rollback.
    void appInstall() {
      container(homeAssistantContainerName, id: 'sha256:2222');
      container('$homeAssistantContainerName-evccpitool-old',
          running: false, id: 'sha256:1111');
    }

    bool exists(String name) => File('$root/state/c/$name').existsSync();

    List<String> calls() {
      final f = File('$root/state/calls');
      return f.existsSync() ? f.readAsLinesSync() : const [];
    }

    List<String> changes() => calls()
        .where((c) => RegExp(r'^(stop|rm|image|rename|start|run|update)\b')
            .hasMatch(c))
        .toList();

    List<String> backups() => Directory('$root/backups')
        .listSync()
        .map((e) => e.uri.pathSegments.last)
        .toList();

    Future<({int code, String out})> run({required bool purge}) async {
      final script = buildHomeAssistantUninstallScript(purge: purge)
          .replaceAll('/opt/homeassistant', '$root/opt/homeassistant')
          .replaceAll('/var/backups/pi-tool', '$root/backups');
      final p = await Process.start(_bash!, ['-s']);
      p.stdin.add(utf8.encode(
          "docker() { bash '$root/docker.sh' '$root/state' \"\$@\"; }\n"
          '$script\n'));
      await p.stdin.close();
      final res = await Future.wait([
        p.stdout.transform(const Utf8Decoder(allowMalformed: true)).join(),
        p.stderr.transform(const Utf8Decoder(allowMalformed: true)).join(),
      ]);
      final code = await p.exitCode;
      return (code: code, out: '${res[0]}\n--stderr--\n${res[1]}');
    }

    String lastLine(String out) => out
        .split('\n--stderr--\n')
        .first
        .trimRight()
        .split('\n')
        .last;

    void expectRefused(({int code, String out}) r, String reason) {
      expect(r.code, 3, reason: r.out);
      final refusals =
          r.out.split('\n').where((l) => l.startsWith('UNINSTALL_REFUSED: '));
      expect(refusals, hasLength(1), reason: r.out);
      expect(refusals.single, contains(reason));
      expect(lastLine(r.out), refusals.single);
      expect(r.out, isNot(contains(homeAssistantRemovedMarker)));
      expect(changes(), isEmpty, reason: 'nothing may change: ${calls()}');
      expect(File('${cfgDir()}/configuration.yaml').existsSync(), isTrue);
      expect(backups(), hasLength(4));
    }

    test('keep: removes both containers, keeps config, data, image, backups',
        () async {
      appInstall();
      container('pihole', image: 'pihole/pihole:latest', config: '/etc/pihole');
      final r = await run(purge: false);
      expect(r.code, 0, reason: r.out);
      expect(lastLine(r.out), homeAssistantRemovedMarker);
      expect(exists(homeAssistantContainerName), isFalse);
      expect(exists('$homeAssistantContainerName-evccpitool-old'), isFalse);
      expect(exists('pihole'), isTrue);
      expect(calls(), contains('stop -t 60 $homeAssistantContainerName'));
      expect(changes().where((c) => c.startsWith('image')), isEmpty);
      expect(File('${cfgDir()}/configuration.yaml').existsSync(), isTrue);
      expect(File('${cfgDir()}/home-assistant_v2.db').existsSync(), isTrue);
      expect(backups(), hasLength(4));
    });

    test('purge: also config dir, images and only the HA backups', () async {
      appInstall();
      final r = await run(purge: true);
      expect(r.code, 0, reason: r.out);
      expect(lastLine(r.out), homeAssistantRemovedMarker);
      expect(exists(homeAssistantContainerName), isFalse);
      expect(exists('$homeAssistantContainerName-evccpitool-old'), isFalse);
      expect(Directory(cfgDir()).existsSync(), isFalse);
      // Empty parent goes as well.
      expect(Directory('$root/opt/homeassistant').existsSync(), isFalse);
      expect(
          backups(),
          unorderedEquals([
            'pihole-backup-20260901-120000.zip',
            'config-configuration.yaml-20260901-120000.bak',
          ]));
      final images = calls().where((c) => c.startsWith('image rm')).toList();
      expect(images, contains('image rm $homeAssistantImage'));
      expect(images, contains('image rm sha256:2222'));
      expect(images, contains('image rm sha256:1111'));
    });

    test('purge keeps anything else living next to the config dir', () async {
      appInstall();
      Directory('$root/opt/homeassistant/esphome').createSync();
      final r = await run(purge: true);
      expect(r.code, 0, reason: r.out);
      expect(Directory(cfgDir()).existsSync(), isFalse);
      expect(Directory('$root/opt/homeassistant/esphome').existsSync(), isTrue);
    });

    test('a retry after a partial run succeeds (idempotent)', () async {
      // Containers already gone, config + backups still there.
      final keepRun = await run(purge: false);
      expect(keepRun.code, 0, reason: keepRun.out);
      expect(lastLine(keepRun.out), homeAssistantRemovedMarker);
      expect(File('${cfgDir()}/configuration.yaml').existsSync(), isTrue);

      // Only the rollback copy survived the first attempt.
      container('$homeAssistantContainerName-evccpitool-old', running: false);
      final purgeRun = await run(purge: true);
      expect(purgeRun.code, 0, reason: purgeRun.out);
      expect(exists('$homeAssistantContainerName-evccpitool-old'), isFalse);
      expect(Directory(cfgDir()).existsSync(), isFalse);

      final again = await run(purge: true);
      expect(again.code, 0, reason: again.out);
      expect(lastLine(again.out), homeAssistantRemovedMarker);
    });

    test('refuses when another Home Assistant container runs', () async {
      appInstall();
      container('hass', image: 'homeassistant/home-assistant:2026.9',
          config: '/home/pi/hass');
      for (final purge in [false, true]) {
        expectRefused(await run(purge: purge), 'hass');
      }
    });

    test('refuses on a stopped foreign HA and on a conventional name alone',
        () async {
      appInstall();
      container('my-ha', image: 'ghcr.io/home-assistant/home-assistant:2025.1',
          running: false);
      expectRefused(await run(purge: true), 'my-ha');
      File('$root/state/c/my-ha').deleteSync();
      container('home-assistant', image: 'custom/smart-home:1');
      expectRefused(await run(purge: true), 'home-assistant');
    });

    test('refuses a foreign machine-specific or linuxserver HA image',
        () async {
      appInstall();
      container('ha-pi4',
          image: 'homeassistant/raspberrypi4-64-homeassistant:2023.1',
          running: false,
          config: '/home/pi/ha');
      expectRefused(await run(purge: true), 'ha-pi4');
      File('$root/state/c/ha-pi4').deleteSync();
      container('ha-lsio',
          image: 'lscr.io/linuxserver/homeassistant:latest', config: '/srv/ha');
      expectRefused(await run(purge: false), 'ha-lsio');
    });

    test('companions (Matter Server & Co.) neither block nor get touched',
        () async {
      for (final purge in [false, true]) {
        appInstall();
        var running = true;
        for (final line in _companions) {
          final [name, image] = line.split('|');
          container(name, image: image, running: running, config: '/data');
          running = !running; // stopped companions must not block either
        }
        final r = await run(purge: purge);
        expect(r.code, 0, reason: r.out);
        expect(lastLine(r.out), homeAssistantRemovedMarker);
        expect(r.out, isNot(contains('UNINSTALL_REFUSED')));
        expect(exists(homeAssistantContainerName), isFalse);
        for (final line in _companions) {
          final name = line.split('|').first;
          expect(exists(name), isTrue, reason: '$purge: $name');
          expect(changes().where((c) => c.contains(name)), isEmpty,
              reason: '$purge: ${changes()}');
        }
      }
    });

    test('verification: a Matter Server started meanwhile is not HA',
        () async {
      appInstall();
      final [name, image] = _companions.first.split('|');
      container(name, image: image, config: '/data', appearsDuringRun: true);
      final r = await run(purge: false);
      expect(r.code, 0, reason: r.out);
      expect(lastLine(r.out), homeAssistantRemovedMarker);
      expect(exists(name), isTrue);
    });

    test('verification: another HA started meanwhile fails the run', () async {
      appInstall();
      container('ha2', config: '/srv/ha2', appearsDuringRun: true);
      final r = await run(purge: false);
      expect(r.code, isNot(0), reason: r.out);
      expect(r.out, contains('Es läuft weiterhin ein Home-Assistant-Container: ha2'));
      expect(r.out, isNot(contains(homeAssistantRemovedMarker)));
    });

    test('guard and verification match exactly what the card shows', () async {
      final s = buildHomeAssistantUninstallScript(purge: true);
      final re = RegExp(r"^ha_re='([^']+)'$", multiLine: true)
          .firstMatch(s)!
          .group(1)!;
      // Both checks use that one pattern, and so does the version probe.
      expect('grep -iE "\$ha_re"'.allMatches(s), hasLength(2));
      expect(haVersionProbe, contains("grep -iE '$re'"));
      final lines = [
        ..._companions,
        'homeassistant|$homeAssistantImage',
        'ha|homeassistant/home-assistant:2026.9',
        'ha|ghcr.io/home-assistant/home-assistant@sha256:0123abcd',
        'ha|ghcr.io/home-assistant/home-assistant',
        'ha|registry.local:5000/home-assistant/home-assistant:stable',
        'ha|homeassistant/raspberrypi4-64-homeassistant:stable',
        'ha|lscr.io/linuxserver/homeassistant:latest',
        'hass|custom/smart-home:1',
        'home-assistant|custom/smart-home:1',
        'homeassistant|custom/smart-home:1',
        'evcc|evcc/evcc:latest',
        'pihole|pihole/pihole:latest',
        'esphome|ghcr.io/esphome/esphome:stable',
        'zigbee2mqtt|koenkk/zigbee2mqtt:latest',
      ];
      File('$root/lines').writeAsStringSync('${lines.join('\n')}\n');
      final out = await _runBash('while IFS= read -r l; do '
          "if printf '%s\\n' \"\$l\" | grep -qiE '$re'; "
          'then echo 1; else echo 0; fi; '
          "done < '$root/lines'");
      expect(out.trim().split('\n'),
          [for (final l in lines) parseHomeAssistant(l) == null ? '0' : '1']);
    });

    test('refuses a compose-managed Home Assistant', () async {
      container(homeAssistantContainerName, labels: [
        'com.docker.compose.project',
        'com.docker.compose.service',
        'io.hass.type',
      ]);
      for (final purge in [false, true]) {
        expectRefused(await run(purge: purge), 'Compose');
      }
    });

    test('refuses a same-named container whose /config lives elsewhere',
        () async {
      container(homeAssistantContainerName, config: '/home/pi/homeassistant');
      for (final purge in [false, true]) {
        expectRefused(await run(purge: purge), 'nicht von Pi-Tool');
      }
    });

    test('refuses a rollback copy that is not the app form', () async {
      container(homeAssistantContainerName);
      container('$homeAssistantContainerName-evccpitool-old',
          running: false, config: '/srv/ha');
      expectRefused(await run(purge: true), 'nicht von Pi-Tool');
    });

    test('refuses when the Docker daemon does not answer', () async {
      appInstall();
      File('$root/state/down').writeAsStringSync('');
      expectRefused(await run(purge: true), 'Docker');
    });
  }, skip: _bash == null ? 'needs bash (Git Bash on Windows)' : false);
}
