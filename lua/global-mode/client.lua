--- The connection to the global mode server.
---
--- Raw TCP carrying newline-delimited JSON. Neovim gives us a TCP client for
--- free via `vim.uv`; a WebSocket would mean hand-rolling frame masking in Lua
--- for no benefit, since the peer is our own server.
local config = require("global-mode.config")
local protocol = require("global-mode.protocol")
local apply = require("global-mode.apply")

local M = {}

---@class GlobalModeState
---@field mode string|nil     the global mode, as last heard from the server
---@field by string|nil       who last changed it
---@field seq integer         the server's change counter
---@field id string|nil       our client id
---@field peers table[]       everyone else connected
---@field status string       "offline" | "connecting" | "online"
M.state = { mode = nil, by = nil, seq = 0, id = nil, peers = {}, status = "offline" }

local handle = nil
local timer = nil
local buffer = ""
local backoff = nil
local want_connection = false
local last_sent = nil

local function notify(msg, level)
  if config.current.notify then
    vim.notify("global-mode: " .. msg, level or vim.log.levels.INFO)
  end
end

--- Tell anything watching (statuslines, mostly) that the state moved.
local function announce()
  vim.schedule(function()
    vim.api.nvim_exec_autocmds("User", { pattern = "GlobalModeChanged" })
    vim.cmd.redrawstatus()
  end)
end

-- Gated on the socket rather than on `status`, because the very first thing we
-- send is the hello that gets us to "online" in the first place.
local function send(msg)
  if handle and not handle:is_closing() then
    handle:write(protocol.encode(msg))
  end
end

--- Broadcast a local mode change, unless it is one the server just forced on us.
---@param mode string  a normalized mode
function M.send_mode(mode)
  -- The loop guard: never report back a change we made because we were told to.
  if apply.consume(mode) then
    return
  end
  -- Nor re-report what we already told it.
  if mode == last_sent then
    return
  end
  last_sent = mode

  -- Update our own view optimistically. The server deliberately does not echo
  -- a change back to whoever caused it, so this is the only chance we get:
  -- without it our idea of the global mode would freeze at whatever someone
  -- else last broadcast, and we would suppress our own next change as stale.
  M.state.mode = mode
  M.state.by = config.current.user

  send({ t = "mode", mode = mode })
  announce()
end

local function handle_message(msg)
  if msg.t == "welcome" then
    -- Only now are we genuinely usable: we have an id and we know the mode.
    -- Reporting "online" from the moment the socket opened would leave a
    -- window where the statusline and :checkhealth have nothing to show.
    M.state.status = "online"
    M.state.id = msg.id
    M.state.mode = msg.mode
    M.state.by = msg.by
    M.state.seq = msg.seq or 0
    apply.apply(msg.mode)
    announce()
  elseif msg.t == "mode" then
    -- Ignore anything older than what we have already applied: after a
    -- reconnect, frames can arrive out of order.
    if (msg.seq or 0) < M.state.seq then
      return
    end
    M.state.mode = msg.mode
    M.state.by = msg.by
    M.state.seq = msg.seq or M.state.seq
    last_sent = msg.mode
    apply.apply(msg.mode)
    announce()
  elseif msg.t == "roster" then
    M.state.peers = msg.clients or {}
    announce()
  elseif msg.t == "ping" then
    send({ t = "pong" })
  end
end

--- Split the byte stream into lines. TCP will hand us half a line whenever
--- it feels like it, so the tail is kept until its newline arrives.
local function consume(chunk)
  buffer = buffer .. chunk
  while true do
    local nl = buffer:find("\n", 1, true)
    if not nl then
      break
    end
    local line = buffer:sub(1, nl - 1)
    buffer = buffer:sub(nl + 1)
    if line ~= "" then
      local msg = protocol.decode(line)
      if msg then
        handle_message(msg)
      end
    end
  end
end

local function cleanup()
  if handle and not handle:is_closing() then
    handle:close()
  end
  handle = nil
  buffer = ""
  last_sent = nil
  M.state.status = "offline"
  M.state.peers = {}
  M.state.id = nil
  announce()
end

local schedule_reconnect

local function connect()
  local c = config.current
  M.state.status = "connecting"
  handle = vim.uv.new_tcp()

  handle:connect(c.host, c.port, function(err)
    if err then
      cleanup()
      schedule_reconnect()
      return
    end

    backoff = nil
    send({
      t = "hello",
      user = c.user,
      host = vim.uv.os_gethostname(),
      nvim = tostring(vim.version()),
    })
    vim.schedule(function()
      notify(("connected to %s:%d"):format(c.host, c.port))
    end)

    handle:read_start(function(read_err, chunk)
      if read_err or not chunk then
        cleanup()
        schedule_reconnect()
        return
      end
      consume(chunk)
    end)
  end)
end

--- Retry with exponential backoff, so a server that is down does not turn into
--- a busy loop.
schedule_reconnect = function()
  if not want_connection then
    return
  end

  local c = config.current
  backoff = backoff and math.min(backoff * 2, c.reconnect.max) or c.reconnect.min

  if timer then
    timer:stop()
    timer:close()
  end
  timer = vim.uv.new_timer()
  timer:start(backoff, 0, function()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    if want_connection then
      connect()
    end
  end)
end

function M.connect()
  if handle then
    return
  end
  want_connection = true
  backoff = nil
  connect()
end

function M.disconnect()
  want_connection = false
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  cleanup()
  M.state.mode = nil
  M.state.by = nil
  notify("disconnected")
end

function M.is_connected()
  return M.state.status == "online"
end

--- Everyone connected except us. The server's roster includes ourselves, which
--- is not what "who else is subject to this" wants to know.
---@return table[]
function M.others()
  local others = {}
  for _, peer in ipairs(M.state.peers) do
    if peer.id ~= M.state.id then
      table.insert(others, peer)
    end
  end
  return others
end

return M
