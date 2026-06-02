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
    _outputSub = backend.output.listen((data) {
      if (!_disposed) terminal.write(data);
    });

    backend.done.then((_) {
      // Completes after we dispose too (we kill the process); guard the notifier.
      if (_disposed) return;
      final code = backend.exitCode;
      terminal.write(
        '\r\n\x1b[90m── process exited${code != null ? ' (code $code)' : ''} ──\x1b[0m\r\n',
      );
      exited.value = true;
    });

    // Keyboard / paste → backend (local PTY stdin, or remote SendPtyInput).
    terminal.onOutput = (data) {
      if (!_disposed) backend.write(data);
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
  }

  /// Types a full command line and presses Enter, so it runs on the machine
  /// hosting the PTY (this machine for a local backend, or a remote one via the
  /// transport). `\r` is the Enter key as the line discipline expects it.
  void sendCommand(String command) {
    if (_disposed) return;
    backend.write('$command\r');
  }

  /// Frees everything this session owns. Idempotent. Call only after the
  /// session's [TerminalView] has unmounted (see `_closeSession` in main.dart)
  /// so the scroll/terminal controllers aren't disposed while still attached.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _outputSub?.cancel();
    backend.dispose();
    scrollController.dispose();
    terminalController.dispose();
    titleNotifier.dispose();
    exited.dispose();
  }
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
