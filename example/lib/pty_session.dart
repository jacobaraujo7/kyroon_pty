import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import 'local_pty_backend.dart';
import 'terminal_backend.dart';

/// A single live terminal tab: an xterm [Terminal] emulator wired to a
/// [TerminalBackend], plus the UI state (scroll controller, title, exit code)
/// the tab needs to render itself.
///
/// The emulator is transport-agnostic — it does full VT/ANSI emulation exactly
/// like xterm.js, and neither knows nor cares whether its bytes come from a
/// local PTY ([LocalPtyBackend]) or a remote stream (a [TerminalBackend] backed
/// by gRPC). Swapping the backend is all it takes to go from "runs on this
/// machine" to "watch a PTY running on another machine from a phone".
class PtySession {
  PtySession._({
    required this.id,
    required this.shellName,
    required this.title,
    required TerminalBackend Function(int cols, int rows) backendBuilder,
  }) {
    terminal = Terminal(
      maxLines: 10000,
      platform: _terminalPlatform,
    );

    // The backend needs an initial size; the Terminal defaults to 80x24 until
    // the view measures itself and fires onResize.
    backend = backendBuilder(terminal.viewWidth, terminal.viewHeight);

    // Backend output → emulator. The backend already decoded UTF-8 (streaming).
    // Each chunk also feeds the idle detector (output activity = "busy").
    _outputSub = backend.output.listen((data) {
      if (_disposed) return;
      terminal.write(data);
      if (idleReadyPattern != null) _appendTail(data);
      _markBusy();
    });

    backend.done.then((_) {
      // Completes after we dispose too (we kill the process); guard the notifier.
      if (_disposed) return;
      final code = backend.exitCode;
      terminal.write(
        '\r\n\x1b[90m── process exited${code != null ? ' (code $code)' : ''} ──\x1b[0m\r\n',
      );
      _idleTimer?.cancel();
      busy.value = false;
      exited.value = true;
    });

    // Keyboard / paste → backend (local PTY stdin, or remote SendPtyInput).
    // Bytes always go to the PTY immediately (live echo), but the onInput
    // *event* is buffered and only fires once a line is committed (Enter) —
    // otherwise live typing emits one event per keystroke.
    terminal.onOutput = (data) {
      if (_disposed) return;
      backend.write(data);
      _bufferLiveInput(data);
    };

    // View size → backend (local resize, or remote ResizePty).
    terminal.onResize = (w, h, pw, ph) {
      if (!_disposed) backend.resize(h, w);
    };

    // Let the running program rename the tab (OSC 0/2), like a real terminal.
    // Windows' cmd.exe reports its own full path — normalize path-like titles.
    terminal.onTitleChange = (t) {
      if (_disposed) return;
      final pretty = _prettyTitle(t);
      if (pretty.isNotEmpty) {
        title = pretty;
        titleNotifier.value = title;
      }
    };
  }

  /// A local shell on this machine (the desktop case).
  factory PtySession.local({
    required int id,
    String? executable,
    List<String> arguments = const [],
    String? label,
  }) {
    final exe = executable ?? defaultShell;
    final name = label ?? _shellLabel(exe);
    return PtySession._(
      id: id,
      shellName: name,
      title: name,
      backendBuilder: (cols, rows) => LocalPtyBackend(
        executable: exe,
        arguments: arguments,
        columns: cols,
        rows: rows,
      ),
    );
  }

  /// A local shell that immediately launches the Claude Code CLI. On Windows
  /// `cmd /k claude` keeps the prompt after Claude exits; on unix we re-exec
  /// the login shell for the same effect.
  factory PtySession.claude({required int id}) {
    if (Platform.isWindows) {
      return PtySession.local(
        id: id,
        executable: defaultShell,
        arguments: ['/k', 'claude'],
        label: 'claude',
      );
    }
    return PtySession.local(
      id: id,
      executable: defaultShell,
      arguments: ['-lc', r'claude; exec "$SHELL"'],
      label: 'claude',
    );
  }

  /// A remote PTY (the mobile / "watch another machine" case). Pass any
  /// [TerminalBackend] — typically a `RemotePtyBackend` wrapping your gRPC
  /// transport. The UI below is identical to the local case.
  factory PtySession.remote({
    required int id,
    required TerminalBackend Function(int cols, int rows) backendBuilder,
    String label = 'remote',
  }) {
    return PtySession._(
      id: id,
      shellName: label,
      title: label,
      backendBuilder: backendBuilder,
    );
  }

  final int id;

  /// Short, stable label for the meta badge (e.g. `cmd`, `bash`, `claude`).
  final String shellName;

  late final Terminal terminal;
  late final TerminalBackend backend;

  StreamSubscription<String>? _outputSub;
  bool _disposed = false;

  final scrollController = ScrollController();
  final terminalController = TerminalController();

  /// Tab label — starts as [shellName], updated by OSC title changes.
  String title;
  final titleNotifier = ValueNotifier<String>('');

  /// True once the underlying process / stream has ended.
  final exited = ValueNotifier<bool>(false);

  /// Reactive processing state: true while the process is producing output
  /// (the CLI is working), false once it goes idle (see [onIdle]). Bind a badge
  /// to this to show RUNNING vs IDLE.
  final busy = ValueNotifier<bool>(false);

  /// Fires every time input is sent to the process — live typing, pasted text,
  /// the command bar, or a programmatic [sendText]/[sendCommand]. Lets the
  /// embedder / origin system react to user interaction (activity tracking,
  /// idle-timer reset, audit, analytics…) without intercepting the byte stream.
  Stream<String> get onInput => _inputController.stream;
  final _inputController = StreamController<String>.broadcast();

  /// Accumulates live keystrokes until a line is committed (Enter), so onInput
  /// fires once per line instead of once per character.
  final _inputLine = StringBuffer();

  void _emitInput(String data) {
    if (!_disposed && data.isNotEmpty && !_inputController.isClosed) {
      _inputController.add(data);
    }
  }

  /// Buffers live typing and only emits an input event when an Enter (CR/LF) is
  /// seen — the whole committed line is emitted at once.
  void _bufferLiveInput(String data) {
    _inputLine.write(data);
    if (data.contains('\r') || data.contains('\n')) {
      final line = _inputLine.toString();
      _inputLine.clear();
      _emitInput(line);
    }
  }

  /// Fires when the process goes quiet after a burst of output — a heuristic for
  /// "the CLI (claude/codex/qwen/…) finished processing and is now idle". One
  /// event per processing→idle transition; it re-arms on the next output.
  ///
  /// Detection is by output quiescence: no new output for [idleThreshold] after
  /// activity. This works well for agentic CLIs because they render an animated
  /// spinner / status line while working ("✻ Thinking… (12s)"), which keeps
  /// output flowing the whole time a task runs — so a long, heavy task does NOT
  /// look idle. The only way to get a false "idle" is a CLI that produces *no*
  /// output at all for longer than [idleThreshold] while still working; raise
  /// the threshold to cover that. (No fixed time can cover an arbitrarily long
  /// fully-silent task — for that you'd gate on a prompt/ready pattern instead.)
  Stream<TerminalIdleEvent> get onIdle => _idleController.stream;
  final _idleController = StreamController<TerminalIdleEvent>.broadcast();

  /// How long output must stay quiet (after activity) before the session is
  /// considered idle. Default is generous (1.5s) to avoid flagging idle during
  /// momentary pauses in a long task; lower it for snappier detection, raise it
  /// for CLIs that go silent mid-task.
  Duration idleThreshold = const Duration(milliseconds: 1500);

  /// Optional precision gate for [onIdle]. When set, idle only fires if the
  /// recent output (ANSI-stripped) matches this pattern — i.e. the CLI's
  /// prompt/ready indicator is actually on screen. This avoids false "idle"
  /// during a long task that goes silent without finishing: if the prompt
  /// hasn't reappeared, no event is emitted no matter how long the silence.
  /// Leave null for pure output-quiescence detection (the default).
  ///
  /// Examples: `RegExp(r'\$ $')` (shell), or a CLI's input box marker.
  RegExp? idleReadyPattern;

  Timer? _idleTimer;
  DateTime? _busySince;
  final _outTail = StringBuffer();

  static final _ansiEscape = RegExp(
    r'\x1B\[[0-9;?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)',
  );

  void _appendTail(String data) {
    _outTail.write(data);
    if (_outTail.length > 600) {
      final s = _outTail.toString();
      _outTail
        ..clear()
        ..write(s.substring(s.length - 400));
    }
  }

  void _markBusy() {
    _busySince ??= DateTime.now();
    busy.value = true;
    _idleTimer?.cancel();
    _idleTimer = Timer(idleThreshold, _markIdle);
  }

  void _markIdle() {
    if (_disposed || _busySince == null) return;
    // Precision gate: if a ready pattern is configured but the prompt isn't on
    // screen yet, the CLI is still working (just silent) — don't flag idle.
    final pattern = idleReadyPattern;
    if (pattern != null &&
        !pattern.hasMatch(_outTail.toString().replaceAll(_ansiEscape, ''))) {
      return;
    }
    final busyFor = DateTime.now().difference(_busySince!);
    _busySince = null;
    busy.value = false;
    if (!_idleController.isClosed) {
      _idleController.add(TerminalIdleEvent(DateTime.now(), busyFor));
    }
  }

  int? get exitCode => backend.exitCode;

  int get pid => backend.pid ?? -1;

  /// Whether input is currently accepted (always true locally; reflects the
  /// control lease for a remote backend).
  ValueListenable<bool> get inputEnabled => backend.inputEnabled;

  /// Sends raw text to the process, exactly as if typed (no newline appended).
  /// For a remote backend this travels over the transport — e.g. gRPC → Redis →
  /// the PTY running on the host machine.
  void sendText(String text) {
    if (_disposed) return;
    backend.write(text);
    _emitInput(text);
  }

  /// Writes keyboard-origin bytes to the process through the same path as live
  /// typing (immediate write + per-line [onInput] buffering). Used by the view
  /// for dead-key/accent composition, so composed characters are echoed by the
  /// PTY and counted toward the committed-line input event — not emitted per
  /// keystroke.
  void sendKeyboard(String data) {
    if (_disposed || data.isEmpty) return;
    backend.write(data);
    _bufferLiveInput(data);
  }

  /// Types a full command line and presses Enter, so it runs on the machine
  /// hosting the PTY (this machine for a local backend, or a remote one via the
  /// transport). `\r` is the Enter key as the line discipline expects it.
  void sendCommand(String command) {
    if (_disposed) return;
    final data = '$command\r';
    backend.write(data);
    _emitInput(data);
  }

  /// Frees everything this session owns. Idempotent. Call only after the
  /// session's [TerminalView] has unmounted (see `_closeSession` in main.dart)
  /// so the scroll/terminal controllers aren't disposed while still attached.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _outputSub?.cancel();
    _idleTimer?.cancel();
    _inputController.close();
    _idleController.close();
    backend.dispose();
    scrollController.dispose();
    terminalController.dispose();
    titleNotifier.dispose();
    exited.dispose();
    busy.dispose();
  }
}

/// Emitted by [PtySession.onIdle] when the process stops producing output after
/// a burst of activity — a heuristic for "the CLI finished and is now idle".
class TerminalIdleEvent {
  const TerminalIdleEvent(this.at, this.busyFor);

  /// When the session went idle.
  final DateTime at;

  /// How long output had been flowing before it went quiet.
  final Duration busyFor;
}

TerminalTargetPlatform get _terminalPlatform {
  if (Platform.isWindows) return TerminalTargetPlatform.windows;
  if (Platform.isMacOS) return TerminalTargetPlatform.macos;
  if (Platform.isLinux) return TerminalTargetPlatform.linux;
  return TerminalTargetPlatform.unknown;
}

/// The shell launched for new tabs on this platform.
String get defaultShell {
  if (Platform.isWindows) {
    return Platform.environment['COMSPEC'] ?? 'cmd.exe';
  }
  if (Platform.isMacOS || Platform.isLinux) {
    return Platform.environment['SHELL'] ?? 'bash';
  }
  return 'sh';
}

String _shellLabel(String shell) {
  final name = shell.split(RegExp(r'[\\/]')).last;
  return name.replaceAll(RegExp(r'\.exe$', caseSensitive: false), '');
}

/// Normalizes an OSC window-title. Path-like titles (cmd.exe reports its own
/// full path) collapse to the executable name; semantic titles pass through.
String _prettyTitle(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '';
  if (t.contains(RegExp(r'[\\/]'))) return _shellLabel(t);
  return t;
}
