"""Scaffolding shared by the fake servers in this directory.

Each of these tests is a controlled server driving one real headless Neovim.
What differs between them is the server's *behaviour* -- when it challenges,
when it refuses, what it pushes and when -- and that stays in each test. What
does not differ is spawning the editor, talking to it over its RPC socket, and
counting checks, which the JavaScript versions each carried their own copy of.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from collections.abc import Callable
from pathlib import Path

from frames import Frame, decode

REPO: Path = Path(__file__).resolve().parent.parent


class Checker:
    """Counts checks and prints them in the shape the shell tests use."""

    def __init__(self) -> None:
        self.failures: int = 0

    def check(self, label: str, actual: object, expected: object) -> None:
        ok = actual == expected
        if not ok:
            self.failures += 1
        print(f"{'ok  ' if ok else 'FAIL'} {label}")
        if not ok:
            print(f"       expected {expected!r}, got {actual!r}")

    def report(self) -> int:
        print(
            "\nall checks passed"
            if self.failures == 0
            else f"\n{self.failures} check(s) failed"
        )
        return 1 if self.failures else 0


class Editor:
    """One headless Neovim, configured to talk to a server on `port`."""

    def __init__(self, nvim: str, port: int, *, notify: bool = False) -> None:
        self.nvim: str = nvim
        self.work: Path = Path(tempfile.mkdtemp(prefix="global-mode-"))
        self.sock: Path = self.work / "nvim.sock"
        (self.work / "init.lua").write_text(
            f'vim.opt.runtimepath:prepend("{REPO}")\n'
            f'require("global-mode").setup({{ host = "127.0.0.1", '
            f'port = {port}, user = "probe", '
            f"notify = {'true' if notify else 'false'} }})\n"
        )
        self.proc: subprocess.Popen[bytes] | None = None

    def start(self) -> None:
        self.proc = subprocess.Popen(
            [
                self.nvim,
                "--headless",
                "--listen",
                str(self.sock),
                "-u",
                str(self.work / "init.lua"),
                "-n",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        for _ in range(50):
            if self.sock.exists():
                break
            time.sleep(0.1)
        time.sleep(1.2)

    def rpc(self, *args: str) -> str:
        try:
            out = subprocess.run(
                [self.nvim, "--server", str(self.sock), *args],
                capture_output=True,
                timeout=10,
            )
            return out.stdout.decode("utf-8", "replace").strip()
        except (subprocess.SubprocessError, OSError):
            return ""

    def send_keys(self, keys: str) -> None:
        _ = self.rpc("--remote-send", keys)

    def expr(self, expression: str) -> str:
        return self.rpc("--remote-expr", expression)

    def mode(self) -> str:
        return self.expr("mode(1)")

    def lua(self, chunk: str) -> str:
        return self.expr(f'luaeval("{chunk}")')

    def global_mode(self) -> str:
        return self.lua("require('global-mode').mode()")

    def state(self, field: str) -> str:
        return self.lua(f"require('global-mode.client').state.{field}")

    def close(self) -> None:
        if self.proc is not None:
            self.proc.kill()
            _ = self.proc.wait(timeout=10)
        shutil.rmtree(self.work, ignore_errors=True)


class FakeServer:
    """A UDP socket standing in for the real server.

    `on_frame` is the scenario: it decides what to answer and when. The socket,
    the reader thread and remembering where the editor is are the same
    everywhere, so they live here.
    """

    def __init__(self, port: int, on_frame: Callable[[Frame], None]) -> None:
        self.port: int = port
        self.on_frame: Callable[[Frame], None] = on_frame
        # UDP has no connection, so "peer" means nothing more than having heard
        # from the editor.
        self.peer: tuple[str, int] | None = None
        self.socket: socket.socket | None = None
        self._stop: threading.Event = threading.Event()

    def start(self) -> None:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0.2)
        s.bind(("127.0.0.1", self.port))
        self.socket = s
        self._stop.clear()
        threading.Thread(target=self._read_loop, daemon=True).start()

    def _read_loop(self) -> None:
        while not self._stop.is_set():
            s = self.socket
            if s is None:
                return
            try:
                # recvfrom is typed tuple[bytes, Any]; the shape is declared so
                # the address does not arrive as Any.
                packet: tuple[bytes, tuple[str, int]] = s.recvfrom(2048)
            except (TimeoutError, OSError):
                continue
            data, addr = packet
            self.peer = addr
            f = decode(data)
            if f is not None:
                self.on_frame(f)

    def send(self, payload: bytes) -> None:
        s = self.socket
        if s is not None and self.peer is not None:
            _ = s.sendto(payload, self.peer)

    def stop(self) -> None:
        self._stop.set()
        s = self.socket
        self.socket = None
        self.peer = None
        if s is not None:
            s.close()
        # Let the reader notice before the port is reused.
        time.sleep(0.3)


def free_port(default: int) -> int:
    return int(os.environ.get("GLOBAL_MODE_TEST_PORT", default))
