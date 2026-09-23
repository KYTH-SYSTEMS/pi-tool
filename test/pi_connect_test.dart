import 'dart:convert';
import 'dart:io';

import 'package:evcc_updater/src/commands.dart' show shSingleQuote;
import 'package:evcc_updater/src/services/pi_connect.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shell for the real-bash group: `bash` on Linux/macOS (CI). On Windows
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
  group('isPiConnectCompatible (Bookworm+ = Debian 12+)', () {
    test('bookworm (12) and trixie (13) are compatible', () {
      expect(isPiConnectCompatible('PRETTY_NAME="Debian 12"\nVERSION_ID="12"'),
          isTrue);
      expect(isPiConnectCompatible('VERSION_ID="13"'), isTrue);
    });
    test('bullseye (11) and older are NOT compatible', () {
      expect(isPiConnectCompatible('VERSION_ID="11"'), isFalse);
      expect(isPiConnectCompatible('VERSION_ID="10"'), isFalse);
    });
    test('unknown / missing version → not compatible (fail-safe)', () {
      expect(isPiConnectCompatible(''), isFalse);
      expect(isPiConnectCompatible('PRETTY_NAME="Something"'), isFalse);
    });
  });

  group('commands set the user dbus env for over-SSH use', () {
    test('every rpi-connect command exports XDG_RUNTIME_DIR', () {
      for (final c in [
        piConnectStatusCommand,
        piConnectOnCommand,
        piConnectOffCommand,
        piConnectSigninCommand,
        piConnectSignoutCommand,
      ]) {
        expect(c, contains('XDG_RUNTIME_DIR=/run/user/'));
        expect(c, contains('rpi-connect'));
      }
    });
    test('install script installs lite + enables linger (headless)', () {
      expect(piConnectInstallScript, contains('rpi-connect-lite'));
      expect(piConnectInstallScript, contains('enable-linger'));
      expect(piConnectInstallScript, contains('PICONNECT_INSTALLED'));
    });
  });

  group('piConnectInstallScript (linger provenance)', () {
    const s = piConnectInstallScript;

    test('marker path lives in the app state dir', () {
      expect(piConnectLingerMarker, '/var/lib/pi-tool/piconnect-linger');
    });

    test('records linger only when it was off and enabling it worked', () {
      final wasOff = s.indexOf(r'[ ! -e "/var/lib/systemd/linger/$u" ]');
      final enable = s.indexOf(r'if loginctl enable-linger "$u"');
      final record = s.indexOf('>> $piConnectLingerMarker');
      expect(wasOff, greaterThan(-1));
      expect(enable, greaterThan(wasOff));
      expect(record, greaterThan(enable));
      // One line per user, never duplicated on a reinstall.
      expect(s, contains(r'grep -qsxF -- "$u" ' '$piConnectLingerMarker'));
    });

    test('an empty SUDO_USER plus a failing logname no longer aborts', () {
      expect(s, contains('logname 2>/dev/null || true'));
      expect(s, isNot(contains(r'[ -z "$u" ] && u=')));
    });

    test('apt never reads the rest of the script from stdin', () {
      final apt = _code(s).where((l) => l.contains('apt-get '));
      expect(apt, isNotEmpty);
      for (final l in apt) {
        expect(l, endsWith('</dev/null'), reason: l);
      }
      expect(s, contains('DPkg::Lock::Timeout=120'));
    });

    test('marker is still the last line', () {
      expect(s.trimRight().split('\n').last, 'echo PICONNECT_INSTALLED');
    });
  });

  group('buildPiConnectUninstallScript', () {
    final keep = buildPiConnectUninstallScript(user: 'pi', purge: false);
    final purge = buildPiConnectUninstallScript(user: 'pi', purge: true);

    test('marker does not overlap with the install marker', () {
      expect(piConnectRemovedMarker, 'PICONNECT_REMOVED_OK');
      expect(piConnectRemovedMarker, isNot(contains('INSTALL')));
    });

    test('rejects anything but a plain user name', () {
      for (final bad in [
        '',
        'pi; rm -rf /',
        "pi'x",
        r'$(id)',
        '`id`',
        'a b',
        '-rf',
        '.hidden',
        'pi\nx',
        'x' * 33,
      ]) {
        expect(() => buildPiConnectUninstallScript(user: bad, purge: false),
            throwsArgumentError,
            reason: bad);
      }
      for (final ok in ['pi', 'stefan', 'user_1', 'my-user', 'Admin.2']) {
        expect(buildPiConnectUninstallScript(user: ok, purge: true),
            contains("u='$ok'\n"));
      }
    });

    for (final (name, s) in [('keep', keep), ('purge', purge)]) {
      group('both modes: $name', () {
        test('root script header: set -e, noninteractive, C locale', () {
          expect(s.split('\n').first, 'set -e');
          expect(s, contains('export DEBIAN_FRONTEND=noninteractive LC_ALL=C'));
          expect(s, contains("u='pi'\n"));
        });

        test('never cuts off its own stdin (script arrives via bash -s)', () {
          expect(s, isNot(contains('exec <')));
          expect(RegExp(r'(^|[;&|{]\s*)exec\b', multiLine: true).hasMatch(s),
              isFalse);
        });

        test('every apt-get call waits for the lock, no pty, own stdin', () {
          final apt = _code(s).where((l) => l.contains('apt-get '));
          expect(apt.length, greaterThanOrEqualTo(2)); // simulation + real run
          for (final l in apt) {
            expect(l, contains('-o DPkg::Lock::Timeout=120'), reason: l);
            expect(l, contains('-o Dpkg::Use-Pty=0'), reason: l);
            expect(l, contains('</dev/null'), reason: l);
          }
        });

        test('user-side commands run as the user with their own stdin', () {
          expect(
              RegExp(r'run_as\(\) \{[^}]*runuser -u "\$ru" --[^}]*'
                      r'XDG_RUNTIME_DIR="/run/user/\$ruid"[^}]*timeout \d+'
                      r'[^}]*</dev/null[^}]*\}')
                  .hasMatch(s),
              isTrue);
          expect(s, contains(r'as_user() { run_as "$u" "$uid" "$@"; }'));
          // loginctl calls, not the hint that names the command.
          for (final l in _code(s).where((l) =>
              l.contains('loginctl ') && !l.trimLeft().startsWith('echo '))) {
            expect(l, contains('</dev/null'), reason: l);
          }
        });

        test('no autoremove, no shared packages, no OS apt source', () {
          expect(s, isNot(contains('autoremove')));
          for (final shared in [
            'dbus-user-session',
            'curl',
            'gnupg',
            'ca-certificates',
            'keyring',
            'docker',
            'sources.list',
            'raspi.list',
            'raspi.sources',
          ]) {
            expect(s, isNot(contains(shared)), reason: shared);
          }
        });

        test('no unquoted heredoc', () {
          expect(RegExp(r'<<-?\s*[A-Za-z_]').hasMatch(s), isFalse);
        });

        test('handles the lite and the full (OS-preinstalled) package', () {
          expect(s, contains('for p in rpi-connect-lite rpi-connect; do'));
          expect(s, contains(r"dpkg-query -W -f='${db:Status-Status}'"));
        });

        test('refusal is one German line and exit 3', () {
          expect(s, contains(r'refuse() { echo "UNINSTALL_REFUSED: $*"; exit 3; }'));
          // Held package, foreign binary, unowned binary, apt collateral.
          expect(s, contains('apt-mark hold'));
          expect(s, contains('stammt nicht aus dem Paket'));
          expect(s, contains('gehört zu keinem installierten Paket'));
          expect(s, contains('apt würde zusätzlich entfernen'));
          expect(s, contains(r'awk ' "'" r'/^(Remv|Purg) /'));
        });

        test('all guards run before the first change', () {
          final code = _code(s).join('\n');
          final lastGuard = code.lastIndexOf('refuse "');
          expect(lastGuard, greaterThan(-1));
          for (final change in [
            'pkill ',
            'systemctl --user stop',
            'apt-get -o',
            'rm -',
            'find ',
            'loginctl ',
            'signout',
          ]) {
            final i = code.indexOf(change);
            if (i == -1) continue;
            expect(i, greaterThan(lastGuard), reason: change);
          }
          // The apt simulation is a guard, the real run is not.
          expect(code.indexOf('apt-get -s '), lessThan(lastGuard));
        });

        test('stops the user units before apt touches the package', () {
          final stop = s.indexOf("as_user systemctl --user stop 'rpi-connect*'");
          expect(stop, greaterThan(-1));
          expect(stop, lessThan(s.indexOf('apt-get -o')));
          // The detached sign-in poller the app may have started.
          expect(s.indexOf('pkill -x rpi-connect '), lessThan(stop));
        });

        test('remembers the running units before it stops them', () {
          final record = s.indexOf(
              r"was_active=" r'"$(as_user systemctl --user list-units '
              r"--state=active --no-legend --plain 'rpi-connect*'");
          expect(record, greaterThan(-1));
          expect(record,
              lessThan(s.indexOf("as_user systemctl --user stop 'rpi-connect*'")));
        });

        test('apt failing restarts the remembered units, exit 1, no marker', () {
          final apt = s.indexOf(r'  if ! apt-get -o');
          final restart =
              s.indexOf(r'as_user systemctl --user start $was_active');
          final fail = s.indexOf('    exit 1', restart);
          expect(apt, greaterThan(-1));
          expect(restart, greaterThan(apt));
          expect(fail, greaterThan(restart));
          expect(fail, lessThan(s.indexOf('echo $piConnectRemovedMarker')));
          expect(s.substring(apt, fail), contains('apt konnte'));
          // Only what ran before comes back, not the whole unit family.
          expect(s.substring(apt, fail), isNot(contains("start 'rpi-connect*'")));
        });

        test('proves the daemon is gone (pkill fallback) before the marker', () {
          final marker = s.indexOf('echo $piConnectRemovedMarker');
          final kill = s.indexOf('pkill -KILL -x rpi-connectd');
          final lastCheck = s.lastIndexOf('pgrep -x rpi-connectd');
          expect(kill, greaterThan(s.indexOf('apt-get -o')));
          expect(lastCheck, greaterThan(kill));
          expect(marker, greaterThan(lastCheck));
        });

        test('verifies binary + package state before the marker', () {
          final marker = s.indexOf('echo $piConnectRemovedMarker');
          expect(s.lastIndexOf('command -v rpi-connect'), lessThan(marker));
          expect(s.lastIndexOf(r'for f in "${bins[@]}"'), lessThan(marker));
          expect(s.lastIndexOf('pkg_state'), lessThan(marker));
          expect(s.lastIndexOf('pkg_state'),
              greaterThan(s.indexOf('apt-get -o')));
        });

        test('marker is the last line and appears once', () {
          expect(s.trimRight().split('\n').last, 'echo $piConnectRemovedMarker');
          expect(piConnectRemovedMarker.allMatches(s).length, 1);
        });

        test('cleans up the app-made sign-in log', () {
          expect(s, contains('rm -f /tmp/pi-tool-signin'));
        });
      });
    }

    group('keep (default): program goes, sign-in + settings stay', () {
      test('removes, never purges', () {
        expect(keep, contains(r'remove -y $todo </dev/null'));
        expect(keep, isNot(contains('purge')));
        expect(keep, contains(r'todo="$active"' '\n'));
      });

      test('a package already in rc counts as gone (idempotent retry)', () {
        expect(keep, contains('config-files) leftover='));
        expect(keep, contains('""|not-installed|config-files) ;;'));
      });

      test('no sign-out, no state deletion, linger untouched', () {
        expect(keep, isNot(contains('signout')));
        expect(keep, isNot(contains('rm -rf')));
        expect(keep, isNot(contains('com.raspberrypi.connect')));
        expect(keep, isNot(contains('disable-linger')));
        expect(keep, isNot(contains(piConnectLingerMarker)));
        expect(keep, isNot(contains('find ')));
      });
    });

    group('purge: complete rollback', () {
      test('purges active and rc leftovers', () {
        expect(purge, contains(r'purge -y $todo </dev/null'));
        expect(purge, contains(r'todo="$active$leftover"'));
        expect(purge, isNot(contains('remove -y')));
      });

      test('only a gone / not-installed package counts as done', () {
        expect(purge, contains('""|not-installed) ;;'));
        expect(purge, isNot(contains('""|not-installed|config-files) ;;')));
      });

      test('signs out as the user first, best effort', () {
        final signout = purge.indexOf('as_user rpi-connect signout');
        expect(signout, greaterThan(-1));
        expect(signout,
            lessThan(purge.indexOf("as_user systemctl --user stop")));
        expect(signout, lessThan(purge.indexOf('apt-get -o')));
        expect(purge, contains('Abmelden bei Pi Connect nicht möglich'));
      });

      test('home is checked before anything is deleted', () {
        final guard = purge.indexOf(r'case "$home" in /?*) ;;');
        expect(guard, greaterThan(-1));
        expect(guard, lessThan(purge.indexOf('rm -rf')));
        expect(purge,
            contains(r'rm -rf -- "$home/.config/com.raspberrypi.connect"'));
      });

      test('removes only rpi-connect autostart links, incl. Imager ones', () {
        expect(
            purge,
            contains(r'find "$home/.config/systemd/user" -mindepth 2 '
                r"-maxdepth 2 -type l -path '*.wants/rpi-connect*' -delete"));
      });

      test('removes the app-made config backups of this service only', () {
        final backups = _code(purge)
            .where((l) => l.contains('/var/backups/pi-tool'))
            .toList();
        expect(backups,
            ['rm -f -- /var/backups/pi-tool/config-wayvnc.config-*.bak']);
      });

      test('linger goes off only when the app switched it on', () {
        final check = purge.indexOf('[ -f "\$m" ]');
        final off = purge.indexOf('loginctl disable-linger');
        expect(purge, contains('m=$piConnectLingerMarker\n'));
        expect(check, greaterThan(-1));
        expect(off, greaterThan(check));
        expect(purge, contains(r'rm -f "$m"'));
        // Names from the marker are validated before loginctl sees them.
        expect(purge, contains(r"''|-*|*[!A-Za-z0-9._-]*) continue ;;"));
      });

      test('linger stays while the user manager runs more than Pi Connect', () {
        final inUse = purge.indexOf(r'if linger_in_use "$lu"; then');
        final hint = purge.indexOf(r'Hinweis: Linger für $lu bleibt');
        final off = purge.indexOf('loginctl disable-linger');
        expect(inUse, greaterThan(-1));
        expect(hint, greaterThan(inUse));
        expect(off, greaterThan(hint));
        // Autostart links of the user's own and running units count.
        expect(purge,
            contains(r"-path '*.wants/*' ! -name 'rpi-connect*'"));
        expect(purge,
            contains('list-units --type=service,timer --state=active'));
        // The marker goes either way: Pi-Tool no longer owns that linger.
        expect(purge.lastIndexOf(r'rm -f "$m"'), greaterThan(off));
      });

      test('an apt failure after the sign-out says so', () {
        final fail = purge.indexOf(r'  if ! apt-get -o');
        expect(purge.indexOf('signed_out=1'), lessThan(fail));
        expect(purge.indexOf('Pi Connect ist abgemeldet', fail),
            greaterThan(fail));
      });

      test('says where the device record still lives', () {
        expect(purge, contains('connect.raspberrypi.com'));
      });
    });
  });

  group('buildPiConnectUninstallScript in bash', () {
    late Directory tmp;
    late String root; // tmp as bash's `readlink -f` spells it
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

    void pkg(String name, String status) {
      write('state/status/$name', '$status\n');
      write('state/want/$name', 'install\n');
    }

    String status(String name) =>
        exists('state/status/$name') ? read('state/status/$name').trim() : '';
    String log() => exists('state/log') ? read('state/log') : '';

    /// A unit in [user]'s systemd manager; [frag] is where its file lives.
    void unit(String name, String active, {String user = 'pi', String? frag}) {
      write('state/user/$user/active.$name', '$active\n');
      if (frag != null) write('state/user/$user/frag.$name', '$frag\n');
    }

    String unitState(String name, {String user = 'pi'}) =>
        read('state/user/$user/active.$name').trim();

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('piconnect');
      // readlink -f must see the same prefix the script is rewritten to.
      root = (Process.runSync(
                  _bash!, ['-c', r'readlink -f "$1"', '_', _posix(tmp.path)])
              .stdout as String)
          .trim();
      state = '$root/state';
      write('state/passwd', 'pi:x:1000:1000::$root/home/pi:/bin/bash\n'
          'bob:x:1001:1001::$root/home/bob:/bin/bash\n');
      Directory('${tmp.path}/run/user/1000').createSync(recursive: true);
      Directory('${tmp.path}/run/user/1001').createSync(recursive: true);
      write('bin/getent', r'''#!/bin/bash
[ "$1" = passwd ] && grep -m1 "^$2:" "$STUB/passwd"
''');
      write('bin/runuser', r'''#!/bin/bash
echo "runuser $*" >> "$STUB/log"
while [ "$#" -gt 0 ]; do
  case "$1" in -u) STUB_USER=$2; shift 2 ;; --) shift; break ;; *) shift ;; esac
done
export STUB_USER
exec "$@"
''');
      write('bin/timeout', '#!/bin/bash\nshift\nexec "\$@"\n');
      write('bin/sleep', '#!/bin/sh\nexit 0\n');
      write('bin/pgrep', '#!/bin/bash\n[ -f "\$STUB/daemon" ]\n');
      write('bin/pkill', r'''#!/bin/bash
echo "pkill $*" >> "$STUB/log"
case "$*" in *rpi-connectd*) rm -f "$STUB/daemon" ;; esac
exit 0
''');
      write('bin/loginctl', r'''#!/bin/bash
echo "loginctl $*" >> "$STUB/log"
case "$1" in disable-linger) rm -f "$STUB/linger.$2" ;; esac
''');
      write('bin/dpkg-query', r'''#!/bin/bash
for a; do p=$a; done
case "$*" in *Status-Want*) d=want ;; *) d=status ;; esac
[ -f "$STUB/status/$p" ] || { echo "dpkg-query: no packages found matching $p" >&2; exit 1; }
cat "$STUB/$d/$p"
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
  exit 0
fi
if [ -f "$STUB/apt_fail" ]; then
  echo "E: Could not get lock /var/lib/dpkg/lock-frontend" >&2; exit 100
fi
for p in "${pkgs[@]}"; do
  if [ "$verb" = purge ]; then echo not-installed > "$STUB/status/$p"
  else echo config-files > "$STUB/status/$p"; fi
done
rm -f "$ROOT/usr/bin/rpi-connect"
''');
      // Only the user manager (`systemctl --user`) is ever asked.
      write('bin/systemctl', r'''#!/bin/bash
echo "systemctl $* [$STUB_USER]" >> "$STUB/log"
[ "$1" = --user ] || exit 1
shift
d="$STUB/user/$STUB_USER"
cmd=$1; shift
case "$cmd" in
  stop)
    for pat; do
      for f in "$d"/active.$pat; do [ -f "$f" ] && echo inactive > "$f"; done
    done ;;
  start)
    [ -f "$STUB/start_fail" ] && exit 1
    for u; do echo active > "$d/active.$u"; done ;;
  list-units)
    [ -f "$STUB/list_fail" ] && { echo "Failed to connect to bus" >&2; exit 1; }
    types=""; pats=()
    for a; do
      case "$a" in --type=*) types=${a#--type=} ;; --*) ;; *) pats+=("$a") ;; esac
    done
    for f in "$d"/active.*; do
      [ -f "$f" ] && [ "$(cat "$f")" = active ] || continue
      u=${f##*/active.}
      if [ -n "$types" ]; then
        ok=0; for t in ${types//,/ }; do case "$u" in *."$t") ok=1 ;; esac; done
        [ "$ok" = 1 ] || continue
      fi
      if [ "${#pats[@]}" -gt 0 ]; then
        ok=0; for p in "${pats[@]}"; do case "$u" in $p) ok=1 ;; esac; done
        [ "$ok" = 1 ] || continue
      fi
      echo "$u loaded active running $u"
    done ;;
  show)
    for u; do :; done
    cat "$d/frag.$u" 2>/dev/null || echo "/usr/lib/systemd/user/$u" ;;
esac
''');
      write('usr/bin/rpi-connect', r'''#!/bin/bash
echo "rpi-connect $*" >> "$STUB/log"
''');
      for (final b in [
        'getent',
        'runuser',
        'timeout',
        'sleep',
        'pgrep',
        'pkill',
        'loginctl',
        'dpkg-query',
        'apt-get',
        'systemctl',
      ]) {
        if (!Platform.isWindows) {
          Process.runSync('chmod', ['+x', '${tmp.path}/bin/$b']);
        }
      }
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['+x', '${tmp.path}/usr/bin/rpi-connect']);
      }
      // A Pi on which the app installed Pi Connect and switched linger on.
      pkg('rpi-connect-lite', 'installed');
      unit('rpi-connect.service', 'active');
      unit('rpi-connect-wayvnc.service', 'active');
      unit('rpi-connect-wayvnc-watcher.path', 'inactive');
      unit('dbus.service', 'active');
      unit('systemd-tmpfiles-clean.timer', 'active');
      write('state/linger.pi', '');
      write('var/lib/pi-tool/piconnect-linger', 'pi\n');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    /// Builds the script, points it into the sandbox and runs it.
    Future<({int code, String out, String all})> run({required bool purge}) {
      final script = buildPiConnectUninstallScript(user: 'pi', purge: purge)
          .replaceAllMapped(
              RegExp(r'''(^|[\s'"=(])/(var|run|usr/local|usr/sbin|usr/bin|'''
                  r'''sbin|bin|snap|tmp)/''', multiLine: true),
              (m) => '${m[1]}$root/${m[2]}/');
      return _runBash('export PATH=${shSingleQuote('$root/bin')}:'
          '${shSingleQuote('$root/usr/bin')}:"\$PATH"\n'
          'export STUB=${shSingleQuote(state)} ROOT=${shSingleQuote(root)}\n'
          '$script');
    }

    String last(String out) => out.trimRight().split('\n').last;

    test('keep: package goes to rc, marker last, linger untouched', () async {
      final r = await run(purge: false);
      expect(r.code, 0, reason: r.all);
      expect(last(r.out), piConnectRemovedMarker);
      expect(status('rpi-connect-lite'), 'config-files');
      expect(log(), isNot(contains('loginctl')));
      expect(exists('state/linger.pi'), isTrue);
    });

    for (final purge in [false, true]) {
      test('apt failing (lock, ${purge ? 'purge' : 'keep'}): the stopped '
          'units run again, exit 1, no marker', () async {
        write('state/apt_fail', '');
        final r = await run(purge: purge);
        expect(r.code, 1, reason: r.all);
        expect(r.out, isNot(contains(piConnectRemovedMarker)));
        expect(r.all, contains('apt konnte rpi-connect-lite nicht entfernen'));
        expect(r.all, contains('Pi Connect läuft wieder.'));
        expect(unitState('rpi-connect.service'), 'active');
        expect(unitState('rpi-connect-wayvnc.service'), 'active');
        // Only what ran before comes back.
        expect(unitState('rpi-connect-wayvnc-watcher.path'), 'inactive');
        expect(status('rpi-connect-lite'), 'installed');
        expect(exists('state/linger.pi'), isTrue);
        expect(r.all.contains('Pi Connect ist abgemeldet'), purge);
      });
    }

    test('apt failing and the restart failing too: says so', () async {
      write('state/apt_fail', '');
      write('state/start_fail', '');
      final r = await run(purge: false);
      expect(r.code, 1, reason: r.all);
      expect(r.all, contains('Pi Connect ließ sich nicht wieder starten'));
      expect(r.all, isNot(contains('Pi Connect läuft wieder.')));
    });

    test('purge: linger off when only Pi Connect and OS units used it',
        () async {
      final r = await run(purge: true);
      expect(r.code, 0, reason: r.all);
      expect(last(r.out), piConnectRemovedMarker);
      expect(status('rpi-connect-lite'), 'not-installed');
      expect(log(), contains('loginctl disable-linger pi'));
      expect(exists('state/linger.pi'), isFalse);
      expect(exists('var/lib/pi-tool/piconnect-linger'), isFalse);
      expect(r.out, contains('Linger für pi ausgeschaltet'));
      expect(r.out, isNot(contains('Hinweis')));
    });

    test('purge: linger stays while the user has another autostart link',
        () async {
      write('home/pi/.config/systemd/user/default.target.wants/docker.service',
          '');
      final r = await run(purge: true);
      expect(r.code, 0, reason: r.all);
      expect(last(r.out), piConnectRemovedMarker);
      expect(log(), isNot(contains('disable-linger')));
      expect(exists('state/linger.pi'), isTrue);
      expect(r.out, contains('Hinweis: Linger für pi bleibt eingeschaltet'));
      expect(r.out, contains('sudo loginctl disable-linger pi'));
      // Pi-Tool no longer owns it: the marker goes anyway.
      expect(exists('var/lib/pi-tool/piconnect-linger'), isFalse);
    });

    test('purge: linger stays while a unit of the user\'s own runs',
        () async {
      unit('app.service', 'active',
          frag: '/run/user/1000/systemd/generator/app.service');
      final r = await run(purge: true);
      expect(r.code, 0, reason: r.all);
      expect(log(), isNot(contains('disable-linger')));
      expect(exists('state/linger.pi'), isTrue);
      expect(r.out, contains('Hinweis: Linger für pi bleibt eingeschaltet'));
      expect(r.out, contains('app.service'));
      expect(exists('var/lib/pi-tool/piconnect-linger'), isFalse);
    });

    test('purge: linger stays when the user manager cannot be asked',
        () async {
      write('state/list_fail', '');
      final r = await run(purge: true);
      expect(r.code, 0, reason: r.all);
      expect(log(), isNot(contains('disable-linger')));
      expect(r.out, contains('Hinweis: Linger für pi bleibt eingeschaltet'));
    });

    test('purge: each marker user is checked on their own', () async {
      write('var/lib/pi-tool/piconnect-linger', 'pi\nbob\n');
      write('state/linger.bob', '');
      write('home/bob/.config/systemd/user/timers.target.wants/backup.timer',
          '');
      final r = await run(purge: true);
      expect(r.code, 0, reason: r.all);
      expect(log(), contains('loginctl disable-linger pi'));
      expect(log(), isNot(contains('disable-linger bob')));
      expect(exists('state/linger.bob'), isTrue);
      expect(r.out, contains('Hinweis: Linger für bob bleibt eingeschaltet'));
    });
  }, skip: _bash == null ? 'needs bash (PITOOL_TEST_BASH on Windows)' : false);

  group('parseSigninUrl', () {
    test('extracts the verify URL from signin output', () {
      const out = 'Complete sign in by visiting '
          'https://connect.raspberrypi.com/verify/ABCD-1234\n';
      expect(parseSigninUrl(out), 'https://connect.raspberrypi.com/verify/ABCD-1234');
    });
    test('null when there is no URL', () {
      expect(parseSigninUrl('some error'), isNull);
    });
  });

  group('parsePiConnectStatus', () {
    test('not installed when the CLI is missing', () {
      final s = parsePiConnectStatus('rpi-connect: command not found');
      expect(s.installed, isFalse);
    });
    test('installed + signed in + on', () {
      final s = parsePiConnectStatus(
          'Signed in: yes\nScreen sharing: on\nRemote shell: on');
      expect(s.installed, isTrue);
      expect(s.signedIn, isTrue);
      expect(s.on, isTrue);
    });
    test('installed but not signed in', () {
      final s = parsePiConnectStatus('Signed in: no');
      expect(s.installed, isTrue);
      expect(s.signedIn, isFalse);
    });
  });
}

/// Script lines without comments, for ordering and per-line checks.
List<String> _code(String script) => [
      for (final l in script.split('\n'))
        if (!l.trimLeft().startsWith('#')) l,
    ];
