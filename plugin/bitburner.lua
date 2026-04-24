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

vim.api.nvim_create_user_command('BitburnerPull', function()
  require('bitburner').pull()
end, {})

vim.api.nvim_create_user_command('BitburnerPullFile', function()
  require('bitburner').pull_file()
end, {})

vim.api.nvim_create_user_command('BitburnerDiff', function()
  require('bitburner').diff()
end, {})

vim.api.nvim_create_user_command('BitburnerSync', function()
  require('bitburner').sync()
end, {})

vim.api.nvim_create_user_command('BitburnerGetDefinitions', function()
  require('bitburner').get_definitions()
end, {})
