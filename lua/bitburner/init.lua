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

function M.setup(opts)
  opts = opts or {}
  _state.config = vim.tbl_deep_extend('force', _state.config, opts)
  if _state.config.sync_root then
    _state.config.sync_root = vim.fn.fnamemodify(_state.config.sync_root, ':p'):gsub('/$', '')
  end
  setup_autocmds()
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
