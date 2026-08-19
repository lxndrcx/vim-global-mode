if vim.g.loaded_global_mode then
  return
end
vim.g.loaded_global_mode = true

vim.api.nvim_create_user_command("GlobalModeConnect", function()
  require("global-mode").connect()
end, { desc = "Submit to the global mode" })

vim.api.nvim_create_user_command("GlobalModeDisconnect", function()
  require("global-mode").disconnect()
end, { desc = "Reclaim your own modal state" })

vim.api.nvim_create_user_command("GlobalModeStatus", function()
  vim.notify(require("global-mode").status())
end, { desc = "Report the global mode and who set it" })
