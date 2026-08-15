/// Docker container overview: list running/stopped containers, restart one, read
/// its logs. Pure command strings + parser here (unit-testable); the app runs
/// them over SSH. Uses the same `name|…` pipe format as the evcc docker probe.
library;

import 'commands.dart' show shSingleQuote;

/// One container row from `docker ps -a`.
typedef DockerContainer = ({
  String name,
  String state,
  String status,
  String image,
});

/// `docker ps -a` as `name|state|status|image` (via sudo so it also works where
/// the user isn't in the `docker` group; harmless if they are).
const String dockerPsSudoCommand =
    "LC_ALL=C sudo -S docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}|{{.Image}}'";

/// Parses the pipe-delimited `docker ps` output. Error/daemon lines (no pipe)
/// are ignored, so a missing daemon just yields an empty list.
List<DockerContainer> parseDockerPs(String output) {
  final out = <DockerContainer>[];
  for (final raw in output.split('\n')) {
    final line = raw.trimRight();
    if (line.isEmpty || !line.contains('|')) continue;
    final p = line.split('|');
    if (p.length < 4) continue;
    out.add((
      name: p[0].trim(),
      state: p[1].trim(),
      status: p[2].trim(),
      image: p.sublist(3).join('|').trim(), // an image ref may contain ':'
    ));
  }
  return out;
}

/// `docker restart <name>` (sudo, name shell-quoted).
String buildDockerRestartCommand(String name) =>
    'LC_ALL=C sudo -S docker restart ${shSingleQuote(name)}';

/// Last 200 log lines of a container (sudo, name shell-quoted, stderr merged).
String buildDockerLogsCommand(String name) =>
    'LC_ALL=C sudo -S docker logs --tail 200 ${shSingleQuote(name)} 2>&1';

/// Is the container actually running? (sudo, name shell-quoted.) Used to
/// verify a container update really left a living container behind.
String buildDockerRunningProbe(String name) =>
    "LC_ALL=C sudo -S docker inspect -f '{{.State.Running}}' "
    '${shSingleQuote(name)}';
