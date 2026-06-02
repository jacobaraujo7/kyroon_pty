import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'terminal_backend.dart';

/// One frame of PTY output coming off the wire. Mirrors the server's `PtyFrame`
/// (terminal_stream.proto) without dragging gRPC into this example.
class RemotePtyFrame {
  const RemotePtyFrame({
    required this.data,
    this.seq = 0,
    this.isSnapshot = false,
    this.closed = false,
    this.controlHolderUserId = '',
  });

  /// Raw bytes from the PTY (NOT pre-decoded — UTF-8 is decoded by the backend
  /// in streaming mode so multi-byte glyphs split across frames survive).
  final List<int> data;

  /// Monotonic sequence number; used to drop duplicates / out-of-order frames.
  final int seq;

  /// True for the buffer replay sent on (re)connect — triggers a screen reset.
  final bool isSnapshot;

  /// True when the remote process has ended.
  final bool closed;

  /// Who currently holds the input lease (for the read-only banner).
  final String controlHolderUserId;
}

/// The network seam. Implement this in your app (e.g. kyroon_app) on top of the
/// existing `PtyTerminalService` / gRPC `TerminalStreamService`. Keeping it an
/// interface lets this example compile with no gRPC dependency.
///
/// Reference mapping (kyroon_app `PtyTerminalService`):
///   streamPty()        -> client.streamPty(StreamPtyRequest)  → map PtyFrame
///   acquireControl()   -> client.acquirePtyControl(...)       → ack.controlToken
///   releaseControl()   -> client.releasePtyControl(...)
///   sendInput()        -> client.sendPtyInput(PtyInputRequest{ data, token })
///   resize()           -> client.resizePty(PtyResizeRequest{ cols, rows, token })
abstract class RemotePtyTransport {
  /// Server stream of output frames (snapshot first, then incremental).
  Stream<RemotePtyFrame> streamPty();

  /// Acquire the input lease. Returns the control token, or null if denied
  /// (someone else holds it). The token has a server TTL (~30s) refreshed by
  /// each [sendInput]/[resize] call.
  Future<String?> acquireControl({bool force = false});

  Future<void> releaseControl(String controlToken);

  Future<void> sendInput(String controlToken, List<int> data);

  Future<void> resize(String controlToken, {required int cols, required int rows});
}

/// A [TerminalBackend] fed by a remote PTY stream — the mobile / "watch a PTY
/// running on another machine" case. Same xterm emulator, different transport.
///
/// Handles the things a naive wiring gets wrong:
///  * **snapshot reset** — clears the screen before replaying buffered output;
///  * **seq dedup** — ignores duplicate / out-of-order frames;
///  * **streaming UTF-8** — buffers partial sequences across frames (no ``);
///  * **control lease** — input is disabled until [acquireControl] succeeds, so
///    the view is read-only by default; bind `TerminalView.readOnly` to
///    [inputEnabled].
class RemotePtyBackend implements TerminalBackend {
  RemotePtyBackend(this._transport) {
    _start();
  }

  final RemotePtyTransport _transport;

  final _output = StreamController<String>.broadcast();
  final _done = Completer<void>();
  final _inputEnabled = ValueNotifier<bool>(false);

  /// Who currently holds the input lease (empty if nobody / unknown).
  final controlHolder = ValueNotifier<String>('');

  StreamSubscription<RemotePtyFrame>? _sub;
  String _controlToken = '';
  int _lastSeq = 0;
  bool _disposed = false;

  // Stateful streaming UTF-8 decoder: feed raw bytes, get decoded strings with
  // partial multi-byte sequences buffered between frames.
  late final Sink<List<int>> _byteSink =
      const Utf8Decoder(allowMalformed: true).startChunkedConversion(
    _CallbackStringSink((s) {
      if (!_disposed) _output.add(s);
    }),
  );

  @override
  Stream<String> get output => _output.stream;

  @override
  Future<void> get done => _done.future;

  @override
  int? get exitCode => null; // remote viewer doesn't observe the real exit code

  @override
  int? get pid => null; // the process lives on the host machine

  @override
  ValueListenable<bool> get inputEnabled => _inputEnabled;

  Future<void> _start() async {
    try {
      final stream = _transport.streamPty();
      _sub = stream.listen(
        _onFrame,
        onError: (_) {
          if (!_done.isCompleted) _done.complete();
        },
        onDone: () {
          if (!_done.isCompleted) _done.complete();
        },
      );
    } catch (_) {
      if (!_done.isCompleted) _done.complete();
    }
  }

  void _onFrame(RemotePtyFrame frame) {
    if (_disposed) return;

    if (frame.isSnapshot) {
      // Clear scrollback + screen, home the cursor, then replay — keeps
      // reconnects from stacking the buffer on top of itself.
      _output.add('\x1b[2J\x1b[3J\x1b[H');
      _lastSeq = 0;
    } else if (frame.seq <= _lastSeq) {
      return; // duplicate / out of order
    }
    if (frame.seq > _lastSeq) _lastSeq = frame.seq;

    if (frame.data.isNotEmpty) _byteSink.add(frame.data);

    controlHolder.value = frame.controlHolderUserId;

    if (frame.closed && !_done.isCompleted) _done.complete();
  }

  /// Request the input lease. On success the view becomes writable.
  Future<bool> acquireControl({bool force = false}) async {
    final token = await _transport.acquireControl(force: force);
    if (_disposed) return false;
    _controlToken = token ?? '';
    _inputEnabled.value = _controlToken.isNotEmpty;
    return _inputEnabled.value;
  }

  /// Give up the lease; the view goes read-only again.
  Future<void> releaseControl() async {
    final token = _controlToken;
    _controlToken = '';
    _inputEnabled.value = false;
    if (token.isNotEmpty) {
      try {
        await _transport.releaseControl(token);
      } catch (_) {/* best-effort */}
    }
  }

  @override
  void write(String data) {
    if (_controlToken.isEmpty || data.isEmpty) return; // read-only without lease
    _transport.sendInput(_controlToken, const Utf8Encoder().convert(data));
  }

  @override
  void resize(int rows, int cols) {
    if (_controlToken.isEmpty || rows <= 0 || cols <= 0) return;
    _transport.resize(_controlToken, cols: cols, rows: rows);
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    if (_controlToken.isNotEmpty) {
      // fire-and-forget release so we don't leave a dangling lease
      _transport.releaseControl(_controlToken).catchError((_) {});
    }
    _byteSink.close();
    _inputEnabled.dispose();
    controlHolder.dispose();
    _output.close();
  }
}

/// Minimal [Sink] that forwards decoded strings to a callback.
class _CallbackStringSink implements Sink<String> {
  _CallbackStringSink(this._onData);
  final void Function(String) _onData;

  @override
  void add(String data) => _onData(data);

  @override
  void close() {}
}
