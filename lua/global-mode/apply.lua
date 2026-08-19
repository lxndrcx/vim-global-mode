--- Applying the global mode to this editor, against its will.
local protocol = require("global-mode.protocol")

local M = {}

--- Keys that put us into each mode, from wherever we happen to be.
---
--- Every one is prefixed with CTRL-\ CTRL-N rather than <Esc>: it is the only
--- escape that works from *every* mode, terminal mode included, and it does not
--- shift the cursor the way <Esc> does when leaving insert.
local KEYS = {
  n = [[<C-\><C-n>]],
  i = [[<C-\><C-n>i]],
  v = [[<C-\><C-n>v]],
  V = [[<C-\><C-n>V]],
  b = [[<C-\><C-n><C-v>]],
  R = [[<C-\><C-n>R]],
  c = [[<C-\><C-n>:]],
  -- `t` is deliberately absent: you cannot meaningfully force someone into
  -- terminal mode in a buffer that is not a terminal. It is displayed, not applied.
}

--- Modes we are currently forcing, oldest first.
---
--- Feeding keys fires `ModeChanged`, which would broadcast the change straight
--- back and start a ping-pong storm. This queue is what the send path checks to
--- stay quiet about changes we caused.
---
--- It is a queue rather than a single value because two remote frames can be
--- scheduled before either one's keys reach the typeahead, and because a single
--- apply produces up to *two* `ModeChanged` events, not one — see `consume`.
M.expected = {}

--- How long to keep waiting for a forced change to land, in milliseconds.
---
--- Without a deadline an apply that never produces a mode change at all — `i`
--- into a `nomodifiable` buffer raises E21, for instance — would leave its entry
--- in the queue forever, silently swallowing the user's next genuine change.
local EXPECT_MS = 500

--- Circuit breaker state. Bounds any feedback loop that survives the guards
--- above, so a bug degrades into a log line rather than a hung editor.
local WINDOW_MS = 1000
local MAX_PER_WINDOW = 20
local window_start = 0
local window_count = 0
local tripped = false

local function allowed()
  local now = vim.uv.now()
  if now - window_start > WINDOW_MS then
    window_start, window_count, tripped = now, 0, false
  end
  window_count = window_count + 1
  if window_count > MAX_PER_WINDOW then
    if not tripped then
      tripped = true
      vim.notify(
        ("global-mode: %d mode changes in a second, pausing briefly"):format(window_count),
        vim.log.levels.WARN
      )
    end
    return false
  end
  return true
end

--- Drop entries whose forced change never arrived.
local function expire()
  local now = vim.uv.now()
  while M.expected[1] and now > M.expected[1].deadline do
    table.remove(M.expected, 1)
  end
end

--- Forget every pending expectation. Used when an applied change lands wrong.
function M.reset()
  M.expected = {}
end

--- Force this editor into `mode`.
---
--- Safe to call from a `vim.uv` callback: the actual work is scheduled, because
--- feeding keys is forbidden in a fast event context.
---@param mode string  a normalized mode
function M.apply(mode)
  local keys = KEYS[mode]
  if not keys then
    return
  end

  vim.schedule(function()
    -- Compare against the mode we are already committed to entering, not the
    -- one we happen to be in. Keys fed by an earlier apply may still be sitting
    -- in the typeahead, so `mode(1)` lags reality: when two frames arrive in a
    -- single read -- which any latency or a busy main loop will coalesce --
    -- the second was discarded as a no-op and the editor was left in the first
    -- one's mode permanently, believing it was in the second's.
    local committed = M.expected[#M.expected]
    local current = committed and committed.mode or protocol.normalize(vim.fn.mode(1))
    if current == mode then
      return
    end

    -- Feeding keys while the command-line window is open throws E11.
    if vim.fn.getcmdwintype() ~= "" then
      return
    end

    if not allowed() then
      return
    end

    table.insert(M.expected, { mode = mode, deadline = vim.uv.now() + EXPECT_MS })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
  end)
end

--- True if `mode` is a change we are in the middle of forcing.
---@param mode string
---@return boolean
function M.consume(mode)
  expire()

  local head = M.expected[1]
  if not head then
    return false
  end

  if mode == head.mode then
    table.remove(M.expected, 1)
    return true
  end

  -- Every entry in KEYS begins with CTRL-\ CTRL-N, so applying any non-normal
  -- mode from any non-normal mode passes through normal on the way and fires an
  -- extra `ModeChanged` first. Treating that transit as a real change is what
  -- used to defeat the loop guard entirely: the editor broadcast a bogus `n`,
  -- yanking everyone else to normal, and then re-broadcast the very mode it had
  -- just been told to enter.
  if mode == "n" and head.mode ~= "n" then
    return true
  end

  -- Anything else means our forced change did not land; stop waiting for it.
  M.expected = {}
  return false
end

return M
