#!/usr/bin/env python3
"""Regression test for heartbeat resync.

An editor can drift out of step with the server in several ways that nothing
else corrects: a frame discarded from a full outbox, two editors changing mode
at the same instant so the winner never learns its own `seq`, an apply dropped
by the circuit breaker. Each of those used to be permanent, because the protocol
had no resync at all -- the server only ever announced *changes*, so a client
that missed one stayed wrong forever.

The heartbeat now carries the authoritative mode. This drives a real Neovim into
a state that disagrees with the server and asserts the next beat fixes it,
without the client echoing anything back.

Usage: python3 tests/resync.py <path-to-nvim> [port]
"""

from __future__ import annotations

import sys
import threading
import time

import frames
from frames import Frame, T
from harness import Checker, Editor, FakeServer

NVIM: str = sys.argv[1] if len(sys.argv) > 1 else "nvim"
PORT: int = int(sys.argv[2]) if len(sys.argv) > 2 else 41098

received: list[str] = []
pongs: int = 0
pings_sent: int = 0

# The state last pushed, re-sent periodically. The real server refreshes every
# couple of seconds and the client treats silence as death, so a fake server
# that only speaks when spoken to would be declared dead mid-test.
current_mode: str = "n"
current_seq: int = 0


def on_frame(f: Frame) -> None:
    global pongs
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
    elif f.kind == "PONG":
        pongs += 1


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


def ping(mode: str, seq: int) -> None:
    global current_mode, current_seq, pings_sent
    pings_sent += 1
    current_mode, current_seq = mode, seq
    server.send(
        frames.encode(
            type=T.STATE, mode=mode, seq=seq, user="bob", wants_pong=True
        )
    )


def main() -> int:
    c = Checker()
    server.start()
    threading.Thread(target=keepalive, daemon=True).start()

    editor = Editor(NVIM, PORT)
    editor.start()

    try:
        c.check("editor connected", server.peer is not None, True)

        # Drive the editor into insert. The server drops the change on the
        # floor, so the two now disagree: editor INSERT, server still NORMAL.
        editor.send_keys("i")
        time.sleep(0.6)
        c.check("the editor is in insert", editor.mode(), "i")
        c.check("the change was sent", received, ["i"])

        # A heartbeat carrying the authoritative state must pull it back.
        before = len(received)
        ping("n", 4)
        time.sleep(1.5)
        c.check("the heartbeat corrected the editor", editor.mode(), "n")
        c.check("and it agrees on the global mode", editor.global_mode(), "n")
        c.check("the correction was not echoed back", received[before:], [])

        # A heartbeat that agrees with the editor must do nothing at all.
        quiet = len(received)
        ping("n", 5)
        time.sleep(1.2)
        c.check("an in-step heartbeat changes nothing", editor.mode(), "n")
        c.check("and sends nothing", received[quiet:], [])

        # A heartbeat can also push the editor into a mode nobody asked for.
        ping("R", 6)
        time.sleep(1.5)
        c.check("a heartbeat can install a new mode", editor.mode(), "R")

        # A stale heartbeat must be ignored rather than dragging it back.
        ping("i", 2)
        time.sleep(1.2)
        c.check("a stale heartbeat is ignored", editor.mode(), "R")

        # Every heartbeat must be answered. The server reaps a client after two
        # unanswered pings, and an idle editor -- nobody typing, which is the
        # normal state -- sends nothing else, so a missing pong means every
        # quiet editor is dropped roughly every fifteen seconds.
        c.check("every heartbeat was answered", pongs, pings_sent)
    finally:
        editor.close()
        server.stop()

    return c.report()


if __name__ == "__main__":
    sys.exit(main())
