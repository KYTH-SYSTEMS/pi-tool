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
}
