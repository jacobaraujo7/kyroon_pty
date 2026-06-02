import 'dart:io';

import 'package:flutter/material.dart';

import 'pty_websocket_server.dart';
import 'theme.dart';

/// Host entrypoint — runs a real PTY on this machine and serves it over
/// WebSocket so web/mobile clients can attach. Run with:
///
///   flutter run -d windows -t lib/main_host.dart   (or macos / linux)
///
/// Then open the web client (`flutter run -d chrome -t lib/main_web.dart`) and
/// connect to the printed ws:// URL.
void main() {
  runApp(const HostApp());
}

class HostApp extends StatelessWidget {
  const HostApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter PTY — WebSocket host',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.bg,
        colorScheme: const ColorScheme.dark(primary: AppColors.accent),
        fontFamily: 'Segoe UI',
        useMaterial3: true,
      ),
      home: const HostPage(),
    );
  }
}

class HostPage extends StatefulWidget {
  const HostPage({super.key});

  @override
  State<HostPage> createState() => _HostPageState();
}

class _HostPageState extends State<HostPage> {
  PtyWebSocketServer? _server;
  String _status = 'parado';
  String _url = '';

  @override
  void initState() {
    super.initState();
    // Demo entrypoint: start serving immediately so a web client can attach.
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _server?.stop();
    super.dispose();
  }

  Future<void> _start() async {
    final server = PtyWebSocketServer(
      // Bind to all interfaces so other machines / the web build can reach it.
      address: InternetAddress.anyIPv4,
      port: 8080,
    );
    await server.start();
    if (!mounted) return;
    setState(() {
      _server = server;
      _status = 'servindo';
      _url = 'ws://localhost:${server.boundPort}';
    });
  }

  Future<void> _stop() async {
    await _server?.stop();
    if (!mounted) return;
    setState(() {
      _server = null;
      _status = 'parado';
      _url = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final running = _server != null;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.dns_rounded, size: 56, color: AppColors.accent),
            const SizedBox(height: 16),
            const Text(
              'Flutter PTY · WebSocket host',
              style: TextStyle(color: AppColors.fg, fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              running ? 'Servindo um PTY em $_url' : 'Servidor parado',
              style: const TextStyle(color: AppColors.fgDim, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              'status: $_status',
              style: const TextStyle(color: AppColors.fgMuted, fontSize: 12),
            ),
            const SizedBox(height: 24),
            running
                ? FilledButton.icon(
                    onPressed: _stop,
                    style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
                    icon: const Icon(Icons.stop_rounded),
                    label: const Text('Parar servidor'),
                  )
                : FilledButton.icon(
                    onPressed: _start,
                    style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Iniciar servidor'),
                  ),
          ],
        ),
      ),
    );
  }
}
