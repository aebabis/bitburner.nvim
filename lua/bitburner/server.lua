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
  sync.calculate_ram_for_buf()
end

function M.on_close(conn)
  if state.conn == conn then
    state.conn = nil
    rpc_mod.flush_pending('disconnected')
    M.stop_pull_timer()
    M.stop_info_timer()
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
