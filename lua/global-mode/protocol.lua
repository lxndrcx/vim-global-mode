--- Wire protocol: fixed 84-byte frames, and the mode alphabet.
---
--- One datagram is one frame, so there is no framing to do -- no length
--- prefix, no delimiter scan, no half-a-message to hold onto. `decode` is
--- handed exactly 84 bytes or it is not called.
---
--- The server side of this is `Global_Mode.Wire` in the Ada repository, and
--- `scripts/fake-client.js` there is the reference encoder. The two must agree
--- byte for byte; `tests/protocol_spec.lua` is what checks that they do.
---
--- Neovim ships LuaJIT 2.1, which is Lua 5.1 plus extensions, so `string.pack`
--- does not exist. The byte arithmetic below is the replacement and is not as
--- bad as it looks: every field is a fixed offset and a fixed width.
local M = {}

--- Bytes per frame. Anything else is not a frame.
M.FRAME_BYTES = 84

--- Longest name the server will keep. Longer ones are truncated rather than
--- refused: a silly name should not cost you your seat.
M.MAX_NAME = 32

--- Frame types, matching the representation clause on
--- `Global_Mode.Wire.Frame_Kind`. The gap between 6 and 16 separates the two
--- directions, so a frame sent the wrong way is obvious in a hex dump.
M.T = {
  HELLO = 1,
  JOIN = 2,
  SET_MODE = 3,
  PONG = 4,
  GET_ROSTER = 5,
  BYE = 6,
  CHALLENGE = 16,
  WELCOME = 17,
  STATE = 18,
  ROSTER_ENTRY = 19,
}

--- Reverse lookup, for readable branching on receipt.
M.KIND = {}
for name, value in pairs(M.T) do
  M.KIND[value] = name
end

--- The eight modes that exist globally.
---
--- Neovim reports far more than eight. Everything else is folded onto one of
--- these or dropped outright by `M.normalize`.
M.MODES = { n = true, i = true, v = true, V = true, b = true, R = true, c = true, t = true }

--- Human-readable names, for the statusline.
M.LABELS = {
  n = "NORMAL",
  i = "INSERT",
  v = "VISUAL",
  V = "V-LINE",
  b = "V-BLOCK",
  R = "REPLACE",
  c = "COMMAND",
  t = "TERMINAL",
}

--- Modes we refuse to touch, mapped from what `mode()` and `ModeChanged` report.
---
--- Operator-pending (`no`, `nov`, ...) is the important one: an autocmd that
--- schedules work on entering it could re-trigger itself in a loop and peg a
--- core (neovim#22263). Dropping it here, before anything is scheduled, is the
--- real fix — everything downstream is belt and braces.
local DROP_PREFIXES = { "no", "ni" }

--- Reduce a Neovim mode string to one of the eight, or nil to ignore it.
---@param mode string  a value from `vim.fn.mode(1)` or `v:event.new_mode`
---@return string|nil
function M.normalize(mode)
  if type(mode) ~= "string" or mode == "" then
    return nil
  end

  for _, prefix in ipairs(DROP_PREFIXES) do
    if mode:sub(1, #prefix) == prefix then
      return nil
    end
  end

  local first = mode:sub(1, 1)

  -- Select modes behave like visual modes to everyone watching.
  if first == "s" then
    return "v"
  elseif first == "S" then
    return "V"
  elseif first == "\19" then -- CTRL-S, select-block
    return "b"
  end

  if first == "\22" then -- CTRL-V, visual-block
    return "b"
  end

  -- `Rv`, `Rx`, `Rc` are all flavours of replace; `cv` is still the cmdline.
  if first == "R" then
    return "R"
  elseif first == "c" then
    return "c"
  end

  return M.MODES[first] and first or nil
end

--- Label for a normalized mode.
---@param mode string|nil
---@return string
function M.label(mode)
  return M.LABELS[mode] or "?"
end

--- Mode letter to its byte on the wire, and back.
---
--- The order is the one `Global_Mode.Types.Mode` declares, and it is load
--- bearing: this being a byte rather than a string is the single change that
--- made the round-trip property provable on the server side.
M.MODE_BYTE = { n = 0, i = 1, v = 2, V = 3, b = 4, R = 5, c = 6, t = 7 }
M.BYTE_MODE = {}
for letter, byte in pairs(M.MODE_BYTE) do
  M.BYTE_MODE[byte] = letter
end

--- Big-endian integers, in the absence of string.pack.
---@param value integer
---@param width integer  bytes
---@return string
local function be(value, width)
  local out = {}
  for i = width, 1, -1 do
    out[i] = string.char(value % 256)
    value = math.floor(value / 256)
  end
  return table.concat(out)
end

---@param s string
---@param at integer  1-based index of the first byte
---@param width integer
---@return integer
local function un_be(s, at, width)
  local value = 0
  for i = 0, width - 1 do
    value = value * 256 + s:byte(at + i)
  end
  return value
end

--- One name field: a length, and 32 bytes with zeros past it.
---
--- The padding must be zeros. The server refuses a frame whose padding carries
--- anything else, because two encodings of one name would mean two byte
--- strings decoding to the same frame -- exactly the parser differential its
--- round-trip property rules out. Truncation is by byte, so a multi-byte
--- character at the boundary could be cut in half; the server treats names as
--- opaque bytes and never decodes them, so this cannot make it misbehave.
---@param name string|nil
---@return string padded, integer length
local function name_field(name)
  local raw = (name or ""):sub(1, M.MAX_NAME)
  return raw .. string.rep("\0", M.MAX_NAME - #raw), #raw
end

--- Encode one frame. Always returns exactly 84 bytes.
---
--- `token_raw`, when present, is spliced in as the eight bytes it already is.
--- See `decode` for why it must never become a number.
---@param f table
---@return string
function M.encode(f)
  local user, user_len = name_field(f.user)
  local host, host_len = name_field(f.host)
  return string.char(f.type)
    .. string.char(f.mode and M.MODE_BYTE[f.mode] or 0)
    .. string.char(f.wants_pong and 1 or 0)
    .. string.char(user_len)
    -- seq and token share this field; only one is ever set.
    .. (f.token_raw or be(f.seq or 0, 8))
    .. be(f.id or 0, 2)
    .. be(f.index or 0, 2)
    .. be(f.count or 0, 2)
    .. string.char(host_len)
    .. string.char(0) -- reserved
    .. user
    .. host
end

--- Decode one datagram.
---
--- Returns nil rather than throwing. The plugin trusts its server, but a
--- stray datagram from anywhere on the network can land on this socket, and
--- none of them should be able to disturb the editor.
---@param data string
---@return table|nil
function M.decode(data)
  if type(data) ~= "string" or #data ~= M.FRAME_BYTES then
    return nil
  end

  local kind = M.KIND[data:byte(1)]
  if not kind then
    return nil
  end

  local mode = M.BYTE_MODE[data:byte(2)]
  if not mode then
    return nil
  end

  local user_len = data:byte(4)
  local host_len = data:byte(19)
  if user_len > M.MAX_NAME or host_len > M.MAX_NAME then
    return nil
  end

  return {
    type = data:byte(1),
    kind = kind,
    mode = mode,
    wants_pong = data:byte(3) % 2 == 1,

    -- The same eight bytes, twice, deliberately.
    --
    -- `seq` as a number is fine: Lua numbers are doubles, exact to 2^53, and
    -- at one increment per keypress nobody reaches that.
    --
    -- The token is not fine as a number, and this cost an afternoon. It is 64
    -- bits of randomness, so it is above 2^53 essentially always, and turning
    -- it into a double silently rounds it. The client would then echo back a
    -- token one or two bits different from the one it was issued, the server
    -- would recompute the real one, refuse the mismatch in silence, and the
    -- handshake would loop forever with both ends behaving correctly.
    --
    -- The client has no business reading the token anyway -- it is opaque, and
    -- the only thing ever done with it is handing it straight back. So it is
    -- carried as the bytes it arrived as.
    payload = un_be(data, 5, 8),
    token_raw = data:sub(5, 12),
    id = un_be(data, 13, 2),
    index = un_be(data, 15, 2),
    count = un_be(data, 17, 2),
    user = data:sub(21, 20 + user_len),
    host = data:sub(53, 52 + host_len),
  }
end

return M
