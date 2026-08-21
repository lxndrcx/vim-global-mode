// The wire format, for the fake servers in this directory.
//
// Shared by loop-guard.js and resync.js, which both stand in for the real
// server. The authority is `Global_Mode.Wire` in the Ada repository, and
// `scripts/fake-client.js` there is its reference encoder; this must agree with
// both, byte for byte. `tests/protocol_spec.lua` checks the Lua side against
// the same layout.
//
//   0   1   type          1..6 editor->server, 16..19 server->editor
//   1   1   mode          0..7
//   2   1   flags         bit 0 = wants_pong
//   3   1   user_len      0..32
//   4   8   seq_or_token  big-endian
//   12  2   id
//   14  2   index         roster position
//   16  2   count         roster total
//   18  1   host_len      0..32
//   19  1   reserved      must be zero
//   20  32  user
//   52  32  host

const FRAME = 84;
const NAME_MAX = 32;

const T = {
  HELLO: 1,
  JOIN: 2,
  SET_MODE: 3,
  PONG: 4,
  GET_ROSTER: 5,
  BYE: 6,
  CHALLENGE: 16,
  WELCOME: 17,
  STATE: 18,
  ROSTER_ENTRY: 19,
};

const KIND = Object.fromEntries(Object.entries(T).map(([k, v]) => [v, k]));

const MODES = ["n", "i", "v", "V", "b", "R", "c", "t"];

function encode(f) {
  const b = Buffer.alloc(FRAME);
  b[0] = f.type;
  b[1] = f.mode ? MODES.indexOf(f.mode) : 0;
  b[2] = f.wantsPong ? 1 : 0;
  const user = Buffer.from(f.user ?? "", "utf8").subarray(0, NAME_MAX);
  const host = Buffer.from(f.host ?? "", "utf8").subarray(0, NAME_MAX);
  b[3] = user.length;
  // The token is carried as raw bytes when echoing one back, because a 64-bit
  // value does not survive a round trip through a double.
  if (f.tokenRaw) {
    f.tokenRaw.copy(b, 4);
  } else {
    b.writeBigUInt64BE(BigInt(f.token ?? f.seq ?? 0), 4);
  }
  b.writeUInt16BE(f.id ?? 0, 12);
  b.writeUInt16BE(f.index ?? 0, 14);
  b.writeUInt16BE(f.count ?? 0, 16);
  b[18] = host.length;
  b[19] = 0;
  user.copy(b, 20);
  host.copy(b, 52);
  return b;
}

function decode(b) {
  if (!Buffer.isBuffer(b) || b.length !== FRAME) return null;
  const kind = KIND[b[0]];
  if (!kind) return null;
  const mode = MODES[b[1]];
  if (mode === undefined) return null;
  const userLen = b[3];
  const hostLen = b[18];
  if (userLen > NAME_MAX || hostLen > NAME_MAX) return null;
  return {
    type: b[0],
    kind,
    mode,
    wantsPong: (b[2] & 1) !== 0,
    payload: b.readBigUInt64BE(4),
    tokenRaw: b.subarray(4, 12),
    id: b.readUInt16BE(12),
    index: b.readUInt16BE(14),
    count: b.readUInt16BE(16),
    user: b.subarray(20, 20 + userLen).toString("utf8"),
    host: b.subarray(52, 52 + hostLen).toString("utf8"),
  };
}

module.exports = { FRAME, NAME_MAX, T, KIND, MODES, encode, decode };
