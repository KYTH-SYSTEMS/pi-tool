import 'package:evcc_updater/src/commands.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildConsoleExec', () {
    test('a plain command runs as-is, no password needed', () {
      final r = buildConsoleExec('df -h');
      expect(r.exec, 'df -h');
      expect(r.sudo, isFalse);
    });

    test('leading sudo → -S -p so the password is read from stdin', () {
      final r = buildConsoleExec('sudo apt-get update');
      expect(r.sudo, isTrue);
      expect(r.exec, "sudo -S -p '' apt-get update");
    });

    test('trims and collapses spacing after sudo', () {
      final r = buildConsoleExec('  sudo   systemctl restart evcc  ');
      expect(r.sudo, isTrue);
      expect(r.exec, "sudo -S -p '' systemctl restart evcc");
    });

    test('sudo not at the very start is a normal command', () {
      final r = buildConsoleExec('echo sudo rules');
      expect(r.sudo, isFalse);
      expect(r.exec, 'echo sudo rules');
    });

    test('bare "sudo" is still treated as sudo (empty remainder)', () {
      final r = buildConsoleExec('sudo');
      expect(r.sudo, isTrue);
      expect(r.exec, "sudo -S -p ''");
    });
  });

  group('buildDetectBatch / splitDetectSections', () {
    test('batch script marks + runs each probe (failures swallowed)', () {
      final script = buildDetectBatch([
        ('DOCKER', 'docker ps'),
        ('OS', 'cat /etc/os-release'),
      ]);
      expect(script, contains('@@PT@@DOCKER@@PT@@'));
      expect(script, contains('{ docker ps ; } 2>&1 || true'));
      expect(script, contains('@@PT@@OS@@PT@@'));
    });

    test('split parses each section back out, trimmed', () {
      const output = '@@PT@@DOCKER@@PT@@\n'
          'evcc|ghcr.io/evcc\n'
          '@@PT@@OS@@PT@@\n'
          'PRETTY_NAME="Debian 12"\n';
      final sec = splitDetectSections(output);
      expect(sec['DOCKER'], 'evcc|ghcr.io/evcc');
      expect(sec['OS'], 'PRETTY_NAME="Debian 12"');
    });

    test('round-trips: split(run(build)) recovers each probe output', () {
      // Simulate the shell running the built script: echo blank, echo marker,
      // then the command output.
      final probes = [('A', 'x'), ('B', 'y')];
      buildDetectBatch(probes); // (structure asserted above)
      const simulated = '\n@@PT@@A@@PT@@\naaa\n\n@@PT@@B@@PT@@\nbbb line2\n';
      final sec = splitDetectSections(simulated);
      expect(sec['A'], 'aaa');
      expect(sec['B'], 'bbb line2');
    });

    test('missing/empty section → empty string, not null lookup surprise', () {
      final sec = splitDetectSections('@@PT@@A@@PT@@\n');
      expect(sec['A'], '');
      expect(sec['NOPE'], isNull);
    });
  });

  group('config read/write', () {
    test('read cats the path as root, shell-quoted', () {
      expect(buildConfigReadCommand('/etc/evcc.yaml'),
          "sudo -S -p '' cat '/etc/evcc.yaml'");
      final bad = buildConfigReadCommand("/etc/x';reboot;'");
      expect(bad, contains(r"'\''"));
    });

    test('write backs up then base64-decodes the new content into place', () {
      final s = buildConfigWriteScript(
          path: '/etc/evcc.yaml', base64Content: 'aGkK');
      expect(s, contains('/var/backups/pi-tool')); // backup first
      expect(s, contains("cp '/etc/evcc.yaml'"));
      expect(s, contains("printf '%s' 'aGkK' | base64 -d > '/etc/evcc.yaml'"));
      expect(s, contains('CONFIG_SAVED'));
    });

    test('a hostile path cannot break out of the write script', () {
      final s = buildConfigWriteScript(
          path: "/etc/x';reboot;'", base64Content: 'aGkK');
      expect(s, contains(r"'\''"));
      expect(s, isNot(contains("> /etc/x';reboot")));
    });
  });

  group('buildServiceLogsCommand', () {
    test('apt/systemd service → journalctl -u <unit>', () {
      final r = buildServiceLogsCommand(id: 'evcc', detail: 'apt · aktiv');
      expect(r.command, contains('journalctl -u evcc'));
      expect(r.sudo, isTrue);
    });
    test('maps pihole → pihole-FTL and grafana → grafana-server', () {
      expect(buildServiceLogsCommand(id: 'pihole', detail: 'apt').command,
          contains('journalctl -u pihole-FTL'));
      expect(buildServiceLogsCommand(id: 'grafana', detail: 'apt').command,
          contains('journalctl -u grafana-server'));
    });
    test('System card → the whole journal', () {
      final r = buildServiceLogsCommand(id: 'system', detail: '');
      expect(r.command, contains('journalctl -n 200'));
      expect(r.command, isNot(contains('-u ')));
    });
    test('Docker service → docker logs <name> with a sudo fallback', () {
      final r = buildServiceLogsCommand(
          id: 'homeassistant', detail: 'Docker · homeassistant');
      expect(r.command, contains("docker logs --tail 200 'homeassistant'"));
      expect(r.command, contains('|| '));
      expect(r.sudo, isTrue);
    });
    test('quotes a hostile container name', () {
      final r =
          buildServiceLogsCommand(id: 'evcc', detail: "Docker · x';reboot;'");
      expect(r.command, contains(r"'\''"));
      expect(r.command, isNot(contains("logs --tail 200 x';reboot")));
    });
  });
}
