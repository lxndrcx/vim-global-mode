--- Configuration, with defaults.
local M = {}

---@class GlobalModeConfig
---@field host string           server address
---@field port integer          server port for editors
---@field user string           name shown to everyone else
---@field auto_connect boolean  connect on startup
---@field notify boolean        announce connect/disconnect
---@field reconnect { min: integer, max: integer }  backoff bounds, milliseconds
local defaults = {
  host = "127.0.0.1",
  port = 7777,
  user = vim.env.USER or vim.env.USERNAME or "anon",
  auto_connect = true,
  notify = true,
  reconnect = { min = 1000, max = 30000 },
}

M.current = vim.deepcopy(defaults)

--- Merge user options over the defaults.
---@param opts table|nil
---@return GlobalModeConfig
function M.setup(opts)
  M.current = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  local c = M.current
  vim.validate("host", c.host, "string")
  vim.validate("port", c.port, "number")
  vim.validate("user", c.user, "string")
  vim.validate("auto_connect", c.auto_connect, "boolean")
  vim.validate("notify", c.notify, "boolean")
  vim.validate("reconnect.min", c.reconnect.min, "number")
  vim.validate("reconnect.max", c.reconnect.max, "number")

  if c.reconnect.min > c.reconnect.max then
    c.reconnect.max = c.reconnect.min
  end

  return c
end

return M
