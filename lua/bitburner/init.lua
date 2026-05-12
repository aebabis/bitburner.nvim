local M = {}

local state   = require('bitburner.state')
local rpc_mod = require('bitburner.rpc')
local fs      = require('bitburner.fs')
local sync    = require('bitburner.sync')
local srv     = require('bitburner.server')

-- Delegate sync commands to sync module
M.push        = sync.push
M.pull        = sync.pull
M.pull_file   = sync.pull_file
M.diff        = sync.diff
M.sync        = sync.sync
M.rm          = sync.rm
M.gen_companion = sync.gen_companion

-- Project config (.bitburner.json) ----------------------------------------

local function find_project_config()
  local dir = vim.fn.getcwd()
  while true do
    local path = dir .. '/.bitburner.json'
    if vim.fn.filereadable(path) == 1 then return path end
    local parent = vim.fn.fnamemodify(dir, ':h')
    if parent == dir then return nil end
    dir = parent
  end
end

local function project_root()
  local cfg = find_project_config()
  return cfg and vim.fn.fnamemodify(cfg, ':h') or vim.fn.getcwd()
end

-- TypeScript/JS definitions ------------------------------------------------

local function fetch_definitions(write_jsconfig)
  rpc_mod.rpc('getDefinitionFile', {}, function(result, err)
    if err or not result then
      vim.notify('[bitburner] getDefinitionFile failed: ' .. tostring(err), vim.log.levels.WARN)
      return
    end
    local root = project_root()
    local dir  = root .. '/.bitburner'
    vim.fn.mkdir(dir, 'p')

    local f = io.open(dir .. '/NetscriptDefinitions.d.ts', 'w')
    if not f then
      vim.notify('[bitburner] could not write to ' .. dir, vim.log.levels.ERROR)
      return
    end
    f:write(result)
    f:close()

    -- Expose all exported types globally so they work without imports.
    local seen = {}
    local type_names = {}
    -- Prepend newline so start-of-line patterns work even on the first line.
    local src = '\n' .. result
    for _, pat in ipairs({
      'export%s+interface%s+(%a[%w_]*)',
      'export%s+type%s+(%a[%w_]*)',
      'export%s+enum%s+(%a[%w_]*)',
      'export%s+declare%s+interface%s+(%a[%w_]*)',
      'export%s+declare%s+type%s+(%a[%w_]*)',
      'export%s+declare%s+enum%s+(%a[%w_]*)',
      '\ninterface%s+(%a[%w_]*)',
      '\ntype%s+(%a[%w_]*)',
      '\nenum%s+(%a[%w_]*)',
    }) do
      for name in src:gmatch(pat) do
        if not seen[name] then
          seen[name] = true
          table.insert(type_names, name)
        end
      end
    end
    table.sort(type_names)
    local gf = io.open(dir .. '/bitburner-globals.d.ts', 'w')
    if gf then
      local lines = { 'export {};', 'declare global {' }
      for _, name in ipairs(type_names) do
        table.insert(lines, string.format("  type %s = import('./NetscriptDefinitions').%s;", name, name))
      end
      table.insert(lines, '}')
      gf:write(table.concat(lines, '\n') .. '\n')
      gf:close()
    end

    if write_jsconfig then
      local jsconfig = root .. '/jsconfig.json'
      local config = { compilerOptions = { target = 'ES2022', lib = { 'ES2022' }, checkJs = false } }

      local ef = io.open(jsconfig, 'r')
      if ef then
        local ok, parsed = pcall(vim.json.decode, ef:read('*a'))
        ef:close()
        if ok and type(parsed) == 'table' then
          config = parsed
          config.compilerOptions = vim.tbl_deep_extend('keep', config.compilerOptions or {}, {
            target = 'ES2022', lib = { 'ES2022' }, checkJs = false,
          })
        end
      end

      -- TypeScript doesn't auto-include hidden directories; be explicit.
      -- If include wasn't set before, the default was "**/*" — preserve that.
      local include = config.include or {}
      local has_bb, has_glob = false, false
      for _, v in ipairs(include) do
        if v == '.bitburner/**/*.d.ts' then has_bb = true end
        if v == '**/*' then has_glob = true end
      end
      if not has_bb then table.insert(include, 1, '.bitburner/**/*.d.ts') end
      if not has_glob then table.insert(include, '**/*') end
      config.include = include

      local wf = io.open(jsconfig, 'w')
      if wf then
        wf:write(vim.json.encode(config) .. '\n')
        wf:close()
        vim.notify('[bitburner] updated jsconfig.json — restart your LSP to pick up NS types', vim.log.levels.INFO)
      end
    end
  end)
end

-- Setup & config -----------------------------------------------------------

local function setup_autocmds()
  local group = vim.api.nvim_create_augroup('BitburnerAutoPush', { clear = true })
  local auto_push = state.config.auto_push

  if auto_push == 'on_save' then
    vim.api.nvim_create_autocmd('BufWritePost', {
      group    = group,
      callback = function() sync.push() end,
    })
  elseif auto_push == 'on_exit_insert' then
    if not state._timer then
      state._timer = vim.uv.new_timer()
    end
    vim.api.nvim_create_autocmd('InsertLeave', {
      group    = group,
      callback = function()
        state._timer:stop()
        state._timer:start(500, 0, vim.schedule_wrap(function()
          sync.push()
        end))
      end,
    })
  end

  vim.api.nvim_create_autocmd('VimLeavePre', {
    group    = group,
    callback = function()
      srv.stop_info_timer()
      if state.conn   then state.conn:close() end
      if state.server then state.server:close() end
    end,
  })
end

local function load_project_config(path)
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), ''))
  end)
  if not ok then
    vim.notify('[bitburner] invalid .bitburner.json: ' .. path, vim.log.levels.ERROR)
    return nil
  end
  -- resolve sync_root relative to the config file's directory
  if data.sync_root then
    local dir = vim.fn.fnamemodify(path, ':h')
    data.sync_root = vim.fn.fnamemodify(dir .. '/' .. data.sync_root, ':p'):gsub('/$', '')
  end
  return data
end

local function apply_project_config(data)
  local old_port = state.config.port
  state.config = vim.tbl_deep_extend('force', state.config, data)
  setup_autocmds()
  if state.config.port ~= old_port then
    srv.start_server(state.config.port)
  end
end

local function detect_project()
  local cwd = vim.fn.getcwd()
  if vim.fn.filereadable(cwd .. '/NetscriptDefinitions.d.ts') == 1 then return true end
  if vim.fn.filereadable(cwd .. '/filesync.json') == 1 then return true end
  local pkg = cwd .. '/package.json'
  if vim.fn.filereadable(pkg) == 1 then
    local content = table.concat(vim.fn.readfile(pkg), '')
    if content:find('"bitburner"') or content:find('"@ns%-types/netscript"') then
      return true
    end
  end
  return false
end

local function on_vim_enter()
  local config_path = find_project_config()
  if config_path then
    local data = load_project_config(config_path)
    if data then apply_project_config(data) end
    if not state.server then
      srv.start_server(state.config.port)
    end
  elseif state.config.auto_detect and detect_project() then
    vim.notify('[bitburner] Bitburner project detected. Run :BitburnerInit to configure.', vim.log.levels.INFO)
  end
end

-- RAM statusline -----------------------------------------------------------

local function rel_time(t)
  if not t then return nil end
  local diff = os.time() - t
  if diff < 60    then return diff .. 's' end
  if diff < 3600  then return math.floor(diff / 60) .. 'm' end
  return math.floor(diff / 3600) .. 'h'
end

local function setup_ram_autocmds()
  local group = vim.api.nvim_create_augroup('BitburnerRam', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost' }, {
    group    = group,
    callback = sync.calculate_ram_for_buf,
  })
end

-- Public API ---------------------------------------------------------------

function M.setup(opts)
  opts = opts or {}
  state.config = vim.tbl_deep_extend('force', state.config, opts)
  if state.config.sync_root then
    state.config.sync_root = vim.fn.fnamemodify(state.config.sync_root, ':p'):gsub('/$', '')
  end
  setup_autocmds()
  setup_ram_autocmds()
  vim.api.nvim_set_hl(0, 'BitburnerRam',      { link = 'DiagnosticInfo',  default = true })
  vim.api.nvim_set_hl(0, 'BitburnerRamError', { link = 'DiagnosticError', default = true })
  vim.api.nvim_create_autocmd('VimEnter', {
    group    = vim.api.nvim_create_augroup('BitburnerProjectLoad', { clear = true }),
    once     = true,
    callback = on_vim_enter,
  })
end

function M.connect(port)
  srv.start_server(port and tonumber(port) or state.config.port)
end

function M.disconnect()
  srv.stop_pull_timer()
  srv.stop_info_timer()
  srv.stop_disk_poll()
  if state.conn then
    state.conn:close()
    state.conn = nil
  end
  if state.server then
    state.server:close()
    state.server = nil
  end
  vim.notify('[bitburner] server stopped', vim.log.levels.INFO)
end

function M.init()
  local wizard = {}

  local function write_and_apply()
    local path = vim.fn.getcwd() .. '/.bitburner.json'
    -- store sync_root as relative so the file is portable
    local out = vim.deepcopy(wizard)
    if out.sync_root then
      out.sync_root = vim.fn.fnamemodify(out.sync_root, ':.')
    end
    local ok, err = pcall(vim.fn.writefile, { vim.json.encode(out) }, path)
    if not ok then
      vim.notify('[bitburner] failed to write config: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.notify('[bitburner] wrote ' .. path, vim.log.levels.INFO)

    local gitignore_path = vim.fn.getcwd() .. '/.gitignore'
    local entries = { '/.bitburner.json', '/.bitburner/' }
    local existing = {}
    local gf = io.open(gitignore_path, 'r')
    if gf then
      for line in gf:lines() do existing[line] = true end
      gf:close()
    end
    local added = {}
    local af = io.open(gitignore_path, 'a')
    if af then
      for _, entry in ipairs(entries) do
        if not existing[entry] then
          af:write(entry .. '\n')
          table.insert(added, entry)
        end
      end
      af:close()
    end
    if #added > 0 then
      vim.notify('[bitburner] added to .gitignore: ' .. table.concat(added, ', '), vim.log.levels.INFO)
    end

    apply_project_config(wizard)
    -- treat init as a connection event if the game is already connected
    if state.conn then
      if state.config.push_all_on_connect then
        state._queue = {}
        sync.push_all()
      else
        sync.flush_queue()
      end
    end
  end

  local function ask_server()
    vim.ui.input({ prompt = 'default_server [home]: ' }, function(v)
      wizard.default_server = (v and v ~= '') and v or 'home'
      write_and_apply()
    end)
  end

  local function ask_auto_pull_interval()
    vim.ui.input({ prompt = 'auto_pull_interval in ms [5000]: ' }, function(v)
      wizard.auto_pull_interval = tonumber(v) or 5000
      ask_server()
    end)
  end

  local function ask_auto_pull()
    vim.ui.input({ prompt = 'auto_pull (poll / none) [none]: ' }, function(v)
      if v == 'poll' then
        wizard.auto_pull = 'poll'
        ask_auto_pull_interval()
      else
        wizard.auto_pull = false
        ask_server()
      end
    end)
  end

  local function ask_restart_if_running()
    vim.ui.input({ prompt = 'restart_if_running (y/n) [n]: ' }, function(v)
      wizard.restart_if_running = (v == 'y' or v == 'yes')
      ask_auto_pull()
    end)
  end

  local function ask_run_on_push()
    vim.ui.input({ prompt = 'run_on_push script path (blank to disable): ' }, function(v)
      wizard.run_on_push = (v ~= nil and v ~= '') and v or false
      ask_restart_if_running()
    end)
  end

  local function ask_push_all_on_connect()
    vim.ui.input({ prompt = 'push_all_on_connect (y/n) [n]: ' }, function(v)
      wizard.push_all_on_connect = (v == 'y' or v == 'yes')
      ask_run_on_push()
    end)
  end

  local function ask_auto_push()
    vim.ui.input({ prompt = 'auto_push (on_save / on_exit_insert / none) [none]: ' }, function(v)
      if v == 'on_save' or v == 'on_exit_insert' then
        wizard.auto_push = v
      else
        wizard.auto_push = false
      end
      ask_push_all_on_connect()
    end)
  end

  local function ask_port()
    vim.ui.input({ prompt = 'port [12525]: ' }, function(v)
      wizard.port = tonumber(v) or 12525
      ask_auto_push()
    end)
  end

  vim.ui.input({ prompt = 'sync_root (path relative to cwd): ' }, function(v)
    if not v or v == '' then
      vim.notify('[bitburner] init cancelled', vim.log.levels.WARN)
      return
    end
    wizard.sync_root = vim.fn.fnamemodify(vim.fn.getcwd() .. '/' .. v, ':p'):gsub('/$', '')
    ask_port()
  end)
end

function M.get_definitions()
  if not state.conn then
    vim.notify('[bitburner] game not connected', vim.log.levels.WARN)
    return
  end
  fetch_definitions(true)
end

function M.ram_statusline()
  if not state.conn then return '' end
  local buf_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p')
  local ram = state._ram_cache[buf_path]
  if ram == nil then return '' end

  local push_t = rel_time(state._file_push_time[buf_path])
  local pull_t = rel_time(state._file_pull_time[buf_path])

  local inner, hl
  if ram == false then
    inner = 'error'
    hl    = 'BitburnerRamError'
  else
    inner = ram
    if push_t then inner = inner .. ' ↑' .. push_t end
    if pull_t then inner = inner .. ' ↓' .. pull_t end
    hl = 'BitburnerRam'
  end

  return '%#' .. hl .. '#(' .. inner .. ')%*'
end

local function fmt_money(n)
  if     n >= 1e12 then return string.format('$%.2ft', n / 1e12)
  elseif n >= 1e9  then return string.format('$%.2fb', n / 1e9)
  elseif n >= 1e6  then return string.format('$%.2fm', n / 1e6)
  elseif n >= 1e3  then return string.format('$%.2fk', n / 1e3)
  else                   return string.format('$%.0f',  n)
  end
end

function M.statusline()
  local buf_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p')
  if state._ram_cache[buf_path] == nil then return '' end
  if not state.server then
    return 'BB:off'
  elseif not state.conn then
    local n = vim.tbl_count(state._queue)
    return n > 0 and ('BB:waiting[' .. n .. ']') or 'BB:waiting'
  end

  local info = state._info
  if info then
    if info.status then
      return 'BB:connected | ' .. info.status
    end
    local parts = { 'BB:connected' }
    if info.ram then
      parts[#parts+1] = string.format('home:%.0f/%.0fGB', info.ram.used, info.ram.max)
    end
    if info.player then
      parts[#parts+1] = fmt_money(info.player.money)
      parts[#parts+1] = 'hk:' .. info.player.hacking
    end
    if info.reset then
      parts[#parts+1] = 'BN' .. info.reset.bitnode
    end
    return table.concat(parts, ' | ')
  end
  return 'BB:connected'
end

return M
