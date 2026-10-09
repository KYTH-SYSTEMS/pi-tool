import 'dart:io';

import 'package:evcc_updater/src/evcc_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// A loopback server standing in for evcc. [stall] true: it sends the headers
/// and the start of the body, then goes quiet without closing.
Future<HttpServer> _evccServer({required bool stall}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    const body = '{"version":"0.316.2","grid":{"power":120}}';
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..contentLength = body.length
      ..write(stall ? body.substring(0, 12) : body);
    await (stall ? req.response.flush() : req.response.close());
  });
  addTearDown(() => server.close(force: true));
  return server;
}

/// A loopback server that answers every request with [status] and [body]
/// (plus a `Location` header when [location] is given) and adds what was
/// asked to [asked]: `METHOD path`, then the Accept header.
Future<Uri> _evccAnswering(int status, String body,
    {String? location, List<String>? asked}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    asked?.add('${req.method} ${req.uri.path} '
        '${req.headers.value(HttpHeaders.acceptHeader)}');
    req.response.statusCode = status;
    if (location != null) {
      req.response.headers.set(HttpHeaders.locationHeader, location);
    }
    req.response
      ..headers.contentType = ContentType.json
      ..write(body);
    await req.response.close();
  });
  addTearDown(() => server.close(force: true));
  return Uri.parse('http://127.0.0.1:${server.port}/api/state');
}

/// The message [evccGetJson] fails with for [url].
Future<String> _evccFailure(Uri url) async {
  try {
    await evccGetJson(url);
  } on EvccApiException catch (e) {
    return e.message;
  }
  fail('evccGetJson($url) did not throw');
}

void main() {
  group('evccGetJson (HTTP adapter)', () {
    test('reads a complete answer', () async {
      final server = await _evccServer(stall: false);
      final state = await EvccApiClient().fetchState(
          scheme: 'http', host: '127.0.0.1', port: '${server.port}');
      expect(state.version, '0.316.2');
      expect(state.gridPower, 120);
    });

    test('the client asks GET /api/state for JSON, once', () async {
      final asked = <String>[];
      final url =
          await _evccAnswering(200, '{"version":"0.316.2"}', asked: asked);
      final state = await EvccApiClient()
          .fetchState(scheme: 'http', host: '127.0.0.1', port: '${url.port}');
      expect(state.version, '0.316.2');
      expect(asked, ['GET /api/state application/json']);
    });

    test('401 and 403: evcc wants a login', () async {
      for (final status in [401, 403]) {
        expect(await _evccFailure(await _evccAnswering(status, '{}')),
            'evcc verlangt eine Anmeldung – Live-Status nicht abrufbar.',
            reason: '$status');
      }
    });

    test('any other status is named', () async {
      expect(await _evccFailure(await _evccAnswering(500, 'oops')),
          'evcc-API antwortete mit HTTP 500.');
      expect(await _evccFailure(await _evccAnswering(404, '{}')),
          'evcc-API antwortete mit HTTP 404.');
    });

    test('a redirect is not followed', () async {
      // Whatever answers on the port must not send this read elsewhere.
      final elsewhere = <String>[];
      final target =
          await _evccAnswering(200, '{"version":"9.9.9"}', asked: elsewhere);
      final asked = <String>[];
      final url =
          await _evccAnswering(302, '', location: '$target', asked: asked);
      expect(await _evccFailure(url), 'evcc-API antwortete mit HTTP 302.');
      expect(asked, hasLength(1));
      expect(elsewhere, isEmpty);
    });

    test('JSON that is no object is not taken for a state', () async {
      expect(await _evccFailure(await _evccAnswering(200, '[1,2,3]')),
          'Unerwartete Antwort der evcc-API.');
      expect(await _evccFailure(await _evccAnswering(200, '"0.316.2"')),
          'Unerwartete Antwort der evcc-API.');
    });

    test('an answer that is not JSON (another web server on the port)',
        () async {
      expect(
          await _evccFailure(
              await _evccAnswering(200, '<html><body>nginx</body></html>')),
          startsWith('Live-Status fehlgeschlagen: FormatException'));
    });

    test('nothing listens on the port: "nicht erreichbar"', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final url = Uri.parse('http://127.0.0.1:${server.port}/api/state');
      await server.close(force: true);
      expect(await _evccFailure(url),
          'evcc nicht erreichbar – läuft die Oberfläche auf diesem Host/Port?');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a body that stalls mid-way ends in a timeout, not a hang', () async {
      // Headers arrive (so the header limit passes), the body never finishes.
      // Without a limit on the whole request this waited for good.
      final server = await _evccServer(stall: true);
      final sw = Stopwatch()..start();
      await expectLater(
          evccGetJson(Uri.parse('http://127.0.0.1:${server.port}/api/state'),
              timeout: const Duration(milliseconds: 400)),
          throwsA(isA<EvccApiException>().having(
              (e) => e.message, 'message', contains('Zeitüberschreitung'))));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

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

    test('reads flat keys without the result wrapper', () {
      final state = parseEvccState({
        'version': '0.130.0',
        'siteTitle': 'Haus',
        'gridPower': 50,
        'loadpoints': [],
      });
      expect(state.version, '0.130.0');
      expect(state.siteTitle, 'Haus');
      expect(state.gridPower, 50);
      expect(state.loadpoints, isEmpty);
    });

    // The three shapes of grid and battery in /api/state, each derived from
    // evcc's source at that tag (github.com/evcc-io/evcc): core/site.go
    // (site.publish calls), core/keys/site.go (key names), core/types/types.go
    // (JSON field names) and server/http_site_handler.go (stateHandler).
    test('evcc 0.124.0: flat keys inside the result wrapper', () {
      // core/site.go: retryMeter publishes name+"Power" ("gridPower");
      // updateMeters publishes batterySoc, batteryPower and `battery` as the
      // list of device measurements; prepare publishes batteryConfigured.
      // stateHandler answers via jsonResult → {"result": …}.
      final state = parseEvccState({
        'result': {
          'version': '0.124.0',
          'siteTitle': 'Zuhause',
          'gridConfigured': true,
          'gridPower': -1240.5,
          'homePower': 480.2,
          'pvConfigured': true,
          'pvPower': 2100,
          'batteryConfigured': true,
          'batteryCapacity': 10.2,
          'batterySoc': 76,
          'batteryPower': -380,
          'battery': [
            {'power': -380, 'soc': 76, 'capacity': 10.2, 'controllable': false},
          ],
          'loadpoints': [],
        },
      });
      expect(state.gridPower, -1240.5);
      expect(state.homePower, 480.2);
      expect(state.pvPower, 2100);
      expect(state.batteryConfigured, isTrue);
      expect(state.batterySoc, 76);
      expect(state.batteryPower, -380);
    });

    test('evcc 0.133.0–0.300.x: grid nested, battery values still flat', () {
      // 0.133.0 "Align grid measurements structure with pv and battery (BC)":
      // site.publish(keys.Grid, mm) with measurement{power, energy, powers,
      // currents}; the gridPower key is gone. batteryConfigured was removed in
      // 0.125.0 — evcc's own UI then reads `battery?.length > 0`
      // (assets/js/components/Site/Site.vue at 0.207.0).
      final state = parseEvccState({
        'version': '0.207.0',
        'gridConfigured': true,
        'grid': {
          'power': 312.4,
          'energy': 8123.4,
          'powers': [104.1, 104.1, 104.2],
          'currents': [0.5, 0.5, 0.5],
        },
        'homePower': 512.4,
        'pvPower': 0,
        'batteryCapacity': 10.2,
        'batterySoc': 41.5,
        'batteryPower': 200,
        'batteryEnergy': 0,
        'battery': [
          {'power': 200, 'capacity': 10.2, 'soc': 41.5, 'controllable': true},
        ],
        'loadpoints': [],
      });
      expect(state.gridPower, 312.4);
      expect(state.batteryConfigured, isTrue);
      expect(state.batterySoc, 41.5);
      expect(state.batteryPower, 200);
    });

    test('evcc 0.301.0+ (checked up to 0.316.2): grid and battery nested', () {
      // 0.301.0 "Batteries: consolidate measurements api (BC)":
      // site.publish(keys.Battery, battery) with types.BatteryState{power,
      // energy, capacity, soc, devices}; batterySoc / batteryPower are gone
      // from core/keys/site.go. Site.vue: `this.battery?.soc`,
      // `(this.battery?.devices?.length ?? 0) > 0`, `this.grid?.power`.
      final state = parseEvccState({
        'version': '0.316.2',
        'siteTitle': 'Zuhause',
        'gridConfigured': true,
        'grid': {
          'power': -1240.5,
          'energy': 8123.4,
          'returnEnergy': 5120.9,
          'powers': [-413.5, -413.5, -413.5],
          'currents': [-1.8, -1.8, -1.8],
        },
        'homePower': 480.2,
        'pvPower': 2100,
        'pv': [
          {'power': 2100, 'energy': 12345.6},
        ],
        'battery': {
          'power': -380,
          'energy': 1200.5,
          'capacity': 10.2,
          'soc': 76,
          'devices': [
            {
              'name': 'battery1',
              'power': -380,
              'capacity': 10.2,
              'soc': 76,
              'controllable': true,
            },
          ],
        },
        'batteryMode': 'unknown',
        'loadpoints': [],
      });
      expect(state.version, '0.316.2');
      expect(state.gridPower, -1240.5);
      expect(state.homePower, 480.2);
      expect(state.pvPower, 2100);
      expect(state.batteryConfigured, isTrue);
      expect(state.batterySoc, 76);
      expect(state.batteryPower, -380);
      expect(evccCardLines(state), [
        'PV 2,1 kW · Netz -1,2 kW · Haus 480 W',
        'Batterie 76 %',
      ]);
    });

    test('no battery: null (0.301.0+) or an empty list (0.125.0–0.300.x)', () {
      // prepare(): site.publish(keys.Battery, nil) resp. []api.Meter{}, and
      // site.publish(keys.Grid, api.Meter(nil)) until the first reading.
      for (final battery in [null, <Object>[]]) {
        final state = parseEvccState({
          'version': '0.316.2',
          'grid': null,
          'battery': battery,
          'loadpoints': [],
        });
        expect(state.batteryConfigured, isFalse, reason: '$battery');
        expect(state.batterySoc, isNull, reason: '$battery');
        expect(state.batteryPower, isNull, reason: '$battery');
        expect(state.gridPower, isNull, reason: '$battery');
      }
    });

    test('nested values win over flat ones; a missing one falls back', () {
      final both = parseEvccState({
        'grid': {'power': 100},
        'gridPower': 1,
        'battery': {
          'soc': 50,
          'power': 20,
          'devices': [
            {'power': 20},
          ],
        },
        'batterySoc': 2,
        'batteryPower': 3,
      });
      expect(both.gridPower, 100);
      expect(both.batterySoc, 50);
      expect(both.batteryPower, 20);

      final partial = parseEvccState({
        'grid': {'energy': 5},
        'gridPower': 1,
        'battery': {'devices': <Object>[]},
        'batterySoc': 2,
        'batteryPower': 3,
      });
      expect(partial.gridPower, 1);
      expect(partial.batterySoc, 2);
      expect(partial.batteryPower, 3);
      expect(partial.batteryConfigured, isFalse);
    });

    test('nested values tolerate strings, null and wrong types', () {
      final strings = parseEvccState({
        'grid': {'power': '1500'},
        'battery': {
          'soc': ' 76.5 ',
          'power': '-380',
          'devices': [
            {'power': -380},
          ],
        },
      });
      expect(strings.gridPower, 1500);
      expect(strings.batterySoc, 76.5);
      expect(strings.batteryPower, -380);
      expect(strings.batteryConfigured, isTrue);

      final broken = parseEvccState({
        'grid': 'n/a',
        'battery': {'soc': null, 'power': 'x', 'devices': 'none'},
      });
      expect(broken.gridPower, isNull);
      expect(broken.batterySoc, isNull);
      expect(broken.batteryPower, isNull);
      expect(broken.batteryConfigured, isFalse);

      expect(parseEvccState({'grid': 7, 'battery': true}).gridPower, isNull);
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

    test('several loadpoints: the charging one wins over a connected one '
        'listed before it — the only one shown', () {
      final lines = evccCardLines(state(pv: 1, lps: [
        lp(title: 'A', connected: true),
        lp(title: 'B', charging: true, connected: true, power: 5000),
      ]));
      // The whole card: no line for A before or after it.
      expect(lines, ['PV 1 W', 'B: 5,0 kW']);
    });

    test('several loadpoints, none charging: the first connected one', () {
      final lines = evccCardLines(state(pv: 1, lps: [
        lp(title: 'A'),
        lp(title: 'B', connected: true),
        lp(title: 'C', connected: true),
      ]));
      expect(lines, ['PV 1 W', 'B: verbunden']);
    });
  });
}
