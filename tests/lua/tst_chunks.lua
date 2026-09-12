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
  seq(hl, { "focus", "window.bring_to_top" })
  eq(hl.__active_window and hl.__active_window.address, "0xabc", "window is active")
  eq(hl.__top and hl.__top.address, "0xabc", "window is raised above its siblings")
  eq(#hl.__notifications, 0, "no error reported")
end)
case("scratchpad focus: focus throws → one notification, bring_to_top never runs", function()
  local hl = Mock.new({ windows = { ["0xabc"] = { address = "0xabc", floating = true, fullscreen = 0,
                                                  workspace = { id = -98, name = "special:scratchpad" } } } })
  hl.__fail_on = "focus"
  run("SCRATCHPAD_FOCUS", hl)
  eq(#hl.__notifications, 1, "one notification")
  assert(hl.__notifications[1].text:find("focus scratchpad window failed", 1, true))
  eq(hl.__seen["window.bring_to_top"], nil, "bring_to_top never ran")
end)

local function state(hl) return hl.__files[(hl.__runtime_dir or "/run/user/1000") .. "/omyview/share-state"] end
-- Distinguishes: a non-idempotent install (two layer rules / two subscriptions) or one that
-- never publishes.
case("lock install is idempotent and publishes 0", function()
  local hl = Mock.new({})
  run("LOCK_INSTALL", hl); run("LOCK_INSTALL", hl)
  eq(#hl.__layer_rules, 1, "one layer rule"); eq(#hl.__subs, 1, "one subscription")
  eq(hl.__layer_rules[1].spec.no_screen_share, true); eq(hl.__layer_rules[1].spec.match.namespace, "omyview")
  eq(state(hl), "0", "published 0"); eq(#hl.__mkdirs, 1, "mkdir once")
  eq(#hl.__notifications, 0)
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
  eq(#hl.__window_rules, 2)
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
-- publishing the wrong value; the counter not clamping.
case("share events publish 1/0 with a clamped counter and never touch rules", function()
  local hl = Mock.new({}); run("LOCK_INSTALL", hl); run("LOCK_SYNC_3", hl)
  Mock.fire(hl, "screenshare.state", true, 0, "eDP-1"); eq(state(hl), "1")
  Mock.fire(hl, "screenshare.state", true, 0, "HDMI-A-1"); Mock.fire(hl, "screenshare.state", false, 0, "eDP-1")
  eq(state(hl), "1", "two starts, one end: still sharing")
  Mock.fire(hl, "screenshare.state", false, 0, "HDMI-A-1"); eq(state(hl), "0")
  Mock.fire(hl, "screenshare.state", false, 0, "eDP-1"); eq(state(hl), "0", "clamped at 0")
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
end)
-- Distinguishes: sync before install silently doing nothing.
case("lock sync before install reports", function()
  local hl = Mock.new({}); run("LOCK_SYNC_3", hl)
  eq(#hl.__notifications, 1); eq(#hl.__window_rules, 0)
end)
-- Distinguishes: a failed mkdir poisoning L.dir (a later install could never retry), and a
-- failed write replacing valid state.
case("lock install: mkdir failure is reported and retried; write failure leaves state intact", function()
  local hl = Mock.new({})
  hl.__fail_on = "mkdir"; run("LOCK_INSTALL", hl)
  eq(#hl.__notifications, 1, "mkdir failure reported"); eq(state(hl), nil, "nothing published")
  hl.__fail_on = nil; run("LOCK_INSTALL", hl)
  eq(state(hl), "0", "retry succeeded"); eq(#hl.__mkdirs, 2, "mkdir attempted again")
  hl.__fail_on = "io.open"; Mock.fire(hl, "screenshare.state", true, 0, "eDP-1")
  -- 2, not 1: the earlier mkdir failure already logged one line via reportLua; this is the
  -- observer's own (separate) failure log, on top of it.
  eq(state(hl), "0", "failed write did not replace the state"); eq(#hl.__printed, 2, "observer failure logged")
end)

if failures > 0 then io.stderr:write(failures .. " Lua chunk test(s) failed\n"); os.exit(1) end
print("PASS: Lua chunk behaviour suite")
