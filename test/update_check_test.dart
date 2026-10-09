import 'dart:async';
import 'dart:io';

import 'package:evcc_updater/src/update_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isNewerVersion', () {
    test('a higher patch is newer', () {
      expect(isNewerVersion('0.1.3', '0.1.2'), isTrue);
    });

    test('strips a leading v from the tag', () {
      expect(isNewerVersion('v0.1.3', '0.1.2'), isTrue);
    });

    test('equal versions are not newer', () {
      expect(isNewerVersion('0.1.2', '0.1.2'), isFalse);
    });

    test('an older version is not newer', () {
      expect(isNewerVersion('0.1.2', '0.1.3'), isFalse);
    });

    test('compares numerically, not lexically (1.10 > 1.9)', () {
      expect(isNewerVersion('1.10.0', '1.9.0'), isTrue);
    });

    test('a minor bump beats a high patch', () {
      expect(isNewerVersion('0.2.0', '0.1.9'), isTrue);
    });

    test('missing components count as zero (1.0 == 1.0.0)', () {
      expect(isNewerVersion('1.0', '1.0.0'), isFalse);
    });

    test('build metadata after + is ignored', () {
      expect(isNewerVersion('0.1.2+9', '0.1.2+1'), isFalse);
      expect(isNewerVersion('0.1.3+1', '0.1.2+9'), isTrue);
    });

    test('garbage is treated as not newer', () {
      expect(isNewerVersion('garbage', '0.1.2'), isFalse);
    });
  });

  group('parseLatestRelease', () {
    test('reads tag, html url and the .apk asset url', () {
      final info = parseLatestRelease({
        'tag_name': 'v0.1.3',
        'html_url': 'https://github.com/KYTH-SYSTEMS/pi-tool/releases/tag/v0.1.3',
        'assets': [
          {'name': 'something.txt', 'browser_download_url': 'https://x/t.txt'},
          {
            'name': 'app-release.apk',
            'browser_download_url':
                'https://github.com/KYTH-SYSTEMS/pi-tool/releases/download/v0.1.3/app-release.apk'
          },
        ],
      });

      expect(info.version, 'v0.1.3');
      expect(info.htmlUrl, contains('releases/tag/v0.1.3'));
      expect(info.apkUrl, endsWith('app-release.apk'));
    });

    test('apkUrl is null when no apk asset is attached', () {
      final info = parseLatestRelease({
        'tag_name': 'v0.1.3',
        'html_url': 'https://example/r',
        'assets': [
          {'name': 'notes.txt', 'browser_download_url': 'https://x/t.txt'},
        ],
      });

      expect(info.apkUrl, isNull);
    });
  });

  group('installChannelFor', () {
    test('the Play Store installer means a Play build', () {
      expect(installChannelFor('com.android.vending'), InstallChannel.play);
    });

    test('the legacy Play installer package also means a Play build', () {
      expect(
          installChannelFor('com.google.android.feedback'), InstallChannel.play);
    });

    test('casing and surrounding whitespace do not matter', () {
      expect(installChannelFor('  COM.Android.Vending '), InstallChannel.play);
    });

    test('null (adb / unknown installer) means sideload', () {
      expect(installChannelFor(null), InstallChannel.sideload);
    });

    test('an empty string means sideload', () {
      expect(installChannelFor(''), InstallChannel.sideload);
    });

    test('another installer (browser, file manager) means sideload', () {
      expect(installChannelFor('com.google.android.packageinstaller'),
          InstallChannel.sideload);
      expect(installChannelFor('org.fdroid.fdroid'), InstallChannel.sideload);
    });

    test('a package merely containing the Play id is not a Play build', () {
      expect(installChannelFor('com.android.vending.evil'),
          InstallChannel.sideload);
    });
  });

  group('parseEvccRelease', () {
    test('reads tag and notes body', () {
      final r = parseEvccRelease(
          {'tag_name': '0.207.0', 'body': '## Changes\n- something'});
      expect(r.version, '0.207.0');
      expect(r.notes, contains('Changes'));
    });
  });

  group('UpdateChecker.checkForUpdate', () {
    UpdateChecker checkerReturning(Map<String, dynamic> json) =>
        UpdateChecker(getJson: (_) async => json);

    final releaseJson = {
      'tag_name': 'v0.1.3',
      'html_url': 'https://github.com/KYTH-SYSTEMS/pi-tool/releases/tag/v0.1.3',
      'assets': [
        {
          'name': 'app-release.apk',
          'browser_download_url': 'https://x/app-release.apk'
        },
      ],
    };

    test('returns release info when a newer version exists', () async {
      final info = await checkerReturning(releaseJson).checkForUpdate('0.1.2');
      expect(info, isNotNull);
      expect(info!.version, 'v0.1.3');
      expect(info.apkUrl, endsWith('app-release.apk'));
    });

    test('returns null when already on the latest version', () async {
      final info = await checkerReturning(releaseJson).checkForUpdate('0.1.3');
      expect(info, isNull);
    });

    test('returns null (never throws) on a network/parse error', () async {
      final checker = UpdateChecker(getJson: (_) async => throw Exception('offline'));
      expect(await checker.checkForUpdate('0.1.2'), isNull);
    });

    test('returns null (never throws) on an answer without a tag', () async {
      expect(await checkerReturning({}).checkForUpdate('0.1.2'), isNull);
    });
  });

  // The manual check has to tell "no update" from "could not check": the
  // fail-soft variant returns null for both, and the app then reported
  // "Aktuell" while offline or rate-limited.
  group('UpdateChecker.checkForUpdateOrThrow', () {
    UpdateChecker checkerReturning(Map<String, dynamic> json) =>
        UpdateChecker(getJson: (_) async => json);

    test('a newer release is returned', () async {
      final info = await checkerReturning({'tag_name': 'v0.1.3'})
          .checkForUpdateOrThrow('0.1.2');
      expect(info?.version, 'v0.1.3');
    });

    test('null only means: checked, nothing newer', () async {
      expect(
          await checkerReturning({'tag_name': 'v0.1.3'})
              .checkForUpdateOrThrow('0.1.3'),
          isNull);
    });

    test('a failed fetch throws (offline, HTTP 403/429 rate limit)', () async {
      final checker = UpdateChecker(
          getJson: (_) async => throw const HttpException('GitHub API 403'));
      await expectLater(
          checker.checkForUpdateOrThrow('0.1.2'), throwsA(isA<HttpException>()));
    });

    test('an answer without a release tag throws', () async {
      await expectLater(checkerReturning({}).checkForUpdateOrThrow('0.1.2'),
          throwsA(isA<FormatException>()));
      await expectLater(
          checkerReturning({'tag_name': '  '}).checkForUpdateOrThrow('0.1.2'),
          throwsA(isA<FormatException>()));
    });
  });

  // The real adapter against a loopback server: every phase of the request
  // has to end within the time limit.
  group('githubGetJson (HTTP adapter)', () {
    /// [stall] true: headers and the start of the body, then silence.
    Future<Uri> serve({int status = 200, bool stall = false}) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        const body = '{"tag_name":"v1.2.3"}';
        req.response
          ..statusCode = status
          ..headers.contentType = ContentType.json
          ..contentLength = body.length
          ..write(stall ? body.substring(0, 8) : body);
        await (stall ? req.response.flush() : req.response.close());
      });
      addTearDown(() => server.close(force: true));
      return Uri.parse('http://127.0.0.1:${server.port}/releases/latest');
    }

    test('reads a complete answer', () async {
      expect(await githubGetJson(await serve()), {'tag_name': 'v1.2.3'});
    });

    test('a non-200 answer (rate limit) is an error', () async {
      await expectLater(githubGetJson(await serve(status: 403)),
          throwsA(isA<HttpException>()));
    });

    test('the status of a refused request is in the error', () async {
      await expectLater(
          githubGetJson(await serve(status: 429)),
          throwsA(isA<HttpException>()
              .having((e) => e.message, 'message', 'GitHub API 429')));
    });

    test('asks with GET and the headers GitHub wants', () async {
      final github = await _GitHub.start({
        '/repos/o/r/releases/latest': (200, '{"tag_name":"v1.2.3"}'),
      });
      expect(await githubGetJson(github.url('/repos/o/r/releases/latest')),
          {'tag_name': 'v1.2.3'});
      expect(github.asked, ['GET /repos/o/r/releases/latest']);
      // GitHub answers a request without a User-Agent with 403.
      expect(github.headers.single['user-agent'], 'evcc-updater-app');
      expect(github.headers.single['accept'], 'application/vnd.github+json');
    });

    test('an answer that is no JSON object is an error', () async {
      final github = await _GitHub.start({
        '/html': (200, '<html>rate limited</html>'),
        '/list': (200, '[{"tag_name":"v1.2.3"}]'),
      });
      await expectLater(
          githubGetJson(github.url('/html')), throwsA(isA<FormatException>()));
      await expectLater(
          githubGetJson(github.url('/list')), throwsA(isA<TypeError>()));
    });

    test('nothing listens on the port: an error, not a hang', () async {
      final github = await _GitHub.start(const {});
      final url = github.url('/releases/latest');
      await github.stop();
      await expectLater(githubGetJson(url), throwsA(isA<SocketException>()));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a body that stalls mid-way ends in a timeout, not a hang', () async {
      // Only the wait for the headers was limited; the body read was not.
      final url = await serve(stall: true);
      final sw = Stopwatch()..start();
      await expectLater(
          githubGetJson(url, timeout: const Duration(milliseconds: 400)),
          throwsA(isA<TimeoutException>()));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('the fail-soft callers survive the timeout', () async {
      final url = await serve(stall: true);
      Future<Map<String, dynamic>> get(Uri _) =>
          githubGetJson(url, timeout: const Duration(milliseconds: 300));
      expect(await fetchEvccRelease(getJson: get), isNull);
      expect(await fetchLatestHomeAssistantVersion(getJson: get), isNull);
      expect(await UpdateChecker(getJson: get).checkForUpdate('0.1.2'), isNull);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('the connect phase has its own limit', () async {
      // Without one, DNS + TCP + TLS run until the OS gives up (minutes when
      // packets are dropped). Dropped packets cannot be provoked on loopback,
      // so this looks at the client the adapter really used.
      final overrides = _RecordingOverrides();
      await HttpOverrides.runWithHttpOverrides(
          () async => githubGetJson(await serve()), overrides);
      final limit = overrides.created.single.connectionTimeout;
      expect(limit, isNotNull);
      expect(limit, lessThanOrEqualTo(const Duration(seconds: 10)));
    });
  });

  // The two fail-soft fetchers through the real adapter. Their URLs are fixed
  // (https://api.github.com/…), so the getter handed to them notes the
  // address and sends the same path to a loopback server instead — no request
  // leaves the machine.
  group('fetchEvccRelease / fetchLatestHomeAssistantVersion (loopback)', () {
    const evccPath = '/repos/evcc-io/evcc/releases/latest';
    const haPath = '/repos/home-assistant/core/releases/latest';

    /// What the fetchers asked for, before it was sent to the loopback.
    final wanted = <String>[];
    setUp(wanted.clear);

    HttpGetJson via(_GitHub github) => (Uri url) {
          wanted.add('$url');
          return githubGetJson(github.url(url.path));
        };

    test('evcc: tag and release notes of evcc-io/evcc', () async {
      final github = await _GitHub.start({
        evccPath: (
          200,
          '{"tag_name":"0.311.0","body":"## Changes\\n- Ladeplanung"}'
        ),
      });
      final release = await fetchEvccRelease(getJson: via(github));
      expect(release?.version, '0.311.0');
      expect(release?.notes, '## Changes\n- Ladeplanung');
      expect(wanted, ['https://api.github.com$evccPath']);
      expect(github.asked, ['GET $evccPath']);
    });

    test('evcc: a release without notes still has its tag', () async {
      final github =
          await _GitHub.start({evccPath: (200, '{"tag_name":"0.311.0"}')});
      final release = await fetchEvccRelease(getJson: via(github));
      expect(release?.version, '0.311.0');
      expect(release?.notes, isEmpty);
    });

    test('Home Assistant: the tag of home-assistant/core, trimmed', () async {
      final github =
          await _GitHub.start({haPath: (200, '{"tag_name":" 2026.10.1\\n"}')});
      expect(await fetchLatestHomeAssistantVersion(getJson: via(github)),
          '2026.10.1');
      expect(wanted, ['https://api.github.com$haPath']);
      expect(github.asked, ['GET $haPath']);
    });

    test('both are null on what GitHub answers when it does not deliver',
        () async {
      for (final (status, body) in [
        (403, '{"message":"API rate limit exceeded"}'),
        (404, '{"message":"Not Found"}'),
        (200, '<html>'), // not JSON
        (200, '[]'), // JSON, but no object
        (200, '{}'), // no tag_name
        (200, '{"tag_name":""}'),
      ]) {
        final github = await _GitHub.start(
            {evccPath: (status, body), haPath: (status, body)});
        expect(await fetchEvccRelease(getJson: via(github)), isNull,
            reason: '$status $body');
        expect(await fetchLatestHomeAssistantVersion(getJson: via(github)),
            isNull,
            reason: '$status $body');
        // Asked once each — a failure is not retried.
        expect(github.asked, ['GET $evccPath', 'GET $haPath']);
        await github.stop();
      }
    });

    test('both are null when nothing answers at all', () async {
      final github = await _GitHub.start(const {});
      await github.stop();
      expect(await fetchEvccRelease(getJson: via(github)), isNull);
      expect(
          await fetchLatestHomeAssistantVersion(getJson: via(github)), isNull);
      // Both got as far as the request.
      expect(wanted, hasLength(2));
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}

/// A loopback server standing in for api.github.com: answers a path with the
/// status and body given for it (404 without), and keeps what was asked.
class _GitHub {
  _GitHub._(this._server, this._answers) : _port = _server.port;

  final HttpServer _server;
  final int _port; // the server no longer tells once it is closed
  final Map<String, (int, String)> _answers;

  /// `METHOD path` of every request, in order …
  final asked = <String>[];

  /// … and its headers, by lower-case name.
  final headers = <Map<String, String>>[];

  static Future<_GitHub> start(Map<String, (int, String)> answers) async {
    final github = _GitHub._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0), answers);
    github._server.listen(github._answer);
    addTearDown(github.stop);
    return github;
  }

  Future<void> _answer(HttpRequest req) async {
    asked.add('${req.method} ${req.uri.path}');
    final seen = <String, String>{};
    req.headers.forEach((name, values) => seen[name] = values.join(', '));
    headers.add(seen);
    final (status, body) =
        _answers[req.uri.path] ?? (404, '{"message":"Not Found"}');
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(body);
    await req.response.close();
  }

  Uri url(String path) => Uri.parse('http://127.0.0.1:$_port$path');

  Future<void> stop() => _server.close(force: true);
}

/// Hands out real clients and remembers them.
class _RecordingOverrides extends HttpOverrides {
  final created = <HttpClient>[];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    created.add(client);
    return client;
  }
}
