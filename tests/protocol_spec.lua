-- Run with: nvim -l tests/protocol_spec.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local protocol = require("global-mode.protocol")

local failures, checks = 0, 0
local function eq(label, actual, expected)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print(
      ("FAIL %s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual))
    )
  end
end

-- The eight real modes map to themselves.
for _, mode in ipairs({ "n", "i", "v", "V", "R", "c", "t" }) do
  eq("normalize " .. mode, protocol.normalize(mode), mode)
end

-- Blockwise visual arrives as a literal CTRL-V.
eq("normalize CTRL-V", protocol.normalize("\22"), "b")

-- Select modes look like visual modes to everyone else.
eq("normalize s", protocol.normalize("s"), "v")
eq("normalize S", protocol.normalize("S"), "V")
eq("normalize CTRL-S", protocol.normalize("\19"), "b")

-- Replace and cmdline variants collapse onto their base mode.
eq("normalize Rv", protocol.normalize("Rv"), "R")
eq("normalize Rx", protocol.normalize("Rx"), "R")
eq("normalize Rc", protocol.normalize("Rc"), "R")
eq("normalize cv", protocol.normalize("cv"), "c")
eq("normalize cr", protocol.normalize("cr"), "c")

-- Operator-pending is dropped. This is the neovim#22263 guard: these must
-- never reach the wire, and must never schedule anything.
for _, mode in ipairs({ "no", "nov", "noV", "no\22", "noi", "nor" }) do
  eq("drop " .. vim.inspect(mode), protocol.normalize(mode), nil)
end

-- Insert-mode-pending variants are dropped for the same reason.
for _, mode in ipairs({ "niI", "niR", "niV", "nit" }) do
  eq("drop " .. mode, protocol.normalize(mode), nil)
end

-- Junk is dropped rather than guessed at.
for _, mode in ipairs({ "", "x", "!", "?" }) do
  eq("drop " .. vim.inspect(mode), protocol.normalize(mode), nil)
end
eq("drop nil", protocol.normalize(nil), nil)
eq("drop number", protocol.normalize(42), nil)

-- Labels.
eq("label i", protocol.label("i"), "INSERT")
eq("label b", protocol.label("b"), "V-BLOCK")
eq("label nil", protocol.label(nil), "?")

-- Every frame is exactly 84 bytes. That is the whole of the framing rule:
-- one datagram is one frame, so there is nothing to delimit and nothing to
-- reassemble.
for _, kind in ipairs({ "HELLO", "JOIN", "SET_MODE", "PONG", "GET_ROSTER", "BYE" }) do
  eq(
    "encode " .. kind .. " is 84 bytes",
    #protocol.encode({ type = protocol.T[kind], mode = "n" }),
    protocol.FRAME_BYTES
  )
end

-- Round trip, over every mode in the alphabet.
for letter in pairs(protocol.MODES) do
  local f = protocol.decode(protocol.encode({ type = protocol.T.SET_MODE, mode = letter }))
  eq("round trip mode " .. letter, f and f.mode, letter)
  eq("round trip kind " .. letter, f and f.kind, "SET_MODE")
end

-- Names survive, and are padded rather than trusted.
local named = protocol.decode(protocol.encode({
  type = protocol.T.STATE,
  mode = "i",
  seq = 7,
  user = "alex",
  host = "box",
}))
eq("round trip user", named.user, "alex")
eq("round trip host", named.host, "box")
eq("round trip seq", named.payload, 7)

-- A name longer than the field is truncated, not refused.
local long = string.rep("z", protocol.MAX_NAME + 10)
local trimmed = protocol.decode(protocol.encode({ type = protocol.T.HELLO, user = long }))
eq("over-long name truncates", #trimmed.user, protocol.MAX_NAME)

-- The token is carried as bytes and never as a number. Sixty-four bits of
-- randomness does not survive a double, and the client's only job is to hand
-- it straight back -- getting this wrong made the handshake loop forever with
-- both ends behaving correctly.
local high = string.rep(string.char(0xFF), 8)
local challenge = string.char(protocol.T.CHALLENGE, 0, 0, 0)
  .. high
  .. string.rep(string.char(0), protocol.FRAME_BYTES - 12)
local seen = protocol.decode(challenge)
eq("token survives as bytes", seen.token_raw, high)
eq(
  "and re-encodes unchanged",
  protocol.encode({ type = protocol.T.JOIN, token_raw = seen.token_raw }):sub(5, 12),
  high
)

-- Anything that is not a frame decodes to nil rather than throwing.
for _, junk in ipairs({ "", "not a frame", string.rep("x", 83), string.rep("x", 85) }) do
  eq("decode junk of length " .. #junk, protocol.decode(junk), nil)
end
eq("decode nil", protocol.decode(nil), nil)

-- An unknown frame type is refused rather than coerced onto a known one.
eq(
  "unknown type refused",
  protocol.decode(string.char(99) .. string.rep(string.char(0), protocol.FRAME_BYTES - 1)),
  nil
)

-- So is a ninth mode.
eq(
  "mode byte 8 refused",
  protocol.decode(
    string.char(protocol.T.SET_MODE, 8) .. string.rep(string.char(0), protocol.FRAME_BYTES - 2)
  ),
  nil
)

-- And a length that would reach past the field.
eq(
  "over-long declared name refused",
  protocol.decode(
    string.char(protocol.T.HELLO, 0, 0, 99) .. string.rep(string.char(0), protocol.FRAME_BYTES - 4)
  ),
  nil
)

print(("%d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
