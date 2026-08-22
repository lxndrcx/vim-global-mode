#!/usr/bin/env python3
"""Regression test for the loop guard, driven by a controlled server.

Every entry in the plugin's key table begins with CTRL-\\ CTRL-N, so forcing a
non-normal mode onto an editor that is in some *other* non-normal mode passes
through normal on the way and fires an extra ModeChanged. If the guard treats
that transit as a genuine local change, the editor broadcasts a bogus `n` --
yanking every other editor to normal -- and then re-broadcasts the very mode it
was just told to enter.

tests/two-editors.sh cannot reach this case: a direct push is what triggers it,
which is what the `welcome` path does for a late joiner. Deleting the transit
rule leaves every check in two-editors.sh green; only this file fails.

Usage: python3 tests/loop_guard.py <path-to-nvim> [port]
"""

from __future__ import annotations

import sys
import threading
import time
from dataclasses import dataclass

import frames
from frames import Frame, T
from harness import Checker, Editor, FakeServer

NVIM: str = sys.argv[1] if len(sys.argv) > 1 else "nvim"
PORT: int = int(sys.argv[2]) if len(sys.argv) > 2 else 41099


@dataclass
class Report:
    mode: str
    seq: int


# What the editor has told us.
received: list[str] = []

# The same reports, with their counters. Kept separate so the mode-only
# assertions stay readable.
reports: list[Report] = []

# The state last pushed, re-sent periodically. The real server refreshes every
# couple of seconds and the client treats silence as death, so a fake server
# that only speaks when spoken to would be declared dead mid-test.
current_mode: str = "n"
current_seq: int = 0


def on_frame(f: Frame) -> None:
    if f.kind == "HELLO":
        # Any token at all: this stands in for the real server, and what is
        # being tested is that the client echoes back whatever it is handed.
        server.send(frames.encode(type=T.CHALLENGE, token=0x0123456789ABCDEF))
    elif f.kind == "JOIN":
        server.send(
            frames.encode(
                type=T.WELCOME,
                id=1,
                mode=current_mode,
                seq=current_seq,
                user="server",
            )
        )
    elif f.kind == "SET_MODE":
        received.append(f.mode)
        reports.append(Report(mode=f.mode, seq=f.payload))


server: FakeServer = FakeServer(PORT, on_frame)


def keepalive() -> None:
    while True:
        time.sleep(2)
        # Deliberately not asking for a pong. This frame exists only so the
        # client keeps hearing from us; a pong request here would be counted
        # against the heartbeats the test actually sends.
        server.send(
            frames.encode(
                type=T.STATE,
                mode=current_mode,
                seq=current_seq,
                user="bob",
                wants_pong=False,
            )
        )


def push(mode: str, seq: int) -> None:
    global current_mode, current_seq
    current_mode, current_seq = mode, seq
    server.send(frames.encode(type=T.STATE, mode=mode, seq=seq, user="bob"))


def main() -> int:
    c = Checker()
    server.start()
    threading.Thread(target=keepalive, daemon=True).start()

    editor = Editor(NVIM, PORT)
    editor.start()

    try:
        c.check("editor connected", server.peer is not None, True)

        # Put the editor into insert mode by its own hand; this SHOULD be
        # reported.
        editor.send_keys("i")
        time.sleep(0.6)
        c.check("the editor's own keypress is broadcast", received, ["i"])
        c.check("the editor is in insert mode", editor.mode(), "i")

        # Now force VISUAL directly, with no intervening normal. This is the
        # case that used to produce a spurious `n` followed by a spurious `v`.
        before = len(received)
        push("v", 2)
        time.sleep(1.5)
        c.check("the forced mode was applied", editor.mode(), "v")
        c.check("no frames were echoed back", received[before:], [])

        # And again from visual into replace, still with no intervening normal.
        before_replace = len(received)
        push("R", 3)
        time.sleep(1.5)
        c.check("a second cross-mode push applied", editor.mode(), "R")
        c.check("still nothing echoed back", received[before_replace:], [])

        # A genuine local change after all that must still be reported, proving
        # the guard cleared its expectations rather than latching shut.
        before_genuine = len(received)
        editor.send_keys("<C-\\><C-n>")
        time.sleep(0.8)
        c.check(
            "a genuine change is still broadcast afterwards",
            received[before_genuine:],
            ["n"],
        )

        # Two frames back to back. Any latency, or a busy main loop, coalesces
        # reads like this. `apply` schedules its work, so when the second frame
        # is handled the first one's keys are still in the typeahead and
        # `mode(1)` still reports the OLD mode -- so a check against the current
        # mode discarded the second frame as a no-op and left the editor in the
        # first one's mode believing it was in the second's. Nothing recovered
        # it.
        before_batch = len(received)
        push("i", 10)
        push("n", 11)
        time.sleep(2)
        c.check("a coalesced batch lands on its LAST mode", editor.mode(), "n")
        c.check(
            "and the editor agrees with the server about it",
            editor.global_mode(),
            "n",
        )
        c.check("the batch was not echoed back", received[before_batch:], [])

        # The reverse ordering too: ending on a non-normal mode.
        before_batch2 = len(received)
        push("n", 12)
        push("v", 13)
        time.sleep(2)
        c.check(
            "a coalesced batch ending in visual lands there", editor.mode(), "v"
        )
        c.check("still nothing echoed", received[before_batch2:], [])

        # A burst of mode changes is one report, not one per mode passed
        # through. Every entry in the key table starts with CTRL-\ CTRL-N, so
        # this walks normal on the way to visual and fires two ModeChanged
        # events a millisecond apart. Sending both would put two datagrams back
        # to back on the wire, and those are the two most likely to be
        # reordered -- which is the whole reason for coalescing them.
        before_burst = len(reports)
        editor.send_keys("<C-\\><C-n>v")
        time.sleep(0.8)
        burst = reports[before_burst:]
        c.check("a burst of changes is reported once", len(burst), 1)
        c.check(
            "and reports the mode it ended on",
            burst[0].mode if burst else None,
            "v",
        )

        # Every report carries a strictly greater counter than the last, which
        # is what lets the server discard one that overtook a newer one in
        # flight.
        seqs = [r.seq for r in reports]
        c.check(
            "report counters strictly increase",
            all(b > a for a, b in zip(seqs, seqs[1:])),
            True,
        )
        c.check("and start above zero", seqs[0] > 0 if seqs else False, True)
    finally:
        editor.close()
        server.stop()

    return c.report()


if __name__ == "__main__":
    sys.exit(main())
