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
  });
}
