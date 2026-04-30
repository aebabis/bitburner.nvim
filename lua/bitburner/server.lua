local state   = require('bitburner.state')
local rpc_mod = require('bitburner.rpc')
local sync    = require('bitburner.sync')

local M = {}

function M.start_pull_timer()
  if state.config.auto_pull ~= 'poll' then return end
  if not state._pull_timer then
    state._pull_timer = vim.uv.new_timer()
  end
  local ms = state.config.auto_pull_interval
  state._pull_timer:start(ms, ms, vim.schedule_wrap(sync.pull_silent))
end

function M.stop_pull_timer()
  if state._pull_timer then
    state._pull_timer:stop()
  end
end

function M.start_info_timer()
  if not state.config.companion_tier or state.config.companion_tier < 1 then return end
  if not state._info_timer then
    state._info_timer = vim.uv.new_timer()
  end
  local ms     = state.config.companion_poll_ms
  local file   = state.config.companion_file
  local server = state.config.default_server
  state._info_timer:start(ms, ms, vim.schedule_wrap(function()
    rpc_mod.rpc('getFile', { filename = file, server = server }, function(result, err)
      if err or not result then return end
      local ok, data = pcall(vim.json.decode, result)
      if ok and type(data) == 'table' and data.v == 1 then
        state._info = data
        vim.cmd('redrawstatus')
      end
    end)
  end))
end

function M.stop_info_timer()
  if state._info_timer then
    state._info_timer:stop()
    state._info = nil
  end
end

function M.start_disk_poll()
  if not state.config.auto_push then return end
  if state._disk_poll_timer then return end
  state._disk_poll_timer = vim.uv.new_timer()
  -- delay=0 for first tick (populate mtimes), repeat=1000ms
  state._disk_poll_timer:start(0, 1000, vim.schedule_wrap(function()
    if not state.conn then return end
    local sync_root = state.config.sync_root
    if not sync_root then return end
    local now_ms  = vim.uv.now()
    local now_sec = os.time()
    for _, path in ipairs(vim.fn.globpath(sync_root, '**/*', false, true)) do
      if vim.fn.isdirectory(path) == 0 then
        local rel_path = path:sub(#sync_root + 2)
        if not fs.matches_ignore(rel_path) then
          local stat = vim.uv.fs_stat(path)
          if stat then
            local mtime = stat.mtime.sec * 1000 + math.floor(stat.mtime.nsec / 1e6)
            local known = state._disk_mtimes[path]
            state._disk_mtimes[path] = mtime
            if known ~= nil and mtime ~= known then
              local filename = '/' .. rel_path
              -- debounce: skip if we recently sent a push for this file
              local push_at = state._push_times[filename]
              if push_at and (now_ms - push_at) < 2000 then goto continue end
              -- debounce: skip if we recently wrote this file from a game pull
              local pull_at = state._file_pull_time[path]
              if pull_at and (now_sec - pull_at) < 3 then goto continue end
              -- external change — push it
              local ok, lines = pcall(vim.fn.readfile, path)
              if ok then
                sync.do_push_file(filename, table.concat(lines, '\n'), state.config.default_server)
              end
              ::continue::
            end
          end
        end
      end
    end
  end))
end

function M.stop_disk_poll()
  if state._disk_poll_timer then
    state._disk_poll_timer:stop()
    state._disk_poll_timer = nil
    state._disk_mtimes = {}
  end
end

function M.on_connect(conn)
  state.conn = conn
  vim.notify('[bitburner] game connected', vim.log.levels.INFO)
  if state.config.push_all_on_connect then
    state._queue = {}
    sync.push_all()
  else
    sync.flush_queue()
  end
  M.start_pull_timer()
  M.start_info_timer()
  M.start_disk_poll()
  sync.calculate_ram_for_buf()
end

function M.on_close(conn)
  if state.conn == conn then
    state.conn = nil
    rpc_mod.flush_pending('disconnected')
    M.stop_pull_timer()
    M.stop_info_timer()
    M.stop_disk_poll()
    vim.notify('[bitburner] game disconnected', vim.log.levels.WARN)
  end
end

function M.on_error(err)
  local msg = '[bitburner] websocket error: ' .. tostring(err)
  if tostring(err):find('bind failed') then
    local port = state.config.port
    local pids = vim.fn.systemlist('ss -Htlnp sport = :' .. port .. " 2>/dev/null | grep -oP 'pid=\\K[0-9]+'")
    if #pids > 0 then
      msg = msg .. ' (PID ' .. table.concat(pids, ',') .. ' is using the port — kill it or run :BitburnerConnect)'
    else
      msg = msg .. ' (another process may be using port ' .. port .. ')'
    end
  end
  vim.notify(msg, vim.log.levels.ERROR)
end

function M.start_server(port)
  if state.server then
    state.server:close()
    state.server = nil
    state.conn   = nil
    rpc_mod.flush_pending('server restarted')
  end
  state.config.port = port
  state.server = require('websocket').listen(port, {
    host       = '0.0.0.0',
    on_connect = M.on_connect,
    on_message = rpc_mod.on_message,
    on_close   = M.on_close,
    on_error   = M.on_error,
  })
  vim.notify('[bitburner] listening on port ' .. port, vim.log.levels.INFO)
end

return M
