/// "Alles aktualisieren" on one Pi — what it takes besides the system
/// packages. The apt full-upgrade always runs and brings every apt-installed
/// service (evcc from apt, Grafana, InfluxDB, Tailscale, …) up to date with it.
/// On top of that come Pi-hole (`pihole -up`, not an apt package) and every
/// running Docker container: Home Assistant's and evcc's through their own
/// updates, the others ([otherContainersToUpdate]) through the generic one. A
/// container reports no update state ([ServiceStatus.updateKnown] false), so
/// the pull itself finds out and leaves a current container untouched.
library;

import 'docker_containers.dart';
import 'services/homeassistant_service.dart' show parseHomeAssistant;
import 'services/pi_service.dart';

/// The steps after the system packages. [evcc] also covers an apt evcc with an
/// update: the full-upgrade brings it, but the backup before an evcc update
/// must run first.
typedef FullUpdatePlan = ({bool pihole, bool homeAssistant, bool evcc});

FullUpdatePlan planFullUpdate(List<ServiceStatus> services) {
  bool due(String id) => services.any((s) =>
      s.id == id && s.installed && (s.updateAvailable || !s.updateKnown));
  return (
    pihole: due('pihole'),
    homeAssistant: due('homeassistant'),
    evcc: due('evcc'),
  );
}

/// Whether the Pi has an update the app knows of — for the System card's
/// button and the multi-Pi traffic light. An unknown state (a container) is
/// no pending update: it would keep every Pi with Home Assistant amber.
bool fullUpdatePending(List<ServiceStatus> services) => services
    .any((s) => s.installed && s.updateKnown && s.updateAvailable);

/// The running containers the generic container update takes on, after Home
/// Assistant's and evcc's own updates ([evccContainer]: the evcc container,
/// when evcc runs in one). Home Assistant's is found the way its update finds
/// it. Never Pi-Tool's rollback containers, never a stopped container: it was
/// stopped on purpose, and the recreate would start it.
List<String> otherContainersToUpdate(List<DockerContainer> all,
    {String? evccContainer}) {
  final ha = parseHomeAssistant(
          all.map((c) => '${c.name}|${c.image}').join('\n'))
      ?.name;
  return [
    for (final c in all)
      if (c.state == 'running' &&
          c.name != ha &&
          c.name != evccContainer &&
          !c.name.endsWith('-evccpitool-old'))
        c.name
  ];
}
