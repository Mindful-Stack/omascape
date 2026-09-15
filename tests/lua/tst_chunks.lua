-- Behaviour tests for the generated Lua chunks, run by tests/lua-check.sh after the parse
-- check. arg[1] is a file with one `NAME <single-line chunk>` per line, rendered from logic.js.
package.path = arg[0]:gsub("[^/]*$", "") .. "?.lua;" .. package.path
local Mock = require("mock_hl")

local chunks = {}
for line in io.lines(arg[1]) do
  local name, body = line:match("^(%S+) (.+)$")
  if name then chunks[name] = body end
end

-- Evaluate the chunk the way hl.dispatch does (it yields a function), then call it with the
-- mock as `hl`, `print` captured, and a PRIVATE global table: chunks that keep state in _G
-- (the lock) must not leak it between cases. `env._G = env` makes `_G.x` resolve to env.x.
-- `os`/`io` are the mock's fakes when the mock provides them, the host's otherwise.
local function envFor(hl)
  local env = setmetatable({ hl = hl, print = function(...)
    hl.__printed[#hl.__printed + 1] = table.concat({ ... }, "\t") end,
    os = hl.__os or os, io = hl.__io or io }, { __index = _G })
  env._G = env
  return env
end
local function run(name, hl)
  local body = assert(chunks[name], "no chunk named " .. name)
  hl.__env = hl.__env or envFor(hl)
  local f = assert(load("return " .. body, name, "t", hl.__env))
  local fn = f()
  assert(type(fn) == "function", name .. " must evaluate to a function")
  fn()
end
-- The private `_G` a chunk will see, materialised BEFORE the first run: lets a case seed the
-- compositor state an older build left behind (`_G.omyview_lock` from round 3) and then install
-- over it, which is the upgrade path itself — not something a run can be made to produce.
local function globals(hl)
  hl.__env = hl.__env or envFor(hl)
  return hl.__env._G
end

local failures = 0
local function case(label, f)
  local ok, err = pcall(f)
  if ok then print("ok   " .. label)
  else failures = failures + 1; print("FAIL " .. label .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
  if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function seq(hl, expected)
  eq(table.concat(Mock.names(hl), ","), table.concat(expected, ","), "dispatch order")
end
local function tiledWindows()
  return { ["0xabc"] = { address = "0xabc", floating = false, fullscreen = 0, workspace = { id = 1 },
                         at = { x = 0, y = 0 }, size = { x = 100, y = 100 } },
           ["0xdef"] = { address = "0xdef", floating = false, fullscreen = 0, workspace = { id = 3 },
                         at = { x = 500, y = 500 }, size = { x = 200, y = 100 } } }
end

-- TILED_INSERT: 0xabc (tiled, ws 1) → workspace 3, anchor 0xdef, side left (see lua-check.sh)
case("tiled insert replays float → move → cursor → un-float and restores config", function()
  local hl = Mock.new({ windows = tiledWindows() })
  run("TILED_INSERT", hl)
  seq(hl, { "window.float", "window.move", "cursor.move", "window.float", "cursor.move" })
  eq(hl.__windows["0xabc"].floating, false, "ends tiled")
  eq(hl.__windows["0xabc"].workspace.id, 3, "on the target workspace")
  eq(hl.__config["dwindle.smart_split"], false, "smart_split restored")
  eq(hl.__config["dwindle.use_active_for_splits"], true, "use_active restored")
  eq(#hl.__notifications, 0, "no error reported")
  eq(hl.__cursor.x, 5, "cursor restored")
end)
case("tiled insert: cursor move throws → window is NOT left floating, config restored, error reported", function()
  local hl = Mock.new({ windows = tiledWindows() })
  hl.__fail_on = "cursor.move"; hl.__fail_nth = 1   -- the placement move; the final cursor restore must still work
  run("TILED_INSERT", hl)
  eq(hl.__windows["0xabc"].floating, false, "cleanup un-floated it")
  eq(hl.__seen["window.float"], 2, "float, then the cleanup un-float (so 'ends tiled' is not vacuous)")
  eq(hl.__config["dwindle.smart_split"], false, "smart_split restored")
  eq(#hl.__notifications, 1, "one notification")
  assert(hl.__notifications[1].text:find("tiled insert failed", 1, true), "notification names the operation")
  assert(hl.__printed[1] and hl.__printed[1]:find("injected failure in cursor.move", 1, true), "logged the Lua error")
end)
case("tiled insert: the float itself throws → cleanup must not float the still-tiled window", function()
  local hl = Mock.new({ windows = tiledWindows() })
  hl.__fail_on = "window.float"
  run("TILED_INSERT", hl)
  eq(hl.__windows["0xabc"].floating, false, "still tiled")
  local n = 0
  for _, e in ipairs(hl.__log) do if e.name == "window.float" then n = n + 1 end end
  eq(n, 1, "exactly one float attempt (the failed one); cleanup re-read state and skipped")
end)
case("tiled insert: the cleanup un-float itself throws → still reported (once), config restored", function()
  local hl = Mock.new({ windows = tiledWindows() })
  hl.__fail_on = "window.float"; hl.__fail_nth = 2   -- the risky path succeeds; the cleanup toggle fails
  run("TILED_INSERT", hl)
  eq(#hl.__notifications, 1, "one notification")
  assert(hl.__notifications[1].text:find("tiled insert failed", 1, true))
  eq(hl.__config["dwindle.smart_split"], false, "smart_split restored")
  eq(Mock.names(hl)[#hl.__log], "cursor.move", "cursor restore still runs")
end)
case("tiled insert on a non-dwindle layout: the plain move throws → reported, cursor restored", function()
  local hl = Mock.new({ windows = tiledWindows(), layout = "master" })
  hl.__fail_on = "window.move"
  run("TILED_INSERT", hl)
  eq(#hl.__notifications, 1, "one notification")
  eq(Mock.names(hl)[#hl.__log], "cursor.move", "cursor restore is the last dispatch")
end)
case("tiled insert on a non-dwindle layout → plain silent move only", function()
  local hl = Mock.new({ windows = tiledWindows(), layout = "master" })
  run("TILED_INSERT", hl)
  seq(hl, { "window.move", "cursor.move" })
  eq(hl.__log[1].args.workspace, "3"); eq(hl.__log[1].args.follow, false)
  eq(hl.__seen["window.float"], nil, "dwindle path never entered")
end)
case("tiled insert: unknown layout key (nil) keeps the dwindle path", function()
  local hl = Mock.new({ windows = tiledWindows() })
  hl.__config["general.layout"] = nil
  run("TILED_INSERT", hl)
  eq(Mock.names(hl)[1], "window.float")
end)
case("tiled insert re-applies the target workspace's fullscreen after the re-tile", function()
  local w = tiledWindows(); w["0xdef"].fullscreen = 2
  local hl = Mock.new({ windows = w, workspaces = { ["3"] = { fullscreen_window = w["0xdef"], fullscreen_mode = 2 } } })
  run("TILED_INSERT", hl)
  seq(hl, { "window.fullscreen", "window.float", "window.move", "cursor.move", "window.float", "window.fullscreen", "cursor.move" })
  eq(hl.__windows["0xdef"].fullscreen, 2, "anchor fullscreen restored")
end)
case("tiled insert with no anchor uses the fallback point", function()
  local hl = Mock.new({ windows = tiledWindows() })
  run("TILED_INSERT_NO_ANCHOR", hl)
  seq(hl, { "window.float", "window.move", "cursor.move", "window.float", "cursor.move" })
  eq(hl.__log[3].args.x, 10); eq(hl.__log[3].args.y, 20)
end)
-- FLOATING_MOVE: 0xabc (floating, ws 1) → workspace 3 at (200,1600)
case("floating move transfers then positions in one chunk", function()
  local w = tiledWindows(); w["0xabc"].floating = true
  local hl = Mock.new({ windows = w })
  run("FLOATING_MOVE", hl)
  seq(hl, { "window.move", "window.move", "cursor.move" })
  eq(hl.__log[1].args.workspace, "3"); eq(hl.__log[2].args.x, "200"); eq(hl.__log[2].args.y, "1600")
  eq(hl.__windows["0xabc"].workspace.id, 3); eq(hl.__windows["0xabc"].at.x, 200)
end)
case("floating move on its own workspace only positions", function()
  local w = tiledWindows(); w["0xabc"].floating = true; w["0xabc"].workspace = { id = 3 }
  local hl = Mock.new({ windows = w })
  run("FLOATING_MOVE", hl)
  seq(hl, { "window.move", "cursor.move" }); eq(hl.__log[1].args.x, "200")
end)
case("floating move ignores a tiled window", function()
  local hl = Mock.new({ windows = tiledWindows() })
  run("FLOATING_MOVE", hl)
  eq(#hl.__log, 0)
end)
case("floating move: transfer throws → reported, cursor still restored", function()
  local w = tiledWindows(); w["0xabc"].floating = true
  local hl = Mock.new({ windows = w }); hl.__fail_on = "window.move"
  run("FLOATING_MOVE", hl)
  eq(#hl.__notifications, 1); assert(hl.__notifications[1].text:find("floating move failed", 1, true))
  eq(Mock.names(hl)[#hl.__log], "cursor.move", "cursor restore is the last dispatch")
end)
-- UNFULLSCREEN: 0xabc
case("un-fullscreen toggles only when the window is fullscreen", function()
  local w = tiledWindows(); w["0xabc"].fullscreen = 2
  local hl = Mock.new({ windows = w })
  run("UNFULLSCREEN", hl)
  seq(hl, { "window.fullscreen", "cursor.move" }); eq(hl.__windows["0xabc"].fullscreen, 0)
  local hl2 = Mock.new({ windows = tiledWindows() })
  run("UNFULLSCREEN", hl2)
  seq(hl2, { "cursor.move" })
end)

case("scratchpad show: toggles when no special workspace is up", function()
  local hl = Mock.new({})
  run("SCRATCHPAD_SHOW", hl)
  seq(hl, { "workspace.toggle_special" })
  eq(hl.__active_special and hl.__active_special.name, "special:scratchpad", "scratchpad is up")
  eq(#hl.__notifications, 0, "no error reported")
end)
case("scratchpad show: does nothing when the scratchpad is already up (never hides it)", function()
  local hl = Mock.new({ active_special = { name = "special:scratchpad" } })
  run("SCRATCHPAD_SHOW", hl)
  seq(hl, {})
  eq(hl.__active_special.name, "special:scratchpad", "still up")
end)
case("scratchpad show: another special is up → toggles the scratchpad", function()
  local hl = Mock.new({ active_special = { name = "special" } })
  run("SCRATCHPAD_SHOW", hl)
  seq(hl, { "workspace.toggle_special" })
end)
case("scratchpad show: toggle throws → reported", function()
  local hl = Mock.new({})
  hl.__fail_on = "workspace.toggle_special"
  run("SCRATCHPAD_SHOW", hl)
  eq(#hl.__notifications, 1, "one notification"); eq(#hl.__printed, 1, "one log line")
end)
case("floating move to the scratchpad names the workspace and positions", function()
  local hl = Mock.new({ windows = { ["0xabc"] = { address = "0xabc", floating = true, fullscreen = 0,
                                                  workspace = { id = 1 }, at = { x = 0, y = 0 } } } })
  run("FLOATING_MOVE_SCRATCH", hl)
  seq(hl, { "window.move", "window.move", "cursor.move" })
  eq(hl.__log[1].args.workspace, "special:scratchpad", "named target")
  eq(hl.__windows["0xabc"].workspace.name, "special:scratchpad")
  eq(hl.__windows["0xabc"].at.x, 200)
end)
case("floating move already on the scratchpad only positions", function()
  local hl = Mock.new({ windows = { ["0xabc"] = { address = "0xabc", floating = true, fullscreen = 0,
                                                  workspace = { id = -98, name = "special:scratchpad" }, at = { x = 0, y = 0 } } } })
  run("FLOATING_MOVE_SCRATCH", hl)
  seq(hl, { "window.move", "cursor.move" })
  eq(hl.__log[1].args.x, "200")
end)

-- SCRATCHPAD_FOCUS: "0xabc"
case("scratchpad focus: focuses then brings the window to the top", function()
  local hl = Mock.new({ windows = { ["0xabc"] = { address = "0xabc", floating = true, fullscreen = 0,
                                                  workspace = { id = -98, name = "special:scratchpad" } } } })
  run("SCRATCHPAD_FOCUS", hl)
  seq(hl, { "focus", "window.alter_zorder" })
  eq(hl.__log[2].args.window, "address:0xabc", "raised BY ADDRESS, not via the active window")
  eq(hl.__active_window and hl.__active_window.address, "0xabc", "window is active")
  eq(hl.__top and hl.__top.address, "0xabc", "window is raised above its siblings")
  eq(#hl.__notifications, 0, "no error reported")
end)
case("scratchpad focus: focus throws → one notification, the raise never runs", function()
  local hl = Mock.new({ windows = { ["0xabc"] = { address = "0xabc", floating = true, fullscreen = 0,
                                                  workspace = { id = -98, name = "special:scratchpad" } } } })
  hl.__fail_on = "focus"
  run("SCRATCHPAD_FOCUS", hl)
  eq(#hl.__notifications, 1, "one notification")
  assert(hl.__notifications[1].text:find("focus scratchpad window failed", 1, true))
  eq(hl.__seen["window.alter_zorder"], nil, "the raise never ran")
end)

-- The observer's grace period (logic.js `LOCK_SHARE_GRACE_MS`), shipped through the same
-- rendered file as the chunks (see lua-check.sh) rather than copied here: these cases advance
-- the mock's fake clock by the real constant, so changing it in logic.js can never leave them
-- elapsing a stale number.
local GRACE = assert(tonumber(chunks["LOCK_SHARE_GRACE_MS"]), "no LOCK_SHARE_GRACE_MS rendered")
local function state(hl) return hl.__files[hl.__os.getenv("XDG_RUNTIME_DIR") .. "/omyview/share-state"] end
local function statePath(hl) return hl.__os.getenv("XDG_RUNTIME_DIR") .. "/omyview/share-state" end
-- Mock.ruleNamed returns the FIRST rule matching `name` in hl.__window_rules (a flat log that
-- keeps every rule ever created, including dead handles a failed re-enable dropped from
-- L.rules). A dropped handle is recreated under the SAME name, so this returns the LAST match
-- instead, i.e. the one still referenced by the compositor's table.
local function lastRuleNamed(hl, name)
  local found = nil
  for _, r in ipairs(hl.__window_rules) do if r.spec.name == name then found = r end end
  return found
end
-- Distinguishes: a non-idempotent install (two subscriptions) or one that never publishes. The
-- runtime dir is re-verified on every install by design (see lockInstallLua's L.ensureDir), but
-- probe-first — a bare mkdir costs ~2.5ms of compositor main-thread time, paid on every overview
-- open, so it only runs when the probe shows the directory is actually missing.
case("lock install is idempotent and publishes 0", function()
  local hl = Mock.new({})
  run("LOCK_INSTALL", hl); run("LOCK_INSTALL", hl)
  eq(#hl.__subs, 1, "one subscription")
  eq(state(hl), "0", "published 0")
  eq(#hl.__mkdirs, 1, "mkdir attempted only when the directory was missing (once, on the first install)")
  eq(hl.__opens, 5, "probe-first: 3 opens to create it (failed probe, mkdir, re-probe) + publish, 2 more on the idempotent re-run (probe + publish)")
  eq(#hl.__notifications, 0)
end)
-- Distinguishes: a running compositor whose old subscription's callback closes over stale
-- behaviour surviving a shell restart. `_G.omyview_lock` is compositor Lua state, so
-- `L.sub:is_active()` stays true across a restart — a version mismatch is the only thing that
-- can tell a fresh install to replace it with a subscription carrying the current callback.
case("lock install replaces a stale-version observer subscription with a fresh one", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  local oldSub = hl.__subs[1]
  hl.__env._G.omyview_lock.subVer = nil          -- simulate a subscription installed by an older version
  run("LOCK_INSTALL", hl)
  eq(oldSub:is_active(), false, "the stale subscription was removed")
  local active = 0
  for _, s in ipairs(hl.__subs) do if s:is_active() then active = active + 1 end end
  eq(active, 1, "exactly one active subscription")
end)
-- Distinguishes: an install that trusts a stale L.dir left over from a previous session — the
-- compositor's Lua state (and L) outlives the shell, but the runtime directory does not (a
-- cleaner, or just the directory being gone after a restart). Confirmed live: L.dir stayed set
-- to a directory that no longer existed, and every publish failed with "cannot write
-- share-state" forever, since nothing ever re-checked.
case("lock install re-verifies the runtime dir on every run, recreating it if it vanished", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  eq(state(hl), "0")
  local dir = hl.__os.getenv("XDG_RUNTIME_DIR") .. "/omyview"
  for path in pairs(hl.__files) do if path:sub(1, #dir) == dir then hl.__files[path] = nil end end
  hl.__dir_exists = false                              -- the directory itself is gone now
  run("LOCK_INSTALL", hl)
  eq(state(hl), "0", "republished after recreating the directory")
  eq(#hl.__mkdirs, 2, "the second mkdir is recorded")
  eq(#hl.__notifications, 0, "a routine install recovers silently")
end)
-- Distinguishes: an observer whose first io.open failure is fatal (no retry) from one that
-- recovers by calling L.ensureDir() itself, within the same publish, before the next install.
case("share observer recovers from a vanished runtime dir without waiting for a fresh install", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  local dir = hl.__os.getenv("XDG_RUNTIME_DIR") .. "/omyview"
  for path in pairs(hl.__files) do if path:sub(1, #dir) == dir then hl.__files[path] = nil end end
  hl.__dir_exists = false
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  eq(state(hl), "1", "publish recreated the directory and wrote the live value")
  eq(#hl.__notifications, 0, "recovered silently")
end)
-- Distinguishes: a counter that reacts to the overview's own thumbnail captures (type 1,
-- toplevel/window export) instead of ignoring only those — every overview open would
-- otherwise flip armed boxes to the placeholder for no real share at all.
case("share observer ignores window capture events (type 1), a window share cannot capture the overview", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  Mock.fire(hl, "screenshare.state", true, 1, "Some window")
  eq(state(hl), "0", "a window capture (the overview's own thumbnails) does not count as a share")
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  eq(state(hl), "1", "a monitor capture still counts")
  Mock.fire(hl, "screenshare.state", false, 1, "Some window")
  eq(state(hl), "1", "a window-capture end must not decrement the counter either")
end)
-- Distinguishes: a filter that only recognises type 0 (monitor) from one that treats every
-- non-window type as a real share — a region share (type 2) renders through the same output
-- capture path as a monitor share and must count the same way.
case("share observer counts region captures (type 2) like monitor captures", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  Mock.fire(hl, "screenshare.state", true, 2, "region")
  eq(state(hl), "1", "a region capture counts as a share")
  Mock.fire(hl, "screenshare.state", false, 2, "region")
  Mock.elapse(hl, GRACE)                      -- the end only takes effect once the grace expires
  eq(state(hl), "0", "and its end decrements the counter")
end)
-- Distinguishes: an install that only publishes on the very first run (a fresh mock's
-- share-state pre-seeded, as a stale file from a previous session would be) from one that always
-- publishes the live counter — a stale "1" left over from a crash must not survive an install.
case("every install publishes the current value, even over a pre-seeded stale file", function()
  local hl = Mock.new({})
  hl.__files[statePath(hl)] = "1"
  run("LOCK_INSTALL", hl)
  eq(state(hl), "0", "the fresh counter (0) overwrites the stale value")
end)
-- Regression: os.execute("mkdir -p ...") returns nil on the real compositor even when the
-- directory WAS created (it reaps the child itself, so Lua never sees an exit status). Gating
-- L.dir on that return value made every install fail: this pins that a nil return, with a
-- filesystem that otherwise works, must NOT report and must still publish "0".
case("lock install: os.execute returning nil does not fail the install (mkdir's return value is untrustworthy)", function()
  local hl = Mock.new({})
  run("LOCK_INSTALL", hl)
  eq(#hl.__notifications, 0, "no failure reported")
  eq(state(hl), "0", "published despite os.execute returning nil")
end)
-- Share-time reminder frame (docs/specs/2026-09-12-lock-design.md, addendum, 2026-09-14, round 4).
-- The frame is omyview's own layer-shell surfaces; the layer rule is what blanks them in every
-- capture, so a viewer sees a plain black screen instead of a red frame around one. Distinguishes:
-- no rule at all (the frame would be IN the recording), a rule on the wrong namespace, or one
-- without no_screen_share.
case("lock install creates the lockframe layer rule with no_screen_share", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  local r = Mock.layerRuleNamed(hl, "omyview-lockframe")
  eq(r ~= nil, true, "layer rule created")
  eq(r.spec.match.namespace, "omyview-lockframe", "matches the strips' namespace")
  eq(r.spec.no_screen_share, true)
  eq(r:is_enabled(), true, "created enabled")
  eq(#hl.__notifications, 0)
end)
-- Distinguishes: an install that recreates the rule every time (the overview installs on every
-- open; the compositor's rule table has no removal call, so each one would leak a handle) and one
-- that leaves a surviving-but-disabled rule disabled (the frame would then be visible to viewers
-- with no way back short of a config reload).
case("a second install reuses the lockframe layer rule and re-enables a disabled one", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  local first = Mock.layerRuleNamed(hl, "omyview-lockframe")
  run("LOCK_INSTALL", hl)
  eq(#hl.__layer_rules, 1, "no duplicate layer rule")
  first:set_enabled(false)
  run("LOCK_INSTALL", hl)
  eq(#hl.__layer_rules, 1, "still no duplicate")
  eq(first:is_enabled(), true, "a surviving disabled rule is re-enabled")
end)
-- Distinguishes: a layer-rule failure taking the whole install down with it (the exclusion rules
-- and the share observer are the actual protection and must survive) or being swallowed silently.
case("a failing layer rule is reported but leaves the observer and the publish intact", function()
  local hl = Mock.new({})
  hl.__fail_on = "layer_rule"
  run("LOCK_INSTALL", hl)
  eq(#hl.__notifications, 1, "reported through the install's own error path")
  eq(#hl.__subs, 1, "the share observer still exists")
  eq(state(hl), "0", "and the state file was still published")
  hl.__fail_on = nil
  run("LOCK_INSTALL", hl)
  eq(Mock.layerRuleNamed(hl, "omyview-lockframe") ~= nil, true, "the next install retries it")
  eq(#hl.__notifications, 1, "the clean retry reports nothing new")
end)
-- Round 4b, the upgrade path off round 3. A compositor still holding a ROUND-3 `_G.omyview_lock`
-- has an `L.borders` table of `omyview-lock-border-*` window rules, possibly enabled, that round
-- 4's code never touches: this Hyprland Lua API can disable a rule but never remove one, so those
-- rims would keep colouring every window on an armed workspace until the user's next config
-- reload (which is exactly what round 4's live check had to do by hand). The install disables them
-- once and drops the table.
-- Distinguishes: an install that ignores the leftover table (the stale rims survive), and one that
-- drops the table without disabling the rules first (same rims, minus the handles to fix them).
case("install disables and forgets a round-3 border rule table", function()
  local hl = Mock.new({})
  local stale = hl.window_rule({ name = "omyview-lock-border-3", match = { workspace = "3" },
                                 border_color = "rgb(ff4444)", border_size = 6, enabled = true })
  eq(stale:is_enabled(), true, "the leftover starts enabled (so the check below is not vacuous)")
  local G = globals(hl)
  G.omyview_lock = { rules = {}, sharing = 0, effective = false, grace = nil, sub = nil,
                     subVer = nil, dir = nil, borders = { ["3"] = stale },
                     borderCfg = { color = "rgb(ff4444)", size = 6 } }
  run("LOCK_INSTALL", hl)
  eq(stale:is_enabled(), false, "the round-3 rim is switched off")
  eq(G.omyview_lock.borders, nil, "and the table is gone, so the sweep happens once")
  eq(#hl.__notifications, 0, "a clean upgrade reports nothing")
  eq(state(hl), "0", "the install still completed")
end)
-- Distinguishes: a stale handle whose set_enabled throws aborting the whole install — the share
-- observer and the layer rule would never be installed on that upgrade.
case("a stale border rule that cannot be disabled does not break the install", function()
  local hl = Mock.new({})
  local stale = hl.window_rule({ name = "omyview-lock-border-3", match = { workspace = "3" }, enabled = true })
  local G = globals(hl)
  G.omyview_lock = { rules = {}, sharing = 0, effective = false, borders = { ["3"] = stale } }
  hl.__fail_on = "rule.set_enabled"
  run("LOCK_INSTALL", hl)
  hl.__fail_on = nil
  eq(G.omyview_lock.borders, nil, "dropped anyway: nothing else can reach that handle")
  eq(#hl.__subs, 1, "the share observer was still installed")
  eq(state(hl), "0", "and the state file published")
end)
-- Round 4b review fix: when BOTH the layer rule and the filesystem step fail, the install has one
-- `ok, err` to report and must spend it on the FILESYSTEM. A failed layer rule costs the local
-- cue's blanking (the frame would show up in the capture); a failed share-state publish costs
-- share DETECTION itself, so the frame and the overview's placeholder never appear at all — the
-- bigger failure, and the one whose cause (a broken runtime dir) the user can act on.
-- Distinguishes: the original `if not fok … if not pok` order, which reported the cosmetic
-- layer-rule error and swallowed the share-state one entirely.
case("install reports the share-state failure, not the layer-rule one, when both fail", function()
  local hl = Mock.new({})
  hl.__fail_on = "layer_rule"
  hl.__runtime_dir = false                  -- XDG_RUNTIME_DIR unset: ensureDir() cannot succeed
  run("LOCK_INSTALL", hl)
  eq(#hl.__notifications, 1, "one report")
  local text = hl.__notifications[1].text
  assert(text:find("XDG_RUNTIME_DIR", 1, true), "names the share-state failure, got: " .. text)
  assert(not text:find("layer_rule", 1, true), "not the cosmetic layer-rule error, got: " .. text)
  eq(#hl.__subs, 1, "the share observer still exists either way")
end)
-- Distinguishes: a layer-rule failure that stops being reported at all once the precedence above
-- is in place (the swap must only decide which error WINS, never drop the loser's own case).
case("a layer-rule failure alone is still the reported error", function()
  local hl = Mock.new({})
  hl.__fail_on = "layer_rule"
  run("LOCK_INSTALL", hl)
  eq(#hl.__notifications, 1, "one report")
  assert(hl.__notifications[1].text:find("layer_rule", 1, true), "names the layer rule failure")
  eq(state(hl), "0", "the filesystem step still ran and published")
end)
-- Distinguishes: a counter reset by re-install, or an install that publishes stale state.
case("lock install preserves the share counter", function()
  local hl = Mock.new({})
  run("LOCK_INSTALL", hl); Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  run("LOCK_INSTALL", hl)
  eq(state(hl), "1", "still sharing after re-install")
end)
-- Distinguishes: a rule created disabled, unnamed, or matched on something other than workspace.
case("lock sync creates one enabled named rule per selector", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  run("LOCK_SYNC_3_SCRATCH", hl)
  eq(#hl.__window_rules, 2, "exactly one rule per selector, nothing else")
  local r3 = Mock.ruleNamed(hl, "omyview-lock-3"); eq(r3 ~= nil, true, "named rule for 3")
  eq(r3:is_enabled(), true); eq(r3.spec.match.workspace, "3"); eq(r3.spec.no_screen_share, true)
  eq(Mock.ruleNamed(hl, "omyview-lock-special:scratchpad"):is_enabled(), true)
  eq(#hl.__notifications, 0)
end)
-- Distinguishes: disarm destroying/forgetting the handle (re-arm would create a second rule),
-- or disarm not disabling.
case("lock sync disables removed selectors and reuses the handle on re-arm", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  run("LOCK_SYNC_3", hl); run("LOCK_SYNC_NONE", hl)
  eq(Mock.ruleNamed(hl, "omyview-lock-3"):is_enabled(), false, "disabled")
  run("LOCK_SYNC_3", hl)
  eq(#hl.__window_rules, 1, "same handle re-enabled, no second rule")
  eq(Mock.ruleNamed(hl, "omyview-lock-3"):is_enabled(), true)
end)
-- Distinguishes: the share observer touching rules (they must stay as the sync left them) or
-- publishing the wrong value; the counter not clamping. `L.sharing` stays the raw balanced
-- counter under the round-3 hysteresis — only the OFF direction is debounced, so every `false`
-- here is followed by an elapse of the grace window, while an end that leaves another share
-- running arms no timer at all (the count is still > 0, so nothing changed).
case("share events publish 1/0 with a clamped counter and never touch rules", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1"); eq(state(hl), "1")
  Mock.fire(hl, "screenshare.state", true, 0, "HDMI-A-1"); Mock.fire(hl, "screenshare.state", false, 0, "eDP-1")
  eq(Mock.pendingTimers(hl), 0, "an end with another share still running arms no grace timer")
  Mock.elapse(hl, GRACE)
  eq(state(hl), "1", "two starts, one end: still sharing")
  Mock.fire(hl, "screenshare.state", false, 0, "HDMI-A-1"); Mock.elapse(hl, GRACE); eq(state(hl), "0")
  Mock.fire(hl, "screenshare.state", false, 0, "eDP-1"); Mock.elapse(hl, GRACE)
  eq(state(hl), "0", "clamped at 0")
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  eq(state(hl), "1", "one start after the clamp is a share again (unclamped would be 0)")
  eq(Mock.ruleNamed(hl, "omyview-lock-3"):is_enabled(), true, "rules untouched by share events")
end)
-- Distinguishes: one failing selector aborting the rest (a single pcall around both loops).
case("lock sync isolates a failing selector and still protects the others", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  hl.__fail_on = "window_rule"; hl.__fail_sel = "3"
  run("LOCK_SYNC_3_SCRATCH", hl)
  eq(Mock.ruleNamed(hl, "omyview-lock-3"), nil, "3 failed")
  eq(Mock.ruleNamed(hl, "omyview-lock-special:scratchpad"):is_enabled(), true, "scratchpad still protected")
  eq(#hl.__notifications, 1, "reported once"); eq(hl.__notifications[1].text:find("3:", 1, true) ~= nil, true, "names the selector")
end)
-- Distinguishes: a stale rule not disabled because an earlier enable threw.
case("lock sync still disables stale rules when an enable throws", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3_SCRATCH", hl)
  hl.__fail_on = "rule.set_enabled"
  run("LOCK_SYNC_NONE", hl)   -- both set_enabled(false) calls throw → both reported, nothing crashes
  eq(#hl.__notifications, 1)
  hl.__fail_on = nil
  run("LOCK_SYNC_NONE", hl)
  eq(Mock.ruleNamed(hl, "omyview-lock-3"):is_enabled(), false)
  eq(Mock.ruleNamed(hl, "omyview-lock-special:scratchpad"):is_enabled(), false, "scratchpad also disabled")
  eq(#hl.__notifications, 1, "the clean retry reports nothing new")
end)
-- Distinguishes: a dead handle left in L.rules after a failed re-enable (a later re-arm would
-- keep retrying the same broken rule instead of creating a fresh one).
case("lock sync drops a dead handle after a failed re-enable, so re-arm creates a fresh rule", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  run("LOCK_SYNC_3", hl)
  local dead = Mock.ruleNamed(hl, "omyview-lock-3")
  hl.__fail_on = "rule.set_enabled"
  run("LOCK_SYNC_3", hl)
  eq(#hl.__notifications, 1, "reported")
  hl.__fail_on = nil
  run("LOCK_SYNC_3", hl)
  eq(#hl.__window_rules, 2, "the dead handle is dropped and a fresh rule created under the same name")
  local fresh = lastRuleNamed(hl, "omyview-lock-3")
  eq(fresh ~= dead, true, "a distinct rule object")
  eq(fresh:is_enabled(), true, "the fresh exclusion rule is enabled")
end)

-- Distinguishes: a running compositor whose OLD callback (the pre-addendum one, which only ever
-- called L.publish() and ignored the `kind` filter changes above it) surviving a shell restart
-- unreplaced. LOCK_OBSERVER_VERSION was bumped to 3 for exactly this; a stale subVer of 2 must be
-- replaced just like any other mismatch.
case("install over a stale subVer = 2 subscription replaces it under the current LOCK_OBSERVER_VERSION", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  local oldSub = hl.__subs[1]
  hl.__env._G.omyview_lock.subVer = 2
  run("LOCK_INSTALL", hl)
  eq(oldSub:is_active(), false, "the v2 subscription was removed")
  local active = 0
  for _, s in ipairs(hl.__subs) do if s:is_active() then active = active + 1 end end
  eq(active, 1, "exactly one active subscription")
end)

-- Quality-review fix (item 3, 2026-09-14): lockSyncLua must not fold a failing L.publish() into
-- its own ok/err report -- publishing the share-state file is the observer/install's job, so a
-- broken runtime dir must never turn "every rule reconciled fine" into a reported "lock sync
-- failed". Distinguishes: a regression that puts L.apply() (and so L.publish()) into the sync
-- chunk's own ok/err.
case("a failing publish does not fail the sync report, and rules are still reconciled", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  hl.__fail_on = "io.open"          -- would break L.ensureDir()/L.publish() if the sync called them
  run("LOCK_SYNC_3", hl)
  eq(#hl.__notifications, 0, "publish is not this chunk's job; no error reported")
  eq(Mock.ruleNamed(hl, "omyview-lock-3"):is_enabled(), true, "exclusion rule still enabled")
end)
-- Share-state hysteresis (round 3, 2026-09-14). Hyprland emits screenshare.state(true) per
-- COPIED frame and (false) from a 500 ms frame-idle timer, so a consumer pulling frames
-- irregularly (OBS on a static screen) flaps the signal for the whole recording. The observer
-- keeps `L.sharing` as the raw counter but drives the state file from `L.effective`, which only
-- goes false after LOCK_SHARE_GRACE_MS with no new start. Since round 4 the state file IS the
-- whole cue: the shell's FileView reloads on every write and the reminder frame (and the
-- overview's placeholder) follow it, so a rewrite twice a second is a visible flicker.
-- Distinguishes: an observer that applies every edge. `hl.__renames` counts committed publishes,
-- which the file's content alone could never show (every rewrite would write the same "1").
case("a flapping share signal inside the grace window rewrites no state", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  local writes = hl.__renames
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  eq(state(hl), "1", "the ON edge applies immediately, no delay")
  eq(hl.__renames, writes + 1, "exactly one publish so far")
  Mock.fire(hl, "screenshare.state", false, 0, "eDP-1")
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  Mock.fire(hl, "screenshare.state", false, 0, "eDP-1")
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  eq(hl.__renames, writes + 1, "four flapping edges committed no further publish")
  eq(state(hl), "1")
  eq(hl.__env._G.omyview_lock.effective, true, "still effectively sharing")
  eq(hl.__env._G.omyview_lock.sharing, 1, "the raw counter still tracks every edge")
  assert(Mock.pendingTimers(hl) <= 1, "at most one grace timer pending, got " .. Mock.pendingTimers(hl))
  Mock.elapse(hl, GRACE)
  eq(hl.__renames, writes + 1, "the last false's timer was cancelled by the true that followed it")
  eq(state(hl), "1")
end)
-- Distinguishes: an immediate off (the flicker's other half), or a grace shorter than
-- LOCK_SHARE_GRACE_MS.
case("a share end only takes effect once the whole grace window has passed", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  Mock.fire(hl, "screenshare.state", false, 0, "eDP-1")
  eq(state(hl), "1", "still on the moment the share stops signalling")
  Mock.elapse(hl, GRACE - 1)
  eq(state(hl), "1", "still on one millisecond before the grace expires")
  Mock.elapse(hl, 1)
  eq(state(hl), "0", "off once the grace expires")
  eq(hl.__env._G.omyview_lock.effective, false)
  eq(Mock.pendingTimers(hl), 0, "the grace timer fired and is spent")
end)
-- Distinguishes: an observer that leaves L.effective stuck true when hl.timer is missing or
-- throws on the off edge — every later ON edge would then be a no-op and every OFF edge would
-- throw again, so the frame would stay on every armed workspace until a config reload. Without a
-- timer the observer must degrade to the immediate off.
case("a share end still turns the cue off when the grace timer cannot be created", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  hl.__fail_on = "timer"
  Mock.fire(hl, "screenshare.state", false, 0, "eDP-1")
  hl.__fail_on = nil
  eq(#hl.__printed, 0, "a missing timer is a degraded path, not an error")
  eq(state(hl), "0", "off at once when no grace timer could be armed")
  eq(hl.__env._G.omyview_lock.effective, false)
  eq(Mock.pendingTimers(hl), 0)
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  eq(state(hl), "1", "the next share start still turns it on (effective was not stranded)")
end)
-- Distinguishes: an off edge from an already-idle state arming a pointless timer (a pending
-- grace must always imply L.effective == true).
case("an off edge while already idle arms no grace timer", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  Mock.fire(hl, "screenshare.state", false, 0, "eDP-1")
  eq(Mock.pendingTimers(hl), 0, "nothing to turn off, nothing armed")
  eq(#hl.__timers, 0, "no timer was even created")
  eq(state(hl), "0")
end)
-- Distinguishes: a grace timer that still fires after the share resumed — the frame would drop
-- out mid-share, which is exactly the wrong direction for a privacy reminder.
case("a share resuming inside the grace cancels the pending off", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  local writes = hl.__renames
  Mock.fire(hl, "screenshare.state", false, 0, "eDP-1")
  eq(Mock.pendingTimers(hl), 1, "one grace timer armed by the off edge")
  Mock.elapse(hl, 1000)
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  eq(hl.__timers[1]:is_enabled(), false, "the pending off was cancelled")
  eq(hl.__renames, writes, "no publish since the one the share start committed")
  eq(state(hl), "1")
  Mock.elapse(hl, 5000)                       -- well past the cancelled timer's original deadline
  eq(state(hl), "1", "still on: the cancelled timer can never fire")
end)
-- Distinguishes: a sync republishing the state file. It cannot have changed (only the observer
-- moves L.sharing/L.effective), and every write makes the shell reload and re-evaluate the frame.
case("a sync while sharing publishes nothing", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  local writes = hl.__renames
  run("LOCK_SYNC_3", hl); run("LOCK_SYNC_NONE", hl)
  eq(hl.__renames, writes, "a sync never touches the state file")
  eq(state(hl), "1", "and the published value still stands")
end)
-- Distinguishes: a running compositor whose v3 callback (applies every edge, no grace) survives
-- a shell restart — it would keep rewriting the state file twice a second. LOCK_OBSERVER_VERSION
-- was bumped to 4 for exactly this; mirrors the subVer = 2 case above.
case("install over a stale subVer = 3 (pre-hysteresis) subscription replaces it under the current LOCK_OBSERVER_VERSION", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  local oldSub = hl.__subs[1]
  hl.__env._G.omyview_lock.subVer = 3
  run("LOCK_INSTALL", hl)
  eq(oldSub:is_active(), false, "the v3 subscription was removed")
  local active = 0
  for _, s in ipairs(hl.__subs) do if s:is_active() then active = active + 1 end end
  eq(active, 1, "exactly one active subscription")
end)

-- Distinguishes: sync before install silently doing nothing.
case("lock sync before install reports", function()
  local hl = Mock.new({}); run("LOCK_SYNC_3", hl)
  eq(#hl.__notifications, 1); eq(#hl.__window_rules, 0)
  assert(hl.__notifications[1].text:find("lock not installed", 1, true), "names the reason")
end)
-- Distinguishes: a failed mkdir poisoning L.dir (a later install could never retry), and a
-- failed write replacing valid state.
case("lock install: mkdir failure is reported and retried; write failure leaves state intact", function()
  local hl = Mock.new({})
  hl.__fail_on = "mkdir"; run("LOCK_INSTALL", hl)
  eq(#hl.__notifications, 1, "mkdir failure reported"); eq(state(hl), nil, "nothing published")
  -- The observer is created before the dir/publish step ever runs, so a broken runtime dir must
  -- not take it down with it.
  eq(#hl.__subs, 1, "subscription exists despite mkdir failure")
  hl.__fail_on = nil; run("LOCK_INSTALL", hl)
  eq(state(hl), "0", "retry succeeded"); eq(#hl.__mkdirs, 2, "mkdir attempted again")
  hl.__fail_on = "io.open"; Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  eq(state(hl), "0", "failed write did not replace the state")
  -- [2], not a count: the earlier mkdir failure already logged one line via reportLua; this is
  -- the observer's own (separate) failure log, on top of it.
  assert(hl.__printed[2] and hl.__printed[2]:find("share observer failed", 1, true), "observer failure logged")
end)
-- Distinguishes: a close failure silently committing the temp file's content as if it were the
-- real state, or leaving the temp file behind instead of cleaning it up.
case("lock install: publish close failure leaves state intact and is logged", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  hl.__fail_on = "io.close"
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  eq(state(hl), "0", "no rename happened")
  assert(hl.__printed[#hl.__printed]:find("share observer failed", 1, true), "observer failure logged")
end)
-- Distinguishes: the `not w` half of the write-failure guard from the close-failure half above
-- (a write failure must be caught on its own, not only incidentally via the close check).
case("lock install: publish write failure leaves state intact and is logged", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  hl.__fail_on = "io.write"
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  eq(state(hl), "0", "no rename happened")
  assert(hl.__printed[#hl.__printed]:find("share observer failed", 1, true), "observer failure logged")
end)
-- Distinguishes: a rename failure silently committing state (or the write not being cleaned up
-- when the rename that would have published it fails).
case("lock install: publish rename failure leaves state intact and is logged", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  hl.__fail_on = "rename"
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  eq(state(hl), "0", "no rename happened")
  eq(hl.__files[hl.__os.getenv("XDG_RUNTIME_DIR") .. "/omyview/share-state.tmp"], nil, "tmp removed on failure")
  assert(hl.__printed[#hl.__printed]:find("share observer failed", 1, true), "observer failure logged")
end)

-- Distinguishes: a notify builder that interpolates raw text into the chunk (a backslash or a
-- quote would break out of the Lua string, or a real newline would break the single-line
-- chunk) instead of escaping/flattening it first.
case("notification text round-trips a backslash, a quote and a newline safely", function()
  local hl = Mock.new({})
  run("NOTIFY", hl)
  eq(#hl.__notifications, 1, "one notification")
  eq(hl.__notifications[1].text, 'bad \\ " line break')
end)
-- Distinguishes: escaping before truncating (a backslash landing right at the 200-character cut
-- can have its escape pair split, leaving a lone trailing "\" that escapes the chunk's own
-- closing quote and makes it unparseable -- caught here because `run()` already had to `load()`
-- the chunk to get this far) from truncating the raw text first, which this chunk does.
case("a notification over the 200-character budget still parses and is marked truncated", function()
  local hl = Mock.new({})
  run("NOTIFY_LONG", hl)
  eq(#hl.__notifications, 1, "one notification")
  local text = hl.__notifications[1].text
  -- "…" is a 3-byte UTF-8 sequence; Lua strings are raw bytes, so the marker's length in
  -- bytes (not characters) is what :sub needs here.
  assert(text:sub(-#"…") == "…", "truncated text ends with the ellipsis marker, got: " .. text)
end)

if failures > 0 then io.stderr:write(failures .. " Lua chunk test(s) failed\n"); os.exit(1) end
print("PASS: Lua chunk behaviour suite")
