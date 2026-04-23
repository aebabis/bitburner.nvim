# bitburner.nvim — Implementation Plan

Neovim plugin that syncs files with the Bitburner game via its Remote File API.
Depends on [nvim-websocket](https://github.com/aebabis/nvim-websocket) for the
WebSocket server layer (no Node, no external Lua dependencies).

## Architecture notes

- **Protocol**: JSON-RPC 2.0 over WebSocket. The plugin runs a WS *server*;
  the game is the client that connects to it. Configure the port in the game's
  Settings → Remote API, then press Connect.
- **Default port**: 12525
- **No virtual filesystem**: multi-server targeting is an explicit command-line
  option (`--server <name>`), not a folder structure. Source of truth is local;
  other servers are deployment targets reached via `ns.scp` in user scripts.
- **sync_root**: a configurable subfolder of the repo that maps to `/` in the
  game. Default: prompt during `:BitburnerInit`. Files outside sync_root are
  ignored by push/pull.

## Known RPC methods

| Method            | Params                          | Notes                        |
|-------------------|---------------------------------|------------------------------|
| `pushFile`        | filename, content, server       |                              |
| `getFile`         | filename, server                |                              |
| `deleteFile`      | filename, server                |                              |
| `getFileNames`    | server                          | returns list of filenames    |
| `getAllFiles`      | server                          | returns filename+content     |
| `calculateRam`    | filename, server                | game computes RAM cost       |
| `getDefinitionFile` | —                             | returns NetscriptDefinitions |

## Existing code

`lua/bitburner/` contains exploratory prototype code (Node-dependent, uses
plenary). It should be replaced entirely during Phase 1 implementation.

---

## Phases

### Phase 1 — Manual connection + basic push
**Goal**: usable core loop. Edit a file, push it, see it in the game.

- [ ] Clean up / replace prototype code
- [ ] `require('bitburner').setup(opts)` entry point
  - opts: `port` (default 12525), `sync_root` (required or prompted)
- [ ] Start WS server on setup using nvim-websocket
- [ ] Track connection state (disconnected / connected / game address)
- [ ] `:BitburnerConnect [port]` — start server (or restart on new port)
- [ ] `:BitburnerDisconnect` — stop server
- [ ] `:BitburnerPush` — push current buffer to game
  - Map buffer path relative to sync_root → game filename
  - Ignore files outside sync_root
- [ ] Statusline component: `require('bitburner').statusline()` → string
- [ ] `sync_ignore` glob list (default: `*.md`, `*.json`, `node_modules/**`)

**TEST CHECKPOINT**: manually connect, edit a .js file, `:BitburnerPush`,
verify file appears in game editor.

---

### Phase 2 — Auto-push
**Goal**: zero-friction edit loop.

- [ ] `auto_push` config option (default: false)
  - `"on_save"` — BufWritePost
  - `"on_exit_insert"` — InsertLeave + idle timer (debounced ~500ms)
- [ ] Push failure notification (game not connected, file ignored, etc.)
- [ ] Push success notification (opt-in, noisy — off by default)
- [ ] Offline queue: buffer failed pushes, flush on reconnect
- [ ] `push_all_on_connect` option: push all sync_root files on game connect

**TEST CHECKPOINT**: enable `auto_push = "on_save"`, edit + save, verify
game receives update without manual command.

---

### Phase 3 — Project detection & config persistence
**Goal**: set-and-forget. Open the project and it just works.

- [ ] `.bitburner.json` hidden config file (per-project, gitignore-able)
  - Fields: `port`, `sync_root`, `auto_push`, `sync_ignore`, `default_server`
- [ ] `:BitburnerInit` — interactive setup wizard, writes `.bitburner.json`
- [ ] Auto-load config on startup if `.bitburner.json` found in cwd or parent dirs
- [ ] Auto-detection heuristic (opt-in global setting: `auto_detect = true`)
  - Check for `package.json` containing `"bitburner"` or `"@ns-types/netscript"`
  - Check for `filesync.json`
  - Check for `NetscriptDefinitions.d.ts`
- [ ] Auto-connect on detection (respects `auto_push` from config)

**TEST CHECKPOINT**: close and reopen Neovim in the project folder, verify
plugin connects automatically without any manual commands.

---

### Phase 4 — Pull and diff
**Goal**: full bidirectional sync; usable for migrating from in-game editor.

- [ ] `:BitburnerPull` — pull all files from game into sync_root
  - Prompt before overwriting locally modified files
- [ ] `:BitburnerPullFile` — pull game version of current buffer
- [ ] `:BitburnerDiff` — open diff split: local buffer vs game's version
- [ ] `:BitburnerSync` — two-way: push local-only, pull game-only, diff conflicts

**TEST CHECKPOINT**: edit a file in the game's built-in editor, `:BitburnerPull`,
verify local file matches. Then `:BitburnerDiff` on a diverged file.

---

### Phase 5 — Script execution
**Goal**: close the loop without leaving Neovim.

- [ ] `signal_on_push` option — after each successful push, write a Unix
  timestamp to `signal_file` (default `/bitburner-nvim.txt`) on the game
  server. Users poll this with `ns.read()` in a bootstrap/watcher script
  to trigger re-initialization without the plugin needing to understand
  their process topology.
  - Add `signal_on_push` and `signal_file` config options ✓
  - Add to `:BitburnerInit` wizard ✓
- [ ] Companion NS script — required for `:BitburnerRun` / `:BitburnerKill`;
  run/kill are not in the documented Remote File API.
  - Design: companion script runs inside the game and executes `ns.run()`
    / `ns.kill()` based on commands written to a known file by the plugin
  - Companion script generator (`:BitburnerGenCompanion` or similar) that
    writes the script to sync_root so the user can push it once — add to
    backlog
- [ ] `:BitburnerRun [args]` — run current file on home via companion script
- [ ] `:BitburnerKill` — kill current file on home via companion script
- [ ] `run_on_push` — defer until run/kill are implemented and tested
- [ ] TypeScript compilation awareness (opt-in):
  - `ts_out_dir` config: push from compiled output dir instead of source

**TEST CHECKPOINT**: `:BitburnerRun`, verify script appears in game's process
list. `:BitburnerKill`, verify it's gone. Enable `restart_on_push`, save file,
verify running script restarts.

---

### Phase 6 — Game info & RAM diagnostics (stretch)
**Goal**: surface live game state in the editor.

- [ ] Companion NS script (`/bitburner-nvim.js`) that runs in the game:
  - Polls `ns.getPlayer()`, server RAM, running scripts
  - Sends data back over WS on a timer
- [ ] Plugin caches incoming game state
- [ ] Statusline: available RAM on home, player level/money
- [ ] Static RAM cost analysis: parse `ns.*` calls in buffer, sum known costs
  - Ship a lookup table of NS function → RAM cost (from NS type definitions)
  - Display as virtual text or statusline item
- [ ] `calculateRam` RPC: ask game to compute RAM for current file
- [ ] Diagnostic warning if script RAM cost > available RAM on target server

**TEST CHECKPOINT**: run a RAM-heavy script to reduce available RAM, verify
diagnostic appears on a script that would exceed the limit.
