# Handover: the Neovim plugin

Everything below was built, run and measured — not remembered. Where something
is unverified it says so.

## The project

A joke Neovim plugin: every connected editor shares **one global mode**. Press `i`
and everyone on the server is in insert mode.

This repository is the plugin half — pure Lua (`lua/`, `plugin/`), no build step,
no companion binary. The server is
[lxndrcx/vim-global-mode-server-moonbit](https://github.com/lxndrcx/vim-global-mode-server-moonbit)
(MoonBit, native, with a live WebSocket dashboard), and the two were split apart
from a single repository; commits before the split are in both histories.

The wire format is the contract between them: `lua/global-mode/protocol.lua` on
this side, `protocol/protocol.mbt` on that one. A change to either has to land
in both, and `tests/two-editors.sh` is what notices when it does not.

- Branch: `claude/neovim-global-mode-plugin-hnn95k` (the repository's default)
- Draft PR: https://github.com/lxndrcx/vim-global-mode/pull/1 (base `main`)

## The session hook

`nvim` and `stylua` land via `.claude/hooks/session-start-binaries.sh`, which
runs **asynchronously** — the session does not wait for it. **So a session can
start before `nvim` exists.** If an `nvim` or `stylua` command fails with
"command not found" in the first half-minute of a cold session, that is this
race, not a broken install: wait and retry. Check
`~/.cache/global-mode-binaries.status` if in doubt — a partial install is
otherwise indistinguishable from a complete one. Run it by hand with:

    CLAUDE_CODE_REMOTE=true ./.claude/hooks/session-start-binaries.sh

It does **not** install MoonBit. Nothing here needs it except
`tests/two-editors.sh`, and `scripts/build-server.sh` installs it on demand for
exactly that.

## Building and testing

```sh
nvim -l tests/protocol_spec.lua   # 45 checks, mode normalization
nvim -l tests/api_spec.lua        # 39 checks, config + statusline API
node tests/loop-guard.js nvim     # the loop guard, vs a controlled server
node tests/resync.js nvim         # the heartbeat resync
stylua --check lua plugin tests
```

Those four need only Neovim and Node — the loop-guard and resync tests bring
their own JavaScript server, deliberately, so each can say exactly what its case
needs said and neither depends on the other repository.

`tests/two-editors.sh` is the one that matters — two real headless Neovim
instances over RPC — and it needs a real server:

```sh
./scripts/build-server.sh   # clone + build into .server/, prints the path
./tests/two-editors.sh      # finds the binary there on its own
```

It also takes an explicit path, reads `$GLOBAL_MODE_SERVER`, and falls back to a
sibling `../vim-global-mode-server-moonbit` checkout. CI does the same thing the
long way round: a second `actions/checkout` into `.server/`, then a MoonBit build.

## Two things the client does that look like bugs

**The loop guard is fussier than it sounds.** Every applied mode is fed as
`CTRL-\ CTRL-N` followed by a mode key, so applying one from a *different*
non-normal mode passes through normal and fires **two** `ModeChanged` events, not
one — and two remote frames can be in flight before either one's keys land. So
the client tracks a queue of modes it is expecting, treats a transit through
normal as its own, and expires an entry after half a second in case the keys
never take effect at all. Deleting any part of that produces an echo storm, and
`tests/two-editors.sh` **cannot** catch it: a real editor walking `i`→`v` steps
its peers through normal, so the transit rule is unreachable from there.
`tests/loop-guard.js` is the only thing covering it. Do not consolidate the two.

**Operator-pending is dropped** before anything is scheduled
(`lua/global-mode/protocol.lua`). A `ModeChanged` autocmd calling `vim.schedule`
could once loop to 100% CPU ([neovim#22263](https://github.com/neovim/neovim/issues/22263))
and this plugin is exactly that shape. `tests/two-editors.sh` has a regression
check. Do not remove it.

## Review state — all six are done

Six adversarial reviews were planned and all six ran, one at a time, with every
finding verified against the code before any fix and a regression test added
wherever one could be. **Do not redo these.** Reviews 1, 3 and 4 were largely
about the server, and its handover carries that half.

| Review | Outcome |
| --- | --- |
| 1 MoonBit concurrency | server-side; see the server repository |
| 2 Lua handle lifecycle | the loop guard was defeated whenever anyone was in a non-normal mode; a startup hang from `vim.version` in a fast context |
| 3 Protocol / distributed | no storms, but several routes to permanent disagreement; fixed by making the heartbeat carry the authoritative mode |
| 4 Security / DoS | server-side, except that the client must tolerate a hang-up at any point |
| 5 Test validity | by mutation: several shipped fixes were deletable with every suite green |
| 6 Documentation | this file included |

## One thing that is deliberate, not a bug

**No authentication.** Anyone who can reach the port changes everyone's mode.
Documented in the README as not for the public internet. Note it; do not "fix" it.
