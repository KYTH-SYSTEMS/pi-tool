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
  });
}
