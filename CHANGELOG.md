## 1.0.0

* First stable release of `kyroon_pty`.
* Native PTY implementation: `forkpty` on Linux/macOS/Android and ConPTY on
  Windows (Windows 10 1809+).
* Spawn a child process attached to a pseudo-terminal with full support for
  line editing, ANSI colors, cursor control, job control and resize.
* Core API: `Pty.start`, `output` stream, `write`, `resize`, `kill`,
  `exitCode`, `pid` and optional read acknowledgement (`ackRead`) for
  backpressure.
* Configurable working directory and environment variables.
* Designed to pair with [`xterm`](https://pub.dev/packages/xterm) for a fully
  interactive terminal widget.
* Example app with tabbed local terminals, pluggable backends (local PTY vs.
  remote stream) and a batteries-included WebSocket transport + server for
  remote/web terminals.
