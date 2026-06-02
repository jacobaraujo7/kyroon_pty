import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kyroon_pty_example/remote_pty_backend.dart';
import 'package:kyroon_pty_example/websocket_pty_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercises the PTY-over-WebSocket wire protocol from the client
/// ([WebSocketPtyTransport]) side, against a hand-rolled server that mimics
/// [PtyWebSocketServer]'s framing. Verifies both directions:
///   * server → client: snapshot (text JSON) + live output (binary) + exit
///   * client → server: stdin (binary) + resize (text JSON)
void main() {
  test('WebSocketPtyTransport speaks the PTY-over-WebSocket protocol', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    final receivedInput = <int>[];
    final receivedControl = <String>[];
    late WebSocket serverWs;

    server.listen((req) async {
      serverWs = await WebSocketTransformer.upgrade(req);
      // 1) snapshot replay (text JSON)
      serverWs.add(jsonEncode({
        'type': 'snapshot',
        'dataB64': base64Encode(utf8.encode('SNAPSHOT')),
      }));
      // 2) live output (binary)
      serverWs.add(Uint8List.fromList(utf8.encode('live-output')));
      // collect what the client sends back
      serverWs.listen((msg) {
        if (msg is List<int>) {
          receivedInput.addAll(msg);
        } else if (msg is String) {
          receivedControl.add(msg);
        }
      });
    });

    final transport = WebSocketPtyTransport('ws://127.0.0.1:${server.port}');
    final frames = <RemotePtyFrame>[];
    final sub = transport.streamPty().listen(frames.add);

    // Let snapshot + live frames arrive.
    await _until(() => frames.length >= 2);

    expect(frames[0].isSnapshot, isTrue, reason: 'first frame is the snapshot');
    expect(utf8.decode(frames[0].data), 'SNAPSHOT');
    expect(frames[1].isSnapshot, isFalse);
    expect(utf8.decode(frames[1].data), 'live-output');
    expect(frames[1].seq, greaterThan(frames[0].seq), reason: 'seq increments');

    // Client → server: input goes as a binary frame, resize as JSON.
    await transport.sendInput('ws', utf8.encode('ls -al\r'));
    await transport.resize('ws', cols: 120, rows: 40);
    await _until(() =>
        receivedInput.isNotEmpty && receivedControl.isNotEmpty);

    expect(utf8.decode(receivedInput), 'ls -al\r');
    expect(receivedControl.single, contains('"type":"resize"'));
    expect(receivedControl.single, contains('"cols":120'));
    expect(receivedControl.single, contains('"rows":40'));

    // Server → client: exit closes the session.
    serverWs.add(jsonEncode({'type': 'exit', 'code': 0}));
    await _until(() => frames.any((f) => f.closed));
    expect(frames.last.closed, isTrue);

    await sub.cancel();
    await transport.close();
  });
}

/// Polls [condition] until true or a timeout, without a fixed sleep.
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}
