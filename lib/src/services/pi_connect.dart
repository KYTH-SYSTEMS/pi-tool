/// Raspberry Pi Connect (official remote-access service) as a managed service.
/// Pure command strings + parsers; SSH orchestration is wired in
/// evcc_updater.dart. Needs Raspberry Pi OS Bookworm (Debian 12) or newer.
///
/// NOTE: the headless/over-SSH behaviour (linger, XDG_RUNTIME_DIR, the exact
/// `rpi-connect status` text) is not covered by the official docs — these are
/// built defensively and want an on-device check.
library;

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

/// Root script: installs the headless (lite) variant and enables linger so the
/// user service keeps running without an active login session.
const String piConnectInstallScript = '''
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -o Dpkg::Use-Pty=0 install -y rpi-connect-lite
u="\$SUDO_USER"; [ -z "\$u" ] && u="\$(logname 2>/dev/null)"
[ -n "\$u" ] && loginctl enable-linger "\$u" 2>/dev/null || true
echo PICONNECT_INSTALLED
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
