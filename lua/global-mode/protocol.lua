--- Wire protocol: newline-delimited JSON, and the mode alphabet.
local M = {}

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

--- Encode one message as a wire line, newline included.
---@param msg table
---@return string
function M.encode(msg)
  return vim.json.encode(msg) .. "\n"
end

--- Decode one wire line.
---
--- Returns nil rather than throwing: the server is trusted, but a truncated or
--- garbled line should never take down the editor.
---@param line string
---@return table|nil
function M.decode(line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" or type(msg.t) ~= "string" then
    return nil
  end
  return msg
end

return M
