return {
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
    run_on_push         = false,   -- false | "/script.js" to run after every push
    restart_if_running  = false,
    cmd_file            = '/.bitburner/cmd.json',
    companion_tier      = 0,       -- 0=disabled, 1, 2, or 3
    companion_file      = '/.bitburner/info.json',
    companion_poll_ms   = 2000,
    debug               = false,
  },
  server          = nil,
  conn            = nil,
  _id             = 0,
  _pending        = {},
  _queue          = {},  -- keyed by "filename\0server" to deduplicate
  _timer          = nil,
  _pull_timer     = nil,
  _info_timer     = nil,
  _push_times     = {},  -- game filename -> vim.uv.now() when pushFile was sent
  _cmd_id         = 0,
  _ram_cache      = {},  -- buf_path -> formatted RAM string | false
  _info           = nil, -- latest parsed companion script output
  _last_game      = {},  -- game filename -> content last written from game to disk
  _file_push_time = {},  -- local buf_path -> os.time() when push succeeded
  _file_pull_time = {},  -- local buf_path -> os.time() when file was written locally
}
