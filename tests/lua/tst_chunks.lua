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
-- L.rules/L.borders). A border config change intentionally creates a SECOND rule with the same
-- name as the one it just disabled and dropped — this returns the LAST match instead, i.e. the
-- one still referenced by the compositor's tables.
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
  eq(#hl.__window_rules, 4, "one exclusion rule and one (disabled) border rule per selector")
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
  eq(#hl.__window_rules, 2, "same handle re-enabled, no second rule (plus the earlier border rule)")
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
-- keep retrying the same broken rule instead of creating a fresh one). `hl.__fail_on =
-- "rule.set_enabled"` is global (not scoped to one rule), so it would also reach the border's
-- own set_enabled inside the same sync's L.reconcileBorders() call — but the border is already
-- disabled and, with no share running, wants to stay disabled, and the round-3 reconcile only
-- calls set_enabled when the rule's state differs from what it wants. So the border handle is
-- never touched here at all: only the exclusion's handle (a failed ENABLE) is dropped and
-- rebuilt fresh on the next sync.
case("lock sync drops a dead handle after a failed re-enable, so re-arm creates a fresh rule", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  run("LOCK_SYNC_3", hl)
  local borderBefore = Mock.ruleNamed(hl, "omyview-lock-border-3")
  hl.__fail_on = "rule.set_enabled"
  run("LOCK_SYNC_3", hl)
  eq(#hl.__notifications, 1, "reported")
  hl.__fail_on = nil
  run("LOCK_SYNC_3", hl)
  eq(#hl.__window_rules, 3, "the exclusion's dead handle is dropped and rebuilt; the border's kept handle is reused")
  eq(lastRuleNamed(hl, "omyview-lock-3"):is_enabled(), true, "the fresh exclusion rule is enabled")
  eq(lastRuleNamed(hl, "omyview-lock-border-3"), borderBefore, "the border rule was never dropped, only retried")
  eq(borderBefore:is_enabled(), false, "the retried border rule stays disabled (not sharing)")
end)

-- Share-time reminder border (docs/specs/2026-09-12-lock-design.md, addendum, 2026-09-14).
-- Distinguishes: a border rule created enabled (it must start disabled — only L.apply() ever
-- toggles it), unnamed, matched on something other than the workspace, or missing the
-- configured colour/size -- and (round 3) a SINGLE colour value, which Hyprland's
-- parseBorderColorRule reads as the ACTIVE border only, leaving every unfocused window on the
-- armed workspace un-rimmed. The doubled form ("<c> <c>") is what sets active AND inactive.
case("lock sync creates a disabled border rule with the configured colour, doubled for inactive windows, and size, outside a share", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  run("LOCK_SYNC_3", hl)
  local border = Mock.ruleNamed(hl, "omyview-lock-border-3")
  eq(border ~= nil, true, "border rule created")
  eq(border:is_enabled(), false, "disabled outside a share")
  eq(border.spec.match.workspace, "3")
  eq(border.spec.border_color, "rgb(ff4444) rgb(ff4444)", "active AND inactive, not just the focused window")
  eq(border.spec.border_size, 6)
end)
-- Distinguishes: the border rule not following a share starting/ending, or following it for a
-- selector that is not armed. The end is only effective once the grace window has elapsed
-- (round 3) -- that debounce has its own cases below.
case("a share start enables the border rule for an armed selector; a share end disables it", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  local border = Mock.ruleNamed(hl, "omyview-lock-border-3")
  eq(border:is_enabled(), false)
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  eq(border:is_enabled(), true, "enabled: armed and a share is active")
  Mock.fire(hl, "screenshare.state", false, 0, "eDP-1")
  Mock.elapse(hl, GRACE)
  eq(border:is_enabled(), false, "disabled once the share ends")
end)
-- Distinguishes: disarming during a share leaving the border enabled (it must follow the
-- exclusion rule, not the share state alone), or re-arming not restoring it.
case("disarming during a share disables both rules; re-arming enables both", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  local excl, border = Mock.ruleNamed(hl, "omyview-lock-3"), Mock.ruleNamed(hl, "omyview-lock-border-3")
  eq(excl:is_enabled(), true); eq(border:is_enabled(), true)
  run("LOCK_SYNC_NONE", hl)
  eq(excl:is_enabled(), false, "exclusion disarmed"); eq(border:is_enabled(), false, "border follows it")
  run("LOCK_SYNC_3", hl)
  eq(excl:is_enabled(), true, "re-armed"); eq(border:is_enabled(), true, "border re-enabled: still sharing")
end)
-- Distinguishes: a colour/size change reusing the stale rule (never picking up the new value)
-- instead of disabling and dropping it so a fresh one is built; and a size of 0 leaving a stray
-- `border_size` field in the spec instead of omitting it outright.
case("a config change disables the old border rule and creates a new one with the new colour, omitting border_size at 0", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  local old = Mock.ruleNamed(hl, "omyview-lock-border-3")
  local n0 = #hl.__window_rules
  run("LOCK_SYNC_3_BLUE", hl)
  eq(old:is_enabled(), false, "old colour rule disabled")
  eq(#hl.__window_rules, n0 + 1, "a fresh border rule was created")
  local fresh = lastRuleNamed(hl, "omyview-lock-border-3")
  eq(fresh ~= old, true, "a distinct rule object")
  eq(fresh.spec.border_color, "rgb(3355ff) rgb(3355ff)", "the new colour, doubled (active + inactive)")
  eq(fresh.spec.border_size, nil, "size 0 omits border_size entirely")
  eq(fresh:is_enabled(), false, "created disabled (not sharing)")
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  eq(fresh:is_enabled(), true, "enabled now that a share is active")
end)
-- Distinguishes: a running compositor whose OLD callback only calls L.publish() (pre-border)
-- surviving a shell restart unreplaced — it would never pick up border toggling. LOCK_OBSERVER_VERSION
-- was bumped to 3 for exactly this; a stale subVer of 2 (the pre-addendum version) must be
-- replaced just like any other mismatch.
case("install over a stale subVer = 2 (pre-border) subscription replaces it under the current LOCK_OBSERVER_VERSION", function()
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
-- its own ok/err report -- publishing the share-state file is the observer/install's job
-- (L.reconcileBorders(), not L.apply(), is what a sync calls), so a broken runtime dir must never
-- turn "every rule reconciled fine" into a reported "lock sync failed". Distinguishes: a
-- regression that reintroduces L.apply() (and so L.publish()) into the sync chunk's own ok/err.
case("a failing publish does not fail the sync report, and rules are still reconciled", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl)
  hl.__fail_on = "io.open"          -- would break L.ensureDir()/L.publish() if the sync called them
  run("LOCK_SYNC_3", hl)
  eq(#hl.__notifications, 0, "publish is not this chunk's job; no error reported")
  eq(Mock.ruleNamed(hl, "omyview-lock-3"):is_enabled(), true, "exclusion rule still enabled")
  eq(Mock.ruleNamed(hl, "omyview-lock-border-3") ~= nil, true, "border rule still created")
end)
-- Quality-review fix (item 4 / minor 6-8, 2026-09-14): a border rule whose set_enabled throws
-- (inside L.reconcileBorders(), reached here via the share observer's L.apply()) must drop its
-- handle from L.borders so the next sync recreates it, exactly like a dead exclusion-rule handle
-- already does -- and that failure must never touch the exclusion rule, which L.reconcileBorders()
-- never calls set_enabled on.
-- Round 3: a second share start no longer re-affirms anything (the cue is already on, so the
-- observer does nothing at all), and a reconcile skips a rule that is already in the wanted
-- state — so the failing ENABLE is reached the way it happens in practice: a share ends, the
-- grace expires and the cue drops, then a new share starts.
case("a border rule's failed enable drops its handle; the exclusion rule is unaffected; the next sync recreates and re-enables it", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  local before = Mock.ruleNamed(hl, "omyview-lock-border-3")
  eq(before:is_enabled(), true, "enabled while sharing")
  Mock.fire(hl, "screenshare.state", false, 0, "eDP-1"); Mock.elapse(hl, GRACE)
  eq(before:is_enabled(), false, "the cue dropped when the grace expired")
  hl.__fail_on = "rule.set_enabled"
  Mock.fire(hl, "screenshare.state", true, 0, "HDMI-A-1")   -- a new share: L.apply() enables the border, and fails
  hl.__fail_on = nil
  eq(Mock.ruleNamed(hl, "omyview-lock-3"):is_enabled(), true, "exclusion rule untouched by the border's failure")
  run("LOCK_SYNC_3", hl)
  local fresh = lastRuleNamed(hl, "omyview-lock-border-3")
  eq(fresh ~= before, true, "a fresh border rule handle was created")
  eq(fresh:is_enabled(), true, "the fresh handle is enabled (still sharing)")
end)
-- Quality-review fix round 2 (item 1, 2026-09-14): a failed border DISABLE (share end, when the
-- compositor's set_enabled throws) must NOT drop the handle from L.borders the way a failed
-- ENABLE does. Rules cannot be destroyed in this Hyprland Lua API, so dropping on a failed
-- disable would leave the rule stuck ENABLED and unreachable -- the next sync would create a
-- second, disabled rule under the same name, which never undoes the first (a permanently red
-- frame with no share running, until a config reload). Mirrors lockSyncLua's own exclusion-rule
-- disable loop, which never drops a handle on a failed set_enabled(false) either.
-- Round 3: the disable now happens inside the grace timer's callback, and the retry comes from
-- the next reconcile of any kind — here the next sync (another share end would not do it: with
-- `L.effective` already false, a further `false` edge changes nothing).
case("a border rule's failed DISABLE keeps its handle so the next reconcile can retry it; no duplicate rule is created", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  local before = Mock.ruleNamed(hl, "omyview-lock-border-3")
  eq(before:is_enabled(), true, "enabled while sharing")
  hl.__fail_on = "rule.set_enabled"
  Mock.fire(hl, "screenshare.state", false, 0, "eDP-1")
  Mock.elapse(hl, GRACE)                                 -- the grace expires: L.apply() tries to disable, fails
  eq(hl.__env._G.omyview_lock.borders["3"], before, "handle kept on a failed disable, not dropped")
  eq(before:is_enabled(), true, "still enabled -- the failed disable never took")
  hl.__fail_on = nil
  run("LOCK_SYNC_3", hl)                                 -- the next reconcile retries the same handle
  eq(before:is_enabled(), false, "the retried disable on the kept handle succeeds")
  run("LOCK_SYNC_3", hl)
  eq(lastRuleNamed(hl, "omyview-lock-border-3"), before, "no duplicate rule was created under the name")
  local count = 0
  for _, r in ipairs(hl.__window_rules) do if r.spec.name == "omyview-lock-border-3" then count = count + 1 end end
  eq(count, 1, "still exactly one border rule for this selector")
end)

-- Share-state hysteresis (round 3, 2026-09-14). Hyprland emits screenshare.state(true) per
-- COPIED frame and (false) from a 500 ms frame-idle timer, so a consumer pulling frames
-- irregularly (OBS on a static screen) flaps the signal for the whole recording. The observer
-- keeps `L.sharing` as the raw counter but drives the border rules and the state file from
-- `L.effective`, which only goes false after LOCK_SHARE_GRACE_MS with no new start.
-- Distinguishes: an observer that applies every edge — the live "windows constantly resizing"
-- flicker (a border_size change relayouts the workspace) plus a state-file rewrite twice a second.
case("a flapping share signal inside the grace window toggles no rule and rewrites no state", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  local border = Mock.ruleNamed(hl, "omyview-lock-border-3")
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  eq(border:is_enabled(), true, "the ON edge applies immediately, no delay")
  eq(state(hl), "1")
  eq(border.__set_calls, 1, "exactly one toggle so far: the sync left the disabled rule alone")
  Mock.fire(hl, "screenshare.state", false, 0, "eDP-1")
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  Mock.fire(hl, "screenshare.state", false, 0, "eDP-1")
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  eq(border.__set_calls, 1, "four flapping edges asked the compositor for no further toggle")
  eq(state(hl), "1", "and rewrote no state (the shell's FileView never reloads)")
  eq(hl.__env._G.omyview_lock.effective, true, "still effectively sharing")
  eq(hl.__env._G.omyview_lock.sharing, 1, "the raw counter still tracks every edge")
  assert(Mock.pendingTimers(hl) <= 1, "at most one grace timer pending, got " .. Mock.pendingTimers(hl))
  Mock.elapse(hl, GRACE)
  eq(border.__set_calls, 1, "the last false's timer was cancelled by the true that followed it")
  eq(border:is_enabled(), true); eq(state(hl), "1")
end)
-- Distinguishes: an immediate off (the flicker's other half), or a grace shorter than
-- LOCK_SHARE_GRACE_MS.
case("a share end only takes effect once the whole grace window has passed", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  local border = Mock.ruleNamed(hl, "omyview-lock-border-3")
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  Mock.fire(hl, "screenshare.state", false, 0, "eDP-1")
  eq(border:is_enabled(), true, "still on the moment the share stops signalling")
  eq(state(hl), "1")
  Mock.elapse(hl, GRACE - 1)
  eq(border:is_enabled(), true, "still on one millisecond before the grace expires")
  eq(state(hl), "1")
  Mock.elapse(hl, 1)
  eq(border:is_enabled(), false, "off once the grace expires")
  eq(state(hl), "0")
  eq(hl.__env._G.omyview_lock.effective, false)
  eq(Mock.pendingTimers(hl), 0, "the grace timer fired and is spent")
end)
-- Distinguishes: a grace timer that still fires after the share resumed — the rim would drop out
-- mid-share, which is exactly the wrong direction for a privacy reminder.
case("a share resuming inside the grace cancels the pending off", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  local border = Mock.ruleNamed(hl, "omyview-lock-border-3")
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  Mock.fire(hl, "screenshare.state", false, 0, "eDP-1")
  eq(Mock.pendingTimers(hl), 1, "one grace timer armed by the off edge")
  Mock.elapse(hl, 1000)
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  eq(hl.__timers[1]:is_enabled(), false, "the pending off was cancelled")
  eq(border.__set_calls, 1, "no toggle since the very first enable")
  eq(state(hl), "1")
  Mock.elapse(hl, 5000)                       -- well past the cancelled timer's original deadline
  eq(border:is_enabled(), true, "still on: the cancelled timer can never fire")
  eq(state(hl), "1")
end)
-- Distinguishes: a reconcile that re-sets a rule already in the wanted state. Harmless on paper,
-- but every set_enabled on a border rule is a relayout of the workspace, and lockSyncLua runs a
-- reconcile on every arm/disarm and every config change.
case("a sync while sharing does not re-set an already-correct border rule", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  local border = Mock.ruleNamed(hl, "omyview-lock-border-3")
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  local before = border.__set_calls
  run("LOCK_SYNC_3", hl)                      -- same config, same armed set: nothing to change
  eq(border.__set_calls, before, "the already-enabled border rule was left alone")
  eq(border:is_enabled(), true, "and is still enabled")
end)
-- Distinguishes: a running compositor whose v3 callback (applies every edge, no grace) survives
-- a shell restart — it would keep flapping the rules twice a second. LOCK_OBSERVER_VERSION was
-- bumped to 4 for exactly this; mirrors the subVer = 2 case above.
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
