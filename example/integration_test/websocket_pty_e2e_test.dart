import 'dart:io';

import 'package:kyroon_pty_example/pty_websocket_server.dart';
import 'package:kyroon_pty_example/remote_pty_backend.dart';
import 'package:kyroon_pty_example/websocket_pty_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// True end-to-end test of the WebSocket remote mode — this is the exact path
/// the **web** client uses, minus the browser's xterm rendering:
///
///   client types  → WebSocketPtyTransport → ws → PtyWebSocketServer
///                  → real kyroon_pty PTY on this machine → runs the command
///   output streams → ws → RemotePtyBackend → (would be) terminal.write
///
/// Runs on a desktop device (`-d windows`) because the host half needs the
/// native PTY library.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('type a command over WebSocket and see its output come back',
      (tester) async {
    // 1) Host: serve a real PTY on an ephemeral localhost port.
    final server = PtyWebSocketServer(
      address: InternetAddress.loopbackIPv4,
      port: 0,
    );
    await server.start();
    addTearDown(server.stop);

    // 2) Client: the same backend the web app uses.
    final backend = RemotePtyBackend(
      WebSocketPtyTransport('ws://127.0.0.1:${server.boundPort}'),
    );
    addTearDown(backend.dispose);

    final out = StringBuffer();
    backend.output.listen(out.write);

    // 3) Acquire control and type a command (Enter = \r).
    final granted = await backend.acquireControl();
    expect(granted, isTrue);

    const marker = 'ws_e2e_marker_42';
    final cmd = Platform.isWindows ? 'echo $marker' : 'printf "$marker\\n"';
    backend.write('$cmd\r');

    // 4) The command runs on the host PTY and its output streams back to us.
    await _until(() => out.toString().contains(marker),
        timeout: const Duration(seconds: 12));
    expect(out.toString(), contains(marker));
  });
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
