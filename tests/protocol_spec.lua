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

-- Encoding is one newline-terminated line.
local line = protocol.encode({ t = "mode", mode = "i" })
eq("encode ends with newline", line:sub(-1), "\n")
eq("encode has one newline", select(2, line:gsub("\n", "")), 1)

-- Round trip.
local decoded = protocol.decode(protocol.encode({ t = "mode", mode = "V" }):sub(1, -2))
eq("decode t", decoded.t, "mode")
eq("decode mode", decoded.mode, "V")

-- Garbage decodes to nil rather than throwing.
for _, junk in ipairs({ "", "not json", "[]", "null", "42", '{"no_t":1}' }) do
  eq("decode junk " .. vim.inspect(junk), protocol.decode(junk), nil)
end

print(("%d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
