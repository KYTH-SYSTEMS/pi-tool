/// Extra systemd-managed services the app can DETECT and manage (open web, logs,
/// restart) once the user has installed them their own way — AdGuard Home,
/// Node-RED, Zigbee2MQTT. These aren't apt packages and their installers are
/// bespoke, so the app deliberately does not install them; it only surfaces +
/// manages what's already there. Pure descriptors + parser (unit-testable).
library;

/// Descriptor for one systemd service the app knows how to detect/manage.
class SystemdService {
  const SystemdService({
    required this.id,
    required this.name,
    required this.unit,
    this.webPort,
  });

  /// Stable card id (routes UI actions + log unit mapping).
  final String id;

  /// Display name on the card.
  final String name;

  /// systemd unit (for state / restart / journalctl).
  final String unit;

  /// Web-UI port, or null.
  final int? webPort;
}

const List<SystemdService> knownSystemdServices = [
  SystemdService(
      id: 'adguard', name: 'AdGuard Home', unit: 'AdGuardHome', webPort: 3000),
  SystemdService(
      id: 'nodered', name: 'Node-RED', unit: 'nodered', webPort: 1880),
  SystemdService(
      id: 'zigbee2mqtt',
      name: 'Zigbee2MQTT',
      unit: 'zigbee2mqtt',
      webPort: 8080),
];

/// Whether a unit is present (installed) and whether it's running.
typedef SystemdState = ({bool installed, bool active});

/// Read-only unit state probe (no sudo): `not-found` LoadState ⇒ not installed.
String systemdStateCommand(String unit) =>
    'systemctl show -p LoadState -p ActiveState $unit 2>/dev/null';

SystemdState parseSystemdState(String output) {
  final load = RegExp(r'LoadState=(\S+)').firstMatch(output)?.group(1);
  final active = RegExp(r'ActiveState=(\S+)').firstMatch(output)?.group(1);
  return (installed: load == 'loaded', active: active == 'active');
}
