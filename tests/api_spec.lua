-- Unit tests for the pure, user-facing parts of the plugin.
--
-- These are the pieces a user touches directly — config validation and the
-- statusline API — and none of them had any coverage: every existing suite
-- drives mode propagation and never reads a statusline or hands setup() a bad
-- option.
--
-- Run with: nvim -l tests/api_spec.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local gm = require("global-mode")
local config = require("global-mode.config")
local client = require("global-mode.client")

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

local function errors_with(label, fn, needle)
  checks = checks + 1
  local ok, err = pcall(fn)
  if ok then
    failures = failures + 1
    print(("FAIL %s: expected an error, got none"):format(label))
  elseif not tostring(err):find(needle, 1, true) then
    failures = failures + 1
    print(("FAIL %s: error %q did not mention %q"):format(label, tostring(err), needle))
  end
end

-- Config validation -----------------------------------------------------------

-- Defaults are usable without any options at all.
config.setup(nil)
eq("default host", config.current.host, "127.0.0.1")
eq("default port", config.current.port, 7777)
eq("default auto_connect", config.current.auto_connect, true)

-- The version is resolved eagerly, because `vim.version` cannot be required
-- from inside a uv callback.
checks = checks + 1
if config.nvim_version == "?" or config.nvim_version == nil then
  failures = failures + 1
  print("FAIL nvim_version was not resolved at setup")
end

-- User options override, and nested tables merge rather than replace.
config.setup({ port = 9999, reconnect = { min = 250 } })
eq("port overridden", config.current.port, 9999)
eq("nested min overridden", config.current.reconnect.min, 250)
eq("nested max preserved by deep merge", config.current.reconnect.max, 30000)

-- An inverted backoff range is clamped rather than left nonsensical.
config.setup({ reconnect = { min = 60000, max = 1000 } })
eq("inverted backoff is clamped", config.current.reconnect.max, 60000)

-- Bad options are rejected with a plain sentence. `vim.validate` is not used:
-- its (name, value, type) form is Neovim 0.11+, and the docs promise 0.10.
errors_with("non-number port", function()
  config.setup({ port = "seven" })
end, "`port` must be a number")
errors_with("non-string host", function()
  config.setup({ host = 42 })
end, "`host` must be a string")
errors_with("non-boolean auto_connect", function()
  config.setup({ auto_connect = "yes" })
end, "`auto_connect` must be a boolean")
errors_with("non-table opts", function()
  config.setup("nonsense")
end, "must be a table")

-- Statusline API --------------------------------------------------------------

config.setup({ notify = false })

-- Offline: everything must degrade quietly rather than erroring or showing junk.
client.state.status = "offline"
client.state.mode, client.state.by, client.state.id = nil, nil, nil
client.state.peers, client.state.seq = {}, 0
eq("statusline is empty when offline", gm.statusline(), "")
eq("highlight falls back when offline", gm.highlight(), "GlobalModeNormal")
eq("mode() is nil when offline", gm.mode(), nil)
eq("others() is empty when offline", #gm.others(), 0)
checks = checks + 1
if not gm.status():find("offline", 1, true) then
  failures = failures + 1
  print("FAIL status() did not report being offline: " .. gm.status())
end

-- Online, with a roster that includes ourselves.
client.state.status = "online"
client.state.mode, client.state.by, client.state.seq = "i", "alex", 7
client.state.id = "c1"
client.state.peers = {
  { id = "c1", user = "me", host = "here" },
  { id = "c2", user = "alex", host = "thinkpad" },
}
eq("statusline names the mode and the culprit", gm.statusline(), "INSERT · alex")
eq("highlight tracks the mode", gm.highlight(), "GlobalModeInsert")
eq("mode() reports the global mode", gm.mode(), "i")
eq("others() excludes ourselves", #gm.others(), 1)
eq("others() keeps everyone else", gm.others()[1].user, "alex")

-- Visual modes share one highlight group; replace and command have their own.
for mode, group in pairs({
  n = "GlobalModeNormal",
  v = "GlobalModeVisual",
  V = "GlobalModeVisual",
  b = "GlobalModeVisual",
  R = "GlobalModeReplace",
  c = "GlobalModeCommand",
  t = "GlobalModeTerminal",
}) do
  client.state.mode = mode
  eq("highlight for " .. mode, gm.highlight(), group)
end

-- A statusline with no blame attributed yet still renders.
client.state.mode, client.state.by = "V", nil
eq("statusline without a culprit", gm.statusline(), "V-LINE")

-- lualine() hands back a component whose pieces actually work.
client.state.mode, client.state.by = "R", "sam"
local component = gm.lualine()
eq("lualine component exposes statusline", component[1](), "REPLACE · sam")
eq("lualine component colours itself", component.color(), "GlobalModeReplace")
eq("lualine cond tracks connection", component.cond(), true)
client.state.status = "offline"
eq("lualine cond is false when offline", component.cond(), false)

-- Losing the server must clear the mode, not leave a stale one behind. Anything
-- built on the documented `mode()` contract would otherwise show a mode that
-- nobody is in, indefinitely -- and a dropped server, not an explicit
-- :GlobalModeDisconnect, is the common way a session ends.
client.state.status = "online"
client.state.mode, client.state.by, client.state.id = "i", "alex", "c1"
client.state.peers = { { id = "c1", user = "me", host = "here" } }
require("global-mode.client").disconnect()
eq("mode() is nil after losing the connection", gm.mode(), nil)
eq("blame is cleared too", client.state.by, nil)
eq("status goes offline", client.state.status, "offline")
eq("the roster is emptied", #client.state.peers, 0)
eq("statusline is empty again", gm.statusline(), "")

print(("%d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
