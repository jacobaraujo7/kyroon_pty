import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import 'pty_session.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TerminalApp());
}

class TerminalApp extends StatelessWidget {
  const TerminalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter PTY Terminal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.bg,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.accent,
          surface: AppColors.surface,
        ),
        fontFamily: 'Segoe UI',
        useMaterial3: true,
      ),
      home: const TerminalWorkspace(),
    );
  }
}

class TerminalWorkspace extends StatefulWidget {
  const TerminalWorkspace({super.key});

  @override
  State<TerminalWorkspace> createState() => _TerminalWorkspaceState();
}

class _TerminalWorkspaceState extends State<TerminalWorkspace> {
  final List<PtySession> _sessions = [];
  int _activeIndex = 0;
  int _nextId = 1;

  /// Whether the command-input bar is shown. When off, input goes straight to
  /// the PTY (type in the terminal itself). Toggled from the meta bar.
  bool _showCommandBar = true;

  @override
  void initState() {
    super.initState();
    _newSession();
  }

  @override
  void dispose() {
    for (final s in _sessions) {
      s.dispose();
    }
    super.dispose();
  }

  void _newSession() => _addSession(PtySession.local(id: _nextId++));

  /// Opens a tab that launches the Claude Code CLI right away.
  void _newClaudeSession() => _addSession(PtySession.claude(id: _nextId++));

  void _addSession(PtySession session) {
    session.titleNotifier.addListener(_onSessionChanged);
    session.exited.addListener(_onSessionChanged);
    setState(() {
      _sessions.add(session);
      _activeIndex = _sessions.length - 1;
    });
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  void _closeSession(int index) {
    final session = _sessions[index];
    session.titleNotifier.removeListener(_onSessionChanged);
    session.exited.removeListener(_onSessionChanged);
    setState(() {
      _sessions.removeAt(index);
      if (_activeIndex >= _sessions.length) {
        _activeIndex = _sessions.length - 1;
      }
    });
    // Dispose only after this frame: the TerminalView for this session is still
    // mounted right now, and tearing down its scroll/terminal controllers while
    // attached throws "used after dispose". After the frame it has unmounted.
    WidgetsBinding.instance.addPostFrameCallback((_) => session.dispose());
    if (_sessions.isEmpty) _newSession();
  }

  PtySession? get _active =>
      (_activeIndex >= 0 && _activeIndex < _sessions.length)
          ? _sessions[_activeIndex]
          : null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        // Subtle radial glow in the top-left, like `.app-shell`.
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topLeft,
            radius: 1.4,
            colors: [Color(0xFF121A2B), AppColors.bg],
            stops: [0.0, 0.55],
          ),
        ),
        child: Column(
          children: [
            _Header(connected: _active?.exited.value != true),
            _TabBar(
              sessions: _sessions,
              activeIndex: _activeIndex,
              onSelect: (i) => setState(() => _activeIndex = i),
              onClose: _closeSession,
              onNew: _newSession,
              onNewClaude: _newClaudeSession,
            ),
            if (_active != null)
              _MetaBar(
                session: _active!,
                showCommandBar: _showCommandBar,
                onToggleCommandBar: () =>
                    setState(() => _showCommandBar = !_showCommandBar),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: _sessions.isEmpty
                    ? const SizedBox.shrink()
                    : IndexedStack(
                        // Keep-alive: every pane stays mounted to preserve
                        // scrollback, only the active one is shown.
                        index: _activeIndex,
                        children: [
                          for (final s in _sessions)
                            TerminalPane(
                              key: ValueKey(s.id),
                              session: s,
                              showCommandBar: _showCommandBar,
                            ),
                        ],
                      ),
              ),
            ),
            const _Footer(),
          ],
        ),
      ),
    );
  }
}

// ── Header ────────────────────────────────────────────────────────────────
class _Header extends StatelessWidget {
  const _Header({required this.connected});
  final bool connected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.accent, AppColors.accentStrong],
              ),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              boxShadow: const [
                BoxShadow(color: Color(0x88000000), blurRadius: 6, offset: Offset(0, 2)),
              ],
            ),
            child: const Icon(Icons.terminal_rounded, size: 18, color: Colors.white),
          ),
          const SizedBox(width: 12),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Flutter PTY Terminal',
                style: TextStyle(
                  color: AppColors.fg,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
              Text(
                'pseudo-terminal · xterm emulator',
                style: TextStyle(color: AppColors.fgDim, fontSize: 12),
              ),
            ],
          ),
          const Spacer(),
          _ConnPill(connected: connected),
        ],
      ),
    );
  }
}

class _ConnPill extends StatelessWidget {
  const _ConnPill({required this.connected});
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final color = connected ? const Color(0xFF6EE7B7) : const Color(0xFFFECACA);
    final dotColor = connected ? AppColors.success : AppColors.danger;
    final bg = connected ? const Color(0x441F3B2E) : const Color(0x22EF4444);
    final borderColor =
        connected ? const Color(0x662E7D5B) : AppColors.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            connected ? 'RUNNING' : 'EXITED',
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.9,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Tab bar ───────────────────────────────────────────────────────────────
class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.sessions,
    required this.activeIndex,
    required this.onSelect,
    required this.onClose,
    required this.onNew,
    required this.onNewClaude,
  });

  final List<PtySession> sessions;
  final int activeIndex;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final VoidCallback onNew;
  final VoidCallback onNewClaude;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < sessions.length; i++)
                    _Tab(
                      session: sessions[i],
                      active: i == activeIndex,
                      onTap: () => onSelect(i),
                      onClose: () => onClose(i),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          _RoundIconButton(
            icon: Icons.add_rounded,
            tooltip: 'Novo terminal',
            accent: AppColors.accent,
            onTap: onNew,
          ),
          const SizedBox(width: 6),
          _RoundIconButton(
            icon: Icons.android,
            tooltip: 'Abrir Claude',
            accent: _kAndroidGreen,
            onTap: onNewClaude,
          ),
        ],
      ),
    );
  }
}

/// Android brand green — distinguishes the "open Claude" action from "+".
const _kAndroidGreen = Color(0xFF3DDC84);

// ── Dead-key (accent) composition ───────────────────────────────────────────
// The IME path that would compose accents natively crashes on Windows desktop
// ("view ID is null"), so with hardware-key input we compose dead keys here:
// hold the accent, then combine it with the next letter. ABNT2/Latin layouts.
const _kDeadKeys = {'´', '`', '^', '~', '¨'};

const _kCompose = <String, Map<String, String>>{
  '´': {'a': 'á', 'e': 'é', 'i': 'í', 'o': 'ó', 'u': 'ú', 'y': 'ý', 'c': 'ć', 'n': 'ń'},
  '`': {'a': 'à', 'e': 'è', 'i': 'ì', 'o': 'ò', 'u': 'ù'},
  '^': {'a': 'â', 'e': 'ê', 'i': 'î', 'o': 'ô', 'u': 'û'},
  '~': {'a': 'ã', 'o': 'õ', 'n': 'ñ'},
  '¨': {'a': 'ä', 'e': 'ë', 'i': 'ï', 'o': 'ö', 'u': 'ü', 'y': 'ÿ'},
};

/// Composes a pending dead-key accent with the next typed character.
/// - base vowel/consonant → the accented letter (á, ã, ê…), preserving case;
/// - an already-composed accented letter (the OS pre-composed it) → as-is;
/// - space → the literal spacing accent (dead-key + space convention);
/// - anything else (e.g. `~/`, `` `cmd` ``) → accent followed by the char.
String composeDeadKey(String dead, String ch) {
  if (ch == ' ') return dead;
  final lower = ch.toLowerCase();
  final composed = _kCompose[dead]?[lower];
  if (composed != null) return ch == lower ? composed : composed.toUpperCase();
  // Already an accented (non-ASCII) letter → the OS composed it; keep it.
  if (ch.runes.isNotEmpty && ch.runes.first > 0x7f && !_kDeadKeys.contains(ch)) {
    return ch;
  }
  return '$dead$ch'; // didn't combine — emit accent + char literally
}

final _kModifierKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
};

class _Tab extends StatelessWidget {
  const _Tab({
    required this.session,
    required this.active,
    required this.onTap,
    required this.onClose,
  });

  final PtySession session;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final exited = session.exited.value;
    final dotColor = exited ? AppColors.fgMuted : AppColors.accent;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.full),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            constraints: const BoxConstraints(maxWidth: 240),
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
            decoration: BoxDecoration(
              color: active ? AppColors.accentSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.full),
              border: Border.all(
                color: active ? AppColors.accent : Colors.transparent,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active ? AppColors.fg : AppColors.fgDim,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                _TabCloseButton(onTap: onClose),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TabCloseButton extends StatefulWidget {
  const _TabCloseButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_TabCloseButton> createState() => _TabCloseButtonState();
}

class _TabCloseButtonState extends State<_TabCloseButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: _hover ? AppColors.danger : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
          child: Icon(
            Icons.close_rounded,
            size: 13,
            color: _hover ? Colors.white : AppColors.fgMuted,
          ),
        ),
      ),
    );
  }
}

class _RoundIconButton extends StatefulWidget {
  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<_RoundIconButton> createState() => _RoundIconButtonState();
}

class _RoundIconButtonState extends State<_RoundIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: _hover
                  ? widget.accent.withValues(alpha: 0.16)
                  : AppColors.surfaceContainer,
              borderRadius: BorderRadius.circular(AppRadius.full),
              border: Border.all(
                color: _hover ? widget.accent : AppColors.borderStrong,
              ),
            ),
            child: Icon(
              widget.icon,
              size: 18,
              color: _hover ? widget.accent : AppColors.fgDim,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Meta bar (cli · path · last-input · pid) ────────────────────────────────
class _MetaBar extends StatefulWidget {
  const _MetaBar({
    required this.session,
    required this.showCommandBar,
    required this.onToggleCommandBar,
  });
  final PtySession session;
  final bool showCommandBar;
  final VoidCallback onToggleCommandBar;

  @override
  State<_MetaBar> createState() => _MetaBarState();
}

class _MetaBarState extends State<_MetaBar> {
  // Live view of PtySession.onInput — proves the input event reaches the origin
  // system. Updated on every keystroke/paste/command sent to the PTY.
  StreamSubscription<String>? _inputSub;
  DateTime? _lastInputAt;
  String _lastInputPreview = '';

  // Live view of PtySession.onIdle — fires when the CLI finishes processing.
  StreamSubscription<TerminalIdleEvent>? _idleSub;
  DateTime? _lastIdleAt;
  Duration? _lastBusyFor;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(_MetaBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _lastInputAt = null;
      _lastInputPreview = '';
      _lastIdleAt = null;
      _lastBusyFor = null;
      _subscribe();
    }
  }

  void _subscribe() {
    _inputSub?.cancel();
    _idleSub?.cancel();
    _inputSub = widget.session.onInput.listen((data) {
      if (!mounted) return;
      setState(() {
        _lastInputAt = DateTime.now();
        _lastInputPreview = _sanitizePreview(data);
      });
    });
    _idleSub = widget.session.onIdle.listen((event) {
      if (!mounted) return;
      setState(() {
        _lastIdleAt = event.at;
        _lastBusyFor = event.busyFor;
      });
    });
  }

  @override
  void dispose() {
    _inputSub?.cancel();
    _idleSub?.cancel();
    super.dispose();
  }

  /// Turns raw input bytes (which may carry CR/LF/control chars) into a short,
  /// printable preview suitable for a status label.
  static String _sanitizePreview(String s) {
    final buf = StringBuffer();
    for (final r in s.runes) {
      if (r == 0x0d || r == 0x0a) {
        buf.write('⏎');
      } else if (r == 0x09) {
        buf.write('⇥');
      } else if (r < 0x20 || r == 0x7f) {
        buf.write('·');
      } else {
        buf.writeCharCode(r);
      }
    }
    var out = buf.toString();
    if (out.length > 24) out = '…${out.substring(out.length - 24)}';
    return out;
  }

  static String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  PtySession get session => widget.session;

  @override
  Widget build(BuildContext context) {
    final pid = session.pid;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainer,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.accentSoft,
              borderRadius: BorderRadius.circular(AppRadius.xs),
              border: Border.all(color: AppColors.borderStrong),
            ),
            child: Text(
              session.shellName.toUpperCase(),
              style: const TextStyle(
                color: AppColors.accent,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _StatusBadge(session: session),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              Directory.current.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.fgDim,
                fontSize: 12,
                fontFamily: kMonoFontFamily,
                fontFamilyFallback: kMonoFontFallback,
              ),
            ),
          ),
          const Spacer(),
          _CommandBarToggle(
            on: widget.showCommandBar,
            onTap: widget.onToggleCommandBar,
          ),
          const SizedBox(width: 12),
          _LastInputLabel(at: _lastInputAt, preview: _lastInputPreview),
          const SizedBox(width: 12),
          _IdleLabel(at: _lastIdleAt, busyFor: _lastBusyFor),
          const SizedBox(width: 12),
          Text(
            session.exited.value
                ? 'exited ${session.exitCode}'
                : (pid > 0 ? 'pid $pid' : '—'),
            style: const TextStyle(
              color: AppColors.fgMuted,
              fontSize: 10,
              fontFamily: kMonoFontFamily,
              fontFamilyFallback: kMonoFontFallback,
            ),
          ),
        ],
      ),
    );
  }
}

/// Status label fed by `PtySession.onInput`: shows the time of the last
/// interaction and a short preview of what was typed/sent — a live, visible
/// proof that the input event fires for both direct typing and the command bar.
class _LastInputLabel extends StatelessWidget {
  const _LastInputLabel({required this.at, required this.preview});
  final DateTime? at;
  final String preview;

  @override
  Widget build(BuildContext context) {
    final hasInput = at != null;
    final label = hasInput
        ? '${_MetaBarState._fmtTime(at!)}  ${preview.isEmpty ? '' : '› $preview'}'
        : 'sem interação';
    return Tooltip(
      message: 'Última interação (PtySession.onInput) — hora e texto enviado',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.bolt_rounded,
            size: 13,
            color: hasInput ? AppColors.accent : AppColors.fgMuted,
          ),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: hasInput ? AppColors.fgDim : AppColors.fgMuted,
                fontSize: 10,
                fontFamily: kMonoFontFamily,
                fontFamilyFallback: kMonoFontFallback,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Amber used for the RUNNING (processing) state.
const _kRunningAmber = Color(0xFFF59E0B);

/// Live RUNNING / IDLE / ENCERRADO badge, driven by `PtySession.busy` and
/// `PtySession.exited`. RUNNING while the CLI produces output, IDLE once it goes
/// quiet (finished), ENCERRADO when the process ends.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.session});
  final PtySession session;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([session.busy, session.exited]),
      builder: (context, _) {
        final String label;
        final Color color;
        final IconData icon;
        if (session.exited.value) {
          label = 'ENCERRADO';
          color = AppColors.fgMuted;
          icon = Icons.stop_circle_outlined;
        } else if (session.busy.value) {
          label = 'RUNNING';
          color = _kRunningAmber;
          icon = Icons.autorenew_rounded;
        } else {
          label = 'IDLE';
          color = AppColors.success;
          icon = Icons.check_circle_outline_rounded;
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(AppRadius.full),
            border: Border.all(color: color.withValues(alpha: 0.7)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.7,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Status label fed by `PtySession.onIdle`: shows when the CLI last finished
/// processing (went idle) and for how long it had been busy.
class _IdleLabel extends StatelessWidget {
  const _IdleLabel({required this.at, required this.busyFor});
  final DateTime? at;
  final Duration? busyFor;

  @override
  Widget build(BuildContext context) {
    final idle = at != null;
    final secs = busyFor == null
        ? ''
        : ' (${(busyFor!.inMilliseconds / 1000).toStringAsFixed(1)}s)';
    final label = idle ? '${_MetaBarState._fmtTime(at!)}$secs' : 'aguardando';
    return Tooltip(
      message: 'Última vez que o CLI ficou ocioso (PtySession.onIdle) — '
          'hora e quanto tempo processou',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.bedtime_rounded,
            size: 13,
            color: idle ? _kAndroidGreen : AppColors.fgMuted,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: idle ? AppColors.fgDim : AppColors.fgMuted,
              fontSize: 10,
              fontFamily: kMonoFontFamily,
              fontFamilyFallback: kMonoFontFallback,
            ),
          ),
        ],
      ),
    );
  }
}

/// Toggle between typing through the command-input bar and typing straight into
/// the PTY. The pill reflects the current mode and flips it on tap.
class _CommandBarToggle extends StatelessWidget {
  const _CommandBarToggle({required this.on, required this.onTap});

  /// True when the command bar is visible (input via the bar); false means
  /// input goes directly to the terminal.
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = on ? AppColors.accent : _kAndroidGreen;
    return Tooltip(
      message: on
          ? 'Barra de comando ATIVA — clique para digitar direto no PTY'
          : 'Digitação direta no PTY — clique para usar a barra de comando',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.full),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadius.full),
              border: Border.all(color: accent),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  on ? Icons.keyboard_rounded : Icons.terminal_rounded,
                  size: 14,
                  color: accent,
                ),
                const SizedBox(width: 6),
                Text(
                  on ? 'BARRA DE INPUT' : 'PTY DIRETO',
                  style: TextStyle(
                    color: accent,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Terminal pane (the xterm view + jump-to-bottom) ─────────────────────────
class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.session,
    this.showCommandBar = true,
  });
  final PtySession session;

  /// When false, the command-input bar is hidden and the user types straight
  /// into the PTY (the terminal keeps focus). Toggled from the meta bar.
  final bool showCommandBar;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  bool _atBottom = true;

  // Owned focus node so we can move keyboard focus into the terminal when the
  // command bar is hidden (otherwise focus stays where the bar was and the PTY
  // receives nothing).
  final FocusNode _termFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.session.scrollController.addListener(_onScroll);
    if (!widget.showCommandBar) _focusTerminal();
  }

  @override
  void didUpdateWidget(TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Switched into "type directly into the PTY" mode → focus the terminal.
    if (oldWidget.showCommandBar && !widget.showCommandBar) {
      _focusTerminal();
    }
  }

  /// Moves keyboard focus to the terminal so hardware keys reach the PTY.
  void _focusTerminal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _termFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    widget.session.scrollController.removeListener(_onScroll);
    _termFocus.dispose();
    super.dispose();
  }

  void _onScroll() {
    final c = widget.session.scrollController;
    if (!c.hasClients) return;
    final atBottom = c.offset >= c.position.maxScrollExtent - 4;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
  }

  /// Pending dead-key accent (´ ` ^ ~ ¨) awaiting the next character.
  String? _deadKey;

  /// Handles two things the raw terminal doesn't on desktop:
  ///  * **dead-key accents** — composes ´/`/^/~/¨ with the next letter (é, ã…)
  ///    since the IME path that would do this crashes on Windows desktop;
  ///  * **Ctrl+Enter / Shift+Enter** — sends a newline (LF) instead of the
  ///    carriage return that plain Enter produces.
  /// Returns `handled` when it consumed the key; otherwise `ignored` so xterm
  /// processes it normally.
  KeyEventResult _handleTerminalKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // Never let a modifier press disturb a pending accent (e.g. ´ then Shift+a
    // for Á): modifiers arrive as their own char-less events.
    if (_kModifierKeys.contains(event.logicalKey)) {
      return KeyEventResult.ignored;
    }

    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    final ch = event.character;

    // Resolve a pending dead key against this keystroke.
    if (_deadKey != null) {
      final dead = _deadKey!;
      _deadKey = null;
      if (ch != null && ch.isNotEmpty && !isEnter) {
        widget.session.sendKeyboard(composeDeadKey(dead, ch));
        return KeyEventResult.handled;
      }
      // Non-character key (arrows/Enter/…): flush the accent literally, then
      // let the key continue through normal handling below.
      widget.session.sendKeyboard(dead);
    }

    // Ctrl/Shift+Enter → newline (LF) instead of submit (CR).
    if (isEnter &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isShiftPressed)) {
      widget.session.sendText('\n');
      return KeyEventResult.handled;
    }

    // Start composing when an accent dead key is pressed; wait for the next key.
    if (ch != null && ch.length == 1 && _kDeadKeys.contains(ch)) {
      _deadKey = ch;
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _jumpToBottom() {
    final c = widget.session.scrollController;
    if (!c.hasClients) return;
    c.animateTo(
      c.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _buildTerminal()),
        // "Type something and send it to the machine running the PTY." For a
        // remote backend this is how a phone drives a shell on another box.
        // Hidden when the user opts to type directly into the PTY.
        if (widget.showCommandBar) ...[
          const SizedBox(height: 8),
          _CommandBar(
            onSend: widget.session.sendCommand,
            inputEnabled: widget.session.inputEnabled,
          ),
        ],
      ],
    );
  }

  Widget _buildTerminal() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        decoration: BoxDecoration(
          color: kTerminalTheme.background,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.border),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              // readOnly follows the backend's input lease: always writable for
              // a local PTY, read-only for a remote stream until control is
              // acquired. Rebuilds when the lease flips.
              child: ValueListenableBuilder<bool>(
                valueListenable: widget.session.backend.inputEnabled,
                builder: (context, canInput, _) => TerminalView(
                  widget.session.terminal,
                  focusNode: _termFocus,
                  controller: widget.session.terminalController,
                  scrollController: widget.session.scrollController,
                  theme: kTerminalTheme,
                  textStyle: const TerminalStyle(
                    fontSize: 13,
                    fontFamily: kMonoFontFamily,
                    fontFamilyFallback: kMonoFontFallback,
                  ),
                  padding: const EdgeInsets.all(10),
                  autofocus: true,
                  backgroundOpacity: 0,
                  cursorType: TerminalCursorType.block,
                  readOnly: !canInput,
                  // Read characters straight from hardware key events. The IME /
                  // text-input path (hardwareKeyboardOnly:false) composes dead
                  // keys (accents) correctly, but on Windows desktop it throws
                  // "Could not set client, view ID is null" on attach and typing
                  // fails — so we keep hardware mode here for reliable input.
                  // For accented text use the command bar (a normal TextField,
                  // which handles dead keys via the OS IME).
                  hardwareKeyboardOnly: true,
                  // Highest-priority key hook: turn Ctrl+Enter / Shift+Enter into
                  // a literal newline (LF) instead of "submit" (CR). Apps like
                  // the Claude CLI / readline treat LF as "insert line break".
                  onKeyEvent: _handleTerminalKey,
                ),
              ),
            ),
            if (!_atBottom)
              Positioned(
                right: 16,
                bottom: 14,
                child: _JumpToBottomButton(onTap: _jumpToBottom),
              ),
          ],
        ),
      ),
    );
  }
}

/// A compact "type a command and send it" bar. Sends the line (with Enter) to
/// the session backend — to the local PTY, or, with a remote backend, all the
/// way to the shell running on another machine. Disabled when the backend has
/// no input lease (remote read-only).
class _CommandBar extends StatefulWidget {
  const _CommandBar({required this.onSend, required this.inputEnabled});

  final ValueChanged<String> onSend;
  final ValueListenable<bool> inputEnabled;

  @override
  State<_CommandBar> createState() => _CommandBarState();
}

class _CommandBarState extends State<_CommandBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text;
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.inputEnabled,
      builder: (context, enabled, _) {
        return Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Container(
            height: 42,
            padding: const EdgeInsets.only(left: 14, right: 6),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                const Text(
                  '›',
                  style: TextStyle(
                    color: AppColors.accent,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    fontFamily: kMonoFontFamily,
                    fontFamilyFallback: kMonoFontFallback,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    enabled: enabled,
                    onSubmitted: (_) => _send(),
                    style: const TextStyle(
                      color: AppColors.fg,
                      fontSize: 13,
                      fontFamily: kMonoFontFamily,
                      fontFamilyFallback: kMonoFontFallback,
                    ),
                    cursorColor: AppColors.accent,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: enabled
                          ? 'digite um comando e envie para a máquina…'
                          : 'somente leitura — sem controle do terminal',
                      hintStyle: const TextStyle(
                        color: AppColors.fgMuted,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _RoundIconButton(
                  icon: Icons.send_rounded,
                  tooltip: 'Enviar comando',
                  accent: AppColors.accent,
                  onTap: enabled ? _send : () {},
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _JumpToBottomButton extends StatelessWidget {
  const _JumpToBottomButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.full),
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: AppColors.accentStrong,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.accent),
            boxShadow: const [
              BoxShadow(color: Color(0x55000000), blurRadius: 14, offset: Offset(0, 4)),
            ],
          ),
          child: const Icon(Icons.arrow_downward_rounded, size: 18, color: Colors.white),
        ),
      ),
    );
  }
}

// ── Footer ──────────────────────────────────────────────────────────────────
class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'kyroon_pty + xterm',
            style: TextStyle(color: AppColors.fgMuted, fontSize: 10, letterSpacing: 0.3),
          ),
          Text(
            'Ctrl+Shift+C copy · Ctrl+Shift+V paste',
            style: TextStyle(color: AppColors.fgMuted, fontSize: 10, letterSpacing: 0.3),
          ),
        ],
      ),
    );
  }
}
