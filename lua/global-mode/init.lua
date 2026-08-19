--- global-mode: one modal state, shared by everyone.
---
--- Whoever presses `i` puts the whole server into insert mode. This is a joke.
local config = require("global-mode.config")
local protocol = require("global-mode.protocol")
local client = require("global-mode.client")

local M = {}

M.state = client.state

local group = vim.api.nvim_create_augroup("GlobalMode", { clear = true })

--- Highlight groups, one per mode, so a statusline can colour itself.
local HIGHLIGHTS = {
  n = "GlobalModeNormal",
  i = "GlobalModeInsert",
  v = "GlobalModeVisual",
  V = "GlobalModeVisual",
  b = "GlobalModeVisual",
  R = "GlobalModeReplace",
  c = "GlobalModeCommand",
  t = "GlobalModeTerminal",
}

local function define_highlights()
  local defaults = {
    GlobalModeNormal = "Comment",
    GlobalModeInsert = "String",
    GlobalModeVisual = "Statement",
    GlobalModeReplace = "ErrorMsg",
    GlobalModeCommand = "WarningMsg",
    GlobalModeTerminal = "Constant",
  }
  for name, link in pairs(defaults) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

---@param opts table|nil
function M.setup(opts)
  local c = config.setup(opts)
  define_highlights()

  -- Report every local mode change. This handler deliberately does no
  -- scheduling: `ModeChanged` plus `vim.schedule` is the shape that could once
  -- loop to 100% CPU (neovim#22263), and operator-pending is dropped in
  -- `normalize` before it can get anywhere near a scheduled callback.
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = "*:*",
    callback = function()
      local mode = protocol.normalize(vim.v.event.new_mode)
      if mode then
        client.send_mode(mode)
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      client.disconnect()
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = define_highlights,
  })

  if c.auto_connect then
    client.connect()
  end
end

M.connect = client.connect
M.disconnect = client.disconnect
M.is_connected = client.is_connected
M.others = client.others

--- The global mode, or nil when offline.
---@return string|nil
function M.mode()
  return client.state.mode
end

--- A statusline string: `INSERT · alex`, or empty when offline.
---@return string
function M.statusline()
  local s = client.state
  if s.status ~= "online" or not s.mode then
    return ""
  end
  local label = protocol.label(s.mode)
  return s.by and (label .. " · " .. s.by) or label
end

--- The highlight group matching the current global mode.
---@return string
function M.highlight()
  return HIGHLIGHTS[client.state.mode] or "GlobalModeNormal"
end

--- A ready-made lualine component.
---
---   require("lualine").setup({
---     sections = { lualine_x = { require("global-mode").lualine() } },
---   })
---@return table
function M.lualine()
  return {
    M.statusline,
    cond = function()
      return client.is_connected()
    end,
    color = function()
      return M.highlight()
    end,
  }
end

--- A one-line summary, for `:GlobalModeStatus`.
---@return string
function M.status()
  local s = client.state
  local c = config.current
  if s.status ~= "online" then
    return ("global-mode: %s (%s:%d)"):format(s.status, c.host, c.port)
  end
  return ("global-mode: %s — %s, set by %s, seq %d, %d other editor(s)"):format(
    s.id or "?",
    protocol.label(s.mode),
    s.by or "?",
    s.seq,
    #client.others()
  )
end

return M
