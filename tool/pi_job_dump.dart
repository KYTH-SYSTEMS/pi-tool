// Schreibt die Pi-Job-Skripte (Launcher, Follower, Neustart-Sperre) für den
// E2E-Test auf einem echten Pi in ein Verzeichnis — mit fester Job-ID und
// einer harmlosen Payload (echo/sleep, ändert nichts am System).
//
// Nutzung (PowerShell, im Projektordner):
//   $env:Path = "C:\Users\stefa\flutterdev\flutter\bin;" + $env:Path
//   dart run tool/pi_job_dump.dart <ausgabe-ordner> [sekunden] [exit-code]
//
// Importiert nur reine Bibliotheken (kein Flutter, kein SSH) — deshalb läuft
// es mit plain `dart run`. Das Pi-Passwort kommt in KEINE Datei: die stdin-
// Dateien beginnen mit der Sentinel-Zeile, das Passwort setzt man beim Senden
// davor (siehe README.txt im Ausgabe-Ordner).
//
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:evcc_updater/src/commands.dart'
    show jobPowerGuard, rebootCommand, shutdownCommand;
import 'package:evcc_updater/src/pi_job.dart';

/// Fixed so the Pi-side commands can be typed by hand.
const String e2eJobId = 'e2e0e2e0e2e0e2e0';
const String e2eJobKind = 'e2e-test';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
        'Nutzung: dart run tool/pi_job_dump.dart <ordner> [sekunden] [exit-code]');
    exit(64);
  }
  final out = Directory(args[0])..createSync(recursive: true);
  final seconds = args.length > 1 ? int.tryParse(args[1]) ?? 120 : 120;
  final rc = args.length > 2 ? int.tryParse(args[2]) ?? 3 : 3;
  if (seconds < 1 || seconds > 3600 || rc < 0 || rc > 255) {
    stderr.writeln('sekunden 1…3600, exit-code 0…255');
    exit(64);
  }

  // Harmless: prints a tick every 2 s, then a marker, then exits with [rc].
  final payload = buildJobPayload('''
echo 'Pi-Tool E2E: Start'
i=0
while [ "\$i" -lt ${(seconds + 1) ~/ 2} ]; do
  i=\$((i + 1))
  echo "tick \$i"
  sleep 2
done
echo E2E_DONE
exit $rc
''');

  void write(String name, String content) {
    File('${out.path}${Platform.pathSeparator}$name')
        .writeAsStringSync(content);
    print('geschrieben: $name');
  }

  final startStdin =
      buildJobStartStdin(password: '', id: e2eJobId, kind: e2eJobKind, payload: payload);
  final followStdin = buildJobFollowStdin(password: '', id: e2eJobId);

  write('start.stdin', startStdin);
  write('follow.stdin', followStdin);
  write('payload.sh', payload);
  write('run.sh', buildJobWrapperScript());
  // The guard with `true` instead of reboot/poweroff: safe on a production Pi.
  write('guard-test.sh', '$jobPowerGuard; echo PITOOL_GUARD_ALLOWED\n');
  write('commands.txt', '''
# Job-Start (stdin: Passwortzeile + start.stdin)
${jobStartCommand(e2eJobId)}

# Mitlesen (stdin: Passwortzeile + follow.stdin)
${jobFollowCommand(e2eJobId)}

# Status ohne sudo
$jobStatusProbe

# Neustart-Sperre testen (führt KEINEN Neustart aus; stdin: Passwortzeile)
LC_ALL=C sudo -S sh -c '$jobPowerGuard; echo PITOOL_GUARD_ALLOWED'

# Zum Vergleich — NICHT auf einem Produktiv-Pi ausführen:
# $rebootCommand
# $shutdownCommand
''');
  write('README.txt', '''
Pi-Job E2E ($e2eJobKind, ID $e2eJobId, ~$seconds s, Exit $rc)

Senden (Git Bash, Passwort nur in der Umgebungsvariable PI_PW):
  { printf '%s\\n' "\$PI_PW"; cat start.stdin; } | ssh pi@<host> "\$(sed -n 2p commands.txt)"
  { printf '%s\\n' "\$PI_PW"; cat follow.stdin; } | ssh pi@<host> "\$(sed -n 5p commands.txt)"

Erwartet: "PITOOL_JOB_STARTED $e2eJobId $e2eJobKind", die tick-Zeilen, E2E_DONE,
dann "PITOOL_JOB_RC $e2eJobId $rc". Ein zweites Mitlesen liefert dasselbe Log.
Aufräumen: sudo rm -rf $jobsBaseDir/$e2eJobId
''');
}
