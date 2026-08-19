# global-mode-server

The server behind [vim-global-mode](../README.md). It owns the single global
mode, fans changes out to every connected editor, and serves the live dashboard.

Written in MoonBit, on the native backend, using
[`moonbitlang/async`](https://github.com/moonbitlang/async) for sockets and HTTP.

## Build and run

```sh
moon update   # required once: a fresh toolchain ships no registry index
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

`state` holds all the *shared* mutable state — `editors` keeps only a
per-connection counter of unanswered pings. The async runtime is
single-threaded, so every mutation runs to completion before another task
observes it, and no locking is needed.

## Ports

Editors get raw TCP; the dashboard gets a WebSocket. That split is deliberate:
Neovim's `vim.uv` provides a TCP client for free, so a plugin talking newline-
delimited JSON needs no dependencies at all, whereas a browser wants a real
WebSocket. Each side gets the transport that costs it nothing.

## Connection handling

The welcome frame is written directly, before the group exists. After that,
each editor connection runs three tasks in one group:

- a **reader**, which is the group body — the connection lives exactly as long
  as the editor keeps talking;
- a **writer**, thereafter the only thing that sends, draining that client's
  outbox;
- a **heartbeat**, every five seconds.

The writer being the sole sender is what keeps a broadcast from blocking on one
slow peer. Each outbox is a bounded queue that discards its oldest frames, so a
stalled editor falls behind and catches up rather than stalling everyone else.

The heartbeat does two jobs. It hangs up after two unanswered pings, since TCP
will otherwise hold a dead connection open indefinitely — and it carries the
authoritative mode, which is the only resync in the protocol. Everything else
announces *changes*, so an editor that missed one would disagree with everyone
else forever; instead it is corrected within five seconds.

## Limits

Everything a client can grow is bounded, because none of it is authenticated:

| Limit | Value | Why |
| --- | --- | --- |
| `MAX_EDITORS` | 256 | each accept costs a roster broadcast to everyone |
| `MAX_DASHBOARDS` | 64 | `subscribe_dashboard` grows a map |
| `MAX_LINE_BYTES` | 8192 | an unbounded line cost 100% of a core and 56 MB |
| `OUTBOX_DEPTH` | 64 | bounds what a stalled client can hold |
| `MAX_FIELD_UNITS` | 64 | names are copied into every roster frame |

Only the first `hello` on a connection counts, too: every identify fans a fresh
roster to everyone, so an unthrottled one is an O(n) amplifier — one client
repeating it pinned a core with 150 idle editors attached.

## Tests

```sh
moon test --target native
```

Covers protocol round-tripping, rejection of invalid and injected input, and the
fan-out invariants: the originator is excluded from its own broadcast, `seq`
advances by exactly one per real change, re-reporting the current mode is a
no-op, and a client that never reads gets a bounded backlog whose newest frame
is the current mode. Also: only the first `hello` counts, names that cannot be
encoded as UTF-8 are refused, over-long fields fall back to the default, and
dashboards are pushed state on every change.

For the server end-to-end, start the binary and then drive it with fake editors
— no Neovim required:

```sh
./_build/native/debug/build/cmd/main/main.exe --bind 127.0.0.1 &
node ../scripts/fake-client.js --clients 3
```
