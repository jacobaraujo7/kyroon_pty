import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'remote_pty_backend.dart';
import 'terminal_backend.dart';
import 'theme.dart';
import 'websocket_pty_transport.dart';

/// Web entrypoint — a browser can't spawn a PTY, so it **attaches** to one
/// running on another machine over WebSocket. Run with:
///
///   flutter run -d chrome -t lib/main_web.dart
///
/// and point it at a host running `PtyWebSocketServer` (see `bin/pty_host.dart`
/// or `flutter run -d windows -t lib/main_host.dart`).
///
/// This file is web-safe: it imports only the remote/WebSocket path, never
/// `kyroon_pty` / `dart:io` / `dart:ffi`.
void main() {
  runApp(const WebTerminalApp());
}

class WebTerminalApp extends StatelessWidget {
  const WebTerminalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter PTY — Web (WebSocket)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.bg,
        colorScheme: const ColorScheme.dark(primary: AppColors.accent),
        fontFamily: 'Segoe UI',
        useMaterial3: true,
      ),
      home: const WebTerminalPage(),
    );
  }
}

class WebTerminalPage extends StatefulWidget {
  const WebTerminalPage({super.key});

  @override
  State<WebTerminalPage> createState() => _WebTerminalPageState();
}

class _WebTerminalPageState extends State<WebTerminalPage> {
  final _urlController = TextEditingController(text: 'ws://localhost:8080');

  Terminal? _terminal;
  RemotePtyBackend? _backend;
  StreamSubscription<String>? _outputSub;
  bool _connecting = false;
  String _status = 'desconectado';

  @override
  void initState() {
    super.initState();
    // Demo entrypoint: auto-connect to the default host on launch.
    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  @override
  void dispose() {
    _teardown();
    _urlController.dispose();
    super.dispose();
  }

  void _teardown() {
    _outputSub?.cancel();
    _outputSub = null;
    _backend?.dispose();
    _backend = null;
  }

  Future<void> _connect() async {
    _teardown();
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    final terminal = Terminal(maxLines: 10000);
    final backend = RemotePtyBackend(WebSocketPtyTransport(url));

    _outputSub = backend.output.listen((data) => terminal.write(data));
    terminal.onOutput = (data) => backend.write(data);
    terminal.onResize = (w, h, pw, ph) => backend.resize(h, w);
    backend.done.then((_) {
      if (mounted) setState(() => _status = 'sessão encerrada');
    });

    setState(() {
      _connecting = true;
      _status = 'conectando…';
      _terminal = terminal;
      _backend = backend;
    });

    // Single-connection server grants control immediately → writable terminal.
    await backend.acquireControl();
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _status = 'ao vivo';
    });
  }

  void _disconnect() {
    _teardown();
    setState(() {
      _terminal = null;
      _status = 'desconectado';
    });
  }

  @override
  Widget build(BuildContext context) {
    final connected = _terminal != null;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _ConnectBar(
              controller: _urlController,
              connected: connected,
              connecting: _connecting,
              status: _status,
              onConnect: _connect,
              onDisconnect: _disconnect,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: connected
                    ? _RemoteTerminal(terminal: _terminal!, backend: _backend!)
                    : const _EmptyState(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectBar extends StatelessWidget {
  const _ConnectBar({
    required this.controller,
    required this.connected,
    required this.connecting,
    required this.status,
    required this.onConnect,
    required this.onDisconnect,
  });

  final TextEditingController controller;
  final bool connected;
  final bool connecting;
  final String status;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final live = status == 'ao vivo';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cable_rounded, size: 18, color: AppColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: !connected,
              onSubmitted: (_) => connected ? null : onConnect(),
              style: const TextStyle(
                color: AppColors.fg,
                fontSize: 13,
                fontFamily: kMonoFontFamily,
                fontFamilyFallback: kMonoFontFallback,
              ),
              cursorColor: AppColors.accent,
              decoration: const InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: 'ws://host:porta',
                hintStyle: TextStyle(color: AppColors.fgMuted, fontSize: 13),
              ),
            ),
          ),
          const SizedBox(width: 12),
          _StatusDot(live: live, connecting: connecting),
          const SizedBox(width: 6),
          Text(status, style: const TextStyle(color: AppColors.fgDim, fontSize: 12)),
          const SizedBox(width: 12),
          if (connected)
            FilledButton.icon(
              onPressed: onDisconnect,
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              icon: const Icon(Icons.link_off_rounded, size: 18),
              label: const Text('Desconectar'),
            )
          else
            FilledButton.icon(
              onPressed: connecting ? null : onConnect,
              style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('Conectar'),
            ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.live, required this.connecting});
  final bool live;
  final bool connecting;

  @override
  Widget build(BuildContext context) {
    final color = live
        ? AppColors.success
        : connecting
            ? AppColors.warning
            : AppColors.fgMuted;
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _RemoteTerminal extends StatelessWidget {
  const _RemoteTerminal({required this.terminal, required this.backend});
  final Terminal terminal;
  final TerminalBackend backend;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        decoration: BoxDecoration(
          color: kTerminalTheme.background,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.border),
        ),
        child: ValueListenableBuilder<bool>(
          valueListenable: backend.inputEnabled,
          builder: (context, canInput, _) => TerminalView(
            terminal,
            theme: kTerminalTheme,
            textStyle: const TerminalStyle(
              fontSize: 13,
              fontFamily: kMonoFontFamily,
              fontFamilyFallback: kMonoFontFallback,
            ),
            padding: const EdgeInsets.all(10),
            autofocus: true,
            readOnly: !canInput,
            // Web: keep the default IME/text-input path so the browser/soft
            // keyboard works (do NOT force hardwareKeyboardOnly here).
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.terminal_rounded, size: 48, color: AppColors.fgMuted),
          SizedBox(height: 12),
          Text(
            'Conecte a um host PtyWebSocketServer',
            style: TextStyle(color: AppColors.fg, fontSize: 15, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 6),
          Text(
            'Rode o servidor na máquina e informe a URL ws:// acima.',
            style: TextStyle(color: AppColors.fgDim, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
