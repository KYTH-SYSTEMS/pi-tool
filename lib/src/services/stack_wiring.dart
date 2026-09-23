/// Wires the evcc monitoring stack end to end: InfluxDB gets set up (org
/// `pi-tool`, bucket `evcc`), a scoped access token is created, evcc.yaml gets
/// its `influx:` block (backed up, restored if evcc rejects it), and Grafana is
/// provisioned with the datasource plus a ready-made evcc dashboard.
///
/// Requested v0.66.0: the guided stack install left users in front of EMPTY
/// services ("trag InfluxDB + MQTT in evcc ein, siehe Doku"). This closes that
/// gap — charts out of the box.
///
/// Design constraints:
/// - **The token never crosses the wire back.** It is generated on the Pi and
///   consumed there (evcc.yaml + Grafana provisioning); the app log never sees
///   it. That is why this is ONE script instead of several round trips.
/// - Nothing app-side is interpolated into the script (org/bucket are
///   constants), so there is nothing to shell-escape; the dashboard JSON goes
///   through a quoted heredoc.
/// - Fail-soft where a part is missing (no Grafana → skip with a message; a
///   Docker-evcc has no /etc/evcc.yaml → skip with a hint), fail-HARD with
///   rollback where a wrong config could break evcc.
/// - A hand-set-up InfluxDB without root CLI config is reported honestly
///   instead of guessed at.
library;

import 'dart:convert';

import '../commands.dart' show shSingleQuote;

/// Fixed identifiers — also what the user sees in InfluxDB/Grafana.
const String stackOrg = 'pi-tool';
const String stackBucket = 'evcc';

/// First line of the block the wiring appends to /etc/evcc.yaml. It is the
/// ONLY thing [buildEvccInfluxUnwireScriptPart] removes — a user's own
/// `influx:` block never carries it. ASCII on purpose (grep -F under LC_ALL=C).
const String evccInfluxBlockMarker =
    '# Von Pi-Tool ergaenzt (Monitoring-Stack):';

/// influx CLI profile the wiring creates (`influx setup -n`) in
/// /root/.influxdbv2/configs, holding the operator token.
const String stackCliProfile = 'pitool';

/// How much of the stack actually got wired. [partial] exists because the
/// script legitimately skips halves (Docker-evcc without /etc/evcc.yaml,
/// Grafana not installed) — reporting that as full success would leave the
/// user with a green status over a permanently empty dashboard.
enum StackWiringOutcome { wired, partial }

String _fluxQuery(String measurement) => 'from(bucket: "evcc")\n'
    '  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n'
    '  |> filter(fn: (r) => r._measurement == "$measurement")\n'
    '  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)';

Map<String, dynamic> _panel({
  required int id,
  required String type,
  required String title,
  required String measurement,
  required int x,
  required int y,
  required String unit,
  int w = 12,
  int h = 8,
}) =>
    {
      'id': id,
      'type': type,
      'title': title,
      'datasource': {'type': 'influxdb', 'uid': 'pitool-influx'},
      'gridPos': {'h': h, 'w': w, 'x': x, 'y': y},
      'fieldConfig': {
        'defaults': {'unit': unit},
        'overrides': <dynamic>[],
      },
      'targets': [
        {'refId': 'A', 'query': _fluxQuery(measurement)},
      ],
    };

/// The provisioned starter dashboard: the four evcc power series + battery
/// SoC. evcc writes each value as its own measurement (field `value`), so one
/// Flux query per panel. Charts fill as soon as evcc starts writing.
String grafanaEvccDashboardJson() => const JsonEncoder.withIndent('  ')
    .convert({
      'uid': 'pitool-evcc',
      'title': 'evcc (Pi-Tool)',
      'timezone': 'browser',
      'schemaVersion': 39,
      'version': 1,
      'refresh': '1m',
      'time': {'from': 'now-24h', 'to': 'now'},
      'panels': [
        _panel(
            id: 1,
            type: 'timeseries',
            title: 'Netz (gridPower)',
            measurement: 'gridPower',
            x: 0,
            y: 0,
            unit: 'watt'),
        _panel(
            id: 2,
            type: 'timeseries',
            title: 'PV (pvPower)',
            measurement: 'pvPower',
            x: 12,
            y: 0,
            unit: 'watt'),
        _panel(
            id: 3,
            type: 'timeseries',
            title: 'Haus (homePower)',
            measurement: 'homePower',
            x: 0,
            y: 8,
            unit: 'watt'),
        _panel(
            id: 4,
            type: 'timeseries',
            title: 'Laden (chargePower)',
            measurement: 'chargePower',
            x: 12,
            y: 8,
            unit: 'watt'),
        _panel(
            id: 5,
            type: 'gauge',
            title: 'Batterie-SoC',
            measurement: 'batterySoc',
            x: 0,
            y: 16,
            unit: 'percent',
            w: 6,
            h: 6),
      ],
    });

/// The root script (run via `sudo -S bash -s`, marker `WIRE_OK`). German
/// output lines — they stream into the visible log as the narrative.
String buildStackWiringScript() {
  final dashboard = grafanaEvccDashboardJson();
  return '''
export LC_ALL=C
export HOME=/root

# --- InfluxDB: Setup, Bucket, Token -----------------------------------------
if ! command -v influx >/dev/null 2>&1; then
  echo "influx-CLI fehlt (kommt mit dem Paket influxdb2)."
  echo WIRE_FAIL; exit 1
fi
if ! systemctl is-active influxdb >/dev/null 2>&1; then
  echo "InfluxDB laeuft nicht - bitte zuerst installieren/starten."
  echo WIRE_FAIL; exit 1
fi
if [ ! -f /root/.influxdbv2/configs ]; then
  pw=\$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
  if influx setup -f -u pitool -p "\$pw" -o pi-tool -b evcc -n $stackCliProfile >/dev/null 2>&1; then
    echo "InfluxDB eingerichtet (Org pi-tool, Bucket evcc)."
    # Das Admin-Passwort wird bewusst NICHT ausgegeben (es duerfte sonst im Log
    # landen). Damit die InfluxDB-Weboberflaeche keine stumme Sackgasse ist,
    # nennen wir stattdessen den Weg zu einem eigenen Passwort.
    echo "Hinweis: Fuer die InfluxDB-Weboberflaeche (Benutzer 'pitool') auf dem Pi ein eigenes Passwort setzen: sudo influx user password -n pitool"
  else
    echo "InfluxDB wurde bereits von Hand eingerichtet - ohne zugaengliches Admin-Token kann Pi-Tool nicht verdrahten. Bitte Token/Datenquelle manuell anlegen."
    echo WIRE_FAIL; exit 1
  fi
fi
org=\$(influx org list --hide-headers 2>/dev/null | awk 'NR==1{print \$2}')
if [ -z "\$org" ]; then
  echo "Konnte die InfluxDB-Organisation nicht ermitteln."
  echo WIRE_FAIL; exit 1
fi
if ! influx bucket list -o "\$org" --hide-headers 2>/dev/null | awk '{print \$2}' | grep -qx evcc; then
  influx bucket create -n evcc -o "\$org" >/dev/null 2>&1 || true
  echo "Bucket evcc angelegt."
fi
bid=\$(influx bucket list -o "\$org" -n evcc --hide-headers 2>/dev/null | awk 'NR==1{print \$1}')
tok=\$(influx auth create -o "\$org" --read-bucket "\$bid" --write-bucket "\$bid" -d "pi-tool evcc wiring" --json 2>/dev/null | grep -o '"token": *"[^"]*"' | head -1 | cut -d '"' -f4)
if [ -z "\$tok" ]; then
  echo "Konnte kein Zugriffs-Token erzeugen."
  echo WIRE_FAIL; exit 1
fi
echo "Zugriffs-Token erzeugt (bleibt auf dem Pi)."

# --- evcc.yaml: influx-Block ergaenzen (mit Backup + Selbstheilung) ---------
# evcc_wired bleibt 0, wenn evcc NICHT verdrahtet wurde - das entscheidet am
# Ende ueber WIRE_OK vs. WIRE_PARTIAL. Ohne das meldete die App "verdrahtet"
# ueber einem Pi, auf dem evcc nie etwas schreibt (Audit 2026-08-15).
evcc_wired=0
if [ -f /etc/evcc.yaml ]; then
  if ! systemctl cat evcc >/dev/null 2>&1; then
    # Datei da, aber keine systemd-Unit: Docker-evcc mit gemountetem
    # /etc/evcc.yaml oder ein "apt remove" ohne purge. Frueher lief das in den
    # Restart-Fehler und log "evcc akzeptiert die Aenderung nicht" - falsch.
    echo "evcc.yaml gefunden, aber kein systemd-Dienst evcc (Docker-evcc?) - bitte influx dort selbst eintragen (Org \$org, Bucket evcc)."
  elif grep -q '^influx:' /etc/evcc.yaml; then
    echo "evcc.yaml hat schon einen influx-Block - bleibt unveraendert."
  else
    mkdir -p /var/backups/pi-tool
    bak="/var/backups/pi-tool/evcc.yaml.wire-\$(date +%Y%m%d-%H%M%S)"
    # Ohne gelungenes Backup NICHT anfassen - sonst waere die versprochene
    # Ruecknahme eine Luege (volle/nur-lesende SD-Karte).
    if ! cp /etc/evcc.yaml "\$bak"; then
      echo "Konnte kein Backup der evcc.yaml anlegen (Platte voll oder nur lesend?) - nichts geaendert."
      echo WIRE_FAIL; exit 1
    fi
    # Fehlender abschliessender Zeilenumbruch wuerde den Block an die letzte
    # Zeile kleben und die YAML zerstoeren.
    [ -s /etc/evcc.yaml ] && [ "\$(tail -c 1 /etc/evcc.yaml | od -An -c | tr -d ' ')" != "\\n" ] && echo "" >> /etc/evcc.yaml
    if ! {
      echo ""
      echo "$evccInfluxBlockMarker"
      echo "influx:"
      echo "  url: http://localhost:8086"
      echo "  database: evcc"
      echo "  org: \$org"
      echo "  token: \$tok"
    } >> /etc/evcc.yaml; then
      cp "\$bak" /etc/evcc.yaml 2>/dev/null || true
      echo "Konnte evcc.yaml nicht schreiben - nichts geaendert."
      echo WIRE_FAIL; exit 1
    fi
    # Nach dem Restart kurz warten: bei Restart=always meldet is-active sofort
    # "active", auch wenn evcc gleich wieder stirbt (falsche Konfiguration).
    systemctl restart evcc 2>/dev/null || true
    sleep 5
    if [ "\$(systemctl is-active evcc)" = "active" ]; then
      echo "evcc schreibt jetzt nach InfluxDB."
      evcc_wired=1
    else
      cp "\$bak" /etc/evcc.yaml
      systemctl restart evcc 2>/dev/null || true
      echo "evcc akzeptiert die Aenderung nicht - evcc.yaml wurde zurueckgesetzt."
      echo WIRE_FAIL; exit 1
    fi
  fi
else
  echo "Kein /etc/evcc.yaml gefunden (Docker-evcc?) - bitte influx dort selbst eintragen (Org \$org, Bucket evcc)."
fi

# --- Grafana: Datenquelle + Dashboard provisionieren ------------------------
grafana_wired=0
if [ -d /etc/grafana ]; then
  if ! mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards; then
    echo "Konnte die Grafana-Verzeichnisse nicht anlegen - Dashboard uebersprungen."
    echo WIRE_FAIL; exit 1
  fi
  ds=/etc/grafana/provisioning/datasources/pitool-influxdb.yaml
  {
    echo "apiVersion: 1"
    echo "datasources:"
    echo "- name: InfluxDB (evcc)"
    echo "  uid: pitool-influx"
    echo "  type: influxdb"
    echo "  access: proxy"
    echo "  url: http://localhost:8086"
    echo "  jsonData:"
    echo "    version: Flux"
    echo "    organization: \$org"
    echo "    defaultBucket: evcc"
    echo "  secureJsonData:"
    echo "    token: \$tok"
  } > "\$ds" || { echo "Konnte die Grafana-Datenquelle nicht schreiben."; echo WIRE_FAIL; exit 1; }
  chmod 640 "\$ds" 2>/dev/null || true
  chown root:grafana "\$ds" 2>/dev/null || true
  cat > /etc/grafana/provisioning/dashboards/pitool.yaml <<'WRAP'
apiVersion: 1
providers:
- name: pitool
  folder: evcc
  type: file
  options:
    path: /var/lib/grafana/dashboards
WRAP
  cat > /var/lib/grafana/dashboards/pitool-evcc.json <<'WRAP'
$dashboard
WRAP
  chown -R root:grafana /var/lib/grafana/dashboards 2>/dev/null || true
  chmod -R g+rX /var/lib/grafana/dashboards 2>/dev/null || true
  # Ohne lesbares Dashboard-JSON waere die Erfolgsmeldung wertlos.
  if [ ! -s /var/lib/grafana/dashboards/pitool-evcc.json ]; then
    echo "Dashboard-Datei wurde nicht geschrieben (Platte voll oder nur lesend?)."
    echo WIRE_FAIL; exit 1
  fi
  if ! systemctl restart grafana-server; then
    echo "Grafana liess sich nicht neu starten - Dashboard erst nach einem Neustart sichtbar."
    echo WIRE_FAIL; exit 1
  fi
  echo "Grafana: Datenquelle + Dashboard 'evcc' eingerichtet."
  grafana_wired=1
else
  echo "Grafana nicht installiert - Dashboard uebersprungen."
fi

# Nur wenn BEIDE Haelften stehen, ist der Stack wirklich verdrahtet. Sonst
# meldet die App ehrlich Teilerfolg statt gruen ueber einem leeren Dashboard.
if [ "\$evcc_wired" = "1" ] && [ "\$grafana_wired" = "1" ]; then
  echo WIRE_OK
else
  echo "Teilweise verdrahtet: evcc=\$evcc_wired grafana=\$grafana_wired"
  echo WIRE_PARTIAL
fi
''';
}

// --- undo (InfluxDB uninstall with purge) ------------------------------------
// Fragments for buildAptServiceUninstallScript: bash, run as root under the
// uninstall's `set -e`. A refusal prints one `UNINSTALL_REFUSED: <Grund>` line
// and exits 3. Grafana's datasource/dashboard stay: a re-wiring overwrites the
// datasource anyway, and the user may have built on the dashboard.

/// Takes back the `influx:` block the wiring appended to /etc/evcc.yaml. Left
/// in place, evcc keeps writing with a dead token and a later re-wiring stops
/// at "hat schon einen influx-Block" (WIRE_PARTIAL forever).
///
/// - Removes only the [evccInfluxBlockMarker] line, the `influx:` key right
///   below it and that key's indented body (blank/comment lines inside it
///   included), plus the one blank line the wiring put in front.
/// - Timestamped backup under /var/backups/pi-tool first, then an atomic
///   replace that keeps owner and mode.
/// - evcc is restarted only when it is installed AND running. If it does not
///   come back active, the backup is restored and the fragment refuses — so
///   the caller runs it BEFORE removing anything.
String buildEvccInfluxUnwireScriptPart() =>
    'wire_marker=${shSingleQuote(evccInfluxBlockMarker)}\n'
    '$_evccInfluxUnwireBody';

const String _evccInfluxUnwireBody = r'''
# awk: drop the marker line, the influx: key below it and the key's body.
# Blank/comment lines belong to the body only while indented lines follow.
unwire_awk='
  { l[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      if (l[i] != m || l[i + 1] != "influx:") continue
      d[i] = 1; d[i + 1] = 1
      j = i + 2
      while (j <= NR) {
        if (l[j] ~ /^[ \t]/) { d[j] = 1; j++; continue }
        k = j
        while (k <= NR && l[k] ~ /^[ \t]*(#.*)?$/) k++
        if (k > j && k <= NR && l[k] ~ /^[ \t]/) { while (j < k) d[j++] = 1; continue }
        break
      }
      if (i > 1 && l[i - 1] == "") d[i - 1] = 1
      i = j - 1
    }
    for (i = 1; i <= NR; i++) if (!(i in d)) print l[i]
  }'
if [ -f /etc/evcc.yaml ] && grep -qxF "$wire_marker" /etc/evcc.yaml; then
  mkdir -p /var/backups/pi-tool
  unwire_bak="/var/backups/pi-tool/evcc.yaml.unwire-$(date +%Y%m%d-%H%M%S)"
  unwire_tmp=""
  if ! cp -p /etc/evcc.yaml "$unwire_bak" ||
    ! unwire_tmp=$(mktemp /etc/.pitool-evcc.XXXXXX) ||
    ! awk -v m="$wire_marker" "$unwire_awk" /etc/evcc.yaml >"$unwire_tmp"; then
    if [ -n "$unwire_tmp" ]; then rm -f -- "$unwire_tmp"; fi
    echo "UNINSTALL_REFUSED: Die evcc-Konfiguration ließ sich nicht sichern oder anpassen (Speicher voll oder schreibgeschützt?) – nichts geändert."
    exit 3
  fi
  if cmp -s /etc/evcc.yaml "$unwire_tmp"; then
    # Marker without its influx: key (edited by hand): nothing of ours left.
    rm -f -- "$unwire_tmp" "$unwire_bak"
  else
    chmod --reference=/etc/evcc.yaml "$unwire_tmp" 2>/dev/null || true
    chown --reference=/etc/evcc.yaml "$unwire_tmp" 2>/dev/null || true
    mv -f "$unwire_tmp" /etc/evcc.yaml
    echo "InfluxDB-Eintrag von Pi-Tool aus /etc/evcc.yaml entfernt (Sicherung: $unwire_bak)."
    if systemctl cat evcc >/dev/null 2>&1 && systemctl is-active --quiet evcc; then
      systemctl restart evcc >/dev/null 2>&1 || true
      # Restart=always reports "active" at once, even for a crash loop.
      sleep 5
      if [ "$(systemctl is-active evcc 2>/dev/null)" != active ]; then
        cp -p "$unwire_bak" /etc/evcc.yaml
        systemctl restart evcc >/dev/null 2>&1 || true
        echo "UNINSTALL_REFUSED: evcc lief ohne den InfluxDB-Eintrag nicht wieder an – /etc/evcc.yaml ist wiederhergestellt, nichts deinstalliert."
        exit 3
      fi
      echo "evcc läuft ohne den InfluxDB-Eintrag weiter."
    fi
  fi
fi
''';

/// Removes the wiring's CLI profile [stackCliProfile] (operator token of the
/// deleted database) from /root/.influxdbv2/configs — run AFTER the data is
/// gone. Left behind, the next wiring would skip `influx setup` (the file
/// exists) and fail on the fresh database. Other profiles stay; the file and
/// its directory only go when nothing else is left in them.
String buildInfluxCliProfileCleanupScriptPart() =>
    'cli_profile=${shSingleQuote(stackCliProfile)}\n'
    '$_influxCliProfileCleanupBody';

const String _influxCliProfileCleanupBody = r'''
cli_cfg=/root/.influxdbv2/configs
# awk: a profile is its [name] header plus the lines up to the next header.
cli_has='{ t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t) } t == "[" p "]" { f = 1 } END { exit !f }'
cli_drop='{ t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t) } t ~ /^\[/ { skip = (t == "[" p "]") } !skip { print }'
if [ -f "$cli_cfg" ] && awk -v p="$cli_profile" "$cli_has" "$cli_cfg"; then
  cli_tmp=$(mktemp /root/.influxdbv2/.pitool-cfg.XXXXXX)
  awk -v p="$cli_profile" "$cli_drop" "$cli_cfg" >"$cli_tmp"
  if grep -Eq '^[[:blank:]]*\[' "$cli_tmp"; then
    chmod --reference="$cli_cfg" "$cli_tmp" 2>/dev/null || true
    mv -f "$cli_tmp" "$cli_cfg"
    echo "influx-CLI-Profil „$cli_profile“ entfernt, weitere Profile bleiben."
  else
    rm -f -- "$cli_tmp" "$cli_cfg"
    rmdir /root/.influxdbv2 2>/dev/null || true
    echo "influx-CLI-Profil „$cli_profile“ entfernt."
  fi
fi
if [ -f /etc/grafana/provisioning/datasources/pitool-influxdb.yaml ]; then
  echo "Hinweis: Die Grafana-Datenquelle „InfluxDB (evcc)“ bleibt bis zur nächsten Verdrahtung ohne Daten."
fi
''';
