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

--- The mode we are currently forcing, if any.
---
--- Feeding keys fires `ModeChanged`, which would broadcast the change straight
--- back and start a ping-pong storm. The send path checks this and stays quiet
--- when the change is one we caused.
M.pending = nil

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
    -- Re-check inside the scheduled callback: things move between then and now.
    if protocol.normalize(vim.fn.mode(1)) == mode then
      return
    end

    -- Feeding keys while the command-line window is open throws E11.
    if vim.fn.getcmdwintype() ~= "" then
      return
    end

    if not allowed() then
      return
    end

    M.pending = mode
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
  end)
end

--- True if `mode` is a change we are in the middle of forcing.
---
--- Consumes the pending marker, so a genuine later change to the same mode is
--- still broadcast.
---@param mode string
---@return boolean
function M.consume(mode)
  if M.pending == mode then
    M.pending = nil
    return true
  end
  -- Any other change means our forced one never landed; stop waiting for it.
  M.pending = nil
  return false
end

return M
