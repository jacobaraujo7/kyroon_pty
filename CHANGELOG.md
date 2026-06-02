## 1.0.2

* **Windows ConPTY stdin fix** — the native Windows backend no longer sets
  `STARTF_USESTDHANDLES` with NULL handles when launching the child process.
  With a pseudoconsole (`PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`) the ConPTY itself
  provides the child's stdin/stdout/stderr; forcing NULL std handles conflicted
  with it and corrupted stdin. CLIs launched directly as the ConPTY root (e.g.
  `claude`) could see their own name injected into stdin right after start. The
  startup info now only sets `cb` + the pseudoconsole attribute, matching the
  official Microsoft sample.

## 1.0.1

Example app improvements (the plugin API in `lib/` is unchanged):

* **Input events** — `PtySession.onInput` (`Stream<String>`) fires when input is
  sent to the process. Live typing is buffered and emitted once per committed
  line (on Enter); the command bar emits the whole command at once. Useful for
  activity tracking, audit logs or idle-timer resets.

  ```dart
  session.onInput.listen((line) => print('input: $line'));
  ```

* **CLI idle detection** — `PtySession.onIdle` (`Stream<TerminalIdleEvent>`)
  fires when the process stops producing output after a burst of activity — a
  heuristic for "the CLI (claude/codex/qwen/…) finished and is idle". Tunable
  via `session.idleThreshold` (default 1.5s) and an optional
  `session.idleReadyPattern` (a `RegExp` matched against recent output so a long
  *silent* task doesn't look idle until its prompt returns). A reactive
  `session.busy` drives the RUNNING/IDLE status badge.

  ```dart
  session.idleThreshold = const Duration(milliseconds: 1200);
  session.idleReadyPattern = RegExp(r'\$ $'); // fire only when the prompt is back
  session.onIdle.listen((e) => print('idle after ${e.busyFor.inMilliseconds}ms'));
  ```

* **Accented input in the terminal** — dead-key composition (´ ` ^ ~ ¨ + letter →
  á ã ê ç ü …) for typing directly into the PTY on desktop, where the IME path
  is unavailable on Windows.

* **Ctrl+Enter / Shift+Enter** — send a newline (LF) instead of submitting (CR),
  matching how CLIs like Claude/readline insert a line break.

* **Command bar ⇄ direct-PTY toggle** — switch between typing through the input
  bar and typing straight into the terminal.

* **WebSocket host input event** — `PtyWebSocketServer.onInput`
  (`Stream<Uint8List>`) notifies the host when a remote client sends input.

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
