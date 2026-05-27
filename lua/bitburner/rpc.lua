local state = require('bitburner.state')

local M = {}

function M.dbg(msg)
  if state.config.debug then
    vim.notify('[bitburner:debug] ' .. msg, vim.log.levels.WARN)
  end
end

local function next_id()
  state._id = state._id + 1
  return state._id
end

function M.rpc(method, params, callback)
  if not state.conn then
    if callback then callback(nil, 'not connected') end
    return
  end
  local id = next_id()
  state._pending[id] = callback or function() end
  state.conn:send(vim.json.encode({
    jsonrpc = '2.0',
    id      = id,
    method  = method,
    params  = params or {},
  }))
end

function M.on_message(_, raw)
  M.dbg('raw: ' .. raw)
  local ok, data = pcall(vim.json.decode, raw)
  if not ok then
    M.dbg('json decode failed: ' .. tostring(data))
    return
  end
  local id = data.id
  M.dbg('id=' .. vim.inspect(id) .. ' pending=' .. vim.inspect(vim.tbl_keys(state._pending)))
  if id and state._pending[id] then
    local cb = state._pending[id]
    state._pending[id] = nil
    cb(data.result, data.error)
  else
    M.dbg('no pending callback for id=' .. vim.inspect(id))
  end
end

function M.flush_pending(err)
  for _, cb in pairs(state._pending) do
    pcall(cb, nil, err)
  end
  state._pending = {}
end

return M
