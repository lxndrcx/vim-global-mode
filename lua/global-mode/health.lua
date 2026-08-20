--- `:checkhealth global-mode`
local config = require("global-mode.config")
local protocol = require("global-mode.protocol")
local client = require("global-mode.client")

local M = {}

function M.check()
  vim.health.start("global-mode")

  if vim.fn.has("nvim-0.10") == 0 then
    vim.health.error("Neovim 0.10 or newer is required (vim.uv, vim.json)")
    return
  end
  vim.health.ok("Neovim " .. tostring(vim.version()))
  -- Resolved at setup rather than here: `vim.version` cannot be called from a
  -- fast event context, which is where the client would otherwise need it.
  -- It no longer travels on the wire -- the server never displayed it -- but
  -- it is still worth seeing locally.
  vim.health.info("plugin resolved nvim as: " .. tostring(config.nvim_version))

  local c = config.current
  vim.health.info(("server: %s:%d"):format(c.host, c.port))
  vim.health.info("identifying as: " .. c.user)

  local s = client.state
  if s.status == "online" then
    vim.health.ok(("connected as %s"):format(tostring(s.id or "?")))
    vim.health.info(
      ("global mode: %s (set by %s, seq %d)"):format(protocol.label(s.mode), s.by or "?", s.seq)
    )

    -- The roster is not pushed. Broadcasting one on every join and leave was
    -- an O(n) amplifier on the server, so it is sent only when asked for --
    -- and this is the only thing that ever asks.
    client.request_roster()
    vim.wait(500, function()
      return #s.peers > 0
    end, 20)

    local others = client.others()
    if #others == 0 then
      vim.health.info("no other editors connected — you are alone with your choices")
    else
      local names = {}
      for _, peer in ipairs(others) do
        table.insert(names, ("%s@%s"):format(peer.user, peer.host))
      end
      vim.health.info(("%d other editor(s): %s"):format(#others, table.concat(names, ", ")))
    end
  elseif s.status == "connecting" then
    vim.health.warn("connecting…")
  else
    vim.health.warn("offline", { "start the server, then :GlobalModeConnect" })
  end
end

return M
