import 'package:evcc_updater/src/docker_containers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseDockerPs', () {
    test('parses name|state|status|image lines', () {
      const out = 'evcc|running|Up 2 hours (healthy)|evcc/evcc:latest\n'
          'pihole|exited|Exited (0) 3 days ago|pihole/pihole:latest\n';
      final r = parseDockerPs(out);
      expect(r, hasLength(2));
      expect(r[0].name, 'evcc');
      expect(r[0].state, 'running');
      expect(r[0].status, contains('Up 2 hours'));
      expect(r[0].image, 'evcc/evcc:latest');
      expect(r[1].state, 'exited');
    });

    test('keeps colons in the image (rejoins split tail)', () {
      final r = parseDockerPs('x|running|Up|registry:5000/app:v1');
      expect(r.single.image, 'registry:5000/app:v1');
    });

    test('garbled / error output yields no containers', () {
      expect(parseDockerPs('Cannot connect to the Docker daemon'), isEmpty);
      expect(parseDockerPs(''), isEmpty);
    });
  });

  group('commands', () {
    test('ps command uses the pipe format; sudo variant exists', () {
      expect(dockerPsSudoCommand, contains('docker ps'));
      expect(dockerPsSudoCommand, contains('{{.Names}}'));
      expect(dockerPsSudoCommand, startsWith('LC_ALL=C sudo -S'));
    });

    test('restart + logs single-quote the container name', () {
      expect(buildDockerRestartCommand("x';reboot;'"), contains(r"'\''"));
      expect(buildDockerLogsCommand("x';reboot;'"), contains(r"'\''"));
      expect(buildDockerLogsCommand('evcc'), contains('logs --tail'));
    });

    test('running probe single-quotes the name and asks the State', () {
      expect(buildDockerRunningProbe('grafana'),
          contains('{{.State.Running}}'));
      expect(buildDockerRunningProbe("x';reboot;'"), contains(r"'\''"));
      expect(buildDockerRunningProbe('grafana'), startsWith('LC_ALL=C sudo -S'));
    });
  });
}
