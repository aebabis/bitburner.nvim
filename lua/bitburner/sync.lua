local state   = require('bitburner.state')
local rpc_mod = require('bitburner.rpc')
local fs      = require('bitburner.fs')

local M = {}

function M.do_push_file(filename, content, server, skip_cmd)
  state._push_times[filename] = vim.uv.now()
  rpc_mod.rpc('pushFile', { filename = filename, content = content, server = server }, function(result, err)
    if err then
      vim.notify('[bitburner] push failed: ' .. filename .. ': ' .. vim.inspect(err), vim.log.levels.ERROR)
    else
      local sync_root = state.config.sync_root
      if sync_root then
        state._file_push_time[sync_root .. filename] = os.time()
      end
      if state.config.notify_on_push then
        vim.notify('[bitburner] pushed ' .. filename, vim.log.levels.INFO)
      end
      local cfg = state.config
      if not skip_cmd and (cfg.run_on_push or cfg.restart_if_running) and filename ~= cfg.cmd_file then
        state._cmd_id = state._cmd_id + 1
        local cmd = { id = state._cmd_id }
        if cfg.restart_if_running then
          cmd.restart_if_running = true
          cmd.pushed = filename
        end
        if cfg.run_on_push then
          cmd.run = cfg.run_on_push
        end
        rpc_mod.rpc('pushFile', { filename = cfg.cmd_file, content = vim.json.encode(cmd), server = server }, nil)
      end
    end
  end)
end

function M.flush_queue()
  local queue = state._queue
  state._queue = {}
  for _, item in pairs(queue) do
    M.do_push_file(item.filename, item.content, item.server, true)
  end
end

function M.push_all()
  local sync_root = state.config.sync_root
  if not sync_root then return end
  local paths = vim.fn.globpath(sync_root, '**/*', false, true)
  for _, path in ipairs(paths) do
    if vim.fn.isdirectory(path) == 0 then
      local rel_path = path:sub(#sync_root + 2)
      if not fs.matches_ignore(rel_path) then
        local ok, lines = pcall(vim.fn.readfile, path)
        if ok then
          M.do_push_file('/' .. rel_path, table.concat(lines, '\n'), state.config.default_server, true)
        end
      end
    end
  end
end

function M.pull_silent()
  if not state.conn or not state.config.sync_root then return end
  local requested_at = vim.uv.now()
  rpc_mod.rpc('getAllFiles', { server = state.config.default_server }, function(result, err)
    if err or not result then return end
    for _, file in ipairs(result) do
      local rel_path = file.filename:gsub('^/', '')
      if not fs.matches_ignore(rel_path) then
        local local_path = state.config.sync_root .. '/' .. rel_path
        local push_time  = state._push_times[file.filename]
        if push_time and push_time > requested_at then
          -- a push was sent after this pull request; game state is not settled
        elseif not fs.buf_is_modified(local_path) then
          local existing = fs.read_local_file(local_path)
          if existing == nil then
            fs.write_local_file(rel_path, file.content)
            state._last_game[file.filename] = file.content
          elseif existing ~= file.content then
            local last_game = state._last_game[file.filename]
            if last_game ~= nil and existing == last_game then
              -- local still matches last game version; safe to update
              fs.write_local_file(rel_path, file.content)
              state._last_game[file.filename] = file.content
            else
              rpc_mod.dbg('pull_silent: skipping ' .. rel_path .. ' (locally modified since last pull)')
            end
          end
        end
      end
    end
  end)
end

function M.calculate_ram_for_buf()
  if not state.conn then return end
  local sync_root = state.config.sync_root
  if not sync_root then return end
  local buf_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p')
  if not vim.startswith(buf_path, sync_root .. '/') then return end
  local rel_path = buf_path:sub(#sync_root + 2)
  if fs.matches_ignore(rel_path) then return end
  local ext = buf_path:match('%.([^.]+)$')
  if not ({ js = true, ts = true, ns = true, script = true })[ext] then return end
  rpc_mod.rpc('calculateRam', { filename = '/' .. rel_path, server = state.config.default_server },
    function(result, err)
      if not err and result then
        state._ram_cache[buf_path] = string.format('%.2f GB', result)
      else
        state._ram_cache[buf_path] = false
      end
      vim.cmd('redrawstatus')
    end)
end

-- Public commands -----------------------------------------------------------

function M.push()
  local sync_root = state.config.sync_root
  if not sync_root then
    vim.notify('[bitburner] sync_root not configured', vim.log.levels.ERROR)
    return
  end

  local buf_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p')
  if buf_path == '' then return end
  if not vim.startswith(buf_path, sync_root .. '/') then return end

  local rel_path = buf_path:sub(#sync_root + 2)
  if fs.matches_ignore(rel_path) then return end

  local content  = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  local filename = '/' .. rel_path
  local server   = state.config.default_server

  if not state.conn then
    state._queue[filename .. '\0' .. server] = { filename = filename, content = content, server = server }
    vim.notify('[bitburner] queued ' .. filename .. ' (not connected)', vim.log.levels.INFO)
    return
  end

  M.do_push_file(filename, content, server)
end

function M.pull()
  if not state.conn then
    vim.notify('[bitburner] game not connected', vim.log.levels.WARN)
    return
  end
  local sync_root = state.config.sync_root
  if not sync_root then
    vim.notify('[bitburner] sync_root not configured', vim.log.levels.ERROR)
    return
  end

  rpc_mod.rpc('getAllFiles', { server = state.config.default_server }, function(result, err)
    if err then
      vim.notify('[bitburner] pull failed: ' .. vim.inspect(err), vim.log.levels.ERROR)
      return
    end
    local files = result or {}
    rpc_mod.dbg('pull: got ' .. #files .. ' files from game')
    local written, skipped = 0, 0
    for _, file in ipairs(files) do
      local rel_path = file.filename:gsub('^/', '')
      if fs.matches_ignore(rel_path) then
        rpc_mod.dbg('pull: ignoring ' .. rel_path)
      else
        local local_path = sync_root .. '/' .. rel_path
        local existing = fs.read_local_file(local_path)
        if existing ~= nil and existing ~= file.content then
          rpc_mod.dbg('pull: ' .. rel_path .. ' differs, prompting')
          local choice = vim.fn.confirm(rel_path .. ' differs locally. Overwrite?', '&Yes\n&No', 2)
          if choice == 1 then
            fs.write_local_file(rel_path, file.content)
            state._last_game[file.filename] = file.content
            written = written + 1
          else
            skipped = skipped + 1
          end
        elseif existing == nil then
          rpc_mod.dbg('pull: writing new file ' .. rel_path)
          fs.write_local_file(rel_path, file.content)
          state._last_game[file.filename] = file.content
          written = written + 1
        else
          rpc_mod.dbg('pull: ' .. rel_path .. ' already in sync')
        end
      end
    end
    vim.notify(string.format('[bitburner] pull: wrote %d, skipped %d', written, skipped), vim.log.levels.INFO)
  end)
end

function M.pull_file()
  if not state.conn then
    vim.notify('[bitburner] game not connected', vim.log.levels.WARN)
    return
  end
  local sync_root = state.config.sync_root
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
  rpc_mod.rpc('getFile', { filename = '/' .. rel_path, server = state.config.default_server }, function(result, err)
    if err or result == nil then
      vim.notify('[bitburner] pull failed: file not found in game', vim.log.levels.WARN)
      return
    end
    fs.write_local_file(rel_path, result)
    state._last_game['/' .. rel_path] = result
    vim.notify('[bitburner] pulled /' .. rel_path, vim.log.levels.INFO)
  end)
end

function M.diff()
  if not state.conn then
    vim.notify('[bitburner] game not connected', vim.log.levels.WARN)
    return
  end
  local sync_root = state.config.sync_root
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

  rpc_mod.rpc('getFile', { filename = filename, server = state.config.default_server }, function(result, err)
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
  if not state.conn then
    vim.notify('[bitburner] game not connected', vim.log.levels.WARN)
    return
  end
  local sync_root = state.config.sync_root
  if not sync_root then
    vim.notify('[bitburner] sync_root not configured', vim.log.levels.ERROR)
    return
  end

  rpc_mod.rpc('getAllFiles', { server = state.config.default_server }, function(result, err)
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
        if not fs.matches_ignore(rel_path) then
          local content = fs.read_local_file(path)
          if content then local_files[rel_path] = content end
        end
      end
    end

    local pushed, pulled, conflicts = 0, 0, {}

    for rel_path, content in pairs(local_files) do
      if not game_files[rel_path] then
        M.do_push_file('/' .. rel_path, content, state.config.default_server)
        pushed = pushed + 1
      elseif game_files[rel_path] ~= content then
        table.insert(conflicts, rel_path)
      end
    end

    for rel_path, content in pairs(game_files) do
      if not local_files[rel_path] and not fs.matches_ignore(rel_path) then
        fs.write_local_file(rel_path, content)
        state._last_game['/' .. rel_path] = content
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

function M.rm()
  if not state.conn then
    vim.notify('[bitburner] game not connected', vim.log.levels.WARN)
    return
  end
  local sync_root = state.config.sync_root
  if not sync_root then
    vim.notify('[bitburner] sync_root not configured', vim.log.levels.ERROR)
    return
  end
  local buf_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p')
  if not vim.startswith(buf_path, sync_root .. '/') then
    vim.notify('[bitburner] file is outside sync_root', vim.log.levels.WARN)
    return
  end
  local rel_path = buf_path:sub(#sync_root + 2)
  local filename = '/' .. rel_path
  local server   = state.config.default_server
  local choice = vim.fn.confirm(
    'Delete ' .. filename .. ' from game and disk?',
    '&Yes\n&Game only\n&Cancel', 3)
  if choice == 3 or choice == 0 then return end
  rpc_mod.rpc('deleteFile', { filename = filename, server = server }, function(result, err)
    if err then
      vim.notify('[bitburner] deleteFile failed: ' .. vim.inspect(err), vim.log.levels.ERROR)
      return
    end
    vim.notify('[bitburner] deleted ' .. filename .. ' from game', vim.log.levels.INFO)
    if choice == 1 then
      vim.fn.delete(buf_path)
      state._ram_cache[buf_path] = nil
      vim.cmd('bdelete!')
    end
  end)
end

-- Companion script ----------------------------------------------------------

local function gen_companion_script(tier)
  local has_cmd = state.config.run_on_push or state.config.restart_if_running
  local lines = {
    '/**',
    ' * bitburner-nvim companion script (tier ' .. tier .. ')',
    ' *',
    ' * Polls game state and writes it to OUTPUT_FILE so the bitburner.nvim',
    ' * plugin can display live info in your statusline.',
    ' *',
    ' * OUTPUT CONTRACT — call ns.write(OUTPUT_FILE, JSON.stringify(data), "w")',
    ' * on a regular interval where `data` matches this shape:',
    ' *',
    " *   {",
    " *     v:           1,            // schema version — must be 1",
    " *     ts:          Date.now(),",
    " *     ram:         { max: number, used: number },",
    " *     player:      { money: number, hacking: number },  // tier 2+",
    " *     procs:       [{ file, pid, threads }],            // tier 2+",
    " *     reset:       { bitnode, playtime },               // tier 3+",
    " *     status:      string,        // optional — shown verbatim in statusline",
    " *     last_cmd_id: number,        // ack for last command received",
    " *   }",
    ' *',
    ' * You can replace this script entirely as long as you honour the contract.',
    ' * Customise `formatStatus` below to change what appears in Neovim.',
    ' */',
    '',
    "const OUTPUT_FILE = '" .. state.config.companion_file .. "';",
    "const CMD_FILE    = '" .. state.config.cmd_file .. "';",
    'const INTERVAL_MS = ' .. state.config.companion_poll_ms .. ';',
    '',
  }

  if tier >= 2 then
    vim.list_extend(lines, {
      '/** Return the string shown in the Neovim statusline. */',
      'function formatStatus(data) {',
      "  const ram = `home:${Math.round(data.ram.used)}/${Math.round(data.ram.max)}GB`;",
      '  const money = formatMoney(data.player.money);',
      '  const hk = `hk:${data.player.hacking}`;',
      "  return [ram, money, hk].join(' | ');",
      '}',
      '',
      'function formatMoney(n) {',
      "  if (n >= 1e12) return `$${(n/1e12).toFixed(2)}t`;",
      "  if (n >= 1e9)  return `$${(n/1e9).toFixed(2)}b`;",
      "  if (n >= 1e6)  return `$${(n/1e6).toFixed(2)}m`;",
      "  if (n >= 1e3)  return `$${(n/1e3).toFixed(2)}k`;",
      "  return `$${Math.round(n)}`;",
      '}',
      '',
    })
  end

  vim.list_extend(lines, {
    '/** @param {NS} ns */',
    'export async function main(ns) {',
    "  ns.disableLog('ALL');",
    '  let lastCmdId = -1;',
    '  while (true) {',
    '    const data = { v: 1, ts: Date.now() };',
    '    data.ram = {',
    "      max:  ns.getServerMaxRam('home'),",
    "      used: ns.getServerUsedRam('home'),",
    '    };',
  })

  if tier >= 2 then
    vim.list_extend(lines, {
      '    const p = ns.getPlayer();',
      '    data.player = { money: p.money, hacking: p.skills.hacking };',
      "    data.procs = ns.ps('home').map(proc => ({",
      '      file: proc.filename, pid: proc.pid, threads: proc.threads, args: proc.args,',
      '    }));',
      '    data.status = formatStatus(data);',
    })
  end

  if tier >= 3 then
    vim.list_extend(lines, {
      '    const r = ns.getResetInfo();',
      '    data.reset = { bitnode: r.currentNode, playtime: r.totalPlaytime };',
    })
  end

  if has_cmd then
    vim.list_extend(lines, {
      '    const cmdRaw = ns.read(CMD_FILE);',
      '    if (cmdRaw) {',
      '      try {',
      '        const cmd = JSON.parse(cmdRaw);',
      '        if (cmd.id !== lastCmdId) {',
      '          lastCmdId = cmd.id;',
      '          if (cmd.restart_if_running && cmd.pushed) {',
      "            const procs = ns.ps('home').filter(p => p.filename === cmd.pushed);",
      '            for (const proc of procs) {',
      '              ns.kill(proc.pid);',
      '              ns.run(cmd.pushed, proc.threads, ...proc.args);',
      '            }',
      '          }',
      '          if (cmd.run) ns.run(cmd.run);',
      '        }',
      '      } catch {}',
      '    }',
    })
  end

  vim.list_extend(lines, {
    '    data.last_cmd_id = lastCmdId;',
    '    ns.write(OUTPUT_FILE, JSON.stringify(data), "w");',
    '    await ns.sleep(INTERVAL_MS);',
    '  }',
    '}',
    '',
  })

  return table.concat(lines, '\n')
end

function M.gen_companion(tier)
  tier = tonumber(tier) or state.config.companion_tier
  if not tier or tier < 1 or tier > 3 then
    vim.notify('[bitburner] companion_tier must be 1, 2, or 3', vim.log.levels.ERROR)
    return
  end
  local sync_root = state.config.sync_root
  if not sync_root then
    vim.notify('[bitburner] sync_root not configured', vim.log.levels.ERROR)
    return
  end
  local content  = gen_companion_script(tier)
  local filename = '/bitburner-nvim.js'
  local f = io.open(sync_root .. filename, 'w')
  if f then f:write(content); f:close() end
  if state.conn then
    M.do_push_file(filename, content, state.config.default_server)
    vim.notify('[bitburner] companion script (tier ' .. tier .. ') pushed as ' .. filename, vim.log.levels.INFO)
  else
    vim.notify('[bitburner] companion script written to ' .. sync_root .. filename .. ' (connect to push)', vim.log.levels.INFO)
  end
end

return M
