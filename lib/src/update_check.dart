/// In-app update check against GitHub Releases — sideload channel only, which
/// [installChannelFor] enforces (a Play build is updated by Play itself).
///
/// Pure version comparison + JSON parsing are unit-tested; the network fetch is
/// a thin injectable adapter. The check is deliberately fail-soft: any error
/// yields "no update" so it can never disrupt the app.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Where this build was installed from.
enum InstallChannel {
  /// Installed by the Play Store — updates come through Play.
  play,

  /// Everything else: the GitHub APK, adb, a file manager, another store.
  sideload,
}

/// Installer package name reported by the Play Store.
const _kPlayInstaller = 'com.android.vending';

/// Legacy installer package Play used (still reported on some devices).
const _kPlayInstallerLegacy = 'com.google.android.feedback';

/// Classifies `PackageInfo.installerStore` into an [InstallChannel].
///
/// A Play build must NEVER be offered the GitHub APK: Play requires its apps to
/// update through Play, and Play App Signing re-signs the bundle, so the
/// differently-signed sideload APK cannot install over a Play build anyway.
/// Anything we cannot positively identify as Play counts as sideload — that is
/// the channel whose only update path IS the in-app notice.
InstallChannel installChannelFor(String? installerStore) {
  final store = (installerStore ?? '').trim().toLowerCase();
  return (store == _kPlayInstaller || store == _kPlayInstallerLegacy)
      ? InstallChannel.play
      : InstallChannel.sideload;
}

/// Info about the latest GitHub release.
class ReleaseInfo {
  /// Raw tag, e.g. `v0.1.3`.
  final String version;

  /// Release page URL.
  final String htmlUrl;

  /// Direct `app-release.apk` asset URL, if attached.
  final String? apkUrl;

  const ReleaseInfo({
    required this.version,
    required this.htmlUrl,
    required this.apkUrl,
  });

  /// Best URL to send the user to (direct APK if present, else release page).
  String get downloadUrl => apkUrl ?? htmlUrl;
}

/// Whether [latest] is a strictly newer version than [current].
///
/// Ignores a leading `v` and any `+build` / `-prerelease` suffix, and compares
/// dot-separated components numerically (so 1.10 > 1.9). Non-numeric parts
/// count as 0.
bool isNewerVersion(String latest, String current) {
  final a = _parseVersion(latest);
  final b = _parseVersion(current);
  final len = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < len; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

List<int> _parseVersion(String v) {
  var s = v.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  s = s.split('+').first.split('-').first;
  return s.split('.').map((p) => int.tryParse(p) ?? 0).toList();
}

/// Parses the GitHub "latest release" JSON into [ReleaseInfo].
ReleaseInfo parseLatestRelease(Map<String, dynamic> json) {
  final tag = (json['tag_name'] ?? '').toString();
  final htmlUrl = (json['html_url'] ?? '').toString();

  String? apkUrl;
  final assets = json['assets'];
  if (assets is List) {
    for (final asset in assets) {
      if (asset is Map) {
        final name = (asset['name'] ?? '').toString();
        if (name.toLowerCase().endsWith('.apk')) {
          apkUrl = (asset['browser_download_url'] ?? '').toString();
          break;
        }
      }
    }
  }

  return ReleaseInfo(version: tag, htmlUrl: htmlUrl, apkUrl: apkUrl);
}

/// Fetches JSON from [url]. Injected so the checker can be unit-tested.
typedef HttpGetJson = Future<Map<String, dynamic>> Function(Uri url);

/// Checks GitHub Releases for a newer version of the app.
class UpdateChecker {
  final HttpGetJson _get;
  final String owner;
  final String repo;

  UpdateChecker({
    HttpGetJson? getJson,
    this.owner = 'profex1337',
    this.repo = 'evcc-pi-tool',
  }) : _get = getJson ?? _defaultGetJson;

  /// Returns [ReleaseInfo] when a release newer than [currentVersion] exists,
  /// otherwise `null`. Never throws — a failed check just means "no update".
  Future<ReleaseInfo?> checkForUpdate(String currentVersion) async {
    try {
      final json = await _get(
        Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest'),
      );
      final info = parseLatestRelease(json);
      if (info.version.isEmpty) return null;
      return isNewerVersion(info.version, currentVersion) ? info : null;
    } catch (_) {
      return null;
    }
  }
}

/// Latest evcc release (tag + release-notes body).
class EvccRelease {
  final String version;
  final String notes;

  const EvccRelease({required this.version, required this.notes});
}

EvccRelease parseEvccRelease(Map<String, dynamic> json) => EvccRelease(
      version: (json['tag_name'] ?? '').toString(),
      notes: (json['body'] ?? '').toString(),
    );

/// Fetches evcc's latest GitHub release notes. Fail-soft: returns null on any
/// error, so it can never block the update flow.
Future<EvccRelease?> fetchEvccRelease({HttpGetJson? getJson}) async {
  final get = getJson ?? _defaultGetJson;
  try {
    final json = await get(
      Uri.parse('https://api.github.com/repos/evcc-io/evcc/releases/latest'),
    );
    final release = parseEvccRelease(json);
    return release.version.isEmpty ? null : release;
  } catch (_) {
    return null;
  }
}

/// Home Assistant's latest release tag (e.g. "2026.6.3"). Fail-soft: null on any
/// error, so it can never block detection.
Future<String?> fetchLatestHomeAssistantVersion({HttpGetJson? getJson}) async {
  final get = getJson ?? _defaultGetJson;
  try {
    final json = await get(Uri.parse(
        'https://api.github.com/repos/home-assistant/core/releases/latest'));
    final tag = (json['tag_name'] ?? '').toString().trim();
    return tag.isEmpty ? null : tag;
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>> _defaultGetJson(Uri url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, 'evcc-updater-app');
    request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw HttpException('GitHub API ${response.statusCode}');
    }
    final body = await response.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}
