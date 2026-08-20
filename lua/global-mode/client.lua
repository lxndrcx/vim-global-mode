--- The connection to the global mode server.
---
--- Except that there is no connection. The transport is UDP on a single
--- socket, which is why almost everything a socket client usually does is
--- missing here: there is no connect, no stream to reassemble, no half-read
--- message to hold onto, and nothing to clean up when the far end goes away.
---
--- One datagram is one whole frame. `recv_start` hands us exactly 84 bytes or
--- nothing at all, so the buffering that a TCP client needs has no counterpart
--- below -- it was deleted rather than translated.
---
--- What replaces connection state is silence. Every frame the server sends
--- carries the full authoritative state, and it re-sends every couple of
--- seconds whether anything changed or not, so "am I connected" becomes "have
--- I heard from it lately".
local config = require("global-mode.config")
local protocol = require("global-mode.protocol")
local apply = require("global-mode.apply")

local M = {}

---@class GlobalModeState
---@field mode string|nil     the global mode, as last heard from the server
---@field by string|nil       who last changed it
---@field seq integer         the server's change counter
---@field id integer|nil      our client id
---@field peers table[]       everyone connected, including us
---@field status string       "offline" | "connecting" | "online"
M.state = { mode = nil, by = nil, seq = 0, id = nil, peers = {}, status = "offline" }

local handle = nil
local timer = nil
local backoff = nil
local want_connection = false
local last_sent = nil

--- When the server was last heard from, and when we last said hello.
local last_heard = nil
local last_hello = nil

--- Roster frames arrive one per peer and are collected until the set is whole,
--- so a half-delivered roster never replaces a good one.
local roster_partial = nil

--- Silence after which we assume the server is gone, in milliseconds.
---
--- The server refreshes every two seconds and drops us after three missed
--- refreshes; matching that here means both ends give up at about the same
--- time instead of one of them talking to nobody.
local LIVENESS_MS = 6000

--- How often to look at the clock.
local TICK_MS = 500

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

local function send(frame)
  if handle and not handle:is_closing() then
    local c = config.current
    -- Errors are ignored on purpose. There is no connection to lose, so a
    -- failed send is one lost datagram: the server's next refresh repairs it.
    handle:send(protocol.encode(frame), c.host, c.port, function() end)
  end
end

--- Adopt the server's account of the world.
---
--- Frames carry full state and the rule is one line: take anything at least as
--- new as what we have. Ordering does not matter, duplicates are no-ops, and a
--- frame lost in transit is replaced by the next refresh -- which is why the
--- old client's resync logic is not here. There is nothing to resync from,
--- because nothing is ever incremental.
local function adopt(f)
  if f.payload < M.state.seq then
    return
  end
  M.state.mode = f.mode
  M.state.by = f.user ~= "" and f.user or nil
  M.state.seq = f.payload
  last_sent = f.mode
  apply.apply(f.mode)
  announce()
end

local function go_offline()
  local was = M.state.status
  M.state.status = "offline"
  M.state.peers = {}
  M.state.id = nil
  -- Forget the mode too. Keeping it meant `mode()` reported a global mode long
  -- after the server died, which is the documented contract's opposite.
  M.state.mode = nil
  M.state.by = nil
  last_sent = nil
  last_heard = nil
  roster_partial = nil
  apply.reset()
  if was == "online" then
    notify("lost the server")
  end
  announce()
end

local function handle_frame(f)
  last_heard = vim.uv.now()

  if f.kind == "CHALLENGE" then
    -- The token is proof that we can receive at the address we claimed. It is
    -- opaque: echo it back untouched and never look inside.
    send({
      type = protocol.T.JOIN,
      token_raw = f.token_raw,
      user = config.current.user,
      host = vim.uv.os_gethostname(),
    })
  elseif f.kind == "WELCOME" then
    local was_online = M.state.status == "online"
    M.state.status = "online"
    backoff = nil
    M.state.id = f.id
    adopt(f)
    if not was_online then
      local c = config.current
      vim.schedule(function()
        notify(("connected to %s:%d"):format(c.host, c.port))
      end)
    end
  elseif f.kind == "STATE" then
    -- A State frame is proof of life as well as a mode. Arriving here at all
    -- is what keeps us online; the server sends one every couple of seconds
    -- whether or not anything changed.
    if M.state.status ~= "online" then
      M.state.status = "online"
      backoff = nil
      announce()
    end
    if f.wants_pong then
      send({ type = protocol.T.PONG })
    end
    adopt(f)
  elseif f.kind == "ROSTER_ENTRY" then
    if f.index == 0 then
      roster_partial = {}
    end
    if roster_partial then
      table.insert(roster_partial, { id = f.id, user = f.user, host = f.host })
      if #roster_partial >= f.count then
        M.state.peers = roster_partial
        roster_partial = nil
        announce()
      end
    end
  end
end

--- Broadcast a local mode change, unless it is one the server just forced on us.
---@param mode string  a normalized mode
function M.send_mode(mode)
  -- The loop guard: never report back a change we made because we were told to.
  -- Consumed even while offline, so a leftover expectation cannot outlive the
  -- disconnection and swallow a genuine change afterwards.
  if apply.consume(mode) then
    return
  end

  -- While offline there is no global mode to have an opinion about.
  if M.state.status ~= "online" then
    return
  end

  -- Nor re-report what we already told it.
  if mode == last_sent then
    return
  end
  last_sent = mode

  -- Update our own view optimistically. The server deliberately does not echo
  -- a change back to whoever caused it, so this is the only chance we get.
  M.state.mode = mode
  M.state.by = config.current.user

  send({ type = protocol.T.SET_MODE, mode = mode })
  announce()
end

--- Ask for the roster. It is not pushed: broadcasting one on every join and
--- leave was an O(n) amplifier on the server, so it is sent only on request.
function M.request_roster()
  if M.state.status == "online" then
    send({ type = protocol.T.GET_ROSTER })
  end
end

local function say_hello()
  last_hello = vim.uv.now()
  M.state.status = M.state.status == "online" and "online" or "connecting"
  send({
    type = protocol.T.HELLO,
    user = config.current.user,
    host = vim.uv.os_gethostname(),
  })
end

--- One tick: chase the handshake while offline, watch for silence while on.
local function tick()
  if not want_connection then
    return
  end

  local now = vim.uv.now()

  if M.state.status == "online" then
    if last_heard and now - last_heard > LIVENESS_MS then
      go_offline()
      backoff = nil
      say_hello()
    end
    return
  end

  -- Still trying to get in. Back off so a server that is genuinely down is not
  -- hammered -- but only here: once online, the server's own refresh is the
  -- liveness signal and a long backoff would make one lost datagram look like
  -- a dead server.
  local c = config.current
  backoff = backoff or c.reconnect.min
  if not last_hello or now - last_hello >= backoff then
    say_hello()
    backoff = math.min(backoff * 2, c.reconnect.max)
  end
end

local function close_socket()
  if handle and not handle:is_closing() then
    handle:close()
  end
  handle = nil
end

local function clear_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

function M.connect()
  if handle then
    return
  end
  want_connection = true
  backoff = nil
  last_hello = nil
  last_heard = nil

  local sock = vim.uv.new_udp()
  handle = sock

  -- Bound explicitly so replies have somewhere to land. luv wants a numeric
  -- address and raises rather than reporting to a callback, so a bad `host` in
  -- the config would otherwise throw straight out of `setup()`.
  local ok, err = pcall(function()
    sock:bind("0.0.0.0", 0)
    sock:recv_start(function(recv_err, data)
      if handle ~= sock then
        return
      end
      -- `data` is nil on an empty read, which luv uses to mean "nothing right
      -- now" rather than an error.
      if recv_err or not data then
        return
      end
      local f = protocol.decode(data)
      if f then
        vim.schedule(function()
          if handle == sock then
            handle_frame(f)
          end
        end)
      end
    end)
  end)

  if not ok then
    close_socket()
    M.state.status = "offline"
    local c = config.current
    vim.schedule(function()
      notify(
        ("cannot use %s:%d — %s (the host must be a numeric address)"):format(
          c.host,
          c.port,
          tostring(err)
        ),
        vim.log.levels.ERROR
      )
    end)
    return
  end

  clear_timer()
  timer = vim.uv.new_timer()
  timer:start(0, TICK_MS, tick)
end

function M.disconnect()
  want_connection = false
  clear_timer()
  -- Say so, rather than just going quiet. The server would time us out in six
  -- seconds anyway, but leaving cleanly frees the slot at once and stops
  -- everyone else being told about a mode we are no longer subject to.
  send({ type = protocol.T.BYE })
  close_socket()
  go_offline()
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
