# Omascape — Hardening (review follow-up) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four concrete defects and the CI gap found in the post-merge review of [omascape#8](https://github.com/Mindful-Stack/omascape/pull/8) (commit `9b6a9ac`) without the large refactor: every compositor operation becomes one atomic Lua chunk whose cleanup cannot be skipped, refresh scheduling survives event floods, keyboard selection follows the workspace rather than its position, and CI actually parses and behaviour-tests the generated Lua.

**Architecture:** All Lua generation stays in the pure `.pragma library` `logic.js` (Tier-1 unit-tested offscreen, now also executed against a mock `hl` table by a real Lua 5.4 interpreter). `Overview.qml` loses the two-phase floating move (transfer, then position after acknowledgement) — the compositor does both in one chunk, so no operation depends on the overlay staying loaded. The settle timer coalesces raw events instead of restarting on each one. `rebuild()` re-resolves the selected workspace id after layout. `tests/lua-check.sh` grows from parse-only into a behaviour suite and becomes mandatory in CI.

**Tech Stack:** QML/Qt Quick 6, Quickshell 0.3.1, Hyprland 0.56.2 in Lua configuration mode. Tests: `mise run test` (`tests/run.sh` = `tests/tst_layout.qml` + `tests/ui/drag.qml` + `tests/lua-check.sh`), `mise run test-integration` (nested Hyprland + real Quickshell). Lua 5.4 (`lua5.4`), `qml` runtime (`/usr/bin/qml6` on Arch, `/usr/lib/qt6/bin/qml` from package `qml-qt6` on Ubuntu noble — **not on PATH there**).

**Spec:** the review findings summarised in the "Why" of each task below; there is no separate design doc. Branch: `hardening` (created off `origin/main` at `9b6a9ac`).

---

## Conventions (every task)

**Branch:** `git checkout hardening`.

**Unit-test loop:** `mise run test` — runs `tests/run.sh`: the pure `logic.js` tests (`tests/tst_layout.qml`), the offscreen Qt UI tests (`tests/ui/run.sh` builds a fixture from production QML with `tests/ui/prepare.py`, then runs `tests/ui/drag.qml`), then `tests/lua-check.sh`. Everything must stay green after every task. One UI test: `bash tests/ui/run.sh Drag::test_name`. One layout test: `/usr/lib/qt6/bin/qmltestrunner -input tests Layout::test_name` (Arch path; `qmltestrunner6` on Debian). Lua suite alone: `bash tests/lua-check.sh`.

**Integration loop:** `mise run test-integration` (needs `Hyprland`, `hyprctl`, `quickshell`, `foot`, `jq`, a running Wayland session). It prints `SKIP:` when a binary is missing — a skip is **not** a pass; run it on the dev machine. Run it after Task 1 and Task 2 (both change what the compositor is asked to do).

**Live-test loop (QML tasks):**
```bash
LIVE="$HOME/.config/omarchy/plugins/se.mindfulstack.omascape"
cp logic.js WindowTile.qml Overview.qml "$LIVE"/ && omarchy restart shell
```
Then SUPER+P.

**Lua chunk rule:** every chunk sent through `Hyprland.dispatch` is a **single line** (Quickshell drops multi-line requests silently). Build readable with `\n`, then `.replace(/\n\s*/g, ' ')`. Hyprland evaluates the payload as `hl.dispatch(<payload>)` and accepts a function; an uncaught error inside the function is logged by the compositor as `error in keybind lambda: …` (verified in `src/config/lua/bindings/LuaBindingsRegistration.cpp` at `v0.56.2`) — but anything inside our own `pcall` is *not*, which is why Task 2 reports it.

**Hyprland Lua facts used below (all verified against the `v0.56.2` sources):**
- `print(...)` is rebound by Hyprland to its log at INFO level with a `[Lua]` prefix (`LuaBindingsRegistration.cpp`, `hlPrint`).
- `hl.notification.create({ text = "...", duration = <ms>, icon = "error" })` shows an on-screen notification; `icon` accepts `"error"`, `"warn"`, `"info"`, `"ok"`, `"none"` (`LuaBindingsNotification.cpp`).
- `hl.get_config("general.layout")` returns the config value (a string for that key); dotted and colon keys are both accepted; an unknown key returns `nil, "unknown config key …"` (`LuaBindingsConfigRules.cpp`, `hlGetConfig`).

**Commit style:** `fix(...)`, `feat(...)`, `test(...)`, `ci(...)`, `docs(...)`; body explains *why*.

**Progress ledger:** `.agent/sdd/progress.md` — append a `## Hardening (branch hardening)` section and keep it current per task (the controller resumes from it).

---

## File structure

| File | Responsibility after this plan |
|---|---|
| `logic.js` | Geometry + every Lua chunk. Gains `floatingMoveLua`, `reportLua` (shared error-report statements), a layout guard inside `tiledInsertLua`, and `indexOfWorkspace`. |
| `Overview.qml` | Snapshot, reconcile, dispatch, rendering. Loses `_movePosition` and the `positioning` phase; `scheduleRebuild` coalesces; `rebuild` preserves the selected workspace id. |
| `tests/tst_layout.qml` | Pure-logic tests (chunk shape + `indexOfWorkspace`). |
| `tests/ui/drag.qml` | Offscreen UI tests (atomic floating move, settle coalescing, selection identity). |
| `tests/ui/prepare.py` | Fixture builder; the mock compositor gains a refresh counter. |
| `tests/lua/mock_hl.lua` | **New. Shared test infrastructure:** in-memory `hl` table with window state that dispatches actually mutate, and an injectable failing dispatcher. |
| `tests/lua/tst_chunks.lua` | **New.** Behaviour tests that run the real generated chunks against the mock. |
| `tests/lua-check.sh` | Renders named chunks with the qml runtime, parses each with `load()`, then runs `tst_chunks.lua`. Fails (not skips) when `CI` is set. |
| `.github/workflows/ci.yml` | Installs `lua5.4` + `qml-qt6`, exports `CI=1`. |
| `README.md`, `ROADMAP.md`, `manifest.json` | Portability note (dwindle), roadmap tick, version 0.2.1. |

---

## Task 1: Atomic floating move (removes the overlay-lifetime dependency)

**Why:** A floating drop across workspaces dispatches a workspace transfer, then waits for the compositor to acknowledge it, then dispatches the x/y move from the reconcile timer (`Overview.qml` `reconcileMoves`, the `pending.positioning` branch). The Omarchy shell's plugin loader is active only while the plugin is keepLoaded or listed as open (`/usr/share/omarchy/shell/shell.qml`, `active: … keepLoaded || openPanelIds[id]`), and `hide()` drops it from the list — so SUPER+P after a quick drop destroys the component and the positioning never happens. Doing transfer + positioning in one Lua chunk (the pattern `tiledInsertLua` already uses) removes the second phase entirely.

**Files:**
- Modify: `logic.js` (add `floatingMoveLua` after `unfullscreenLua`, ~line 428)
- Modify: `Overview.qml:143-147` (`_movePosition`), `Overview.qml:223-247` (`submitDrop` tail), `Overview.qml:270-300` (`reconcileMoves`), `Overview.qml:451-455` (`close()` comment)
- Test: `tests/tst_layout.qml`, `tests/ui/drag.qml`

- [ ] **Step 1: Write the failing chunk-shape test** — append to `tests/tst_layout.qml` right after `test_unfullscreen_lua_is_guarded_single_line_and_addressed`:

```qml
    // A floating drop is ONE chunk: (workspace transfer, skipped when already there) then the
    // exact-position move, in that order, inside the compositor — so nothing depends on the
    // overlay staying loaded to finish the job. Focus/cursor restore as in every other chunk.
    function test_floating_move_lua_transfers_then_positions_in_one_chunk() {
        var lua = Logic.floatingMoveLua("0xabc", 3, { x: 200.4, y: 1600.6 })
        verify(lua.indexOf('\n') < 0, "single line")
        verify(lua.indexOf('function()') === 0)
        verify(lua.indexOf('hl.get_window("address:0xabc")') >= 0 || lua.indexOf('local sel = "address:0xabc"') >= 0)
        verify(lua.indexOf('if not w or not w.floating then return end') >= 0, "tiled windows are not moved by this chunk")
        var xfer = lua.indexOf('workspace = "3", follow = false'), pos = lua.indexOf('x = "200", y = "1601"')
        verify(xfer >= 0, "workspace transfer present"); verify(pos >= 0, "rounded exact position present")
        verify(xfer < pos, "transfer before positioning")
        verify(lua.indexOf('w.workspace.id == 3') >= 0, "transfer is skipped when already on the workspace")
        verify(lua.indexOf('pcall(function()') >= 0 && luaBalanced(lua), "guarded and balanced")
        verify(lua.lastIndexOf('hl.dsp.focus(') > pos && lua.lastIndexOf('cursor.move(') > lua.lastIndexOf('hl.dsp.focus('),
               "focus then cursor restored after the moves")
        verify(lua.indexOf('NaN') < 0 && lua.indexOf('undefined') < 0)
    }
```
This test distinguishes: a chunk that positions before transferring (order), one that also moves tiled windows (guard), and a missing function (ReferenceError).

- [ ] **Step 2: Run it to verify it fails**

Run: `/usr/lib/qt6/bin/qmltestrunner -input tests Layout::test_floating_move_lua_transfers_then_positions_in_one_chunk`
Expected: FAIL — `TypeError: Property 'floatingMoveLua' of object … is not a function`.

- [ ] **Step 3: Implement `floatingMoveLua`** in `logic.js`, directly after `unfullscreenLua`:

```js
// One atomic chunk that moves the floating window `addr` to workspace `targetWs` (skipped when
// it is already there) and then to the exact global position `pos` — in that order, because a
// workspace transfer relocates a floating window (especially across monitors), so positioning
// must come after it. Both happen inside the compositor before the next frame, so nothing in
// the overlay has to survive to finish the move: an unloaded overlay loses only its optimistic
// tile, never the operation. Tiled windows return early (they take the tiled-insert chunk).
// The position payload is the same string form `_movePosition` used (exact coordinates).
function floatingMoveLua(addr, targetWs, pos) {
    var ws = String(parseInt(targetWs, 10))
    var x = Math.round(pos.x), y = Math.round(pos.y)
    return (
        'function()\n' +
        '  local sel = "address:' + addr + '"\n' +
        '  local w = hl.get_window(sel)\n' +
        '  if not w or not w.floating then return end\n' +
        '  local prevW, cur = hl.get_active_window(), hl.get_cursor_pos()\n' +
        '  local same = w.workspace ~= nil and w.workspace.id == ' + ws + '\n' +
        '  local ok, err = pcall(function()\n' +
        '    if not same then hl.dispatch(hl.dsp.window.move({ workspace = "' + ws + '", follow = false, window = sel })) end\n' +
        '    hl.dispatch(hl.dsp.window.move({ x = "' + x + '", y = "' + y + '", window = sel }))\n' +
        '  end)\n' +
        '  ' + restoreFocusLua('prevW', 'cur') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}
```
Property this must hold: `x = "200", y = "1601"` for the inputs above (rounding, string form identical to the old `_movePosition` payload so the integration `assert_position` keeps matching). `ok, err` are unused until Task 2 adds the report; keep the names so Task 2 only inserts one line.

- [ ] **Step 4: Run the layout test to verify it passes**

Run: `/usr/lib/qt6/bin/qmltestrunner -input tests Layout::test_floating_move_lua_transfers_then_positions_in_one_chunk`
Expected: PASS.

- [ ] **Step 5: Replace the two-phase UI test with the atomic one** — in `tests/ui/drag.qml`, delete `test_cross_workspace_waits_before_positioning` (lines 94–112) and put this in its place:

```qml
    function test_cross_workspace_floating_move_is_one_dispatch() {
        client.floating = true; view.rebuild()
        dragBy(view.boxes[1].x-view.boxes[0].x,20)
        compare(view.compositor.commands.length,1,"transfer and positioning are one atomic chunk")
        var cmd=view.compositor.commands[0]
        verify(cmd.indexOf('workspace = "2"')>=0, "transfer to workspace 2")
        verify(cmd.indexOf('x = "')>=0, "position is in the same chunk")
        verify(cmd.indexOf('workspace = "2"') < cmd.indexOf('x = "'), "transfer before positioning")
        var dropped = tile().x
        view.rebuild(); compare(tile().x,dropped,"stale geometry must not undo the optimistic drop")
        var ws = view.compositor.workspaces.values
        ws[0].toplevels.values=[]
        ws[1].toplevels.values=[{lastIpcObject:client}]
        view.rebuild()
        compare(view.compositor.commands.length,1,"no second phase once the transfer lands")
        compare(tile().x,dropped)
        var p=view.pendingMoves[client.address].pos
        client.at=[p.x,p.y]; view.rebuild()
        verify(view.pendingMoves[client.address] === undefined, "acknowledged by geometry")
        compare(view.testModel.get(0).wsid,2)
    }
```
Distinguishes: the old two-dispatch behaviour (first `verify` on `x = "` fails because the transfer command has no position; later `compare(…,1)` fails because a second command appears).

- [ ] **Step 6: Run it to verify it fails**

Run: `bash tests/ui/run.sh Drag::test_cross_workspace_floating_move_is_one_dispatch`
Expected: FAIL at `position is in the same chunk`.

- [ ] **Step 7: Wire the chunk into `Overview.qml`**

(a) Delete `_movePosition` (lines 143–146).

(b) In `submitDrop`, replace from `var pending = { workspaceId: targetWs, pos: pos,` to the end of the function with:

```qml
        var pending = { workspaceId: targetWs, pos: pos, deadline: Date.now() + 1800 }
        pendingMoves[addr] = pending
        // Publish the destination before restoring x/y bindings. Keep it until the
        // compositor acknowledges this move; refreshToplevels is asynchronous.
        for (var i = 0; i < tilesModel.count; i++) {
            if (tilesModel.get(i).address !== addr) continue
            // A floating fullscreen window has no slot: Logic._tileRect would span the whole
            // output and fill the cell until the next rebuild, so keep the tile's current size
            // and only move it to the drop point.
            var rect = (pos && !win.fullscreen) ? Logic._tileRect({ax:pos.x, ay:pos.y, sw:win.sw, sh:win.sh},
                                            mon, box, params) : null
            tilesModel.set(i, { wx: rect ? rect.x : dropX, wy: rect ? rect.y : dropY,
                                ww: rect ? rect.w : tilesModel.get(i).ww,
                                wh: rect ? rect.h : tilesModel.get(i).wh, wsid: targetWs })
            break
        }
        // Floating: transfer + exact position in one compositor-side chunk (nothing here has to
        // outlive the overlay to finish it). Grouped tiled windows only change workspace.
        if (pos) Hyprland.dispatch(Logic.floatingMoveLua(addr, targetWs, pos))
        else Hyprland.dispatch('hl.dsp.window.move({ workspace = ' + targetWs +
                               ', follow = false, window = "address:' + addr + '" })')
        scheduleRebuild()
        reconcileTimer.restart()
    }
```

(c) In `reconcileMoves`, delete the block:
```qml
            if (pending.pos && !pending.positioning) {
                // Wait for workspace transfer before positioning: transfer itself can
                // relocate a floating window, especially across different monitors.
                pending.positioning = true
                _movePosition(addr, pending.pos)
                continue
            }
```
The remaining acknowledgement (`!pending.pos || within 1px of pos and size`) is unchanged.

(d) In `close()`, replace the comment `// A dispatched workspace move still needs its positioning/ack phase when closed.` with `// Every dispatched operation is atomic in the compositor; the reconcile timer only clears optimistic state.`

- [ ] **Step 8: Run the whole unit suite**

Run: `mise run test`
Expected: all Layout, Drag tests pass; the Lua check prints `PASS: 3 generated Lua chunks parse` (still 3 until Task 5). If `test_float_toggle_updates_existing_tile` or `test_acknowledgement_releases_pending_geometry` fail, the `pos` field or the `x = "` payload form was changed — restore them.

- [ ] **Step 9: Integration** — `mise run test-integration`. Expected lines include `PASS: real typed cross-workspace floating move, silent and acknowledged` (this asserts the window lands at `[200,1600]` on workspace 3, which now proves the single chunk positions correctly after the transfer). If the position is off, the compositor relocated the window *after* our x/y move; then reorder is not the fix — check `hypr.log` for a Lua error from the chunk.

- [ ] **Step 10: Commit**

```bash
git add logic.js Overview.qml tests/tst_layout.qml tests/ui/drag.qml
git commit -m "fix(overview): floating move is one atomic Lua chunk; no positioning phase after unload

The shell unloads a non-keepLoaded overlay on toggle-close, which destroyed the
pending positioning dispatch of a cross-workspace floating drop. Transfer and
exact position now run in one compositor-side chunk, so no operation depends on
the overlay staying loaded."
```

---

## Task 2: Guarded Lua cleanup, error reporting, dwindle guard

**Why:** In `tiledInsertLua` the un-float, fullscreen re-apply and the re-tile all sit inside the same `pcall` as the risky steps; a throw skips them and is swallowed, leaving the window floating and un-fullscreened while the overlay's deadline reconcile reads the changed geometry as success. The chunk also assumes dwindle (`smart_split`, cursor-based insert) with no check.

**Files:**
- Modify: `logic.js:316-370` (`tiledInsertLua`), `logic.js` (`unfullscreenLua`, `floatingMoveLua`), add `reportLua`
- Test: `tests/tst_layout.qml`

- [ ] **Step 1: Write the failing shape tests** — append after the Task 1 test in `tests/tst_layout.qml`:

```qml
    // Cleanup must not be skippable: the un-float, both fullscreen re-applies and the config
    // restore each run OUTSIDE the risky pcall and re-read state so they only undo what the
    // chunk did. A swallowed error is reported (compositor log + on-screen notification).
    function test_tiled_insert_lua_cleanup_is_outside_the_risky_pcall_and_reports() {
        var lua = Logic.tiledInsertLua("0xabc", 3, { anchor: "0xdef", side: "left", x: 1, y: 2 })
        var risky = lua.indexOf('local ok, err = pcall(function()')
        verify(risky >= 0, "risky steps capture ok/err")
        var riskyEnd = lua.indexOf('end)', lua.indexOf('cursor.move(', risky))
        verify(riskyEnd > risky, "the cursor move is the last risky step")
        var unfloat = lua.indexOf('if fw and fw.floating then hl.dispatch(hl.dsp.window.float(')
        verify(unfloat > riskyEnd, "un-float re-reads floating state and runs after the pcall")
        verify(lua.indexOf('pcall(function() if fsSel and fsSel ~= sel then') > riskyEnd, "workspace fullscreen re-apply is its own guarded step")
        verify(lua.indexOf('pcall(function() if ownMode ~= 0 then') > riskyEnd, "own fullscreen re-apply is its own guarded step")
        verify(lua.lastIndexOf('smart_split = smart') > lua.lastIndexOf('pcall(function()'), "config restored after every guarded step")
        verify(lua.indexOf('if not ok then') > lua.lastIndexOf('smart_split = smart'), "report after the config restore")
        verify(lua.indexOf('print(msg)') >= 0 && lua.indexOf('hl.notification.create({ text = msg') >= 0, "reported to log and screen")
        verify(lua.indexOf('tiled insert failed') >= 0)
        verify(luaBalanced(lua))
    }
    // Non-dwindle layouts get a plain silent workspace move (or nothing, same workspace) —
    // the cursor-based insert is a dwindle behaviour.
    function test_tiled_insert_lua_falls_back_to_plain_move_off_dwindle() {
        var lua = Logic.tiledInsertLua("0xabc", 3, { anchor: "0xdef", side: "left", x: 1, y: 2 })
        var guard = lua.indexOf('local layout = hl.get_config("general.layout")')
        verify(guard >= 0 && guard < lua.indexOf('smart_split = true'), "layout read before any dwindle config change")
        verify(lua.indexOf('if layout ~= nil and layout ~= "dwindle" then') >= 0, "unknown key (nil) keeps the dwindle path")
        var fb = lua.indexOf('if not same then hl.dispatch(hl.dsp.window.move({ workspace = "3", follow = false, window = sel })) end', guard)
        verify(fb > guard && fb < lua.indexOf('smart_split = true'), "fallback is a plain silent move, before the dwindle path")
        verify(lua.indexOf('return', fb) > fb && lua.indexOf('return', fb) < lua.indexOf('smart_split = true'), "fallback returns before the dwindle path")
    }
    function test_every_chunk_reports_swallowed_errors() {
        verify(Logic.unfullscreenLua("0xabc").indexOf('un-fullscreen failed') >= 0)
        verify(Logic.floatingMoveLua("0xabc", 2, { x: 1, y: 2 }).indexOf('floating move failed') >= 0)
        var r = Logic.reportLua('thing')
        verify(r.indexOf('if not ok then') === 0 && r.indexOf('tostring(err)') >= 0)
        verify(r.indexOf('pcall(function() hl.notification.create(') >= 0, "notification API itself guarded (older Hyprland)")
    }
```
Distinguishes: cleanup still inside the pcall (the `> riskyEnd` checks), config restore before a cleanup step, no guard, no report.

- [ ] **Step 2: Run them to verify they fail**

Run: `/usr/lib/qt6/bin/qmltestrunner -input tests Layout::test_tiled_insert_lua_cleanup_is_outside_the_risky_pcall_and_reports Layout::test_tiled_insert_lua_falls_back_to_plain_move_off_dwindle Layout::test_every_chunk_reports_swallowed_errors`
Expected: three FAILs (`risky steps capture ok/err`; `layout read before…`; `reportLua is not a function`).

- [ ] **Step 3: Add `reportLua` and restructure the chunks** in `logic.js`.

Add before `tiledInsertLua`:
```js
// Lua statements that report a failure captured as `ok, err` (from pcall) for the operation
// `what`: to the compositor log (Hyprland rebinds `print` to its log with a [Lua] prefix) and
// as an on-screen notification (guarded: hl.notification is missing on older Hyprland). Errors
// inside our own pcall are otherwise invisible — the compositor only logs uncaught ones.
// Returns newline-separated statements; the outermost chunk builder must flatten to one line.
function reportLua(what) {
    return (
        'if not ok then\n' +
        '  local msg = "omascape: ' + what + ' failed: " .. tostring(err)\n' +
        '  print(msg)\n' +
        '  pcall(function() hl.notification.create({ text = msg, duration = 4000, icon = "error" }) end)\n' +
        'end'
    )
}
```

Replace the body of `tiledInsertLua` (keep the signature and the `ws`/`gx`/`gy`/`side`/`anchorSel` locals) with:
```js
    return (
        'function()\n' +
        '  local sel = "address:' + addr + '"\n' +
        '  local w = hl.get_window(sel)\n' +
        '  if not w or w.floating then return end\n' +
        '  local prevW = hl.get_active_window()\n' +
        '  local cur = hl.get_cursor_pos()\n' +
        '  local same = w.workspace ~= nil and w.workspace.id == ' + ws + '\n' +
        // The cursor-based insert is dwindle behaviour (smart_split, hit test at the cursor).
        // Any other layout gets the plain silent move; nil (unknown key) keeps the dwindle path.
        '  local layout = hl.get_config("general.layout")\n' +
        '  if layout ~= nil and layout ~= "dwindle" then\n' +
        '    if not same then hl.dispatch(hl.dsp.window.move({ workspace = "' + ws + '", follow = false, window = sel })) end\n' +
        '    ' + restoreFocusLua('prevW', 'cur') + '\n' +
        '    return\n' +
        '  end\n' +
        '  local anchorSel = ' + anchorSel + '\n' +
        '  local smart = hl.get_config("dwindle.smart_split")\n' +
        '  local useActive = hl.get_config("dwindle.use_active_for_splits")\n' +
        '  local aws = hl.get_active_workspace()\n' +
        '  local onActive = aws ~= nil and aws.id == ' + ws + '\n' +
        '  local tws = hl.get_workspace("' + ws + '")\n' +
        '  local fsWin = tws and tws.fullscreen_window or nil\n' +
        '  local fa = fsWin and tostring(fsWin.address or "") or ""\n' +
        '  if fa ~= "" and fa:sub(1, 2) ~= "0x" then fa = "0x" .. fa end\n' +
        '  local fsSel = fa ~= "" and ("address:" .. fa) or nil\n' +
        '  local fsMode = fsWin and tws.fullscreen_mode or 0\n' +
        '  local ownMode = same and w.fullscreen or 0\n' +
        '  hl.config({ dwindle = { smart_split = true, use_active_for_splits = not onActive } })\n' +
        '  local ok, err = pcall(function()\n' +
        '    if fsSel then ' + fullscreenBodyLua('fsSel', '0') + ' end\n' +
        '    ' + fullscreenBodyLua('sel', '0') + '\n' +
        '    hl.dispatch(hl.dsp.window.float({ window = sel, action = "toggle" }))\n' +
        '    if not same then\n' +
        '      hl.dispatch(hl.dsp.window.move({ workspace = "' + ws + '", follow = false, window = sel }))\n' +
        '    end\n' +
        '    local x, y = ' + gx + ', ' + gy + '\n' +
        '    local a = anchorSel and hl.get_window(anchorSel) or nil\n' +
        '    if a and a.at and a.size then\n' +
        '      local inset = 2\n' +
        '      x, y = a.at.x + a.size.x / 2, a.at.y + a.size.y / 2\n' +
        '      if "' + side + '" == "left" then x = a.at.x + inset\n' +
        '      elseif "' + side + '" == "right" then x = a.at.x + a.size.x - 1 - inset\n' +
        '      elseif "' + side + '" == "top" then y = a.at.y + inset\n' +
        '      elseif "' + side + '" == "bottom" then y = a.at.y + a.size.y - 1 - inset end\n' +
        '    end\n' +
        '    hl.dispatch(hl.dsp.cursor.move({ x = math.floor(x + 0.5), y = math.floor(y + 0.5) }))\n' +
        '  end)\n' +
        // Cleanup. On success the un-float IS the re-tile (at the cursor). Each step re-reads
        // state and is guarded on its own, so a failure above — or in an earlier cleanup step —
        // never leaves the window floating, the workspace un-fullscreened, or the config changed.
        // The window was tiled on entry, so any floating state here is ours to undo.
        '  pcall(function() local fw = hl.get_window(sel); if fw and fw.floating then hl.dispatch(hl.dsp.window.float({ window = sel, action = "toggle" })) end end)\n' +
        '  pcall(function() if fsSel and fsSel ~= sel then ' + fullscreenBodyLua('fsSel', 'fsMode') + ' end end)\n' +
        '  pcall(function() if ownMode ~= 0 then ' + fullscreenBodyLua('sel', 'ownMode') + ' end end)\n' +
        '  hl.config({ dwindle = { smart_split = smart, use_active_for_splits = useActive } })\n' +
        '  ' + reportLua('tiled insert') + '\n' +
        '  ' + restoreFocusLua('prevW', 'cur') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
```
Property: on the success path the dispatch order is unchanged from before (fullscreen strip → float → move → cursor → un-float → fullscreen re-apply → config → focus → cursor), which Task 5's mock verifies by replaying it.

In `unfullscreenLua`, change `pcall(function()` to `local ok, err = pcall(function()` and insert `reportLua('un-fullscreen') + '\n' +` between the `end)` line and `restoreFocusLua`. In `floatingMoveLua` (Task 1) insert `'  ' + reportLua('floating move') + '\n' +` between its `end)` line and `restoreFocusLua`.

- [ ] **Step 4: Update the two pre-existing shape tests that the guard's early `window.move(` shifts.**

In `test_tiled_insert_lua_replays_native_drop` replace the `order` array with:
```qml
        var firstFloat = lua.indexOf('window.float(')
        var order = [firstFloat, lua.indexOf('window.move(', firstFloat),
                     lua.indexOf('hl.get_window(anchorSel)'), lua.indexOf('cursor.move('),
                     lua.lastIndexOf('window.float(')]
```
(the fallback move precedes the float by design; the replay order is measured from the float). In `test_tiled_insert_lua_strips_fullscreen_first_and_reapplies_last` no change is needed — verify it still passes (the last `hl.dsp.window.fullscreen(` is now in a cleanup pcall after the last `window.float(`, and `smart_split = smart` still follows it).

- [ ] **Step 5: Run the layout suite**

Run: `/usr/lib/qt6/bin/qmltestrunner -input tests`
Expected: all pass (51 with the four new tests).

- [ ] **Step 6: Run everything** — `mise run test` (the UI tiled-drop tests assert substrings that are still present) and `mise run test-integration`. Expected integration lines: every `PASS:` from `drag.sh` and `fullscreen.sh`, in particular `PASS: production tiled drop inserts at the drop point on a hidden workspace; state restored` (it asserts `smart_split`/`use_active_for_splits` restored — now after guarded cleanup). The nested compositor runs dwindle, so the fallback branch is not exercised here; Task 5's mock covers it.

- [ ] **Step 7: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "fix(logic): tiled-insert cleanup cannot be skipped; report swallowed errors; dwindle guard

Un-float, fullscreen re-apply and config restore each run in their own guarded
step after the risky pcall and re-read state, so a thrown dispatcher never leaves
a window floating. Failures are printed to the compositor log and shown as a
notification instead of vanishing inside pcall. Non-dwindle layouts get a plain
silent move: the cursor-based insert is dwindle behaviour."
```

---

## Task 3: Settle timer coalescing

**Why:** `scheduleRebuild()` calls `settleTimer.restart()` on every raw Hyprland event, and `Timer.restart()` resets the interval — events arriving faster than 60 ms (a terminal title spinner, browser tab progress) starve the rebuild for the whole stream while `refreshToplevels()` is issued per event.

**Files:**
- Modify: `Overview.qml:458-475` (`scheduleRebuild`, `settleTimer`)
- Modify: `tests/ui/prepare.py` (mock compositor counts refreshes)
- Test: `tests/ui/drag.qml`

- [ ] **Step 1: Give the mock compositor a refresh counter** — in `tests/ui/prepare.py`, change the injected QtObject's two lines
```
        function refreshToplevels() {}
        function refreshWorkspaces() {}
```
to
```
        property int refreshes: 0
        function refreshToplevels() { refreshes++ }
        function refreshWorkspaces() {}
```

- [ ] **Step 2: Write the failing UI test** — append to `tests/ui/drag.qml` before the final `}`:

```qml
    // Raw compositor events faster than the settle interval must not starve the rebuild, and
    // must not fan out into one refresh request per event.
    function test_event_flood_still_rebuilds_and_throttles_refresh() {
        var spy = createTemporaryObject(Qt.createQmlObject(
            'import QtTest; SignalSpy { signalName: "boxesChanged" }', tc), tc)
        spy.target = view
        view.compositor.refreshes = 0
        for (var i = 0; i < 20; i++) { view.compositor.rawEvent(); wait(25) }   // 500 ms stream
        verify(spy.count >= 5, "rebuilt during the flood (got " + spy.count + ")")
        verify(view.compositor.refreshes <= 10, "at most one refresh per settle tick (got " + view.compositor.refreshes + ")")
        var after = spy.count
        wait(400)
        verify(spy.count > after, "settles after the stream ends")
        var settled = spy.count
        wait(400)
        compare(spy.count, settled, "timer stops after five quiet ticks")
    }
```
Distinguishes: the restart-per-event behaviour (spy.count stays 0 during the stream — `rebuild()` assigns `root.boxes` a fresh array every call, so `boxesChanged` counts rebuilds) and per-event refresh (20 refreshes vs ≤ 10). If `Qt.createQmlObject` of a `SignalSpy` proves awkward, declare `SignalSpy { id: boxesSpy; target: view; signalName: "boxesChanged" }` as a child of the TestCase and `boxesSpy.clear()` in the test — same property.

- [ ] **Step 3: Run it to verify it fails**

Run: `bash tests/ui/run.sh Drag::test_event_flood_still_rebuilds_and_throttles_refresh`
Expected: FAIL at `rebuilt during the flood (got 0)`.

- [ ] **Step 4: Coalesce** — replace `scheduleRebuild` and `settleTimer` in `Overview.qml` with:

```qml
    // Ask Hyprland for fresh client data, then rebuild every 60ms until five quiet ticks have
    // passed, so a window opened while the overview is visible appears once its async geometry
    // arrives. A burst of events extends the settle window (the tick counter resets) but never
    // restarts the running timer, so a stream of events faster than the interval still
    // rebuilds every tick; the refresh request is issued at most once per tick.
    function scheduleRebuild() {
        if (!settleTimer.refreshed) {
            settleTimer.refreshed = true
            if (typeof Hyprland.refreshToplevels === "function") Hyprland.refreshToplevels()
            if (typeof Hyprland.refreshWorkspaces === "function") Hyprland.refreshWorkspaces()
        }
        settleTimer.ticks = 0
        if (!settleTimer.running) settleTimer.start()
    }
    Timer {
        id: settleTimer
        interval: 60; repeat: true
        property int ticks: 0
        property bool refreshed: false   // a refresh was requested since the last tick
        onTriggered: {
            refreshed = false
            if (root.opened) root.rebuild()
            if (++ticks >= 5) stop()
        }
        onRunningChanged: if (!running) refreshed = false
    }
```
Property: the first rebuild after the first event still comes 60 ms after the refresh request (data has a tick to land), and the timer stops 300 ms after the last event as before.

- [ ] **Step 5: Run the UI suite** — `bash tests/ui/run.sh`. Expected: all pass, including the new test.

- [ ] **Step 6: Commit**

```bash
git add Overview.qml tests/ui/prepare.py tests/ui/drag.qml
git commit -m "fix(overview): coalesce raw events; a flood no longer starves the rebuild or fans out refreshes"
```

---

## Task 4: Keyboard selection follows the workspace id

**Why:** `rebuild()` keeps `selectedIndex` positional; Hyprland destroys a non-persistent workspace when its last window leaves it, so a drag out of a workspace shifts the boxes and Enter activates the wrong workspace.

**Files:**
- Modify: `logic.js` (add `indexOfWorkspace` next to `hitWorkspace`), `Overview.qml:413-420` (`rebuild` selection block)
- Test: `tests/tst_layout.qml`, `tests/ui/drag.qml`

- [ ] **Step 1: Failing logic test** — append to `tests/tst_layout.qml`:

```qml
    function test_index_of_workspace() {
        var boxes = [{ workspaceId: 2 }, { workspaceId: 5 }, { workspaceId: 7 }]
        compare(Logic.indexOfWorkspace(boxes, 5), 1)
        compare(Logic.indexOfWorkspace(boxes, 2), 0)
        compare(Logic.indexOfWorkspace(boxes, 9), -1)
        compare(Logic.indexOfWorkspace([], 2), -1)
    }
```
Run: `/usr/lib/qt6/bin/qmltestrunner -input tests Layout::test_index_of_workspace` → FAIL (`indexOfWorkspace is not a function`).

- [ ] **Step 2: Implement** in `logic.js` after `hitWorkspace`:

```js
// Index of the box showing workspace `id`, or -1.
function indexOfWorkspace(boxes, id) {
    for (var i = 0; i < boxes.length; i++) if (boxes[i].workspaceId === id) return i
    return -1
}
```
Run the test → PASS.

- [ ] **Step 3: Failing UI tests** — append to `tests/ui/drag.qml`:

```qml
    function threeWorkspaces() {
        var mon = view.compositor.monitors.values[0]
        view.compositor.workspaces = {values:[
            {id:1,monitor:mon,toplevels:{values:[{lastIpcObject:client}]}},
            {id:2,monitor:mon,toplevels:{values:[]}},
            {id:3,monitor:mon,toplevels:{values:[]}}
        ]}
        view.rebuild()
    }
    // Selection is a workspace, not a position: when a preceding workspace disappears the
    // selected id must survive the rebuild.
    function test_selection_keeps_workspace_when_earlier_one_vanishes() {
        threeWorkspaces()
        view.selectByNav("right")
        compare(view.selectedId, 2)
        view.compositor.workspaces.values.splice(0, 1)   // workspace 1 destroyed
        view.rebuild()
        compare(view.selectedId, 2, "still workspace 2, not whatever now sits at index 1")
    }
    // When the selected workspace itself disappears, fall back to the nearest position.
    function test_selection_falls_back_when_selected_workspace_vanishes() {
        threeWorkspaces()
        view.selectByNav("right"); view.selectByNav("right")
        compare(view.selectedId, 3)
        view.compositor.workspaces.values.splice(2, 1)   // workspace 3 destroyed
        view.rebuild()
        compare(view.selectedId, 2, "clamped to the last box")
    }
```
Distinguishes: the positional clamp (first test would yield 3). The second test passes on old and new code alike; it pins the fallback so it is not lost.

Run: `bash tests/ui/run.sh Drag::test_selection_keeps_workspace_when_earlier_one_vanishes` → FAIL (`Actual 3, Expected 2`).

- [ ] **Step 4: Preserve the id in `rebuild()`** — in `Overview.qml` add, as the first line of `rebuild()` (before `buildHandles()`):

```qml
        var keepId = root.selectedId   // the workspace the user has selected, before layout
```
and replace the trailing selection block (`if (root.selectedIndex < 0) { … } else { … }`) with:

```qml
        var idx = keepId >= 0 ? Logic.indexOfWorkspace(res.boxes, keepId) : -1
        if (idx < 0 && root.selectedIndex >= 0)   // selected workspace vanished: nearest position
            idx = res.boxes.length ? Math.min(root.selectedIndex, res.boxes.length - 1) : -1
        if (idx < 0 && res.boxes.length) {        // nothing selected yet: the focused workspace
            for (var b = 0; b < res.boxes.length; b++) if (res.boxes[b].focused) { idx = b; break }
            if (idx < 0) idx = 0
        }
        root.selectedIndex = idx
```
Property: `open()` sets `selectedIndex = -1` before calling `rebuild()`, so the focused-workspace default still applies on open; `selectedId` is read *before* `root.boxes = res.boxes` (it is a binding on `boxes`).

- [ ] **Step 5: Run the full unit suite** — `mise run test`. Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add logic.js Overview.qml tests/tst_layout.qml tests/ui/drag.qml
git commit -m "fix(overview): keyboard selection follows the workspace id across rebuilds"
```

---

## Task 5: Lua behaviour suite with a mock `hl`, mandatory in CI

**Why:** CI's last run on main printed `SKIP: lua-check needs a Qt6 qml runtime … and a Lua interpreter` and passed: no generated chunk has ever been parsed in CI, and nothing executes them. This task is **shared test infrastructure**: Tasks 1–2's guarantees ("window ends tiled even if a step throws", "fallback off dwindle") are only demonstrated here.

**What the mock must genuinely reproduce:** (1) window state that dispatches mutate — `float toggle` flips `floating`, `window.move` with `workspace` sets the workspace, with `x/y` sets `at`, `fullscreen toggle` sets `fullscreen` per Hyprland's toggle rule (same mode → 0, otherwise → requested mode); (2) errors that really propagate — a dispatcher named in `hl.__fail_on` raises a Lua error with `error()`, not a return code; (3) `hl.get_config` / `hl.config` backed by one table so restore can be asserted; (4) every dispatch appended to `hl.__log` as `{ name, args }` so order is observable. **What it cannot supply:** real dwindle re-layout (the anchor's geometry never changes) and real focus semantics (`get_active_window` is a constant); tests therefore assert dispatch order and end state, never geometry. **What must not collapse:** `w.floating` must be a real toggled field (a constant `false` would make "ends tiled" vacuous) and `__fail_on` must default to `nil` so the happy path proves the order without injection.

**Files:**
- Create: `tests/lua/mock_hl.lua`, `tests/lua/tst_chunks.lua`
- Modify: `tests/lua-check.sh`, `.github/workflows/ci.yml`

- [ ] **Step 1: Write the mock** — `tests/lua/mock_hl.lua`:

```lua
-- In-memory stand-in for Hyprland's `hl` table, just enough for the chunks logic.js builds.
-- Dispatches mutate window state and are logged; `hl.__fail_on = "window.float"` makes that
-- dispatcher raise. Geometry never re-lays out (no dwindle here): assert order and end state.
local M = {}

function M.new(opts)
  opts = opts or {}
  local hl = { __log = {}, __notifications = {}, __fail_on = nil, __config = {
    ["general.layout"] = opts.layout or "dwindle",
    ["dwindle.smart_split"] = false, ["dwindle.use_active_for_splits"] = true } }
  hl.__windows = opts.windows or {}
  hl.__active_workspace = opts.active_workspace or { id = 1 }
  hl.__workspaces = opts.workspaces or {}
  hl.__active_window = opts.active_window or nil
  hl.__cursor = { x = 5, y = 6 }

  local function byAddress(sel)
    local a = sel:match("^address:(.+)$")
    return a and hl.__windows[a] or nil
  end
  function hl.get_window(sel) return byAddress(sel) end
  function hl.get_active_window() return hl.__active_window end
  function hl.get_cursor_pos() return { x = hl.__cursor.x, y = hl.__cursor.y } end
  function hl.get_active_workspace() return hl.__active_workspace end
  function hl.get_workspace(id) return hl.__workspaces[tostring(id)] or { fullscreen_window = nil, fullscreen_mode = 0 } end
  function hl.get_config(k)
    local v = hl.__config[k]
    if v == nil then return nil, "unknown config key '" .. k .. "'" end
    return v
  end
  function hl.config(t)
    for group, kv in pairs(t) do for k, v in pairs(kv) do hl.__config[group .. "." .. k] = v end end
  end
  hl.notification = { create = function(t) hl.__notifications[#hl.__notifications + 1] = t end }

  -- Typed dispatcher table: each entry returns a descriptor; hl.dispatch applies it.
  local function d(name) return function(args) return { name = name, args = args } end end
  hl.dsp = {
    focus = d("focus"),
    cursor = { move = d("cursor.move") },
    window = { float = d("window.float"), move = d("window.move"), fullscreen = d("window.fullscreen") },
  }
  function hl.dispatch(desc)
    hl.__log[#hl.__log + 1] = desc
    if hl.__fail_on == desc.name then error("injected failure in " .. desc.name) end
    local a = desc.args or {}
    local w = a.window and byAddress(a.window) or nil
    if desc.name == "window.float" and w then w.floating = not w.floating
    elseif desc.name == "window.move" and w then
      if a.workspace then w.workspace = { id = tonumber(a.workspace) } end
      if a.x and a.y then w.at = { x = tonumber(a.x), y = tonumber(a.y) } end
    elseif desc.name == "window.fullscreen" and w then
      local want = (a.mode == "maximized") and 1 or 2
      w.fullscreen = (w.fullscreen == want) and 0 or want
    elseif desc.name == "cursor.move" then hl.__cursor = { x = a.x, y = a.y }
    end
  end
  return hl
end

-- Names of dispatches in order, e.g. { "window.float", "window.move", ... }.
function M.names(hl)
  local out = {}
  for i, e in ipairs(hl.__log) do out[i] = e.name end
  return out
end

return M
```

- [ ] **Step 2: Write the tests** — `tests/lua/tst_chunks.lua` (takes the chunk file path; each line is `NAME <one-line chunk>`):

```lua
-- Behaviour tests for the generated chunks, run by lua-check.sh after the parse check.
package.path = arg[0]:gsub("[^/]*$", "") .. "?.lua;" .. package.path
local Mock = require("mock_hl")

local chunks = {}
for line in io.lines(arg[1]) do
  local name, body = line:match("^(%S+) (.+)$")
  if name then chunks[name] = body end
end
local function run(name, hl)
  local body = assert(chunks[name], "no chunk named " .. name)
  local f = assert(load("return " .. body, name, "t", setmetatable({ hl = hl, print = function(...)
    hl.__printed = hl.__printed or {}; hl.__printed[#hl.__printed + 1] = table.concat({ ... }, "\t") end },
    { __index = _G })))
  local fn = f()                      -- the chunk evaluates to a function, as hl.dispatch does
  assert(type(fn) == "function", name .. " must evaluate to a function")
  fn()
end
local failures = 0
local function case(label, f)
  local ok, err = pcall(f)
  if ok then print("ok   " .. label) else failures = failures + 1; print("FAIL " .. label .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
  if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function seq(hl, expected)
  local got = table.concat(Mock.names(hl), ",")
  eq(got, table.concat(expected, ","), "dispatch order")
end
local function tiledWindows()
  return { ["0xabc"] = { address = "0xabc", floating = false, fullscreen = 0, workspace = { id = 1 },
                         at = { x = 0, y = 0 }, size = { x = 100, y = 100 } },
           ["0xdef"] = { address = "0xdef", floating = false, fullscreen = 0, workspace = { id = 3 },
                         at = { x = 500, y = 500 }, size = { x = 200, y = 100 } } }
end

-- TILED_INSERT: addr 0xabc → workspace 3, anchor 0xdef, side left (rendered by lua-check.sh)
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
  hl.__fail_on = "cursor.move"
  run("TILED_INSERT", hl)
  eq(hl.__windows["0xabc"].floating, false, "cleanup un-floated it")
  eq(hl.__config["dwindle.smart_split"], false, "smart_split restored")
  eq(#hl.__notifications, 1, "one notification")
  assert(hl.__notifications[1].text:find("tiled insert failed"), "notification names the operation")
  assert(hl.__printed and hl.__printed[1]:find("injected failure in cursor.move"), "logged the Lua error")
end)
case("tiled insert: the float itself throws → cleanup must not float the still-tiled window", function()
  local hl = Mock.new({ windows = tiledWindows() })
  hl.__fail_on = "window.float"
  run("TILED_INSERT", hl)
  eq(hl.__windows["0xabc"].floating, false, "still tiled")
  local n = 0; for _, e in ipairs(hl.__log) do if e.name == "window.float" then n = n + 1 end end
  eq(n, 1, "exactly one float attempt (the failed one); cleanup re-read state and skipped")
end)
case("tiled insert on a non-dwindle layout → plain silent move only", function()
  local hl = Mock.new({ windows = tiledWindows(), layout = "master" })
  run("TILED_INSERT", hl)
  seq(hl, { "window.move", "cursor.move" })
  eq(hl.__log[1].args.workspace, "3"); eq(hl.__log[1].args.follow, false)
  eq(hl.__config["dwindle.smart_split"], false, "dwindle config never touched")
end)
case("tiled insert: unknown layout key (nil) keeps the dwindle path", function()
  local hl = Mock.new({ windows = tiledWindows() }); hl.__config["general.layout"] = nil
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
-- FLOATING_MOVE: addr 0xabc (floating, ws 1) → workspace 3 at (200,1600)
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
case("floating move: transfer throws → reported, focus/cursor still restored", function()
  local w = tiledWindows(); w["0xabc"].floating = true
  local hl = Mock.new({ windows = w }); hl.__fail_on = "window.move"
  run("FLOATING_MOVE", hl)
  eq(#hl.__notifications, 1); assert(hl.__notifications[1].text:find("floating move failed"))
  eq(Mock.names(hl)[#hl.__log], "cursor.move", "cursor restore is the last dispatch")
end)
-- UNFULLSCREEN: addr 0xabc
case("un-fullscreen toggles only when the window is fullscreen", function()
  local w = tiledWindows(); w["0xabc"].fullscreen = 2
  local hl = Mock.new({ windows = w })
  run("UNFULLSCREEN", hl)
  seq(hl, { "window.fullscreen", "cursor.move" }); eq(hl.__windows["0xabc"].fullscreen, 0)
  local hl2 = Mock.new({ windows = tiledWindows() })
  run("UNFULLSCREEN", hl2)
  seq(hl2, { "cursor.move" })
end)

if failures > 0 then io.stderr:write(failures .. " Lua chunk test(s) failed\n"); os.exit(1) end
print("PASS: Lua chunk behaviour suite")
```
Would-it-fail check: the second and third cases go red on the pre-Task-2 chunk (window left floating; `float` count would be 2 because the old cleanup blindly toggled), the fourth on a chunk without the guard, and `floating move transfers then positions` on a `FLOATING_MOVE` chunk that emitted only one move.

- [ ] **Step 3: Rewrite `tests/lua-check.sh`** so it renders *named* chunks, parses each, then runs the suite, and fails instead of skipping under CI:

```bash
#!/usr/bin/env bash
# Real-Lua check of the atomic chunks logic.js builds: render them through a throwaway QML
# script (importing logic.js the way the plugin does), parse each with a real interpreter's
# `load()` — an unparseable chunk is dropped silently by the compositor — then run the
# behaviour suite (tests/lua/tst_chunks.lua) against a mock `hl` table.
set -euo pipefail
src=$(cd "$(dirname "$0")/.." && pwd)

QML_BIN=""
for c in qml6 qml /usr/lib/qt6/bin/qml; do
  if command -v "$c" >/dev/null 2>&1; then QML_BIN="$c"; break; fi
done
LUA_BIN=""
for c in lua5.4 lua luajit; do
  if command -v "$c" >/dev/null 2>&1; then LUA_BIN="$c"; break; fi
done

if [ -z "$QML_BIN" ] || [ -z "$LUA_BIN" ]; then
  msg="lua-check needs a Qt6 qml runtime (qml6, qml, /usr/lib/qt6/bin/qml) and a Lua interpreter (lua5.4/lua/luajit) -- missing one of them"
  if [ -n "${CI:-}" ]; then echo "FAIL: $msg (CI must install them)" >&2; exit 1; fi
  echo "SKIP: $msg"; exit 0
fi

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cat > "$fixture/dump.qml" <<EOF
import QtQuick
import "$src/logic.js" as Logic
QtObject { Component.onCompleted: {
    console.log("CHUNK UNFULLSCREEN " + Logic.unfullscreenLua("0xabc"))
    console.log("CHUNK TILED_INSERT " + Logic.tiledInsertLua("0xabc", 3, { anchor: "0xdef", side: "left", x: 1, y: 2 }))
    console.log("CHUNK TILED_INSERT_NO_ANCHOR " + Logic.tiledInsertLua("0xabc", 2, { anchor: "", side: "", x: 10, y: 20 }))
    console.log("CHUNK FLOATING_MOVE " + Logic.floatingMoveLua("0xabc", 3, { x: 200, y: 1600 }))
    Qt.quit()
} }
EOF

# console.log routes through qDebug, which on a systemd session defaults to the journal rather
# than this process's stderr -- QT_FORCE_STDERR_LOGGING pins it back to stderr. Only what
# follows "CHUNK " is kept (qml's own "qml: " prefix and other noise are dropped).
QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 "$QML_BIN" "$fixture/dump.qml" 2>&1 \
  | sed -n 's/^.*CHUNK //p' > "$fixture/chunks.txt"

count=$(grep -c . "$fixture/chunks.txt" || true)
if [ "$count" -lt 4 ]; then
  echo "FAIL: expected 4 generated Lua chunks, got $count (silent/empty output must not pass)" >&2
  cat "$fixture/chunks.txt" >&2
  exit 1
fi

"$LUA_BIN" -e '
for line in io.lines(arg[1]) do
  local name, body = line:match("^(%S+) (.+)$")
  local f, err = load("return " .. body, name)
  if not f then io.stderr:write("LUA PARSE FAIL (" .. name .. "): " .. err .. "\n" .. body .. "\n"); os.exit(1) end
end' "$fixture/chunks.txt"
echo "PASS: $count generated Lua chunks parse"

"$LUA_BIN" "$src/tests/lua/tst_chunks.lua" "$fixture/chunks.txt"
```
Property: the `CHUNK NAME <body>` line format is what both the parse loop and `tst_chunks.lua` split on with `^(%S+) (.+)$`; chunk bodies are single-line by construction (the `\n`-flatten rule), which is exactly why one line per chunk is sound.

- [ ] **Step 4: Run it locally**

Run: `bash tests/lua-check.sh`
Expected: `PASS: 4 generated Lua chunks parse`, then eleven `ok   …` lines and `PASS: Lua chunk behaviour suite`. If a case fails, read its message: it names the property (order, end state, restore, report). A failure in `run()` with `attempt to index a nil value (field 'dsp')` means the mock lacks a dispatcher the chunk uses — add it to `hl.dsp`, never stub it as a no-op.

- [ ] **Step 5: Make CI install the runtime and fail on skip** — `.github/workflows/ci.yml`:

```yaml
name: ci
on:
  push:
  pull_request:
jobs:
  logic-tests:
    runs-on: ubuntu-latest
    env:
      CI: "1"
    steps:
      - uses: actions/checkout@v4
      - name: Install Qt6 Quick test tooling, the qml runtime and Lua
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            qml6-module-qttest qml6-module-qtquick qml6-module-qtqml \
            qml6-module-qtqml-workerscript qml6-module-qtquick-window \
            qt6-declarative-dev-tools qml-qt6 libqt6quick6 libgl1 lua5.4
      - name: Run Tier 1 logic tests (offscreen) + Lua chunk suite
        run: bash tests/run.sh
```
Environment facts pinned: on Ubuntu noble the `qml` runtime binary lives at `/usr/lib/qt6/bin/qml` in package `qml-qt6` (packages.ubuntu.com file search, 2026-09-10) and is **not** on PATH — hence the third probe in the script. `lua5.4` provides `/usr/bin/lua5.4`. GitHub already exports `CI=true`; the explicit `env` makes the requirement visible.

- [ ] **Step 6: Run the whole unit suite** — `mise run test`. Expected: Layout and Drag totals `0 failed`, then the two Lua PASS lines.

- [ ] **Step 7: Commit and push; watch CI**

```bash
git add tests/lua tests/lua-check.sh .github/workflows/ci.yml
git commit -m "test(lua): behaviour suite against a mock hl; CI fails instead of skipping the Lua check"
git push -u origin hardening
gh run watch --exit-status
```
Expected: the run's log contains `PASS: Lua chunk behaviour suite`. If it prints `FAIL: lua-check needs …`, the apt package names are wrong for the runner image — `apt-cache search qml | grep qt6` in a step to find the runtime package, and fix the workflow rather than relaxing the check.

---

## Task 6: Docs, version, ledger

**Files:**
- Modify: `README.md` (requirements section, ~line 38), `ROADMAP.md` (status + maintenance gotchas), `manifest.json` (version), `.agent/sdd/progress.md`

- [ ] **Step 1: README** — in the requirements list (after the Omarchy/Hyprland bullet) add:

```markdown
- The **dwindle** layout for drag-to-rearrange. On any other layout a tiled drop still moves
  the window to the target workspace, but it is not re-tiled at the drop point (the
  cursor-based insert is a dwindle behaviour). Floating drops work on every layout.
```

- [ ] **Step 2: ROADMAP** — under `## Maintenance gotchas` add:

```markdown
- **Every compositor operation is one atomic Lua chunk** (`logic.js`: `tiledInsertLua`,
  `floatingMoveLua`, `unfullscreenLua`). The shell unloads the overlay on toggle-close
  (`keepLoaded: false`), so nothing in `Overview.qml` may be required to *finish* an
  operation — `pendingMoves` is optimistic display state only. Chunk failures are printed to
  the Hyprland log (`[Lua] omascape: … failed: …`) and shown as a notification.
- `tests/lua-check.sh` runs the generated chunks against a mock `hl` (`tests/lua/`); a new
  dispatcher used by a chunk must be added to the mock, never stubbed as a no-op.
```
and in the `**Status:**` paragraph append: `Hardening (2026-09-10): atomic floating move, guarded chunk cleanup + error reporting, dwindle guard, event-flood-safe refresh, selection by workspace id, Lua behaviour suite in CI.`

- [ ] **Step 3: manifest** — `"version": "0.2.1"`.

- [ ] **Step 4: Ledger** — append to `.agent/sdd/progress.md` the `## Hardening (branch hardening)` section with per-task status (commit hashes) and the note that `mise run test-integration` was run after Tasks 1 and 2 with all `PASS:` lines.

- [ ] **Step 5: Commit, push, open the PR**

```bash
git add README.md ROADMAP.md manifest.json .agent/sdd/progress.md
git commit -m "docs: dwindle requirement, atomic-chunk rule, version 0.2.1"
git push
gh pr create --base main --head hardening --title "Hardening: atomic floating move, guarded Lua cleanup, event-flood-safe refresh, selection by id, Lua suite in CI" --body-file - <<'EOF'
Follow-up to the post-merge review of #8.

- Floating drops are one atomic Lua chunk (transfer + position); nothing depends on the overlay staying loaded after toggle-close.
- Tiled-insert cleanup (un-float, fullscreen re-apply, config restore) runs in guarded steps outside the risky pcall and re-reads state; swallowed errors are logged and shown as a notification.
- Non-dwindle layouts get a plain silent move.
- Raw-event floods no longer starve the settle timer or fan out refresh requests.
- Keyboard selection follows the workspace id across rebuilds.
- `tests/lua-check.sh` runs the generated chunks against a mock `hl` (fault injection included) and CI fails instead of skipping it.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
```

---

## Self-review notes

- **Coverage:** review items 1 (Task 2), 2 (Task 1), 3 (Task 3), 4 (Task 4), 5 partial by design — dwindle guard (Task 2) and the adapter/controller extraction deliberately deferred (recorded in the assessment that produced this plan), 6 (Task 5; Tier 2 in CI deferred).
- **Would-it-fail:** every new test has a stated pre-fix failure; Task 4's second UI test is explicitly a pin, not a discriminator. Task 5's mock toggles `floating` for real, and `__fail_on` defaults to `nil`.
- **Type consistency:** `floatingMoveLua(addr, targetWs, pos)` with `pos = {x, y}` in Tasks 1, 2, 5; `reportLua(what)` uses locals `ok, err` that every chunk now declares; `indexOfWorkspace(boxes, id)` in Task 4 only.
- **Environment:** Ubuntu package names verified against packages.ubuntu.com for noble; Hyprland API facts verified against `v0.56.2` sources (see Conventions).
