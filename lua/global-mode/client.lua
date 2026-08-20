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

--- Always scheduled, never synchronous.
---
--- `go_offline` is reached from `tick`, which is a `vim.uv` timer callback --
--- a fast event context, where `nvim_echo` is forbidden. Notifying from there
--- raised E5560 and unwound `tick` mid-function, so the `say_hello` that was
--- meant to follow the disconnect was skipped. Losing the server is the
--- ordinary case, not an exotic one, so this was firing for everybody.
local function notify(msg, level)
  if config.current.notify then
    vim.schedule(function()
      vim.notify("global-mode: " .. msg, level or vim.log.levels.INFO)
    end)
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

--- How long to sit on a mode change before reporting it.
---
--- Mode changes arrive in bursts: every entry in the key table begins with
--- CTRL-\ CTRL-N, so walking into visual fires normal and then visual a
--- millisecond apart. Sending both puts two datagrams on the wire back to
--- back, which are also the two most likely to be reordered in flight -- and a
--- reordered pair leaves everybody in the mode the user just left.
---
--- Coalescing them is the same trick the server uses on its fan-out, in the
--- other direction: report the mode you ended up in, not every mode you passed
--- through. The counter below then makes the surviving reports orderable, so
--- the two changes cover the problem from both ends.
local DEBOUNCE_MS = 20

--- Our own report counter, which is what lets the server order them.
---
--- Reset on going offline, because the server forgets its side on every
--- handshake. If only one end reset, every report would be discarded as stale
--- from then on -- silently, with the client online and apparently well.
local mode_seq = 0
local mode_timer = nil
local pending_mode = nil

local function clear_mode_timer()
  if mode_timer then
    mode_timer:stop()
    mode_timer:close()
    mode_timer = nil
  end
end

--- Send whatever mode we ended up in. Runs in a timer callback, so it must
--- stay in fast-context-safe territory: no vim.notify, no autocmds.
local function flush_mode()
  clear_mode_timer()
  local mode = pending_mode
  pending_mode = nil
  if mode == nil or M.state.status ~= "online" then
    return
  end
  mode_seq = mode_seq + 1
  send({ type = protocol.T.SET_MODE, mode = mode, seq = mode_seq })
end

--- Adopt the server's account of the world.
---
--- Frames carry full state and the rule is one line: take anything at least as
--- new as what we have. Ordering does not matter, duplicates are no-ops, and a
--- frame lost in transit is replaced by the next refresh -- which is why the
--- old client's resync logic is not here. There is nothing to resync from,
--- because nothing is ever incremental.
---
--- `Fresh` marks a frame that starts a new session rather than continuing one.
--- Only `Welcome` is fresh: it answers a handshake this client just performed,
--- so its seq is authoritative even when it counts *backwards* -- which is
--- exactly what a restarted server sends.
local function adopt(f, fresh)
  -- Beyond the server's own ceiling (Seq_Type is 0 .. 2**62) and beyond what a
  -- Lua double holds exactly. Nothing legitimate is up here: at a thousand
  -- mode changes a second the real server needs ~285,000 years to arrive. A
  -- frame claiming otherwise is forged, and adopting it would raise the
  -- high-water mark past anything the real server can ever beat.
  if f.payload > 2 ^ 53 then
    return
  end
  -- Strictly greater, not "at least as new". A refresh that left the server
  -- just before this editor's own Set_Mode arrived carries the *previous*
  -- mode at an equal seq, and adopting it dragged the editor back into the
  -- mode it had just left. Equal seq from one server means an identical
  -- frame, so requiring strictly-greater discards only duplicates.
  if not fresh and f.payload <= M.state.seq then
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
  clear_mode_timer()
  pending_mode = nil
  -- Matching Forget_Seen on the server, which resets on every handshake.
  mode_seq = 0
  M.state.mode = nil
  M.state.by = nil
  -- And the counter, which is the one that bites. A server that restarts
  -- counts from zero again; a client that kept a high-water mark from the
  -- previous instance rejected every frame the new one sent -- Welcome
  -- included -- and sat "online" while following nobody, forever. Three
  -- independent reviews reached this line by three different routes.
  M.state.seq = 0
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
    adopt(f, true)
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
    -- Keyed by index rather than appended, because counting arrivals trusts
    -- the network to deliver each entry exactly once. A duplicated datagram
    -- stood in for a lost one and published a roster with somebody listed
    -- twice and somebody else missing, presented as complete; an entry that
    -- overtook index 0 was dropped and the set then never reached its count.
    if f.index == 0 or (roster_partial and roster_partial.count ~= f.count) then
      roster_partial = { count = f.count, seen = {} }
    end
    if roster_partial and f.index < f.count then
      roster_partial.seen[f.index] = { id = f.id, user = f.user, host = f.host }
      local whole = {}
      for i = 0, f.count - 1 do
        if not roster_partial.seen[i] then
          whole = nil
          break
        end
        whole[i + 1] = roster_partial.seen[i]
      end
      if whole then
        M.state.peers = whole
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
  -- This stays inline: only the datagram waits, never the statusline.
  M.state.mode = mode
  M.state.by = config.current.user

  -- Arm on the first change of a burst and leave it armed, rather than
  -- restarting the window on each one. A restarting window would never fire
  -- under a continuous stream; this way the report is always sent within
  -- DEBOUNCE_MS of the change that began the burst, carrying whichever mode
  -- the burst ended on.
  pending_mode = mode
  if not mode_timer then
    mode_timer = vim.uv.new_timer()
    mode_timer:start(DEBOUNCE_MS, 0, flush_mode)
  end
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
  clear_mode_timer()
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
    sock:recv_start(function(recv_err, data, addr)
      if handle ~= sock then
        return
      end
      -- Anything not from the server is not the server. The socket is bound
      -- to a wildcard port that any local process can reach, and one forged
      -- State frame was enough to drag this editor into a mode nobody chose
      -- and -- before the bound above -- pin its seq past anything the real
      -- server could outrun. This does not defeat an on-path attacker, who
      -- can forge the source too; it stops strays, misdirected traffic and
      -- any unprivileged process that merely knows the port.
      local c = config.current
      if addr and (addr.ip ~= c.host or addr.port ~= c.port) then
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
