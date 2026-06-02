import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
            if (_active != null) _MetaBar(session: _active!),
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
                            TerminalPane(key: ValueKey(s.id), session: s),
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

// ── Meta bar (cli · path · pid) ─────────────────────────────────────────────
class _MetaBar extends StatelessWidget {
  const _MetaBar({required this.session});
  final PtySession session;

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

// ── Terminal pane (the xterm view + jump-to-bottom) ─────────────────────────
class TerminalPane extends StatefulWidget {
  const TerminalPane({super.key, required this.session});
  final PtySession session;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  bool _atBottom = true;

  @override
  void initState() {
    super.initState();
    widget.session.scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.session.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final c = widget.session.scrollController;
    if (!c.hasClients) return;
    final atBottom = c.offset >= c.position.maxScrollExtent - 4;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
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
        const SizedBox(height: 8),
        // "Type something and send it to the machine running the PTY." For a
        // remote backend this is how a phone drives a shell on another box.
        _CommandBar(
          onSend: widget.session.sendCommand,
          inputEnabled: widget.session.inputEnabled,
        ),
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
                  // Desktop: read characters straight from hardware key events
                  // (event.character) instead of the platform IME/text-input
                  // connection — robust typing without an on-screen keyboard.
                  // On mobile you'd flip this to false so the soft keyboard works.
                  hardwareKeyboardOnly: true,
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
