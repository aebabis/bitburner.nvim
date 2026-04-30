local state = require('bitburner.state')

local M = {}

function M.matches_ignore(rel_path)
  if vim.startswith(rel_path, '.bitburner/') then return true end
  for _, pattern in ipairs(state.config.sync_ignore) do
    if vim.fn.match(rel_path, vim.fn.glob2regpat(pattern)) >= 0 then
      return true
    end
  end
  return false
end

function M.write_local_file(rel_path, content)
  local path = state.config.sync_root .. '/' .. rel_path
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local f = io.open(path, 'w')
  if not f then
    vim.notify('[bitburner] could not write ' .. path, vim.log.levels.ERROR)
    return
  end
  f:write(content)
  f:close()
  state._file_pull_time[path] = os.time()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
      vim.api.nvim_buf_call(buf, function() vim.cmd('edit!') end)
    end
  end
end

function M.read_local_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read('*a')
  f:close()
  return content
end

function M.buf_is_modified(path)
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

return M
