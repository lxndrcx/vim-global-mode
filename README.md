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

## Run a server

The server is a separate project:
[lxndrcx/vim-global-mode-server-ada](https://github.com/lxndrcx/vim-global-mode-server-ada).
It is Ada/SPARK, speaks UDP, and holds one file descriptor no matter how many
editors connect:

```sh
git clone https://github.com/lxndrcx/vim-global-mode-server-ada
cd vim-global-mode-server-ada
gprbuild -P global_mode.gpr
./bin/global_mode --verbose
```

```
global mode: editors may connect on 0.0.0.0: 7777
global mode: one socket, up to 1024 editors
```

Its flags and limits are documented there. This side needs to know only the
port: editors send 84-byte datagrams to `7777`.

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

**Every frame carries the whole state, so nobody can drift.** The server never
sends "the mode changed"; it sends "the mode is X, set by Y, and this is change
number N", and a client adopts anything at least as new as what it has. Order
does not matter, duplicates are no-ops, and a datagram lost in flight is
replaced by the next refresh a couple of seconds later. There is no resync path
because nothing is ever incremental — an earlier version of this protocol
announced only changes, and every way of missing one was permanent.

**Joining takes a round trip, because UDP source addresses are forgeable.** The
server answers `hello` with a token computed from the address the hello came
from, and admits you only when you echo it back. Without that, anyone could
claim to be somebody else's address and have the server aim traffic at them.
The token is computed rather than stored, so there is no handshake table for a
flood to exhaust.

**Operator-pending mode is dropped before it reaches anything.** A `ModeChanged`
autocmd that schedules work could once loop between normal and operator-pending
until it pegged a core ([neovim#22263](https://github.com/neovim/neovim/issues/22263)).
So `d` and `y` leave everyone else alone — you can still operate on text, you
just cannot inflict the half-finished operator on anybody.

Transport is fixed 84-byte frames over UDP. One datagram is one frame, so the
plugin does no framing at all: there is no length prefix to read, no delimiter
to scan for and no half-a-message to hold onto. `vim.uv` provides the socket,
and the frames are packed by hand because Neovim's LuaJIT has no
`string.pack`.

## Tests

```sh
nvim -l tests/protocol_spec.lua   # mode normalization
nvim -l tests/api_spec.lua        # config validation and the statusline API
node tests/loop-guard.js nvim     # the loop guard, against a controlled server
node tests/resync.js nvim         # the heartbeat resync
stylua --check lua plugin tests
```

None of those needs the server repository: the loop-guard and resync tests
bring their own server, a few lines of JavaScript apiece that say exactly what
each test needs said.

`tests/two-editors.sh` is the headline, and the one that needs the real thing —
it starts a server, launches two headless Neovim instances, presses `i` in one
and asserts the other ends up in insert mode. `scripts/build-server.sh` clones
and builds the server repository for it (installing GNAT if you have not got
it) and prints the binary's path:

```sh
./scripts/build-server.sh   # into .server/, which is gitignored
./tests/two-editors.sh      # finds it there
```

Or point it at a build you already have:

```sh
./tests/two-editors.sh /path/to/main.exe
GLOBAL_MODE_SERVER=/path/to/main.exe ./tests/two-editors.sh
```

But it is not sufficient on its own, and says so in its own comments: a real
editor walking `i`→`v` steps its peers through normal, so the loop guard's
transit rule is unreachable from it. `tests/loop-guard.js` pushes modes
directly, which is what the `welcome` path and a backlogged client do, and is
the only thing covering that rule.

To watch traffic while driving real editors by hand, the server repository has
`scripts/fake-client.js`:

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
