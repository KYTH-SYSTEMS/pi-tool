/// Package sources of end-of-life Raspbian/Debian releases (jessie, stretch,
/// buster). Their regular servers dropped them — the old URLs answer 404 — and
/// ONE dead source makes every `apt-get update` on that Pi exit 100. Seen on a
/// Raspbian-Buster Pi on 2026-09-23 ("The repository 'http://raspbian.
/// raspberrypi.org/raspbian buster Release' no longer has a Release file"): the
/// Tailscale install aborted, and so would every other install or update.
///
/// [eolSourcesFixScript] points those lines at the official archives
/// (legacy.raspbian.org, archive.debian.org — same signing keys, verified
/// 2026-09-23). It runs as root before each apt action of the app and inside
/// the on-Pi auto-update. Pure strings + a parser, so everything is testable.
library;

/// Remote command for [eolSourcesFixScript]: a root bash reading the script
/// from stdin, like `installShellCommand`. The trailing argument is ignored by
/// the script; it only makes this step distinguishable in logs and tests.
const String eolSourcesShellCommand =
    'LC_ALL=C sudo -S bash -s -- pitool-eol-sources';

/// Bash. Rewrites only lines that are provably broken: the source is one of
/// the official Raspbian/Debian servers, the suite belongs to jessie, stretch
/// or buster, the old URL no longer serves its Release file AND the archive
/// does. A suite the archive does not carry either (e.g. stretch-updates) is
/// commented out — it can never work again and would keep apt failing. Every
/// changed file is backed up to /var/backups/pi-tool/apt-sources/ first (not
/// next to it: apt would warn about the extra file in sources.list.d). Prints
/// one `Pi-Tool:` line per change and nothing on a healthy Pi, where it costs a
/// grep and no network. Never fails the caller (`|| true`).
const String eolSourcesFixScript = r'''
pitool_reach() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o /dev/null --connect-timeout 10 -m 20 "$1" </dev/null >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -t 1 -T 20 -O /dev/null "$1" </dev/null >/dev/null 2>&1
  else
    return 1
  fi
}
pitool_archive_for() {
  local c="${2%%[-/]*}" h="${1%/}"
  case "$c" in jessie|stretch|buster) ;; *) return 0 ;; esac
  h="${h#*://}"
  case "$h" in
    raspbian.raspberrypi.org/raspbian|raspbian.raspberrypi.com/raspbian|mirrordirector.raspbian.org/raspbian|archive.raspbian.org/raspbian)
      echo http://legacy.raspbian.org/raspbian ;;
    deb.debian.org/debian|httpredir.debian.org/debian|ftp.debian.org/debian|ftp.*.debian.org/debian)
      echo http://archive.debian.org/debian ;;
    security.debian.org|security.debian.org/debian-security|deb.debian.org/debian-security)
      echo http://archive.debian.org/debian-security ;;
  esac
}
pitool_fix_eol_sources() {
  local re f line typ opts url suite rest new key tmp changed ts bdir
  local -A seen=()
  re='^[[:space:]]*(deb|deb-src)[[:space:]]+(\[[^]]*\][[:space:]]+)?([^[:space:]]+)[[:space:]]+([^[:space:]]+)(.*)$'
  ts=$(date +%Y%m%d-%H%M%S)
  bdir=/var/backups/pi-tool/apt-sources
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    grep -Eq 'jessie|stretch|buster' "$f" 2>/dev/null || continue
    tmp=$(mktemp) || return 0
    changed=0
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ $line =~ $re ]]; then
        typ=${BASH_REMATCH[1]} opts=${BASH_REMATCH[2]} url=${BASH_REMATCH[3]}
        suite=${BASH_REMATCH[4]} rest=${BASH_REMATCH[5]}
        new=$(pitool_archive_for "$url" "$suite")
        if [ -n "$new" ]; then
          key="$url $suite"
          if [ -z "${seen[$key]:-}" ]; then
            if pitool_reach "${url%/}/dists/$suite/Release"; then
              seen[$key]=keep
            elif pitool_reach "$new/dists/$suite/Release"; then
              seen[$key]=move
              echo "Pi-Tool: Paketquelle umgestellt: $url $suite → $new (liegt nur noch im Archiv)"
            elif pitool_reach "$new/dists/${suite%%[-/]*}/Release"; then
              seen[$key]=drop
              echo "Pi-Tool: Paketquelle abgeschaltet: $url $suite (gibt es auch im Archiv nicht mehr)"
            else
              seen[$key]=keep
            fi
          fi
          case ${seen[$key]} in
            move) line="$typ $opts$new $suite$rest"; changed=1 ;;
            drop) line="# $line  # Pi-Tool: Quelle existiert nicht mehr"; changed=1 ;;
          esac
        fi
      fi
      printf '%s\n' "$line" >>"$tmp"
    done <"$f"
    if [ "$changed" = 1 ]; then
      if mkdir -p "$bdir" && cp -p "$f" "$bdir/${f##*/}.$ts" &&
        cp "$tmp" "$f.pitool-new" && chmod 0644 "$f.pitool-new" &&
        mv -f "$f.pitool-new" "$f"; then
        echo "Pi-Tool: Sicherung der alten Fassung: $bdir/${f##*/}.$ts"
      else
        rm -f "$f.pitool-new"
        echo "Pi-Tool: $f konnte nicht angepasst werden."
      fi
    fi
    rm -f "$tmp"
  done
}
pitool_fix_eol_sources || true
''';

/// The `<url> <suite>` of a source apt gave up on because its server no longer
/// serves the Release file (404) — or null. apt ≥ 1.x words it as "no longer
/// has a Release file" (was there before) or "does not have a Release file".
String? parseDeadAptSource(String output) {
  final m = RegExp(r"The repository '([^']+?) Release' (?:no longer has|does not have) a Release file")
      .firstMatch(output);
  return m?.group(1)?.trim();
}

/// True when apt/dpkg could not start because another package run holds the
/// lock — typically the daily apt timer or unattended-upgrades right after
/// boot. Transient: trying again a few minutes later is the remedy.
bool isAptLocked(String output) =>
    output.contains('Could not get lock') ||
    output.contains('Unable to acquire the dpkg frontend lock') ||
    output.contains('Unable to lock directory /var/lib/apt/lists');
