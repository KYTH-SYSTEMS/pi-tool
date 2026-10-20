part of '../main.dart';

// Presentational widgets + sheets for the updater screen, split out of
// main.dart. Kept as a part so they stay library-private and share the
// top-level theme constants (kGreen/kBlack/kCard) without re-importing.

/// A green that stays legible on both themes — vivid kGreen on the dark
/// surfaces, darkened for light mode where bright kGreen washes out.
Color _themeGreen(bool dark) => dark ? kGreen : const Color(0xFF15803D);

/// Full-width connect button (under the connection settings). Neutral when untested,
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
      label = context.l10n.busyConnecting;
      fg = cs.onSurfaceVariant;
      border = cs.outlineVariant;
    } else if (result == true) {
      icon = Icon(Icons.check_circle, size: 18, color: okGreen);
      label = context.l10n.wConnected;
      fg = okGreen;
      bg = kGreen.withValues(alpha: dark ? 0.14 : 0.10);
      border = kGreen.withValues(alpha: 0.55);
    } else if (result == false) {
      icon = Icon(Icons.error_outline, size: 18, color: cs.error);
      label = context.l10n.wNoConnection;
      fg = cs.error;
      bg = cs.error.withValues(alpha: dark ? 0.14 : 0.08);
      border = cs.error.withValues(alpha: 0.55);
    } else {
      icon = Icon(Icons.wifi_tethering, size: 18, color: cs.onSurfaceVariant);
      label = context.l10n.wConnect;
      fg = cs.onSurfaceVariant;
      border = cs.outlineVariant;
    }

    // Full width, same height as "Pi im WLAN suchen" below it: connecting is
    // the form's main action, not a side button.
    return OutlinedButton.icon(
      onPressed: (enabled && !testing) ? onTap : null,
      icon: icon,
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: fg,
        backgroundColor: bg,
        side: BorderSide(color: border),
        minimumSize: const Size.fromHeight(44),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
  /// uploaded (→ the view reloads). [entries] is the listing on screen, so a
  /// file that would be replaced can be asked about first.
  final Future<bool> Function(String dir, List<DirEntry> entries) onUpload;

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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // The logic layer says why (Pi unreachable, login refused, …).
        _error = e is EvccUpdateException
            ? e.message
            : context.l10n.wDirLoadFailed;
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
                tooltip: context.l10n.wRefresh,
                onPressed: busy ? null : () => _load(_path),
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: context.l10n.wUploadFile,
                onPressed: busy
                    ? null
                    : () => _work(() async {
                        if (await widget.onUpload(_path, entries)) {
                          await _load(_path);
                        }
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
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
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
                      ListTile(enabled: false, title: Text(context.l10n.wEmpty)),
                    for (final e in entries)
                      ListTile(
                        leading: Icon(
                          e.isDir
                              ? Icons.folder
                              : Icons.insert_drive_file_outlined,
                        ),
                        title: Text(e.name),
                        // Listed as what it points to; opening, uploading
                        // over and deleting it differ for a link.
                        subtitle: e.isLink
                            ? Text(context.l10n.wSymlink)
                            : null,
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
                          tooltip: context.l10n.wActions,
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
                            PopupMenuItem(
                              value: 'delete',
                              child: Text(context.l10n.actionDelete),
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
    required this.onTest,
  });
  final AlertsStatus status;

  /// The ntfy destination the app knows for this Pi; an empty topic = none.
  final String initialServer;
  final String initialTopic;
  final VoidCallback onOpenNtfy;

  /// Sends a test push and resolves to what to tell the user about it. Shown
  /// in the sheet itself — a snack would lie beneath it.
  final Future<({bool ok, String text})> Function(String server, String topic)
      onTest;

  @override
  State<_AlertsSheet> createState() => _AlertsSheetState();
}

class _AlertsSheetState extends State<_AlertsSheet> {
  late final TextEditingController _serverCtrl = TextEditingController(
    text: widget.initialServer,
  );

  /// The Pi runs alerts, but the app knows no topic for it (set up from
  /// another device, or before a reinstall). The field then starts empty, with
  /// a hint: a made-up topic next to "active" would pass for the Pi's own.
  late final bool _topicUnknown =
      widget.status.enabled && widget.initialTopic.trim().isEmpty;

  /// On first setup the field starts on a generated topic: an ntfy topic IS the
  /// password (no account, no auth), so the default path has to be the safe one
  /// — a hand-typed "pi" publishes the Pi's health to whoever guesses it.
  late final TextEditingController _topicCtrl = TextEditingController(
    text: widget.initialTopic.trim().isNotEmpty
        ? widget.initialTopic
        : _topicUnknown
        ? ''
        : generateNtfyTopic(),
  );

  bool _topicMissing = false; // "turn on"/"test" was tapped with an empty topic
  bool _serverRefused = false; // … or with a server that is not http(s)
  bool _testing = false; // a test push is in flight → its button is off
  ({bool ok, String text})? _testResult; // of the last test, under the buttons
  final _testResultKey = GlobalKey(); // to scroll that line into view

  @override
  void initState() {
    super.initState();
    // Rebuild while typing so the "easy to guess" line tracks the actual field.
    _topicCtrl.addListener(_onTopicChanged);
    _serverCtrl.addListener(_onServerChanged);
  }

  void _onTopicChanged() => setState(() {
    if (_topicCtrl.text.trim().isNotEmpty) _topicMissing = false;
  });

  void _onServerChanged() {
    if (_serverRefused && isNtfyServerUsable(_server)) {
      setState(() => _serverRefused = false);
    }
  }

  /// The trimmed topic — or null, with the field marked, when there is none.
  String? _requireTopic() {
    final topic = _topicCtrl.text.trim();
    if (topic.isNotEmpty) return topic;
    setState(() => _topicMissing = true);
    return null;
  }

  /// The server — or null, with the field marked, when it is none the alerts
  /// can use: the logic layer takes http(s) only (alerts.dart). Said here, at
  /// the field, before the value is sent to the Pi or saved with the profile.
  String? _requireServer() {
    final server = _server;
    if (isNtfyServerUsable(server)) return server;
    setState(() => _serverRefused = true);
    return null;
  }

  Future<void> _runTest() async {
    final topic = _requireTopic();
    final server = _requireServer();
    if (topic == null || server == null) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    ({bool ok, String text})? result;
    try {
      result = await widget.onTest(server, topic);
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
          _testResult = result;
        });
        // The line is added below the buttons. With the keyboard up the sheet
        // scrolls, and that is past the end of what is visible.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final line = _testResultKey.currentContext;
          if (line == null) return;
          Scrollable.ensureVisible(
            line,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          );
        });
      }
    }
  }

  @override
  void dispose() {
    _topicCtrl.removeListener(_onTopicChanged);
    _serverCtrl.removeListener(_onServerChanged);
    _serverCtrl.dispose();
    _topicCtrl.dispose();
    super.dispose();
  }

  String get _server => _serverCtrl.text.trim().isEmpty
      ? 'https://ntfy.sh'
      : _serverCtrl.text.trim();

  void _rollTopic() {
    final topic = generateNtfyTopic();
    _topicCtrl.value = TextEditingValue(
      text: topic,
      selection: TextSelection.collapsed(offset: topic.length),
    );
  }

  /// Warning row in the app's usual style (amber icon, `cs.error`).
  Widget _warnRow(String text, {required bool strong}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: cs.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: strong ? cs.error : cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

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
        // Scrollable: with the topic warning + both fields the sheet is taller
        // than a small phone in landscape or with the keyboard up.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.healthAlertsTitle,
                  style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(context.l10n.wAlertsExplain),
              const SizedBox(height: 6),
              InkWell(
                onTap: widget.onOpenNtfy,
                // A tap target of at least 48 dp, not just the line of text.
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    widthFactor: 1,
                    heightFactor: 1,
                    child: Text(
                      context.l10n.wAlertsNtfyLink,
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                status.enabled
                    ? context.l10n.wAlertsActiveSince(status.lastCheck ?? '—')
                    : context.l10n.statusScheduleOff,
                style: TextStyle(
                  color: status.enabled
                      ? _themeGreen(theme.brightness == Brightness.dark)
                      : null,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (status.enabled && status.wrapperOutdated)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    context.l10n
                        .wrapperOutdatedHint(context.l10n.actionUpdate),
                    key: const Key('wrapperOutdatedHint'),
                    style: TextStyle(
                          color: Theme.of(context).colorScheme.error),
                  ),
                ),
              if (_topicUnknown)
                _warnRow(
                  context.l10n.wAlertsTopicUnknown(context.l10n.actionUpdate),
                  strong: false,
                ),
              const SizedBox(height: 12),
              _warnRow(context.l10n.wNtfyTopicPublicWarning, strong: false),
              const SizedBox(height: 14),
              TextField(
                controller: _topicCtrl,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: context.l10n.wNtfyTopicLabel,
                  hintText: context.l10n.wNtfyTopicHint,
                  helperText: context.l10n.wNtfyTopicHelper,
                  errorText: _topicMissing
                      ? context.l10n.wEnterNtfyTopic
                      : null,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.casino_outlined),
                    tooltip: context.l10n.wNtfyTopicDice,
                    onPressed: _rollTopic,
                  ),
                ),
              ),
              if (isWeakNtfyTopic(_topicCtrl.text))
                _warnRow(context.l10n.wNtfyTopicWeak, strong: true),
              const SizedBox(height: 10),
              TextField(
                controller: _serverCtrl,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: context.l10n.wNtfyServerLabel,
                  errorText: _serverRefused
                      ? context.l10n.wNtfyServerInvalid
                      : null,
                  errorMaxLines: 3,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        final topic = _requireTopic();
                        final server = _requireServer();
                        if (topic == null || server == null) return;
                        Navigator.pop(context, (
                          enable: true,
                          server: server,
                          topic: topic,
                        ));
                      },
                      child: Text(
                        status.enabled
                            ? context.l10n.actionUpdate
                            : context.l10n.turnOn,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    // Off while a test runs: every tap is an SSH connection.
                    onPressed: _testing ? null : _runTest,
                    child: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(context.l10n.wTest),
                  ),
                ],
              ),
              if (_testResult != null)
                Padding(
                  key: _testResultKey,
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _testResult!.text,
                    key: const Key('alertsTestResult'),
                    style: TextStyle(
                      fontSize: 13,
                      color: _testResult!.ok
                          ? _themeGreen(theme.brightness == Brightness.dark)
                          : theme.colorScheme.error,
                    ),
                  ),
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
                    child: Text(context.l10n.turnOff),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "What's eating my disk?" sheet: biggest folders/files at a path, tap a folder
/// to drill in, an up button to go back. Each level is fetched on demand.
class _StorageExplorerSheet extends StatefulWidget {
  const _StorageExplorerSheet({
    required this.initialPath,
    required this.initialEntries,
    required this.fetch,
  });
  final String initialPath;
  final List<DiskEntry> initialEntries;
  final Future<List<DiskEntry>> Function(String path) fetch;

  @override
  State<_StorageExplorerSheet> createState() => _StorageExplorerSheetState();
}

class _StorageExplorerSheetState extends State<_StorageExplorerSheet> {
  late String _path = widget.initialPath;
  late List<DiskEntry> _entries = widget.initialEntries;
  bool _loading = false;
  String? _error;
  String? _failedPath; // the folder [_error] is about, for "Erneut versuchen"

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
      _failedPath = null;
    });
    try {
      final e = await widget.fetch(path);
      if (!mounted) return;
      setState(() {
        _path = path;
        _entries = e;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // [_path] and [_entries] stay: at "/" there is no way up, so a list
      // replaced by the error would leave nothing to tap.
      // What the updater could not classify reads "Details im Terminal-Log",
      // and the drill-down writes none: that one stays generic, too.
      setState(() {
        _loading = false;
        _failedPath = path;
        _error = e is EvccUpdateException && e.kind != UpdateErrorKind.unknown
            ? e.message
            : context.l10n.wLoadFailedPerms;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final atRoot = _path == '/';
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.8,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
            child: Row(
              children: [
                IconButton(
                  tooltip: context.l10n.wParentFolder,
                  onPressed:
                      (atRoot || _loading) ? null : () => _load(parentRemotePath(_path)),
                  icon: const Icon(Icons.arrow_upward),
                ),
                Expanded(
                  child: Text(_path,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12)),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              // The retry below the reason, not next to it: in one row a
              // large font left the reason no width and pushed the row past
              // its edge.
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline,
                          size: 18,
                          color: Theme.of(context).colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('$_failedPath: $_error',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      ),
                    ],
                  ),
                  TextButton(
                    onPressed: () => _load(_failedPath!),
                    child: Text(context.l10n.wRetry),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _entries.isEmpty
                        ? Center(child: Text(context.l10n.wEmpty))
                        : ListView.builder(
                            itemCount: _entries.length,
                            itemBuilder: (_, i) {
                              final e = _entries[i];
                              return ListTile(
                                dense: true,
                                leading: Icon(e.isDir
                                    ? Icons.folder
                                    : Icons.insert_drive_file_outlined),
                                title: Text(e.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                trailing: Text(formatBytes(e.bytes),
                                    style: const TextStyle(
                                        fontFamily: 'monospace', fontSize: 12)),
                                onTap: e.isDir ? () => _load(e.path) : null,
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}

/// Docker container overview: one row per container (state dot, status, image)
/// with restart + logs actions. Each level/refresh is fetched on demand.
class _DockerSheet extends StatefulWidget {
  const _DockerSheet({
    required this.initial,
    required this.refresh,
    required this.onRestart,
    required this.onLogs,
    required this.onUpdate,
  });
  final List<DockerContainer> initial;
  final Future<List<DockerContainer>> Function() refresh;
  final Future<void> Function(String name) onRestart;
  final Future<void> Function(String name) onLogs;

  /// Hand this container to the caller for updating. The sheet CLOSES on it
  /// (the caller pops with the name): a pull+recreate runs for minutes and
  /// belongs in the app's normal busy/cancel/keep-alive path, not in a sheet.
  final void Function(String name) onUpdate;

  @override
  State<_DockerSheet> createState() => _DockerSheetState();
}

class _DockerSheetState extends State<_DockerSheet> {
  late List<DockerContainer> _list = widget.initial;
  bool _busy = false;

  Future<void> _reload() async {
    setState(() => _busy = true);
    try {
      final l = await widget.refresh();
      if (mounted) setState(() => _list = l);
    } catch (_) {
      // keep the last list
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(Future<void> Function() body) async {
    setState(() => _busy = true);
    try {
      await body();
    } catch (_) {
      // Reporting belongs to the caller (it owns the l10n + dialog context);
      // swallowing here only stops an unawaited future from tearing down the
      // zone. Never leave this without the catch: the callers are fired as
      // `_run(...).then(...)`, so a throw would vanish unhandled.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.8,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(context.l10n.actionDockerContainers,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (_busy)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                IconButton(
                  tooltip: context.l10n.wRefresh,
                  onPressed: _busy ? null : _reload,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _list.isEmpty
                ? Center(child: Text(context.l10n.wNoContainers))
                : ListView.builder(
                    itemCount: _list.length,
                    itemBuilder: (_, i) {
                      final c = _list[i];
                      final running = c.state == 'running';
                      final rollback = c.name.endsWith('-evccpitool-old');
                      return ListTile(
                        leading: Icon(Icons.circle,
                            size: 12,
                            color: running ? kGreen : cs.onSurfaceVariant),
                        title: Text(c.name),
                        subtitle: Text('${c.status}\n${c.image}',
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        isThreeLine: true,
                        trailing: PopupMenuButton<String>(
                          enabled: !_busy,
                          onSelected: (v) {
                            if (v == 'restart') {
                              _run(() => widget.onRestart(c.name))
                                  .then((_) => _reload());
                            } else if (v == 'logs') {
                              _run(() => widget.onLogs(c.name));
                            } else if (v == 'update') {
                              widget.onUpdate(c.name); // closes the sheet
                            }
                          },
                          itemBuilder: (_) => [
                            // Our own rollback containers are the safety net of
                            // the LAST update: updating one is refused anyway,
                            // and STARTING one would run a stale duplicate of a
                            // service that is already up. Only logs make sense.
                            if (!rollback) ...[
                              PopupMenuItem(
                                  value: 'update',
                                  child: Text(context.l10n.actionUpdate)),
                              PopupMenuItem(
                                  value: 'restart',
                                  child: Text(context.l10n.actionRestart)),
                            ],
                            PopupMenuItem(
                                value: 'logs',
                                child: Text(context.l10n.wLogs)),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Service-log sheet with an optional **Live** mode: while on, it re-fetches the
/// log tail every few seconds (journalctl-follow-ish via polling — no PTY, no
/// background service). The timer is cancelled on dispose. It opens at the
/// newest entry and stays there while following; a fetch that fails leaves
/// the last log in place under a line that says so.
class _LiveLogSheet extends StatefulWidget {
  const _LiveLogSheet({
    required this.title,
    required this.initial,
    required this.fetch,
  });
  final String title;
  final String initial;
  final Future<String> Function() fetch;

  @override
  State<_LiveLogSheet> createState() => _LiveLogSheetState();
}

class _LiveLogSheetState extends State<_LiveLogSheet> {
  late String _logs = widget.initial;
  bool _live = false;
  bool _loading = false;
  bool _failed = false; // the last fetch failed: what is shown is older
  Timer? _timer;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollToEnd(); // a log is read from its newest entry
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// Jumps to the newest entry once the text is laid out.
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// Whether the view stands at the newest entry — false once someone
  /// scrolled up to read.
  bool get _atEnd =>
      !_scroll.hasClients ||
      _scroll.position.pixels >= _scroll.position.maxScrollExtent - 24;

  void _toggleLive(bool on) {
    setState(() => _live = on);
    _timer?.cancel();
    if (on) {
      _timer = Timer.periodic(const Duration(seconds: 3), (_) {
        // Not beneath the app lock: every refresh is an SSH login. The sheet
        // stays open there, the polling picks up again with the unlock.
        if (AppLockLayer.maybeOf(context)?.locked ?? false) return;
        _refresh();
      });
      _refresh();
    }
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final l = await widget.fetch();
      if (!mounted) return;
      // Stay at the newest entry — unless someone scrolled up to read.
      final atEnd = _atEnd;
      setState(() {
        _logs = l;
        _loading = false;
        _failed = false;
      });
      if (atEnd) _scrollToEnd();
    } catch (_) {
      if (!mounted) return;
      // The log on screen stays; say that it is no longer the current one.
      // The line takes its room from the log: without following it here, the
      // newest entry slid out of view and the next fetch took that for
      // "scrolled up" — one failed poll ended the following.
      final atEnd = _atEnd;
      setState(() {
        _loading = false;
        _failed = true;
      });
      if (atEnd) _scrollToEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.8,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(widget.title,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (_loading)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text(context.l10n.wLive),
                Switch(value: _live, onChanged: _toggleLive),
                IconButton(
                  tooltip: context.l10n.wRefresh,
                  onPressed: _loading ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_failed)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  Icon(Icons.error_outline,
                      size: 16, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      context.l10n.wLogRefreshFailed,
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                _logs.trim().isEmpty ? context.l10n.wNoOutput : _logs,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Read-only security-audit result sheet: one traffic-light row per finding.
class _SecurityReportSheet extends StatelessWidget {
  const _SecurityReportSheet({required this.findings, this.onFix});
  final List<SecurityFinding> findings;

  /// Called when the user taps "Beheben" on a fixable finding. Null renders
  /// the sheet read-only (e.g. demo mode).
  final void Function(SecurityFinding f, SecurityFix fix)? onFix;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    (IconData, Color) visual(SecurityLevel l) => switch (l) {
          SecurityLevel.ok => (Icons.check_circle, kGreen),
          SecurityLevel.warn => (Icons.warning_amber_rounded, cs.error),
          SecurityLevel.info => (Icons.info_outline, cs.onSurfaceVariant),
        };
    final warnings = findings.where((f) => f.level == SecurityLevel.warn).length;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.actionSecurityCheck,
                style: Theme.of(context).textTheme.titleMedium),
            subtitle: Text(warnings == 0
                ? context.l10n.wNoWarnings
                : context.l10n.wWarningsFound(warnings)),
          ),
          const Divider(height: 1),
          for (final f in findings)
            Builder(builder: (context) {
              final (icon, color) = visual(f.level);
              final fix = securityFixFor(f);
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
                leading: Icon(icon, color: color),
                title: Text(f.title),
                subtitle: Text(f.detail),
                trailing: (fix != null && onFix != null)
                    ? TextButton(
                        onPressed: () => onFix!(f, fix),
                        child: Text(context.l10n.actionFixSecurity),
                      )
                    : null,
              );
            }),
          const SizedBox(height: 4),
          Text(
            context.l10n.wReadOnlyCheckNote,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant),
          ),
        ],
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

/// How „Alles aktualisieren" on one Pi ended in the multi-Pi overview. A
/// [note] is shown as the row's text: neither success nor failure — the Pi-Job
/// runs on without the app, or the Pi is busy with another one — or a success
/// with a remark. [error] is a failure's reason, when there is one.
typedef PiUpdateOutcome = ({bool ok, String? note, String? error});

/// Multi-Pi overview: a traffic-light row per profile. Probes each Pi
/// sequentially (fail-soft) so one unreachable Pi doesn't block the rest.
class _MultiPiDashboardPage extends StatefulWidget {
  const _MultiPiDashboardPage({
    required this.profiles,
    required this.probe,
    required this.update,
    required this.confirmBulk,
    required this.onBulkStart,
    required this.onBulkEnd,
  });
  final List<Profile> profiles;
  final Future<PiSnapshot> Function(Profile) probe;

  /// Runs „Alles aktualisieren" on one Pi and reports how it ended. Sequenced
  /// by the page across all reachable Pis (fail-soft).
  final Future<PiUpdateOutcome> Function(Profile) update;

  /// Asks before a bulk update; false leaves every Pi as it is.
  final Future<bool> Function() confirmBulk;

  /// Bracket a bulk update — before its first Pi, after its last, also when
  /// it ends early — so the app is kept alive for the whole run and the Pis
  /// still waiting are not left out once the app goes to the background.
  final Future<void> Function() onBulkStart;
  final Future<void> Function() onBulkEnd;

  @override
  State<_MultiPiDashboardPage> createState() => _MultiPiDashboardPageState();
}

class _MultiPiDashboardPageState extends State<_MultiPiDashboardPage> {
  final Map<int, PiSnapshot> _results = {};
  final Map<int, PiUpdateOutcome> _updateResult = {}; // index → how it ended
  int _probing = -1;
  int _updating = -1;
  bool _bulkRunning = false;
  bool _asking = false; // the bulk update's confirmation is open
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

  /// What the traffic light says, for a screen reader: the colour alone tells
  /// a warning from "all fine" — the health text next to it is the same kind
  /// of line in both cases.
  String _labelFor(BuildContext ctx, PiSnapshot s) {
    if (!s.reachable) return ctx.l10n.probeUnreachable;
    if (s.warning) return ctx.l10n.wStatusWarning;
    if (s.updates) return ctx.l10n.wUpdatesAvailable;
    return ctx.l10n.wStatusOk;
  }

  /// Indices of reachable Pis. Every one of them takes part in a bulk update:
  /// a Home Assistant or evcc container reports no update state, so only the
  /// pull itself finds out whether a Pi without a known update has one.
  List<int> get _updatable => [
        for (var i = 0; i < widget.profiles.length; i++)
          if (_results[i]?.reachable ?? false) i
      ];

  /// Sequentially updates everything on every reachable Pi. Fail-soft: one
  /// Pi's failure doesn't stop the rest; cancellable by leaving the page.
  Future<void> _updateAll() async {
    if (_asking) return;
    _asking = true;
    final go = await widget.confirmBulk();
    _asking = false;
    if (!go || !mounted || _cancelled) return;
    setState(() {
      _bulkRunning = true;
      _updateResult.clear();
    });
    await widget.onBulkStart();
    try {
      await _updateEach();
    } finally {
      await widget.onBulkEnd();
    }
    if (!mounted) return;
    setState(() => _bulkRunning = false);
    // Re-probe so the traffic lights reflect the new state.
    if (!_cancelled) await _run();
  }

  /// The Pis of one bulk update, one after the other.
  Future<void> _updateEach() async {
    for (final i in _updatable) {
      if (_cancelled || !mounted) break;
      setState(() => _updating = i);
      PiUpdateOutcome outcome;
      try {
        outcome = await widget.update(widget.profiles[i]);
      } catch (_) {
        outcome = (ok: false, note: null, error: null);
      }
      if (!mounted) return;
      setState(() {
        _updateResult[i] = outcome;
        _updating = -1;
      });
    }
  }

  /// "Neu prüfen": a fresh look at every Pi. The outcome rows of an earlier
  /// bulk update go with it — they take precedence over the probe result and
  /// would keep the re-check invisible for exactly those Pis.
  void _recheck() {
    setState(_updateResult.clear);
    _run();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final probed = _results.length == widget.profiles.length;
    final idle = probed && !_bulkRunning && _probing == -1;
    const spinner = SizedBox(
        width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2));
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.wAllPis),
        actions: [
          if (_updatable.isNotEmpty)
            IconButton(
              tooltip: context.l10n.wUpdateAllWithUpdates,
              onPressed: idle ? _updateAll : null,
              icon: const Icon(Icons.system_update),
            ),
          IconButton(
            tooltip: context.l10n.wRecheck,
            onPressed: idle ? _recheck : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_bulkRunning) const LinearProgressIndicator(),
          Expanded(
            child: ListView.builder(
              itemCount: widget.profiles.length,
              itemBuilder: (ctx, i) {
                final p = widget.profiles[i];
                final snap = _results[i];
                final upd = _updateResult[i];
                Widget leading;
                String subtitle;
                int? subtitleLines = 2;
                if (_updating == i) {
                  leading = spinner;
                  subtitle = ctx.l10n.wUpdating;
                } else if (upd?.note != null) {
                  // A Pi-Job that runs on, or a busy Pi: amber like in the
                  // main view, never the red "fehlgeschlagen". The sentence
                  // says what to do next, so it gets the room to be read.
                  leading =
                      Icon(Icons.info_outline, color: Colors.amber.shade700);
                  subtitle = upd!.note!;
                  // In full, at any font size: the end of this text is the
                  // instruction (where to follow the job).
                  subtitleLines = null;
                } else if (upd != null) {
                  leading = Icon(upd.ok ? Icons.check_circle : Icons.error,
                      color: upd.ok ? kGreen : cs.error);
                  subtitle = upd.ok
                      ? ctx.l10n.wUpdated
                      : upd.error != null
                          ? ctx.l10n.wUpdateFailedReason(upd.error!)
                          : ctx.l10n.wUpdateFailed;
                } else if (snap == null) {
                  leading = i == _probing
                      ? spinner
                      : Icon(Icons.circle_outlined,
                          color: cs.onSurfaceVariant);
                  subtitle =
                      i == _probing ? ctx.l10n.wChecking : ctx.l10n.wWaiting;
                } else {
                  leading = Icon(Icons.circle,
                      color: _colorFor(ctx, snap),
                      semanticLabel: _labelFor(ctx, snap));
                  subtitle = [
                    if (snap.updates) ctx.l10n.wUpdatesAvailable,
                    snap.detail,
                  ].where((s) => s.isNotEmpty).join('  ·  ');
                }
                return ListTile(
                  leading: leading,
                  title: Text(p.name),
                  subtitle: Text(subtitle,
                      maxLines: subtitleLines,
                      overflow: subtitleLines == null
                          ? null
                          : TextOverflow.ellipsis),
                  trailing: (_updating != i &&
                          upd == null &&
                          (snap?.updates ?? false))
                      ? const Icon(Icons.system_update, size: 18)
                      : null,
                );
              },
            ),
          ),
        ],
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
      appBar: AppBar(title: Text(context.l10n.menuSetupPi)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            context.l10n.wSetupIntro,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          step(
            1,
            context.l10n.wSetupStep1Title,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.l10n.wSetupStep1Body),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  onPressed: onDownloadImager,
                  icon: const Icon(Icons.download, size: 18),
                  label: Text(context.l10n.wDownloadImager),
                ),
              ],
            ),
          ),
          step(
            2,
            context.l10n.wSetupStep2Title,
            Text(context.l10n.wSetupStep2Body),
          ),
          step(
            3,
            context.l10n.wSetupStep3Title,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.l10n.wSetupStep3Body),
                bullet(context.l10n.wSetupBulletSsh),
                bullet(context.l10n.wSetupBulletUserPass),
                bullet(context.l10n.wSetupBulletHostname),
                bullet(context.l10n.wSetupBulletWifi),
              ],
            ),
          ),
          step(
            4,
            context.l10n.wSetupStep4Title,
            Text(context.l10n.wSetupStep4Body),
          ),
          step(
            5,
            context.l10n.wSetupStep5Title,
            Text(context.l10n.wSetupStep5Body),
          ),
          Text(
            context.l10n.wSetupTip,
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
/// or null when the user backs out (cancel) — with unsaved changes only after
/// they confirmed that those may go.
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
  bool _dirty = false; // the text differs from what was loaded

  @override
  void initState() {
    super.initState();
    _c.addListener(_trackDirty);
  }

  void _trackDirty() {
    final dirty = _c.text != widget.initial;
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Back (gesture, system key or the app-bar arrow) with unsaved changes:
  /// ask before they are gone. Dismissing the dialog means "keep editing".
  Future<void> _confirmDiscard() async {
    final cs = Theme.of(context).colorScheme;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.dialogDiscardEditsTitle),
        content: Text(ctx.l10n.dialogDiscardEditsBody(widget.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.actionKeepEditing),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: cs.error, foregroundColor: cs.onError),
            child: Text(ctx.l10n.actionDiscard),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    // Saving pops with the text directly (Navigator.pop is not held back by
    // the PopScope); only backing out of a changed text goes through the
    // question.
    return PopScope<String>(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            IconButton(
              icon: const Icon(Icons.save),
              tooltip: context.l10n.actionSave,
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
    this.warning,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool locked;

  /// Optional second subtitle line in warning style — used for a configuration
  /// that works but is unsafe (e.g. a guessable ntfy topic), so the user sees it
  /// without having to reopen the sheet.
  final String? warning;

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
        subtitle: warning == null
            ? Text(subtitle)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(subtitle),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          size: 15, color: cs.error),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          warning!,
                          style: TextStyle(
                              fontSize: 12, height: 1.3, color: cs.error),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
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
  const _CardAction(this.label, this.onTap,
      {this.pro = false, this.destructive = false, this.lockedHint});
  final String label;
  final VoidCallback onTap;
  final bool pro;

  /// Renders the menu label in the error colour (e.g. shutdown/reboot).
  final bool destructive;

  /// Non-null → the entry is greyed out and shows this line under its label:
  /// what has to happen first (the same look as a locked app-menu entry).
  final String? lockedHint;
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
    this.primaryIsUpdate = true,
    this.onOpenWeb,
    this.actions = const [],
    this.isPro = true,
    this.liveLines = const [],
    this.liveMaxLines = 1,
    this.notes = const [],
  });

  final ServiceStatus status;
  final IconData icon;
  final String primaryLabel; // "Aktualisieren" | "Installieren"
  final VoidCallback onPrimary;
  final bool enabled;

  /// Whether the primary button is the update. Only then may a known
  /// up-to-date state replace it with the disabled "Aktuell". False where the
  /// primary follows the service's state (Pi Connect: Anmelden / Web öffnen,
  /// Tailscale: Verbinden / Trennen) — that action must stay reachable.
  final bool primaryIsUpdate;
  final VoidCallback? onOpenWeb;
  final List<_CardAction> actions;
  final bool isPro; // false → Pro actions show a lock badge

  /// Compact live measurements under the detail line (evcc card: PV/grid/house
  /// and battery/loadpoint). Empty = nothing measurable or unreachable — the
  /// card then renders exactly as it did before, never an empty row.
  final List<String> liveLines;

  /// Lines each [liveLines] entry may wrap to (evcc's values: one).
  final int liveMaxLines;

  /// Lines under [liveLines] that are shown in full, however often they wrap
  /// (Tailscale: a sentence and an address) — [liveMaxLines] does not apply.
  /// Half an address is of no use to anyone.
  final List<String> notes;

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
    // Never in place of a primary that is not the update (see primaryIsUpdate).
    final upToDate = primaryIsUpdate &&
        status.installed &&
        status.updateKnown &&
        !status.updateAvailable;

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
                          ? context.l10n.wStatusUpdate
                          : (status.active
                                ? context.l10n.serviceActive
                                : context.l10n.serviceInactive))
                    : context.l10n.wNotInstalled,
                style: TextStyle(color: ledText, fontSize: 12),
              ),
              if (actions.isNotEmpty)
                PopupMenuButton<int>(
                  // Stable per-service key so callers/tests can target a card's
                  // menu regardless of card order.
                  key: ValueKey('menu-${status.id}'),
                  enabled: enabled,
                  tooltip: context.l10n.wServiceActions(status.name),
                  icon: const Icon(Icons.more_vert),
                  onSelected: (i) => actions[i].onTap(),
                  itemBuilder: (_) => [
                    for (var i = 0; i < actions.length; i++)
                      PopupMenuItem(
                        value: i,
                        enabled: actions[i].lockedHint == null,
                        child: actions[i].lockedHint != null
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(actions[i].label),
                                  Text(
                                    actions[i].lockedHint!,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              )
                            : (actions[i].pro && !isPro)
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
                            : Text(
                                actions[i].label,
                                style: actions[i].destructive
                                    ? TextStyle(color: cs.error)
                                    : null,
                              ),
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
          // Live measurements (evcc): the values users came for, on the card
          // itself instead of two taps away in the ⋮ (GitHub issue #22).
          if (status.installed && (liveLines.isNotEmpty || notes.isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(left: 30, bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in liveLines)
                    Text(line, style: mono, maxLines: liveMaxLines,
                        overflow: TextOverflow.ellipsis),
                  for (final line in notes) Text(line, style: mono),
                ],
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
                          label: Text(context.l10n.wUpToDate),
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
                    tooltip: context.l10n.wOpenInterface,
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
    required this.expanded,
    required this.onToggleExpanded,
    required this.autoConnect,
    required this.onAutoConnect,
    this.onSetupKey,
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

  /// Whether the connection fields are shown. Collapsed once credentials are set
  /// (the big SSH-key PEM field otherwise eats a lot of vertical space).
  final bool expanded;
  final VoidCallback onToggleExpanded;

  /// Whether THIS Pi connects by itself when the app starts. At most one Pi
  /// may — see [onAutoConnect].
  final bool autoConnect;
  final ValueChanged<bool> onAutoConnect;

  /// Runs the automatic per-Pi SSH-key setup (generate → install → switch).
  /// Offered inline while the SSH-Key segment is selected but no key exists yet.
  final VoidCallback? onSetupKey;

  /// Compact one-line stand-in shown in the header while collapsed.
  String _summary(BuildContext context) {
    final h = host.text.trim();
    if (h.isEmpty) return context.l10n.wNotSetUp;
    final u = user.text.trim().isEmpty ? 'pi' : user.text.trim();
    return '$u@$h · ${authMode == AuthMode.key ? context.l10n.wSshKey : context.l10n.wPassword}';
  }

  @override
  Widget build(BuildContext context) {
    final keyMode = authMode == AuthMode.key;
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: dark ? kCard : cs.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: dark ? Colors.white10 : cs.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          // Tappable header — always visible, toggles the fields below. When
          // collapsed it shows a compact summary instead of the full form.
          InkWell(
            key: const ValueKey('conn-card-header'),
            onTap: onToggleExpanded,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 8, expanded ? 4 : 12),
              child: Row(
                children: [
                  Icon(
                      authMode == AuthMode.key
                          ? Icons.vpn_key_outlined
                          : Icons.lock_outline,
                      size: 20,
                      color: cs.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(context.l10n.wCredentials,
                            style: textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        if (!expanded)
                          Text(_summary(context),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      color: cs.onSurfaceVariant),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                children: [
                  TextField(
                    controller: host,
                    enabled: enabled,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: context.l10n.wHostIpLabel,
                hintText: context.l10n.wHostHint,
                prefixIcon: const Icon(Icons.dns_outlined),
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
                    decoration: InputDecoration(
                      labelText: context.l10n.wUser,
                      prefixIcon: const Icon(Icons.person_outline),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: port,
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: context.l10n.wPort),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<AuthMode>(
              segments: [
                ButtonSegment(
                  value: AuthMode.password,
                  label: Text(context.l10n.wPassword),
                  icon: const Icon(Icons.password),
                ),
                ButtonSegment(
                  value: AuthMode.key,
                  label: Text(context.l10n.wSshKey),
                  icon: const Icon(Icons.vpn_key_outlined),
                ),
              ],
              selected: {authMode},
              onSelectionChanged: enabled ? (s) => onAuthMode(s.first) : null,
            ),
            if (keyMode) ...[
              // Per-Pi convenience: while the SSH-Key segment is on but no key
              // is set yet, offer the automatic setup right here. Rebuilds live
              // off the key field, so it disappears the moment a key is present
              // (pasted or freshly generated).
              if (onSetupKey != null)
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: privateKey,
                  builder: (context, value, _) {
                    if (value.text.trim().isNotEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: dark ? Colors.white12 : cs.outlineVariant),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(context.l10n.wNoKeyYet,
                              style: Theme.of(context).textTheme.labelLarge),
                          const SizedBox(height: 8),
                          FilledButton.tonalIcon(
                            onPressed: enabled ? onSetupKey : null,
                            icon: const Icon(Icons.vpn_key_outlined, size: 18),
                            label: Text(context.l10n.wSetupKeyAuto),
                            style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(44)),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            context.l10n.wSetupKeyExplain,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              TextField(
                controller: privateKey,
                enabled: enabled,
                autocorrect: false,
                enableSuggestions: false,
                minLines: 3,
                maxLines: 6,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: InputDecoration(
                  labelText: context.l10n.wPrivateKeyLabel,
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
                decoration: InputDecoration(
                  labelText: context.l10n.wKeyPassphraseLabel,
                  prefixIcon: const Icon(Icons.key_outlined),
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
                labelText: keyMode ? context.l10n.wSudoPassword : context.l10n.wPassword,
                helperText: keyMode ? context.l10n.wSudoPasswordHelper : null,
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  onPressed: onToggleObscure,
                  icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                  tooltip: obscure ? context.l10n.wShow : context.l10n.wHide,
                ),
              ),
            ),
            // Belongs to SETTING UP a Pi, not to switching between them — so it
            // sits with the credentials rather than in the Pi picker.
            SwitchListTile(
              key: const Key('autoConnectSwitch'),
              value: autoConnect,
              onChanged: enabled ? onAutoConnect : null,
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.wAutoConnect),
              subtitle: Text(context.l10n.wAutoConnectHint,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Dialog that owns its text controller (disposed via its own State lifecycle,
/// so it isn't used-after-dispose during the dialog's exit animation).
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.initial,
    this.label = 'Name',
    this.confirmLabel = 'OK',
    this.hint,
    this.fieldKey,
    this.mono = false,
  });

  final String title;
  final String initial;
  final String label;
  final String confirmLabel;
  final String? hint;
  final Key? fieldKey;
  final bool mono; // monospace field (e.g. a shell command)

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
        key: widget.fieldKey,
        controller: _ctrl,
        autofocus: true,
        style: widget.mono
            ? const TextStyle(fontFamily: 'monospace', fontSize: 14)
            : null,
        decoration: InputDecoration(
            labelText: widget.label, hintText: widget.hint),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: Text(widget.confirmLabel),
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
  static const _minLen = kExportMinPassphraseLength;

  @override
  void dispose() {
    _ctrl.dispose();
    _ctrl2.dispose();
    super.dispose();
  }

  String? _errorText(BuildContext context) {
    if (widget.confirm && _ctrl.text.length < _minLen) {
      return context.l10n.wMinChars(_minLen);
    }
    if (widget.confirm && _ctrl2.text.isNotEmpty && _ctrl2.text != _ctrl.text) {
      return context.l10n.wPassphrasesNoMatch;
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
      // With the keyboard up a small phone has less room than the text and the
      // two fields take: they scroll then, instead of sliding under the buttons.
      scrollable: true,
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
              labelText: context.l10n.wPassphrase,
              errorText: _errorText(context),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                tooltip: _obscure ? context.l10n.wShow : context.l10n.wHide,
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
              decoration: InputDecoration(
                labelText: context.l10n.wRepeatPassphrase,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
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
      data: buildAppTheme(Brightness.dark),
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
              Text(context.l10n.wLocked,
                  style: const TextStyle(color: Colors.white54)),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onUnlock,
                icon: const Icon(Icons.lock_open),
                label: Text(context.l10n.wUnlock),
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
                  Flexible(
                    child: Text(
                      context.l10n.wWelcomeTitle,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(context.l10n.wDisclaimerIntro),
                      const SizedBox(height: 14),
                      Text(
                        context.l10n.wDisclaimerConfirmIntro,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 10),
                      bullet(context.l10n.wDisclaimerBullet1),
                      bullet(context.l10n.wDisclaimerBullet2),
                      bullet(context.l10n.wDisclaimerBullet3),
                      bullet(context.l10n.wDisclaimerBullet4),
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: onPrivacy,
                          icon: const Icon(
                            Icons.privacy_tip_outlined,
                            size: 18,
                          ),
                          label: Text(context.l10n.wPrivacyPolicy),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '© 2026 KYTH. Systems UG (haftungsbeschränkt)',
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
                child: Text(context.l10n.wAcceptAndStart),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: onDecline,
                child: Text(context.l10n.wDeclineExit),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A Pi-Job the job bar offers to follow.
class _JobView {
  const _JobView(this.ref, {required this.since});
  final JobRef ref;
  final DateTime since;
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner(
      {required this.message, required this.ok, this.warn = false});

  final String message;
  final bool ok;

  /// Amber: neither success nor failure (a Pi-Job keeps running on the Pi).
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = ok
        ? scheme.primaryContainer
        : warn
            ? scheme.tertiaryContainer
            : scheme.errorContainer;
    final fg = ok
        ? scheme.onPrimaryContainer
        : warn
            ? scheme.onTertiaryContainer
            : scheme.onErrorContainer;
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
            ok
                ? Icons.check_circle_outline
                : warn
                    ? Icons.sync
                    : Icons.error_outline,
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
              context.l10n.wUpdateAvailableVersion(release.version),
              style: TextStyle(color: scheme.onTertiaryContainer),
            ),
          ),
          TextButton(
              onPressed: onDownload, child: Text(context.l10n.wDownloadShort)),
          IconButton(
            onPressed: onDismiss,
            icon: Icon(Icons.close, color: scheme.onTertiaryContainer),
            tooltip: context.l10n.wDismiss,
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
          ? Text(
              context.l10n.wLogEmpty,
              style: const TextStyle(color: Color(0xFF8A8F84), fontSize: 13),
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
                  : ctx.l10n.wLiveStatusUnavailable;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ctx.l10n.wEvccLiveStatus,
                      style: theme.textTheme.titleMedium),
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
                  s.siteTitle ?? ctx.l10n.wEvccStatus,
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
            ctx.l10n.wPvGeneration,
            formatPower(s.pvPower),
          ),
          _metric(ctx, Icons.swap_vert, ctx.l10n.wGrid,
              formatPower(s.gridPower)),
          _metric(
            ctx,
            Icons.home_outlined,
            ctx.l10n.wHomeConsumption,
            formatPower(s.homePower),
          ),
          if (s.batteryConfigured)
            _metric(
              ctx,
              Icons.battery_charging_full,
              ctx.l10n.wBattery,
              '${s.batterySoc != null ? '${s.batterySoc!.round()} %' : '—'}'
                  '  ·  ${formatPower(s.batteryPower)}',
            ),
          if (s.loadpoints.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(ctx.l10n.wLoadpoints, style: theme.textTheme.labelLarge),
            for (final lp in s.loadpoints) _loadpoint(ctx, lp),
          ],
          const SizedBox(height: 8),
          Text(
            ctx.l10n.wEvccLiveApiNote,
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
    if (lp.mode != null) bits.add(ctx.l10n.wModeValue(lp.mode!));
    bits.add(
      lp.charging
          ? ctx.l10n.wChargingPower(formatPower(lp.chargePower))
          : (lp.connected ? ctx.l10n.wConnectedLp : ctx.l10n.wFree),
    );
    if (lp.vehicleSoc != null) {
      bits.add(ctx.l10n.wVehicleSoc(lp.vehicleSoc!.round()));
    }
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
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 16),
          Flexible(child: Text(context.l10n.wScanningWifi)),
        ],
      ),
      actions: [
        TextButton(onPressed: onCancel, child: Text(context.l10n.cancel)),
      ],
    );
  }
}
