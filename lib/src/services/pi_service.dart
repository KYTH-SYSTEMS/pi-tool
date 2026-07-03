/// Core, Flutter-free model for the multi-service Pi-Tool (see
/// design/2026-06-30-multi-service.md). A "service" is something the app can
/// detect, install, update and show status for on the Pi (evcc, Pi-hole,
/// System). UI-specific bits (icons, actions) live in the widget layer.
library;

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
  });

  /// A "not installed" status for a service the app knows about but didn't find.
  factory ServiceStatus.absent(String id, String name) =>
      ServiceStatus(id: id, name: name, installed: false);
}

/// Orders services for the overview so the System (Pi) card is always first;
/// the remaining services keep their detected order.
List<ServiceStatus> orderServicesForDisplay(List<ServiceStatus> services) => [
      ...services.where((s) => s.id == 'system'),
      ...services.where((s) => s.id != 'system'),
    ];
