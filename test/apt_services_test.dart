import 'package:evcc_updater/src/services/apt_services.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test('grafana install adds the official apt repo and enables the unit', () {
      final s = knownAptServices.firstWhere((s) => s.id == 'grafana');
      expect(s.installScript, contains('apt.grafana.com'));
      expect(s.installScript, contains('apt-get install -y grafana'));
      expect(s.installScript, contains('grafana-server'));
    });

    test('influxdb install adds the influxdata repo and installs v2', () {
      final s = knownAptServices.firstWhere((s) => s.id == 'influxdb');
      expect(s.installScript, contains('repos.influxdata.com'));
      expect(s.installScript, contains('influxdb2'));
      expect(s.installScript, contains('systemctl enable --now influxdb'));
    });

    test('mosquitto install is a plain apt install of the broker', () {
      final s = knownAptServices.firstWhere((s) => s.id == 'mosquitto');
      expect(s.installScript, contains('apt-get install -y mosquitto'));
      expect(s.installScript, contains('systemctl enable --now mosquitto'));
    });
  });
}
