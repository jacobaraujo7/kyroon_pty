# kyroon_pty_example

A polished terminal app built on **kyroon_pty** + the **xterm** emulator,
styled after the `kyroon_terminal` design system (dark Kyroon Enterprise
palette + purple product accent).

It replaces the old "dump raw bytes into a Text widget" demo with a real
terminal: full ANSI/VT emulation, a blinking block cursor, 10k-line
scrollback, selection and copy/paste.

## Features

- **Real terminal emulation** — `xterm` renders the PTY output (colors, cursor,
  alt-screen for `vim`/`htop`, etc.), wired to `kyroon_pty`'s `Pty`.
- **Tabbed sessions** — open multiple shells with the `+` button; each tab shows
  a live status dot and a close button.
- **Kyroon look** — header with logo + connection pill, per-session meta bar
  (shell · working dir · pid), rounded terminal pane, and a footer.
- **Jump-to-bottom** — a floating button appears when you scroll up.
- **Clipboard** — `Ctrl+Shift+C` / `Ctrl+Shift+V` (xterm defaults).
- **Resize-aware** — the emulator size is forwarded to the PTY (`SIGWINCH`).

## How it fits together

`lib/pty_session.dart` glues a `Pty` process to an xterm `Terminal`:

```dart
pty.output.cast<List<int>>().transform(const Utf8Decoder()).listen(terminal.write);
terminal.onOutput = (data) => pty.write(const Utf8Encoder().convert(data));
terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
```

`lib/theme.dart` holds the design tokens (colors, radii, terminal theme) and
`lib/main.dart` builds the themed app shell.

## Running

This example has three entrypoints:

| Entrypoint | Mode | Command |
| --- | --- | --- |
| `lib/main.dart` | **local** terminal (default) | `flutter run -d windows` (or macos/linux) |
| `lib/main_host.dart` | **WebSocket host** — serves a local PTY over `ws://…:8080` | `flutter run -d windows -t lib/main_host.dart` |
| `lib/main_web.dart` | **web client** — attaches to a host from the browser | see below |

### Local mode

```bash
flutter run -d windows   # or macos / linux
```

> On desktop the terminal uses `hardwareKeyboardOnly: true`, reading characters
> straight from hardware key events for reliable typing without an on-screen
> keyboard.

### Web mode (WebSocket)

A browser can't spawn a process, so the web client attaches to a PTY running on
another machine.

```bash
# 1) On the host machine — serve a real PTY over ws://localhost:8080
flutter run -d windows -t lib/main_host.dart

# 2a) Web client (normal): opens Chrome
flutter run -d chrome -t lib/main_web.dart

# 2b) Web client (if `flutter run -d chrome` is unavailable): build + serve
flutter build web -t lib/main_web.dart
cd build/web && python -m http.server 5599   # then open http://localhost:5599
```

The web client auto-connects to `ws://localhost:8080` (editable in the connect
bar). For another machine/phone use `ws://<host-LAN-IP>:8080` and open TCP 8080.

The terminal font (`CascadiaMono`) is bundled as an asset so it renders crisply
on web too. See the package
[README](../README.md#running-the-web-demo-end-to-end) for the full guide,
wire protocol and the backend contract.
