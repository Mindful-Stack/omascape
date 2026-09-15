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
-- mock as `hl` and `print` captured (Hyprland rebinds print to its log).
local function run(name, hl)
  local body = assert(chunks[name], "no chunk named " .. name)
  local env = setmetatable({ hl = hl, print = function(...)
    hl.__printed[#hl.__printed + 1] = table.concat({ ... }, "\t") end }, { __index = _G })
  local f = assert(load("return " .. body, name, "t", env))
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

if failures > 0 then io.stderr:write(failures .. " Lua chunk test(s) failed\n"); os.exit(1) end
print("PASS: Lua chunk behaviour suite")
