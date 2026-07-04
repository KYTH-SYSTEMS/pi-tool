part of '../main.dart';

// Presentational widgets + sheets for the updater screen, split out of
// main.dart. Kept as a part so they stay library-private and share the
// top-level theme constants (kGreen/kBlack/kCard) without re-importing.

/// A green that stays legible on both themes — vivid kGreen on the dark
/// surfaces, darkened for light mode where bright kGreen washes out.
Color _themeGreen(bool dark) => dark ? kGreen : const Color(0xFF15803D);

enum _ProfileAction { rename, delete }

/// Active-Pi selector. A bordered card matching [_ConnectionCard]; each profile
/// is a one-tap ChoiceChip (active one filled green), with a tinted "+ Profil"
/// add chip and rename/delete folded into a single overflow menu.
class _ProfileBar extends StatelessWidget {
  const _ProfileBar({
    required this.profiles,
    required this.activeIndex,
    required this.enabled,
    required this.onSwitch,
    required this.onAdd,
    required this.onRename,
    this.onDelete,
  });

  final List<Profile> profiles;
  final int activeIndex;
  final bool enabled;
  final ValueChanged<int> onSwitch;
  final VoidCallback onAdd;
  final VoidCallback onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    final chips = <Widget>[
      for (var i = 0; i < profiles.length; i++)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(profiles[i].name, overflow: TextOverflow.ellipsis),
            selected: i == activeIndex,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            selectedColor: kGreen,
            backgroundColor: Colors.transparent,
            labelStyle: TextStyle(
              color: i == activeIndex ? kBlack : cs.onSurface,
              fontWeight:
                  i == activeIndex ? FontWeight.w600 : FontWeight.w500,
            ),
            shape: StadiumBorder(
              side: BorderSide(
                color: i == activeIndex
                    ? Colors.transparent
                    : (dark ? Colors.white24 : cs.outlineVariant),
              ),
            ),
            onSelected: enabled ? (_) => onSwitch(i) : null,
          ),
        ),
      Tooltip(
        message: 'Neues Profil',
        child: ActionChip(
          avatar: Icon(Icons.add,
              size: 18, color: enabled ? _themeGreen(dark) : cs.onSurfaceVariant),
          label: const Text('Profil'),
          visualDensity: VisualDensity.compact,
          backgroundColor: kGreen.withValues(alpha: dark ? 0.10 : 0.08),
          shape: StadiumBorder(
              side: BorderSide(color: kGreen.withValues(alpha: 0.5))),
          onPressed: enabled ? onAdd : null,
        ),
      ),
    ];

    return IgnorePointer(
      ignoring: !enabled,
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.6,
        duration: const Duration(milliseconds: 150),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          decoration: BoxDecoration(
            color: dark ? kCard : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
            border:
                Border.all(color: dark ? Colors.white10 : cs.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(Icons.dns_outlined, size: 18, color: cs.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: chips),
                ),
              ),
              PopupMenuButton<_ProfileAction>(
                enabled: enabled,
                tooltip: 'Profil-Aktionen',
                icon: const Icon(Icons.more_vert),
                onSelected: (a) {
                  switch (a) {
                    case _ProfileAction.rename:
                      onRename();
                    case _ProfileAction.delete:
                      onDelete?.call();
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: _ProfileAction.rename,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.edit_outlined),
                      title: Text('Profil umbenennen'),
                    ),
                  ),
                  if (onDelete != null)
                    PopupMenuItem(
                      value: _ProfileAction.delete,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.delete_outline, color: cs.error),
                        title: Text('Profil löschen',
                            style: TextStyle(color: cs.error)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact connection-test button below the profile bar. Neutral when untested,
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
          child: CircularProgressIndicator(strokeWidth: 2));
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

/// One entry in a service card's ⋮ menu.
class _CardAction {
  const _CardAction(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;
}

/// One entry in the "Dienst hinzufügen" picker: a not-yet-installed service and
/// how to install it (bespoke evcc/Pi-hole/HA flow, or a generic apt install).
class _AddableService {
  const _AddableService(this.name, this.icon, this.onAdd, {this.subtitle});
  final String name;
  final IconData icon;
  final VoidCallback onAdd;
  final String? subtitle;
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
  });

  final ServiceStatus status;
  final IconData icon;
  final String primaryLabel; // "Aktualisieren" | "Installieren"
  final VoidCallback onPrimary;
  final bool enabled;
  final VoidCallback? onOpenWeb;
  final List<_CardAction> actions;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final mono = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(fontFamily: 'monospace', color: cs.onSurfaceVariant);

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
                child: Text(status.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
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
                      PopupMenuItem(value: i, child: Text(actions[i].label)),
                  ],
                )
              else
                const SizedBox(width: 8),
            ],
          ),
          if (status.installed && (status.version != null || status.detail.isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(left: 30, bottom: 6),
              child: Text(
                [status.version, status.detail]
                    .where((s) => s != null && s.isNotEmpty)
                    .join('  ·  '),
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
                          icon: Icon(Icons.check_circle_outline,
                              size: 18, color: okGreen),
                          label: const Text('Aktuell'),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(42)),
                        )
                      : OutlinedButton(
                          onPressed: enabled ? onPrimary : null,
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(42)),
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
                    icon: Icon(Icons.password)),
                ButtonSegment(
                    value: AuthMode.key,
                    label: Text('SSH-Key'),
                    icon: Icon(Icons.vpn_key_outlined)),
              ],
              selected: {authMode},
              onSelectionChanged:
                  enabled ? (s) => onAuthMode(s.first) : null,
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
                  icon: Icon(
                      obscure ? Icons.visibility : Icons.visibility_off),
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
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

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
            child: const Text('Abbrechen')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
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
              chevronColor: chevronColor ?? const Color(0xFFE8EDE9))),
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

    canvas.drawCircle(
        const Offset(384, 216), 62, Paint()..color = kGreen);
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
    return Scaffold(
      backgroundColor: kBlack,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PromptMark(key: Key('promptMark'), size: 76),
            const SizedBox(height: 12),
            const Text('Pi-Tool',
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w800, color: kGreen)),
            const SizedBox(height: 2),
            const Text('by KYTH. Systems',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
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
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
              color: fg),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: TextStyle(color: fg))),
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
              Icon(Icons.bolt,
                  color: _themeGreen(theme.brightness == Brightness.dark)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(s.siteTitle ?? 'evcc-Status',
                    style: theme.textTheme.titleMedium),
              ),
              if (s.version != null)
                Text('v${s.version}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 8),
          _metric(ctx, Icons.solar_power_outlined, 'PV-Erzeugung',
              formatPower(s.pvPower)),
          _metric(ctx, Icons.swap_vert, 'Netz', formatPower(s.gridPower)),
          _metric(ctx, Icons.home_outlined, 'Hausverbrauch',
              formatPower(s.homePower)),
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
          Text('Live aus der evcc-Web-API (nur Anzeige).',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
    bits.add(lp.charging
        ? 'lädt ${formatPower(lp.chargePower)}'
        : (lp.connected ? 'verbunden' : 'frei'));
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
