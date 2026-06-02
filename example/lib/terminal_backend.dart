import 'package:flutter/foundation.dart';

/// Transport-agnostic source of terminal data.
///
/// The UI ([PtySession] + xterm `TerminalView`) only ever talks to this
/// interface. Whether the bytes come from a **local PTY** (this machine, via
/// kyroon_pty/ConPTY — see `LocalPtyBackend`) or from a **remote stream** (a
/// phone / browser watching a PTY that runs on another machine, via WebSocket
/// or gRPC — see `RemotePtyBackend`) is an implementation detail.
///
/// This file is deliberately **web-safe**: it imports nothing from `dart:io`,
/// `dart:ffi` or `kyroon_pty`, so the remote/WebSocket path compiles for the
/// web. The local backend lives in its own file (`local_pty_backend.dart`).
abstract class TerminalBackend {
  /// Text coming FROM the process, already UTF-8 decoded. Implementations MUST
  /// decode in streaming mode (buffering partial multi-byte sequences across
  /// chunks) — box-drawing glyphs and accents routinely straddle chunk borders.
  Stream<String> get output;

  /// User input (keyboard / paste) going TO the process.
  void write(String data);

  /// The terminal view resized; forward the new size to the process.
  void resize(int rows, int cols);

  /// Completes when the underlying process / stream ends.
  Future<void> get done;

  /// Process id, when known (local). Remote viewers don't own the process.
  int? get pid;

  /// Exit code, when known (local). Null while running or for remote streams.
  int? get exitCode;

  /// Whether keyboard input is currently allowed. Always true locally; for a
  /// remote backend it reflects the control lease (read-only until acquired).
  ValueListenable<bool> get inputEnabled;

  void dispose();
}
