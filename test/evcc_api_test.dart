import 'package:evcc_updater/src/evcc_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseEvccState', () {
    test('reads the legacy result-wrapped shape', () {
      final state = parseEvccState({
        'result': {
          'version': '0.123.1',
          'siteTitle': 'Zuhause',
          'gridPower': 1234.0,
          'homePower': 800,
          'pvPower': 2500.5,
          'batteryConfigured': true,
          'batterySoc': 87,
          'batteryPower': -300,
          'loadpoints': [
            {
              'title': 'Garage',
              'charging': true,
              'chargePower': 11000,
              'vehicleSoc': 62,
              'connected': true,
              'mode': 'pv',
            },
          ],
        },
      });

      expect(state.version, '0.123.1');
      expect(state.siteTitle, 'Zuhause');
      expect(state.gridPower, 1234.0);
      expect(state.homePower, 800);
      expect(state.pvPower, 2500.5);
      expect(state.batteryConfigured, true);
      expect(state.batterySoc, 87);
      expect(state.batteryPower, -300);
      expect(state.loadpoints, hasLength(1));
      expect(state.loadpoints.first.title, 'Garage');
      expect(state.loadpoints.first.charging, true);
      expect(state.loadpoints.first.chargePower, 11000);
      expect(state.loadpoints.first.vehicleSoc, 62);
      expect(state.loadpoints.first.mode, 'pv');
    });

    test('reads the new unwrapped shape (no result key)', () {
      final state = parseEvccState({
        'version': '0.200.0',
        'siteTitle': 'Haus',
        'gridPower': 50,
        'loadpoints': [],
      });
      expect(state.version, '0.200.0');
      expect(state.siteTitle, 'Haus');
      expect(state.gridPower, 50);
      expect(state.loadpoints, isEmpty);
    });

    test('tolerates the alternate batterySoC / vehicleSoC casing', () {
      final state = parseEvccState({
        'batterySoC': 41,
        'loadpoints': [
          {'title': 'LP1', 'vehicleSoC': 33},
        ],
      });
      expect(state.batterySoc, 41);
      expect(state.loadpoints.first.vehicleSoc, 33);
    });

    test('is fully defensive about missing / wrong-typed fields', () {
      final state = parseEvccState({'loadpoints': 'not-a-list'});
      expect(state.version, isNull);
      expect(state.siteTitle, isNull);
      expect(state.gridPower, isNull);
      expect(state.batteryConfigured, false);
      expect(state.batterySoc, isNull);
      expect(state.loadpoints, isEmpty);
    });

    test('coerces numbers given as strings', () {
      final state = parseEvccState({'gridPower': '1500'});
      expect(state.gridPower, 1500);
    });
  });

  group('formatPower', () {
    test('null is an em dash', () => expect(formatPower(null), '—'));
    test('below 1 kW shows whole watts', () {
      expect(formatPower(0), '0 W');
      expect(formatPower(350), '350 W');
      expect(formatPower(999), '999 W');
    });
    test('1 kW and above shows kW with a German decimal comma', () {
      expect(formatPower(1000), '1,0 kW');
      expect(formatPower(1500), '1,5 kW');
      expect(formatPower(11000), '11,0 kW');
    });
    test('keeps the sign for feed-in / battery discharge', () {
      expect(formatPower(-2300), '-2,3 kW');
      expect(formatPower(-250), '-250 W');
    });
    test('a value that rounds up to 1000 W is shown as kW, not "1000 W"', () {
      expect(formatPower(999.6), '1,0 kW');
      expect(formatPower(-999.6), '-1,0 kW');
    });
  });

  group('evccCardLines (GitHub issue #22)', () {
    EvccState state({
      num? pv,
      num? grid,
      num? home,
      bool battery = false,
      num? soc,
      List<EvccLoadpoint> lps = const [],
    }) =>
        EvccState(
          version: '0.313.3',
          siteTitle: null,
          gridPower: grid,
          homePower: home,
          pvPower: pv,
          batteryConfigured: battery,
          batterySoc: soc,
          batteryPower: null,
          loadpoints: lps,
        );

    EvccLoadpoint lp({
      String title = 'Ladepunkt',
      bool charging = false,
      bool connected = false,
      num? power,
    }) =>
        EvccLoadpoint(
          title: title,
          charging: charging,
          connected: connected,
          chargePower: power,
          vehicleSoc: null,
          mode: null,
        );

    test('site line lists PV, grid and house', () {
      final lines = evccCardLines(
          state(pv: 3400, grid: -1200, home: 900, lps: [lp(power: 0)]));
      expect(lines.first, 'PV 3,4 kW · Netz -1,2 kW · Haus 900 W');
    });

    test('second line carries battery SoC and the charging loadpoint', () {
      final lines = evccCardLines(state(
        pv: 3400,
        battery: true,
        soc: 78,
        lps: [lp(title: 'Garage', charging: true, connected: true, power: 7200)],
      ));
      expect(lines, hasLength(2));
      expect(lines[1], contains('78 %'));
      expect(lines[1], contains('Garage'));
      expect(lines[1], contains('7,2 kW'));
    });

    test('no battery configured → no battery part, but the loadpoint stays',
        () {
      final lines = evccCardLines(state(
          pv: 100, lps: [lp(charging: true, connected: true, power: 4000)]));
      expect(lines[1], isNot(contains('%')));
      expect(lines[1], contains('4,0 kW'));
    });

    test('connected but not charging is reported as such, not as power', () {
      final lines =
          evccCardLines(state(pv: 100, lps: [lp(connected: true, power: 0)]));
      expect(lines[1], contains('verbunden'));
      expect(lines[1], isNot(contains('kW')));
    });

    test('an idle loadpoint without a battery yields only the site line', () {
      final lines = evccCardLines(state(pv: 100, grid: 50, lps: [lp()]));
      expect(lines, hasLength(1));
    });

    test('a state with nothing measurable yields no lines at all', () {
      // The card must then look exactly as it did before — no empty row.
      expect(evccCardLines(state()), isEmpty);
    });

    test('several loadpoints: the charging one wins, count is shown', () {
      final lines = evccCardLines(state(pv: 1, lps: [
        lp(title: 'A', connected: true),
        lp(title: 'B', charging: true, connected: true, power: 5000),
      ]));
      expect(lines[1], contains('B'));
      expect(lines[1], contains('5,0 kW'));
    });
  });
}
