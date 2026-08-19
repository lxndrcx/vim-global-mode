# Handover: MoonBit work on vim-global-mode

Written for a **fresh session** that has the `moonbit-skills@moonbit-code-plugins`
plugin loaded. The session that built this project registered that marketplace in
`.claude/settings.json` but could not use it: Claude Code's settings watcher only
watches directories that already had a settings file at session start, and
`.claude/` had none. So the config is correct on disk and inert in that session,
and a subagent spawned there would have inherited the same empty skill set.

**Update — that is handled now, by the hooks in `.claude/hooks/`.** The
watcher problem is gone (`.claude/settings.json` exists at session start), but a
second one replaced it: declaring a plugin in settings does not make a remote
container *fetch* it. A later session started with the marketplace declared and
`installed_plugins.json` still empty, and with no MoonBit toolchain at all --
`moon` is not preinstalled in these containers, so the `0.1.20260814` /
`v0.10.8` versions quoted below were a property of one container, not of the
project. The hooks install everything the repo needs and are no-ops once it is
all present.

`moon`, `nvim`, `stylua`, `z3` and `cvc5` land via `session-start-binaries.sh`,
which runs
asynchronously -- a cold container measured 34s, and the session does not wait
for it. **So a session can start before `moon` exists.** If a `moon`, `nvim` or
`stylua` command fails with "command not found" in the first half-minute of a
cold session, that is this race, not a broken install: wait and retry.
`session-start-skills.sh` is synchronous by contrast (5s cold), because skills
are read at session start to decide what the session knows. Run either by hand:

    CLAUDE_CODE_REMOTE=true ./.claude/hooks/session-start-binaries.sh
    CLAUDE_CODE_REMOTE=true ./.claude/hooks/session-start-skills.sh

Skills load from the plugin cache, from `.claude/skills/`, and from
`~/.claude/skills/`. Nothing is vendored into this repo, deliberately. Cost is
half the reason -- the nine skills are ~1,187 tokens always-on, and
`moonbit-agent-guide` alone is ~23.1k on invoke. Licensing is the other half:
`moonbitlang/skills` has no root LICENSE and licenses each skill separately, so
only `moonbit-agent-guide` (Apache-2.0) and `moonbit-refactoring` (MIT) state
one. Six more are mirrored per `skills.sources.json` and inherit whatever their
upstream repo says -- `moonbit-proof` among them, from
`moonbitlang/moonbit-agent-guide`, so Apache-2.0 by inference rather than by
statement. `moonbit-orientation`, `moonbit-extract-spec-test` and
`make-moonbit-c-bindings` are native to that repo and state nothing at all.

None of this touches what is committed here, which is only the marketplace
name and plugin id (in `.claude/hooks/session-start-skills.sh`) and two download
URLs (in `session-start-binaries.sh`) -- `.claude/settings.json` itself now
carries only the hook wiring, with `enabledPlugins` and `extraKnownMarketplaces`
both empty. It matters if a later session
decides to vendor: `moonbit-agent-guide` and `moonbit-refactoring` are the two
that can be copied in with their LICENSE files and no inference. Skills whose
license has to be inferred are worth leaving on the install path.

Everything below is verified — built, run, and measured — not remembered. Where
something is unverified it says so.

## The project

A joke Neovim plugin: every connected editor shares **one global mode**. Press `i`
and everyone on the server is in insert mode. Pure-Lua plugin (`lua/`, `plugin/`),
MoonBit server (`server/`), live WebSocket dashboard.

- Branch: `claude/neovim-global-mode-plugin-hnn95k`
- Draft PR: https://github.com/lxndrcx/vim-global-mode/pull/1 (base `main`)
- CI: green at time of writing

## The task this handover exists for — done

**Explore MoonBit's built-in formal verification and assess whether it can be
applied to the server.** It was task #12 in the originating session, deliberately
sequenced last so it starts from code whose invariants have already survived
adversarial review rather than code that merely compiles.

**It is finished. The answer is in `.claude/VERIFICATION-moonbit.md`.** In short:
the toolchain works, the opt-in key is `options("proof-enabled": true)` in
`moon.pkg`, and none of the four properties below is reachable — MoonBit's
verification language has no strings, and no `old()`, so the wire round trip
cannot be stated and neither can the `seq` step. One canary lemma is proof-enabled
in `protocol/` so a future session can tell a working pipeline from a silent one.
The rest of this file is kept for the MoonBit facts it records, which are still
accurate and still expensive to rediscover.

### Step one: find out what actually exists

Do not assume the feature exists or behaves as you remember. Check `moon --help`, the
official docs, the `moonbitlang/core` source, and — this is why this file exists —
whatever the MoonBit skills say. A negative result is a perfectly good outcome:
if verification is absent, immature, or a poor fit for code dominated by async
I/O, say so plainly rather than contorting the server to suit a tool.

**Partial answer, from setting up the solver.** The feature exists and is not
hypothetical: `moon prove` is a real subcommand ("Prove the current package"),
it is Why3-backed -- `--why3-config` overrides the generated default, and
`MOON_PROVE_PRELUDE_OVERRIDE` replaces `moonbit_builtin_prelude.mlw` -- and it
dispatches to an external SMT solver. Without one it fails with:

    failed to locate any SMT solver for `moon prove`:
    searched for `alt-ergo`, `cvc5`, `z3` in PATH

Z3 and CVC5 are both installed by the binaries hook, which clears that. Two
rather than one because Why3 runs several provers over the same goals -- the
generated config carries a `[partial_prover]` strategy and
`running_provers_max = 16` -- so a goal one solver cannot close often falls to
another. Alt-Ergo, the third `moon prove` accepts, is not installed: it is not
in apt and would mean an opam/OCaml build. Add it if the two SMT solvers leave
goals unproved.

Their apt versions are not the drag they look. MoonBit bundles its own Why3 at
`$MOON_HOME/share/why3`, and its newest Z3 driver is `z3_487.drv`, written for
4.8.7 -- apt's 4.8.12 sits just past it, where a bleeding-edge Z3 would be
further from the shipped driver rather than closer. CVC5's driver is
version-generic and apt's 1.1.2 is recent. `moon explain
--attribute` lists `#proof_pure`, `#proof_import` and `#proof_external`, and
`#proof_pure` has real documented limits: no verification contracts, no direct
or mutual recursion. Proof output is expected at
`_build/verif/<pkg>/<pkg>.proof.json`.

How a package opts in — the question this section used to leave open — is
`options("proof-enabled": true)` in its `moon.pkg`. The bare keys `proof_enabled`,
`proof-enabled`, `proof`, `enable_proof` and `verify` are all rejected; the
`rr_moon_pkg` format routes it through `options(...)`, like the `native-stub` entry
in `logging/moon.pkg`. Note that `moon prove` on a package without the key exits 0
having proved nothing, so check its output for `goals proved` rather than its exit
status. See `.claude/VERIFICATION-moonbit.md` for the rest.

### The properties worth proving

These are exactly the invariants that adversarial review stress-tested by
experiment. Verification would complement the tests, never replace the end-to-end
proof that two real editors share a mode.

| Property | Where | Currently tested by |
| --- | --- | --- |
| `Mode::of_wire`/`to_wire` round-trip totality; nothing outside the eight-mode alphabet is ever accepted | `server/protocol/protocol.mbt` | `protocol_test.mbt` |
| `Hub::set_mode` advances `seq` by exactly one on a real change, not at all on a no-op | `server/state/state.mbt` | `state_test.mbt` |
| The originator is never a member of the broadcast set | `server/state/state.mbt` | `state_test.mbt` |
| Outbox depth stays bounded regardless of message volume | `server/state/state.mbt` | `state_test.mbt` |

The `state` package is the best target: it is the only package holding mutable
state, and it is pure logic with no I/O. `protocol` is pure too. `editors` and
`web` are async I/O and probably out of scope for verification.

## MoonBit facts established the hard way

Each of these cost real debugging time. They were checked against the vendored
source at `server/.mooncakes/moonbitlang/async/src/`, whose `.mbti` files give
exact signatures.

**Task groups.** `@async.with_task_group(group => {...})` returns when the group
*body* returns. Tasks spawned `no_wait=true` are cancelled at that point; tasks
spawned without it are waited for. `group.return_immediately(())` ends the group
*now* — using it right after spawning silently cancels everything you just
spawned, which cost an afternoon.

**Closing a socket does not wake a parked reader.** `IoHandle::close` detaches the
fd, closes it, and nulls it. A coroutine parked in `wait_read` is never resumed.
To end a connection from another task, end the task group instead. This was a real
bug: unresponsive editors were never reaped and lingered in the roster forever.

**`try_put` does not honour `DiscardOldest`.** It returns `false` when full; only
the async `put` discards. Ignoring the return value inverts the policy to
discard-*newest*, which silently strands a slow client on a stale mode. See
`send` in `state/state.mbt` for the sync workaround.

**`read_until("\n")` is unusable against untrusted input.** No length cap, and its
buffer grows by rounding up to a segment with no doubling — so it recopies
everything read so far roughly every kilobyte. Measured: 21 MiB of newline-free
input burned 100% of a core and +56 MB RSS. `editors/editors.mbt` now frames lines
itself with a bounded reader.

**Package manifests are `moon.pkg`**, not `moon.pkg.json`, in this toolchain:
`import { ... }`, `supported_targets = "+native"`, `pkgtype(kind: "executable")`,
`options("native-stub": [ "flush.c" ])`.

**No `exit` in core**, and `println` buffers — a long-running server never reaches
the flush at exit, so `--verbose` output is invisible in a pipe. Both are solved
by FFI: see `logging/flush.c` and `c_exit` in `cmd/main/main.mbt`.

**Enum constructors often need qualifying** in array literals
(`let all : Array[Mode] = [...]`), and `moon fmt` reshapes code — an exact-match
edit written against pre-format source will silently fail to apply. Re-read before
editing.

## Building and testing

```sh
# The toolchain may not be installed in a fresh container:
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
export PATH="$HOME/.moon/bin:$PATH"
moon update          # REQUIRED on a fresh install: no registry index ships with it

cd server
moon fmt --check
moon check --target native --deny-warn
moon test --target native          # 23 tests
moon build --target native
```

Full suite, from the repo root:

```sh
nvim -l tests/protocol_spec.lua           # 45 checks, mode normalization
nvim -l tests/api_spec.lua                # 39 checks, config + statusline API
node tests/loop-guard.js nvim             # the loop guard, vs a controlled server
node tests/resync.js nvim                 # the heartbeat resync
node scripts/fake-client.js --clients 3   # needs a server already running
./tests/two-editors.sh                    # starts its own server on its own port
stylua --check lua plugin tests
```

`tests/two-editors.sh` is the one that matters — two real headless Neovim
instances over RPC. Neovim is not installed in the base container; fetch the
`nvim-linux-x86_64.tar.gz` release if needed.

## Review state — all six are done

Six adversarial reviews were planned and all six ran, one at a time, with every
finding verified against the code before any fix and a regression test added
wherever one could be. **Do not redo these.**

| Review | Outcome |
| --- | --- |
| 1 MoonBit concurrency | 3 high bugs: ghost clients never reaped, the outbox discarding the wrong end, an uncapped quadratic reader burning a core |
| 2 Lua handle lifecycle | the loop guard was defeated whenever anyone was in a non-normal mode; a startup hang from `vim.version` in a fast context |
| 3 Protocol / distributed | no storms, but several routes to permanent disagreement; fixed by making the heartbeat carry the authoritative mode |
| 4 Security / DoS | one `hello` frame with an unpaired surrogate aborted the whole process; roster amplification; uncapped names |
| 5 Test validity | by mutation: several shipped fixes were deletable with every suite green |
| 6 Documentation | this file included — see below |

The one piece of that plan still outstanding is the task this handover exists
for: exploring MoonBit's built-in formal verification.

## Two things that are deliberate, not bugs

- **No authentication.** Anyone who can reach the port changes everyone's mode.
  Documented in the README as not for the public internet. Note it; do not "fix" it.
- **Operator-pending is dropped** before anything is scheduled
  (`lua/global-mode/protocol.lua`). A `ModeChanged` autocmd calling `vim.schedule`
  could once loop to 100% CPU ([neovim#22263](https://github.com/neovim/neovim/issues/22263))
  and this plugin is exactly that shape. `tests/two-editors.sh` has a regression
  check. Do not remove it.
