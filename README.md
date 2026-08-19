# vim-global-mode

There is one mode. Everybody is in it.

Connect your Neovim to a global mode server and you no longer have your own
modal state — you have a share in everyone else's. When a colleague presses
`i`, you are in insert mode. When someone hits `<Esc>`, you are back in normal
mode, wherever you were and whatever you were doing.

This is a joke. It works completely.

```
  alex ── presses i ──▶ ┌────────┐ ──▶ sam    is now in INSERT
                        │ server │ ──▶ kim    is now in INSERT
                        └────────┘ ──▶ jo     is now in INSERT
```

## Install

The plugin is pure Lua and depends on nothing — no build step, no companion
binary, no Rust toolchain. Neovim's built-in `vim.uv` provides the TCP client.

```lua
-- lazy.nvim
{
  "lxndrcx/vim-global-mode",
  opts = {
    host = "127.0.0.1", -- must be a numeric address; libuv does not resolve names
    port = 7777,
    user = vim.env.USER,
  },
}
```

Requires Neovim 0.10 or newer.

## Run the server

The server is written in [MoonBit](https://www.moonbitlang.com/). If you do not
have the toolchain:

```sh
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
export PATH="$HOME/.moon/bin:$PATH"
```

Then build it once. `moon update` is not optional on a fresh install — the
toolchain ships no registry index, so resolving `moonbitlang/async` fails with
*"module was not found in the registry"* until you run it:

```sh
cd server
moon update
moon build --target native
./_build/native/debug/build/cmd/main/main.exe --verbose
```

```
global mode: editors may connect on 0.0.0.0:7777
global mode: dashboard on http://0.0.0.0:7778
```

| Flag | Default | Meaning |
| --- | --- | --- |
| `--bind ADDR` | `0.0.0.0` | address to listen on |
| `--port PORT` | `7777` | port for editors |
| `--http-port PORT` | `7778` | port for the web dashboard |
| `--no-web` | | do not serve the dashboard |
| `--verbose`, `-v` | | log connections and mode changes |
| `--help`, `-h` | | show usage |

`--port` and `--http-port` must differ; the server refuses to start otherwise.

## The dashboard

`http://localhost:7778` shows the current global mode in large letters, who is
responsible for it, and everyone currently subject to it. It updates live over
a WebSocket. `GET /api/state` returns the same thing as JSON.

## Statusline

```lua
-- lualine
sections = { lualine_x = { require("global-mode").lualine() } }
```

Or use the pieces directly — `require("global-mode").statusline()` returns
`INSERT · alex`, and `.highlight()` gives the matching highlight group.

## Commands

| Command | Effect |
| --- | --- |
| `:GlobalModeConnect` | submit to the global mode |
| `:GlobalModeDisconnect` | reclaim your own modal state |
| `:GlobalModeStatus` | report the global mode and who set it |
| `:checkhealth global-mode` | connection state, the global mode, and the roster |

## How it works

A `ModeChanged` autocmd reports your mode; the server records it as *the* mode
and pushes it to every other editor, which applies it with `nvim_feedkeys`.

Two details do most of the work:

**The server never echoes a change back to whoever caused it,** and the client
stays quiet about the `ModeChanged` events its own forced change produces.
Without both, one keypress becomes an infinite ping-pong storm between editors.
A third backstop lives on the server: re-reporting the mode already in force is a
no-op that does not advance the sequence counter. One keypress, one increment.

The client side of that is fussier than it sounds. Every applied mode is fed as
`CTRL-\ CTRL-N` followed by a mode key, so applying one from a *different*
non-normal mode passes through normal and fires **two** `ModeChanged` events, not
one — and two remote frames can be in flight before either one's keys land. So
the client tracks a queue of modes it is expecting, treats a transit through
normal as its own, and expires an entry after half a second in case the keys
never take effect at all.

**The heartbeat carries the global mode, and that is the only resync there is.**
Every five seconds the server states the authoritative mode; a client already in
it does nothing, and one that has drifted is pulled back. Without it, several
ways of falling out of step — a frame dropped from a full outbox, two editors
changing mode in the same instant, an apply refused by the rate limiter — leave
an editor permanently disagreeing with everyone else, because the protocol
otherwise only ever announces *changes*.

**Operator-pending mode is dropped before it reaches anything.** A `ModeChanged`
autocmd that schedules work could once loop between normal and operator-pending
until it pegged a core ([neovim#22263](https://github.com/neovim/neovim/issues/22263)).
So `d` and `y` leave everyone else alone — you can still operate on text, you
just cannot inflict the half-finished operator on anybody.

Transport is newline-delimited JSON over raw TCP, because `vim.uv` gives that
for free. The dashboard gets a real WebSocket, because a browser wants one.

## Tests

```sh
(cd server && moon test --target native)  # protocol, fan-out and hub invariants
nvim -l tests/protocol_spec.lua           # mode normalization
nvim -l tests/api_spec.lua                # config validation and the statusline API
node tests/loop-guard.js nvim             # the loop guard, against a controlled server
node tests/resync.js nvim                 # the heartbeat resync
./tests/two-editors.sh                    # two real Neovim instances, one mode
```

`scripts/fake-client.js` drives the **real** server with fake editors, so start
one first:

```sh
./server/_build/native/debug/build/cmd/main/main.exe --bind 127.0.0.1 &
node scripts/fake-client.js --clients 3
```

`tests/two-editors.sh` is the headline — it starts its own server, launches two
headless Neovim instances, presses `i` in one and asserts the other ends up in
insert mode. But it is not sufficient on its own, and says so in its own
comments: a real editor walking `i`→`v` steps its peers through normal, so the
loop guard's transit rule is unreachable from it. `tests/loop-guard.js` pushes
modes directly, which is what the `welcome` path and a backlogged client do, and
is the only thing covering that rule.

To watch traffic while driving real editors by hand:

```sh
node scripts/fake-client.js --watch --user spy
```

## Caveats

It does what it says. Someone else can put you in insert mode while you are
typing a command. That is the entire point, and there is no opt-out short of
`:GlobalModeDisconnect`.

Terminal mode is reported and displayed but never forced — you cannot
meaningfully shove someone into terminal mode in a buffer that is not a terminal.

There is no authentication. Anyone who can reach the port can change everyone's
mode. Do not put this on the public internet.
