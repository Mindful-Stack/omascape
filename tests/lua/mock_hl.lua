-- In-memory stand-in for Hyprland's `hl` table, just enough for the chunks logic.js builds.
-- Dispatches mutate window state and are logged. Like Hyprland's, `hl.dispatch` never raises:
-- it returns { ok = true } or, when `hl.__fail_on = "window.float"` names the dispatcher (every
-- time, or only its `hl.__fail_nth` occurrence), { ok = false, error = "..." } — the chunk's own
-- run() guard is what turns that into the failure path. Geometry never re-lays out (no dwindle here) and focus
-- is a constant: tests assert dispatch order and end state, never geometry.
-- A new dispatcher used by a chunk must be added to `hl.dsp` AND applied in `hl.dispatch`;
-- never stub it as a no-op, or "ends tiled"-style checks become vacuous.
--
-- `hl.__fail_on` also drives the lock chunks' failure points, one string naming the single
-- operation to break on the NEXT call to it (persists until changed; combine with `hl.__fail_sel`
-- to target one selector): "window_rule" (hl.window_rule throws; scope with __fail_sel to one
-- workspace selector), "layer_rule" (hl.layer_rule throws — the share-time reminder frame's
-- namespace rule), "rule.set_enabled" (any rule's set_enabled throws), "mkdir" (the fake
-- `os.execute` runs but does NOT mark the runtime dir as existing — see `hl.__dir_exists`
-- below), "io.open" (returns nil for any path), "io.write" (the open file's write returns nil),
-- "io.close" (the open file's close returns nil, so nothing commits to hl.__files), "rename"
-- (os.rename returns nil, err). `hl.__runtime_dir` overrides the fake XDG_RUNTIME_DIR (default
-- "/run/user/1000"); `false` means the variable is UNSET, which breaks the install's filesystem
-- step without spending the single `hl.__fail_on` slot. `hl.__os`/`hl.__io` are the fakes tst_chunks.lua's `run()` installs in
-- place of the real `os`/`io` inside a chunk's environment; each falls through to the real
-- library (via `__index`) for anything not faked here. `hl.__os.execute` always returns nil,
-- like the real compositor's Lua (it reaps the child itself, so the exit status never reaches
-- Lua) — `hl.__mkdirs` still records every call so "mkdir attempted" assertions work; a chunk
-- must verify the directory some other way (a probe file), never by trusting this return
-- value. `hl.__opens` counts every `io.open` call (any path, any outcome) — useful to pin a
-- probe-first `L.ensureDir()`: one open when the directory is already there, three (failed
-- probe, then a successful re-probe, then the actual file open) when it had to be created.
-- `hl.__dir_exists` models whether the runtime directory is actually there on "disk":
-- it starts false, an `os.execute` whose command starts with "mkdir" sets it true (unless
-- `hl.__fail_on == "mkdir"`, modelling a failed create), and `io.open` for any path under the
-- runtime dir returns nil while it is false. A test can clear it back to false mid-case to
-- simulate the directory vanishing after a successful install (it survives a shell restart in
-- `_G`, but the directory on disk does not) — combine with deleting the relevant `hl.__files`
-- entries so a stale in-memory file doesn't make a vanished directory look intact.
-- `hl.__env` is a per-mock cache of that environment (see tst_chunks.lua's `envFor`) — a fresh
-- `Mock.new()` per test case is what keeps `_G` (and so `_G.omascape_lock`) from leaking between
-- cases.
local M = {}

function M.new(opts)
  opts = opts or {}
  local hl = { __log = {}, __notifications = {}, __printed = {}, __fail_on = nil, __fail_nth = nil,
    __seen = {}, __config = {
    ["general.layout"] = opts.layout or "dwindle",
    ["dwindle.smart_split"] = false, ["dwindle.use_active_for_splits"] = true } }
  hl.__windows = opts.windows or {}
  hl.__active_workspace = opts.active_workspace or { id = 1 }
  hl.__workspaces = opts.workspaces or {}
  hl.__active_window = opts.active_window or nil
  hl.__cursor = { x = 5, y = 6 }
  hl.__active_special = opts.active_special or nil          -- { name = "special:…" } or nil
  function hl.get_active_special_workspace() return hl.__active_special end
  hl.__active_by_monitor = opts.active_by_monitor or {}
  -- hl.get_active_workspace(monitorSelector) — with no selector it answers the focused monitor's,
  -- which is what the existing callers use.
  function hl.get_active_workspace(mon)
    if mon == nil then return hl.__active_workspace end
    return hl.__active_by_monitor[mon]
  end

  local function byAddress(sel)
    local a = sel:match("^address:(.+)$")
    return a and hl.__windows[a] or nil
  end
  function hl.get_window(sel) return byAddress(sel) end
  function hl.get_active_window() return hl.__active_window end
  function hl.get_cursor_pos() return { x = hl.__cursor.x, y = hl.__cursor.y } end
  function hl.get_workspace(id)
    return hl.__workspaces[tostring(id)] or { fullscreen_window = nil, fullscreen_mode = 0 }
  end
  function hl.get_config(k)
    local v = hl.__config[k]
    if v == nil then return nil, "unknown config key '" .. k .. "'" end
    return v
  end
  function hl.config(t)
    for group, kv in pairs(t) do
      for k, v in pairs(kv) do hl.__config[group .. "." .. k] = v end
    end
  end
  hl.notification = { create = function(t) hl.__notifications[#hl.__notifications + 1] = t end }

  -- Rules: named handles with enable state, so tests can assert "one handle per selector".
  hl.__window_rules, hl.__layer_rules, hl.__subs = {}, {}, {}
  -- Addresses closed via window.close, in order (Task 12 asserts "closed every window the
  -- workspace listed" — meaningful only because the dispatcher below actually drops them).
  hl.__closed = {}
  -- Every workspace.move/swap_monitors dispatch, in order. Ownership only: which workspace each
  -- monitor then SHOWS is the compositor's business (moveWorkspaceToMonitor, 0.56.2) and is
  -- asserted on the nested rig, not here.
  hl.__moved, hl.__swapped = {}, {}
  -- `__set_calls` counts every set_enabled CALL on this rule, including one that throws: the
  -- observer's grace timer (below) is only worth anything if the flapping edges produce no calls
  -- at all, so "how many times was the compositor asked to toggle this rule" is the property the
  -- tests assert, not just the rule's end state.
  local function ruleObject(spec)
    local r = { spec = spec, enabled = spec.enabled ~= false, __set_calls = 0 }
    function r:set_enabled(v)
      self.__set_calls = self.__set_calls + 1
      if hl.__fail_on == "rule.set_enabled" then error("injected set_enabled failure") end
      self.enabled = v
    end
    function r:is_enabled() return self.enabled end
    return r
  end
  function hl.window_rule(spec)
    if hl.__fail_on == "window_rule" and (hl.__fail_sel == nil or hl.__fail_sel == spec.match.workspace) then error("injected window_rule failure") end
    local r = ruleObject(spec); hl.__window_rules[#hl.__window_rules + 1] = r; return r
  end
  function hl.layer_rule(spec)
    if hl.__fail_on == "layer_rule" then error("injected layer_rule failure") end
    local r = ruleObject(spec); hl.__layer_rules[#hl.__layer_rules + 1] = r; return r
  end
  -- Timers: `hl.timer(cb, { timeout = <ms>, type = "oneshot" })` starts immediately and fires
  -- once. Probed live on 0.56.2 and modelled exactly here: `set_enabled(false)` before it fires
  -- CANCELS it (re-enabling before the deadline makes it fire once at the ORIGINAL deadline —
  -- the clock never stops, which is why M.elapse advances disabled timers too), and a timer that
  -- has ALREADY fired can never be re-armed: `set_enabled(true)`/`set_timeout` after firing do
  -- nothing, so the observer must create a fresh timer per off-edge. `is_enabled()` is true only
  -- while pending. Nothing fires on its own: a test drives the clock with M.elapse.
  hl.__timers = {}
  function hl.timer(cb, opts)
    if hl.__fail_on == "timer" then error("injected timer failure") end
    opts = opts or {}
    local t = { cb = cb, timeout = opts.timeout, type = opts.type or "oneshot",
                enabled = true, fired = false, remaining = opts.timeout }
    function t:set_enabled(v) if self.fired then return end; self.enabled = v end
    function t:is_enabled() return self.enabled and not self.fired end
    function t:set_timeout(ms) if self.fired then return end; self.timeout = ms; self.remaining = ms end
    hl.__timers[#hl.__timers + 1] = t
    return t
  end
  -- Events: hl.on stores callbacks; M.fire(hl, name, ...) delivers.
  function hl.on(name, cb)
    local sub = { name = name, cb = cb, active = true }
    function sub:remove() self.active = false end
    function sub:is_active() return self.active end
    hl.__subs[#hl.__subs + 1] = sub
    return sub
  end
  -- Fake os/io: an in-memory filesystem so the observer's publish can be asserted without disk.
  -- Both fall through to the real os/io library (via __index) for anything not faked here, so
  -- a chunk calling e.g. os.time still works even though this mock never anticipated it.
  hl.__files, hl.__mkdirs, hl.__opens, hl.__renames = {}, {}, 0, 0
  hl.__dir_exists = false          -- set true by a real "mkdir" execute; a test can clear it to
                                    -- simulate the runtime dir vanishing after a successful install
  hl.__os = setmetatable({
    -- `hl.__runtime_dir = false` (not nil, which just selects the default) models the variable
    -- being UNSET: the only way to break the filesystem step independently of `hl.__fail_on`,
    -- which names a single operation and is needed elsewhere in the same case.
    getenv = function(k)
      if k == "XDG_RUNTIME_DIR" then
        if hl.__runtime_dir == false then return nil end
        return hl.__runtime_dir or "/run/user/1000"
      end
      return nil
    end,
    -- Always nil: the real compositor reaps the child itself, so os.execute's return value is
    -- never a usable success/failure signal (verified live). Still recorded in hl.__mkdirs so
    -- "attempted the mkdir" assertions have something to check, and marks the directory as
    -- existing (unless __fail_on == "mkdir", modelling a create that didn't take).
    execute = function(cmd)
      hl.__mkdirs[#hl.__mkdirs + 1] = cmd
      if hl.__fail_on ~= "mkdir" and cmd:match("^mkdir") then hl.__dir_exists = true end
      return nil
    end,
    -- `hl.__renames` counts every SUCCESSFUL rename, i.e. every share-state publish that actually
    -- committed: the hysteresis cases assert that a flapping share signal rewrites the state file
    -- no further times, which the file's CONTENT alone (it would be rewritten with the same "1")
    -- could never show.
    rename = function(a, b) if hl.__fail_on == "rename" then return nil, "injected rename failure" end; hl.__files[b] = hl.__files[a]; hl.__files[a] = nil; hl.__renames = hl.__renames + 1; return true end,
    remove = function(path) hl.__files[path] = nil; return true end,
  }, { __index = os })
  hl.__io = setmetatable({
    open = function(path, mode)
      hl.__opens = hl.__opens + 1
      if hl.__fail_on == "io.open" then return nil end
      -- Any open under the runtime dir (the install chunk's probe file, or later its
      -- share-state files) fails while the directory isn't there.
      local dir = (hl.__runtime_dir or "/run/user/1000") .. "/omascape"
      if path:sub(1, #dir) == dir and not hl.__dir_exists then return nil end
      local buf = {}
      return { write = function(self, s) if hl.__fail_on == "io.write" then return nil end; buf[#buf + 1] = s; return self end,
               close = function() if hl.__fail_on == "io.close" then return nil end; hl.__files[path] = table.concat(buf); return true end }
    end,
  }, { __index = io })

  -- Typed dispatcher table: each entry returns a descriptor; hl.dispatch applies it.
  local function d(name) return function(args) return { name = name, args = args } end end
  hl.dsp = {
    focus = d("focus"),
    cursor = { move = d("cursor.move") },
    window = { float = d("window.float"), move = d("window.move"), fullscreen = d("window.fullscreen"),
               close = d("window.close"),
               bring_to_top = d("window.bring_to_top"), alter_zorder = d("window.alter_zorder") },
    workspace = { toggle_special = d("workspace.toggle_special"), move = d("workspace.move"),
                  swap_monitors = d("workspace.swap_monitors") },
  }
  function hl.dispatch(desc)
    hl.__log[#hl.__log + 1] = desc
    hl.__seen[desc.name] = (hl.__seen[desc.name] or 0) + 1
    if hl.__fail_on == desc.name and (hl.__fail_nth == nil or hl.__fail_nth == hl.__seen[desc.name]) then
      return { ok = false, error = "injected failure in " .. desc.name, level = "error", code = "C_INVARG" }
    end
    local a = desc.args or {}
    local w = a.window and byAddress(a.window) or nil
    if desc.name == "focus" then
      hl.__active_window = w or hl.__active_window
      -- Focus CARRIES THE WORKSPACE: focusing a window that lives on another workspace switches
      -- the compositor to it (probed live on 0.56.2 against the nested rig, step by step through
      -- a tiled insert — it is the only step of that chunk that moves the active workspace).
      -- Modelled here because a chunk that restores focus to a window it has just moved away
      -- takes the user with it, and a mock whose active workspace never moves cannot show that.
      if w and w.workspace then hl.__active_workspace = w.workspace end
      if a.workspace then
        local n = tonumber(a.workspace)
        hl.__active_workspace = n and { id = n } or { id = -99, name = a.workspace }
      end
    elseif desc.name == "window.float" and w then
      -- Absolute, not a toggle: Hyprland's parseToggleStr maps "on"/"off" to ENABLE/DISABLE and
      -- Actions::floatWindow returns early when the state already matches (probed live, see
      -- tests/integration/actions-probe.sh). Modelled here so a chunk that skips a redundant
      -- dispatch and one that sends it are distinguishable.
      if a.action == "on" then w.floating = true
      elseif a.action == "off" then w.floating = false
      else w.floating = not w.floating end
      -- The float raises the window and relayouts its workspace, which moves focus onto it. This
      -- is what gives restoreFocusLua something to restore; without it the "focus restored"
      -- assertions below would pass against a chunk that never restored anything. Only while the
      -- window is on the ACTIVE workspace, though: floating or un-floating one on a workspace
      -- nothing is showing leaves focus (and the active workspace) alone — probed live on
      -- 0.56.2, and it is what makes a tiled insert onto a hidden workspace end with focus
      -- somewhere other than the window that moved.
      if w.workspace == nil or hl.__active_workspace == nil or w.workspace.id == hl.__active_workspace.id then
        hl.__active_window = w
      end
    elseif desc.name == "window.close" and w then
      -- A real close removes the window; "closed every window the workspace listed" is the
      -- property Task 12 asserts, and it is only meaningful if the mock actually drops them.
      hl.__windows[w.address] = nil
      hl.__closed[#hl.__closed + 1] = w.address
    elseif desc.name == "window.move" and w then
      if a.workspace then
        local n = tonumber(a.workspace)
        local from = w.workspace
        w.workspace = n and { id = n } or { id = -99, name = a.workspace }
        -- `follow = false` leaves the user where they are, and the compositor hands focus to
        -- another window on the workspace the moved one just left — nil when there is none
        -- (probed live on 0.56.2). Without this the moved window stays "active" in the mock and
        -- every focus-restore assertion is answered by a guard that never fires.
        if a.follow == false and hl.__active_window == w then
          hl.__active_window = nil
          for _, other in pairs(hl.__windows) do
            if other ~= w and other.workspace and from and other.workspace.id == from.id then
              hl.__active_window = other; break
            end
          end
        end
      end
      if a.x and a.y then w.at = { x = tonumber(a.x), y = tonumber(a.y) } end
    elseif desc.name == "window.fullscreen" and w then
      -- Hyprland's toggle rule: asking for the mode the window has turns it off, otherwise switches.
      local want = (a.mode == "maximized") and 1 or 2
      w.fullscreen = (w.fullscreen == want) and 0 or want
    elseif desc.name == "window.bring_to_top" then
      -- No window arg (it acts on whatever is currently focused): record it, never a no-op.
      hl.__top = hl.__active_window
    elseif desc.name == "window.alter_zorder" then
      -- Targets a window by selector; mode "top" raises it. Recorded, never a no-op.
      if a.mode == "top" then hl.__top = w end
    elseif desc.name == "cursor.move" then
      hl.__cursor = { x = a.x, y = a.y }
    elseif desc.name == "workspace.toggle_special" then
      local name = "special:" .. tostring(desc.args)
      if hl.__active_special and hl.__active_special.name == name then hl.__active_special = nil
      else hl.__active_special = { name = name } end
    elseif desc.name == "workspace.move" then
      -- Ownership only: which workspace each monitor then SHOWS is the compositor's business
      -- (moveWorkspaceToMonitor, 0.56.2) and is asserted on the nested rig, not here.
      hl.__moved[#hl.__moved + 1] = { workspace = a.workspace, monitor = a.monitor }
      -- Stand-in for the real compositor's cursor warp to the destination monitor's centre
      -- (moveWorkspaceToMonitor, 0.56.2 — no noWarpCursor from Lua): a fixed, clearly-not-the-
      -- fixture's-starting-position value, so a chunk that captures the cursor position AFTER
      -- this dispatch (instead of before) restores the warped value instead of undoing it, and
      -- the "cursor restored" assertion can actually tell the two orderings apart.
      hl.__cursor = { x = 9999, y = 9999 }
    elseif desc.name == "workspace.swap_monitors" then
      hl.__swapped[#hl.__swapped + 1] = { monitor1 = a.monitor1, monitor2 = a.monitor2 }
      -- Same reasoning as workspace.move above (swapActiveWorkspaces also warps the cursor to
      -- the now-active workspace, 0.56.2): warp here too, so a chunk that captures the cursor
      -- AFTER dispatching instead of before restores the warp instead of undoing it.
      hl.__cursor = { x = 9999, y = 9999 }
    end
    return { ok = true, pass_event = false }
  end
  return hl
end

-- Names of dispatches in order, e.g. { "window.float", "window.move", ... }.
function M.names(hl)
  local out = {}
  for i, e in ipairs(hl.__log) do out[i] = e.name end
  return out
end

function M.fire(hl, name, ...)
  for _, s in ipairs(hl.__subs) do if s.name == name and s.active then s.cb(...) end end
end
-- Advance the fake clock by `ms`. Every unfired timer loses that much of its remaining time
-- (including a disabled one: cancelling does not stop the clock, so re-enabling it cannot push
-- the deadline out); a oneshot that is still enabled and has run out fires exactly once and is
-- marked fired+disabled, so it can never fire again. The timer list is snapshotted first: a
-- callback that creates a NEW timer must not have it firing within the same elapse.
function M.elapse(hl, ms)
  local snapshot = {}
  for i, t in ipairs(hl.__timers or {}) do snapshot[i] = t end
  for _, t in ipairs(snapshot) do
    if not t.fired then
      t.remaining = (t.remaining or 0) - ms
      if t.enabled and t.type == "oneshot" and t.remaining <= 0 then
        t.fired = true; t.enabled = false
        t.cb()
      end
    end
  end
end
-- Timers still waiting to fire (enabled and unfired).
function M.pendingTimers(hl)
  local n = 0
  for _, t in ipairs(hl.__timers or {}) do if t.enabled and not t.fired then n = n + 1 end end
  return n
end
function M.ruleNamed(hl, name)
  for _, r in ipairs(hl.__window_rules) do if r.spec.name == name then return r end end
  return nil
end
-- Same, over the LAYER rules (the share-time reminder frame's `no_screen_share` rule on the
-- omascape-lockframe namespace, created by the install chunk).
function M.layerRuleNamed(hl, name)
  for _, r in ipairs(hl.__layer_rules) do if r.spec.name == name then return r end end
  return nil
end

return M
