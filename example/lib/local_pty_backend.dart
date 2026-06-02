import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kyroon_pty/kyroon_pty.dart';

import 'terminal_backend.dart';

/// A [TerminalBackend] backed by a local pseudo-terminal via kyroon_pty.
/// This is what runs when the app sits on the same machine as the shell.
///
/// Native-only — imports `dart:io` and `kyroon_pty` (`dart:ffi`), so it is NOT
/// part of the web build. The web client uses `RemotePtyBackend` instead.
class LocalPtyBackend implements TerminalBackend {
  LocalPtyBackend({
    required String executable,
    List<String> arguments = const [],
    required int columns,
    required int rows,
    Map<String, String>? environment,
  }) {
    _pty = Pty.start(
      executable,
      arguments: arguments,
      columns: columns,
      rows: rows,
      // Inherit the full parent environment, like a real terminal — otherwise
      // on Windows `Path`/`SystemRoot`/`APPDATA` are missing and external
      // commands (e.g. `claude`) can't be resolved.
      environment: environment ?? Map<String, String>.from(Platform.environment),
    );

    // Streaming UTF-8 decode: the transform keeps partial sequences buffered
    // across chunks, so a split `─`/accented byte never renders as ``.
    _outputSub = _pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_output.add);

    _pty.exitCode.then((code) {
      _exitCode = code;
      if (!_done.isCompleted) _done.complete();
    });
  }

  late final Pty _pty;
  final _output = StreamController<String>.broadcast();
  final _done = Completer<void>();
  final _inputEnabled = ValueNotifier<bool>(true);
  StreamSubscription<String>? _outputSub;
  int? _exitCode;

  @override
  Stream<String> get output => _output.stream;

  @override
  Future<void> get done => _done.future;

  @override
  int? get exitCode => _exitCode;

  @override
  int? get pid {
    try {
      return _pty.pid;
    } catch (_) {
      return null;
    }
  }

  @override
  ValueListenable<bool> get inputEnabled => _inputEnabled;

  @override
  void write(String data) {
    _pty.write(const Utf8Encoder().convert(data));
  }

  @override
  void resize(int rows, int cols) {
    _pty.resize(rows, cols);
  }

  @override
  void dispose() {
    _outputSub?.cancel();
    if (_exitCode == null) {
      try {
        _pty.kill();
      } catch (_) {/* best-effort */}
    }
    _inputEnabled.dispose();
    _output.close();
  }
}
