/// Pi-Jobs: package-changing updates that keep running ON THE PI when the
/// connection drops, the app is killed or the user stops following.
///
/// The app hands a small root "launcher" to `sudo -S bash`, which writes the
/// job into `/var/lib/pi-tool/jobs/<id>/` and starts a constant wrapper (run.sh)
/// as a transient systemd unit (setsid when there is no systemd). The wrapper
/// runs the payload with its output going to a log file and leaves the exit
/// code in an rc file. A "follower" streams that log from offset 0 and ends
/// with one control line — so the app only ever reports success on positive
/// proof (`PITOOL_JOB_RC <id> 0` plus the kind's own markers), and it can
/// re-follow a job later to get the real outcome.
///
/// Pure builders + parsers only (no Flutter, no SSH): `dart run` works on this
/// library, which the E2E dump tool (tool/pi_job_dump.dart) relies on.
/// On-Pi protocol and invariants: ARCHITECTURE.md, and SPEC v2 (Pi-Jobs).
library;

import 'dart:convert';
import 'dart:math';

import 'commands.dart' show shSingleQuote, versionQuery;
import 'eol_sources.dart'
    show eolSourcesFixScript, isAptLocked, parseDeadAptSource;
import 'parsing.dart'
    show isAlreadyNewest, isSudoPasswordFailure, parseInstalledVersion;
import 'services/system_service.dart' show isDpkgInterrupted;

// ---------------------------------------------------------------------------
// On-Pi layout
// ---------------------------------------------------------------------------

/// Pi-Tool's state directory (0755; other features keep files here too).
const String piToolStateDir = '/var/lib/pi-tool';

/// Base of all jobs (0700 root). One directory per job id.
const String jobsBaseDir = '$piToolStateDir/jobs';

/// Global exclusivity lock: held by the wrapper of the running job.
const String jobLockPath = '$jobsBaseDir/lock';

/// One world-readable line about the latest job (no log content):
/// `<id> <kind> <running|done|lost> <rc|-> <start> <end|-> <boot_id>`.
const String jobStatusPath = '$piToolStateDir/job.status';

/// The wrapper's PATH — fixed, so a job never depends on the login shell.
const String jobDefaultPath =
    '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';

// Job kinds of Tier 1 (the only job-backed actions).
const String jobKindSystemUpgrade = 'system-upgrade';
const String jobKindEvccUpdate = 'evcc-update';
const String jobKindPackageUpdate = 'package-update';
const String jobKindPackageRepair = 'package-repair';
const String jobKindPiholeUpdate = 'pihole-update';

/// Printed by the payload right before the actual upgrade command, so the
/// evaluation reads "already newest" from that command's output only — the
/// fix-broken step before it prints an apt summary of its own.
const String jobUpgradeMarker = 'PITOOL_UPGRADE_OUTPUT';

final RegExp _idRe = RegExp(r'^[0-9a-f]{16}$');
final RegExp _kindRe = RegExp(r'^[a-z0-9-]{1,32}$');

/// A job id: 16 lowercase hex characters.
bool isValidJobId(String id) => _idRe.hasMatch(id);

/// A job kind: 1–32 of `[a-z0-9-]`.
bool isValidJobKind(String kind) => _kindRe.hasMatch(kind);

void _checkId(String id) {
  if (!isValidJobId(id)) {
    throw ArgumentError.value(id, 'id', 'keine gültige Job-ID');
  }
}

void _checkKind(String kind) {
  if (!isValidJobKind(kind)) {
    throw ArgumentError.value(kind, 'kind', 'keine gültige Job-Art');
  }
}

/// A fresh job id from a cryptographically secure source.
String generateJobId([Random? random]) {
  final r = random ?? Random.secure();
  final b = StringBuffer();
  for (var i = 0; i < 8; i++) {
    b.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// Identifies one job on one Pi.
class JobRef {
  const JobRef({required this.id, required this.kind});
  final String id;
  final String kind;

  @override
  bool operator ==(Object other) =>
      other is JobRef && other.id == id && other.kind == kind;

  @override
  int get hashCode => Object.hash(id, kind);

  @override
  String toString() => 'JobRef($id, $kind)';
}

/// German label of a job kind for updater messages (the UI has its own l10n
/// map). Unknown kinds get a neutral word — never the raw string.
String jobKindLabel(String kind) => switch (kind) {
      jobKindSystemUpgrade => 'System-Update',
      jobKindEvccUpdate => 'evcc-Update',
      jobKindPackageUpdate => 'Paket-Update',
      jobKindPackageRepair => 'Paket-Reparatur',
      jobKindPiholeUpdate => 'Pi-hole-Update',
      'autoupdate' => 'automatische Updates',
      _ => 'Pi-Job',
    };

/// Hard runtime cap per kind (systemd `RuntimeMaxSec`): a hung payload must
/// not hold the lock — and block every reboot from the app — forever.
String jobRuntimeLimit(String kind) => switch (kind) {
      jobKindSystemUpgrade || jobKindEvccUpdate || jobKindPackageRepair => '6h',
      _ => '2h',
    };

// ---------------------------------------------------------------------------
// Transport: a bootstrap that can never execute a stray password line
// ---------------------------------------------------------------------------

/// The line that separates the (optional) sudo password from the script.
const String jobSentinel = '#PITOOL-BEGIN';

/// Runs under `sudo -S bash -c`. It reads stdin line by line (bash `read`
/// takes pipes byte-wise, so nothing after the sentinel is consumed) and only
/// execs `bash -s` once the sentinel arrives. A password line that sudo did
/// not ask for (NOPASSWD, cached timestamp) lands in `$l` and is dropped —
/// never executed, never echoed. No sentinel at all → exit 97.
const String jobBootstrap =
    r'while IFS= read -r l; do [ "$l" = "#PITOOL-BEGIN" ] && exec bash -s -- "$@"; done; exit 97';

/// Exit code of [jobBootstrap] when the sentinel never came.
const int jobBadHeaderExit = 97;

String _jobCommand(String mode, String id) {
  _checkId(id);
  return "LC_ALL=C sudo -S bash -c '$jobBootstrap' pitool $mode ${shSingleQuote(id)}";
}

/// Starts a job (launcher on stdin, see [buildJobStartStdin]). The id is in
/// argv — it is no secret — so the demo runner can answer without stdin.
String jobStartCommand(String id) => _jobCommand('pitool-job-start', id);

/// Follows a job (follower on stdin, see [buildJobFollowStdin]).
String jobFollowCommand(String id) => _jobCommand('pitool-job-follow', id);

final RegExp _cmdIdRe =
    RegExp(r" pitool pitool-job-(start|follow) '([0-9a-f]{16})'$");

/// The job id in a [jobStartCommand] / [jobFollowCommand], or null.
String? jobIdFromCommand(String command) =>
    _isJobCommand(command) ? _cmdIdRe.firstMatch(command)!.group(2) : null;

bool _isJobCommand(String command) =>
    command.startsWith("LC_ALL=C sudo -S bash -c '$jobBootstrap' pitool ") &&
    _cmdIdRe.hasMatch(command);

bool isJobStartCommand(String command) =>
    _isJobCommand(command) &&
    _cmdIdRe.firstMatch(command)!.group(1) == 'start';

bool isJobFollowCommand(String command) =>
    _isJobCommand(command) &&
    _cmdIdRe.firstMatch(command)!.group(1) == 'follow';

/// Paths and loop timing of the on-Pi scripts. The defaults are production;
/// the bash sandbox tests rebase everything into a temp root and speed up the
/// loops. Every value is validated before it reaches a script.
class JobScriptOptions {
  const JobScriptOptions({
    this.root = '',
    this.path = jobDefaultPath,
    this.pollSeconds = '1',
    this.hbEvery = 15,
    this.startWait = 40,
    this.startSleep = '0.5',
  });

  /// Prefix for every absolute on-Pi path ('' in production).
  final String root;

  /// The wrapper's fixed PATH.
  final String path;

  /// Follower poll interval (`sleep` argument).
  final String pollSeconds;

  /// Follower heartbeat every N polls (stderr).
  final int hbEvery;

  /// Launcher start-wait iterations (× [startSleep]).
  final int startWait;
  final String startSleep;

  String get top => '$root$piToolStateDir';
  String get base => '$root$jobsBaseDir';
  String get lock => '$root$jobLockPath';
  String get status => '$root$jobStatusPath';
  String get runDir => '$root/run';

  static final _rootRe = RegExp(r'^(/[A-Za-z0-9._-]+)*$');
  static final _pathRe = RegExp(r'^[A-Za-z0-9._/:-]+$');
  static final _secondsRe = RegExp(r'^[0-9]{1,4}(\.[0-9]{1,3})?$');

  void validate() {
    if (!_rootRe.hasMatch(root)) {
      throw ArgumentError.value(root, 'root', 'unsicherer Pfad');
    }
    if (!_pathRe.hasMatch(path)) {
      throw ArgumentError.value(path, 'path', 'unsicherer PATH');
    }
    if (!_secondsRe.hasMatch(pollSeconds)) {
      throw ArgumentError.value(pollSeconds, 'pollSeconds');
    }
    if (!_secondsRe.hasMatch(startSleep)) {
      throw ArgumentError.value(startSleep, 'startSleep');
    }
    if (hbEvery < 1 || hbEvery > 1000) {
      throw ArgumentError.value(hbEvery, 'hbEvery');
    }
    if (startWait < 1 || startWait > 10000) {
      throw ArgumentError.value(startWait, 'startWait');
    }
  }
}

String _q(String s) => shSingleQuote(s);

String _stdin(String password, String script) =>
    '${password.isNotEmpty ? '$password\n' : ''}$jobSentinel\n$script';

/// stdin for [jobStartCommand]: the password line (whenever there is a
/// password — no sudo probe: a line sudo does not want is dropped by the
/// bootstrap), the sentinel, then the launcher with [payload] embedded.
String buildJobStartStdin({
  required String password,
  required String id,
  required String kind,
  required String payload,
  JobScriptOptions options = const JobScriptOptions(),
}) =>
    _stdin(
        password,
        buildJobLauncherScript(
            id: id, kind: kind, payload: payload, options: options));

/// stdin for [jobFollowCommand].
String buildJobFollowStdin({
  required String password,
  required String id,
  JobScriptOptions options = const JobScriptOptions(),
}) =>
    _stdin(password, buildJobFollowerScript(id: id, options: options));

/// Wraps a payload body in a function that only the last line calls: a text
/// cut short anywhere is a syntax error, and bash then runs none of it.
String buildJobPayload(String script) => '''
# Pi-Tool job payload. One function, called on the last line only.
pitool_job_payload() {
:
${script.trimRight()}
}
pitool_job_payload "\$@"
''';

final RegExp _b64LineRe =
    RegExp(r"^  local pl_b64='([A-Za-z0-9+/=]*)'$", multiLine: true);
final RegExp _kindLineRe =
    RegExp(r"^  local kind='([a-z0-9-]{1,32})'$", multiLine: true);

/// The payload embedded in a launcher stdin, or null (tests and demo).
String? decodeJobPayload(String stdin) {
  final m = _b64LineRe.firstMatch(stdin);
  if (m == null) return null;
  try {
    return utf8.decode(base64.decode(m.group(1)!));
  } catch (_) {
    return null;
  }
}

/// The job kind embedded in a launcher stdin, or null.
String? jobKindFromStdin(String stdin) => _kindLineRe.firstMatch(stdin)?.group(1);

// ---------------------------------------------------------------------------
// The scripts
// ---------------------------------------------------------------------------

/// Streams the log from [off] on and advances it. Uses the caller's locals
/// (`d`, `off`, `size`) — bash functions see the locals of their callers.
const String _shStream = r'''
pitool_stream() {
  size=$(stat -c %s "$d/log" 2>/dev/null) || return 0
  [[ $size =~ ^[0-9]+$ ]] || return 0
  if [ "$size" -gt "$off" ]; then
    # Exactly the bytes up to the size just read: a line the payload is still
    # writing is sent as far as it got; the rest follows with the next round.
    tail -c +$((off + 1)) "$d/log" | head -c $((size - off))
    off=$size
  fi
}
''';

/// Marks this job `lost` in job.status — only while that line is still about
/// this job and says running (a newer job's line must never be overwritten).
const String _shMarkLost = r'''
pitool_mark_lost() {
  local a b c e g h k
  read -r a b c e g h k <"$st" 2>/dev/null || return 0
  [ "$a" = "$id" ] && [ "$c" = running ] || return 0
  [[ $b =~ ^[a-z0-9-]{1,32}$ ]] || b=unknown
  [[ $g =~ ^[0-9]{1,12}$ ]] || g=0
  [[ $k =~ ^[0-9a-f-]{1,64}$ ]] || k=-
  printf '%s %s lost - %s - %s\n' "$id" "$b" "$g" "$k" >"$st.tmp.$$" &&
    chmod 0644 "$st.tmp.$$" && mv -f "$st.tmp.$$" "$st"
}
''';

/// The follower loop. Control lines RC/LOST go to STDOUT right after the log,
/// so RC can never overtake the last log bytes; the artificial newline in
/// front guarantees they start a line. The heartbeat goes to STDERR: it keeps
/// the app's watchdog fed, and a write into a closed channel ends this
/// follower (SIGPIPE) instead of leaving it behind.
const String _shFollow = r'''
pitool_follow() {
  local d=$1 id=$2 off=0 size n=0 fin rc
  local runrc="$rundir/pi-tool-job-$2.rc"
  while :; do
    fin=0
    { [ -e "$d/rc" ] || [ -e "$runrc" ]; } && fin=1
    pitool_stream
    if [ "$fin" = 1 ]; then
      if [ -e "$d/rc" ]; then rc=$(head -c 16 "$d/rc" 2>/dev/null); else rc=$(head -c 16 "$runrc" 2>/dev/null); fi
      # An empty or garbled rc file (full disk) is a failure, never success.
      [[ $rc =~ ^[0-9]{1,3}$ ]] || rc=255
      printf '\nPITOOL_JOB_RC %s %s\n' "$id" "$rc"
      return 0
    fi
    # The wrapper holds `alive` for its whole life. Getting the lock here
    # means it is gone without leaving an rc: reboot, kill, power loss.
    flock -n -E 75 "$d/alive" true 2>/dev/null
    if [ $? -ne 75 ]; then
      { [ -e "$d/rc" ] || [ -e "$runrc" ]; } && continue # finished just now
      pitool_stream
      pitool_mark_lost
      printf '\nPITOOL_JOB_LOST %s\n' "$id"
      return 0
    fi
    n=$((n + 1))
    if [ $((n % hb)) -eq 0 ]; then printf 'PITOOL_JOB_HB %s\n' "$id" >&2; fi
    sleep "$poll"
  done
}
''';

/// BUSY line for this launcher: its own id first (binds the line to this
/// run), then the running job's id/kind/start from job.status — validated,
/// `-` when unknown.
const String _shBusyLine = r'''
pitool_busy_line() {
  local bid=- bkind=- bstart=- a b c e g h k
  if read -r a b c e g h k <"$st" 2>/dev/null; then
    [[ $a =~ ^[0-9a-f]{16}$ ]] && bid=$a
    [[ $b =~ ^[a-z0-9-]{1,32}$ ]] && bkind=$b
    [[ $g =~ ^[0-9]{1,12}$ ]] && bstart=$g
  fi
  printf 'PITOOL_JOB_BUSY %s %s %s %s\n' "$id" "$bid" "$bkind" "$bstart"
}
''';

/// Keeps the newest 10 job directories. Only names that are job ids, and
/// never a directory whose `alive` lock is held (a running job).
const String _shCleanup = r'''
pitool_cleanup() {
  local n=0 dd name
  while IFS= read -r dd; do
    dd=${dd%/}
    name=${dd##*/}
    [[ $name =~ ^[0-9a-f]{16}$ ]] || continue
    n=$((n + 1))
    [ "$n" -le 10 ] && continue
    if [ -e "$dd/alive" ]; then
      flock -n -E 75 "$dd/alive" true 2>/dev/null || continue
    fi
    rm -rf -- "$dd"
  done < <(ls -1dt -- "$base"/*/ 2>/dev/null)
}
''';

/// Waits for `started` (the wrapper runs) or `busy` (another job holds the
/// lock). Counts iterations — never wall-clock differences: a Pi without RTC
/// may jump in time right after boot.
const String _shWaitStart = r'''
pitool_wait_start() {
  local n=0
  while [ "$n" -lt "$startwait" ]; do
    { [ -e "$d/started" ] || [ -e "$d/busy" ]; } && return 0
    sleep "$startsleep"
    n=$((n + 1))
    if [ $((n % 10)) -eq 0 ]; then printf 'PITOOL_JOB_HB %s\n' "$id" >&2; fi
  done
  [ -e "$d/started" ] || [ -e "$d/busy" ]
}
''';

/// The wrapper (run.sh). Constant content for a given [options] — everything
/// job-specific comes from the files next to it.
String buildJobWrapperScript(
    {JobScriptOptions options = const JobScriptOptions()}) {
  options.validate();
  final o = options;
  return '''
#!/bin/bash
# Pi-Tool job wrapper. Started as root by systemd-run (or setsid -f); constant
# content — everything job-specific is in the files next to it.
umask 077
d=\$(cd "\$(dirname "\$0")" && pwd) || exit 97
base=${_q(o.base)}
[ -n "\$d" ] && [ "\${d%/*}" = "\$base" ] || exit 97
id=\${d##*/}
[[ \$id =~ ^[0-9a-f]{16}\$ ]] || exit 97
st=${_q(o.status)}
rundir=${_q(o.runDir)}
# Atomic claim: exactly one side renames payload.sh — this wrapper, or the
# launcher giving up on its start timeout. Losing means: do nothing at all.
mv "\$d/payload.sh" "\$d/payload.run" 2>/dev/null || exit 0
exec </dev/null >>"\$d/log" 2>&1 || exit 74
# Global exclusivity on fd 9. -w 5, not -n: the launcher and the reboot guard
# probe this lock for a moment, and that must not look like a running job.
exec 9>"\$base/lock" || exit 74
if ! flock -w 5 9; then : >"\$d/busy"; exit 0; fi
# Per-job liveness on fd 8, held for this wrapper's life: a follower that can
# take it knows the wrapper is gone (reboot, kill) without an rc.
exec 8>"\$d/alive" || exit 74
flock -w 5 8 || exit 74
cd / || exit 74
export HOME=/root USER=root LOGNAME=root LC_ALL=C \\
  PATH=${_q(o.path)} \\
  DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \\
  NEEDRESTART_MODE=l UCF_FORCE_CONFFOLD=1
kind=\$(cat "\$d/kind" 2>/dev/null)
[[ \$kind =~ ^[a-z0-9-]{1,32}\$ ]] || kind=unknown
boot=\$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
[[ \$boot =~ ^[0-9a-f-]{1,64}\$ ]] || boot=-
# job.status: world-readable (detection reads it without sudo), written
# atomically so a reader never sees half a line.
status() { printf '%s\\n' "\$*" >"\$st.tmp.\$\$" && chmod 0644 "\$st.tmp.\$\$" && mv -f "\$st.tmp.\$\$" "\$st"; }
start=\$(date +%s)
printf '%s %s\\n' "\$start" "\$boot" >"\$d/started" || exit 74
status "\$id \$kind running - \$start - \$boot"
# systemd stops the unit with SIGTERM to this process only (KillMode=mixed):
# note it, and let the payload finish instead of leaving dpkg half-done.
trap 'echo "Pi-Tool: Stopp angefordert – der Job läuft zu Ende."' TERM
# The payload gets umask 022 (installers create apt keyrings and sources that
# _apt and non-root apt must read) and NOT fds 8/9: a process it leaves behind
# must neither keep this job "alive" nor hold the global lock.
umask 022
bash "\$d/payload.run" 8>&- 9>&-
rc=\$?
case "\$rc" in ''|*[!0-9]*) rc=255 ;; esac
# rc via tmp + rename; on a full or read-only card into tmpfs instead.
{ printf '%s\\n' "\$rc" >"\$d/rc.tmp" && [ -s "\$d/rc.tmp" ] && mv -f "\$d/rc.tmp" "\$d/rc"; } ||
  printf '%s\\n' "\$rc" >"\$rundir/pi-tool-job-\$id.rc" 2>/dev/null
sync 2>/dev/null
status "\$id \$kind done \$rc \$start \$(date +%s) \$boot"
# Always 0 once started: the outcome is in the files, and no failed unit
# lingers in systemd.
exit 0
''';
}

/// The launcher (mode `pitool-job-start <id>`). See SPEC v2 §4.1.
String buildJobLauncherScript({
  required String id,
  required String kind,
  required String payload,
  JobScriptOptions options = const JobScriptOptions(),
}) {
  _checkId(id);
  _checkKind(kind);
  options.validate();
  final o = options;
  final bytes = utf8.encode(payload);
  final wrapper = buildJobWrapperScript(options: o);
  return '''
# Pi-Tool job launcher (pitool-job-start). Every part is a function and the
# only call is the last line: bash parses the whole text before anything
# runs, so a transfer cut short is a syntax error and executes nothing.
$_shStream$_shMarkLost$_shFollow$_shBusyLine$_shCleanup$_shWaitStart
pitool_job_main() {
  local id=${_q(id)}
  local kind=${_q(kind)}
  local pl_len=${bytes.length}
  local pl_b64=${_q(base64.encode(bytes))}
  local limit=${_q(jobRuntimeLimit(kind))}
  local top=${_q(o.top)} base=${_q(o.base)} st=${_q(o.status)} rundir=${_q(o.runDir)}
  local poll=${_q(o.pollSeconds)} hb=${o.hbEvery} startwait=${o.startWait} startsleep=${_q(o.startSleep)}
  local lock="\$base/lock" d="\$base/\$id" unit="pi-tool-job-\$id" via=setsid f
  # From here on nothing may read the rest of this script (or a stray
  # password line) from stdin: every child gets /dev/null.
  exec </dev/null
  umask 077
  export LC_ALL=C
  if [ "\${1:-}" != pitool-job-start ] || [ "\${2:-}" != "\$id" ]; then
    echo 'Pi-Tool: Aufruf passt nicht zum Job-Skript.' >&2
    return 2
  fi
  if ! [[ \$id =~ ^[0-9a-f]{16}\$ && \$kind =~ ^[a-z0-9-]{1,32}\$ ]]; then
    echo 'Pi-Tool: ungültige Job-Kennung.' >&2
    return 2
  fi
  if ! install -d -m 0755 "\$top" || ! install -d -m 0700 "\$base"; then
    printf 'PITOOL_JOB_NOSTART %s setup\\n' "\$id"
    return 1
  fi
  if [ ! -e "\$lock" ] && ! : >"\$lock"; then
    printf 'PITOOL_JOB_NOSTART %s setup\\n' "\$id"
    return 1
  fi
  # Busy? Checked before anything of this job is written.
  if systemctl is-active --quiet pi-tool-autoupdate.service 2>/dev/null; then
    printf 'PITOOL_JOB_BUSY %s - autoupdate -\\n' "\$id"
    return 0
  fi
  flock -n -E 75 "\$lock" true
  f=\$?
  if [ "\$f" -eq 75 ]; then
    pitool_busy_line
    return 0
  fi
  if [ "\$f" -ne 0 ]; then
    echo "Pi-Tool: Job-Sperre nicht prüfbar (flock Exit \$f)." >&2
    printf 'PITOOL_JOB_NOSTART %s lock\\n' "\$id"
    return 1
  fi
  pitool_cleanup
  if ! mkdir -m 0700 "\$d" 2>/dev/null; then
    printf 'PITOOL_JOB_NOSTART %s exists\\n' "\$id"
    return 1
  fi
  if ! { printf '%s\\n' "\$kind" >"\$d/kind" && install -m 0600 /dev/null "\$d/log"; }; then
    rm -rf -- "\$d"
    printf 'PITOOL_JOB_NOSTART %s setup\\n' "\$id"
    return 1
  fi
  # The payload travels base64-encoded inside this (already fully parsed)
  # script; its byte length proves it was written completely.
  if ! printf '%s' "\$pl_b64" | base64 -d >"\$d/payload.tmp" 2>/dev/null ||
    [ "\$(stat -c %s "\$d/payload.tmp" 2>/dev/null)" != "\$pl_len" ]; then
    rm -rf -- "\$d"
    printf 'PITOOL_JOB_NOSTART %s payload\\n' "\$id"
    return 0
  fi
  if ! mv "\$d/payload.tmp" "\$d/payload.sh"; then
    rm -rf -- "\$d"
    printf 'PITOOL_JOB_NOSTART %s setup\\n' "\$id"
    return 1
  fi
  cat >"\$d/run.sh" <<'PITOOL_RUNSH'
$wrapper
PITOOL_RUNSH
  if ! chmod 0700 "\$d/run.sh"; then
    rm -rf -- "\$d"
    printf 'PITOOL_JOB_NOSTART %s setup\\n' "\$id"
    return 1
  fi
  # Start: a transient systemd unit survives this SSH session, the app and
  # the follower. If systemd-run reports an error but PID 1 did create the
  # unit (D-Bus timeout under load), it starts anyway — never start twice.
  if [ -d "\$rundir/systemd/system" ] && command -v systemd-run >/dev/null 2>&1; then
    if systemd-run --quiet --unit="\$unit" --description="Pi-Tool job \$kind" \\
      -p KillMode=mixed -p TimeoutStopSec=30min -p IgnoreSIGPIPE=no \\
      -p RuntimeMaxSec="\$limit" /bin/bash "\$d/run.sh" </dev/null >&2; then
      via=systemd
    elif [ "\$(systemctl show -p LoadState --value "\$unit.service" 2>/dev/null)" = loaded ]; then
      via=systemd
    fi
  fi
  if [ "\$via" = setsid ]; then
    setsid -f /bin/bash "\$d/run.sh" </dev/null >/dev/null 2>&1
  fi
  if ! pitool_wait_start; then
    # Nothing yet. Take the payload back: if the rename works, the wrapper can
    # never run it, and "nothing was changed" is true.
    if mv "\$d/payload.sh" "\$d/payload.dead" 2>/dev/null; then
      rm -rf -- "\$d"
      printf 'PITOOL_JOB_NOSTART %s timeout\\n' "\$id"
      return 0
    fi
    # The wrapper claimed it first — it is on its way; give it more time.
    pitool_wait_start
  fi
  if [ ! -e "\$d/started" ]; then
    if [ -e "\$d/busy" ]; then
      pitool_busy_line
      rm -rf -- "\$d"
      return 0
    fi
    # No control line: the app reports "start unclear", never success.
    echo 'Pi-Tool: Der Job meldet sich nicht – ob er startet, ist unklar.' >&2
    return 3
  fi
  printf 'PITOOL_JOB_STARTED %s %s\\n' "\$id" "\$kind"
  pitool_follow "\$d" "\$id"
}
pitool_job_main "\$@"
''';
}

/// The follower (mode `pitool-job-follow <id>`). See SPEC v2 §4.3.
String buildJobFollowerScript({
  required String id,
  JobScriptOptions options = const JobScriptOptions(),
}) {
  _checkId(id);
  options.validate();
  final o = options;
  return '''
# Pi-Tool job follower (pitool-job-follow). One function per part, called on
# the last line only — a truncated transfer runs nothing.
$_shStream$_shMarkLost$_shFollow
pitool_job_main() {
  local id=${_q(id)}
  local st=${_q(o.status)} base=${_q(o.base)} rundir=${_q(o.runDir)}
  local poll=${_q(o.pollSeconds)} hb=${o.hbEvery}
  local d kind
  exec </dev/null
  umask 077
  export LC_ALL=C
  if [ "\${1:-}" != pitool-job-follow ] || [ "\${2:-}" != "\$id" ]; then
    echo 'Pi-Tool: Aufruf passt nicht zum Job-Skript.' >&2
    return 2
  fi
  [[ \$id =~ ^[0-9a-f]{16}\$ ]] || return 2
  d="\$base/\$id"
  if [ ! -d "\$d" ] || [ ! -e "\$d/started" ]; then
    printf 'PITOOL_JOB_UNKNOWN %s\\n' "\$id"
    return 0
  fi
  kind=\$(cat "\$d/kind" 2>/dev/null)
  [[ \$kind =~ ^[a-z0-9-]{1,32}\$ ]] || kind=unknown
  printf 'PITOOL_JOB_STARTED %s %s\\n' "\$id" "\$kind"
  pitool_follow "\$d" "\$id"
}
pitool_job_main "\$@"
''';
}

// ---------------------------------------------------------------------------
// Payloads (Tier 1)
// ---------------------------------------------------------------------------

/// apt options for every package-changing call: no pty painting, wait for a
/// held lock (apt ≥ 1.9), and never stop at a conffile question.
const String _shAptOpts = r'''
O=(-o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
''';

/// Buster's apt 1.8 ignores DPkg::Lock::Timeout, so wait for the daily apt
/// run / unattended-upgrades ourselves — bounded (10 min), and only where
/// fuser exists.
const String _shWaitLocks = r'''
pitool_wait_apt_locks() {
  command -v fuser >/dev/null 2>&1 || return 0
  local i=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    if [ "$i" -eq 0 ]; then
      echo 'Pi-Tool: Eine andere Paketverwaltung läuft gerade (z. B. automatische Updates) – warte bis zu 10 Minuten …'
    fi
    i=$((i + 1))
    if [ "$i" -ge 120 ]; then
      echo 'Pi-Tool: Die Paketverwaltung ist nach 10 Minuten noch belegt – versuche es trotzdem.'
      return 0
    fi
    sleep 5
  done
}
''';

/// Finishes what a killed apt/dpkg run left behind: configure, fix-broken
/// (unpacked packages whose new dependencies never arrived), configure again.
const String _shRepair = r'''
pitool_repair() {
  echo 'Pi-Tool: Schließe unterbrochene Paketinstallationen ab …'
  pitool_wait_apt_locks
  dpkg --force-confdef --force-confold --configure -a || true
  pitool_wait_apt_locks
  apt-get "${O[@]}" -f install -y || true
  pitool_wait_apt_locks
  dpkg --force-confdef --force-confold --configure -a || true
}
''';

/// Refreshes the package lists. Tolerant (one dead third-party repo must not
/// block the upgrade) but reported: the app warns when the lists are partial.
const String _shUpdateLists = r'''
pitool_update_lists() {
  echo 'Pi-Tool: Lade die Paketlisten …'
  pitool_wait_apt_locks
  apt-get -o Acquire::AllowReleaseInfoChange::Suite=true -o Acquire::Retries=3 update -qq
  echo "PITOOL_APT_UPDATE_RC=$?"
}
''';

String _aptPrelude({bool eol = true, bool update = true}) => [
      if (eol) ...[
        '# Dead EOL package sources moved to the archive first (eol_sources.dart).',
        eolSourcesFixScript.trim(),
      ],
      _shAptOpts.trim(),
      _shWaitLocks.trim(),
      _shRepair.trim(),
      if (update) _shUpdateLists.trim(),
    ].join('\n');

/// `system-upgrade`: EOL fix, repair, lists, `apt-get full-upgrade`.
String buildSystemUpgradePayload() => buildJobPayload('''
${_aptPrelude()}
pitool_repair
pitool_update_lists
pitool_wait_apt_locks
echo 'Pi-Tool: Installiere alle Updates (apt-get full-upgrade) …'
echo $jobUpgradeMarker
apt-get "\${O[@]}" full-upgrade -y
''');

/// `evcc-update`: like the system upgrade, but either only evcc
/// (`install --only-upgrade`, never pulls in a missing package) or the whole
/// system ([fullUpgrade]). Afterwards the service state and the installed
/// version — same query as [versionQuery] — so the app can verify, also when
/// it only re-follows later. Exits with the apt exit code.
String buildEvccUpdatePayload({required bool fullUpgrade}) {
  final upgrade = fullUpgrade
      ? '''
echo 'Pi-Tool: Installiere alle Updates (apt-get full-upgrade) …'
echo $jobUpgradeMarker
apt-get "\${O[@]}" full-upgrade -y'''
      : '''
echo 'Pi-Tool: Aktualisiere evcc …'
echo $jobUpgradeMarker
apt-get "\${O[@]}" install --only-upgrade -y evcc''';
  return buildJobPayload('''
${_aptPrelude()}
pitool_repair
pitool_update_lists
pitool_wait_apt_locks
$upgrade
rc=\$?
sleep 2
echo "PITOOL_EVCC_ACTIVE=\$(systemctl is-active evcc 2>/dev/null)"
echo "PITOOL_EVCC_VERSION=\$($versionQuery 2>/dev/null)"
exit "\$rc"
''');
}

final RegExp _pkgRe = RegExp(r'^[a-z0-9][a-z0-9+.-]{0,99}$');

/// `package-update`: one apt package, `--only-upgrade` (a missing package is
/// never installed). [package] comes from the app's own descriptors; it is
/// validated as a Debian package name and quoted anyway.
String buildPackageUpdatePayload(String package) {
  if (!_pkgRe.hasMatch(package)) {
    throw ArgumentError.value(package, 'package', 'kein Paketname');
  }
  final p = _q(package);
  return buildJobPayload('''
${_aptPrelude()}
printf 'PITOOL_PACKAGE=%s\\n' $p
pitool_repair
pitool_update_lists
pitool_wait_apt_locks
printf 'Pi-Tool: Aktualisiere %s …\\n' $p
echo $jobUpgradeMarker
apt-get "\${O[@]}" install --only-upgrade -y $p
''');
}

/// `package-repair`: the repair chain with its exit code — non-zero when the
/// fix-broken step or the final configure failed.
String buildPackageRepairPayload() => buildJobPayload('''
${_aptPrelude(eol: false, update: false)}
echo 'Pi-Tool: Repariere den Paketzustand …'
pitool_wait_apt_locks
dpkg --force-confdef --force-confold --configure -a || true
pitool_wait_apt_locks
apt-get "\${O[@]}" -f install -y
f=\$?
pitool_wait_apt_locks
dpkg --force-confdef --force-confold --configure -a
c=\$?
if [ "\$c" -ne 0 ]; then exit "\$c"; fi
exit "\$f"
''');

/// `pihole-update`: `pihole -up`, its exit code.
String buildPiholeUpdatePayload() => buildJobPayload('''
echo 'Pi-Tool: Aktualisiere Pi-hole (pihole -up) …'
pihole -up
''');

// ---------------------------------------------------------------------------
// Detection: job.status
// ---------------------------------------------------------------------------

/// Read-only, no sudo: job.status (0644) plus the current boot id.
const String jobStatusProbe = 'cat $jobStatusPath 2>/dev/null; '
    'echo "BOOT \$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"';

enum PiJobState { running, done, lost, interrupted }

/// The latest job as job.status tells it. Transient — never persisted.
class PiJobStatus {
  const PiJobStatus({
    required this.id,
    required this.kind,
    required this.state,
    this.rc,
    required this.start,
    this.end,
  });

  final String id;
  final String kind;
  final PiJobState state;
  final int? rc;
  final DateTime start;
  final DateTime? end;

  JobRef get ref => JobRef(id: id, kind: kind);
}

final RegExp _bootRe = RegExp(r'^[0-9a-f-]{1,64}$');
final RegExp _epochRe = RegExp(r'^[0-9]{1,12}$');
final RegExp _rcRe = RegExp(r'^[0-9]{1,3}$');

DateTime _epoch(String s) =>
    DateTime.fromMillisecondsSinceEpoch(int.parse(s) * 1000);

/// Parses the JOB detection section. `running` from a different boot than
/// the current one means the Pi rebooted mid-job → [PiJobState.interrupted].
/// [currentBootId] defaults to the section's `BOOT` line. Missing file or any
/// malformed field → null.
PiJobStatus? parseJobStatus(String section, {String? currentBootId}) {
  String? boot = currentBootId;
  String? line;
  for (final raw in section.split('\n')) {
    final t = raw.trim();
    if (t.isEmpty) continue;
    if (t == 'BOOT' || t.startsWith('BOOT ')) {
      boot ??= t.substring(4).trim();
      continue;
    }
    line ??= t;
  }
  if (line == null) return null;
  final f = line.split(' ');
  if (f.length != 7) return null;
  final [id, kind, state, rc, start, end, jobBoot] = f;
  if (!isValidJobId(id) || !isValidJobKind(kind)) return null;
  if (!_epochRe.hasMatch(start)) return null;
  if (!_bootRe.hasMatch(jobBoot) && jobBoot != '-') return null;
  switch (state) {
    case 'running':
    case 'lost':
      if (rc != '-' || end != '-') return null;
      final rebooted = state == 'running' &&
          boot != null &&
          _bootRe.hasMatch(boot) &&
          jobBoot != '-' &&
          jobBoot != boot;
      return PiJobStatus(
        id: id,
        kind: kind,
        state: rebooted
            ? PiJobState.interrupted
            : state == 'running'
                ? PiJobState.running
                : PiJobState.lost,
        start: _epoch(start),
      );
    case 'done':
      if (!_rcRe.hasMatch(rc) || !_epochRe.hasMatch(end)) return null;
      return PiJobStatus(
        id: id,
        kind: kind,
        state: PiJobState.done,
        rc: int.parse(rc),
        start: _epoch(start),
        end: _epoch(end),
      );
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Classification of a launcher / follower run
// ---------------------------------------------------------------------------

/// What one launcher or follower run tells about the job.
sealed class JobRun {
  const JobRun();
}

/// The job ended with exit code [rc]; [log] is its complete output.
class JobRunRc extends JobRun {
  const JobRunRc(this.rc, this.log, {this.kind});
  final int rc;
  final String log;
  final String? kind;
}

/// The wrapper vanished without an rc (reboot, kill, power loss).
class JobRunLost extends JobRun {
  const JobRunLost(this.log, {this.kind});
  final String log;
  final String? kind;
}

/// Another job (or the on-Pi auto-update) holds the lock; nothing started.
class JobRunBusy extends JobRun {
  const JobRunBusy({this.otherId, this.kind, this.since});
  final String? otherId;
  final String? kind;
  final DateTime? since;
}

/// The launcher did not start the job; nothing was changed.
class JobRunNoStart extends JobRun {
  const JobRunNoStart([this.reason]);
  final String? reason;
}

/// The follower found no such (started) job.
class JobRunUnknown extends JobRun {
  const JobRunUnknown();
}

/// sudo rejected the password; nothing ran.
class JobRunSudoFailure extends JobRun {
  const JobRunSudoFailure();
}

/// The bootstrap never saw the sentinel (exit 97); nothing ran.
class JobRunBadHeader extends JobRun {
  const JobRunBadHeader();
}

/// No terminal line: the connection ended first. [started] says whether the
/// job confirmed its start; [log] is what arrived so far.
class JobRunDetached extends JobRun {
  const JobRunDetached({required this.started, this.log = '', this.kind});
  final bool started;
  final String log;
  final String? kind;
}

final RegExp _ctlRe = RegExp(
    r'^PITOOL_JOB_(STARTED|RC|LOST|UNKNOWN|BUSY|NOSTART|HB) (\S+)(?: (.*))?$');

/// Whether [line] is one of this job's control lines (to keep them out of
/// the live log).
bool isJobControlLine(String line, String id) {
  final m = _ctlRe.firstMatch(line);
  return m != null && m.group(2) == id;
}

/// Removes this job's heartbeat lines (stderr) from a merged output stream.
String stripJobHeartbeats(String text, String id) =>
    text.split('\n').where((l) => l != 'PITOOL_JOB_HB $id').join('\n');

/// Classifies a launcher/follower run. Only lines that are exactly a control
/// line with THIS job's id count; the RC must be 1–3 digits (anything else is
/// 255 — a failure, never success); the last terminal line wins. The log is
/// everything between the STARTED line and the terminal line, minus the one
/// artificial newline in front of it — payload output is never filtered
/// otherwise. No terminal line means detached: exit 0 without RC is never
/// success.
JobRun classifyJobRun({
  required String stdout,
  required String stderr,
  required int? exitCode,
  required String id,
}) {
  int? logStart;
  String? kind;
  int? termStart;
  JobRun Function(String log)? term;
  JobRun? pre;
  var pos = 0;
  while (pos < stdout.length) {
    final nl = stdout.indexOf('\n', pos);
    final end = nl == -1 ? stdout.length : nl;
    final line = stdout.substring(pos, end);
    final lineStart = pos;
    pos = nl == -1 ? stdout.length : nl + 1;
    if (!line.startsWith('PITOOL_JOB_')) continue;
    final m = _ctlRe.firstMatch(line);
    if (m == null || m.group(2) != id) continue;
    final rest = m.group(3);
    switch (m.group(1)) {
      case 'STARTED':
        if (logStart == null) {
          logStart = pos;
          final k = (rest ?? '').split(' ').first;
          kind = isValidJobKind(k) ? k : null;
        }
      case 'RC':
        if (logStart == null || lineStart >= logStart) {
          final rc = rest != null && _rcRe.hasMatch(rest) ? int.parse(rest) : 255;
          termStart = lineStart;
          term = (log) => JobRunRc(rc, log, kind: kind);
        }
      case 'LOST':
        if (logStart == null || lineStart >= logStart) {
          termStart = lineStart;
          term = (log) => JobRunLost(log, kind: kind);
        }
      case 'UNKNOWN':
        if (logStart == null) {
          termStart = lineStart;
          term = (_) => const JobRunUnknown();
        }
      case 'BUSY':
        if (logStart == null) {
          final f = (rest ?? '').split(' ');
          String? at(int i) => i < f.length ? f[i] : null;
          final other = at(0), k = at(1), s = at(2);
          pre = JobRunBusy(
            otherId: other != null && isValidJobId(other) ? other : null,
            kind: k != null && isValidJobKind(k) ? k : null,
            since: s != null && _epochRe.hasMatch(s) ? _epoch(s) : null,
          );
        }
      case 'NOSTART':
        if (logStart == null) pre = JobRunNoStart(rest);
    }
  }

  final t = term;
  final ts = termStart;
  if (t != null && ts != null) {
    final from = logStart ?? 0;
    var to = ts;
    // The follower's artificial newline in front of RC/LOST.
    if (to > from && stdout.codeUnitAt(to - 1) == 0x0A) to--;
    return t(to > from ? stdout.substring(from, to) : '');
  }
  if (pre != null) return pre;
  if (logStart == null) {
    if (isSudoPasswordFailure('$stdout\n$stderr')) {
      return const JobRunSudoFailure();
    }
    if (exitCode == jobBadHeaderExit) return const JobRunBadHeader();
  }
  return JobRunDetached(
    started: logStart != null,
    log: logStart != null ? stdout.substring(logStart) : '',
    kind: kind,
  );
}

// ---------------------------------------------------------------------------
// Evaluation — shared by the live path and a later re-follow
// ---------------------------------------------------------------------------

/// Message for a Pi whose dpkg run was killed half-way (see
/// [isDpkgInterrupted]).
const String dpkgInterruptedMessage =
    'Auf dem Pi steckt ein abgebrochener dpkg-Lauf fest — solange der nicht '
    'aufgeräumt ist, schlägt JEDE Installation fehl, nicht nur diese. '
    'System-Karte → ⋮ → „Paketzustand reparieren" führt '
    '`dpkg --configure -a` aus; danach klappt das Update.';

/// The cause of a failed apt/dpkg run in words the user can act on, or null
/// when the output shows none of the known ones (then: "Details im Log").
String? aptFailureCause(String output) {
  if (isDpkgInterrupted(output)) return dpkgInterruptedMessage;
  final dead = parseDeadAptSource(output);
  if (dead != null) {
    return 'die Paketquelle „$dead" gibt es auf dem Server nicht mehr. '
        'Solange sie eingetragen ist, scheitert jede Installation auf diesem '
        'Pi — bitte in /etc/apt/sources.list bzw. /etc/apt/sources.list.d/ '
        'entfernen oder korrigieren.';
  }
  if (isAptLocked(output)) {
    return 'auf dem Pi läuft gerade eine andere Paketinstallation (z. B. die '
        'automatischen Updates). In ein paar Minuten erneut versuchen.';
  }
  return null;
}

/// The verdict on a finished job.
class JobOutcome {
  const JobOutcome({
    required this.kind,
    required this.success,
    required this.message,
    this.listsIncomplete = false,
    this.evccActive,
    this.evccVersion,
    this.alreadyNewest = false,
  });

  final String kind;
  final bool success;

  /// German, for the status line.
  final String message;

  /// `apt-get update` failed for at least one source: the upgrade worked
  /// with partly outdated lists.
  final bool listsIncomplete;

  /// evcc-update only: service active afterwards / installed version.
  final bool? evccActive;
  final String? evccVersion;

  /// The upgrade command itself reported nothing to do.
  final bool alreadyNewest;
}

/// Value of the LAST `KEY=value` line, or null.
String? _marker(String log, String key) {
  String? v;
  for (final l in log.split('\n')) {
    if (l.startsWith('$key=')) v = l.substring(key.length + 1).trim();
  }
  return v;
}

/// The output after the last [jobUpgradeMarker] line (the whole log without).
String _upgradeSection(String log) {
  final lines = log.split('\n');
  final i = lines.lastIndexOf(jobUpgradeMarker);
  return i < 0 ? log : lines.sublist(i + 1).join('\n');
}

/// Evaluates a job that ended with [rc] from its full [log], with the same
/// parsers as the foreground actions. Used for the live run AND for a later
/// re-follow, so both report the same outcome for the same log.
JobOutcome evaluateJob(String kind, int rc, String log) {
  final updateRc = _marker(log, 'PITOOL_APT_UPDATE_RC');
  final listsIncomplete = updateRc != null && updateRc != '0';
  final upgrade = _upgradeSection(log);
  final alreadyNewest = isAlreadyNewest(upgrade);

  JobOutcome fail(String prefix, {bool? evccActive, String? evccVersion}) {
    final cause = aptFailureCause(upgrade) ?? aptFailureCause(log);
    return JobOutcome(
      kind: kind,
      success: false,
      message: cause != null
          ? '$prefix — $cause'
          : '$prefix (Exit $rc). Details im Log.',
      listsIncomplete: listsIncomplete,
      evccActive: evccActive,
      evccVersion: evccVersion,
      alreadyNewest: alreadyNewest,
    );
  }

  JobOutcome ok(String message, {bool? evccActive, String? evccVersion}) =>
      JobOutcome(
        kind: kind,
        success: true,
        message: message,
        listsIncomplete: listsIncomplete,
        evccActive: evccActive,
        evccVersion: evccVersion,
        alreadyNewest: alreadyNewest,
      );

  const listsNote =
      ' Nicht alle Paketlisten ließen sich laden – Details im Log.';

  switch (kind) {
    case jobKindSystemUpgrade:
      if (rc != 0) return fail('System-Upgrade fehlgeschlagen');
      return ok(listsIncomplete
          ? 'System aktualisiert – aber nicht alle Paketlisten ließen sich '
              'laden (Details im Log).'
          : 'System aktualisiert.');
    case jobKindEvccUpdate:
      final active = _marker(log, 'PITOOL_EVCC_ACTIVE') == 'active';
      final version =
          parseInstalledVersion(_marker(log, 'PITOOL_EVCC_VERSION') ?? '');
      if (rc != 0) {
        return fail('evcc-Update fehlgeschlagen',
            evccActive: active, evccVersion: version);
      }
      if (!active) {
        return JobOutcome(
          kind: kind,
          success: false,
          message: 'evcc-Dienst ist nach dem Update nicht aktiv '
              '(systemctl is-active ≠ active).',
          listsIncomplete: listsIncomplete,
          evccActive: false,
          evccVersion: version,
          alreadyNewest: alreadyNewest,
        );
      }
      return ok(
          'evcc ${version ?? '(Version unbekannt)'} installiert, Dienst aktiv.'
          '${listsIncomplete ? listsNote : ''}',
          evccActive: true,
          evccVersion: version);
    case jobKindPackageUpdate:
      final pkg = _marker(log, 'PITOOL_PACKAGE');
      final name = pkg != null && pkg.isNotEmpty ? pkg : 'Paket';
      if (rc != 0) return fail('$name-Update fehlgeschlagen');
      return ok('$name ist aktuell.${listsIncomplete ? listsNote : ''}');
    case jobKindPackageRepair:
      if (rc != 0) return fail('Reparatur fehlgeschlagen');
      return ok('Paketzustand repariert.');
    case jobKindPiholeUpdate:
      if (rc != 0) return fail('Pi-hole-Update fehlgeschlagen');
      // As before in the foreground: pihole -up runs apt itself, and a dpkg
      // left half-done makes it "succeed" without updating anything.
      if (isDpkgInterrupted(log)) {
        return JobOutcome(
            kind: kind, success: false, message: dpkgInterruptedMessage);
      }
      return ok('Pi-hole ist aktuell.');
    default:
      if (rc != 0) return fail('Pi-Job fehlgeschlagen');
      return ok('Pi-Job abgeschlossen.');
  }
}
