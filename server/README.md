# global-mode-server

The server behind [vim-global-mode](../README.md). It owns the single global
mode, fans changes out to every connected editor, and serves the live dashboard.

Written in MoonBit, on the native backend, using
[`moonbitlang/async`](https://github.com/moonbitlang/async) for sockets and HTTP.

## Build and run

```sh
moon build --target native
./_build/native/debug/build/cmd/main/main.exe --verbose
```

```
global mode: editors may connect on 0.0.0.0:7777
global mode: dashboard on http://0.0.0.0:7778
```

## Layout

| Package | Responsibility |
| --- | --- |
| `protocol` | The mode alphabet, and JSON encoding/decoding of every frame |
| `state` | The global mode, the sequence counter, the client registry, fan-out |
| `editors` | TCP listener on 7777, newline-delimited JSON |
| `web` | HTTP + WebSocket on 7778, with the dashboard page embedded |
| `logging` | Unbuffered stdout, so `--verbose` is visible in a pipe |
| `cmd/main` | Flags, and starting both listeners |

`state` is the only package holding mutable state. The async runtime is
single-threaded, so every mutation runs to completion before another task
observes it, and no locking is needed.

## Ports

Editors get raw TCP; the dashboard gets a WebSocket. That split is deliberate:
Neovim's `vim.uv` provides a TCP client for free, so a plugin talking newline-
delimited JSON needs no dependencies at all, whereas a browser wants a real
WebSocket. Each side gets the transport that costs it nothing.

## Connection handling

Each editor connection runs three tasks in one group:

- a **reader**, which is the group body — the connection lives exactly as long
  as the editor keeps talking;
- a **writer**, the only thing that ever sends, draining that client's outbox;
- a **heartbeat**, which pings an idle editor and hangs up after two unanswered
  pings, since TCP will otherwise hold a dead connection open indefinitely.

The writer being the sole sender is what keeps a broadcast from blocking on one
slow peer. Each outbox is a bounded queue that discards its oldest frames, so a
stalled editor falls behind and catches up rather than stalling everyone else.

## Tests

```sh
moon test --target native
```

Covers protocol round-tripping, rejection of invalid and injected input, and the
fan-out invariants: the originator is excluded from its own broadcast, `seq`
advances by exactly one per real change, re-reporting the current mode is a
no-op, and a client that never reads gets a bounded backlog.

For the server end-to-end, `node ../scripts/fake-client.js --clients 3` drives it
with fake editors — no Neovim required.
