import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'remote_pty_backend.dart';

/// A [RemotePtyTransport] that speaks the PTY-over-WebSocket protocol below.
///
/// This is what unlocks **web** (browsers can't spawn processes, so they attach
/// to a PTY running elsewhere) and is the simplest portable option for mobile /
/// another machine. It plugs straight into [RemotePtyBackend], reusing its
/// snapshot reset, seq dedup, streaming UTF-8 decode and control gating.
///
/// ## Wire protocol (matches [PtyWebSocketServer])
///
/// One WebSocket per session.
///
/// * **Binary frame** = raw PTY bytes.
///   * server → client: process output.
///   * client → server: process stdin (typed input / pasted text / commands).
/// * **Text frame** = a JSON control message `{ "type": ... }`:
///   * client → server: `{"type":"resize","cols":80,"rows":24}`
///   * server → client: `{"type":"snapshot","dataB64":"<base64>"}` — the
///     buffered screen, sent once on (re)connect so a late joiner sees current
///     state. Mapped to an `isSnapshot` frame (the backend resets first).
///   * server → client: `{"type":"exit","code":0}` — process ended.
///
/// Keeping output on binary frames avoids base64 overhead on the hot path;
/// control stays human-readable JSON.
class WebSocketPtyTransport implements RemotePtyTransport {
  WebSocketPtyTransport(this.url, {this.protocols});

  /// `ws://host:port/path` or `wss://...`.
  final String url;
  final Iterable<String>? protocols;

  WebSocketChannel? _channel;
  int _seq = 0;

  @override
  Stream<RemotePtyFrame> streamPty() {
    final channel = WebSocketChannel.connect(
      Uri.parse(url),
      protocols: protocols,
    );
    _channel = channel;

    final controller = StreamController<RemotePtyFrame>();
    channel.stream.listen(
      (message) {
        if (message is String) {
          _onText(controller, message);
        } else if (message is List<int>) {
          // Live output bytes.
          controller.add(RemotePtyFrame(data: message, seq: ++_seq));
        }
      },
      onError: controller.addError,
      onDone: () {
        if (!controller.isClosed) controller.close();
      },
      cancelOnError: false,
    );
    return controller.stream;
  }

  void _onText(StreamController<RemotePtyFrame> out, String text) {
    final msg = _tryDecode(text);
    if (msg == null) {
      // Not JSON → treat as plain-text output (some servers send text frames).
      out.add(RemotePtyFrame(data: utf8.encode(text), seq: ++_seq));
      return;
    }
    switch (msg['type']) {
      case 'snapshot':
        final b64 = (msg['dataB64'] as String?) ?? '';
        out.add(RemotePtyFrame(
          data: b64.isEmpty ? const [] : base64Decode(b64),
          seq: ++_seq,
          isSnapshot: true,
        ));
        break;
      case 'exit':
        out.add(RemotePtyFrame(data: const [], seq: ++_seq, closed: true));
        break;
      default:
        break; // ignore unknown control messages
    }
  }

  Map<String, dynamic>? _tryDecode(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  // A single WebSocket session owns its input, so control is granted locally.
  // (Multi-viewer single-writer arbitration belongs to a richer backend such as
  // the gRPC + Redis one.)
  @override
  Future<String?> acquireControl({bool force = false}) async => 'ws';

  @override
  Future<void> releaseControl(String controlToken) async {}

  @override
  Future<void> sendInput(String controlToken, List<int> data) async {
    _channel?.sink.add(data); // binary frame = stdin
  }

  @override
  Future<void> resize(String controlToken, {required int cols, required int rows}) async {
    _channel?.sink.add(jsonEncode({'type': 'resize', 'cols': cols, 'rows': rows}));
  }

  Future<void> close() async {
    await _channel?.sink.close();
    _channel = null;
  }
}
