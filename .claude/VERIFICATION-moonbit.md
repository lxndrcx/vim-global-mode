# MoonBit formal verification, assessed against this server

Closes task #12 from `.claude/HANDOVER-moonbit.md`: *explore MoonBit's built-in formal
verification and assess whether it can be applied to the server.*

Everything below was built, run and measured on 2026-08-19, not remembered. Where
something is unverified it says so.

**Verdict: the toolchain works and none of the four properties we wanted is reachable.**
Not because the solver is weak — because MoonBit's verification language has no strings.
The recommendation is to keep the one-lemma canary that is now in the tree, add nothing to
CI, and revisit when the language grows a string theory.

## Versions

    moon    0.1.20260819 (fc2a4ee 2026-08-19)
    moonc   v0.10.9+6e6c44045 (2026-08-19)
    feature flags: rr_moon_mod,rr_moon_pkg
    Z3 4.8.12 (apt), cvc5 1.1.2 (apt)     -- installed by the binaries hook

## How a package opts in

This was the open question the previous session left, and it cost most of the time here.

    options(
      "proof-enabled": true,
    )

in the package's `moon.pkg`. Two things made it hard to find. The manifest parser rejects
unknown keys outright — `proof_enabled`, `proof-enabled`, `proof`, `enable_proof` and
`verify` as bare top-level keys all fail with `Unexpected key ... found in moon.pkg` — and
the JSON manifest struct really does carry a `proof_enabled` field, so the name was never
wrong, only the *syntax*. The `rr_moon_pkg` format routes it through `options(...)`, the
same call the repo already uses for `options("native-stub": [ "flush.c" ])`.

Adding a `.mbtp` file alone does **not** enable proving. Neither does anything in
`moon.mod`.

Until the key is present, `moon prove <pkg>` exits 0 having done nothing, printing only:

    Warning: Package `...` selected by `protocol` is not proof-enabled; skipping `moon prove` for it.

That is the trap worth knowing: **success and silence look identical.** Check for
`goals proved`, never for exit status.

`moon fmt` has an opinion about the key's layout — it rewrites the one-line form to the
expanded one above, and `moon fmt --check` is CI's first step, so write it expanded.

## What actually proved

`server/protocol/` is proof-enabled and `server/protocol/protocol.mbtp` carries one lemma:

    lemma seq_step_is_positive(seq : Int) where {
      proof_require: seq >= 0,
      proof_ensure: seq + 1 >= 1,
      proof_reasoning: "Adding one to a non-negative integer yields a positive one.",
    } {}

    $ moon prove protocol
    lxndrcx/global-mode-server/protocol
      Succeeded: 1 goals proved

Report at `_build/verif/protocol/protocol.proof.json`:
`{"result":"success","summary":{"valid":1,"invalid":0,"timeout":0,...}}`.

This is a canary, not a theorem anyone needed. It is in the tree so a future session can
tell "the pipeline is wired up" from "the pipeline silently did nothing".

## Where the boundary is

Probed by experiment, one construct at a time. **Arithmetic and algebraic data types work.
Strings do not.**

Enums are fine. A `#proof_pure` function matching all eight `Mode` constructors and
returning `Int`, with a lemma over its result, proves without complaint.

Strings fail in three separate places, each with its own diagnostic:

| Construct | Result |
| --- | --- |
| A string literal in a logic body | `E4207: only Bool, Byte, Int, UInt, Int64, and UInt64 constants are supported in logic body` |
| String patterns in a `#proof_pure` body | `E4207: unsupported pattern in pure function body` — fires on *every* arm of `of_wire` |
| `Mode::of_wire("x") == None` | `E4207: unsupported expression in logic body` — `Option` comparison is out too |
| `Mode::of_wire("x") is None` | Parse error `E3002: unexpected id (lowercase start)` — `is` patterns are not proof syntax |

Two incidental syntax notes: `proof_reasoning` takes a string literal but **escaped quotes
inside it fail to parse**, and quantifiers are written `∀` / `→`.

## The four properties

The handover's table, with what each would actually cost.

| # | Property | Outcome |
| --- | --- | --- |
| 1 | `of_wire`/`to_wire` round trip | **Blocked, decisively.** Both functions are keyed on string literals, which the logic body cannot represent. Not a solver limit — the language cannot state the theorem. Would need a trusted `#proof_import` over Why3's string theory: a bridge larger and less trustworthy than the 26 lines it would verify. The enum half is provable today; had the wire tags been `Byte` or `Int`, this property would prove. |
| 2 | `seq` advances by exactly one | **Not expressible.** The contract vocabulary is `proof_require`, `proof_ensure`, `proof_decrease`, `proof_axiomatized`, `proof_reasoning` (functions) and `proof_invariant`, `proof_yield`, `proof_reasoning` (loops). **There is no `old()`** — nothing names a pre-state, and this property relates the pre- and post-state of `self.seq`. Could be recast as a pure helper `next_seq(current, changed)`, but the theorem would then be about the helper, and `state_test.mbt` already covers that `set_mode` calls it right. |
| 3 | Originator never in the broadcast set | **Possible, but ~90% axiom.** Needs a ghost set (`#proof_external("set.Fset")` plus `#proof_import`s for `mem`/`add`/`empty`), an axiom that `send` adds `peer.id` to it, and a characterisation of `for id, peer in self.clients` over `Map`. Those three trusted bridges carry the operational content; the solver would check only the loop invariant. The existing test is a stronger instrument. |
| 4 | Outbox depth stays bounded | **Would be theatre.** The bound lives inside `@aqueue.Queue(kind=DiscardOldest(64))` — a dependency type with no annotations whose depth `state` never observes. Proving it means first axiomatising that a `DiscardOldest(n)` queue never exceeds `n`, which *is* the property. Decisively: the real bug here was that **`try_put` does not honour `DiscardOldest`**, found by experiment. A `state`-side axiom encoding that wrong belief would have been proved happily while the server stranded slow clients on stale modes. Verification of `state` is structurally incapable of catching that class of bug. |

`state` was never proof-enabled — properties 2–4 are blocked ahead of any solver work, and
enabling it would only have added risk. `editors`, `web` and `cmd/main` are async I/O and
out of scope.

## The two preludes

`MOON_PROVE_PRELUDE_OVERRIDE` points at a directory containing
`moonbit_builtin_prelude.mlw`; the toolchain ships two. Delete `_build/verif` between runs
or the cached session replays the previous result.

The canary lemma is the experiment, because it is *true* over ℤ and *false* over `Int`:

| Prelude | Result |
| --- | --- |
| `~/.moon/lib/prelude_proof` (math ints) | 1 goal proved |
| `~/.moon/lib/prelude_proof_machine_int` | 0 proved, **1 timeout** |

`seq >= 0` does not imply `seq + 1 >= 1` when `seq` is 32-bit — at `Int::max_value` it
wraps negative, and the machine-int prelude correctly refuses to prove it.

**Math ints are the default.** A bare `moon prove` erases overflow entirely, so any
arithmetic result obtained without the override is "modulo overflow" and should be labelled
that way wherever it is quoted.

This is a statement about the tooling, not about this server: `Hub::seq` is already `Int64`,
widened during the review programme.

## Recommendation

**Do not adopt verification for this server yet.** The one property whose proof would have
been worth having — the wire round trip — is exactly the one the language cannot express,
and the other three are either unstateable or would be carried by axioms we would have
written ourselves from the same beliefs the tests already check. The adversarial review
programme found 13 real bugs by experiment; none of them was of a shape this tool would
have caught.

Kept in the tree, deliberately small: the `proof-enabled` key and the one canary lemma.
`moon prove protocol` is a working command, and the day the language grows strings, the
scaffolding to try again is already there.

Not added: any CI step. CI does not prove, and there is nothing here worth gating on. A
`moon prove` step would also need the solvers installed on the runner, which the workflow
does not do.

**What would change this verdict:**

- a `String` theory in the proof prelude — this is the whole blocker for property 1;
- an `old()`-style pre-state form in the contract vocabulary — unblocks property 2;
- `moonbitlang/core` shipping proof annotations, or `@fset`/`@fmap` shims, so set and map
  reasoning stops being hand-written trusted bridges — property 3;
- `moonbitlang/async` annotating `aqueue` — the only thing that would make property 4
  anything other than an axiom restating itself.
