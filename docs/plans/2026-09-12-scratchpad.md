# Omyview — Scratchpad Row Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ctrl+S in the overview shows Omarchy's scratchpad (`special:scratchpad`) as its own row below the workspaces — a real box that is selectable, searchable, a drop target, and later lockable — hidden again on every open.

**Architecture:** The scratchpad is a first-class workspace in the existing box/tile pipeline. `buildInput()` identifies it **by name** and remaps Hyprland's dynamically allocated id (and its windows' `workspaceId`) onto the constant `Logic.SCRATCHPAD_ID = -2`, so a synthetic empty row and a real scratchpad share one id and nothing downstream transitions. `Logic.layout` appends one trailing group with a header band and one cell. Dispatches name the workspace (`Logic.wsSelector`). The "negative id means none" checks become `Logic.hasWs` (only -1 is "none"). A guarded Lua chunk brings the scratchpad up on Enter. Hiding the row clears pending drops into it so no optimistic tile is orphaned.

**Tech Stack:** QML/Qt Quick, Quickshell 0.3.1, Hyprland 0.56.2 Lua mode (`hl.get_active_special_workspace`, `hl.dsp.workspace.toggle_special`, `hl.dsp.window.move` by workspace name). Tests: `mise run test` (Tier 1 `tests/tst_*.qml`, offscreen UI `tests/ui/*.qml`, Lua chunk parse + behaviour suite via `tests/lua-check.sh`).

**Spec:** `docs/specs/2026-09-12-scratchpad-design.md` (read it first). Branch `scratchpad` (off `main` 4382847; spec committed there).

---

## Conventions (every task)

**Branch:** `git checkout scratchpad`. Work in `~/Source/omyview`.

**Test loop:** `mise run test` runs `tests/run.sh`: every `tests/tst_*.qml` (pure logic), then `tests/ui/run.sh` (builds an offscreen fixture from production QML with `tests/ui/prepare.py`, runs every UI file it copies), then `tests/lua-check.sh` (renders the Lua chunks through a throwaway QML test, parses each with real Lua, runs `tests/lua/tst_chunks.lua` against `tests/lua/mock_hl.lua`). One logic file: `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/tst_layout.qml`. One UI test: `bash tests/ui/run.sh Scratchpad::test_name`. Lua only: `bash tests/lua-check.sh`.

**Fixture facts:** `prepare.py` rewrites `Hyprland.` → `compositor.` (a QtObject with `monitors`, `workspaces`, `focusedWorkspace`, `focusedMonitor`, a `commands` array appended by `dispatch()`), `PanelWindow` → a 1200×800 Item, and injects `property alias test…` hooks. `OmyviewConfig` stub: `hint: true`, `workspaces: 0` (no padding — the fixture shows exactly the seeded workspaces). `buildInput()` reads `ws.id`, `ws.name`, `ws.monitor`, `ws.toplevels.values[i].lastIpcObject`. Quickshell's `HyprlandWorkspace` exposes `name` (e.g. `"special:scratchpad"`) in production.

**Gotchas (verified on this branch's ancestors):** Qt 6.4 on CI rejects legacy reserved words (`long`, `short`, `int`, `char`, `float`, `double`, `byte`, `boolean`, `final`, `native`) as identifiers in QML/JS — never use them. `ListModel` roles are fixed at the first `append` — a new role must be in every `append` object. Every Hyprland dispatch is one single-line Lua chunk; guarded steps go through `run(`, never bare `hl.dispatch(` (lua-check enforces the shape). `Keys.onPressed` handles Ctrl/Alt/Meta chords in its FIRST branch; only Ctrl+Backspace acts today. The lua-check mock must apply every dispatcher a chunk uses — never stub one as a no-op.

**Live-test loop:**
```bash
LIVE="$HOME/.config/omarchy/plugins/se.mindfulstack.omyview"
cp logic.js WindowTile.qml FindBar.qml Overview.qml "$LIVE"/ && omarchy restart shell
```
Then SUPER+P, Ctrl+S. `journalctl --user -t omarchy-shell -n 50` shows QML errors. The installed dir is a git clone on `main`; the copies make it dirty, which is expected until the PR merges.

**Commit style:** `feat(scratchpad): …`, `test(scratchpad): …`, `docs(scratchpad): …`; body says *why*. End every commit message with:
```
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TBiFEERoyvnRjSjS75WkX2
```

---

## Task 1: Pure logic — constants, sentinel helpers, trailing group, name-targeted chunks

**Files:**
- Modify: `logic.js` (new section after the Find section at the end; `layout()`; `floatingMoveLua()`)
- Modify: `tests/tst_layout.qml`
- Modify: `tests/lua-check.sh` (render two more chunks), `tests/lua/mock_hl.lua`, `tests/lua/tst_chunks.lua`

- [ ] **Step 1: Write the failing layout/helper tests**

Add inside the `TestCase` in `tests/tst_layout.qml` (it already has `params`, `edp()`, `hdmi()`, `boxById()`):

```qml
    function scratchInput(extra) {
        var wss = [ { id: 1, monitorName: "eDP-1", focused: true, occupied: true },
                    { id: 2, monitorName: "eDP-1", focused: false, occupied: false },
                    { id: Logic.SCRATCHPAD_ID, monitorName: "eDP-1", special: "scratchpad",
                      focused: false, occupied: true } ]
        return { monitors: [edp()], workspaces: wss, windows: extra || [],
                 focusedMonitorName: "eDP-1", availW: 1632, params: params }
    }
    // Distinguishes: the scratchpad laid out inside the monitor group (a third cell on the
    // row), or without its own header band in single-monitor mode.
    function test_scratchpad_group_is_appended_below_with_a_header() {
        var r = Logic.layout(scratchInput())
        compare(r.groups.length, 2)
        compare(r.groups[0].headerH, 0, "single-monitor group keeps no band")
        compare(r.groups[1].special, "scratchpad")
        compare(r.groups[1].headerH, 22, "the scratchpad row always has a band")
        compare(r.groups[1].focused, false)
        verify(r.groups[1].y >= r.groups[0].y + r.groups[0].h + params.rowSpacing - 0.5, "below the last group")
        var s = boxById(r, Logic.SCRATCHPAD_ID)
        verify(s !== null, "one box for the scratchpad")
        compare(s.special, "scratchpad")
        compare(s.w, r.cell.w); compare(s.h, boxById(r, 1).h, "same monitor, same cell height")
        compare(s.y, r.groups[1].y + 22, "under the band")
        fuzzyCompare(r.canvasSize.h, s.y + s.h, 0.5)
    }
    // Distinguishes: the row height taken from the focused monitor instead of the scratchpad's.
    function test_scratchpad_box_height_follows_its_own_monitor() {
        var input = scratchInput()
        input.monitors = [edp(), hdmi()]
        input.workspaces.push({ id: 6, monitorName: "HDMI-A-1", focused: false, occupied: false })
        input.workspaces[2].monitorName = "HDMI-A-1"
        var r = Logic.layout(input)
        compare(boxById(r, Logic.SCRATCHPAD_ID).h, boxById(r, 6).h)
        verify(boxById(r, Logic.SCRATCHPAD_ID).h !== boxById(r, 1).h)
        compare(r.groups.length, 3); compare(r.groups[2].special, "scratchpad")
    }
    // Distinguishes: a special group that appears even when no special workspace is in the input.
    function test_no_scratchpad_group_without_a_special_workspace() {
        var input = scratchInput(); input.workspaces.pop()
        var r = Logic.layout(input)
        compare(r.groups.length, 1); compare(boxById(r, Logic.SCRATCHPAD_ID), null)
    }
    // Distinguishes: a tiled scratchpad window dropped or drawn as floating (layer 2).
    function test_tiled_window_on_the_scratchpad_renders_as_a_tiled_tile() {
        var r = Logic.layout(scratchInput([
            { address: "0xT", cls: "x", ax: 0, ay: 26, sw: 1024, sh: 1254, workspaceId: Logic.SCRATCHPAD_ID,
              floating: false, fullscreen: 0 }]))
        var t = null
        for (var i = 0; i < r.tiles.length; i++) if (r.tiles[i].address === "0xT") t = r.tiles[i]
        verify(t !== null); compare(t.layer, 1); compare(t.workspaceId, Logic.SCRATCHPAD_ID)
    }
    // Distinguishes: `hasWs` written as `>= 0` (rejects -2) or as `!== undefined` (accepts -1).
    function test_hasWs_accepts_the_scratchpad_and_rejects_none() {
        verify(Logic.hasWs(Logic.SCRATCHPAD_ID)); verify(Logic.hasWs(1)); verify(Logic.hasWs(10))
        verify(!Logic.hasWs(-1)); verify(!Logic.hasWs(undefined)); verify(!Logic.hasWs(null)); verify(!Logic.hasWs(NaN))
    }
    // Distinguishes: dispatching the scratchpad by id (Hyprland's id is dynamic) instead of by name.
    function test_wsSelector_names_the_scratchpad() {
        compare(Logic.wsSelector(Logic.SCRATCHPAD_ID), "special:scratchpad")
        compare(Logic.wsSelector(3), "3")
        verify(Logic.isScratchpad(Logic.SCRATCHPAD_ID)); verify(!Logic.isScratchpad(2)); verify(!Logic.isScratchpad(-1))
    }
    // Distinguishes: floatingMoveLua emitting a numeric target for the scratchpad ("-2" is not a
    // workspace Hyprland knows) or comparing "same workspace" by id.
    function test_floating_move_to_the_scratchpad_uses_the_name() {
        var lua = Logic.floatingMoveLua("0xabc", Logic.SCRATCHPAD_ID, { x: 10, y: 20 })
        verify(lua.indexOf('workspace = "special:scratchpad"') >= 0)
        verify(lua.indexOf('w.workspace.name == "special:scratchpad"') >= 0)
        verify(lua.indexOf('"-2"') < 0)
        var normal = Logic.floatingMoveLua("0xabc", 3, { x: 10, y: 20 })
        verify(normal.indexOf('workspace = "3"') >= 0); verify(normal.indexOf('w.workspace.id == 3') >= 0)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/tst_layout.qml`
Expected: the seven new tests FAIL (`Logic.SCRATCHPAD_ID` is `undefined`, so `scratchInput` builds a workspace with `id: undefined`; `hasWs`/`wsSelector`/`isScratchpad` "is not a function"). Every existing Layout test still passes.

- [ ] **Step 3: Add the constants and helpers to `logic.js`**

Append at the end of `logic.js`:

```js
// ---- Scratchpad (docs/specs/2026-09-12-scratchpad-design.md) ---------------------------
// Hyprland allocates special-workspace ids dynamically (the next free id below -99), so the
// overview never uses the reported id: buildInput() identifies the scratchpad by name and remaps
// it, and its windows, onto this constant. It cannot collide: regular ids are >= 1, -1 is the
// "none" sentinel, Hyprland's special ids are <= -99.
var SCRATCHPAD_ID = -2
var SCRATCHPAD_NAME = "special:scratchpad"
function isScratchpad(id) { return id === SCRATCHPAD_ID }
// "Has a workspace": only -1 means none. Replaces every `id >= 0` test that meant that, so
// the scratchpad's negative id is legal wherever a selection or target is checked.
function hasWs(id) { return typeof id === "number" && isFinite(id) && id !== -1 }
// Dispatch target: the scratchpad by name, a normal workspace by id.
function wsSelector(id) { return isScratchpad(id) ? SCRATCHPAD_NAME : String(id) }
```

- [ ] **Step 4: Append the trailing group in `layout()`**

In `layout()`, right after the monitor-group `for (var r = 0; r < order.length; r++) { … }` loop (i.e. after its closing brace and before `// Tiled windows that are not fullscreen …`), insert:

```js
    // Trailing scratchpad group (a special workspace shown on demand): its own header band —
    // always, even when the monitor groups have none — and one cell, below every monitor group.
    // The monitor loop above skips negative ids, so the scratchpad never lands in a monitor row.
    for (var si = 0; si < input.workspaces.length; si++) {
        var sws = input.workspaces[si]; if (!sws.special) continue
        if (groups.length) y += P.rowSpacing
        var sgroup = { monitorName: sws.monitorName, special: sws.special, x: 0, y: y, w: 0, h: 0,
                       inset: inset, headerH: P.headerH, focused: false }
        groups.push(sgroup)
        y += inset + P.headerH
        var sbox = { workspaceId: sws.id, monitorName: sws.monitorName, monFocused: false,
                     special: sws.special, x: inset, y: y, w: cw, h: cellHeightFor(monByName[sws.monitorName]),
                     focused: !!sws.focused, occupied: !!sws.occupied }
        boxes.push(sbox); boxByWs[sbox.workspaceId] = sbox
        y += sbox.h + inset
        sgroup.w = cw + 2 * inset; sgroup.h = y - sgroup.y
        if (sgroup.w > canvasW) canvasW = sgroup.w
    }
```

Property: `_orderedMonitorNames`, `padWorkspaces` and the monitor-group loop all skip `ws.id < 0`, so the scratchpad (-2) reaches only this loop. Do not change those skips. `cellHeightFor(undefined)` falls back to 16:10, which is what the synthetic row on an unknown monitor gets.

- [ ] **Step 5: Name-target the floating move chunk**

In `floatingMoveLua(addr, targetWs, pos)` replace the first line and the `same` line:

```js
function floatingMoveLua(addr, targetWs, pos) {
    var ws = wsSelector(targetWs)
    var x = Math.round(pos.x), y = Math.round(pos.y)
    var same = isScratchpad(targetWs)
        ? 'w.workspace ~= nil and w.workspace.name == "' + SCRATCHPAD_NAME + '"'
        : 'w.workspace ~= nil and w.workspace.id == ' + ws
    return (
        'function()\n' +
        '  local sel = "address:' + addr + '"\n' +
        '  local w = hl.get_window(sel)\n' +
        '  if not w or not w.floating then return end\n' +
        '  local prevW, cur = hl.get_active_window(), hl.get_cursor_pos()\n' +
        '  ' + dispatchGuardLua() + '\n' +
        '  local same = ' + same + '\n' +
        '  local ok, err = pcall(function()\n' +
        '    if not same then run(hl.dsp.window.move({ workspace = "' + ws + '", follow = false, window = sel })) end\n' +
        '    run(hl.dsp.window.move({ x = "' + x + '", y = "' + y + '", window = sel }))\n' +
        '  end)\n' +
        '  ' + reportLua('floating move') + '\n' +
        '  ' + restoreFocusLua('prevW', 'cur') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}
```

Property: for a numeric target the emitted chunk is byte-identical to before (`String(3)` is what `String(parseInt(3, 10))` gave), so the existing FLOATING_MOVE Lua cases and drag UI tests keep passing unchanged.

- [ ] **Step 6: Add the show chunk**

Append to `logic.js` after `wsSelector`:

```js
// Enter on the scratchpad box: bring the scratchpad up on the focused monitor, like SUPER+S —
// but never hide one that is already up. One guarded chunk, reported like the others.
function scratchpadShowLua() {
    return (
        'function()\n' +
        '  ' + dispatchGuardLua() + '\n' +
        '  local ok, err = pcall(function()\n' +
        '    local ws = hl.get_active_special_workspace()\n' +
        '    if not (ws and ws.name == "' + SCRATCHPAD_NAME + '") then run(hl.dsp.workspace.toggle_special("scratchpad")) end\n' +
        '  end)\n' +
        '  ' + reportLua('show scratchpad') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}
```

- [ ] **Step 7: Run the layout tests**

Run: `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/tst_layout.qml`
Expected: all pass (the seven new ones included).

- [ ] **Step 8: Extend the Lua harness — render, mock, cases**

`tests/lua-check.sh`: in the heredoc `test_dump()` add two lines after the FLOATING_MOVE one, and raise the count check from 4 to 6:

```qml
        console.log("CHUNK FLOATING_MOVE_SCRATCH " + Logic.floatingMoveLua("0xabc", Logic.SCRATCHPAD_ID, { x: 200, y: 1600 }))
        console.log("CHUNK SCRATCHPAD_SHOW " + Logic.scratchpadShowLua())
```
```bash
if [ "$qml_status" -ne 0 ] || [ "$count" -lt 6 ]; then
  echo "FAIL: $RUNNER exited $qml_status; expected 6 generated Lua chunks, got $count (silent/empty output must not pass)" >&2
```

`tests/lua/mock_hl.lua` in `M.new`: add state, a getter, a dispatcher, and apply it (never a no-op):

```lua
  hl.__active_special = opts.active_special or nil          -- { name = "special:…" } or nil
  function hl.get_active_special_workspace() return hl.__active_special end
```
in `hl.dsp`, add `workspace = { toggle_special = d("workspace.toggle_special") },` and in `hl.dispatch` before the final `return { ok = true, … }`:
```lua
    elseif desc.name == "workspace.toggle_special" then
      local name = "special:" .. tostring(desc.args)
      if hl.__active_special and hl.__active_special.name == name then hl.__active_special = nil
      else hl.__active_special = { name = name } end
```
and make `window.move` understand a named target (currently `tonumber(a.workspace)` would yield `nil`):
```lua
      if a.workspace then
        local n = tonumber(a.workspace)
        w.workspace = n and { id = n } or { id = -99, name = a.workspace }
      end
```

`tests/lua/tst_chunks.lua`: add cases (before the final summary lines):

```lua
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
  seq(hl, { "window.move", "window.move", "cursor.move" })   -- restoreFocusLua always restores the cursor
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
```

Property: `seq(hl, {})` in the "already up" case must be a real assertion — the mock records every dispatch, so an unconditional toggle would show one entry and fail. The fourth case fails if `run(` is replaced by bare `hl.dispatch(` (no error, no notification).

- [ ] **Step 9: Run lua-check and the full suite**

Run: `bash tests/lua-check.sh`
Expected: `PASS: 6 generated Lua chunks parse` and every case `ok`, including the six new ones. Then `mise run test`: all green.

- [ ] **Step 10: Commit**

```bash
git add logic.js tests/tst_layout.qml tests/lua-check.sh tests/lua/mock_hl.lua tests/lua/tst_chunks.lua
git commit -m "feat(scratchpad): constant overview id, hasWs/wsSelector, trailing layout group, show chunk

Hyprland's special-workspace ids are dynamic, so the overview keys the scratchpad on a
constant (-2) and dispatches by name. The layout appends one trailing group with its own header
band. The show chunk toggles the scratchpad only when it is not already up."
```

---

## Task 2: Overview wiring — input remap, toggle, keys, labels, chips — with the UI fixture

This task builds `tests/ui/scratchpad.qml`, the fixture every later scratchpad assertion runs through. It must genuinely reproduce: a special workspace **identified by name with a non--98 id** (so id independence is real, not assumed), windows on it that carry the remapped id, and the row's absence by default. The fixture cannot supply Hyprland's own special-id allocation; it records the seeded id in `scratchHyprId` so tests reason about it explicitly. It must not collapse "the scratchpad" and "a normal workspace" — the special row is keyed by `name`, never by the sign of the id, because a test that treats any negative id as the scratchpad would pass on a fixture where the two were wrongly identical.

**Files:**
- Modify: `Overview.qml` — `buildInput()`, new `scratchpadShown` + `toggleScratchpad()`, `open()`, `jump()`, the chord branch of `Keys.onPressed`, `wsLabel()`, `applyBoxes` row, the sentinel checks (`rebuild` keepId, `restorePreQuerySelection`, Enter, drop release), the backdrop and chip repeaters, the hint model
- Modify: `tests/ui/prepare.py` (aliases), `tests/ui/run.sh` (copy the new file)
- Create: `tests/ui/scratchpad.qml`

- [ ] **Step 1: Fixture plumbing**

`tests/ui/run.sh`, after the find.qml copy line:
```bash
cp "$src/tests/ui/scratchpad.qml" "$fixture/tst_scratchpad_ui.qml"
```
`tests/ui/prepare.py`, in the injected alias block:
```python
    property alias testHintModel: hintKeys.model
    property alias testBoxes: boxesModel
```
(`hintKeys` is the id Step 6 gives the hint Repeater — so also add `id: hintKeys` to the hint `Repeater` in `Overview.qml` NOW, or the fixture's `Overview.qml` will not compile and every UI test, not just the new ones, fails at the Step 3 checkpoint.)

- [ ] **Step 2: Write the failing UI tests**

Create `tests/ui/scratchpad.qml`:

```qml
import QtQuick
import QtTest

TestCase {
    id: tc
    name: "Scratchpad"
    when: windowShown
    width: 1200; height: 800; visible: true
    property var view
    property var mon
    // Hyprland allocates special ids dynamically; the fixture deliberately uses one that is NOT
    // -98 (the id on the dev machine) so every assertion on -2 proves the remap, not a coincidence.
    readonly property int scratchHyprId: -73   // lowercase: QML property names cannot start with a capital
    Component { id: overview; Overview {} }

    function client(addr, cls, title, x, floating) {
        return { address: addr, at: [x, 1500], size: [500, 400], floating: !!floating,
                 title: title, "class": cls, fullscreen: 0 }
    }
    function wsRow(id, clients, name) {
        return { id: id, name: name === undefined ? String(id) : name, monitor: mon,
                 toplevels: { values: clients.map(function (c) { return { lastIpcObject: c } }) } }
    }
    // ws1: 0xA chromium (tiled) · ws2: 0xB Slack (floating) · scratchpad: 0xS Bitwarden (floating)
    function seed(v, withScratch) {
        mon = { name: "TEST", x: 0, y: 1440, width: 1920, height: 1080,
                scale: 1, lastIpcObject: { reserved: [0, 26, 0, 0], transform: 0 } }
        v.compositor.monitors = { values: [mon] }
        v.compositor.focusedMonitor = mon
        v.compositor.focusedWorkspace = { id: 1 }
        var rows = [ wsRow(1, [client("0xA", "chromium", "Chromium", 100, false)]),
                     wsRow(2, [client("0xB", "Slack", "Slack", 100, true)]) ]
        if (withScratch !== false)
            rows.push(wsRow(scratchHyprId, [client("0xS", "Bitwarden", "Bitwarden", 900, true)], "special:scratchpad"))
        v.compositor.workspaces = { values: rows }
    }
    function init() {
        view = createTemporaryObject(overview, tc)
        verify(view !== null)
        view.motion.scale = 0
        seed(view)
        view.open()
        wait(400)
    }
    function cleanup() { view.close() }
    function boxOf(wsId) {
        for (var i = 0; i < view.boxes.length; i++) if (view.boxes[i].workspaceId === wsId) return view.boxes[i]
        return null
    }
    function row(addr) {
        for (var i = 0; i < view.testModel.count; i++)
            if (view.testModel.get(i).address === addr) return view.testModel.get(i)
        return null
    }
    function type(s) { for (var i = 0; i < s.length; i++) keyClick(s.charAt(i)) }
    function ctrlS() { keyClick("s", Qt.ControlModifier) }

    // Distinguishes: the special workspace leaking into the layout by default (the pre-feature
    // exclusion broken), and a row keyed on Hyprland's id instead of the constant.
    function test_hidden_by_default_and_shown_by_ctrl_s_with_the_constant_id() {
        compare(boxOf(-2), null); compare(boxOf(scratchHyprId), null); compare(row("0xS"), null)
        ctrlS()
        verify(boxOf(-2) !== null, "the scratchpad box uses the constant id")
        compare(boxOf(scratchHyprId), null, "Hyprland's id never reaches the layout")
        compare(boxOf(-2).special, "scratchpad")
        verify(row("0xS") !== null); compare(row("0xS").wsid, -2)
        ctrlS()
        compare(boxOf(-2), null); compare(row("0xS"), null)
    }
    // Distinguishes: the shown state surviving a close/open (spec: hidden on every open).
    function test_reopen_starts_hidden() {
        ctrlS(); verify(boxOf(-2) !== null)
        view.close(); wait(50); view.open(); wait(400)
        compare(view.scratchpadShown, false); compare(boxOf(-2), null)
    }
    // Distinguishes: Enter on the scratchpad dispatching a workspace focus by id (Hyprland has no
    // workspace -2) instead of the guarded show chunk, and the overlay staying open.
    function test_enter_on_the_scratchpad_box_shows_it_and_closes() {
        ctrlS()
        keyClick(Qt.Key_Down)                      // ws 1 → the row below: the scratchpad
        compare(view.selectedId, -2)
        keyClick(Qt.Key_Return)
        compare(view.compositor.commands.length, 1)
        var cmd = view.compositor.commands[0]
        verify(cmd.indexOf('workspace.toggle_special("scratchpad")') >= 0, "show chunk, got: " + cmd)
        verify(cmd.indexOf('get_active_special_workspace') >= 0, "guarded against hiding")
        verify(cmd.indexOf('workspace = "-2"') < 0)
        compare(view.opened, false)
    }
    // Distinguishes: a box click on the scratchpad going through the numeric jump.
    function test_click_on_the_empty_scratchpad_box_shows_it() {
        seed(view, false); ctrlS()                 // empty scratchpad: nothing but the box
        var b = boxOf(-2); verify(b !== null)
        var p = view.testCanvas.mapToItem(tc, b.x + b.w / 2, b.y + b.h / 2)
        mouseClick(tc, p.x, p.y, Qt.LeftButton)
        verify(view.compositor.commands[0].indexOf('toggle_special') >= 0)
        compare(view.opened, false)
    }
    // Distinguishes: the synthetic empty row missing when Hyprland reports no scratchpad.
    function test_empty_scratchpad_still_gets_a_row() {
        seed(view, false); view.rebuild()
        ctrlS()
        var b = boxOf(-2); verify(b !== null, "synthetic row")
        compare(b.occupied, false)
        compare(view.testModel.count, 2, "no tiles in it")
    }
    // Distinguishes: find matching scratchpad windows while hidden, or not matching them when shown.
    function test_find_matches_scratchpad_windows_only_while_shown() {
        type("bitwarden")
        compare(view.matches.length, 0)
        ctrlS()
        compare(view.matches.length, 1); compare(view.selectedMatchAddress, "0xS")
        compare(row("0xS").selectedMatch, true)
        ctrlS()
        compare(view.matches.length, 0)
        compare(view.query, "bitwarden", "toggling the row never touches the query")
    }
    // Distinguishes: a digit reaching the scratchpad (there is no digit for it) — "2" must jump
    // to workspace 2 with the row shown, exactly as without it.
    function test_digits_never_target_the_scratchpad() {
        ctrlS()
        keyClick("2")
        verify(view.compositor.commands[0].indexOf('workspace = "2"') >= 0)
        compare(view.opened, false)
    }
    // Distinguishes: labels for the scratchpad rendering "-2".
    function test_labels_and_hint() {
        compare(view.wsLabel(-2), "S"); compare(view.wsLabel(10), "0"); compare(view.wsLabel(3), "3")
        var hints = view.testHintModel, found = false
        for (var i = 0; i < hints.length; i++) if (hints[i].k === "ctrl+s") found = true
        verify(found, "hint row advertises ctrl+s")
    }
    // Distinguishes: the box selection lost when the row it sits on is hidden.
    function test_hiding_the_selected_row_moves_the_selection_to_a_real_box() {
        ctrlS(); keyClick(Qt.Key_Down); compare(view.selectedId, -2)
        ctrlS()
        verify(view.selectedId !== -2 && view.selectedId !== -1, "selection lands on a workspace")
    }
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `bash tests/ui/run.sh`
Expected: every `Scratchpad::` test FAILs — `ctrlS()` does nothing yet (Ctrl chords are swallowed), so `boxOf(-2)` stays `null`; `view.scratchpadShown` is `undefined`; `view.testHintModel` is undefined until Step 6. `Drag::` and `Find::` all still pass.

- [ ] **Step 4: `Overview.qml` — state, input remap, toggle, open reset**

Add after `property var _windows: []` (find state block):

```qml
    // Scratchpad row (docs/specs/2026-09-12-scratchpad-design.md): shown on demand for this
    // summon only. buildInput() remaps Hyprland's dynamic special id onto Logic.SCRATCHPAD_ID.
    property bool scratchpadShown: false
    // Hide the row (toggle-off and every open()). A drop into the scratchpad still unacknowledged
    // must go with it: a window on a hidden scratchpad is not in the input, so nothing could
    // acknowledge it and applyTiles would keep the optimistic tile until the deadline. The next
    // rebuild removes the row, or returns the tile to its authoritative place if the move has
    // not landed yet.
    function hideScratchpad() {
        scratchpadShown = false
        for (var a in pendingMoves)
            if (pendingMoves[a].workspaceId === Logic.SCRATCHPAD_ID) delete pendingMoves[a]
    }
    function toggleScratchpad() {
        if (scratchpadShown) hideScratchpad(); else scratchpadShown = true
        rebuild()
    }
```

Rewrite the workspace loop in `buildInput()`:

```qml
        var focusedMonitorName = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
        var wss = [], hws = Hyprland.workspaces ? Hyprland.workspaces.values : []
        var focusedWsId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
        var wins = [], haveScratch = false
        for (var j = 0; j < hws.length; j++) {
            var ws = hws[j]; if (!ws) continue
            var special = ""
            if (ws.id < 0) {
                // Special workspaces: only the scratchpad, only while shown, identified by name.
                if (!scratchpadShown || ws.name !== Logic.SCRATCHPAD_NAME) continue
                special = "scratchpad"; haveScratch = true
            }
            var wsId = special ? Logic.SCRATCHPAD_ID : ws.id
            var mon = ws.monitor
            wss.push({ id: wsId, monitorName: mon ? mon.name : "?", special: special,
                       focused: ws.id === focusedWsId,
                       occupied: ws.toplevels && ws.toplevels.values.length > 0 })
            var tls = ws.toplevels ? ws.toplevels.values : []
            for (var t = 0; t < tls.length; t++) {
                var o = tls[t] ? tls[t].lastIpcObject : null
                if (!o || !o.at || !o.size || !o.address) continue
                wins.push({ address: o.address, cls: o["class"] || "", title: o.title || "",
                            ax: o.at[0], ay: o.at[1], sw: o.size[0], sh: o.size[1],
                            workspaceId: wsId, special: special, floating: !!o.floating,
                            fullscreen: Logic.fullscreenMode(o),
                            grouped: !!(o.grouped && o.grouped.length) })
            }
        }
        // Hyprland drops an emptied special workspace; the row is still a place to drop windows.
        if (scratchpadShown && !haveScratch)
            wss.push({ id: Logic.SCRATCHPAD_ID, monitorName: focusedMonitorName, special: "scratchpad",
                       focused: false, occupied: false })
        return { monitors: mons,
```
(delete the old `var focusedMonitorName = …` line that followed the loop; keep the rest of the return unchanged.)

In `open()`, on the line `targetScreen = focusedScreen(); selectedIndex = -1; opened = true` insert `hideScratchpad();` before `selectedIndex = -1` — the same cleanup as toggle-off, so a close/reopen during a pending drop cannot leave the optimistic tile behind either (the first `rebuild()` in `open()` then runs with the row hidden and no pending state).

Property: `haveScratch` must be set only for the **named** special workspace; the unnamed `special` (share popups) or any other special stays excluded, and the fixture's `-73` id proves the remap because nothing downstream ever sees it.

- [ ] **Step 5: `Overview.qml` — keys, jump, labels, sentinel audit**

Chord branch of `Keys.onPressed`:
```qml
                    if (chord) {
                        if (chord === Qt.ControlModifier && e.key === Qt.Key_Backspace && finding) root.setQuery("")
                        else if (chord === Qt.ControlModifier && e.key === Qt.Key_S) root.toggleScratchpad()
                        return
                    }
```
`jump()`:
```qml
    function jump(id) {
        if (!Logic.hasWs(id)) return
        if (Logic.isScratchpad(id)) { Hyprland.dispatch(Logic.scratchpadShowLua()); root.close(); return }
        Hyprland.dispatch('hl.dsp.focus({ workspace = "' + id + '" })'); root.close()
    }
```
`wsLabel`:
```qml
    function wsLabel(id) { return Logic.isScratchpad(id) ? "S" : id === 10 ? "0" : String(id) }   // matches the 1–0 keys
```
Sentinel audit — replace each `>= 0` test on a workspace id (do not touch index tests like `selectedIndex >= 0`):
- `rebuild()`: `var idx = keepId >= 0 ? …` → `var idx = Logic.hasWs(keepId) ? Logic.indexOfWorkspace(res.boxes, keepId) : -1`
- `restorePreQuerySelection()`: `preQuerySelectedId >= 0 ?` → `Logic.hasWs(preQuerySelectedId) ?`
- Enter branch: `else if (root.selectedId >= 0) root.jump(root.selectedId)` → `else if (Logic.hasWs(root.selectedId)) root.jump(root.selectedId)`
- drop release in the tile MouseArea: `if (wasMoved && targetWs >= 0)` → `if (wasMoved && Logic.hasWs(targetWs))`
`applyBoxes` row object gains `special: b.special || ""` (roles are fixed at first append).

Property: `test_hiding_the_selected_row_moves_the_selection_to_a_real_box` passes through `rebuild()`'s existing "selected workspace vanished → nearest position" branch; `hasWs(-2)` being true is what lets `keepId` be looked up (and not found) instead of short-circuited.

- [ ] **Step 6: `Overview.qml` — chips, backdrop, hint**

Add near `groups`:
```qml
    // Monitor chips and the focused-group backdrop key on how many *monitor* groups there are;
    // the scratchpad group is extra and always carries its own chip.
    readonly property bool multiMonitor: groups.filter(function (g) { return !g.special }).length > 1
```
Backdrop repeater: `model: panel.visible && root.groups.length > 1 ? root.groups : []` → `model: panel.visible && root.multiMonitor ? root.groups : []` (its delegate already has `visible: modelData.focused`, and the scratchpad group is never focused).
Chip repeater: change its model to `panel.visible ? root.groups : []` and the delegate:
```qml
                            visible: !!modelData.special || root.multiMonitor
                            text: modelData.special ? "SCRATCHPAD"
                                                    : root.monitorIcon(modelData.monitorName) + "  " + modelData.monitorName
```
Hint row: give the Repeater `id: hintKeys` and add `{ k: "ctrl+s", l: "scratchpad" }` before the `esc` entry:
```qml
                Repeater {
                    id: hintKeys
                    model: [ { k: "1–0", l: "jump" }, { k: "↑ ↓ ← →", l: "move" }, { k: "↵", l: "select" },
                             { k: "drag", l: "move window" }, { k: "type", l: "find" },
                             { k: "ctrl+s", l: "scratchpad" }, { k: "esc", l: "close" } ]
```

- [ ] **Step 7: Adjust one find test whose premise changed**

`tests/ui/find.qml` `test_ctrl_chords_are_ignored` used Ctrl+S as "a reserved chord". Ctrl+S now acts. Change it to Ctrl+K and its comment to "Ctrl+K is reserved":
```qml
    function test_ctrl_chords_are_ignored() {
        keyClick("k", Qt.ControlModifier)
```

- [ ] **Step 8: Run the suite**

Run: `mise run test`
Expected: all `Scratchpad::` tests pass, `Find::`/`Drag::`/`Layout`/Lua unchanged and green. If `test_enter_on_the_scratchpad_box_shows_it_and_closes` fails at `selectedId === -2`: `Logic.navigate("down")` from ws 1 must find the scratchpad box (it is the only box below); check the box's `y` in the fixture is greater than ws 1's.

- [ ] **Step 9: Commit**

```bash
git add Overview.qml tests/ui/prepare.py tests/ui/run.sh tests/ui/scratchpad.qml tests/ui/find.qml
git commit -m "feat(scratchpad): Ctrl+S shows the scratchpad row; Enter/click bring it up; name-based input remap

The row is hidden on every open. buildInput identifies special:scratchpad by name and remaps
it onto the constant id; the empty scratchpad still gets a synthetic row. Every 'negative id
means none' check is now Logic.hasWs. Hiding the row drops pending moves into it."
```

---

## Task 3: Drops into the scratchpad and pending-drop reconciliation

**Files:**
- Modify: `Overview.qml` — `updateDropTarget()`, `submitDrop()`
- Modify: `tests/ui/scratchpad.qml`

- [ ] **Step 1: Write the failing tests**

Add to `tests/ui/scratchpad.qml`:

```qml
    function tileOf(addr) {
        var ch = view.testCanvas.children
        for (var i = 0; i < ch.length; i++) if (ch[i].model && ch[i].model.address === addr) return ch[i]
        fail("no tile for " + addr)
    }
    // Press on a tile, hover the centre of the scratchpad box, optionally release there.
    function dragOntoScratchpad(addr, release) {
        var t = tileOf(addr), p = t.mapToItem(tc, t.width / 2, t.height / 2)
        var b = boxOf(-2), goal = view.testCanvas.mapToItem(tc, b.x + b.w / 2, b.y + b.h / 2)
        mousePress(tc, p.x, p.y, Qt.LeftButton)
        mouseMove(tc, p.x + 12, p.y + 2, 20)
        mouseMove(tc, goal.x, goal.y, 20)
        if (release !== false) mouseRelease(tc, goal.x, goal.y, Qt.LeftButton)
        return goal
    }
    // Distinguishes: the tiled-insert plan being used for the scratchpad (an insertion half while
    // hovering, a dwindle chunk on release) instead of the plain named move — and a move by id.
    function test_tiled_drop_is_a_plain_named_move() {
        ctrlS()
        var goal = dragOntoScratchpad("0xA", false)
        compare(view.dropTargetWs, -2)
        compare(view.dropTargetAddress, "", "no insertion anchor over the scratchpad")
        mouseRelease(tc, goal.x, goal.y, Qt.LeftButton)
        compare(view.compositor.commands.length, 1)
        var cmd = view.compositor.commands[0]
        verify(cmd.indexOf('workspace = "special:scratchpad"') >= 0, "named target, got: " + cmd)
        verify(cmd.indexOf('follow = false') >= 0)
        verify(cmd.indexOf('smart_split') < 0 && cmd.indexOf('cursor') < 0, "not the tiled-insert chunk")
        verify(cmd.indexOf('window.float') < 0, "tiling state is preserved")
        compare(row("0xA").wsid, -2, "optimistic tile sits in the row")
    }
    // Distinguishes: a floating drop losing its position, or naming the target by id.
    function test_floating_drop_names_the_target_and_positions() {
        ctrlS()
        dragOntoScratchpad("0xB")
        var cmd = view.compositor.commands[0]
        verify(cmd.indexOf('workspace = "special:scratchpad"') >= 0)
        verify(cmd.indexOf('x = "') >= 0, "positioned")
        verify(cmd.indexOf('workspace.name == "special:scratchpad"') >= 0, "same-workspace test by name")
    }
    // Distinguishes: a pending drop never acknowledged because the compositor reports the window
    // on Hyprland's own id (-73) while the pending target is -2 — the remap must reconcile them.
    function test_pending_drop_is_acknowledged_on_hyprlands_own_id() {
        ctrlS()
        dragOntoScratchpad("0xA")
        verify(view.pendingMoves["0xA"] !== undefined, "pending after the drop")
        compare(view.pendingMoves["0xA"].workspaceId, -2)
        // The compositor lands the window on the scratchpad (its id, its geometry).
        var rows = view.compositor.workspaces.values
        var win = rows[0].toplevels.values.shift().lastIpcObject
        rows[2].toplevels.values.push({ lastIpcObject: win })
        view.rebuild()
        compare(view.pendingMoves["0xA"], undefined, "acknowledged")
        compare(row("0xA").wsid, -2)
    }
    // Distinguishes: hiding the row before the compositor acknowledges the drop leaving the
    // optimistic tile on the canvas (applyTiles keeps pending rows; nothing could acknowledge a
    // window that is not in the input).
    function test_hiding_the_row_during_a_pending_drop_leaves_no_orphan() {
        ctrlS()
        dragOntoScratchpad("0xA")
        compare(row("0xA").wsid, -2)
        ctrlS()                                            // hide before any acknowledgement
        compare(view.pendingMoves["0xA"], undefined, "pending state dropped")
        compare(row("0xA").wsid, 1, "back on its authoritative workspace (the move has not landed)")
        // Now the move lands; showing the row again picks the window up from compositor data.
        var rows = view.compositor.workspaces.values
        var win = rows[0].toplevels.values.shift().lastIpcObject
        rows[2].toplevels.values.push({ lastIpcObject: win })
        view.rebuild()
        compare(row("0xA"), null, "on a hidden scratchpad: not shown")
        ctrlS()
        compare(row("0xA").wsid, -2)
    }
    // Distinguishes: open() resetting scratchpadShown without the pending cleanup — a drop into
    // the scratchpad, then close and reopen before acknowledgement, would keep the optimistic
    // tile (applyTiles retains pending rows) on a hidden row.
    function test_close_and_reopen_during_a_pending_drop_leaves_no_orphan() {
        ctrlS()
        dragOntoScratchpad("0xA")
        compare(row("0xA").wsid, -2)
        view.close(); wait(50); view.open(); wait(400)
        compare(view.scratchpadShown, false)
        compare(view.pendingMoves["0xA"], undefined, "pending state dropped on reopen")
        compare(row("0xA").wsid, 1, "back on its authoritative workspace")
        compare(boxOf(-2), null)
    }
    // Distinguishes: a scratchpad tile that cannot be dragged out, or a drag out that dispatches
    // to the scratchpad instead of the numeric target.
    function test_dragging_a_scratchpad_window_out_uses_the_numeric_target() {
        ctrlS()
        var t = tileOf("0xS"), p = t.mapToItem(tc, t.width / 2, t.height / 2)
        var b = boxOf(2), goal = view.testCanvas.mapToItem(tc, b.x + b.w / 2, b.y + b.h / 2)
        mousePress(tc, p.x, p.y, Qt.LeftButton)
        mouseMove(tc, p.x + 12, p.y + 2, 20)
        mouseMove(tc, goal.x, goal.y, 20)
        mouseRelease(tc, goal.x, goal.y, Qt.LeftButton)
        var cmd = view.compositor.commands[0]
        verify(cmd.indexOf('workspace = "2"') >= 0, "numeric target, got: " + cmd)
        verify(cmd.indexOf('special:scratchpad') < 0)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/ui/run.sh Scratchpad::test_tiled_drop_is_a_plain_named_move` (and the others)
Expected: `test_tiled_drop_is_a_plain_named_move` fails — the tiled-insert plan runs for the scratchpad (a `dropTargetAddress` is set or the chunk contains `cursor`), or the plain move emits `workspace = -2`. `test_floating_drop…` fails on the name. The pending tests fail on `pendingMoves` behaviour. `test_dragging_…_out` may already pass (existing paths) — that is fine; it guards the future.

- [ ] **Step 3: Bypass the tiled plan and name the target**

`updateDropTarget()`:
```qml
        var win = _windowByAddress[draggingAddress]
        // The scratchpad takes a plain move (no tiled anchor to split): never plan an insertion.
        var tiledDrag = win && !win.floating && !win.grouped && ws !== null && !Logic.isScratchpad(ws)
```
`submitDrop()`:
```qml
        if (!win.floating && !win.grouped && tile && !Logic.isScratchpad(targetWs)) {
```
and the plain move:
```qml
        else Hyprland.dispatch('hl.dsp.window.move({ workspace = "' + Logic.wsSelector(targetWs) +
                               '", follow = false, window = "address:' + addr + '" })')
```

Property: the plain move's target is now quoted for numeric ids too. `grep -n 'workspace = 2\b' tests/ui/drag.qml` — if any Drag test asserted the unquoted form, update it to `workspace = "2"`; Hyprland accepts both.

- [ ] **Step 4: Run the suite**

Run: `mise run test`
Expected: all green. If `test_pending_drop_is_acknowledged_on_hyprlands_own_id` still fails: `reconcileMoves` compares `win.workspaceId !== pending.workspaceId` — confirm `buildInput()` emits `workspaceId: wsId` (the remapped id) for windows on the special workspace, not `ws.id`.

- [ ] **Step 5: Commit**

```bash
git add Overview.qml tests/ui/scratchpad.qml tests/ui/drag.qml
git commit -m "feat(scratchpad): drops are plain named moves that keep tiling; pending drops reconcile on the remapped id

The tiled-insert plan is bypassed explicitly for the scratchpad target. A pending move into it
is acknowledged as soon as the window is reported on special:scratchpad, whatever id Hyprland
allocated; hiding the row first drops the pending state so no optimistic tile is orphaned."
```

---

## Task 4: Docs, live check, PR

**Files:**
- Modify: `README.md` (keys prose + table), `ROADMAP.md`, `DESIGN.md` (the "Excludes special:scratchpad" sentence under Cells and the `Select:` bullet), `docs/specs/2026-09-12-scratchpad-design.md` (only if the implementation diverged — one source of truth)

- [ ] **Step 1: README**

Prose (after the "Type to find" bullet), same style:
```
- **Scratchpad:** `Ctrl+S` shows Omarchy's scratchpad as its own row below the workspaces
  (hidden on every open). `Enter` or a click on it brings the scratchpad up; drop a window on it
  to send it there silently; find covers its windows while the row is shown.
```
Table rows before `Esc / click-out`:
```
| **Ctrl+S**                          | Show / hide the scratchpad row                        |
| **Enter / click** (scratchpad row) | Bring the scratchpad up and close                     |
```

- [ ] **Step 2: ROADMAP + DESIGN**

`ROADMAP.md`: append to Status: `Scratchpad row (2026-09-12): Ctrl+S shows special:scratchpad as a trailing row, see docs/specs/2026-09-12-scratchpad-design.md.` and add `### 8. ~~Scratchpad row~~ ✅ done (2026-09-12)` with one line pointing at the spec.
`DESIGN.md`: change `Excludes \`special:scratchpad\`.` to `\`special:scratchpad\` is excluded by default and shown as its own row on Ctrl+S (see the scratchpad spec).`

- [ ] **Step 3: Live check**

```bash
LIVE="$HOME/.config/omarchy/plugins/se.mindfulstack.omyview"
cp logic.js WindowTile.qml FindBar.qml Overview.qml "$LIVE"/ && omarchy restart shell
```
SUPER+P, Ctrl+S: a SCRATCHPAD row with the Bitwarden / extension / 1password tiles appears below the workspaces; Ctrl+S hides it; with it shown, Down from the bottom row selects it, Enter brings the scratchpad up and closes; SUPER+P again, Ctrl+S, drag a window onto it, confirm it moved (SUPER+S). `journalctl --user -t omarchy-shell -n 50` must show no QML warnings.

- [ ] **Step 4: Test, commit, PR**

Run: `mise run test` — green.
```bash
git add README.md ROADMAP.md DESIGN.md docs/specs/2026-09-12-scratchpad-design.md
git commit -m "docs(scratchpad): README keys, roadmap and design notes"
git push -u origin scratchpad
gh pr create --title "Scratchpad row" --body "$(cat <<'EOF'
Ctrl+S shows Omarchy's scratchpad (special:scratchpad) as its own row below the workspaces,
hidden again on every open. Enter or a click brings the scratchpad up (guarded: never hides one
that is already up). Drops onto it are plain silent moves that keep the window's tiling state;
find covers its windows while shown. The overview keys the scratchpad on a constant id and
identifies it by name, since Hyprland's special ids are dynamic.

Spec: docs/specs/2026-09-12-scratchpad-design.md · Plan: docs/plans/2026-09-12-scratchpad.md

Tests: Tier 1 layout/helper cases, Lua behaviour cases for the show chunk and the named floating
move, `tests/ui/scratchpad.qml` (toggle, reopen, Enter/click, empty row, find, digits, labels,
drops, pending-drop reconciliation, hide-during-pending and close/reopen-during-pending). Live-checked on the dev machine.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01TBiFEERoyvnRjSjS75WkX2
EOF
)"
```
Then `gh pr checks <n> --repo Mindful-Stack/omyview` until CI finishes — CI runs Qt 6.4 and has failed before on things Qt 6.11 accepts.

---

## Self-review notes (already applied)

- **Spec coverage:** decisions/behaviour table → Tasks 2–3 (Ctrl+S, digits, arrows via existing navigation, Enter/click via `jump`, tile click unchanged, drops, drag out, open reset); show chunk → Task 1 (+ Lua cases); layout and data (remap, synthetic row, trailing group, labels, tiles) → Tasks 1–2; sentinel audit → Task 2 Step 5 and Task 3 Step 3; visuals (chip, badge/numeral via `wsLabel`, hint) → Task 2 Step 6; edge cases (query + toggle → Task 2 find test; hide during pending drop → Task 3; docked height → Task 1 layout test; fixture id → Task 2 seed) ; tests section → Tasks 1–3.
- **Would-it-fail:** each UI test names the failure it catches; the id-independence tests use -73 so a -98 assumption cannot pass by coincidence; the "already up" Lua case asserts an empty dispatch log, which an unconditional toggle breaks.
- **Type consistency:** `SCRATCHPAD_ID`, `SCRATCHPAD_NAME`, `isScratchpad`, `hasWs`, `wsSelector`, `scratchpadShowLua`, `scratchpadShown`, `hideScratchpad`, `toggleScratchpad`, fixture `scratchHyprId`, `multiMonitor`, `hintKeys`, aliases `testHintModel`/`testBoxes`, box/group field `special`, input window field `special`.
- **Spec conflicts:** none; the spec already states the constant-id remap, tiled-preserving drops and the hide-clears-pending rule.
