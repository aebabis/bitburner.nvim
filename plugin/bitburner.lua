vim.api.nvim_create_user_command('BitburnerConnect', function(opts)
  require('bitburner').connect(opts.args ~= '' and opts.args or nil)
end, { nargs = '?' })

vim.api.nvim_create_user_command('BitburnerDisconnect', function()
  require('bitburner').disconnect()
end, {})

vim.api.nvim_create_user_command('BitburnerPush', function()
  require('bitburner').push()
end, {})

vim.api.nvim_create_user_command('BitburnerInit', function()
  require('bitburner').init()
end, {})
