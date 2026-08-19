--- Configuration, with defaults.
local M = {}

---@class GlobalModeConfig
---@field host string           server address (numeric IP; luv does not resolve names)
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

--- Our Neovim version, resolved once here.
---
--- `vim.version` is a lazily-required module, and that require fails inside a
--- `vim.uv` callback because the runtime-file loader is unavailable in a fast
--- event context. Building the hello message there would therefore throw --
--- intermittently, depending on whether something else had already loaded the
--- module -- and abort the connect before `read_start` was ever reached.
M.nvim_version = "?"

--- Validate by hand rather than with `vim.validate`.
---
--- `vim.validate` changed signature in Neovim 0.11: the `(name, value, type)`
--- form does not exist on 0.10, which this plugin claims to support, and calling
--- it there errors out of `setup()` before any autocmd is registered.
---@param name string
---@param value any
---@param expected string
local function check(name, value, expected)
  if type(value) ~= expected then
    error(("global-mode: `%s` must be a %s, got %s"):format(name, expected, type(value)), 0)
  end
end

--- Merge user options over the defaults.
---@param opts table|nil
---@return GlobalModeConfig
function M.setup(opts)
  if opts ~= nil then
    check("setup(opts)", opts, "table")
  end
  M.current = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  local c = M.current
  check("host", c.host, "string")
  check("port", c.port, "number")
  check("user", c.user, "string")
  check("auto_connect", c.auto_connect, "boolean")
  check("notify", c.notify, "boolean")
  check("reconnect", c.reconnect, "table")
  check("reconnect.min", c.reconnect.min, "number")
  check("reconnect.max", c.reconnect.max, "number")

  if c.reconnect.min > c.reconnect.max then
    c.reconnect.max = c.reconnect.min
  end

  -- Resolve the version now, in a normal context, so the connect callback does
  -- not have to.
  local ok, version = pcall(function()
    return tostring(vim.version())
  end)
  M.nvim_version = ok and version or "?"

  return c
end

return M
