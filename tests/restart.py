#!/usr/bin/env python3
"""Regression test for the ways a client can be talked out of listening to its
own server.

They share one root: `M.state.seq` is a high-water mark, and anything that
raises it above what the real server can produce silences that server
permanently. The client keeps saying "online" the whole time, which is what
makes it so unpleasant -- no error, no reconnect, just an editor that has
quietly stopped following anybody.

  1. A server restart. Seq counts from zero again, so every frame the new
     instance sends is below the mark left by the old one.
  2. A forged frame from any other socket. Nothing checked the source address.
  3. A stale refresh at an equal seq, adopting "at least as new".
  4. A remote change inside the debounce window, whose superseded local report
     was then sent with a fresh and therefore higher counter.
  5. Coming back online on a refresh alone, with no handshake, so the client's
     counter reset while the server's did not.

None are reachable from tests/two-editors.sh: they need a server that restarts,
a second sender, or a frame held back by hand.

Usage: python3 tests/restart.py <path-to-nvim> [port]
"""

from __future__ import annotations

import socket
import sys
import threading
import time

import frames
from frames import Frame, T
from harness import Checker, Editor, FakeServer

NVIM: str = sys.argv[1] if len(sys.argv) > 1 else "nvim"
PORT: int = int(sys.argv[2]) if len(sys.argv) > 2 else 41097

current_mode: str = "n"
current_seq: int = 0

refuse_handshake: bool = False
race_mode: str | None = None
reports: list[str] = []
hellos: list[float] = []


def on_frame(f: Frame) -> None:
    if f.kind == "HELLO":
        hellos.append(time.monotonic())
        if refuse_handshake:
            return
        server.send(frames.encode(type=T.CHALLENGE, token=0x0123456789ABCDEF))
    elif f.kind == "SET_MODE":
        reports.append(f.mode)
    elif f.kind == "GET_ROSTER":
        # Used only to get a frame to the client at a known instant: it asks
        # for a roster and changes its mode in the same breath, so this reply
        # lands inside the client's 20ms debounce window.
        if race_mode is not None:
            push(race_mode, current_seq + 1)
    elif f.kind == "JOIN":
        if refuse_handshake:
            return
        server.send(
            frames.encode(
                type=T.WELCOME,
                id=1,
                mode=current_mode,
                seq=current_seq,
                user="server",
            )
        )


server: FakeServer = FakeServer(PORT, on_frame)


def keepalive() -> None:
    while True:
        time.sleep(1)
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
    global race_mode, refuse_handshake, current_mode, current_seq
    c = Checker()
    server.start()
    threading.Thread(target=keepalive, daemon=True).start()

    editor = Editor(NVIM, PORT, notify=True)
    editor.start()

    try:
        c.check("editor connected", server.peer is not None, True)

        # Run a while, so the client carries a high-water mark worth wedging on.
        push("i", 1000)
        time.sleep(0.8)
        c.check("the editor follows a long-running server", editor.global_mode(), "i")
        c.check("and holds its counter", editor.state("seq"), "1000")

        # ---- 0. A remote change inside the debounce window ----
        #
        # The client holds a mode report for 20ms to coalesce bursts. If a
        # remote change lands inside that window the held report is stale --
        # and it used to be sent anyway, with a fresh and therefore *higher*
        # counter, so the server honoured it precisely because it looked newest
        # and dragged everybody back to the mode this editor had just been told
        # to leave. The counter that exists to make reports orderable made the
        # wrong one win.
        #
        # Racing this from outside would be hopeless, so the client triggers
        # it: one expression asks for a roster and changes mode, and the reply
        # to the roster arrives a millisecond later, inside the window. The
        # mode must differ from the one the editor is already in, or send_mode
        # returns early and nothing is ever pending.
        race_mode = "v"
        before_race = len(reports)
        _ = editor.lua(
            "(function() local c = require('global-mode.client') "
            "c.request_roster() c.send_mode('R') return 1 end)()"
        )
        time.sleep(1.5)
        race_mode = None

        c.check("the remote change wins the race", editor.global_mode(), "v")
        c.check(
            "the superseded local report is never sent",
            "R" in reports[before_race:],
            False,
        )

        # ---- 1. The restart ----
        server.stop()
        # Longer than LIVENESS_MS, so the client gives up and re-handshakes.
        time.sleep(8)
        c.check("silence takes the editor offline", editor.global_mode(), "vim.NIL")

        current_mode, current_seq = "n", 0
        server.start()
        time.sleep(3)

        c.check("a restarted server is followed again", editor.global_mode(), "n")
        c.check("and the stale high-water mark is gone", editor.state("seq"), "0")

        # A mode change from the restarted instance must land, at a seq far
        # below the one the client used to hold.
        push("v", 1)
        time.sleep(0.8)
        c.check("its first real change is applied", editor.mode(), "v")

        # ---- 2. The forged frame ----
        spoofer = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        peer = server.peer
        if peer is not None:
            _ = spoofer.sendto(
                frames.encode(
                    type=T.STATE, mode="R", seq=2**60, user="mallory"
                ),
                peer,
            )
        time.sleep(0.8)
        c.check("a frame from another socket is ignored", editor.global_mode(), "v")
        c.check("and cannot poison the counter", editor.state("seq"), "1")
        spoofer.close()

        # The real server still owns the editor afterwards.
        push("i", 2)
        time.sleep(0.8)
        c.check("the real server is still in charge", editor.global_mode(), "i")

        # ---- 3. The stale equal-seq refresh ----
        # Re-send the mode the editor was in *before* the last change, at the
        # seq the client already holds -- an in-flight refresh that crossed
        # with a local change. It must not drag the editor backwards.
        server.send(frames.encode(type=T.STATE, mode="v", seq=2, user="bob"))
        time.sleep(0.8)
        c.check("an equal-seq stale refresh is ignored", editor.global_mode(), "i")

        # ---- 4. Back online without a handshake ----
        #
        # The client resets its report counter when it goes offline, matching
        # the server forgetting its side -- but the server only forgets on a
        # Join. A client that came back "online" on the strength of a refresh
        # alone, its Hello having been lost, would count from 1 again against a
        # seat whose high-water mark was still high, and every report from then
        # on would be discarded as stale. It answers pongs, so it is never
        # expired; it never sends another Hello, so nothing repairs it. Online,
        # healthy-looking and mute.
        server.stop()
        time.sleep(8)
        refuse_handshake = True
        server.start()
        hellos.clear()

        # Bare refreshes and nothing else -- the handshake is refused.
        for i in range(6):
            push("n", 5000 + i)
            time.sleep(0.4)
        c.check(
            "a refresh alone does not put us back online",
            editor.state("status"),
            "connecting",
        )
        c.check("and the handshake keeps being retried", len(hellos) > 0, True)
        refuse_handshake = False

        # ---- The fast-context notify ----
        # Going offline notifies from a timer callback, where nvim_echo is
        # forbidden. It used to raise E5560 and abandon the rest of the tick.
        errs = editor.expr('execute("messages")')
        c.check("losing the server raised no E5560", "E5560" in errs, False)
    finally:
        editor.close()
        server.stop()

    return c.report()


if __name__ == "__main__":
    sys.exit(main())
