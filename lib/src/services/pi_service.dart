/// Core, Flutter-free model for the multi-service Pi-Tool (see
/// design/2026-06-30-multi-service.md). A "service" is something the app can
/// detect, install, update and show status for on the Pi (evcc, Pi-hole,
/// System). UI-specific bits (icons, actions) live in the widget layer.
library;

import '../update_check.dart' show isNewerVersion;

/// Health/status of one service as detected on the Pi.
class ServiceStatus {
  /// Stable id: 'evcc' | 'pihole' | 'system'.
  final String id;

  /// Display name shown on the card.
  final String name;

  final bool installed;
  final String? version;

  /// Running/healthy (e.g. systemd active, DNS resolving). Meaningless when not
  /// [installed].
  final bool active;

  /// A newer version / pending updates exist. Only meaningful when
  /// [updateKnown] is true.
  final bool updateAvailable;

  /// Whether the app actually determined update availability for this service.
  /// True for apt-evcc / Pi-hole / System (we check); false where we can't know
  /// cheaply (Docker-based evcc / Home Assistant), so the UI keeps offering a
  /// plain "Aktualisieren" instead of claiming it is up to date.
  final bool updateKnown;

  /// Short human status line (mono), e.g. "Dienst aktiv" or "3 Updates".
  final String detail;

  /// Optional vitals line (System card): temperature, free disk/RAM, uptime.
  final String health;

  /// True when [health] carries a warning (e.g. low disk) — shown emphasized.
  final bool healthWarning;

  /// Web-UI port for generic (apt) services, e.g. Grafana 3000. The bespoke
  /// services (evcc/Pi-hole/HA) keep their own open-web handlers.
  final int? webPort;

  /// The concrete apt package behind a generic service card (e.g. `influxdb2`
  /// for the InfluxDB card) — what an update actually upgrades.
  final String? aptPackage;

  /// False → the service can't run on this Pi (e.g. Pi Connect needs Bookworm+);
  /// the UI shows it greyed with a reason instead of offering it. Default true.
  final bool compatible;

  const ServiceStatus({
    required this.id,
    required this.name,
    required this.installed,
    this.version,
    this.active = false,
    this.updateAvailable = false,
    this.updateKnown = false,
    this.detail = '',
    this.health = '',
    this.healthWarning = false,
    this.webPort,
    this.aptPackage,
    this.compatible = true,
  });

  /// A "not installed" status for a service the app knows about but didn't find.
  factory ServiceStatus.absent(String id, String name, {bool compatible = true}) =>
      ServiceStatus(
          id: id, name: name, installed: false, compatible: compatible);

  /// Round-trips a detection so the app can show the LAST KNOWN state the
  /// moment it opens, instead of an empty screen while the SSH round trip runs.
  /// Deliberately carries no secrets — every field here is already on screen.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'installed': installed,
        'version': version,
        'active': active,
        'updateAvailable': updateAvailable,
        'updateKnown': updateKnown,
        'detail': detail,
        'health': health,
        'healthWarning': healthWarning,
        'webPort': webPort,
        'aptPackage': aptPackage,
        'compatible': compatible,
      };

  static ServiceStatus fromJson(Map<String, dynamic> j) => ServiceStatus(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        installed: j['installed'] == true,
        version: j['version']?.toString(),
        active: j['active'] == true,
        updateAvailable: j['updateAvailable'] == true,
        updateKnown: j['updateKnown'] == true,
        detail: (j['detail'] ?? '').toString(),
        health: (j['health'] ?? '').toString(),
        healthWarning: j['healthWarning'] == true,
        webPort: j['webPort'] is int ? j['webPort'] as int : null,
        aptPackage: j['aptPackage']?.toString(),
        compatible: j['compatible'] != false,
      );

  ServiceStatus copyWith({bool? updateAvailable, bool? updateKnown}) =>
      ServiceStatus(
        id: id,
        name: name,
        installed: installed,
        version: version,
        active: active,
        updateAvailable: updateAvailable ?? this.updateAvailable,
        updateKnown: updateKnown ?? this.updateKnown,
        detail: detail,
        health: health,
        healthWarning: healthWarning,
        webPort: webPort,
        aptPackage: aptPackage,
        compatible: compatible,
      );
}

/// Cross-checks the apt-installed evcc against its latest GitHub release
/// version. The apt update check reads the Pi's LOCAL package index, which can
/// be stale (no recent `apt-get update`) and then wrongly reports "up to date";
/// if [latestEvccVersion] is newer than the installed apt version, flag the
/// update anyway. Only touches an apt evcc — a Docker evcc carries an image tag,
/// not a comparable version. Fail-safe: null/empty latest → unchanged.
List<ServiceStatus> applyLatestEvccVersion(
    List<ServiceStatus> services, String? latestEvccVersion) {
  if (latestEvccVersion == null || latestEvccVersion.isEmpty) return services;
  return [
    for (final s in services)
      if (s.id == 'evcc' &&
          s.installed &&
          s.version != null &&
          s.detail.startsWith('apt'))
        // A compare that SUCCEEDS is knowledge either way — including "you are
        // current", which is what rescues the "Aktuell ✓" when the Pi's apt
        // index is too old for detection to tell. Never downgrade an update apt
        // already found: the local index knowing more is not a contradiction.
        s.copyWith(
          updateAvailable: s.updateAvailable ||
              isNewerVersion(latestEvccVersion, s.version!),
          updateKnown: true,
        )
      else
        s,
  ];
}

/// Cross-checks the running Home Assistant against its latest GitHub release.
/// HA's version comes from /config/.HA_VERSION (see haVersionProbe) — a calver
/// like "2026.6.3". Only compares when BOTH the installed version and [latest]
/// look like a calver, so a non-pinned image tag ("stable"/"latest") stays
/// "unknown" (updateKnown false) rather than being wrongly flagged. On a valid
/// compare we set updateKnown=true so the card can finally show "Aktuell ✓"
/// when current. Fail-safe: null/empty latest → unchanged.
List<ServiceStatus> applyLatestHomeAssistantVersion(
    List<ServiceStatus> services, String? latest) {
  final calver = RegExp(r'^\d{4}\.\d+(?:\.\d+)?$');
  if (latest == null || !calver.hasMatch(latest)) return services;
  return [
    for (final s in services)
      if (s.id == 'homeassistant' &&
          s.installed &&
          s.version != null &&
          calver.hasMatch(s.version!))
        s.copyWith(
          updateKnown: true,
          updateAvailable: isNewerVersion(latest, s.version!),
        )
      else
        s,
  ];
}

/// Orders services for the overview so the System (Pi) card is always first;
/// the remaining services keep their detected order.
List<ServiceStatus> orderServicesForDisplay(List<ServiceStatus> services) => [
      ...services.where((s) => s.id == 'system'),
      ...services.where((s) => s.id != 'system'),
    ];
