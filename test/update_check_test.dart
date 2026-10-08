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
