"""The wire format, for the fake servers in this directory.

Shared by loop_guard.py, resync.py and restart.py, which all stand in for the
real server. The authority is `Global_Mode.Wire` in the Ada repository, and
`scripts/frames.py` there is its reference encoder; this must agree with both,
byte for byte. `tests/protocol_spec.lua` checks the Lua side against the same
layout.

    0   1   type          1..6 editor->server, 16..19 server->editor
    1   1   mode          0..7
    2   1   flags         bit 0 = wants_pong
    3   1   user_len      0..32
    4   8   seq_or_token  big-endian
    12  2   id
    14  2   index         roster position
    16  2   count         roster total
    18  1   host_len      0..32
    19  1   reserved      must be zero
    20  32  user
    52  32  host

Decoding here is stricter than the server's own: an unknown frame type, an
unknown mode or an over-long name is rejected outright. That is the point --
this side is checking what the plugin puts on the wire, so it should be
unforgiving about it.

This is a deliberate second transcription of the format, not a shared module:
if it and the Ada repository's copy drift apart, that is a bug worth catching
rather than a duplication worth removing.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from enum import IntEnum
from typing import Final

FRAME_BYTES: Final[int] = 84
NAME_MAX: Final[int] = 32

_LAYOUT: Final[struct.Struct] = struct.Struct(">4BQ3H2B32s32s")


class T(IntEnum):
    """Frame types. The gap between 6 and 16 separates the two directions."""

    HELLO = 1
    JOIN = 2
    SET_MODE = 3
    PONG = 4
    GET_ROSTER = 5
    BYE = 6
    CHALLENGE = 16
    WELCOME = 17
    STATE = 18
    ROSTER_ENTRY = 19


MODES: Final[list[str]] = ["n", "i", "v", "V", "b", "R", "c", "t"]

_KIND: Final[dict[int, str]] = {int(t): t.name for t in T}


@dataclass(frozen=True)
class Frame:
    type: int
    kind: str
    mode: str
    wants_pong: bool
    payload: int
    id: int
    index: int
    count: int
    user: str
    host: str


def encode(
    *,
    type: int,
    mode: str | None = None,
    wants_pong: bool = False,
    seq: int = 0,
    token: int | None = None,
    id: int = 0,
    index: int = 0,
    count: int = 0,
    user: str = "",
    host: str = "",
) -> bytes:
    """Build one frame.

    `seq` and `token` share a field. The JavaScript version needed a raw-bytes
    escape hatch here, because a 64-bit token does not survive a round trip
    through a double; a Python int is exact, so there is nothing to work around.
    """
    u = user.encode("utf-8")[:NAME_MAX]
    h = host.encode("utf-8")[:NAME_MAX]
    return _LAYOUT.pack(
        type,
        MODES.index(mode) if mode else 0,
        1 if wants_pong else 0,
        len(u),
        token if token is not None else seq,
        id,
        index,
        count,
        len(h),
        0,
        u,
        h,
    )


def decode(data: bytes) -> Frame | None:
    """Return None for anything this side should refuse to understand."""
    if len(data) != FRAME_BYTES:
        return None

    # `struct.unpack` is typed as `tuple[Any, ...]`, so the shape is declared
    # here rather than let Any leak into every field below.
    fields: tuple[
        int, int, int, int, int, int, int, int, int, int, bytes, bytes
    ] = _LAYOUT.unpack(data)
    (
        type_,
        mode,
        flags,
        user_len,
        payload,
        id_,
        index,
        count,
        host_len,
        _reserved,
        user,
        host,
    ) = fields

    kind = _KIND.get(type_)
    if kind is None or mode >= len(MODES):
        return None
    if user_len > NAME_MAX or host_len > NAME_MAX:
        return None

    return Frame(
        type=type_,
        kind=kind,
        mode=MODES[mode],
        wants_pong=(flags & 1) != 0,
        payload=payload,
        id=id_,
        index=index,
        count=count,
        user=user[:user_len].decode("utf-8", "replace"),
        host=host[:host_len].decode("utf-8", "replace"),
    )
