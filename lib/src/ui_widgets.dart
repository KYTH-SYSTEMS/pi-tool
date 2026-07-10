part of '../main.dart';

// Presentational widgets + sheets for the updater screen, split out of
// main.dart. Kept as a part so they stay library-private and share the
// top-level theme constants (kGreen/kBlack/kCard) without re-importing.

/// A green that stays legible on both themes — vivid kGreen on the dark
/// surfaces, darkened for light mode where bright kGreen washes out.
Color _themeGreen(bool dark) => dark ? kGreen : const Color(0xFF15803D);

/// Compact connection-test button (under the connection settings). Neutral when untested,
/// a spinner while testing, green when the last test succeeded, red on failure.
class _TestButton extends StatelessWidget {
  const _TestButton({
    required this.testing,
    required this.result,
    required this.enabled,
    required this.onTap,
  });

  final bool testing;
  final bool? result; // null = untested
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final okGreen = _themeGreen(dark);

    Widget icon;
    String label;
    Color fg;
    Color bg = Colors.transparent;
    Color border;

    if (testing) {
      icon = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
      label = 'Verbinde …';
      fg = cs.onSurfaceVariant;
      border = cs.outlineVariant;
    } else if (result == true) {
      icon = Icon(Icons.check_circle, size: 18, color: okGreen);
      label = 'Verbunden';
      fg = okGreen;
      bg = kGreen.withValues(alpha: dark ? 0.14 : 0.10);
      border = kGreen.withValues(alpha: 0.55);
    } else if (result == false) {
      icon = Icon(Icons.error_outline, size: 18, color: cs.error);
      label = 'Keine Verbindung';
      fg = cs.error;
      bg = cs.error.withValues(alpha: dark ? 0.14 : 0.08);
      border = cs.error.withValues(alpha: 0.55);
    } else {
      icon = Icon(Icons.wifi_tethering, size: 18, color: cs.onSurfaceVariant);
      label = 'Verbindung herstellen';
      fg = cs.onSurfaceVariant;
      border = cs.outlineVariant;
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: (enabled && !testing) ? onTap : null,
        icon: icon,
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: fg,
          backgroundColor: bg,
          side: BorderSide(color: border),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        ),
      ),
    );
  }
}

/// Read-only remote file browser: navigate directories, tap a file to preview.
/// Embedded remote file browser (the „Dateien" tab). Browse directories, tap a
/// file to preview it, upload a file into the current directory, or delete an
/// entry. Manages its own path + loading; each action calls back to the page,
/// which connects over SSH. Taps are serialised so two connections never open
/// at once.
class _FilesView extends StatefulWidget {
  const _FilesView({
    super.key,
    required this.startPath,
    required this.onList,
    required this.onOpenFile,
    required this.onUpload,
    required this.onDelete,
  });
  final String startPath;
  final Future<List<DirEntry>> Function(String path) onList;
  final Future<void> Function(String path) onOpenFile;

  /// Picks + uploads a local file into [dir]. Returns true if something was
  /// uploaded (→ the view reloads).
  final Future<bool> Function(String dir) onUpload;

  /// Deletes [entry] inside [dir]. Returns true if deleted (→ the view reloads).
  final Future<bool> Function(DirEntry entry, String dir) onDelete;

  @override
  State<_FilesView> createState() => _FilesViewState();
}

class _FilesViewState extends State<_FilesView> {
  late String _path = widget.startPath;
  List<DirEntry>? _entries;
  bool _loading = false; // dir-load (shows the body spinner)
  bool _working = false; // open/upload/delete in flight → gate taps
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(_path);
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final e = await widget.onList(path);
      if (!mounted) return;
      setState(() {
        _path = path;
        _entries = e;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Verzeichnis konnte nicht geladen werden.';
      });
    }
  }

  Future<void> _work(Future<void> Function() body) async {
    setState(() => _working = true);
    try {
      await body();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final atRoot = _path == '/';
    final busy = _loading || _working;
    final entries = _entries ?? const <DirEntry>[];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _path,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              IconButton(
                tooltip: 'Aktualisieren',
                onPressed: busy ? null : () => _load(_path),
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: 'Datei hochladen',
                onPressed: busy
                    ? null
                    : () => _work(() async {
                        if (await widget.onUpload(_path)) await _load(_path);
                      }),
                icon: const Icon(Icons.upload_file),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(child: Text(_error!))
              : ListView(
                  children: [
                    if (!atRoot)
                      ListTile(
                        leading: const Icon(Icons.arrow_upward),
                        title: const Text('..'),
                        onTap: busy
                            ? null
                            : () => _load(parentRemotePath(_path)),
                      ),
                    if (entries.isEmpty && !atRoot)
                      const ListTile(enabled: false, title: Text('— leer —')),
                    for (final e in entries)
                      ListTile(
                        leading: Icon(
                          e.isDir
                              ? Icons.folder
                              : Icons.insert_drive_file_outlined,
                        ),
                        title: Text(e.name),
                        onTap: busy
                            ? null
                            : e.isDir
                            ? () => _load(joinRemotePath(_path, e.name))
                            : () => _work(
                                () => widget.onOpenFile(
                                  joinRemotePath(_path, e.name),
                                ),
                              ),
                        trailing: PopupMenuButton<String>(
                          enabled: !busy,
                          tooltip: 'Aktionen',
                          onSelected: (v) {
                            if (v == 'delete') {
                              _work(() async {
                                if (await widget.onDelete(e, _path)) {
                                  await _load(_path);
                                }
                              });
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('Löschen'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Health-Alerts config sheet. A StatefulWidget so its two text controllers are
/// disposed in [State.dispose] — i.e. only after the sheet's close animation
/// finishes (disposing them right after showModalBottomSheet resolves would use
/// them mid-animation → "used after dispose").
class _AlertsSheet extends StatefulWidget {
  const _AlertsSheet({
    required this.status,
    required this.initialServer,
    required this.initialTopic,
    required this.onOpenNtfy,
    required this.onSnack,
    required this.onTest,
  });
  final AlertsStatus status;
  final String initialServer;
  final String initialTopic;
  final VoidCallback onOpenNtfy;
  final void Function(String message) onSnack;
  final void Function(String server, String topic) onTest;

  @override
  State<_AlertsSheet> createState() => _AlertsSheetState();
}

class _AlertsSheetState extends State<_AlertsSheet> {
  late final TextEditingController _serverCtrl = TextEditingController(
    text: widget.initialServer,
  );
  late final TextEditingController _topicCtrl = TextEditingController(
    text: widget.initialTopic,
  );

  @override
  void dispose() {
    _serverCtrl.dispose();
    _topicCtrl.dispose();
    super.dispose();
  }

  String get _server => _serverCtrl.text.trim().isEmpty
      ? 'https://ntfy.sh'
      : _serverCtrl.text.trim();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = widget.status;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 4,
          bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Health-Alerts', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'Der Pi meldet sich per Push (via ntfy), wenn die Platte '
              'vollläuft, ein Dienst ausfällt, es zu heiß wird oder Updates '
              'anstehen — geprüft alle 30 Min. Kostenlos & ohne Konto.',
            ),
            const SizedBox(height: 6),
            InkWell(
              onTap: widget.onOpenNtfy,
              child: Text(
                'So funktioniert ntfy (App installieren, Thema '
                'abonnieren) →',
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              status.enabled
                  ? 'Aktuell aktiv · letzte Prüfung: ${status.lastCheck ?? '—'}'
                  : 'Aktuell aus.',
              style: TextStyle(
                color: status.enabled ? kGreen : null,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _topicCtrl,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'ntfy-Thema (Topic)',
                hintText: 'z. B. mein-pi-a7Xk',
                helperText: 'Frei wählbar, aber schwer erratbar wählen.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _serverCtrl,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'ntfy-Server',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      final topic = _topicCtrl.text.trim();
                      if (topic.isEmpty) {
                        widget.onSnack('Bitte ein ntfy-Thema eingeben.');
                        return;
                      }
                      Navigator.pop(context, (
                        enable: true,
                        server: _server,
                        topic: topic,
                      ));
                    },
                    child: Text(
                      status.enabled ? 'Aktualisieren' : 'Einschalten',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () {
                    final topic = _topicCtrl.text.trim();
                    if (topic.isEmpty) {
                      widget.onSnack('Bitte ein ntfy-Thema eingeben.');
                      return;
                    }
                    widget.onTest(_server, topic);
                  },
                  child: const Text('Test'),
                ),
              ],
            ),
            if (status.enabled)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => Navigator.pop(context, (
                    enable: false,
                    server: '',
                    topic: '',
                  )),
                  child: const Text('Ausschalten'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One Pi's status in the multi-Pi overview.
typedef PiSnapshot = ({
  bool reachable,
  bool updates,
  bool warning,
  String detail,
});

/// Multi-Pi overview: a traffic-light row per profile. Probes each Pi
/// sequentially (fail-soft) so one unreachable Pi doesn't block the rest.
class _MultiPiDashboardPage extends StatefulWidget {
  const _MultiPiDashboardPage({required this.profiles, required this.probe});
  final List<Profile> profiles;
  final Future<PiSnapshot> Function(Profile) probe;

  @override
  State<_MultiPiDashboardPage> createState() => _MultiPiDashboardPageState();
}

class _MultiPiDashboardPageState extends State<_MultiPiDashboardPage> {
  final Map<int, PiSnapshot> _results = {};
  int _probing = -1;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _cancelled = true; // stop probing further Pis once we leave the page
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _results.clear();
      _cancelled = false;
    });
    for (var i = 0; i < widget.profiles.length; i++) {
      if (_cancelled || !mounted) return;
      setState(() => _probing = i);
      final snap = await widget.probe(widget.profiles[i]);
      if (_cancelled || !mounted) return;
      setState(() {
        _results[i] = snap;
        _probing = -1;
      });
    }
  }

  Color _colorFor(BuildContext ctx, PiSnapshot s) {
    final cs = Theme.of(ctx).colorScheme;
    if (!s.reachable) return cs.error;
    if (s.warning || s.updates) return Colors.amber.shade700;
    return kGreen;
  }

  @override
  Widget build(BuildContext context) {
    final done = _results.length == widget.profiles.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alle Pis'),
        actions: [
          IconButton(
            tooltip: 'Aktualisieren',
            onPressed: done ? _run : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: widget.profiles.length,
        itemBuilder: (ctx, i) {
          final p = widget.profiles[i];
          final snap = _results[i];
          final subtitle = snap == null
              ? (i == _probing ? 'Prüfe …' : 'Wartet …')
              : [
                  if (snap.updates) 'Updates verfügbar',
                  snap.detail,
                ].where((s) => s.isNotEmpty).join('  ·  ');
          return ListTile(
            leading: snap == null
                ? (i == _probing
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          Icons.circle_outlined,
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        ))
                : Icon(Icons.circle, color: _colorFor(ctx, snap)),
            title: Text(p.name),
            subtitle: Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: (snap?.updates ?? false)
                ? const Icon(Icons.system_update, size: 18)
                : null,
          );
        },
      ),
    );
  }
}

/// Beginner guide: set up a fresh Pi with Raspberry Pi Imager so this app can
/// connect (enable SSH + user/password + WiFi via the Imager's advanced options).
class _SetupGuidePage extends StatelessWidget {
  const _SetupGuidePage({required this.onDownloadImager});
  final VoidCallback onDownloadImager;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget bullet(String t) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('•  '),
          Expanded(child: Text(t)),
        ],
      ),
    );
    Widget step(int n, String title, Widget body) => Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: kGreen,
            child: Text(
              '$n',
              style: const TextStyle(
                color: kBlack,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                body,
              ],
            ),
          ),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Pi einrichten')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Damit Pi-Tool sich verbinden kann, muss der Pi per SSH erreichbar '
            'sein. Der „Raspberry Pi Imager" richtet das in wenigen Minuten ein '
            '— ganz ohne Bildschirm/Tastatur am Pi.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          step(
            1,
            'Imager installieren',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Lade den „Raspberry Pi Imager" auf deinen Computer '
                  'und starte ihn. Steck die SD-Karte des Pi in den Rechner.',
                ),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  onPressed: onDownloadImager,
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Raspberry Pi Imager laden'),
                ),
              ],
            ),
          ),
          step(
            2,
            'System wählen',
            const Text(
              'Wähle dein Pi-Modell, dann „Raspberry Pi OS Lite '
              '(64-Bit)" (ohne Desktop – schlank und ideal für Pi-Tool) und '
              'die SD-Karte.',
            ),
          ),
          step(
            3,
            '⚙️ Erweiterte Optionen (wichtig!)',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Vor dem Schreiben auf das Zahnrad ⚙ bzw. '
                  '„Einstellungen bearbeiten" tippen und setzen:',
                ),
                bullet('SSH aktivieren (mit Passwort-Anmeldung)'),
                bullet(
                  'Benutzername + Passwort – die trägst du gleich in '
                  'Pi-Tool ein',
                ),
                bullet(
                  'Hostname, z. B. „wohnzimmer-pi" (erreichbar als '
                  'wohnzimmer-pi.local)',
                ),
                bullet(
                  'WLAN: Netzwerkname, Passwort und Land – oder ein '
                  'LAN-Kabel nutzen',
                ),
              ],
            ),
          ),
          step(
            4,
            'Schreiben & starten',
            const Text(
              'SD-Karte beschreiben, in den Pi stecken, Strom '
              'anschließen. Der erste Start dauert 1–2 Minuten.',
            ),
          ),
          step(
            5,
            'In Pi-Tool verbinden',
            const Text(
              'Oben den Pi wählen/anlegen, als Host „<hostname>.local" '
              'eintragen (oder „Pi im WLAN suchen"), Benutzer + Passwort aus '
              'Schritt 3 – dann „Verbindung herstellen". Fertig.',
            ),
          ),
          Text(
            'Tipp: Klappt „.local" nicht, nutze „Pi im WLAN suchen" oder die IP '
            'aus deinem Router.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen editor for a remote config file. Pops the edited text on save,
/// or null when the user backs out (cancel).
class _ConfigEditorPage extends StatefulWidget {
  const _ConfigEditorPage({required this.title, required this.initial});
  final String title;
  final String initial;
  @override
  State<_ConfigEditorPage> createState() => _ConfigEditorPageState();
}

class _ConfigEditorPageState extends State<_ConfigEditorPage> {
  late final TextEditingController _c = TextEditingController(
    text: widget.initial,
  );
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: 'Speichern',
            onPressed: () => Navigator.pop(context, _c.text),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _c,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ),
    );
  }
}

/// A tappable tile on the Automatik tab (one automation feature). Shows a lock
/// when [locked] (Pro), or a muted "coming soon" look when not [enabled].
class _AutomationTile extends StatelessWidget {
  const _AutomationTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.locked = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: dark ? kCard : cs.surfaceContainerHighest,
      child: ListTile(
        leading: Icon(icon, color: _themeGreen(dark)),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
        subtitle: Text(subtitle),
        trailing: locked
            ? Icon(Icons.lock_outline, size: 18, color: cs.onSurfaceVariant)
            : const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// One entry in a service card's ⋮ menu. [pro] marks a Pro-only action so the
/// menu can show a lock for free users (the tap still routes through the gate).
class _CardAction {
  const _CardAction(this.label, this.onTap, {this.pro = false});
  final String label;
  final VoidCallback onTap;
  final bool pro;
}

/// One entry in the "Dienst hinzufügen" picker: a not-yet-installed service and
/// how to install it (bespoke evcc/Pi-hole/HA flow, or a generic apt install).
class _AddableService {
  const _AddableService(
    this.name,
    this.icon,
    this.onAdd, {
    this.subtitle,
    this.enabled = true,
  });
  final String name;
  final IconData icon;
  final VoidCallback onAdd;
  final String? subtitle;

  /// False → shown greyed (e.g. incompatible OS); [onAdd] can still explain why.
  final bool enabled;
}

/// A detected-service card (style B): name + status LED + version (mono) +
/// primary Aktualisieren/Installieren, an optional "Oberfläche öffnen" link and
/// a ⋮ menu of extra actions. Mirrors the connection card's shape.
class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.status,
    required this.icon,
    required this.primaryLabel,
    required this.onPrimary,
    required this.enabled,
    this.onOpenWeb,
    this.actions = const [],
    this.isPro = true,
  });

  final ServiceStatus status;
  final IconData icon;
  final String primaryLabel; // "Aktualisieren" | "Installieren"
  final VoidCallback onPrimary;
  final bool enabled;
  final VoidCallback? onOpenWeb;
  final List<_CardAction> actions;
  final bool isPro; // false → Pro actions show a lock badge

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final mono = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      color: cs.onSurfaceVariant,
    );

    // Known up to date → show a disabled "Aktuell ✓" instead of "Aktualisieren"
    // (a forced update stays available via the ⋮ menu). When currency is
    // unknown (Docker evcc / Home Assistant) we keep offering "Aktualisieren".
    final upToDate =
        status.installed && status.updateKnown && !status.updateAvailable;

    // Bright accents read fine on the dark card but wash out on the light card,
    // so text/icons use a darkened variant in light mode (the small decorative
    // dot keeps the vivid tone).
    final okGreen = _themeGreen(dark);
    final warnAmber = dark ? const Color(0xFFE0A030) : const Color(0xFF9A6B00);

    // Status LED: not installed → grey; update → amber; active → green;
    // installed-but-inactive → red. [led] = the vivid dot, [ledText] = the
    // legible-on-any-theme label colour.
    final Color led;
    final Color ledText;
    if (!status.installed) {
      led = cs.onSurfaceVariant;
      ledText = cs.onSurfaceVariant;
    } else if (status.updateAvailable) {
      led = const Color(0xFFE0A030);
      ledText = warnAmber;
    } else if (status.active) {
      led = kGreen;
      ledText = okGreen;
    } else {
      led = cs.error;
      ledText = cs.error;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
      decoration: BoxDecoration(
        color: dark ? kCard : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: dark ? Colors.white10 : cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: cs.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  status.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ),
              Icon(Icons.circle, size: 10, color: led),
              const SizedBox(width: 6),
              Text(
                status.installed
                    ? (status.updateAvailable
                          ? 'Update'
                          : (status.active ? 'aktiv' : 'inaktiv'))
                    : 'nicht installiert',
                style: TextStyle(color: ledText, fontSize: 12),
              ),
              if (actions.isNotEmpty)
                PopupMenuButton<int>(
                  // Stable per-service key so callers/tests can target a card's
                  // menu regardless of card order.
                  key: ValueKey('menu-${status.id}'),
                  enabled: enabled,
                  tooltip: '${status.name}-Aktionen',
                  icon: const Icon(Icons.more_vert),
                  onSelected: (i) => actions[i].onTap(),
                  itemBuilder: (_) => [
                    for (var i = 0; i < actions.length; i++)
                      PopupMenuItem(
                        value: i,
                        child: (actions[i].pro && !isPro)
                            ? Row(
                                children: [
                                  Expanded(child: Text(actions[i].label)),
                                  const SizedBox(width: 8),
                                  Icon(
                                    Icons.lock_outline,
                                    size: 15,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ],
                              )
                            : Text(actions[i].label),
                      ),
                  ],
                )
              else
                const SizedBox(width: 8),
            ],
          ),
          if (status.installed &&
              (status.version != null || status.detail.isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(left: 30, bottom: 6),
              child: Text(
                [
                  status.version,
                  status.detail,
                ].where((s) => s != null && s.isNotEmpty).join('  ·  '),
                style: mono,
              ),
            ),
          // Vitals (System card): temperature, disk, RAM, uptime. Emphasized in
          // amber when it carries a warning (e.g. low disk before an update).
          if (status.installed && status.health.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 30, bottom: 6),
              child: Text(
                status.health,
                style: status.healthWarning
                    ? mono?.copyWith(color: warnAmber)
                    : mono,
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 30, right: 8, top: 2),
            child: Row(
              children: [
                Expanded(
                  child: upToDate
                      ? OutlinedButton.icon(
                          onPressed: null,
                          icon: Icon(
                            Icons.check_circle_outline,
                            size: 18,
                            color: okGreen,
                          ),
                          label: const Text('Aktuell'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(42),
                          ),
                        )
                      : OutlinedButton(
                          onPressed: enabled ? onPrimary : null,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(42),
                          ),
                          child: Text(primaryLabel),
                        ),
                ),
                if (onOpenWeb != null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: onOpenWeb,
                    icon: const Icon(Icons.open_in_browser),
                    tooltip: 'Oberfläche öffnen',
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    required this.privateKey,
    required this.keyPassphrase,
    required this.authMode,
    required this.obscure,
    required this.enabled,
    required this.onToggleObscure,
    required this.onAuthMode,
  });

  final TextEditingController host;
  final TextEditingController port;
  final TextEditingController user;
  final TextEditingController password;
  final TextEditingController privateKey;
  final TextEditingController keyPassphrase;
  final AuthMode authMode;
  final bool obscure;
  final bool enabled;
  final VoidCallback onToggleObscure;
  final ValueChanged<AuthMode> onAuthMode;

  @override
  Widget build(BuildContext context) {
    final keyMode = authMode == AuthMode.key;
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: dark ? kCard : cs.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: dark ? Colors.white10 : cs.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          children: [
            TextField(
              controller: host,
              enabled: enabled,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Host / IP',
                hintText: 'z. B. 192.168.178.64 oder Tailscale-IP',
                prefixIcon: Icon(Icons.dns_outlined),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: user,
                    enabled: enabled,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Benutzer',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: port,
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<AuthMode>(
              segments: const [
                ButtonSegment(
                  value: AuthMode.password,
                  label: Text('Passwort'),
                  icon: Icon(Icons.password),
                ),
                ButtonSegment(
                  value: AuthMode.key,
                  label: Text('SSH-Key'),
                  icon: Icon(Icons.vpn_key_outlined),
                ),
              ],
              selected: {authMode},
              onSelectionChanged: enabled ? (s) => onAuthMode(s.first) : null,
            ),
            if (keyMode) ...[
              TextField(
                controller: privateKey,
                enabled: enabled,
                autocorrect: false,
                enableSuggestions: false,
                minLines: 3,
                maxLines: 6,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'Privater SSH-Key (PEM)',
                  hintText: '-----BEGIN OPENSSH PRIVATE KEY----- …',
                  alignLabelWithHint: true,
                ),
              ),
              TextField(
                controller: keyPassphrase,
                enabled: enabled,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Key-Passphrase (optional)',
                  prefixIcon: Icon(Icons.key_outlined),
                ),
              ),
            ],
            TextField(
              controller: password,
              enabled: enabled,
              obscureText: obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: keyMode ? 'sudo-Passwort' : 'Passwort',
                helperText: keyMode
                    ? 'für sudo auf dem Pi (leer lassen bei NOPASSWD-sudo)'
                    : null,
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  onPressed: onToggleObscure,
                  icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                  tooltip: obscure ? 'Anzeigen' : 'Verbergen',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dialog that owns its text controller (disposed via its own State lifecycle,
/// so it isn't used-after-dispose during the dialog's exit animation).
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

/// Passphrase prompt for the encrypted profile export/import. Own State so the
/// controllers are disposed after the dialog closes. With [confirm] it requires
/// a matching second entry (min length enforced) before enabling OK.
class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({
    required this.title,
    required this.body,
    required this.confirm,
  });
  final String title;
  final String body;
  final bool confirm;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _ctrl = TextEditingController();
  final _ctrl2 = TextEditingController();
  bool _obscure = true;
  static const _minLen = 6;

  @override
  void dispose() {
    _ctrl.dispose();
    _ctrl2.dispose();
    super.dispose();
  }

  String? get _error {
    if (widget.confirm && _ctrl.text.length < _minLen) {
      return 'Mindestens $_minLen Zeichen.';
    }
    if (widget.confirm && _ctrl2.text.isNotEmpty && _ctrl2.text != _ctrl.text) {
      return 'Die Passphrasen stimmen nicht überein.';
    }
    return null;
  }

  bool get _valid =>
      _ctrl.text.isNotEmpty &&
      (!widget.confirm ||
          (_ctrl.text.length >= _minLen && _ctrl2.text == _ctrl.text));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.body),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() {}),
            onSubmitted: _valid
                ? (_) => Navigator.pop(context, _ctrl.text)
                : null,
            decoration: InputDecoration(
              labelText: 'Passphrase',
              errorText: _error,
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          if (widget.confirm) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl2,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Passphrase wiederholen',
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _valid ? () => Navigator.pop(context, _ctrl.text) : null,
          child: const Text('OK'),
        ),
      ],
    );
  }
}

/// The app's brand mark: a shell prompt `>` with the green KYTH cursor dot.
/// Mirrors the launcher icon (assets/icon) so in-app branding matches.
class _PromptMark extends StatelessWidget {
  const _PromptMark({super.key, this.size = 64, this.chevronColor});

  /// Width in logical pixels; height follows the mark's aspect ratio.
  final double size;

  /// Colour of the `>` chevron. Defaults to the off-white used on the dark
  /// launcher icon; pass a theme colour where the background may be light.
  final Color? chevronColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size * (432 / 446),
      child: CustomPaint(
        painter: _PromptMarkPainter(
          chevronColor: chevronColor ?? const Color(0xFFE8EDE9),
        ),
      ),
    );
  }
}

class _PromptMarkPainter extends CustomPainter {
  const _PromptMarkPainter({required this.chevronColor});

  final Color chevronColor;

  // Group space (matches make_icon.py): 446 x 432, chevron tip at x=36,
  // vertex at x=236, dot centred at x=384. Vertical centre y=216.
  static const double _gw = 446;
  static const double _gh = 432;

  @override
  void paint(Canvas canvas, Size size) {
    final s = (size.width / _gw) < (size.height / _gh)
        ? size.width / _gw
        : size.height / _gh;
    canvas.translate((size.width - _gw * s) / 2, (size.height - _gh * s) / 2);
    canvas.scale(s);

    final chevron = Paint()
      ..color = chevronColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 72
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(36, 36)
      ..lineTo(236, 216)
      ..lineTo(36, 396);
    canvas.drawPath(path, chevron);

    canvas.drawCircle(const Offset(384, 216), 62, Paint()..color = kGreen);
  }

  @override
  bool shouldRepaint(_PromptMarkPainter oldDelegate) =>
      oldDelegate.chevronColor != chevronColor;
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    // Pinned dark regardless of the app theme: this is the first screen after
    // the dark splash video, so it must not flash a light background. Forcing
    // the whole dark ThemeData (not just the scaffold colour) keeps the unlock
    // button and every default consistent.
    return Theme(
      data: _buildTheme(Brightness.dark),
      child: Scaffold(
        backgroundColor: kBlack,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _PromptMark(key: Key('promptMark'), size: 76),
              const SizedBox(height: 12),
              const Text(
                'Pi-Tool',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: kGreen,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'by ',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  const KythWordmark(
                    fontSize: 12,
                    product: 'Systems',
                    background: Brightness.dark,
                  ), // lock screen is always dark
                ],
              ),
              const SizedBox(height: 6),
              const Text('Gesperrt', style: TextStyle(color: Colors.white54)),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onUnlock,
                icon: const Icon(Icons.lock_open),
                label: const Text('Entsperren'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// First-run disclaimer/terms the user must accept once. Placeholder text —
/// meant to be replaced by lawyer-reviewed terms for a Play Store release.
class _DisclaimerScreen extends StatelessWidget {
  const _DisclaimerScreen({
    required this.onAccept,
    required this.onDecline,
    required this.onPrivacy,
  });

  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onPrivacy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget bullet(String s) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('•  '),
          Expanded(child: Text(s)),
        ],
      ),
    );
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Row(
                children: [
                  _PromptMark(
                    size: 26,
                    chevronColor: theme.colorScheme.onSurface,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Willkommen bei Pi-Tool',
                    style: theme.textTheme.titleLarge,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Pi-Tool führt auf den von dir eingerichteten Geräten '
                        'Befehle über SSH aus — auch mit erhöhten Rechten '
                        '(sudo): Paket-Updates, Dienst- und System-Neustarts '
                        'sowie frei eingegebene Konsolen-Befehle.',
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Mit „Akzeptieren" bestätigst du:',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 10),
                      bullet(
                        'Du bist berechtigt, die Zielgeräte zu verwalten, '
                        'und nutzt Pi-Tool auf eigene Verantwortung.',
                      ),
                      bullet(
                        'KYTH. Systems übernimmt keine Haftung für Schäden '
                        'an System, Daten oder Hardware.',
                      ),
                      bullet(
                        'Deine Zugangsdaten bleiben verschlüsselt auf dem '
                        'Gerät — keine Cloud, keine Weitergabe, kein Tracking.',
                      ),
                      bullet(
                        'Pi-Tool ist ein inoffizielles Werkzeug und nicht '
                        'mit evcc oder Pi-hole verbunden.',
                      ),
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: onPrivacy,
                          icon: const Icon(
                            Icons.privacy_tip_outlined,
                            size: 18,
                          ),
                          label: const Text('Datenschutzerklärung'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '© 2026 KYTH. Systems UG (haftungsbeschränkt) i.G.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: onAccept,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
                child: const Text('Akzeptieren und starten'),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: onDecline,
                child: const Text('Ablehnen (App beenden)'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.message, required this.ok});

  final String message;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = ok ? scheme.primaryContainer : scheme.errorContainer;
    final fg = ok ? scheme.onPrimaryContainer : scheme.onErrorContainer;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            color: fg,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: TextStyle(color: fg)),
          ),
        ],
      ),
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({
    required this.release,
    required this.onDownload,
    required this.onDismiss,
  });

  final ReleaseInfo release;
  final VoidCallback onDownload;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.system_update, color: scheme.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Update ${release.version} verfügbar',
              style: TextStyle(color: scheme.onTertiaryContainer),
            ),
          ),
          TextButton(onPressed: onDownload, child: const Text('Laden')),
          IconButton(
            onPressed: onDismiss,
            icon: Icon(Icons.close, color: scheme.onTertiaryContainer),
            tooltip: 'Ausblenden',
          ),
        ],
      ),
    );
  }
}

class _LogView extends StatelessWidget {
  const _LogView({required this.lines, required this.controller});

  final List<String> lines;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 240,
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF11140F),
        borderRadius: BorderRadius.circular(10),
      ),
      child: lines.isEmpty
          ? const Text(
              'Noch keine Ausgabe. Aktionen (z. B. „Aktualisieren") erscheinen '
              'hier live, sobald du einen Dienst startest.',
              style: TextStyle(color: Color(0xFF8A8F84), fontSize: 13),
            )
          : SingleChildScrollView(
              controller: controller,
              child: SelectableText(
                lines.join('\n'),
                style: const TextStyle(
                  color: Color(0xFFB8F2C9),
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ),
    );
  }
}

/// Bottom sheet that shows evcc's live state, fetched read-only from its
/// Web-API. Loading / error / data are all rendered defensively.
class _ApiStatusSheet extends StatelessWidget {
  const _ApiStatusSheet({required this.future});

  final Future<EvccState> future;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: FutureBuilder<EvccState>(
          future: future,
          builder: (ctx, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 160,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              final e = snap.error;
              final msg = e is EvccApiException
                  ? e.message
                  : 'Live-Status nicht verfügbar.';
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('evcc-Live-Status', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.error_outline, color: theme.colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(child: Text(msg)),
                    ],
                  ),
                ],
              );
            }
            return _stateView(ctx, snap.data!);
          },
        ),
      ),
    );
  }

  Widget _stateView(BuildContext ctx, EvccState s) {
    final theme = Theme.of(ctx);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.bolt,
                color: _themeGreen(theme.brightness == Brightness.dark),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.siteTitle ?? 'evcc-Status',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (s.version != null)
                Text(
                  'v${s.version}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _metric(
            ctx,
            Icons.solar_power_outlined,
            'PV-Erzeugung',
            formatPower(s.pvPower),
          ),
          _metric(ctx, Icons.swap_vert, 'Netz', formatPower(s.gridPower)),
          _metric(
            ctx,
            Icons.home_outlined,
            'Hausverbrauch',
            formatPower(s.homePower),
          ),
          if (s.batteryConfigured)
            _metric(
              ctx,
              Icons.battery_charging_full,
              'Batterie',
              '${s.batterySoc != null ? '${s.batterySoc!.round()} %' : '—'}'
                  '  ·  ${formatPower(s.batteryPower)}',
            ),
          if (s.loadpoints.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Ladepunkte', style: theme.textTheme.labelLarge),
            for (final lp in s.loadpoints) _loadpoint(ctx, lp),
          ],
          const SizedBox(height: 8),
          Text(
            'Live aus der evcc-Web-API (nur Anzeige).',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric(BuildContext ctx, IconData icon, String label, String value) {
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _loadpoint(BuildContext ctx, EvccLoadpoint lp) {
    final theme = Theme.of(ctx);
    final bits = <String>[];
    if (lp.mode != null) bits.add('Modus ${lp.mode}');
    bits.add(
      lp.charging
          ? 'lädt ${formatPower(lp.chargePower)}'
          : (lp.connected ? 'verbunden' : 'frei'),
    );
    if (lp.vehicleSoc != null) bits.add('Fahrzeug ${lp.vehicleSoc!.round()} %');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        lp.charging ? Icons.ev_station : Icons.ev_station_outlined,
        color: lp.charging
            ? _themeGreen(theme.brightness == Brightness.dark)
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(lp.title),
      subtitle: Text(bits.join('  ·  ')),
    );
  }
}

/// Modal progress shown while the local network is being scanned for Pis.
class _ScanProgressDialog extends StatelessWidget {
  const _ScanProgressDialog({required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 16),
          Flexible(child: Text('Suche SSH-Geräte im WLAN …')),
        ],
      ),
      actions: [
        TextButton(onPressed: onCancel, child: const Text('Abbrechen')),
      ],
    );
  }
}
