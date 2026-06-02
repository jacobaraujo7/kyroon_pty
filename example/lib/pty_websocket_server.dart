import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kyroon_pty/kyroon_pty.dart';

import 'pty_session.dart' show defaultShell;

/// Host side of the PTY-over-WebSocket protocol: spawns a real [Pty] on *this*
/// machine and exposes it to remote clients over a WebSocket. The desktop app
/// running kyroon_pty becomes the host; a web/mobile app (using
/// `WebSocketPtyTransport`) attaches to it.
///
/// This is the piece a browser cannot provide for itself — turn any machine
/// that can run kyroon_pty into a remote terminal host.
///
/// Protocol (see `WebSocketPtyTransport` for the client half):
///   * binary frame  : raw PTY bytes (out: output, in: stdin)
///   * `{"type":"resize","cols":c,"rows":r}` (client → host)
///   * `{"type":"snapshot","dataB64":...}`   (host → client, on connect)
///   * `{"type":"exit","code":n}`            (host → client, on process end)
///
/// One shared PTY backs all connected clients (a shared session). This server
/// is intentionally simple — it has no auth and lets every client type. For
/// authentication, a single-writer control lease, and fan-out across server
/// instances, use a richer backend (e.g. gRPC + Redis); the client side is the
/// same `RemotePtyBackend`.
class PtyWebSocketServer {
  PtyWebSocketServer({
    this.shell,
    this.arguments = const [],
    this.address,
    this.port = 8080,
    this.snapshotLimit = 64 * 1024,
  });

  /// Executable to run; defaults to the platform shell.
  final String? shell;
  final List<String> arguments;

  /// Bind address; defaults to loopback (localhost only). Use
  /// `InternetAddress.anyIPv4` to accept connections from other machines.
  final InternetAddress? address;
  final int port;

  /// How many recent output bytes to replay to a newly connected client.
  final int snapshotLimit;

  HttpServer? _server;
  Pty? _pty;
  int? _exitCode;
  final _clients = <WebSocket>{};
  final _snapshot = BytesBuilder(copy: false);
  final _inputController = StreamController<Uint8List>.broadcast();

  bool get isRunning => _server != null;
  int get boundPort => _server?.port ?? port;

  /// Fires on this host (the "origin system") every time a connected client
  /// sends input (stdin) — i.e. someone typed/pasted into the terminal from a
  /// remote viewer. Use it for activity tracking, audit logging, idle timeouts
  /// or to wake the host UI. Emits the raw bytes that were written to the PTY.
  Stream<Uint8List> get onInput => _inputController.stream;

  Future<void> start() async {
    if (_server != null) return;

    _server = await HttpServer.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );

    final exe = shell ?? defaultShell;
    final pty = Pty.start(
      exe,
      arguments: arguments,
      columns: 80,
      rows: 24,
      environment: Map<String, String>.from(Platform.environment),
    );
    _pty = pty;

    pty.output.listen((chunk) {
      _appendSnapshot(chunk);
      for (final ws in _clients) {
        ws.add(chunk); // binary frame
      }
    });

    pty.exitCode.then((code) {
      _exitCode = code;
      final msg = jsonEncode({'type': 'exit', 'code': code});
      for (final ws in _clients) {
        ws.add(msg);
      }
    });

    _server!.listen((req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        try {
          final ws = await WebSocketTransformer.upgrade(req);
          _onClient(ws);
        } catch (_) {/* failed upgrade */}
      } else {
        req.response.statusCode = HttpStatus.upgradeRequired;
        await req.response.close();
      }
    });
  }

  void _onClient(WebSocket ws) {
    _clients.add(ws);

    // Replay the buffered screen so the client sees the current state.
    final snap = _snapshot.toBytes();
    if (snap.isNotEmpty) {
      ws.add(jsonEncode({'type': 'snapshot', 'dataB64': base64Encode(snap)}));
    }
    if (_exitCode != null) {
      ws.add(jsonEncode({'type': 'exit', 'code': _exitCode}));
    }

    ws.listen(
      (message) {
        if (message is List<int>) {
          final bytes = Uint8List.fromList(message);
          _pty?.write(bytes); // stdin
          // Notify the origin system that a client interacted with the input.
          if (!_inputController.isClosed) _inputController.add(bytes);
        } else if (message is String) {
          _onControl(message);
        }
      },
      onDone: () => _clients.remove(ws),
      onError: (_) => _clients.remove(ws),
      cancelOnError: true,
    );
  }

  void _onControl(String text) {
    try {
      final msg = jsonDecode(text);
      if (msg is Map && msg['type'] == 'resize') {
        final cols = (msg['cols'] as num?)?.toInt() ?? 0;
        final rows = (msg['rows'] as num?)?.toInt() ?? 0;
        if (cols > 0 && rows > 0) _pty?.resize(rows, cols);
      }
    } catch (_) {/* ignore malformed control */}
  }

  void _appendSnapshot(List<int> chunk) {
    _snapshot.add(chunk);
    if (_snapshot.length > snapshotLimit) {
      final bytes = _snapshot.toBytes();
      _snapshot.clear();
      _snapshot.add(bytes.sublist(bytes.length - snapshotLimit));
    }
  }

  Future<void> stop() async {
    for (final ws in _clients.toList()) {
      try {
        await ws.close();
      } catch (_) {/* best-effort */}
    }
    _clients.clear();
    try {
      _pty?.kill();
    } catch (_) {/* best-effort */}
    await _server?.close(force: true);
    _server = null;
    _pty = null;
    await _inputController.close();
  }
}
