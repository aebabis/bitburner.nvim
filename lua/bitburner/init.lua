local M = {}

local _state = {
  config = {
    port                = 12525,
    sync_root           = nil,
    sync_ignore         = { '*.md', '*.json', 'node_modules/**' },
    default_server      = 'home',
    auto_push           = false,   -- false | "on_save" | "on_exit_insert"
    notify_on_push      = false,
    push_all_on_connect = false,
    auto_detect         = false,
  },
  server   = nil,
  conn     = nil,
  _id      = 0,
  _pending = {},
  _queue   = {},  -- keyed by "filename\0server" to deduplicate
  _timer   = nil,
}

local function next_id()
  _state._id = _state._id + 1
  return _state._id
end

local function rpc(method, params, callback)
  if not _state.conn then
    if callback then callback(nil, 'not connected') end
    return
  end
  local id = next_id()
  _state._pending[id] = callback or function() end
  _state.conn:send(vim.json.encode({
    jsonrpc = '2.0',
    id      = id,
    method  = method,
    params  = params or {},
  }))
end

local function matches_ignore(rel_path)
  for _, pattern in ipairs(_state.config.sync_ignore) do
    if vim.fn.match(rel_path, vim.fn.glob2regpat(pattern)) >= 0 then
      return true
    end
  end
  return false
end

local function do_push_file(filename, content, server)
  rpc('pushFile', { filename = filename, content = content, server = server }, function(result, err)
    if err then
      vim.notify('[bitburner] push failed: ' .. filename .. ': ' .. vim.inspect(err), vim.log.levels.ERROR)
    elseif _state.config.notify_on_push then
      vim.notify('[bitburner] pushed ' .. filename, vim.log.levels.INFO)
    end
  end)
end

local function flush_queue()
  local queue = _state._queue
  _state._queue = {}
  for _, item in pairs(queue) do
    do_push_file(item.filename, item.content, item.server)
  end
end

local function push_all()
  local sync_root = _state.config.sync_root
  if not sync_root then return end
  local paths = vim.fn.globpath(sync_root, '**/*', false, true)
  for _, path in ipairs(paths) do
    if vim.fn.isdirectory(path) == 0 then
      local rel_path = path:sub(#sync_root + 2)
      if not matches_ignore(rel_path) then
        local ok, lines = pcall(vim.fn.readfile, path)
        if ok then
          do_push_file('/' .. rel_path, table.concat(lines, '\n'), _state.config.default_server)
        end
      end
    end
  end
end

local function on_message(_, raw)
  local ok, data = pcall(vim.json.decode, raw)
  if not ok then return end
  local id = data.id
  if id and _state._pending[id] then
    local cb = _state._pending[id]
    _state._pending[id] = nil
    cb(data.result, data.error)
  end
end

local function on_connect(conn)
  _state.conn = conn
  vim.notify('[bitburner] game connected', vim.log.levels.INFO)
  if _state.config.push_all_on_connect then
    _state._queue = {}
    push_all()
  else
    flush_queue()
  end
end

local function on_close(conn)
  if _state.conn == conn then
    _state.conn = nil
    vim.notify('[bitburner] game disconnected', vim.log.levels.WARN)
  end
end

local function on_error(err)
  vim.notify('[bitburner] websocket error: ' .. tostring(err), vim.log.levels.ERROR)
end

local function start_server(port)
  if _state.server then
    _state.server:close()
    _state.server = nil
    _state.conn   = nil
  end
  _state.config.port = port
  _state.server = require('websocket').listen(port, {
    host       = '0.0.0.0',
    on_connect = on_connect,
    on_message = on_message,
    on_close   = on_close,
    on_error   = on_error,
  })
  vim.notify('[bitburner] listening on port ' .. port, vim.log.levels.INFO)
end

local function setup_autocmds()
  local group = vim.api.nvim_create_augroup('BitburnerAutoPush', { clear = true })
  local auto_push = _state.config.auto_push

  if auto_push == 'on_save' then
    vim.api.nvim_create_autocmd('BufWritePost', {
      group    = group,
      callback = function() M.push() end,
    })
  elseif auto_push == 'on_exit_insert' then
    if not _state._timer then
      _state._timer = vim.uv.new_timer()
    end
    vim.api.nvim_create_autocmd('InsertLeave', {
      group    = group,
      callback = function()
        _state._timer:stop()
        _state._timer:start(500, 0, vim.schedule_wrap(function()
          M.push()
        end))
      end,
    })
  end
end

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
  local old_port = _state.config.port
  _state.config = vim.tbl_deep_extend('force', _state.config, data)
  setup_autocmds()
  if _state.config.port ~= old_port then
    start_server(_state.config.port)
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
  elseif _state.config.auto_detect and detect_project() then
    vim.notify('[bitburner] Bitburner project detected. Run :BitburnerInit to configure.', vim.log.levels.INFO)
  end
end

-- Public API ---------------------------------------------------------------

function M.setup(opts)
  opts = opts or {}
  _state.config = vim.tbl_deep_extend('force', _state.config, opts)
  if _state.config.sync_root then
    _state.config.sync_root = vim.fn.fnamemodify(_state.config.sync_root, ':p'):gsub('/$', '')
  end
  setup_autocmds()
  vim.api.nvim_create_autocmd('VimEnter', {
    group    = vim.api.nvim_create_augroup('BitburnerProjectLoad', { clear = true }),
    once     = true,
    callback = on_vim_enter,
  })
  start_server(_state.config.port)
end

function M.connect(port)
  start_server(port and tonumber(port) or _state.config.port)
end

function M.disconnect()
  if _state.conn then
    _state.conn:close()
    _state.conn = nil
  end
  if _state.server then
    _state.server:close()
    _state.server = nil
  end
  vim.notify('[bitburner] server stopped', vim.log.levels.INFO)
end

function M.push()
  local sync_root = _state.config.sync_root
  if not sync_root then
    vim.notify('[bitburner] sync_root not configured', vim.log.levels.ERROR)
    return
  end

  local buf_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p')
  if buf_path == '' then return end
  if not vim.startswith(buf_path, sync_root .. '/') then return end

  local rel_path = buf_path:sub(#sync_root + 2)
  if matches_ignore(rel_path) then return end

  local content  = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  local filename = '/' .. rel_path
  local server   = _state.config.default_server

  if not _state.conn then
    _state._queue[filename .. '\0' .. server] = { filename = filename, content = content, server = server }
    vim.notify('[bitburner] queued ' .. filename .. ' (not connected)', vim.log.levels.INFO)
    return
  end

  do_push_file(filename, content, server)
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
    apply_project_config(wizard)
  end

  local function ask_server()
    vim.ui.input({ prompt = 'default_server [home]: ' }, function(v)
      wizard.default_server = (v and v ~= '') and v or 'home'
      write_and_apply()
    end)
  end

  local function ask_auto_push()
    vim.ui.input({ prompt = 'auto_push (on_save / on_exit_insert / none) [none]: ' }, function(v)
      if v == 'on_save' or v == 'on_exit_insert' then
        wizard.auto_push = v
      else
        wizard.auto_push = false
      end
      ask_server()
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

function M.statusline()
  if not _state.server then
    return 'BB:off'
  elseif _state.conn then
    return 'BB:connected'
  else
    local n = vim.tbl_count(_state._queue)
    return n > 0 and ('BB:waiting[' .. n .. ']') or 'BB:waiting'
  end
end

return M
