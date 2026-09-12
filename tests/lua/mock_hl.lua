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
-- workspace selector), "rule.set_enabled" (any rule's set_enabled throws), "mkdir" (os.execute
-- returns nil), "io.open" (returns nil), "io.write" (the open file's write returns nil),
-- "io.close" (the open file's close returns nil, so nothing commits to hl.__files), "rename"
-- (os.rename returns nil, err). `hl.__runtime_dir` overrides the fake XDG_RUNTIME_DIR (default
-- "/run/user/1000"). `hl.__os`/`hl.__io` are the fakes tst_chunks.lua's `run()` installs in
-- place of the real `os`/`io` inside a chunk's environment; each falls through to the real
-- library (via `__index`) for anything not faked here. `hl.__env` is a per-mock cache of that
-- environment (see tst_chunks.lua's `envFor`) — a fresh `Mock.new()` per test case is what
-- keeps `_G` (and so `_G.omyview_lock`) from leaking between cases.
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

  local function byAddress(sel)
    local a = sel:match("^address:(.+)$")
    return a and hl.__windows[a] or nil
  end
  function hl.get_window(sel) return byAddress(sel) end
  function hl.get_active_window() return hl.__active_window end
  function hl.get_cursor_pos() return { x = hl.__cursor.x, y = hl.__cursor.y } end
  function hl.get_active_workspace() return hl.__active_workspace end
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
  local function ruleObject(spec)
    local r = { spec = spec, enabled = spec.enabled ~= false }
    function r:set_enabled(v) if hl.__fail_on == "rule.set_enabled" then error("injected set_enabled failure") end; self.enabled = v end
    function r:is_enabled() return self.enabled end
    return r
  end
  function hl.window_rule(spec)
    if hl.__fail_on == "window_rule" and (hl.__fail_sel == nil or hl.__fail_sel == spec.match.workspace) then error("injected window_rule failure") end
    local r = ruleObject(spec); hl.__window_rules[#hl.__window_rules + 1] = r; return r
  end
  function hl.layer_rule(spec) local r = ruleObject(spec); hl.__layer_rules[#hl.__layer_rules + 1] = r; return r end
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
  hl.__files, hl.__mkdirs = {}, {}
  hl.__os = setmetatable({
    getenv = function(k) if k == "XDG_RUNTIME_DIR" then return hl.__runtime_dir or "/run/user/1000" end return nil end,
    execute = function(cmd) hl.__mkdirs[#hl.__mkdirs + 1] = cmd; if hl.__fail_on == "mkdir" then return nil end; return true end,
    rename = function(a, b) if hl.__fail_on == "rename" then return nil, "injected rename failure" end; hl.__files[b] = hl.__files[a]; hl.__files[a] = nil; return true end,
    remove = function(path) hl.__files[path] = nil; return true end,
  }, { __index = os })
  hl.__io = setmetatable({
    open = function(path, mode)
      if hl.__fail_on == "io.open" then return nil end
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
               bring_to_top = d("window.bring_to_top") },
    workspace = { toggle_special = d("workspace.toggle_special") },
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
    elseif desc.name == "window.float" and w then
      w.floating = not w.floating
    elseif desc.name == "window.move" and w then
      if a.workspace then
        local n = tonumber(a.workspace)
        w.workspace = n and { id = n } or { id = -99, name = a.workspace }
      end
      if a.x and a.y then w.at = { x = tonumber(a.x), y = tonumber(a.y) } end
    elseif desc.name == "window.fullscreen" and w then
      -- Hyprland's toggle rule: asking for the mode the window has turns it off, otherwise switches.
      local want = (a.mode == "maximized") and 1 or 2
      w.fullscreen = (w.fullscreen == want) and 0 or want
    elseif desc.name == "window.bring_to_top" then
      -- No window arg (it acts on whatever is currently focused): record it, never a no-op.
      hl.__top = hl.__active_window
    elseif desc.name == "cursor.move" then
      hl.__cursor = { x = a.x, y = a.y }
    elseif desc.name == "workspace.toggle_special" then
      local name = "special:" .. tostring(desc.args)
      if hl.__active_special and hl.__active_special.name == name then hl.__active_special = nil
      else hl.__active_special = { name = name } end
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
function M.ruleNamed(hl, name)
  for _, r in ipairs(hl.__window_rules) do if r.spec.name == name then return r end end
  return nil
end

return M
