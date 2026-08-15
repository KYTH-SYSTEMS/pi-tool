import 'dart:convert';

import 'package:evcc_updater/src/services/stack_wiring.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
