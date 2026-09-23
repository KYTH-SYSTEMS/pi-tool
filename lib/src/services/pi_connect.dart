/// Raspberry Pi Connect (official remote-access service) as a managed service.
/// Pure command strings + parsers; SSH orchestration is wired in
/// evcc_updater.dart. Needs Raspberry Pi OS Bookworm (Debian 12) or newer.
///
/// NOTE: the headless/over-SSH behaviour (linger, XDG_RUNTIME_DIR, the exact
/// `rpi-connect status` text) is not covered by the official docs — these are
/// built defensively and want an on-device check.
library;

import '../commands.dart' show shSingleQuote;

/// Pi Connect needs Raspberry Pi OS **Bookworm** (Debian 12) or newer. Parses
/// VERSION_ID from /etc/os-release; fail-safe (unknown → not compatible).
bool isPiConnectCompatible(String osRelease) {
  final m = RegExp(r'VERSION_ID="?(\d+)').firstMatch(osRelease);
  if (m == null) return false;
  return (int.tryParse(m.group(1)!) ?? 0) >= 12;
}

// rpi-connect is a USER service; over SSH it must reach the user dbus, so set
// XDG_RUNTIME_DIR. Run as the login user (NOT sudo).
const String _env = 'XDG_RUNTIME_DIR=/run/user/\$(id -u)';

const String piConnectStatusCommand = '$_env rpi-connect status 2>&1';
const String piConnectOnCommand = '$_env rpi-connect on 2>&1';
const String piConnectOffCommand = '$_env rpi-connect off 2>&1';
const String piConnectSignoutCommand = '$_env rpi-connect signout 2>&1';

/// `rpi-connect signin` prints the verify URL then keeps polling until you
/// complete it in the browser. Run it DETACHED (setsid + &) so the SSH call
/// doesn't hang, wait briefly for the URL, then print the log to read it out.
const String piConnectSigninCommand =
    "$_env sh -c 'setsid rpi-connect signin >/tmp/pi-tool-signin 2>&1 & "
    "sleep 4; cat /tmp/pi-tool-signin 2>/dev/null'";

/// Written by [piConnectInstallScript] only when it switched linger on itself
/// (not Imager or the user); one user name per line. The full uninstall
/// switches linger off only for the users listed here.
const String piConnectLingerMarker = '/var/lib/pi-tool/piconnect-linger';

/// Root script: installs the headless (lite) variant and enables linger so the
/// user service keeps running without an active login session.
const String piConnectInstallScript = '''
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=120 update </dev/null
apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Use-Pty=0 install -y rpi-connect-lite </dev/null
u="\${SUDO_USER:-}"
[ -n "\$u" ] || u="\$(logname 2>/dev/null || true)"
if [ -n "\$u" ] && [ ! -e "/var/lib/systemd/linger/\$u" ]; then
  if loginctl enable-linger "\$u" </dev/null 2>/dev/null; then
    mkdir -p /var/lib/pi-tool
    grep -qsxF -- "\$u" $piConnectLingerMarker || printf '%s\\n' "\$u" >> $piConnectLingerMarker
  fi
fi
echo PICONNECT_INSTALLED
''';

/// Last line of [buildPiConnectUninstallScript], printed only on success.
const String piConnectRemovedMarker = 'PICONNECT_REMOVED_OK';

/// Root script that uninstalls Pi Connect for the SSH login [user] (whose
/// user systemd runs rpi-connectd). Handles rpi-connect-lite (what the app
/// installs) and rpi-connect (preinstalled on Desktop/Full images); both give
/// the same card.
///
/// [purge] false: removes the package(s) but keeps the sign-in data, the
/// autostart links and linger, so a reinstall resumes signed in. true: signs
/// out, purges the package(s) incl. rc leftovers, deletes the user's sign-in
/// data and autostart links, and switches linger off only where
/// [piConnectLingerMarker] shows the app switched it on AND the user manager
/// runs nothing else (own autostart links, or running services/timers whose
/// unit file is not the OS's) — otherwise linger stays with a `Hinweis:`
/// line. The marker goes either way. The OS's Raspberry Pi apt source stays
/// in both modes, it is not Pi Connect's own.
///
/// Refuses (`UNINSTALL_REFUSED: …`, exit 3) before any change when the user
/// is unknown, a package is on hold, an rpi-connect outside the package would
/// keep the card alive, or apt would take other packages along. If apt fails
/// after the units were stopped (lock, interrupted dpkg — the simulation
/// catches neither), the units that were running are started again and the
/// script exits 1. Ends with [piConnectRemovedMarker] only once the binary,
/// the package and a running rpi-connectd (any user) are proven gone.
String buildPiConnectUninstallScript(
    {required String user, required bool purge}) {
  if (!_loginName.hasMatch(user)) {
    throw ArgumentError.value(user, 'user', 'kein gültiger Benutzername');
  }
  final verb = purge ? 'purge' : 'remove';
  final gone = purge ? '""|not-installed' : '""|not-installed|config-files';
  final still = purge ? 'weiterhin registriert' : 'weiterhin installiert';
  final b = StringBuffer()
    ..writeln('set -e')
    ..writeln('export DEBIAN_FRONTEND=noninteractive LC_ALL=C')
    ..writeln('u=${shSingleQuote(user)}')
    ..write(_uninstallHelpers)
    ..write(_uninstallUserGuard);
  if (purge) b.write(_uninstallHomeGuard);
  b
    ..write(_uninstallPackageGuards)
    ..writeln(purge ? r'todo="$active$leftover"' : r'todo="$active"')
    ..writeln(r'if [ -n "$todo" ]; then')
    ..writeln('  # apt must take nothing but rpi-connect(-lite) along.')
    ..writeln(r'  if ! sim="$(apt-get -s '
        '$_aptOpts $verb '
        r'$todo 2>&1 </dev/null)"; then')
    ..write(_uninstallSimulationCheck)
    ..write(_uninstallStop);
  if (purge) b.write(_uninstallSignout);
  b
    ..write(_uninstallStopUnits)
    ..writeln(r'if [ -n "$todo" ]; then')
    ..writeln('  if ! apt-get $_aptOpts $verb -y ' r'$todo </dev/null; then')
    ..write(_uninstallAptFailed);
  if (purge) {
    b.writeln(r'    [ -z "$signed_out" ] || echo "Pi Connect ist abgemeldet – '
        'für den Fernzugriff in der App erneut anmelden." >&2');
  }
  b
    ..writeln('    exit 1')
    ..writeln('  fi')
    ..writeln(r'  echo "Entfernt:$todo"')
    ..writeln('fi')
    ..writeln('rm -f /tmp/pi-tool-signin');
  if (purge) {
    b
      ..write(_uninstallUserData)
      ..writeln('m=$piConnectLingerMarker')
      ..write(_uninstallLinger);
  }
  b
    ..write(_uninstallDaemonGone)
    ..writeln('for p in rpi-connect-lite rpi-connect; do')
    ..writeln(r'  case "$(pkg_state "$p")" in')
    ..writeln('    $gone) ;;')
    ..writeln(r'    *) echo "Das Paket $p ist ' '$still." ' r'>&2; exit 1 ;;')
    ..writeln('  esac')
    ..writeln('done')
    ..write(_uninstallBinaryGone)
    ..writeln(purge
        ? 'echo "Raspberry Pi Connect ist vollständig entfernt. Das Gerät '
            'bleibt auf connect.raspberrypi.com gelistet, bis es dort '
            'gelöscht wird."'
        : 'echo "Raspberry Pi Connect ist entfernt. Anmeldung und '
            'Einstellungen bleiben für eine Neuinstallation erhalten."')
    ..writeln('echo $piConnectRemovedMarker');
  return b.toString();
}

/// A plain login name: no shell syntax, no leading dash or dot.
final RegExp _loginName = RegExp(r'^[A-Za-z_][A-Za-z0-9._-]{0,31}$');

const String _aptOpts = '-o DPkg::Lock::Timeout=120 -o Dpkg::Use-Pty=0';

const String _uninstallHelpers = r'''
refuse() { echo "UNINSTALL_REFUSED: $*"; exit 3; }
pkg_state() { dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true; }
# rpi-connectd runs in the login user's own systemd manager.
run_as() {  # run_as <user> <uid> <command…>
  ru="$1" ruid="$2"
  shift 2
  runuser -u "$ru" -- env XDG_RUNTIME_DIR="/run/user/$ruid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$ruid/bus" timeout 30 "$@" </dev/null
}
as_user() { run_as "$u" "$uid" "$@"; }
# Guards: nothing is changed before all of them have passed.
''';

const String _uninstallUserGuard = r'''
pw="$(getent passwd "$u" || true)"
[ -n "$pw" ] || refuse "Den Benutzer $u gibt es auf dem Pi nicht."
uid="$(printf '%s\n' "$pw" | cut -d: -f3)"
home="$(printf '%s\n' "$pw" | cut -d: -f6)"
case "$uid" in ''|*[!0-9]*) refuse "Die Benutzer-ID von $u ist nicht lesbar." ;; esac
''';

const String _uninstallHomeGuard = r'''
case "$home" in /?*) ;; *) refuse "Das Home-Verzeichnis von $u ist unbekannt – die Anmeldedaten lassen sich nicht sicher löschen." ;; esac
''';

const String _uninstallPackageGuards = r'''
active=""
leftover=""
for p in rpi-connect-lite rpi-connect; do
  case "$(pkg_state "$p")" in
    ""|not-installed) ;;
    config-files) leftover="$leftover $p" ;;
    *) active="$active $p" ;;
  esac
done
for p in $active; do
  if [ "$(dpkg-query -W -f='${db:Status-Want}' "$p" 2>/dev/null || true)" = hold ]; then
    refuse "Das Paket $p ist gesperrt (apt-mark hold) – erst mit „sudo apt-mark unhold $p“ freigeben."
  fi
done
# The card goes only when no rpi-connect is left on the login user's PATH.
bins=(/usr/local/sbin/rpi-connect /usr/local/bin/rpi-connect /usr/sbin/rpi-connect
  /usr/bin/rpi-connect /sbin/rpi-connect /bin/rpi-connect /snap/bin/rpi-connect
  "$home/.local/bin/rpi-connect" "$home/bin/rpi-connect")
for f in "${bins[@]}"; do
  if [ -e "$f" ] && [ "$(readlink -f "$f")" != /usr/bin/rpi-connect ]; then
    refuse "rpi-connect liegt auch unter $f und stammt nicht aus dem Paket – die Karte bliebe sichtbar. Bitte zuerst von Hand entfernen."
  fi
done
if [ -e /usr/bin/rpi-connect ] && [ -z "$active" ]; then
  refuse "/usr/bin/rpi-connect gehört zu keinem installierten Paket – bitte von Hand entfernen."
fi
''';

// Continues the `if ! sim=…; then` line the builder writes. A failed
// simulation is an apt error (e.g. broken package lists), not a refusal:
// print apt's output so the app can name the cause. The simulation takes no
// lock, so a held lock or an interrupted dpkg only fails the real run — see
// [_uninstallAptFailed].
const String _uninstallSimulationCheck = r'''
    printf '%s\n' "$sim" >&2
    echo "apt kann rpi-connect gerade nicht entfernen – es wurde nichts geändert." >&2
    exit 1
  fi
  extra="$(printf '%s\n' "$sim" | awk '/^(Remv|Purg) /{sub(/:.*/, "", $2); print $2}' | grep -vx -e rpi-connect -e rpi-connect-lite | tr '\n' ' ' || true)"
  [ -z "$extra" ] || refuse "apt würde zusätzlich entfernen: ${extra% } – abgebrochen, damit nichts anderes verloren geht."
fi
''';

const String _uninstallStop = r'''
# Uninstall. A sign-in the app started detached (setsid) would keep polling.
pkill -x rpi-connect 2>/dev/null || true
''';

const String _uninstallSignout = r'''
# Sign out while binary and daemon are still there. Best effort: the local
# sign-in data is deleted below either way.
signed_out=""
if [ -x /usr/bin/rpi-connect ] && [ -d "/run/user/$uid" ]; then
  if as_user rpi-connect signout 2>&1; then
    signed_out=1
  else
    echo "Abmelden bei Pi Connect nicht möglich – die lokalen Anmeldedaten werden trotzdem gelöscht."
  fi
fi
''';

const String _uninstallStopUnits = r'''
# prerm stops the units only in user managers it reaches: stop them first,
# remembering the running ones in case apt fails and they must come back.
was_active=""
if [ -d "/run/user/$uid" ]; then
  was_active="$(as_user systemctl --user list-units --state=active --no-legend --plain 'rpi-connect*' 2>/dev/null | awk '$1 ~ /^rpi-connect[A-Za-z0-9@._-]*$/ {print $1}' | tr '\n' ' ' || true)"
  as_user systemctl --user stop 'rpi-connect*' || true
fi
''';

// Body of the builder's `if ! apt-get … -y; then`: the package is still
// there (the units stay enabled), so bring back what ran before. The builder
// closes it with `exit 1` — no marker.
const String _uninstallAptFailed = r'''
    echo "apt konnte$todo nicht entfernen – Pi Connect bleibt installiert." >&2
    if [ -n "$was_active" ]; then
      # Unquoted on purpose: one argument per unit name.
      if as_user systemctl --user start $was_active; then
        echo "Pi Connect läuft wieder." >&2
      else
        echo "Pi Connect ließ sich nicht wieder starten – ein Neustart des Pi startet es." >&2
      fi
    fi
''';

const String _uninstallUserData = r'''
# Sign-in data (state.json, auth.key) and the autostart links, including the
# ones Raspberry Pi Imager adds and the package's postrm does not know.
rm -rf -- "$home/.config/com.raspberrypi.connect"
if [ -d "$home/.config/systemd/user" ]; then
  find "$home/.config/systemd/user" -mindepth 2 -maxdepth 2 -type l -path '*.wants/rpi-connect*' -delete
  rmdir "$home/.config/systemd/user/rpi-connect.service.wants" 2>/dev/null || true
fi
# Config-editor backups of the full package's /etc/rpi-connect/wayvnc.config.
rm -f -- /var/backups/pi-tool/config-wayvnc.config-*.bak
''';

// Needs `m` (the linger marker path) set by the builder. The marker records
// who Pi-Tool switched linger on for, not who came to rely on it since
// (rootless Docker, Podman quadlets, `systemctl --user` timers): linger stays
// while the user manager runs anything besides Pi Connect and the OS's own
// units. Unknown counts as in use.
const String _uninstallLinger = r'''
linger_in_use() {  # linger_in_use <user>; sets $why
  lpw="$(getent passwd "$1" || true)"
  luid="$(printf '%s\n' "$lpw" | cut -d: -f3)"
  lhome="$(printf '%s\n' "$lpw" | cut -d: -f6)"
  case "$lhome" in
    /?*)
      if [ -d "$lhome/.config/systemd/user" ] &&
        find "$lhome/.config/systemd/user" -mindepth 2 -maxdepth 2 -path '*.wants/*' ! -name 'rpi-connect*' 2>/dev/null | grep -q .; then
        why="eigene Autostart-Einträge unter $lhome/.config/systemd/user"
        return 0
      fi ;;
  esac
  case "$luid" in ''|*[!0-9]*) why="die Benutzer-ID ist nicht lesbar"; return 0 ;; esac
  # No user manager running: nothing relies on it right now.
  [ -d "/run/user/$luid" ] || return 1
  if ! units="$(run_as "$1" "$luid" systemctl --user list-units --type=service,timer --state=active --no-legend --plain 2>/dev/null)"; then
    why="die Benutzer-Dienste ließen sich nicht prüfen"
    return 0
  fi
  for unit in $(printf '%s\n' "$units" | awk '{print $1}'); do
    case "$unit" in rpi-connect*) continue ;; esac
    frag="$(run_as "$1" "$luid" systemctl --user show -p FragmentPath --value "$unit" 2>/dev/null || true)"
    case "$frag" in /usr/lib/systemd/user/*|/lib/systemd/user/*) continue ;; esac
    why="$unit läuft im Benutzer-Manager"
    return 0
  done
  return 1
}
if [ -f "$m" ]; then
  while IFS= read -r lu || [ -n "$lu" ]; do
    case "$lu" in ''|-*|*[!A-Za-z0-9._-]*) continue ;; esac
    getent passwd "$lu" >/dev/null || continue
    why=""
    if linger_in_use "$lu"; then
      echo "Hinweis: Linger für $lu bleibt eingeschaltet – $why. Bei Bedarf mit „sudo loginctl disable-linger $lu“ ausschalten."
    elif loginctl disable-linger "$lu" </dev/null; then
      echo "Linger für $lu ausgeschaltet (hatte Pi-Tool eingeschaltet)."
    else
      echo "Linger für $lu ließ sich nicht ausschalten." >&2
    fi
  done < "$m"
  rm -f "$m"
else
  echo "Linger unverändert (nicht von Pi-Tool eingeschaltet)."
fi
''';

const String _uninstallDaemonGone = r'''
# Verify. A surviving rpi-connectd (any user) would keep serving the remote
# shell from the deleted binary until the next reboot.
if pgrep -x rpi-connectd >/dev/null 2>&1; then
  pkill -x rpi-connectd 2>/dev/null || true
  i=0
  while pgrep -x rpi-connectd >/dev/null 2>&1 && [ "$i" -lt 10 ]; do
    sleep 1
    i=$((i + 1))
  done
  pkill -KILL -x rpi-connectd 2>/dev/null || true
  sleep 1
fi
if pgrep -x rpi-connectd >/dev/null 2>&1; then
  echo "rpi-connectd läuft weiterhin – ein Neustart des Pi beendet es." >&2
  exit 1
fi
''';

const String _uninstallBinaryGone = r'''
for f in "${bins[@]}"; do
  if [ -e "$f" ]; then echo "rpi-connect ist weiterhin vorhanden: $f" >&2; exit 1; fi
done
if command -v rpi-connect >/dev/null 2>&1; then
  echo "rpi-connect ist weiterhin vorhanden: $(command -v rpi-connect)" >&2
  exit 1
fi
''';

/// Extracts the `https://connect.raspberrypi.com/verify/…` link from
/// `rpi-connect signin` output, or null if absent.
String? parseSigninUrl(String out) =>
    RegExp(r'https://connect\.raspberrypi\.com/verify/\S+')
        .firstMatch(out)
        ?.group(0);

/// Parsed `rpi-connect status`.
typedef PiConnectStatus = ({bool installed, bool signedIn, bool on});

/// Parses `rpi-connect status` output tolerantly (format not doc-guaranteed).
PiConnectStatus parsePiConnectStatus(String out) {
  final o = out.toLowerCase();
  if (o.contains('command not found') ||
      o.contains('not installed') ||
      o.trim().isEmpty) {
    return (installed: false, signedIn: false, on: false);
  }
  // "Signed in: yes" / "signed in as …" → yes; "Signed in: no" → no.
  final signedIn =
      RegExp(r'signed in:?\s*yes').hasMatch(o) || o.contains('signed in as');
  final on = RegExp(r'(screen sharing|remote shell):?\s*on').hasMatch(o) ||
      RegExp(r'\bon\b').hasMatch(o) && !o.contains('off');
  return (installed: true, signedIn: signedIn, on: on);
}
