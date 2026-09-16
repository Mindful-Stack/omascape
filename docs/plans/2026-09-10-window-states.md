# Omascape — Window States (fullscreen + floating) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Draw fullscreen windows in their real tiled slot with a clickable un-fullscreen badge, let drops treat them as ordinary tiled windows, and stack floating tiles above tiled ones.

**Architecture:** Slot recovery, per-tile stacking layer and every Lua chunk stay in the pure `.pragma library` `logic.js` (Tier-1 unit-tested offscreen). `Overview.qml` plumbs the integer fullscreen mode into the tiles model, owns the optimistic `pendingFullscreen` state and the un-fullscreen dispatch, and drops its "fullscreen ⇒ not tiled" exclusions. `WindowTile.qml` gets the layer-based z and the badge. Integration on a nested Lua Hyprland proves the compositor interplay.

**Tech Stack:** QML/Qt Quick, Quickshell 0.3.1, Hyprland 0.56.2 in Lua configuration mode (`hl.dsp.*`, `hl.get_window`, `hl.get_workspace`). Tests: `mise run test` (Qt6 `qmltestrunner` offscreen: `tests/tst_layout.qml` + `tests/ui/drag.qml`), `mise run test-integration` (nested Hyprland + real Quickshell).

**Spec:** `docs/specs/2026-09-10-window-states-design.md` (read it first). Branch: `window-states` (created off `drag-ghost`; the spec is committed there).

---

## Conventions (every task)

**Branch:** `git checkout window-states`.

**Unit-test loop:** `mise run test` — runs `tests/run.sh`: the pure `logic.js` tests (`tests/tst_layout.qml`) and the offscreen Qt UI tests (`tests/ui/run.sh` builds a fixture from production QML with `tests/ui/prepare.py` and runs `tests/ui/drag.qml`). Everything must stay green after every task. To run only the UI tests: `bash tests/ui/run.sh`. To run one test function: `bash tests/ui/run.sh Drag::test_name` (the runner passes extra args through to `qmltestrunner`), or for layout tests `/usr/lib/qt6/bin/qmltestrunner -input tests -functions | grep name` then `... Layout::test_name`.

**Integration loop:** `mise run test-integration` (needs `Hyprland`, `hyprctl`, `quickshell`, `foot`, `jq`, and a running Wayland session for the nested output). The script skips with `SKIP:` when a binary is missing — a skip is **not** a pass; run it on the dev machine.

**Live-test loop (QML tasks):** copy changed files into the installed clone and restart the shell (QML edits need a full restart, not a rescan):
```bash
LIVE="$HOME/.config/omarchy/plugins/se.mindfulstack.omascape"
cp logic.js WindowTile.qml Overview.qml "$LIVE"/ && omarchy restart shell
```
Then SUPER+P. Workspace 8 on the dev machine currently holds a fullscreen Chrome over a tiled Teams — a ready-made live case.

**Params:** `params` gains `slotGapTolerance: 24`. Every place the params object is spelled out (`Overview.qml` `params`, `tests/tst_layout.qml` `params`) gets the new key.

**Lua chunk rule:** every chunk sent through `Hyprland.dispatch` must be a **single line** (Quickshell drops multi-line requests silently). Build readable with `\n`, then `.replace(/\n\s*/g, ' ')` — the existing `tiledInsertLua` pattern.

**Commit style:** `feat(...)`, `test(...)`, `refactor(...)`, `docs(...)`; message body explains *why*.

---

## Task 1: Integration bootstrap library + fullscreen dispatcher probe

Settles the one open question in the spec — whether `hl.dsp.window.fullscreen` accepts a `window` selector — **before** any chunk is written, and extracts the nested-Hyprland bootstrap that Task 8's new integration script will share. This is shared test infrastructure: every later integration assertion inherits it, so the extraction must not change what `drag.sh` proves (isolated nested compositor, offset output at `0x1440`, Lua configuration mode, real Quickshell with theme-only adapters).

**Files:**
- Create: `tests/integration/lib.sh`
- Modify: `tests/integration/drag.sh` (replace its inline bootstrap with `source lib.sh`)
- Create: `tests/integration/probe-fullscreen.sh`

- [ ] **Step 1: Extract the bootstrap into `tests/integration/lib.sh`**

Move these pieces of `drag.sh` verbatim into a sourced library (keep the exact commands; only the `main` flow stays in `drag.sh`):

```bash
#!/usr/bin/env bash
# Shared bootstrap for the nested-Hyprland integration scripts. Source it after `set -euo pipefail`.
# Provides: require_bins, start_nested (sets $nested $socket $tmp $hypr_pid, defines hc), hc,
# start_quickshell (sets $qs_pid, defines ipc), spawn_window, box, geometry, dump, wait_pending.
require_bins() {
    for bin in Hyprland hyprctl quickshell foot jq; do
        command -v "$bin" >/dev/null || { echo "SKIP: $bin not installed"; exit 0; }
    done
}
src=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
nested=""; hypr_pid=""; qs_pid=""
cleanup() {
    [[ -z "$qs_pid" ]] || kill "$qs_pid" 2>/dev/null || true
    [[ -z "$nested" ]] || HYPRLAND_INSTANCE_SIGNATURE="$nested" hyprctl dispatch 'hl.dsp.exit()' >/dev/null 2>&1 || true
    [[ -z "$hypr_pid" ]] || kill "$hypr_pid" 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT
hc() { HYPRLAND_INSTANCE_SIGNATURE="$nested" hyprctl "$@"; }
# start_nested [extra Lua config lines...]: isolated Lua-mode Hyprland on an offset headless output.
start_nested() {
    {
        cat <<'CONF'
hl.config({ misc = { disable_hyprland_logo = true, disable_splash_rendering = true } })
hl.monitor({output="", mode="1280x720", position="0x1440", scale=1})
hl.workspace_rule({workspace="3", persistent=true})
CONF
        printf '%s\n' "$@"
    } > "$tmp/hypr.lua"
    Hyprland -c "$tmp/hypr.lua" > "$tmp/hypr.log" 2>&1 & hypr_pid=$!
    for _ in $(seq 1 60); do
        nested=$(hyprctl instances -j | jq -r --argjson p "$hypr_pid" '.[] | select(.pid==$p) | .instance')
        [[ -z "$nested" ]] || break
        sleep 0.25
    done
    [[ -n "$nested" ]] || { cat "$tmp/hypr.log"; exit 1; }
    local mon; mon=$(hc monitors -j | jq -r '.[0].name')
    case "$mon" in WAYLAND-*|WL-*|HEADLESS-*) ;; *) echo "REFUSE: $mon is not nested"; exit 1;; esac
    socket=$(hyprctl instances -j | jq -r --argjson p "$hypr_pid" '.[] | select(.pid==$p) | .wl_socket')
}
# start_quickshell: production Overview + the dragtest IPC shell, theme-only adapters.
start_quickshell() {
    mkdir -p "$tmp/Commons" "$tmp/Ui"
    printf 'module qs.Commons\nsingleton Color 1.0 Color.qml\nsingleton Style 1.0 Style.qml\n' > "$tmp/Commons/qmldir"
    printf 'pragma Singleton\nimport QtQuick\nQtObject { readonly property var menu: ({background:"#222",text:"#fff",border:"#888",scrim:"#000",selectedBackground:"#444",selectedText:"#fff"}) }\n' > "$tmp/Commons/Color.qml"
    printf 'pragma Singleton\nimport QtQuick\nQtObject { readonly property int cornerRadius: 8 }\n' > "$tmp/Commons/Style.qml"
    printf 'module qs.Ui\nUnused 1.0 Unused.qml\n' > "$tmp/Ui/qmldir"
    printf 'import QtQuick\nItem {}\n' > "$tmp/Ui/Unused.qml"
    cp "$src/Overview.qml" "$src/WindowTile.qml" "$src/logic.js" "$tmp/"
    cp "$src/tests/integration/drag.qml" "$tmp/shell.qml"
    HYPRLAND_INSTANCE_SIGNATURE="$nested" WAYLAND_DISPLAY="$socket" quickshell -p "$tmp/shell.qml" > "$tmp/qs.log" 2>&1 & qs_pid=$!
    for _ in $(seq 1 40); do
        ipc pending >/dev/null 2>&1 && break
        sleep 0.1
    done
    ipc pending >/dev/null || { cat "$tmp/qs.log"; exit 1; }
}
ipc() { WAYLAND_DISPLAY="$socket" quickshell ipc -p "$tmp/shell.qml" call dragtest "$@"; }
spawn_window() {
    local old found
    old=$(hc clients -j | jq '[.[].address]')
    hc dispatch 'hl.dsp.exec_cmd("foot")' >/dev/null
    for _ in $(seq 1 40); do
        found=$(hc clients -j | jq -r --argjson old "$old" '.[]|.address as $a|select($old|index($a)|not)|.address' | head -1)
        [[ -z "$found" ]] || { echo "$found"; return; }
        sleep 0.1
    done
    return 1
}
geometry() { hc clients -j | jq -c --arg a "$1" '.[]|select(.address==$a)|{at,size}'; }
box() { hc clients -j | jq -r --arg a "$1" '.[]|select(.address==$a)|"\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.workspace.id)"'; }
fsmode() { hc clients -j | jq -r --arg a "$1" '.[]|select(.address==$a)|.fullscreen'; }
dump() { hc clients -j | jq '[.[]|{address,at,size,workspace:.workspace.id,fullscreen}]'; cat "$tmp/qs.log"; }
wait_pending() {
    for _ in $(seq 1 40); do
        [[ "$(ipc pending)" == '{}' ]] && return
        sleep 0.1
    done
    echo 'FAIL: drop not acknowledged'; cat "$tmp/qs.log"; exit 1
}
```

Then rewrite the top of `drag.sh` so it becomes:

```bash
#!/usr/bin/env bash
# Exercises the real Overview submit/ack code via Quickshell on a disposable compositor.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_bins
start_nested
hc dispatch 'hl.dsp.focus({workspace="1"})'  >/dev/null
hc dispatch 'hl.dsp.exec_cmd("foot")'  >/dev/null
```
…continuing from the original `addr=""` loop. Delete from `drag.sh` every function now defined in `lib.sh` (`cleanup`, `hc`, `ipc`, `spawn_window`, `geometry`, `box`, `dump`, `wait_pending`) and the inline Quickshell/Commons setup, replacing that setup with a single `start_quickshell` call at the same point (right after the two `focus` dispatches that create workspace 3). Keep `assert_position`, `stack_below` and every `PASS`/`FAIL` line unchanged.

Property the refactor must keep: `bash tests/integration/drag.sh` prints the **same eight `PASS:` lines** as before the change and exits 0. The `REFUSE:` guard still rejects a non-nested monitor.

- [ ] **Step 2: Run the existing integration test to prove the extraction is behaviour-neutral**

Run: `bash tests/integration/drag.sh`
Expected: the eight `PASS:` lines ending with `PASS: production tiled drop inserts at the drop point on a hidden workspace; state restored`, exit 0. If it prints `SKIP:` you are not on the dev machine — the refactor is unverified; do not continue.

- [ ] **Step 3: Write the probe script**

`tests/integration/probe-fullscreen.sh` — bash only, no Quickshell. It answers: does `hl.dsp.window.fullscreen({ window = ..., mode = ..., action = "toggle" })` act on the *named* window rather than the focused one?

```bash
#!/usr/bin/env bash
# Probe: does the typed fullscreen dispatcher honour a `window` selector (0.56.2)?
# Prints PREFERRED (it does) or FALLBACK (it only acts on the focused window).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_bins
start_nested
hc dispatch 'hl.dsp.focus({workspace="1"})' >/dev/null
a=$(spawn_window); b=$(spawn_window); sleep 0.4
# Focus `a` explicitly, then ask for fullscreen on `b` by selector.
hc dispatch "hl.dsp.focus({window='address:$a'})" >/dev/null; sleep 0.2
[[ "$(hc activewindow -j | jq -r .address)" == "$a" ]] || { echo "FAIL: could not focus a"; dump; exit 1; }
hc dispatch "hl.dsp.window.fullscreen({window='address:$b', mode='fullscreen', action='toggle'})" || true
sleep 0.3
echo "a fullscreen=$(fsmode "$a") b fullscreen=$(fsmode "$b") active=$(hc activewindow -j | jq -r .address)"
grep -i 'invalid\|error' "$tmp/hypr.log" | tail -3 || true
if [[ "$(fsmode "$b")" == 2 && "$(fsmode "$a")" == 0 ]]; then
    echo PREFERRED
    # Second half: does the same call turn it back off (toggle semantics with the same mode)?
    hc dispatch "hl.dsp.window.fullscreen({window='address:$b', mode='fullscreen', action='toggle'})"; sleep 0.3
    [[ "$(fsmode "$b")" == 0 ]] && echo 'PREFERRED: toggle with the same mode turns it off' || echo 'WARN: toggle did not turn it off — inspect hypr.log'
else
    echo FALLBACK
fi
```

- [ ] **Step 4: Run the probe and record the answer**

Run: `bash tests/integration/probe-fullscreen.sh`
Expected: one of
- `PREFERRED` (+ the toggle-off confirmation): `b` is fullscreen, `a` is not, active window still `a`.
- `FALLBACK`: `a` (the focused window) went fullscreen or nothing changed.

Record the answer in the spec: replace the sentence in "Background facts" that says the selector support is *unverified* with the actual result (date it), and in "Dispatching fullscreen" mark the form that Task 2 implements. This is the "one source of truth" rule — the spec must not keep saying "unverified" once it is known.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/lib.sh tests/integration/drag.sh tests/integration/probe-fullscreen.sh docs/specs/2026-09-10-window-states-design.md
git commit -m "test(integration): share the nested-Hyprland bootstrap; probe the fullscreen dispatcher's window selector"
```

---

## Task 2: `logic.js` — `fullscreenBodyLua` + `unfullscreenLua`

**Files:**
- Modify: `logic.js` (add after `tiledInsertLua`)
- Test: `tests/tst_layout.qml`

- [ ] **Step 1: Write the failing tests**

Append inside the `TestCase` in `tests/tst_layout.qml`:

```js
    // The un-fullscreen chunk re-reads the window and only acts when its mode differs from the
    // target, so a stale badge click is harmless; it names the window by address, is one line,
    // and takes the target mode as a Lua expression (the insert chunk re-applies a recorded mode).
    function test_unfullscreen_lua_is_guarded_single_line_and_addressed() {
        var lua = Logic.unfullscreenLua("0xabc")
        verify(lua.indexOf('\n') < 0, "single line: Quickshell drops multi-line dispatches")
        verify(lua.indexOf('function()') === 0, "a function chunk, evaluated by hl.dispatch")
        verify(lua.indexOf('hl.get_window("address:0xabc")') >= 0, "re-reads the window by address")
        verify(lua.indexOf('fw.fullscreen ~= fm') >= 0, "guard: acts only when the mode differs")
        verify(lua.indexOf('hl.dsp.window.fullscreen(') >= 0)
        verify(lua.indexOf('hl.get_window("address:0xabc"), 0') >= 0, "target mode 0 = off")
        verify(lua.indexOf('NaN') < 0 && lua.indexOf('undefined') < 0)
        verify(lua.indexOf('local prevW, cur = hl.get_active_window(), hl.get_cursor_pos()') >= 0, "records focus + cursor first")
        var fsAt = lua.indexOf('hl.dsp.window.fullscreen('), focusAt = lua.indexOf('hl.dsp.focus('), curAt = lua.lastIndexOf('cursor.move(')
        verify(focusAt > fsAt && curAt > focusAt, "re-focus (if changed) then cursor restore, after the toggle")
        verify(lua.indexOf('nowW.address ~= prevW.address') >= 0, "re-focuses only when focus actually moved")
        var body = Logic.fullscreenBodyLua('fsSel', 'fsMode')
        verify(body.indexOf('hl.get_window(fsSel), fsMode') >= 0, "selector and mode may be Lua expressions")
        verify(body.indexOf('"maximized" or "fullscreen"') >= 0, "mode name derived from target/current mode")
    }
```

What this distinguishes: a chunk that dispatches unconditionally (no `~=` guard), one that hard-codes the mode instead of accepting an expression, or one that forgot the single-line flatten.

- [ ] **Step 2: Run to verify it fails**

Run: `mise run test`
Expected: `FAIL!  : Layout::test_unfullscreen_lua_is_guarded_single_line_and_addressed()` with `TypeError: ... unfullscreenLua is not a function`.

- [ ] **Step 3: Implement**

Add to `logic.js` after `tiledInsertLua`. Use the **form Task 1 recorded**. Preferred form:

```js
// ---- fullscreen ----
//
// Lua statements that leave the window selected by the Lua expression `sel` (e.g. '"address:0x1"'
// or a local name) in fullscreen mode `modeExpr` (a Lua expression: 0 off, 1 maximized,
// 2 fullscreen). Re-reads the window and toggles only when its mode differs, so the statements
// are idempotent and a stale request is harmless. Hyprland's toggle turns fullscreen OFF when
// asked for the mode the window already has and SWITCHES modes otherwise, so when turning off the
// name is taken from the window's current mode.
function fullscreenBodyLua(sel, modeExpr) {
    return (
        'do local fw, fm = hl.get_window(' + sel + '), ' + modeExpr + '\n' +
        '  if fw and fm and fw.fullscreen ~= fm then\n' +
        '    local name = (fm == 1 or (fm == 0 and fw.fullscreen == 1)) and "maximized" or "fullscreen"\n' +
        '    hl.dispatch(hl.dsp.window.fullscreen({ window = ' + sel + ', mode = name, action = "toggle" }))\n' +
        '  end\n' +
        'end'
    )
}

// Lua statements that re-focus the window `prevExpr` (an HL.Window or nil, read before the
// change) when the active window is no longer it, then move the cursor back to `curExpr`
// (an HL.Vec2 or nil). The probe (tests/integration/probe-fullscreen.sh) showed the fullscreen
// dispatcher can drop focus to nil, and focusing warps the cursor, so every chunk that touches
// fullscreen ends with this. Addresses from Lua may lack the 0x prefix hyprctl uses.
function restoreFocusLua(prevExpr, curExpr) {
    return (
        'do local nowW = hl.get_active_window()\n' +
        '  if ' + prevExpr + ' and (not nowW or nowW.address ~= ' + prevExpr + '.address) then\n' +
        '    local a = tostring(' + prevExpr + '.address)\n' +
        '    if a:sub(1, 2) ~= "0x" then a = "0x" .. a end\n' +
        '    hl.dispatch(hl.dsp.focus({ window = "address:" .. a }))\n' +
        '  end\n' +
        '  if ' + curExpr + ' then hl.dispatch(hl.dsp.cursor.move({ x = ' + curExpr + '.x, y = ' + curExpr + '.y })) end\n' +
        'end'
    )
}

// One atomic chunk that turns fullscreen off for `addr`. Focus, the active workspace and the
// cursor end up where they were. Used by the tile badge.
function unfullscreenLua(addr) {
    return (
        'function()\n' +
        '  local prevW, cur = hl.get_active_window(), hl.get_cursor_pos()\n' +
        fullscreenBodyLua('"address:' + addr + '"', '0') + '\n' +
        restoreFocusLua('prevW', 'cur') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}
```

Fallback form (only if Task 1 printed `FALLBACK`): the dispatcher acts on the focused window, so focus the target inside the same chunk and restore focus before returning — nothing renders in between. Replace the `hl.dispatch(hl.dsp.window.fullscreen(...))` line with:

```js
        '    local prevW, prevWs = hl.get_active_window(), hl.get_active_workspace()\n' +
        '    hl.dispatch(hl.dsp.focus({ window = ' + sel + ' }))\n' +
        '    hl.dispatch(hl.dsp.window.fullscreen({ mode = name, action = "toggle" }))\n' +
        '    if prevW then hl.dispatch(hl.dsp.focus({ window = "address:" .. prevW.address }))\n' +
        '    elseif prevWs then hl.dispatch(hl.dsp.focus({ workspace = tostring(prevWs.id) })) end\n' +
```
Property the fallback must hold (proved by Task 8's test (a)): after the chunk, `hyprctl activeworkspace` and `activewindow` are what they were before, and the cursor position is unchanged. If `prevW.address` turns out not to carry the `0x` prefix, `hl.get_window("address:" .. prevW.address)` in the integration log will show the focus restore failing — then use `hl.dsp.focus({ window = prevW })` (selector by object) and re-run.

- [ ] **Step 4: Run to verify it passes**

Run: `mise run test`
Expected: `PASS   : Layout::test_unfullscreen_lua_is_guarded_single_line_and_addressed()`; totals unchanged otherwise.

- [ ] **Step 5: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "feat(logic): guarded atomic Lua to set a window's fullscreen mode by address"
```

---

## Task 3: `logic.js` — `recoverSlot`

Pure geometry; this is what every fullscreen tile is placed by. Highest-value unit tests in the plan.

**Files:**
- Modify: `logic.js` (add before `layout`)
- Test: `tests/tst_layout.qml`

- [ ] **Step 1: Write the failing tests**

Add `slotGapTolerance: 24` to the `params` object at the top of `tests/tst_layout.qml`. Then append:

```js
    // ---- recoverSlot: a fullscreen window's tiled slot is what the OTHER tiled windows leave
    // uncovered. R is the usable rect in local coords (2048x1254 = eDP-1 minus the 26px bar).
    readonly property var usableR: ({ x: 0, y: 0, w: 2048, h: 1254 })   // QML property names must start lowercase
    function slotEq(s, x, y, w, h, msg) {
        verify(s !== null, msg + ": got null")
        compare(s.x, x, msg + " x"); compare(s.y, y, msg + " y")
        compare(s.w, w, msg + " w"); compare(s.h, h, msg + " h")
    }
    function test_recover_slot_two_windows() {
        // Teams on the left (x 0..825), Chrome fullscreen: the hole is the right part.
        slotEq(Logic.recoverSlot(usableR, [{ x: 0, y: 0, w: 825, h: 1254 }], params),
               825, 0, 1223, 1254, "two windows")
    }
    function test_recover_slot_nested_split_no_gaps() {
        // left column split top/bottom, hole = right half (a projected horizontal edge splits
        // the hole into two grid cells that must be merged back)
        slotEq(Logic.recoverSlot(usableR, [{ x: 0, y: 0, w: 1024, h: 627 },
                                     { x: 0, y: 627, w: 1024, h: 627 }], params),
               1024, 0, 1024, 1254, "nested split")
    }
    // gaps_in 5 / gaps_out 10: the outer/inner strips are separate thin grid cells wherever a
    // neighbour's edge creates one; those are trimmed, so the recovered slot starts at the true
    // top (y 10, h 1234). Sides without a neighbour edge keep the gap merged in (x may be 1019
    // or 1029, right edge 2048): padding, never a wrong slot.
    function test_recover_slot_with_gaps_trims_padding() {
        var s = Logic.recoverSlot(usableR, [{ x: 10, y: 10, w: 1009, h: 612 },
                                      { x: 10, y: 632, w: 1009, h: 612 }], params)
        verify(s !== null)
        compare(s.y, 10, "top gap row trimmed"); compare(s.h, 1234, "bottom gap row trimmed")
        verify(s.x >= 1019 && s.x <= 1029, "left edge within the inner gap")
        compare(s.x + s.w, 2048)
    }
    // gaps_out 40 is ABOVE slotGapTolerance: the outer strips survive the trim as padding, but
    // the old bounding-box approach would have stretched the result to the whole rect (x 0).
    // Seed+grow must stop at the neighbour: the slot never reaches the left strip.
    function test_recover_slot_outer_gap_above_tolerance_never_spans_whole_rect() {
        var s = Logic.recoverSlot(usableR, [{ x: 40, y: 40, w: 979, h: 582 },
                                      { x: 40, y: 632, w: 979, h: 582 }], params)
        verify(s !== null)
        verify(s.x >= 1019, "must not cross the neighbour into the left outer strip: x=" + s.x)
        compare(s.x + s.w, 2048)
        // contains the true tiled rect {1029,40,979,1174}
        verify(s.x <= 1029 && s.y <= 40 && s.x + s.w >= 2008 && s.y + s.h >= 1214)
    }
    // The fullscreen window was the SMALLEST of six, gaps_in 5: projected edges split the hole,
    // strips are thin. Seed on largest-min-side + grow + trim recovers the exact tiled rect.
    function test_recover_slot_smallest_of_six_exact() {
        var others = [
            { x: 0,    y: 0,   w: 1019, h: 1254 },   // A: left half
            { x: 1029, y: 0,   w: 1019, h: 622 },    // B: right-top
            { x: 1029, y: 632, w: 507,  h: 308 },    // C
            { x: 1541, y: 632, w: 507,  h: 308 },    // D
            { x: 1029, y: 945, w: 507,  h: 309 }     // E ; hole = {1541,945,507,309}
        ]
        slotEq(Logic.recoverSlot(usableR, others, params), 1541, 945, 507, 309, "smallest of six")
    }
    function test_recover_slot_no_others_is_whole_rect() {
        slotEq(Logic.recoverSlot(usableR, [], params), 0, 0, 2048, 1254, "lone")
    }
    function test_recover_slot_fully_covered_is_null() {
        compare(Logic.recoverSlot(usableR, [{ x: 0, y: 0, w: 2048, h: 1254 }], params), null)
        // only a hairline uncovered (thinner than the tolerance) is null too
        compare(Logic.recoverSlot(usableR, [{ x: 0, y: 0, w: 2040, h: 1254 }], params), null)
    }
    function test_recover_slot_clips_others_to_rect() {
        // a window poking left of R must not create a phantom column outside it
        slotEq(Logic.recoverSlot(usableR, [{ x: -100, y: 0, w: 1124, h: 1254 }], params),
               1024, 0, 1024, 1254, "clipped")
    }
```

What these distinguish: `two_windows`/`nested_split` catch a wrong complement or failure to merge cells split by projected edges; `with_gaps` catches a missing trim; `outer_gap_above_tolerance` catches any bounding-box-of-uncovered-cells implementation (it returns x 0); `smallest_of_six` catches an area-based seed or a grow that crosses a neighbour; the null cases catch a missing fallback; `clips` catches unclipped edges.

- [ ] **Step 2: Run to verify they fail**

Run: `mise run test`
Expected: the eight new `Layout::test_recover_slot_*` fail with `recoverSlot is not a function`.

- [ ] **Step 3: Implement**

Add to `logic.js` before `layout(input)`:

```js
function _uniqSorted(a) {
    a = a.slice().sort(function (p, q) { return p - q })
    var out = []
    for (var i = 0; i < a.length; i++) if (!out.length || a[i] - out[out.length - 1] > 0.5) out.push(a[i])
    return out
}

// Where a fullscreen window sits in the tiled layout, recovered from what the OTHER tiled
// windows leave uncovered: dwindle slots partition the usable rect, and fullscreen hides the
// others without moving them, so the hole is the slot the window returns to. `R` is the usable
// rect and `others` rects in the same coordinates (floating/fullscreen windows excluded by the
// caller). Grid R on every edge; seed on the uncovered cell with the largest MINIMUM side (a gap
// strip can never win that, so no gap configuration is needed); grow while whole neighbouring
// columns/rows are uncovered (absorbs adjacent gap padding, never crosses a neighbour); trim
// outer columns/rows thinner than P.slotGapTolerance. Null when nothing usable is uncovered.
function recoverSlot(R, others, P) {
    var tol = P.slotGapTolerance || 24
    var xs = [R.x, R.x + R.w], ys = [R.y, R.y + R.h], rects = []
    for (var i = 0; i < others.length; i++) {
        var o = others[i]
        var x0 = Math.max(R.x, o.x), y0 = Math.max(R.y, o.y)
        var x1 = Math.min(R.x + R.w, o.x + o.w), y1 = Math.min(R.y + R.h, o.y + o.h)
        if (x1 <= x0 || y1 <= y0) continue
        rects.push({ x0: x0, y0: y0, x1: x1, y1: y1 })
        xs.push(x0, x1); ys.push(y0, y1)
    }
    xs = _uniqSorted(xs); ys = _uniqSorted(ys)
    var nx = xs.length - 1, ny = ys.length - 1
    var cov = []                                   // cov[ci][cj]: cell centre inside some rect
    for (var ci = 0; ci < nx; ci++) {
        cov.push([])
        for (var cj = 0; cj < ny; cj++) {
            var cx = (xs[ci] + xs[ci + 1]) / 2, cy = (ys[cj] + ys[cj + 1]) / 2, hit = false
            for (var k = 0; k < rects.length && !hit; k++)
                hit = cx > rects[k].x0 && cx < rects[k].x1 && cy > rects[k].y0 && cy < rects[k].y1
            cov[ci].push(hit)
        }
    }
    var si = -1, sj = -1, best = 0
    for (ci = 0; ci < nx; ci++) for (cj = 0; cj < ny; cj++) {
        if (cov[ci][cj]) continue
        var m = Math.min(xs[ci + 1] - xs[ci], ys[cj + 1] - ys[cj])
        if (m > best) { best = m; si = ci; sj = cj }
    }
    if (si < 0) return null
    function colFree(c, ja, jb) { for (var j = ja; j <= jb; j++) if (cov[c][j]) return false; return true }
    function rowFree(r, ia, ib) { for (var i2 = ia; i2 <= ib; i2++) if (cov[i2][r]) return false; return true }
    var i0 = si, i1 = si, j0 = sj, j1 = sj, grew = true
    while (grew) {
        grew = false
        if (i0 > 0 && colFree(i0 - 1, j0, j1)) { i0--; grew = true }
        if (i1 < nx - 1 && colFree(i1 + 1, j0, j1)) { i1++; grew = true }
        if (j0 > 0 && rowFree(j0 - 1, i0, i1)) { j0--; grew = true }
        if (j1 < ny - 1 && rowFree(j1 + 1, i0, i1)) { j1++; grew = true }
    }
    // Cumulative per side: peel at most one gap band, never a chain of thin projected-edge cells.
    var tx0 = xs[i0];     while (i0 < i1 && xs[i0 + 1] - tx0 < tol) i0++
    var tx1 = xs[i1 + 1]; while (i1 > i0 && tx1 - xs[i1] < tol) i1--
    var ty0 = ys[j0];     while (j0 < j1 && ys[j0 + 1] - ty0 < tol) j0++
    var ty1 = ys[j1 + 1]; while (j1 > j0 && ty1 - ys[j1] < tol) j1--
    var slot = { x: xs[i0], y: ys[j0], w: xs[i1 + 1] - xs[i0], h: ys[j1 + 1] - ys[j0] }
    return Math.min(slot.w, slot.h) <= tol ? null : slot
}
```

Property: for any set of non-overlapping `others` that, together with one missing rectangle, partition `R`, the result contains that missing rectangle and never extends past the neighbours' facing edges by more than the adjacent gap. The tests above are instances of this.

- [ ] **Step 4: Run to verify they pass**

Run: `mise run test`
Expected: all eight `test_recover_slot_*` PASS. If `smallest_of_six` fails on `x`, check the trim loop compares `< tol` (a 5px strip column must be dropped).

- [ ] **Step 5: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "feat(logic): recoverSlot — a fullscreen window's tiled slot from what its neighbours leave uncovered"
```

---

## Task 4: `logic.js` — `layout()` places fullscreen windows in the slot and emits `layer`/`fullscreen`

**Files:**
- Modify: `logic.js` (`_tileRect`, `layout`)
- Test: `tests/tst_layout.qml`

- [ ] **Step 1: Write the failing tests**

Append to `tests/tst_layout.qml`:

```js
    // ---- layout(): fullscreen windows are placed in the recovered slot; every tile carries a
    // stacking layer (0 backdrop, 1 tiled, 2 floating) and the fullscreen mode.
    function fsInput(windows) {
        return { monitors: [edp()],
                 workspaces: [{ id: 1, monitorName: "eDP-1", focused: true, occupied: true }],
                 windows: windows, focusedMonitorName: "eDP-1", availW: 1632, params: params }
    }
    // eDP: R = 2048x1254, cell mini-map 308x188 → height-limited, k = 188/1254.
    readonly property real kEdp: 188 / 1254
    function test_fullscreen_tiled_lands_in_recovered_slot() {
        var r = Logic.layout(fsInput([
            { address: "0xT", cls: "teams", ax: 0, ay: 26, sw: 825, sh: 1254, workspaceId: 1, floating: false, fullscreen: 0 },
            { address: "0xF", cls: "chrome", ax: 0, ay: 0, sw: 2048, sh: 1280, workspaceId: 1, floating: false, fullscreen: 2 }
        ]))
        var t = tilesByAddr(r, "0xT"), f = tilesByAddr(r, "0xF")
        fuzzyCompare(f.x, t.x + t.w, 0.6, "starts where the neighbour ends")
        fuzzyCompare(f.w, 1223 * kEdp, 0.6, "spans the uncovered width")
        fuzzyCompare(f.h, 188, 0.6, "full usable height")
        compare(f.layer, 1); compare(f.fullscreen, 2)
        compare(t.layer, 1); compare(t.fullscreen, 0)
        fuzzyCompare(t.w, 825 * kEdp, 0.6, "neighbour drawn from its real geometry")
    }
    function test_lone_fullscreen_still_fills_usable_rect() {
        var r = Logic.layout(fsInput([
            { address: "0xF", cls: "x", ax: 0, ay: 0, sw: 2048, sh: 1280, workspaceId: 1, floating: false, fullscreen: 2 }]))
        var f = tilesByAddr(r, "0xF")
        fuzzyCompare(f.h, 188, 0.5); fuzzyCompare(f.w, 2048 * kEdp, 0.6)
        compare(f.layer, 1)
    }
    // Stale data: the others already cover everything → fill R but sit BELOW the tiled tiles.
    function test_fullscreen_with_no_hole_is_backdrop() {
        var r = Logic.layout(fsInput([
            { address: "0xT", cls: "x", ax: 0, ay: 26, sw: 2048, sh: 1254, workspaceId: 1, floating: false, fullscreen: 0 },
            { address: "0xF", cls: "x", ax: 0, ay: 0, sw: 2048, sh: 1280, workspaceId: 1, floating: false, fullscreen: 2 }]))
        var f = tilesByAddr(r, "0xF")
        fuzzyCompare(f.h, 188, 0.5); compare(f.layer, 0)
        compare(tilesByAddr(r, "0xT").layer, 1)
    }
    // A floating window that is fullscreen has no slot: centred at 60% of R, floating layer.
    function test_floating_fullscreen_is_centred_60_percent() {
        var r = Logic.layout(fsInput([
            { address: "0xF", cls: "x", ax: 0, ay: 0, sw: 2048, sh: 1280, workspaceId: 1, floating: true, fullscreen: 2 }]))
        var f = tilesByAddr(r, "0xF"), b = boxById(r, 1)
        fuzzyCompare(f.w, 0.6 * 2048 * kEdp, 0.6); fuzzyCompare(f.h, 0.6 * 188, 0.6)
        fuzzyCompare(f.x - b.x, (b.w - f.w) / 2, 1.0, "horizontally centred in the box")
        compare(f.layer, 2); compare(f.fullscreen, 2)
    }
    function test_layers_and_mode_are_carried() {
        var r = Logic.layout(fsInput([
            { address: "0xA", cls: "x", ax: 100, ay: 100, sw: 400, sh: 300, workspaceId: 1, floating: true, fullscreen: 0 },
            { address: "0xB", cls: "x", ax: 600, ay: 100, sw: 400, sh: 300, workspaceId: 1, floating: false, fullscreen: 0 },
            { address: "0xM", cls: "x", ax: 0, ay: 26, sw: 2048, sh: 1254, workspaceId: 1, floating: false, fullscreen: 1 }]))
        compare(tilesByAddr(r, "0xA").layer, 2)
        compare(tilesByAddr(r, "0xB").layer, 1)
        compare(tilesByAddr(r, "0xM").fullscreen, 1, "maximized mode carried as 1")
        // legacy boolean still means fullscreen (mode 2)
        var legacy = Logic.layout(fsInput([{ address: "0xL", cls: "x", ax: 0, ay: 0, sw: 2048, sh: 1280,
                                              workspaceId: 1, floating: false, fullscreen: true }]))
        compare(tilesByAddr(legacy, "0xL").fullscreen, 2)
    }
```

What these distinguish: `lands_in_recovered_slot` fails on today's code (the fullscreen tile fills the cell, `f.x` equals the inset, and `layer` is undefined); `no_hole_is_backdrop` catches a layout that hides the neighbours behind a tiled-layer fill; `floating_fullscreen` catches applying slot recovery to a floating window; `layers_and_mode` catches a boolean-only plumb-through.

- [ ] **Step 2: Run to verify they fail**

Run: `mise run test`
Expected: the five new tests fail (`f.layer` undefined / geometry mismatch). The pre-existing fullscreen tests still pass.

- [ ] **Step 3: Implement**

In `logic.js`, change `_tileRect` to accept an optional slot (usable-rect-local) and replace its body from `var isFull` onward:

```js
function _tileRect(win, mon, box, P, slot) {
    var l = _monLogical(mon), R = _usableRect(mon)
    var mmW = box.w - 2 * P.cellInset, mmH = box.h - 2 * P.cellInset
    var k = Math.min(mmW / R.w, mmH / R.h)
    var offX = P.cellInset + (mmW - R.w * k) / 2
    var offY = P.cellInset + (mmH - R.h * k) / 2
    var wx, wy, sw, sh
    if (slot) {                                   // caller-decided rect (recovered slot etc.)
        wx = slot.x; wy = slot.y; sw = slot.w; sh = slot.h
    } else {
        var isFull = !!win.fullscreen ||
            (Math.abs(win.ax - mon.x) <= 1 && Math.abs(win.ay - mon.y) <= 1 &&
             Math.abs(win.sw - l.w) <= 1 && Math.abs(win.sh - l.h) <= 1)
        if (isFull)
            return { x: box.x + offX, y: box.y + offY, w: R.w * k, h: R.h * k }
        wx = (win.ax - mon.x) - R.x; wy = (win.ay - mon.y) - R.y; sw = win.sw; sh = win.sh
    }
    var cx = Math.max(0, wx), cy = Math.max(0, wy)
    var cR = Math.min(wx + sw, R.w), cB = Math.min(wy + sh, R.h)
    var cw = cR - cx, ch = cB - cy
    if (cw <= 0 || ch <= 0) return null
    var tx = box.x + offX + cx * k, ty = box.y + offY + cy * k
    var tw = Math.max(P.minTileW, cw * k), th = Math.max(P.minTileH, ch * k)
    tx = Math.max(box.x + P.cellInset, Math.min(tx, box.x + box.w - P.cellInset - tw))
    ty = Math.max(box.y + P.cellInset, Math.min(ty, box.y + box.h - P.cellInset - th))
    return { x: tx, y: ty, w: tw, h: th }
}
```

Property: with `slot` omitted the function is byte-for-byte the old behaviour (every pre-existing tile test still passes).

Add a normaliser near the top of `logic.js`:

```js
// Hyprland's `fullscreen` client field is 0 none / 1 maximized / 2 fullscreen; older callers
// passed a boolean, which means fullscreen.
function fullscreenMode(win) {
    return win.fullscreen === true ? 2 : (win.fullscreen | 0)
}
```

In `layout()`, replace the tiles loop (`var tiles = []` … `return`) with:

```js
    // Tiled, non-fullscreen windows per workspace in usable-rect-local coords: what a
    // fullscreen window's slot is recovered from (see recoverSlot).
    var tiledByWs = {}
    for (var pi = 0; pi < input.windows.length; pi++) {
        var pw = input.windows[pi]
        if (pw.floating || fullscreenMode(pw)) continue
        var pbox = boxByWs[pw.workspaceId], pmon = pbox ? monByName[pbox.monitorName] : null
        if (!pmon) continue
        var pR = _usableRect(pmon)
        ;(tiledByWs[pw.workspaceId] = tiledByWs[pw.workspaceId] || []).push(
            { x: (pw.ax - pmon.x) - pR.x, y: (pw.ay - pmon.y) - pR.y, w: pw.sw, h: pw.sh })
    }
    var tiles = []
    for (var wi = 0; wi < input.windows.length; wi++) {
        var win = input.windows[wi], wbox = boxByWs[win.workspaceId]; if (!wbox) continue
        var wmon = monByName[wbox.monitorName]; if (!wmon) continue
        var mode = fullscreenMode(win), layer = win.floating ? 2 : 1, slot = null
        if (mode) {
            var UR = _usableRect(wmon), whole = { x: 0, y: 0, w: UR.w, h: UR.h }
            if (win.floating) {
                slot = { x: UR.w * 0.2, y: UR.h * 0.2, w: UR.w * 0.6, h: UR.h * 0.6 }   // no slot exists
            } else {
                var others = tiledByWs[win.workspaceId] || []
                slot = others.length ? recoverSlot(whole, others, P) : whole
                if (!slot) { slot = whole; layer = 0 }                              // ambiguous → backdrop
            }
        }
        var t = _tileRect(win, wmon, wbox, P, slot)
        if (t) {
            t.address = win.address; t.workspaceId = win.workspaceId
            t.layer = layer; t.fullscreen = mode
            tiles.push(t)
        }
    }
    return { canvasSize: { w: canvasW, h: y }, boxes: boxes, tiles: tiles,
             groups: groups, cell: { w: cw, h: ch, cols: cols } }
```

- [ ] **Step 4: Run to verify they pass**

Run: `mise run test`
Expected: all `Layout::` tests PASS, including the three pre-existing fullscreen tests (lone fullscreen still fills).

- [ ] **Step 5: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "feat(logic): fullscreen tiles placed in the recovered slot; tiles carry layer and fullscreen mode"
```

---

## Task 5: Model roles + layer-based stacking (Feature 4) in `Overview.qml` / `WindowTile.qml`

**Files:**
- Modify: `Overview.qml` (`params`, `buildInput`, `applyTiles`, tile delegate)
- Modify: `WindowTile.qml` (`layer`, `fullscreen`, z)
- Test: `tests/ui/drag.qml`

- [ ] **Step 1: Write the failing UI tests**

Append inside `TestCase` in `tests/ui/drag.qml`:

```qml
    function tileOf(addr) {
        var children = view.testCanvas.children
        for (var i=0;i<children.length;i++)
            if (children[i].model && children[i].model.address === addr) return children[i]
        fail("Tile not found: " + addr)
    }
    // The floating window is the FIRST model entry, the tiled one is appended later (a later
    // sibling paints on top by default). Without a layer-based z the floating tile is hidden.
    function test_floating_tile_stacks_above_later_tiled_tile() {
        client.floating = true; view.rebuild()
        addTarget(1)                               // tiled, index 1
        var floating = tileOf("0x123"), tiled = tileOf("0x456")
        verify(floating.z > tiled.z, "floating z " + floating.z + " must exceed tiled z " + tiled.z)
        compare(view.testModel.get(0).layer, 2); compare(view.testModel.get(1).layer, 1)
    }
    // Hover raises a tile within its layer only: a hovered tiled tile stays below a floating one.
    function test_hovered_tiled_tile_stays_below_floating() {
        client.floating = true; view.rebuild()
        addTarget(1)
        var floating = tileOf("0x123"), tiled = tileOf("0x456")
        var away = tiled.mapToItem(tc, -30, -30), p = tiled.mapToItem(tc, tiled.width/2, tiled.height/2)
        mouseMove(tc, away.x, away.y, 20)
        mouseMove(tc, p.x, p.y, 20)
        tryVerify(function () { return tiled.z === 11 }, 500)          // hovered within layer 1
        verify(floating.z > tiled.z, "floating (20) above hovered tiled (11)")
        mouseMove(tc, away.x, away.y, 20)
        tryVerify(function () { return tiled.z === 10 }, 500)
    }
```

What these distinguish: the first fails today (both z are 0); the second fails against the old `hovered ? 10 : 0` rule (hovered tiled would be 10 > floating 0) and against a rule that forgot hover entirely (z never becomes 11). Note the hover needs a move from *outside* the tile into it — `HoverHandler` only reacts to an enter.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/ui/run.sh`
Expected: `FAIL! : Drag::test_floating_tile_stacks_above_later_tiled_tile()` ("floating z 0 must exceed tiled z 0") and the hover test failing at `tiled.z === 11`.

- [ ] **Step 3: Implement**

`Overview.qml`:

1. `params`: add `slotGapTolerance: 24`.
2. `buildInput`: `fullscreen: !!o.fullscreen` → `fullscreen: o.fullscreen === true ? 2 : (o.fullscreen | 0)`.
3. `applyTiles`: on append add `layer: t.layer, fullscreen: t.fullscreen, fsPending: false`; on update add `layer: tu.layer, fullscreen: tu.fullscreen` (never `fsPending` — Task 6 owns that role).
4. Tile delegate: add `tileLayer: model.layer` and `fullscreen: model.fullscreen` next to `cls: model.cls`.

`WindowTile.qml`: add properties after `dragging`:

```qml
    property int tileLayer: 1            // 0 backdrop | 1 tiled | 2 floating — stacking inside the cell
                                         // (not `layer`: Item owns a FINAL `layer` group property)
    property int fullscreen: 0           // Hyprland mode: 0 none, 1 maximized, 2 fullscreen
```
and replace the z line:
```qml
    // Hover raises a tile within its own layer only; dragging is the single global exception.
    z: dragging ? 99999 : tileLayer * 10 + (hh.hovered ? 1 : 0)
```

- [ ] **Step 4: Run to verify they pass**

Run: `mise run test`
Expected: both new `Drag::` tests PASS; `test_cancel_restores_drag_state` still passes (`t.z < 100` holds: 10 or 11).

- [ ] **Step 5: Live check**

Copy to the live plugin, restart the shell, SUPER+P: on workspace 8 the Teams tile is visible beside the Chrome tile (no badge yet). Drop a floating window onto a workspace with tiled windows: its tile stays on top.

- [ ] **Step 6: Commit**

```bash
git add Overview.qml WindowTile.qml tests/ui/drag.qml
git commit -m "feat(overview): fullscreen mode + stacking layer in the tiles model; floating tiles stack above tiled"
```

---

## Task 6: Fullscreen badge + optimistic un-fullscreen (Feature 2)

**Files:**
- Modify: `WindowTile.qml` (badge, hover-label prefix, signal)
- Modify: `Overview.qml` (`pendingFullscreen`, `unfullscreen`, `reconcileFullscreen`, delegate wiring)
- Test: `tests/ui/drag.qml`

- [ ] **Step 1: Write the failing UI tests**

Append to `tests/ui/drag.qml`:

```qml
    function badgeOf(addr) {
        var t = tileOf(addr), kids = t.children
        for (var i=0;i<kids.length;i++) if (kids[i].objectName === "fsBadge") return kids[i]
        fail("badge not found")
    }
    // The badge shows on a fullscreen tile; clicking it dispatches ONE guarded un-fullscreen
    // chunk, never a drag or a focus, hides the badge optimistically, and leaves no drag state.
    function test_badge_click_unfullscreens_without_drag_or_focus() {
        client.fullscreen = 2; view.rebuild()
        addTarget(1)
        var badge = badgeOf("0x123")
        verify(badge.visible, "badge shown while fullscreen")
        var p = badge.mapToItem(tc, badge.width/2, badge.height/2)
        mouseClick(tc, p.x, p.y, Qt.LeftButton)
        compare(view.compositor.commands.length, 1)
        var cmd = view.compositor.commands[0]
        verify(cmd.indexOf('hl.dsp.window.fullscreen(') >= 0)
        verify(cmd.indexOf('"address:0x123"') >= 0)
        verify(cmd.indexOf('hl.dsp.focus(') < 0 || cmd.indexOf('prevW') >= 0, "no user-visible focus change")
        verify(cmd.indexOf('window.float(') < 0, "not a drag")
        compare(view.draggingAddress, "", "a badge press never starts a drag")
        verify(view.pendingFullscreen["0x123"] !== undefined)
        verify(!badge.visible, "badge hidden while pending")
        view.rebuild()                                   // stale data: still fullscreen 2
        verify(!badge.visible, "stays hidden until confirmed")
        client.fullscreen = 0; view.rebuild()
        verify(view.pendingFullscreen["0x123"] === undefined, "confirmed by fresh data")
        verify(!badge.visible, "now hidden because the window is no longer fullscreen")
    }
    function test_badge_returns_when_unfullscreen_is_rejected() {
        client.fullscreen = 2; view.rebuild()
        var badge = badgeOf("0x123"), p = badge.mapToItem(tc, badge.width/2, badge.height/2)
        mouseClick(tc, p.x, p.y, Qt.LeftButton)
        verify(!badge.visible)
        view.pendingFullscreen["0x123"].deadline = Date.now() - 1
        view.rebuild()
        verify(view.pendingFullscreen["0x123"] === undefined)
        verify(badge.visible, "rejected: the window is still fullscreen, badge back")
    }
    // A plain click on the tile body still focuses + closes and does not touch fullscreen.
    function test_tile_body_click_on_fullscreen_tile_focuses_only() {
        client.fullscreen = 2; view.rebuild()
        var t = tileOf("0x123"), p = t.mapToItem(tc, 8, t.height - 8)     // bottom-left, away from the badge
        mouseClick(tc, p.x, p.y, Qt.LeftButton)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf('hl.dsp.focus(') >= 0)
        verify(view.compositor.commands[0].indexOf('fullscreen') < 0)
    }
```

What these distinguish: a badge without its own `z: 1` MouseArea (the drag area would swallow the press: `draggingAddress` set / a focus dispatch instead), a missing pending state (badge stays visible after the click), a reconcile that clears on stale data, and a missing deadline path.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/ui/run.sh`
Expected: all three fail at `badge not found`.

- [ ] **Step 3: Implement `WindowTile.qml`**

Add properties + signal after `fullscreen`:

```qml
    property bool fullscreenPending: false   // un-fullscreen dispatched; badge hidden until confirmed
    signal unfullscreenRequested()
```

Change the hover label text:
```qml
            text: (tile.fullscreen === 2 ? "Fullscreen · " : tile.fullscreen === 1 ? "Maximized · " : "")
                  + (tile.title.length ? tile.title : tile.cls)
```

Append at the end of the root `Item` (after the insertion-preview `Rectangle`, so `tests/ui/prepare.py`'s capture-block replacement leaves it intact):

```qml
    // fullscreen badge: a drawn four-corner glyph in the top-right corner while the window is
    // fullscreen/maximized. Its own MouseArea stacks above the drag area (z 1), so a badge
    // press never starts a drag and never counts as a tile click. Click → un-fullscreen.
    Rectangle {
        id: badge
        objectName: "fsBadge"
        visible: tile.fullscreen > 0 && !tile.fullscreenPending
        anchors { top: parent.top; right: parent.right; margins: 3 }
        width: 16; height: 16; radius: 4
        color: tile.bg
        border.width: 1; border.color: tile.borderColor
        z: 1
        Repeater {
            model: 4
            Item {
                required property int index
                readonly property bool onRight: index % 2 === 1
                readonly property bool onBottom: index >= 2
                x: onRight ? 9 : 3; y: onBottom ? 9 : 3; width: 4; height: 4
                Rectangle { width: 4; height: 1; color: tile.fg; y: parent.onBottom ? 3 : 0 }
                Rectangle { width: 1; height: 4; color: tile.fg; x: parent.onRight ? 3 : 0 }
            }
        }
        MouseArea {
            anchors.fill: parent
            onClicked: tile.unfullscreenRequested()
        }
    }
```

- [ ] **Step 4: Implement `Overview.qml`**

Next to `pendingMoves`:
```qml
    // addr -> { mode, deadline }: an un-fullscreen was dispatched; the badge stays hidden until
    // fresh data reports that mode, or the deadline passes (rejected: badge returns).
    property var pendingFullscreen: ({})
```

Helper + action (near `_movePosition`):
```qml
    function setTileRoles(addr, roles) {
        for (var i = 0; i < tilesModel.count; i++)
            if (tilesModel.get(i).address === addr) { tilesModel.set(i, roles); return }
    }
    // Badge click: turn fullscreen off for `addr` silently (no focus, no workspace switch, the
    // overview stays open). Optimistic: the badge hides now and the tile keeps its recovered
    // slot, which is where the window lands anyway.
    function unfullscreen(addr) {
        var win = _windowByAddress[addr]
        if (!win || !win.fullscreen) return
        pendingFullscreen[addr] = { mode: 0, deadline: Date.now() + 1800 }
        setTileRoles(addr, { fsPending: true })
        Hyprland.dispatch(Logic.unfullscreenLua(addr))
        scheduleRebuild()
        reconcileTimer.restart()
    }
    function reconcileFullscreen(windows) {
        var byAddress = {}
        for (var i = 0; i < windows.length; i++) byAddress[windows[i].address] = windows[i]
        for (var addr in pendingFullscreen) {
            var pending = pendingFullscreen[addr], win = byAddress[addr]
            if (win && win.fullscreen !== pending.mode && Date.now() < pending.deadline) continue
            delete pendingFullscreen[addr]
            setTileRoles(addr, { fsPending: false })
        }
    }
```

In `reconcileMoves`, change the final stop condition to:
```qml
        if (!Object.keys(pendingMoves).length && !Object.keys(pendingFullscreen).length) reconcileTimer.stop()
```
In `rebuild()`, right after `reconcileMoves(input.windows)`, add `reconcileFullscreen(input.windows)`.

Tile delegate: add
```qml
                            fullscreenPending: model.fsPending
                            onUnfullscreenRequested: root.unfullscreen(model.address)
```
In `dragArea.onPressed`, also `delete root.pendingFullscreen[model.address]` is **not** wanted (a drag of a pending tile should keep the badge hidden); leave it.

- [ ] **Step 5: Run to verify they pass**

Run: `mise run test`
Expected: the three badge tests PASS; everything else green.

- [ ] **Step 6: Live check**

Copy to the live plugin, restart the shell, SUPER+P: the Chrome tile on workspace 8 shows the corner badge; hovering shows "Fullscreen · <title>". Click the badge: the overview stays open, the badge disappears, and after closing the overview and going to workspace 8, Chrome is tiled next to Teams. (Re-fullscreen it with SUPER+F afterwards if you want to keep the live case around.)

- [ ] **Step 7: Commit**

```bash
git add WindowTile.qml Overview.qml tests/ui/drag.qml
git commit -m "feat(overview): fullscreen badge; click turns fullscreen off silently with optimistic hide"
```

---

## Task 7: Drops treat fullscreen windows as tiled peers (Feature 3)

**Files:**
- Modify: `logic.js` (`tiledInsertLua`)
- Modify: `Overview.qml` (`tiledAnchorCandidates`, `tiledDropPlan`, `startTiledInsert`, `submitDrop`, `updateDropTarget`, `reconcileMoves`)
- Test: `tests/tst_layout.qml`, `tests/ui/drag.qml`

- [ ] **Step 1: Write the failing logic test**

Append to `tests/tst_layout.qml`:

```js
    // The insert chunk strips fullscreen (target workspace's window + the dragged one) BEFORE
    // the float so the anchor is measured in its tiled slot, and re-applies it AFTER the
    // un-float: the workspace's window always, the dragged window only when it stays there.
    function test_tiled_insert_lua_strips_fullscreen_first_and_reapplies_last() {
        var lua = Logic.tiledInsertLua("0xabc", 3, { anchor: "0xdef", side: "left", x: 1, y: 2 })
        verify(lua.indexOf('\n') < 0)
        verify(lua.indexOf('hl.get_workspace("3")') >= 0, "reads the target workspace")
        verify(lua.indexOf('fullscreen_window') >= 0 && lua.indexOf('fullscreen_mode') >= 0, "records the workspace's fullscreen state")
        verify(lua.indexOf('ownMode') >= 0, "records the dragged window's own mode")
        var firstFs = lua.indexOf('hl.dsp.window.fullscreen('), firstFloat = lua.indexOf('window.float(')
        var lastFs = lua.lastIndexOf('hl.dsp.window.fullscreen('), lastFloat = lua.lastIndexOf('window.float(')
        verify(firstFs >= 0 && firstFs < firstFloat, "fullscreen stripped before the float")
        verify(lastFs > lastFloat, "fullscreen re-applied after the un-float")
        verify(lua.indexOf('same and w.fullscreen or 0') >= 0, "own mode only kept for a same-workspace re-tile")
        verify(lua.lastIndexOf('smart_split = smart') > lastFs, "config restored after everything")
        verify(lua.indexOf('local prevW = hl.get_active_window()') >= 0, "focus recorded up front")
        verify(lua.lastIndexOf('hl.dsp.focus(') > lua.lastIndexOf('smart_split = smart'), "focus restored (if moved) at the very end")
        verify(lua.lastIndexOf('cursor.move(') > lua.lastIndexOf('hl.dsp.focus('), "cursor restored after the re-focus")
    }
```

What it distinguishes: a chunk that re-applies but never strips (anchor measured as the fullscreen rect), one that strips but never re-applies, or one that re-applies the dragged window's mode across workspaces.

- [ ] **Step 2: Run to verify it fails**

Run: `mise run test`
Expected: `FAIL! : Layout::test_tiled_insert_lua_strips_fullscreen_first_and_reapplies_last()` at "reads the target workspace".

- [ ] **Step 3: Implement `tiledInsertLua`**

Replace the function body's Lua so it reads (only the marked lines are new; keep everything else exactly as it is):

```js
function tiledInsertLua(addr, targetWs, placement) {
    var ws = String(parseInt(targetWs, 10))
    var gx = Math.round(placement.x), gy = Math.round(placement.y)
    var side = { left: 1, right: 1, top: 1, bottom: 1 }[placement.side] ? placement.side : ""
    var anchorSel = placement.anchor ? '"address:' + placement.anchor + '"' : 'nil'
    return (
        'function()\n' +
        '  local sel = "address:' + addr + '"\n' +
        '  local w = hl.get_window(sel)\n' +
        '  if not w or w.floating then return end\n' +
        '  local anchorSel = ' + anchorSel + '\n' +
        '  local cur = hl.get_cursor_pos()\n' +
        '  local smart = hl.get_config("dwindle.smart_split")\n' +
        '  local useActive = hl.get_config("dwindle.use_active_for_splits")\n' +
        '  local aws = hl.get_active_workspace()\n' +
        '  local onActive = aws ~= nil and aws.id == ' + ws + '\n' +
        // NEW: fullscreen bookkeeping. The target workspace's fullscreen window is stripped so
        // every window there (the anchor included) is measured in its tiled slot, and re-applied
        // afterwards; the dragged window's own mode is kept only for a same-workspace re-tile.
        '  local tws = hl.get_workspace("' + ws + '")\n' +
        '  local fsWin = tws and tws.fullscreen_window or nil\n' +
        '  local fa = fsWin and tostring(fsWin.address or "") or ""\n' +                 // Lua addresses may lack 0x
        '  if fa ~= "" and fa:sub(1, 2) ~= "0x" then fa = "0x" .. fa end\n' +
        '  local fsSel = fa ~= "" and ("address:" .. fa) or nil\n' +
        '  local fsMode = fsWin and tws.fullscreen_mode or 0\n' +
        '  local same = w.workspace ~= nil and w.workspace.id == ' + ws + '\n' +
        '  local ownMode = same and w.fullscreen or 0\n' +
        '  hl.config({ dwindle = { smart_split = true, use_active_for_splits = not onActive } })\n' +
        '  pcall(function()\n' +
        '    if fsSel then ' + fullscreenBodyLua('fsSel', '0') + ' end\n' +          // NEW
        '    ' + fullscreenBodyLua('sel', '0') + '\n' +                              // NEW
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
        '    hl.dispatch(hl.dsp.window.float({ window = sel, action = "toggle" }))\n' +
        '    if fsSel and fsSel ~= sel then ' + fullscreenBodyLua('fsSel', 'fsMode') + ' end\n' +   // NEW
        '    if ownMode ~= 0 then ' + fullscreenBodyLua('sel', 'ownMode') + ' end\n' +              // NEW
        '  end)\n' +
        '  hl.config({ dwindle = { smart_split = smart, use_active_for_splits = useActive } })\n' +
        '  ' + restoreFocusLua('prevW', 'cur') + '\n' +                                     // REPLACES the old cursor-only restore
        'end'
    ).replace(/\n\s*/g, ' ')
}
```
Also add `'  local prevW = hl.get_active_window()\n' +` right after the `local cur = hl.get_cursor_pos()` line. `restoreFocusLua` (Task 2) re-focuses the previous window only if the active window changed, then moves the cursor back — the fullscreen strip/re-apply can drop focus (probe result), and focusing warps the cursor, so focus is restored before the cursor.
(The `if w.workspace == nil or w.workspace.id ~= ws` test became `if not same` — same meaning, one variable.) Property: `ownMode`/`fsMode` are read **before** any state changes; `fw` inside `fullscreenBodyLua` is re-read at each use, so the re-apply sees the post-insert state.

- [ ] **Step 4: Run to verify the logic test passes**

Run: `mise run test`
Expected: `test_tiled_insert_lua_strips_fullscreen_first_and_reapplies_last` PASS and `test_tiled_insert_lua_replays_native_drop` still PASS (its step-order assertions use the first `window.float(`, which is still before `window.move(`).

- [ ] **Step 5: Write the failing UI tests**

Append to `tests/ui/drag.qml`:

```qml
    // A fullscreen window can be re-tiled inside its own workspace (previously refused): one
    // atomic insert that records and re-applies fullscreen, acknowledged as soon as the ANCHOR's
    // geometry changes — the window itself ends fullscreen in the same rect, so its own
    // geometry cannot be the signal.
    function test_fullscreen_window_retile_acknowledged_by_anchor_geometry() {
        client.fullscreen = 2; view.rebuild()
        var other = addTarget(1)
        dragOntoTarget(1)
        compare(view.compositor.commands.length, 1, "re-tile dispatched (was refused before)")
        var cmd = view.compositor.commands[0]
        verify(cmd.indexOf('ownMode') >= 0 && cmd.indexOf('hl.dsp.window.fullscreen(') >= 0)
        var pending = view.pendingMoves[client.address]
        verify(pending !== undefined && pending.before.anchor.address === "0x456")
        view.rebuild()                                     // nothing changed yet
        verify(view.pendingMoves[client.address] !== undefined, "still pending on stale data")
        other.at = [1000, 1740]; other.size = [600, 200]   // the anchor got split
        view.rebuild()
        verify(view.pendingMoves[client.address] === undefined, "anchor change acknowledges")
    }
    function test_retile_pending_kept_until_deadline_when_nothing_changes() {
        client.fullscreen = 2; view.rebuild()
        addTarget(1); dragOntoTarget(1)
        view.rebuild(); view.rebuild()
        verify(view.pendingMoves[client.address] !== undefined)
        view.pendingMoves[client.address].deadline = Date.now() - 1
        view.rebuild()
        verify(view.pendingMoves[client.address] === undefined)
    }
    // A fullscreen tile is an ordinary anchor: a tiled window dropped on it previews a side and
    // dispatches the insert (previously the fullscreen tile was excluded from the candidates).
    function test_fullscreen_tile_is_an_anchor() {
        var other = addTarget(1); other.fullscreen = 2; view.rebuild()
        var source = view.testModel.get(0), target = view.testModel.get(1)
        var t = tile(), p = t.mapToItem(tc, t.width/2, t.height/2)
        mousePress(tc, p.x, p.y, Qt.LeftButton)
        mouseMove(tc, p.x+12, p.y+2, 20)
        var goal = view.testCanvas.mapToItem(tc, target.wx + target.ww*0.9, target.wy + target.wh/2)
        mouseMove(tc, goal.x, goal.y, 20)
        compare(view.dropTargetAddress, "0x456", "fullscreen tile previews as an anchor")
        compare(view.dropTargetSide, "right")
        mouseRelease(tc, goal.x, goal.y, Qt.LeftButton)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf('"address:0x456"') >= 0)
    }
    // Same-workspace eligibility uses the tile's model rect (the recovered slot), not
    // _tileRect(win) — which for a fullscreen window is the whole cell and would swallow every
    // drop as "inside its own slot".
    function test_fullscreen_window_own_slot_is_the_recovered_slot() {
        client.fullscreen = 2; view.rebuild()
        var other = addTarget(1)
        var own = view.tileRectFor("0x123"), target = view.testModel.get(1)
        verify(own.h < view.boxes[0].h - 2 * view.params.cellInset - 1, "recovered slot, not the whole cell")
        var plan = view.tiledDropPlan("0x123", view._windowByAddress["0x123"], 1,
                                      target.wx + target.ww/2, target.wy + target.wh/2)
        verify(plan !== null && plan.anchor === "0x456")
    }
```

What these distinguish: the first two fail today with `commands.length 0` (fullscreen refused) and would fail against an ack rule that only looks at the dragged window; the third fails while `tiledAnchorCandidates` excludes fullscreen; the fourth fails while `tiledDropPlan` builds `own` from `_tileRect(win)`.

- [ ] **Step 6: Run to verify they fail**

Run: `bash tests/ui/run.sh`
Expected: the four new tests fail as described.

- [ ] **Step 7: Implement `Overview.qml`**

`tiledAnchorCandidates`: replace the skip condition with
```qml
            if (tile.address === addr || tile.wsid !== workspaceId || !win ||
                win.floating || tile.layer === 0 || pendingMoves[tile.address]) continue
```
(fullscreen tiles anchor; a backdrop tile — no recoverable slot — does not.)

`tiledDropPlan`: replace `var own = same ? Logic._tileRect(win, mon, box, params) : null` with
```qml
        var own = same ? tileRectFor(addr) : null       // the model rect: the recovered slot for a fullscreen window
```

`startTiledInsert`: extend the pending record:
```qml
        var anchorWin = plan.anchor ? _windowByAddress[plan.anchor] : null
        pendingMoves[addr] = { workspaceId: targetWs, pos: null, deadline: Date.now() + 1800,
                               before: { ws: win.workspaceId, ax: win.ax, ay: win.ay, sw: win.sw, sh: win.sh,
                                         anchor: anchorWin ? { address: plan.anchor, ax: anchorWin.ax, ay: anchorWin.ay,
                                                               sw: anchorWin.sw, sh: anchorWin.sh } : null } }
```

`submitDrop`: `if (!win.floating && !win.fullscreen && !win.grouped && tile)` → `if (!win.floating && !win.grouped && tile)`; the comment on the snap-back line becomes `// grouped tiled: snap back in place`.

`updateDropTarget`: `var tiledDrag = win && !win.floating && !win.grouped && ws !== null`.

`reconcileMoves`, the `if (pending.before)` block:
```qml
            if (pending.before) {
                // A re-tile is acknowledged once the dragged window's workspace or geometry
                // differs from the pre-drop record, OR the anchor's geometry does: every insert
                // splits the anchor, and a fullscreen window re-tiled in place ends up
                // reporting the same fullscreen rect it started with.
                var b = pending.before, a = b.anchor, aw = a ? byAddress[a.address] : null
                var ownSame = b.ws === win.workspaceId && b.ax === win.ax && b.ay === win.ay &&
                              b.sw === win.sw && b.sh === win.sh
                var anchorSame = !a || !!(aw && aw.ax === a.ax && aw.ay === a.ay && aw.sw === a.sw && aw.sh === a.sh)
                                  // a vanished anchor acknowledges: the insert is moot
                if (ownSame && anchorSame) continue
                delete pendingMoves[addr]
                continue
            }
```

- [ ] **Step 8: Run to verify everything passes**

Run: `mise run test`
Expected: all `Layout::` and `Drag::` tests PASS, including the pre-existing `test_tiled_drop_replays_native_insert_in_one_dispatch` (its ack comes from the dragged window's geometry change, still honoured) and `test_grouped_tiled_window_is_not_retiled`.

- [ ] **Step 9: Commit**

```bash
git add logic.js Overview.qml tests/tst_layout.qml tests/ui/drag.qml
git commit -m "feat(overview): fullscreen windows are tiled peers for drops; insert chunk strips/re-applies fullscreen; anchor-based ack"
```

---

## Task 8: Integration on the nested Hyprland (spec Tier 2, cases a–d)

**Files:**
- Modify: `tests/integration/drag.qml` (IPC: `unfullscreen`, `pendingFullscreen`)
- Create: `tests/integration/fullscreen.sh`
- Modify: `tests/integration/move.sh` (run both scripts)

- [ ] **Step 1: Extend the IPC shell**

In `tests/integration/drag.qml`'s `IpcHandler` add:
```qml
        function unfullscreen(address: string): void { overview.rebuild(); overview.unfullscreen(address) }
        function pendingFullscreen(): string { return JSON.stringify(overview.pendingFullscreen) }
```

- [ ] **Step 2: Write `tests/integration/fullscreen.sh`**

Gaps are set to 0 in this rig so slot arithmetic is exact (unit tests cover gaps). `fs_on` uses the dispatcher form Task 1 verified; if Task 1 said `FALLBACK`, replace its body with the three-line focus/toggle/focus-back sequence (the *test* may switch focus; production code does it inside one chunk).

```bash
#!/usr/bin/env bash
# Fullscreen interplay on a disposable Lua Hyprland: badge un-fullscreen, drops onto a fullscreen
# anchor, in-place re-tile of a fullscreen window, cross-workspace drag of one.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_bins
start_nested 'hl.config({ general = { gaps_in = 0, gaps_out = 0 } })'
fs_on() { hc dispatch "hl.dsp.window.fullscreen({window='address:$1', mode='fullscreen', action='toggle'})" >/dev/null; sleep 0.3; }
wait_fs() {   # $1 addr, $2 mode: wait until the client reports that mode
    for _ in $(seq 1 40); do [[ "$(fsmode "$1")" == "$2" ]] && return; sleep 0.1; done
    echo "FAIL: $1 did not reach fullscreen mode $2"; dump; exit 1
}
usable() { hc monitors -j | jq -r '.[0] | "\(.x + .reserved[0]) \(.y + .reserved[1]) \(.width - .reserved[0] - .reserved[2]) \(.height - .reserved[1] - .reserved[3])"'; }

hc dispatch 'hl.dsp.focus({workspace="1"})' >/dev/null
a=$(spawn_window); b=$(spawn_window); sleep 0.4
hc dispatch 'hl.dsp.focus({workspace="3"})' >/dev/null
t1=$(spawn_window); t2=$(spawn_window); sleep 0.4
hc dispatch 'hl.dsp.focus({workspace="1"})' >/dev/null
hc dispatch "hl.dsp.focus({window='address:$a'})" >/dev/null; sleep 0.2
start_quickshell
ipc openOverview

# (a) badge: un-fullscreen b silently; b returns to the slot it had before.
before_b=$(geometry "$b")
fs_on "$b"; wait_fs "$b" 2
cursor=$(hc cursorpos -j | jq -c .)
ipc unfullscreen "$b"
wait_fs "$b" 0
for _ in $(seq 1 40); do [[ "$(ipc pendingFullscreen)" == '{}' ]] && break; sleep 0.1; done
[[ "$(ipc pendingFullscreen)" == '{}' ]] || { echo 'FAIL: un-fullscreen not acknowledged'; dump; exit 1; }
[[ "$(geometry "$b")" == "$before_b" ]] || { echo "FAIL: b did not return to its slot"; dump; exit 1; }
[[ "$(hc activeworkspace -j | jq .id)" == 1 ]] || { echo 'FAIL: active workspace changed'; exit 1; }
[[ "$(hc activewindow -j | jq -r .address)" == "$a" ]] || { echo 'FAIL: focus changed'; exit 1; }
[[ "$(hc cursorpos -j | jq -c .)" == "$cursor" ]] || { echo 'FAIL: cursor moved'; exit 1; }
echo 'PASS: badge un-fullscreen is silent and lands in the old slot'

# (b) drops onto each side of a FULLSCREEN anchor on hidden workspace 3. t1 keeps its slot; t2's
# slot is the complement. After each drop: a is on that side inside the slot, t2 is fullscreen
# again, active workspace/cursor untouched. Then a goes back to workspace 1.
read -r ux uy uw uh < <(usable)
fs_on "$t2"; wait_fs "$t2" 2
read -r x1 y1 w1 h1 _ < <(box "$t1")
if [[ "$w1" -lt "$uw" ]]; then sx=$(( x1 == ux ? x1 + w1 : ux )); sy=$uy; sw=$(( uw - w1 )); sh=$uh
else sx=$ux; sy=$(( y1 == uy ? y1 + h1 : uy )); sw=$uw; sh=$(( uh - h1 )); fi
midx=$(( sx + sw / 2 )); midy=$(( sy + sh / 2 ))
drop_side() {   # $1 side, $2 gx, $3 gy, $4 jq predicate over {x,y,w,h} of `a` given $sx.. as args
    local cursor; cursor=$(hc cursorpos -j | jq -c .)
    ipc dropPoint "$a" 3 "$2" "$3"
    wait_pending
    read -r ax ay aw ah aws < <(box "$a")
    [[ "$aws" == 3 ]] || { echo "FAIL($1): a not on workspace 3"; dump; exit 1; }
    jq -ne --argjson x "$ax" --argjson y "$ay" --argjson w "$aw" --argjson h "$ah" \
        --argjson sx "$sx" --argjson sy "$sy" --argjson sw "$sw" --argjson sh "$sh" "$4" >/dev/null || {
        echo "FAIL($1): a not on the $1 side of the fullscreen anchor's slot"; dump; exit 1; }
    [[ "$(fsmode "$t2")" == 2 ]] || { echo "FAIL($1): anchor lost fullscreen"; dump; exit 1; }
    [[ "$(hc activeworkspace -j | jq .id)" == 1 && "$(hc cursorpos -j | jq -c .)" == "$cursor" ]] || { echo "FAIL($1): active/cursor changed"; exit 1; }
    hc dispatch "hl.dsp.window.move({workspace='1', follow=false, window='address:$a'})" >/dev/null; sleep 0.3
    echo "PASS: drop on the $1 side of a fullscreen anchor lands there; anchor stays fullscreen"
}
drop_side left   $(( sx + 8 ))        "$midy" '$x == $sx and ($x + $w) <= ($sx + $sw / 2 + 1) and $h == $sh'
drop_side right  $(( sx + sw - 8 ))   "$midy" '($x + $w) == ($sx + $sw) and $x >= ($sx + $sw / 2 - 1) and $h == $sh'
drop_side top    "$midx" $(( sy + 8 ))        '$y == $sy and ($y + $h) <= ($sy + $sh / 2 + 1) and $w == $sw'
drop_side bottom "$midx" $(( sy + sh - 8 ))   '($y + $h) == ($sy + $sh) and $y >= ($sy + $sh / 2 - 1) and $w == $sw'

# (c) re-tile the FULLSCREEN window t2 in its own workspace onto t1's left edge: still
# fullscreen afterwards, acknowledged promptly (well inside the 1.8 s deadline), and once
# un-fullscreened it sits left of t1.
read -r x1 y1 w1 h1 _ < <(box "$t1")
ipc dropPoint "$t2" 3 $(( x1 + 8 )) $(( y1 + h1 / 2 ))
ticks=0
while [[ "$(ipc pending)" != '{}' ]]; do ticks=$((ticks + 1)); (( ticks <= 12 )) || { echo 'FAIL: re-tile ack took the deadline path'; dump; exit 1; }; sleep 0.1; done
[[ "$(fsmode "$t2")" == 2 ]] || { echo 'FAIL: t2 not fullscreen after in-place re-tile'; dump; exit 1; }
ipc unfullscreen "$t2"; wait_fs "$t2" 0
read -r x2 y2 w2 h2 _ < <(box "$t2"); read -r x1 y1 w1 h1 _ < <(box "$t1")
[[ "$y2" == "$y1" && "$h2" == "$h1" && $((x2 + w2)) -le "$x1" ]] || { echo 'FAIL: t2 not left of t1'; dump; exit 1; }
echo 'PASS: fullscreen window re-tiled in place keeps fullscreen; acknowledged promptly'

# (d) a fullscreen window dragged to another workspace arrives tiled (not fullscreen).
fs_on "$t2"; wait_fs "$t2" 2
read -r xa ya wa ha _ < <(box "$a")
ipc dropPoint "$t2" 1 $(( xa + wa - 8 )) $(( ya + ha / 2 ))
wait_pending
# `a` is split by the insert, so compare against its POST-drop geometry, not the one above.
read -r x2 y2 w2 h2 ws2 < <(box "$t2"); read -r xa ya wa ha _ < <(box "$a")
[[ "$ws2" == 1 && "$(fsmode "$t2")" == 0 && "$y2" == "$ya" && "$h2" == "$ha" && "$x2" -ge $((xa + wa - 1)) ]] || { echo 'FAIL: t2 did not arrive tiled right of a'; dump; exit 1; }
echo 'PASS: fullscreen window dragged across workspaces arrives tiled'

[[ "$(hc getoption dwindle:smart_split | head -1 | tr -d ' ')" == "bool:false" ]] || { echo "FAIL: smart_split not restored"; exit 1; }
[[ "$(hc getoption dwindle:use_active_for_splits | head -1 | tr -d ' ')" == "bool:true" ]] || { echo "FAIL: use_active_for_splits not restored"; exit 1; }
if rg -i 'TypeError|ReferenceError|Error loading|Failed to load|Invalid dispatcher' "$tmp/qs.log"; then exit 1; fi
```

Note on (b)'s `$x == $sx` checks: after `a` is re-tiled *left* of the anchor inside the slot, dwindle gives each half of the slot; the anchor `t2` is re-fullscreened so its own geometry is useless — the assertions are therefore on `a` relative to the slot, which is what the spec's "highlighted side is the side the compositor uses" means here.

What each case distinguishes: (a) the dispatcher form (a fallback that forgets to restore focus fails the `activewindow` check); (b) measuring the anchor before stripping (a would land relative to the fullscreen rect, failing the `$sx` bound) and a missing re-apply; (c) an ack that ignores the anchor (would take > 12 ticks) and a missing `ownMode` re-apply; (d) re-applying the dragged window's mode across workspaces.

- [ ] **Step 3: Chain it from `move.sh`**

```bash
#!/usr/bin/env bash
# Retain the established entry point; exercise production typed dispatch in Lua mode.
set -euo pipefail
bash "$(dirname "$0")/drag.sh"
bash "$(dirname "$0")/fullscreen.sh"
```

- [ ] **Step 4: Run**

Run: `mise run test-integration`
Expected: `drag.sh`'s eight `PASS:` lines, then from `fullscreen.sh`:
```
PASS: badge un-fullscreen is silent and lands in the old slot
PASS: drop on the left side of a fullscreen anchor lands there; anchor stays fullscreen
PASS: drop on the right side of a fullscreen anchor lands there; anchor stays fullscreen
PASS: drop on the top side of a fullscreen anchor lands there; anchor stays fullscreen
PASS: drop on the bottom side of a fullscreen anchor lands there; anchor stays fullscreen
PASS: fullscreen window re-tiled in place keeps fullscreen; acknowledged promptly
PASS: fullscreen window dragged across workspaces arrives tiled
```
If (b) fails on `$x == $sx` while `fsmode` is right, print `hc clients -j` inside the chunk's window: the likely cause is `fsWin.address` lacking the `0x` prefix (then `fsSel` never matches and the strip is skipped) — fix `fsSel` to `"address:" .. (fsWin.address:sub(1,2) == "0x" and fsWin.address or ("0x" .. fsWin.address))` in `tiledInsertLua`, mirror it in the spec's "Risks" list, and re-run. If `hl.get_workspace("3")` returns nil, try `hl.get_workspace(3)` (integer selector) — same treatment.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/drag.qml tests/integration/fullscreen.sh tests/integration/move.sh logic.js docs/specs/2026-09-10-window-states-design.md
git commit -m "test(integration): fullscreen badge, fullscreen anchors on all four sides, in-place re-tile, cross-workspace drag"
```

---

## Task 9: Docs

**Files:**
- Modify: `DESIGN.md` (append a section), `README.md` (Features, key table, drag paragraph), `ROADMAP.md` (status line)

- [ ] **Step 1: `DESIGN.md`** — append:

```markdown
## Window states: fullscreen and floating (2026-09-10)

Spec: `docs/specs/2026-09-10-window-states-design.md`; plan: `docs/plans/2026-09-10-window-states.md`.

- **Fullscreen windows are drawn in their tiled slot, not filling the cell.** Hyprland publishes
  only the fullscreen rect for such a window, but the other tiled windows on the workspace keep
  their geometry (fullscreen hides them without moving them), so `Logic.recoverSlot` derives the
  slot from what they leave uncovered: grid the usable rect on every window edge, seed on the
  uncovered cell with the largest minimum side (a gap strip can never win that), grow while whole
  neighbouring columns/rows are uncovered, trim outer strips thinner than `slotGapTolerance`.
  A lone fullscreen window still fills the cell; an ambiguous result draws as a backdrop below
  the tiled tiles; a floating fullscreen window is centred at 60 %. Both modes (2 fullscreen,
  1 maximized) are treated alike; `layout()` tiles carry `layer` (0 backdrop / 1 tiled /
  2 floating) and `fullscreen` (the mode).
- **Badge.** A drawn corner glyph marks fullscreen/maximized tiles (hover label prefixed
  "Fullscreen ·"/"Maximized ·"). Its own `MouseArea` sits above the drag area, so a click never
  drags; it dispatches `Logic.unfullscreenLua` — one guarded chunk that re-reads the window and
  toggles only if it is still fullscreen — with no focus change and the overview open. The badge
  hides optimistically (`pendingFullscreen`) until fresh data confirms or the 1.8 s deadline
  returns it.
- **Drops.** Fullscreen windows are ordinary tiled peers. `tiledInsertLua` strips the target
  workspace's fullscreen window and the dragged window's mode *before* the float (so the anchor
  is measured in its tiled slot) and re-applies them after the un-float — the dragged window's
  own mode only for a same-workspace re-tile; cross-workspace it arrives tiled. A re-tile is
  acknowledged when the dragged window's workspace/geometry **or the anchor's geometry** changed,
  since an in-place re-tile of a fullscreen window ends in the same fullscreen rect.
- **Stacking.** Tile z is `layer * 10 + hover`, dragging excepted: floating tiles always paint
  above tiled ones, and a hovered tiled tile never covers a floating one.
```

- [ ] **Step 2: `README.md`**

In **Features**, after the drag-and-drop bullet add:
```markdown
- **Fullscreen-aware.** A workspace with a fullscreen window still shows every window in its real
  tiled slot; the fullscreen one carries a small corner badge. Click the badge to un-fullscreen it
  without leaving the overview. Floating windows always show on top of tiled ones.
```
In the key table add a row:
```markdown
| **Click the ⛶ badge**    | Turn fullscreen off for that window (overview stays open)  |
```
In the "Drag regression checks" paragraph replace `Grouped and fullscreen windows are not re-tiled.` with `Grouped windows are not re-tiled; fullscreen windows are treated as tiled (the workspace's fullscreen state is restored after a drop, and a fullscreen window dragged to another workspace arrives tiled).` and add a sentence: `mise run test-integration also runs tests/integration/fullscreen.sh (badge, fullscreen anchors, in-place re-tile).`

- [ ] **Step 3: `ROADMAP.md`** — in the Status paragraph append: `Window states (2026-09-10): fullscreen windows drawn in their recovered slot with an un-fullscreen badge; floating tiles stack above tiled.`

- [ ] **Step 4: Validate and commit**

Run: `omarchy plugin validate .` → OK; `mise run test` → green.
```bash
git add DESIGN.md README.md ROADMAP.md
git commit -m "docs: window states — fullscreen recovered slot, badge, drop interplay, floating stacking"
```

---

## Self-review notes (done while writing)

- **Spec coverage:** Feature 1 → Tasks 3–4; Feature 2 → Tasks 2, 6, 8(a); Feature 3 → Tasks 7, 8(b–d); Feature 4 → Task 5; Testing section → Tasks 3–8; "Dispatching fullscreen" verification → Task 1; docs → Task 9.
- **Type consistency:** (WindowTile's property is `tileLayer`; the model role is `layer`.) `recoverSlot(R, others, P)`, `fullscreenBodyLua(sel, modeExpr)`, `unfullscreenLua(addr)`, `fullscreenMode(win)`, `_tileRect(win, mon, box, P, slot)`; model roles `layer`, `fullscreen`, `fsPending`; Overview `pendingFullscreen`, `unfullscreen(addr)`, `setTileRoles(addr, roles)`, `reconcileFullscreen(windows)`; WindowTile `layer`, `fullscreen`, `fullscreenPending`, `unfullscreenRequested()`, badge `objectName: "fsBadge"`; IPC `unfullscreen`, `pendingFullscreen`.
- **Would-it-fail:** every UI test asserts against production behaviour that the pre-change code lacks (z 0 vs layer z; refused fullscreen drops; no badge). `test_badge_returns_when_unfullscreen_is_rejected` mutates the deadline the code set, not a value the test supplied. `test_recover_slot_outer_gap_above_tolerance_never_spans_whole_rect` is the one that fails for the *rejected* algorithm specifically.
- **Spec conflicts:** the spec's `recoverSlot(R, others, P)` signature and trim rule match Task 3; Task 1 Step 4 updates the spec's "unverified" sentence; Task 8 Step 4 tells the implementer to mirror any address-prefix fix into the spec.
