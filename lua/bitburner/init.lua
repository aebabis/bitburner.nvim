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
    auto_pull           = false,   -- false | "poll"
    auto_pull_interval  = 5000,    -- ms
    signal_on_push      = false,
    signal_file         = '/bitburner-nvim.txt',
    debug               = false,
  },
  server      = nil,
  conn        = nil,
  _id         = 0,
  _pending    = {},
  _queue      = {},  -- keyed by "filename\0server" to deduplicate
  _timer      = nil,
  _pull_timer = nil,
  _push_times = {},  -- filename -> vim.uv.now() when pushFile was sent
  _ram_cache  = {},  -- buf_path -> formatted RAM string
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
  _state._push_times[filename] = vim.uv.now()
  rpc('pushFile', { filename = filename, content = content, server = server }, function(result, err)
    if err then
      vim.notify('[bitburner] push failed: ' .. filename .. ': ' .. vim.inspect(err), vim.log.levels.ERROR)
    else
      if _state.config.notify_on_push then
        vim.notify('[bitburner] pushed ' .. filename, vim.log.levels.INFO)
      end
      if _state.config.signal_on_push and filename ~= _state.config.signal_file then
        rpc('pushFile', {
          filename = _state.config.signal_file,
          content  = tostring(os.time()),
          server   = server,
        }, nil)
      end
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

local function dbg(msg)
  if _state.config.debug then
    vim.notify('[bitburner:debug] ' .. msg, vim.log.levels.WARN)
  end
end

local function on_message(_, raw)
  dbg('raw: ' .. raw)
  local ok, data = pcall(vim.json.decode, raw)
  if not ok then return end
  local id = data.id
  dbg('id=' .. vim.inspect(id) .. ' pending=' .. vim.inspect(vim.tbl_keys(_state._pending)))
  if id and _state._pending[id] then
    local cb = _state._pending[id]
    _state._pending[id] = nil
    cb(data.result, data.error)
  end
end

local function buf_is_modified(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf)
      and vim.api.nvim_buf_get_name(buf) == path
      and vim.bo[buf].modified
    then
      return true
    end
  end
  return false
end

local function pull_silent()
  if not _state.conn or not _state.config.sync_root then return end
  local requested_at = vim.uv.now()
  rpc('getAllFiles', { server = _state.config.default_server }, function(result, err)
    if err or not result then return end
    for _, file in ipairs(result) do
      local rel_path   = file.filename:gsub('^/', '')
      local local_path = _state.config.sync_root .. '/' .. rel_path
      local push_time  = _state._push_times[file.filename]
      if push_time and push_time > requested_at then
        -- a push was sent after this pull request; game state is not settled
      elseif not buf_is_modified(local_path) then
        local existing = read_local_file(local_path)
        if existing ~= file.content then
          write_local_file(rel_path, file.content)
        end
      end
    end
  end)
end

local function start_pull_timer()
  if _state.config.auto_pull ~= 'poll' then return end
  if not _state._pull_timer then
    _state._pull_timer = vim.uv.new_timer()
  end
  local ms = _state.config.auto_pull_interval
  _state._pull_timer:start(ms, ms, vim.schedule_wrap(pull_silent))
end

local function stop_pull_timer()
  if _state._pull_timer then
    _state._pull_timer:stop()
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
  start_pull_timer()
end

local function on_close(conn)
  if _state.conn == conn then
    _state.conn = nil
    stop_pull_timer()
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

-- RAM calculation ----------------------------------------------------------

local function calculate_ram_for_buf()
  if not _state.conn then return end
  local sync_root = _state.config.sync_root
  if not sync_root then return end
  local buf_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p')
  if not vim.startswith(buf_path, sync_root .. '/') then return end
  local rel_path = buf_path:sub(#sync_root + 2)
  if matches_ignore(rel_path) then return end
  rpc('calculateRam', { filename = '/' .. rel_path, server = _state.config.default_server },
    function(result, err)
      if not err and result then
        _state._ram_cache[buf_path] = string.format('%.2f GB', result)
        vim.cmd('redrawstatus')
      end
    end)
end

local function setup_ram_autocmds()
  local group = vim.api.nvim_create_augroup('BitburnerRam', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost' }, {
    group    = group,
    callback = calculate_ram_for_buf,
  })
end

-- Public API ---------------------------------------------------------------

function M.setup(opts)
  opts = opts or {}
  _state.config = vim.tbl_deep_extend('force', _state.config, opts)
  if _state.config.sync_root then
    _state.config.sync_root = vim.fn.fnamemodify(_state.config.sync_root, ':p'):gsub('/$', '')
  end
  setup_autocmds()
  setup_ram_autocmds()
  vim.api.nvim_set_hl(0, 'BitburnerRam', { link = 'DiagnosticInfo', default = true })
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
  stop_pull_timer()
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
    -- treat init as a connection event if the game is already connected
    if _state.conn then
      if _state.config.push_all_on_connect then
        _state._queue = {}
        push_all()
      else
        flush_queue()
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

  local function ask_signal_on_push()
    vim.ui.input({ prompt = 'signal_on_push (y/n) [n]: ' }, function(v)
      wizard.signal_on_push = (v == 'y' or v == 'yes')
      ask_auto_pull()
    end)
  end

  local function ask_push_all_on_connect()
    vim.ui.input({ prompt = 'push_all_on_connect (y/n) [n]: ' }, function(v)
      wizard.push_all_on_connect = (v == 'y' or v == 'yes')
      ask_signal_on_push()
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

local function write_local_file(rel_path, content)
  local path = _state.config.sync_root .. '/' .. rel_path
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local f = assert(io.open(path, 'w'))
  f:write(content)
  f:close()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
      vim.api.nvim_buf_call(buf, function() vim.cmd('edit!') end)
    end
  end
end

local function read_local_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read('*a')
  f:close()
  return content
end

function M.pull()
  if not _state.conn then
    vim.notify('[bitburner] game not connected', vim.log.levels.WARN)
    return
  end
  local sync_root = _state.config.sync_root
  if not sync_root then
    vim.notify('[bitburner] sync_root not configured', vim.log.levels.ERROR)
    return
  end

  rpc('getAllFiles', { server = _state.config.default_server }, function(result, err)
    if err then
      vim.notify('[bitburner] pull failed: ' .. vim.inspect(err), vim.log.levels.ERROR)
      return
    end
    local written, skipped = 0, 0
    for _, file in ipairs(result or {}) do
      local rel_path = file.filename:gsub('^/', '')
      local local_path = sync_root .. '/' .. rel_path
      local existing = read_local_file(local_path)
      if existing ~= nil and existing ~= file.content then
        local choice = vim.fn.confirm(rel_path .. ' differs locally. Overwrite?', '&Yes\n&No', 2)
        if choice == 1 then
          write_local_file(rel_path, file.content)
          written = written + 1
        else
          skipped = skipped + 1
        end
      elseif existing == nil then
        write_local_file(rel_path, file.content)
        written = written + 1
      end
    end
    vim.notify(string.format('[bitburner] pull: wrote %d, skipped %d', written, skipped), vim.log.levels.INFO)
  end)
end

function M.pull_file()
  if not _state.conn then
    vim.notify('[bitburner] game not connected', vim.log.levels.WARN)
    return
  end
  local sync_root = _state.config.sync_root
  if not sync_root then
    vim.notify('[bitburner] sync_root not configured', vim.log.levels.ERROR)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local buf_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':p')
  if not vim.startswith(buf_path, sync_root .. '/') then
    vim.notify('[bitburner] file is outside sync_root', vim.log.levels.WARN)
    return
  end

  if vim.bo[buf].modified then
    local choice = vim.fn.confirm('Buffer has unsaved changes. Overwrite?', '&Yes\n&No', 2)
    if choice ~= 1 then return end
  end

  local rel_path = buf_path:sub(#sync_root + 2)
  rpc('getFile', { filename = '/' .. rel_path, server = _state.config.default_server }, function(result, err)
    if err or result == nil then
      vim.notify('[bitburner] pull failed: file not found in game', vim.log.levels.WARN)
      return
    end
    write_local_file(rel_path, result)
    vim.notify('[bitburner] pulled /' .. rel_path, vim.log.levels.INFO)
  end)
end

function M.diff()
  if not _state.conn then
    vim.notify('[bitburner] game not connected', vim.log.levels.WARN)
    return
  end
  local sync_root = _state.config.sync_root
  if not sync_root then
    vim.notify('[bitburner] sync_root not configured', vim.log.levels.ERROR)
    return
  end

  local source_buf = vim.api.nvim_get_current_buf()
  local buf_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(source_buf), ':p')
  if not vim.startswith(buf_path, sync_root .. '/') then
    vim.notify('[bitburner] file is outside sync_root', vim.log.levels.WARN)
    return
  end

  local rel_path = buf_path:sub(#sync_root + 2)
  local filename  = '/' .. rel_path

  rpc('getFile', { filename = filename, server = _state.config.default_server }, function(result, err)
    if err or result == nil then
      vim.notify('[bitburner] diff failed: file not found in game', vim.log.levels.WARN)
      return
    end

    local buf_name = 'bitburner://' .. filename
    local existing = vim.fn.bufnr(buf_name)
    if existing ~= -1 then vim.api.nvim_buf_delete(existing, { force = true }) end

    local game_lines = vim.split(result, '\n', { plain = true })
    if game_lines[#game_lines] == '' then table.remove(game_lines) end

    local game_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(game_buf, buf_name)
    vim.api.nvim_buf_set_lines(game_buf, 0, -1, false, game_lines)
    vim.bo[game_buf].buftype    = 'nofile'
    vim.bo[game_buf].bufhidden  = 'wipe'
    vim.bo[game_buf].modifiable = false
    local ft = vim.bo[source_buf].filetype
    if ft ~= '' then vim.bo[game_buf].filetype = ft end

    local local_win = vim.api.nvim_get_current_win()
    vim.cmd('diffthis')
    vim.cmd('vsplit')
    vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), game_buf)
    vim.cmd('diffthis')
    vim.api.nvim_set_current_win(local_win)
  end)
end

function M.sync()
  if not _state.conn then
    vim.notify('[bitburner] game not connected', vim.log.levels.WARN)
    return
  end
  local sync_root = _state.config.sync_root
  if not sync_root then
    vim.notify('[bitburner] sync_root not configured', vim.log.levels.ERROR)
    return
  end

  rpc('getAllFiles', { server = _state.config.default_server }, function(result, err)
    if err then
      vim.notify('[bitburner] sync failed: ' .. vim.inspect(err), vim.log.levels.ERROR)
      return
    end

    local game_files = {}
    for _, file in ipairs(result or {}) do
      game_files[file.filename:gsub('^/', '')] = file.content
    end

    local local_files = {}
    for _, path in ipairs(vim.fn.globpath(sync_root, '**/*', false, true)) do
      if vim.fn.isdirectory(path) == 0 then
        local rel_path = path:sub(#sync_root + 2)
        if not matches_ignore(rel_path) then
          local content = read_local_file(path)
          if content then local_files[rel_path] = content end
        end
      end
    end

    local pushed, pulled, conflicts = 0, 0, {}

    for rel_path, content in pairs(local_files) do
      if not game_files[rel_path] then
        do_push_file('/' .. rel_path, content, _state.config.default_server)
        pushed = pushed + 1
      elseif game_files[rel_path] ~= content then
        table.insert(conflicts, rel_path)
      end
    end

    for rel_path, content in pairs(game_files) do
      if not local_files[rel_path] then
        write_local_file(rel_path, content)
        pulled = pulled + 1
      end
    end

    local msg = string.format('[bitburner] sync: pushed %d, pulled %d', pushed, pulled)
    if #conflicts > 0 then
      msg = msg .. string.format('\n%d conflict(s) — use :BitburnerDiff to resolve:', #conflicts)
      for _, f in ipairs(conflicts) do msg = msg .. '\n  ' .. f end
      vim.notify(msg, vim.log.levels.WARN)
    else
      vim.notify(msg, vim.log.levels.INFO)
    end
  end)
end

function M.ram_statusline()
  if not _state.conn then return '' end
  local buf_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p')
  local ram = _state._ram_cache[buf_path]
  return ram and ('(' .. ram .. ')') or ''
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
