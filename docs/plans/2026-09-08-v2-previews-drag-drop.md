# Omascape v2 — Live Previews + Drag-and-Drop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Omascape's icon mini-map with live window thumbnails and add drag-and-drop of windows between workspaces, matching end-4's overview while keeping per-monitor rows.

**Architecture:** A single non-clipped canvas carries two sibling layers — workspace boxes (drop targets) and absolutely-positioned window tiles. All coordinate math, ordering, clipping, and the reconcile diff live in a dependency-free `logic.js` (pure functions, unit-tested offscreen). `Overview.qml` wires Quickshell singletons to that logic and renders; `WindowTile.qml` is one preview tile (a `ScreencopyView` with icon fallback). Drag-drop dispatches a silent Hyprland move and reconciles against refreshed geometry.

**Tech Stack:** QML / Qt Quick, Quickshell 0.3.1 (`Quickshell.Hyprland`, `Quickshell.Wayland` `ScreencopyView` + `ToplevelManager`), Hyprland 0.56.2 typed dispatch (`hl.dsp.*`). Tests: `qmltestrunner` + `QtTest` under `QT_QPA_PLATFORM=offscreen`; Tier 2 headless Hyprland + `foot`/`hyprctl`.

**Spec:** `docs/specs/2026-09-08-omascape-previews-drag-drop-design.md` (read it first).

---

## Conventions used by every task

**Branch:** all work lands on `v2-previews-drag-drop` (already created; Task 1 ensures you're on it).

**Live-test loop (QML tasks).** The running shell loads the *installed* clone, not this
repo. To see a change live, copy the changed files over and restart the shell — a plain
rescan does **not** reload QML:

```bash
LIVE="$HOME/.config/omarchy/plugins/se.mindfulstack.omascape"
cp logic.js WindowTile.qml Overview.qml "$LIVE"/ 2>/dev/null; omarchy restart shell
```

Then press **SUPER+P** to open the overview and observe. (Copy only files that exist yet.)

**Unit-test loop (logic tasks).** No compositor needed — via mise (tasks defined in
`mise.toml`, Task 1):

```bash
mise run test        # = QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/
```

**Layout params used in all logic tests** (a shared fixture — see Task 2, `params`):
`{ cellW:160, cellH:100, cellInset:6, cellSpacing:8, rowSpacing:12, rowLabelH:16, minTileW:8, minTileH:6 }`.
Derived constants the tests reuse: mini-map `mmW = 160−12 = 148`, `mmH = 100−12 = 88`.

---

## Task 1: Feature branch + unit-test harness (shared infrastructure — highest stakes)

Everything downstream asserts through this harness. It must genuinely surface a failing
test, or every later "expected: FAIL" is worthless.

**Files:**
- Create: `tests/tst_smoke.qml`
- Create: `tests/run.sh` (executable — resolves the Qt6 qmltestrunner; PATH may shadow it with Qt5)
- Create: `mise.toml`

- [ ] **Step 1: Be on the feature branch**

The branch already exists (this plan and the spec were committed on it). Ensure you're on it:

```bash
cd ~/Source/omascape
git checkout v2-previews-drag-drop 2>/dev/null || git checkout -b v2-previews-drag-drop
```

- [ ] **Step 2: Write a smoke test**

`tests/tst_smoke.qml`:

```qml
import QtQuick
import QtTest

TestCase {
    name: "Smoke"
    function test_runner_reports_pass() { compare(1 + 1, 2, "arithmetic") }
}
```

- [ ] **Step 3: Add the `test` task + Qt6 runner resolver**

`tests/run.sh` (PATH's `qmltestrunner` may be Qt5, which silently exits 1 on Qt6 imports):

```bash
#!/usr/bin/env bash
set -euo pipefail
if command -v qmltestrunner6 >/dev/null 2>&1; then
  RUNNER=qmltestrunner6                          # Debian/Ubuntu (qt6-declarative-dev-tools)
elif [ -x /usr/lib/qt6/bin/qmltestrunner ]; then
  RUNNER=/usr/lib/qt6/bin/qmltestrunner          # Arch (qt6-declarative), upstream layout
else
  echo "No Qt6 qmltestrunner found (tried: qmltestrunner6, /usr/lib/qt6/bin/qmltestrunner)." >&2
  echo "Install qt6-declarative (Arch) or qt6-declarative-dev-tools (Debian/Ubuntu)." >&2
  exit 127
fi
exec env QT_QPA_PLATFORM=offscreen "$RUNNER" -input "$(dirname "$0")"
```

`chmod +x tests/run.sh`, then `mise.toml`:

```toml
[tasks.test]
description = "Tier 1: pure-logic unit tests, no compositor"
run = "bash tests/run.sh"
```

- [ ] **Step 4: Run it — expect PASS**

Run: `mise run test`
Expected: PASS, `Totals: 1 passed, 0 failed`.
**Distinguishes:** that `qmltestrunner`, the `QtTest` QML module, and the `offscreen` QPA
plugin are all present and wired — i.e. the toolchain itself works.

- [ ] **Step 5: Prove the harness surfaces RED**

Temporarily change the assertion to `compare(1 + 1, 3, "arithmetic")`, run `mise run test`.
Expected: FAIL, `1 failed`, message names `arithmetic` and shows `Actual 2 / Expected 3`.
**Distinguishes:** a harness that always passes. A green-only harness makes every later
TDD "fails first" step a lie. Then revert to `2` and re-run → PASS.

- [ ] **Step 6: Commit**

```bash
git add tests/tst_smoke.qml tests/run.sh mise.toml
git commit -m "test: offscreen qmltestrunner harness + mise test task"
```

---

## Task 2: `logic.js` — `layout()` boxes + canvas size

Pure. Rows grouped by monitor, focused monitor first then by `x`; workspaces `id>=0` sorted
by id; boxes placed left-to-right; canvas sized to the widest row and total height.

**Files:**
- Create: `logic.js`
- Create: `tests/tst_layout.qml`

- [ ] **Step 1: Write failing tests for boxes + ordering + canvas size**

`tests/tst_layout.qml`:

```qml
import QtQuick
import QtTest
import "../logic.js" as Logic

TestCase {
    name: "Layout"

    readonly property var params: ({
        cellW: 160, cellH: 100, cellInset: 6, cellSpacing: 8,
        rowSpacing: 12, rowLabelH: 16, minTileW: 8, minTileH: 6
    })

    // eDP-1: 2560x1600 @1.25 => 2048x1280 logical; 26px top bar reserved.
    function edp() {
        return { name: "eDP-1", x: 0, y: 0, width: 2560, height: 1600,
                 scale: 1.25, reserved: [0, 26, 0, 0], transform: 0 }
    }

    function boxById(res, id) {
        for (var i = 0; i < res.boxes.length; i++)
            if (res.boxes[i].workspaceId === id) return res.boxes[i]
        return null
    }

    function test_single_monitor_boxes_and_canvas() {
        var input = {
            monitors: [edp()],
            workspaces: [
                { id: 1, monitorName: "eDP-1", focused: true,  occupied: true },
                { id: 2, monitorName: "eDP-1", focused: false, occupied: false },
                { id: 3, monitorName: "eDP-1", focused: false, occupied: true }
            ],
            windows: [],
            focusedMonitorName: "eDP-1",
            params: params
        }
        var r = Logic.layout(input)
        compare(r.boxes.length, 3, "three boxes")
        var b1 = boxById(r, 1), b2 = boxById(r, 2), b3 = boxById(r, 3)
        // cells start below the row label: y = rowLabelH
        compare(b1.x, 0);   compare(b1.y, 16)
        compare(b2.x, 168); compare(b2.y, 16)   // 160 + 8 spacing
        compare(b3.x, 336)
        verify(b1.focused); verify(!b2.focused)
        // canvas: widest row = 3*160 + 2*8 = 496 ; height = label+cell = 116
        compare(r.canvasSize.w, 496)
        compare(r.canvasSize.h, 116)
    }

    function test_two_monitors_focused_row_first() {
        var hdmi = { name: "HDMI-A-1", x: 2560, y: 0, width: 1920, height: 1080,
                     scale: 1, reserved: [0, 26, 0, 0], transform: 0 }
        var input = {
            monitors: [edp(), hdmi],
            workspaces: [
                { id: 6, monitorName: "HDMI-A-1", focused: false, occupied: true },
                { id: 1, monitorName: "eDP-1",    focused: true,  occupied: true }
            ],
            windows: [],
            focusedMonitorName: "eDP-1",
            params: params
        }
        var r = Logic.layout(input)
        // focused monitor's workspace sits in the top row (smaller y) despite input order
        verify(boxById(r, 1).y < boxById(r, 6).y)
    }

    function test_skips_negative_workspace_ids() {
        var input = {
            monitors: [edp()],
            workspaces: [
                { id: 1,  monitorName: "eDP-1", focused: true,  occupied: true },
                { id: -99, monitorName: "eDP-1", focused: false, occupied: false }
            ],
            windows: [], focusedMonitorName: "eDP-1", params: params
        }
        var r = Logic.layout(input)
        compare(r.boxes.length, 1, "special/lock workspace id<0 excluded")
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

Run: `mise run test`
Expected: FAIL — `Logic.layout is not a function` (module has no `layout` yet).
**Distinguishes:** the module is actually loaded and the function is genuinely missing —
not a typo'd import passing by accident.

- [ ] **Step 3: Implement `logic.js` (boxes + canvas only for now)**

`logic.js`:

```js
.pragma library

function _index(arr, key) {
    var m = {}
    for (var i = 0; i < arr.length; i++) m[arr[i][key]] = arr[i]
    return m
}

function _orderedMonitorNames(monitors, workspaces, focusedName) {
    var present = {}
    for (var i = 0; i < workspaces.length; i++)
        if (workspaces[i].id >= 0) present[workspaces[i].monitorName] = true
    var byName = _index(monitors, "name")
    var names = []
    for (var j = 0; j < monitors.length; j++)
        if (present[monitors[j].name]) names.push(monitors[j].name)
    names.sort(function (a, b) {
        if (a === focusedName && b !== focusedName) return -1
        if (b === focusedName && a !== focusedName) return 1
        return byName[a].x - byName[b].x
    })
    return names
}

function layout(input) {
    var P = input.params
    var monByName = _index(input.monitors, "name")
    var order = _orderedMonitorNames(input.monitors, input.workspaces, input.focusedMonitorName)

    var wsByMon = {}
    for (var i = 0; i < input.workspaces.length; i++) {
        var ws = input.workspaces[i]
        if (ws.id < 0) continue
        ;(wsByMon[ws.monitorName] = wsByMon[ws.monitorName] || []).push(ws)
    }
    for (var mn in wsByMon)
        wsByMon[mn].sort(function (a, b) { return a.id - b.id })

    var boxes = [], boxByWs = {}, rowTop = 0, canvasW = 0
    for (var r = 0; r < order.length; r++) {
        var wss = wsByMon[order[r]] || []
        if (!wss.length) continue
        var cellsY = rowTop + P.rowLabelH
        for (var c = 0; c < wss.length; c++) {
            var box = {
                workspaceId: wss[c].id, monitorName: order[r],
                x: c * (P.cellW + P.cellSpacing), y: cellsY, w: P.cellW, h: P.cellH,
                focused: !!wss[c].focused, occupied: !!wss[c].occupied
            }
            boxes.push(box); boxByWs[box.workspaceId] = box
        }
        var rowW = wss.length * P.cellW + (wss.length - 1) * P.cellSpacing
        if (rowW > canvasW) canvasW = rowW
        rowTop = cellsY + P.cellH + P.rowSpacing
    }
    var canvasH = rowTop > 0 ? rowTop - P.rowSpacing : 0

    var tiles = []   // filled in Task 3/4
    return { canvasSize: { w: canvasW, h: canvasH }, boxes: boxes, tiles: tiles }
}
```

Property the code must achieve: focused monitor's row has the smallest `y`; a workspace with
`id < 0` produces no box; `canvasSize.w` equals the widest row's cell extent, not the sum of
all rows.

- [ ] **Step 4: Run — expect PASS**

Run: `mise run test`
Expected: PASS (smoke + 3 layout tests).

- [ ] **Step 5: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "feat(logic): layout boxes, monitor-row ordering, canvas size"
```

---

## Task 3: `logic.js` — window→tile mapping (usable rect, scale, centering)

The core coordinate math for ordinary windows inside the usable area, with fractional
scaling and unequal aspect ratios. Fullscreen/clip come in Task 4.

**Files:**
- Modify: `logic.js`
- Modify: `tests/tst_layout.qml`

- [ ] **Step 1: Add failing tests**

Append to `tst_layout.qml`:

```qml
    function tilesByAddr(res, addr) {
        for (var i = 0; i < res.tiles.length; i++)
            if (res.tiles[i].address === addr) return res.tiles[i]
        return null
    }

    // A normal window fully inside the usable area must land entirely within its box's
    // mini-map inset — never bleeding outside (the exact failure of the old formula that
    // subtracted the reserved origin but scaled against the whole monitor).
    function test_tile_stays_within_minimap_fractional_scale() {
        var input = {
            monitors: [edp()],   // scale 1.25, reserved top 26
            workspaces: [{ id: 1, monitorName: "eDP-1", focused: true, occupied: true }],
            windows: [{ address: "0xA", cls: "foot", ax: 100, ay: 200,
                        sw: 800, sh: 600, workspaceId: 1, floating: false, fullscreen: false }],
            focusedMonitorName: "eDP-1", params: params
        }
        var r = Logic.layout(input)
        var b = boxById(r, 1), t = tilesByAddr(r, "0xA")
        verify(t !== null)
        var lo = 0.5
        verify(t.x >= b.x + params.cellInset - lo)
        verify(t.y >= b.y + params.cellInset - lo)
        verify(t.x + t.w <= b.x + params.cellW - params.cellInset + lo)
        verify(t.y + t.h <= b.y + params.cellH - params.cellInset + lo)
    }

    // Unequal aspect: an ultrawide usable area is wider than the cell's mini-map aspect,
    // so it is width-limited => letterboxed vertically (offY > inset), horizontally flush.
    function test_unequal_aspect_letterboxes_on_short_axis() {
        var uw = { name: "DP-1", x: 0, y: 0, width: 5120, height: 1440,
                   scale: 1, reserved: [0, 0, 0, 0], transform: 0 }
        var input = {
            monitors: [uw],
            workspaces: [{ id: 1, monitorName: "DP-1", focused: true, occupied: true }],
            // fullscreen window fills the usable rect exactly, so its tile == the fitted R
            windows: [{ address: "0xF", cls: "x", ax: 0, ay: 0, sw: 5120, sh: 1440,
                        workspaceId: 1, floating: false, fullscreen: true }],
            focusedMonitorName: "DP-1", params: params
        }
        var r = Logic.layout(input)
        var b = boxById(r, 1), t = tilesByAddr(r, "0xF")
        // width-limited: fills mmW (148), centered vertically inside mmH (88)
        fuzzyCompare(t.w, 148, 0.5, "fills mini-map width")
        verify(t.h < 88 - 1)                       // letterboxed on height
        verify(t.y > b.y + params.cellInset + 0.5) // vertically centered, not flush to inset
    }
```

- [ ] **Step 2: Run — expect FAIL**

Run: `mise run test`
Expected: FAIL — the two new tests fail because `tiles` is still empty (`t === null`, `verify`
fails). **Distinguishes:** tile computation genuinely absent, not a bad selector.

- [ ] **Step 3: Implement tile mapping**

In `logic.js`, add the helpers and fill `tiles` inside `layout` (replace the
`var tiles = []` line's block):

```js
function _monLogical(mon) {
    var s = (mon && mon.scale) ? mon.scale : 1
    return { w: mon.width / s, h: mon.height / s }
}

function _usableRect(mon) {
    var l = _monLogical(mon)
    var r = mon.reserved || [0, 0, 0, 0]
    return { x: r[0], y: r[1], w: l.w - r[0] - r[2], h: l.h - r[1] - r[3] }
}

function _tileRect(win, mon, box, P) {
    var l = _monLogical(mon), R = _usableRect(mon)
    var mmW = P.cellW - 2 * P.cellInset, mmH = P.cellH - 2 * P.cellInset
    var k = Math.min(mmW / R.w, mmH / R.h)
    var offX = P.cellInset + (mmW - R.w * k) / 2
    var offY = P.cellInset + (mmH - R.h * k) / 2

    var isFull = !!win.fullscreen ||
        (Math.abs(win.ax - mon.x) <= 1 && Math.abs(win.ay - mon.y) <= 1 &&
         Math.abs(win.sw - l.w) <= 1 && Math.abs(win.sh - l.h) <= 1)
    if (isFull)
        return { x: box.x + offX, y: box.y + offY, w: R.w * k, h: R.h * k }

    var wx = (win.ax - mon.x) - R.x, wy = (win.ay - mon.y) - R.y
    var cx = Math.max(0, wx), cy = Math.max(0, wy)
    var cR = Math.min(wx + win.sw, R.w), cB = Math.min(wy + win.sh, R.h)
    var cw = cR - cx, ch = cB - cy
    if (cw <= 0 || ch <= 0) return null
    var tx = box.x + offX + cx * k, ty = box.y + offY + cy * k
    var tw = Math.max(P.minTileW, cw * k), th = Math.max(P.minTileH, ch * k)
    // keep the (possibly min-clamped) tile inside the cell's mini-map inset
    tx = Math.max(box.x + P.cellInset, Math.min(tx, box.x + P.cellW - P.cellInset - tw))
    ty = Math.max(box.y + P.cellInset, Math.min(ty, box.y + P.cellH - P.cellInset - th))
    return { x: tx, y: ty, w: tw, h: th }
}
```

And in `layout`, replace `var tiles = []   // filled in Task 3/4` with:

```js
    var tiles = []
    for (var wi = 0; wi < input.windows.length; wi++) {
        var win = input.windows[wi]
        var wbox = boxByWs[win.workspaceId]
        if (!wbox) continue
        var wmon = monByName[wbox.monitorName]
        if (!wmon) continue
        var t = _tileRect(win, wmon, wbox, P)
        if (t) { t.address = win.address; t.workspaceId = win.workspaceId; tiles.push(t) }
    }
    return { canvasSize: { w: canvasW, h: canvasH }, boxes: boxes, tiles: tiles }
```

(Return only `canvasSize`/`boxes`/`tiles` — do not leak the internal `boxByWs`/`monByName`
maps.)

Property: `k = min(mmW/R.w, mmH/R.h)` uses the **usable** rect `R` (reserved subtracted from
size), and window positions are taken relative to `R.x/R.y`; centering offsets place the
fitted rect in the middle of the mini-map. A window inside the usable area never exceeds the
mini-map bounds.

- [ ] **Step 4: Run — expect PASS**

Run: `mise run test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "feat(logic): window→tile mapping via usable rect + centering"
```

---

## Task 4: `logic.js` — fullscreen fills R, clip to R, skip off-area, min clamp

**Files:**
- Modify: `tests/tst_layout.qml` (behaviour already implemented in Task 3's `_tileRect`; these
  tests lock it in and guard against regressions)

- [ ] **Step 1: Add failing/guard tests**

Append to `tst_layout.qml`:

```qml
    // Fullscreen fills R; a non-fullscreen window that pokes above the usable top is clipped
    // to R (shorter, but starting at the same usable-top line). The clip window is NOT the
    // full output (sw 1000, sh 1200), so the 1px fullscreen auto-detect must not claim it.
    function test_fullscreen_fills_but_nonfullscreen_clips() {
        function run(w) {
            return Logic.layout({ monitors: [edp()],
                workspaces: [{ id: 1, monitorName: "eDP-1", focused: true, occupied: true }],
                windows: [w], focusedMonitorName: "eDP-1", params: params })
        }
        var full = tilesByAddr(run({ address: "0xF", cls: "x", ax: 0, ay: 0,
            sw: 2048, sh: 1280, workspaceId: 1, floating: false, fullscreen: true }), "0xF")
        // ay:0 is above the usable top (R.y=26) => clipped; not full output => not auto-full
        var norm = tilesByAddr(run({ address: "0xN", cls: "x", ax: 0, ay: 0,
            sw: 1000, sh: 1200, workspaceId: 1, floating: false, fullscreen: false }), "0xN")
        // fullscreen fills the height-limited mini-map exactly (mmH = 88)
        fuzzyCompare(full.h, 88, 0.5, "fullscreen fills limiting axis")
        // clipped window is shorter than the full fill, but shares the usable-top line
        verify(norm.h < full.h - 1)
        fuzzyCompare(norm.y, full.y, 0.5, "clip starts at usable top, not in the bar band")
    }

    // A window entirely left of the monitor has no intersection with R => no tile.
    function test_offscreen_window_yields_no_tile() {
        var r = Logic.layout({ monitors: [edp()],
            workspaces: [{ id: 1, monitorName: "eDP-1", focused: true, occupied: true }],
            windows: [{ address: "0xOff", cls: "x", ax: -500, ay: 100, sw: 200, sh: 200,
                        workspaceId: 1, floating: false, fullscreen: false }],
            focusedMonitorName: "eDP-1", params: params })
        compare(tilesByAddr(r, "0xOff"), null, "off-usable window is skipped")
    }

    // A hairline window is clamped to the minimum visible size.
    function test_min_size_clamp() {
        var r = Logic.layout({ monitors: [edp()],
            workspaces: [{ id: 1, monitorName: "eDP-1", focused: true, occupied: true }],
            windows: [{ address: "0xTiny", cls: "x", ax: 100, ay: 100, sw: 2, sh: 2,
                        workspaceId: 1, floating: true, fullscreen: false }],
            focusedMonitorName: "eDP-1", params: params })
        var t = tilesByAddr(r, "0xTiny")
        compare(t.w, params.minTileW); compare(t.h, params.minTileH)
    }
```

Property these lock in: **the 1px fullscreen auto-detect claims a window as fullscreen only
when its geometry is within 1px of the whole output** — a merely-tall window (`sh: 1200`, not
`1280`) is clipped to R, not filled. An off-usable window yields no tile; a hairline window is
clamped to `minTileW/minTileH`.

Also add two review-driven tests (present in `tests/tst_layout.qml`) that these first four do
NOT catch — each verified to fail before its fix:
- `test_fullscreen_flag_fills_R_even_when_geometry_small` — a **fullscreen-flagged** window with
  small/offset geometry (`ax500 ay400 sw300 sh200`) must **fill R** (`t.h≈88`, `t.w>100`), which
  the clip path cannot do. Pins the `if (isFull)` branch: delete it and `t.h`→~14, test reds.
- `test_min_clamp_stays_within_minimap_at_edge` — a hairline window at the far-right usable edge
  (`ax2046 sw2`) is min-clamped to `minTileW` yet must not spill past the cell inset
  (`t.x + t.w ≤ b.x + cellW − cellInset`). Pins the position-clamp in `_tileRect`.

- [ ] **Step 2: Run — expect PASS** (behaviour implemented in Task 3)

Run: `mise run test`
Expected: PASS (all layout tests). These four assertions guard the fullscreen/clip/skip/clamp
branches of `_tileRect` against regression.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_layout.qml
git commit -m "test(logic): fullscreen-fill vs clip, off-area skip, min clamp"
```

---

## Task 5: `logic.js` — `hitWorkspace()`

**Files:**
- Modify: `logic.js`, `tests/tst_layout.qml`

- [ ] **Step 1: Add failing tests**

Append to `tst_layout.qml`:

```qml
    function test_hit_workspace() {
        var r = Logic.layout({ monitors: [edp()],
            workspaces: [
                { id: 1, monitorName: "eDP-1", focused: true,  occupied: true },
                { id: 2, monitorName: "eDP-1", focused: false, occupied: false }
            ], windows: [], focusedMonitorName: "eDP-1", params: params })
        var b2 = boxById(r, 2)
        // centre of box 2 => ws 2
        compare(Logic.hitWorkspace(r.boxes, b2.x + 80, b2.y + 50), 2)
        // the gap between box 1 and box 2 (x in 160..168) => null
        compare(Logic.hitWorkspace(r.boxes, 164, b2.y + 50), null)
        // above the cells, in the row-label band (y < 16) => null
        compare(Logic.hitWorkspace(r.boxes, 10, 4), null)
    }
```

- [ ] **Step 2: Run — expect FAIL** (`Logic.hitWorkspace is not a function`).

- [ ] **Step 3: Implement**

Append to `logic.js`:

```js
function hitWorkspace(boxes, px, py) {
    for (var i = 0; i < boxes.length; i++) {
        var b = boxes[i]
        if (px >= b.x && px <= b.x + b.w && py >= b.y && py <= b.y + b.h)
            return b.workspaceId
    }
    return null
}
```

Property: returns the workspace whose box contains the point; the inter-cell gaps and the
row-label band return `null` (a drop there is a no-op, not a wrong-workspace move).

- [ ] **Step 4: Run — expect PASS.** `mise run test`.

- [ ] **Step 5: Commit** `git commit -am "feat(logic): hitWorkspace point test"`

---

## Task 6: `logic.js` — `diffByAddress()` (reconcile core / drag safety)

The pure half of the drag-safety guarantee: given the addresses currently in the model and
the freshly computed tiles, decide what to add, update in place, and remove — so a surviving
window keeps its delegate (and its pointer grab / `ScreencopyView`).

**Files:**
- Modify: `logic.js`, `tests/tst_layout.qml`

- [ ] **Step 1: Add failing tests**

```qml
    function test_diff_by_address() {
        var prev = ["0xA", "0xB"]
        var next = [{ address: "0xB", x: 1, y: 1, w: 1, h: 1 },
                    { address: "0xC", x: 2, y: 2, w: 2, h: 2 }]
        var d = Logic.diffByAddress(prev, next)
        compare(d.adds.length, 1);    compare(d.adds[0].address, "0xC")
        compare(d.updates.length, 1); compare(d.updates[0].address, "0xB")
        compare(d.removes.length, 1); compare(d.removes[0], "0xA")
    }
```

Property this distinguishes: a window present in both `prev` and `next` MUST appear in
`updates`, never in `adds` — being re-added would mean destroying and recreating its
delegate, which is the mid-drag failure this whole mechanism exists to prevent.

- [ ] **Step 2: Run — expect FAIL** (`Logic.diffByAddress is not a function`).

- [ ] **Step 3: Implement**

Append to `logic.js`:

```js
function diffByAddress(prevAddresses, nextTiles) {
    var prev = {}
    for (var i = 0; i < prevAddresses.length; i++) prev[prevAddresses[i]] = true
    var next = {}, adds = [], updates = []
    for (var j = 0; j < nextTiles.length; j++) {
        var t = nextTiles[j]
        next[t.address] = true
        if (prev[t.address]) updates.push(t); else adds.push(t)
    }
    var removes = []
    for (var a in prev) if (!next[a]) removes.push(a)
    return { adds: adds, updates: updates, removes: removes }
}
```

- [ ] **Step 4: Run — expect PASS.** `mise run test`.

- [ ] **Step 5: Commit** `git commit -am "feat(logic): diffByAddress reconcile core"`

---

## Task 7: CI — Tier 1 on push

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the workflow**

`.github/workflows/ci.yml`:

```yaml
name: ci
on:
  push:
  pull_request:
jobs:
  logic-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Qt6 Quick test tooling
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends \
            qml6-module-qttest qml6-module-qtquick qml6-module-qtqml \
            qt6-declarative-dev-tools libqt6quick6 libgl1
      - name: Run Tier 1 logic tests (offscreen)
        run: bash tests/run.sh
```

Property this must achieve: CI runs `tests/run.sh` — the *same* Qt6 resolver `mise run test`
runs locally, so the test command has one definition and CI fails the build when a logic test
fails (no `mise`/`just` needed in the runner). `qt6-declarative-dev-tools` provides the Qt6
`qmltestrunner`; the `qml6-module-*` packages provide `QtTest`/`QtQuick`/`QtQml`; `libgl1` +
the offscreen QPA (in `libqt6gui6`, pulled transitively) let it run headless. The resolver's
`qmltestrunner6` branch matches Debian/Ubuntu's binary name; if the runner instead ships it at
`/usr/lib/qt6/bin/qmltestrunner`, the second branch catches it. **Unverifiable until pushed** —
the first Actions run must confirm the resolver finds the Qt6 binary; if not, adjust
`tests/run.sh`'s candidates to the name the runner logs.

- [ ] **Step 2: Verify locally that the command matches CI**

Run: `mise run test`
Expected: PASS. (The workflow can only be confirmed green once pushed; if the Actions run
fails on a missing package, add the exact package the log names — likely `qml6-module-qtquick`
variants — and push again. Do **not** claim CI passes until the Actions run is green.)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: run Tier 1 logic tests offscreen on push"
```

---

## Task 8: Screencopy spike — cases A–D (gates the preview strategy)

Throwaway. Determines, per case, whether we use live capture, snapshot-on-open, or icon.
**Not deleted until Task 13.** Its result decides Task 9's per-tile policy.

**Files:**
- Create: `spike/shell.qml` (throwaway)
- Modify: `docs/plans/2026-09-08-v2-previews-drag-drop.md` (record the result table here)

- [ ] **Step 1: Write the spike**

`spike/shell.qml` — renders a `ScreencopyView` for every current toplevel, labelled with its
app id and whether its workspace is the active one, and samples the centre pixel to flag
black frames. Run with `qs -p spike/shell.qml`.

```qml
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

ShellRoot {
    PanelWindow {
        anchors { top: true; left: true }
        implicitWidth: 900; implicitHeight: 600
        color: "#222"
        Flow {
            anchors.fill: parent; spacing: 8; padding: 8
            Repeater {
                model: ToplevelManager.toplevels
                Rectangle {
                    width: 280; height: 170; color: "#111"; border.color: "#555"
                    ScreencopyView {
                        id: cap
                        anchors.fill: parent; anchors.margins: 2
                        captureSource: modelData
                        live: true
                    }
                    Text {
                        anchors.bottom: parent.bottom; anchors.left: parent.left
                        anchors.margins: 4; color: "#0f0"; font.pixelSize: 11
                        text: (modelData.appId || "?") +
                              "  content=" + cap.hasContent
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Run the case matrix**

Set up: open windows on the **active** workspace (occlude one behind another), on an
**inactive** workspace, and — if an external monitor is available — on the **other monitor**;
open a window playing **animating content** (a video, or `foot` running `top`).

Run: `qs -p spike/shell.qml`

For each case A (active/occluded), B (inactive workspace), C (other monitor), D (animating),
judge — **not** by `hasContent`, which only says a buffer arrived:
- **not-black:** does the tile show real content, or a flat black/grey rectangle?
- **live vs frozen (case D):** watch the animating tile for ~3s — does it update, or is it a
  single frozen frame?

- [ ] **Step 3: Record the result table in this plan**

Fill this in under the task (replace the `?`s), because Task 9 reads it:

```
| Case | Result (live / frozen / black / n-a) | Chosen strategy (live / snapshot / icon) |
| A active+occluded | real (Hyprland composites the active workspace) | live |
| B inactive workspace | UNCONFIRMED — revisit directly in Task 10's grouped overview | live default (icon fallback); flip hidden→icon/snapshot if black |
| C other monitor | LIVE — confirmed: external-monitor browser scroll shown live on the laptop overlay | live |
| D animating content | LIVE — confirmed: real-time page scroll, not frozen | live |
```

Strategy rule: live+non-black → `live`; non-black+frozen → `snapshot`; black → `icon`.

**Decision (2026-09-08):** cross-output live capture works on Quickshell 0.3.1 / Hyprland
0.56.2. Build with `capMode: "live"` for all tiles plus an always-present icon underneath the
capture. Case B (a workspace hidden on every monitor) is the only unknown; it becomes visible
the instant the real grouped overview renders in Task 10 — if hidden-workspace tiles are black
there, set `capMode` to `"icon"` (or `"snapshot"`) for tiles whose workspace is not currently
visible on any monitor. WindowTile already supports this per-tile.

- [ ] **Step 4: Commit the recorded results (spike kept for now)**

```bash
git add spike/shell.qml docs/plans/2026-09-08-v2-previews-drag-drop.md
git commit -m "spike: screencopy cases A–D + recorded capture strategy"
```

---

## Task 9: `WindowTile.qml` — one preview tile with fallback

**Files:**
- Create: `WindowTile.qml`

Implements the per-tile capture policy from Task 8. `capMode` ∈ `"live" | "snapshot" |
"icon"` is chosen by the caller (Task 10) per the recorded table (e.g. keyed on whether the
window's workspace is visible). `hasContent` is used only to cross-fade the icon out once a
buffer is ready — never as proof the frame is good.

- [ ] **Step 1: Write `WindowTile.qml`**

```qml
import QtQuick
import Quickshell
import Quickshell.Wayland

Item {
    id: tile
    // set by the caller:
    property var handle: null            // wl Toplevel, or null
    property string cls: ""
    property string capMode: "live"      // "live" | "snapshot" | "icon"
    property color borderColor: "#888"
    property color bg: "#1a1a1a"
    property color fg: "#ddd"

    readonly property bool wantCapture: handle !== null && capMode !== "icon"
    readonly property string iconUrl: Quickshell.iconPath(String(cls).toLowerCase(), true)

    Rectangle {
        anchors.fill: parent
        color: tile.bg; radius: 4; clip: true
        border.width: 1; border.color: tile.borderColor

        ScreencopyView {
            id: cap
            anchors.fill: parent; anchors.margins: 1
            visible: tile.wantCapture && cap.hasContent
            captureSource: tile.wantCapture ? tile.handle : null
            live: tile.capMode === "live"
        }

        // icon fallback: shown when not capturing, or until the first frame arrives
        Image {
            anchors.centerIn: parent
            visible: !cap.visible && tile.iconUrl.length > 0
            source: tile.iconUrl
            width: Math.min(40, parent.width * 0.5); height: width
            fillMode: Image.PreserveAspectFit
            sourceSize.width: width * Screen.devicePixelRatio
            sourceSize.height: height * Screen.devicePixelRatio
        }
        Text {
            anchors.centerIn: parent
            visible: !cap.visible && tile.iconUrl.length === 0
            text: String(tile.cls).substring(0, 1).toUpperCase()
            color: tile.fg; font.pixelSize: Math.min(20, parent.height * 0.5)
        }
    }
}
```

Property: when `capMode === "icon"` or `handle` is null, no `ScreencopyView` capture runs
(`captureSource` stays null) and the icon/letter shows; when capturing, the icon shows only
until `hasContent`, then the live/snapshot frame replaces it. (`snapshot` = `live:false`, a
single captured frame.)

- [ ] **Step 2: Verify live (standalone)**

Temporarily reference `WindowTile` from the spike or a scratch `qs` config, or defer visual
verification to Task 10 where it is wired in. Minimum: `omarchy plugin validate .` still
passes (no syntax error). Run: `omarchy plugin validate .` → expect exit 0.

- [ ] **Step 3: Commit**

```bash
git add WindowTile.qml
git commit -m "feat: WindowTile preview tile with icon fallback + capture modes"
```

---

## Task 10: Rewrite `Overview.qml` — canvas + boxes + reconciled tiles + keyboard/click

Replaces v1's clipped per-cell rendering. Keeps v1's overlay shell (PanelWindow, scrim,
exclusive focus, focused-screen targeting), keyboard selection, and close behaviour. Renders
boxes from `logic.layout`, and window tiles from a `ListModel` reconciled via
`diffByAddress`. Drag-and-drop is added in Task 11 — here tiles are click-only.

**Files:**
- Modify: `Overview.qml` (full rewrite; v1 is the starting reference)

- [ ] **Step 1: Rewrite `Overview.qml`**

```qml
// Omascape — v2. Canvas + boxes + live tiles. See DESIGN.md / docs/specs, docs/plans.
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "logic.js" as Logic

Item {
    id: root
    property bool opened: false
    property var targetScreen: null

    property var boxes: []
    property var handleByAddress: ({})
    property int selectedIndex: -1
    readonly property int selectedId:
        (selectedIndex >= 0 && selectedIndex < boxes.length) ? boxes[selectedIndex].workspaceId : -1

    // theme
    property color background: Color.menu.background
    property color foreground: Color.menu.text
    property color borderColor: Color.menu.border
    property color scrim: Color.menu.scrim
    property color selBackground: Color.menu.selectedBackground
    property color selText: Color.menu.selectedText
    readonly property int cornerRadius: Style.cornerRadius

    readonly property var params: ({
        cellW: 160, cellH: 100, cellInset: 6, cellSpacing: 8,
        rowSpacing: 12, rowLabelH: 16, minTileW: 8, minTileH: 6
    })

    function focusedScreen() {
        var mon = Hyprland.focusedMonitor, screens = Quickshell.screens || []
        for (var i = 0; i < screens.length; i++)
            if (mon && screens[i].name === mon.name) return screens[i]
        return screens.length ? screens[0] : null
    }

    // Build handleByAddress from the wl toplevels (address <- HyprlandToplevel.address).
    function buildHandles() {
        var map = {}, tls = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
        for (var i = 0; i < tls.length; i++) {
            var t = tls[i], h = t.HyprlandToplevel
            if (h && h.address) map["0x" + h.address] = t
        }
        root.handleByAddress = map
    }

    function buildInput() {
        var mons = [], hmons = Hyprland.monitors ? Hyprland.monitors.values : []
        for (var i = 0; i < hmons.length; i++) {
            var m = hmons[i]
            mons.push({ name: m.name, x: m.x, y: m.y, width: m.width, height: m.height,
                        scale: m.scale, reserved: m.lastIpcObject ? m.lastIpcObject.reserved : [0,0,0,0],
                        transform: m.lastIpcObject ? m.lastIpcObject.transform : 0 })
        }
        var wss = [], hws = Hyprland.workspaces ? Hyprland.workspaces.values : []
        var focusedWsId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
        var wins = []
        for (var j = 0; j < hws.length; j++) {
            var ws = hws[j]; if (!ws || ws.id < 0) continue
            var mon = ws.monitor
            wss.push({ id: ws.id, monitorName: mon ? mon.name : "?",
                       focused: ws.id === focusedWsId,
                       occupied: ws.toplevels && ws.toplevels.values.length > 0 })
            var tls = ws.toplevels ? ws.toplevels.values : []
            for (var t = 0; t < tls.length; t++) {
                var o = tls[t] ? tls[t].lastIpcObject : null
                if (!o || !o.at || !o.size || !o.address) continue
                wins.push({ address: o.address, cls: o["class"] || "",
                            ax: o.at[0], ay: o.at[1], sw: o.size[0], sh: o.size[1],
                            workspaceId: ws.id, floating: !!o.floating, fullscreen: !!o.fullscreen })
            }
        }
        return { monitors: mons, workspaces: wss, windows: wins,
                 focusedMonitorName: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "",
                 params: root.params }
    }

    // Reconcile the tiles ListModel in place (drag-safe: never touch the dragged address).
    property string draggingAddress: ""
    function applyTiles(tiles) {
        var prev = []
        for (var i = 0; i < tilesModel.count; i++) prev.push(tilesModel.get(i).address)
        var d = Logic.diffByAddress(prev, tiles)
        function indexOf(addr) {
            for (var i = 0; i < tilesModel.count; i++)
                if (tilesModel.get(i).address === addr) return i
            return -1
        }
        for (var a = 0; a < d.adds.length; a++) {
            var t = d.adds[a]
            tilesModel.append({ address: t.address, wx: t.x, wy: t.y, ww: t.w, wh: t.h,
                                cls: clsFor(t.address), wsid: t.workspaceId })
        }
        for (var u = 0; u < d.updates.length; u++) {
            var tu = d.updates[u]
            if (root.draggingAddress === tu.address) continue   // grab is authoritative
            var iu = indexOf(tu.address)
            if (iu >= 0) tilesModel.set(iu, { wx: tu.x, wy: tu.y, ww: tu.w, wh: tu.h, wsid: tu.workspaceId })
        }
        for (var rmi = 0; rmi < d.removes.length; rmi++) {
            if (root.draggingAddress === d.removes[rmi]) continue // cancel handled elsewhere
            var ir = indexOf(d.removes[rmi]); if (ir >= 0) tilesModel.remove(ir)
        }
    }

    property var _clsByAddress: ({})
    function clsFor(addr) { return root._clsByAddress[addr] || "" }

    function rebuild() {
        buildHandles()
        var input = buildInput()
        // cache class per address for the model role
        var cmap = {}
        for (var i = 0; i < input.windows.length; i++) cmap[input.windows[i].address] = input.windows[i].cls
        root._clsByAddress = cmap
        var res = Logic.layout(input)
        root.boxes = res.boxes
        canvas.implicitWidth = res.canvasSize.w
        canvas.implicitHeight = res.canvasSize.h
        applyTiles(res.tiles)
        if (root.selectedIndex < 0) {
            var fi = -1
            for (var b = 0; b < res.boxes.length; b++) if (res.boxes[b].focused) { fi = b; break }
            root.selectedIndex = fi >= 0 ? fi : (res.boxes.length ? 0 : -1)
        } else {
            root.selectedIndex = res.boxes.length
                ? Math.min(Math.max(root.selectedIndex, 0), res.boxes.length - 1) : -1
        }
    }

    function moveSel(delta) {
        if (!boxes.length) return
        selectedIndex = Math.max(0, Math.min(boxes.length - 1, selectedIndex + delta))
    }
    function jump(id) {
        if (id === undefined || id === null) return
        Hyprland.dispatch('hl.dsp.focus({ workspace = "' + id + '" })'); root.close()
    }
    function open() {
        if (typeof Hyprland.refreshMonitors === "function") Hyprland.refreshMonitors()
        if (typeof Hyprland.refreshToplevels === "function") Hyprland.refreshToplevels()
        targetScreen = focusedScreen(); selectedIndex = -1; opened = true
        rebuild(); refreshTimer.restart()
        Qt.callLater(function () { keyCatcher.forceActiveFocus() })
    }
    function close() { opened = false }
    function toggle() { if (opened) close(); else open() }

    Timer { id: refreshTimer; interval: 80; onTriggered: if (root.opened) root.rebuild() }
    ListModel { id: tilesModel }

    // Rebuild when toplevels/workspaces change while open (fresh handles + geometry).
    Connections {
        target: Hyprland
        function onRawEvent() { if (root.opened && !root.draggingAddress) root.rebuild() }
    }

    PanelWindow {
        id: panel
        visible: root.opened; screen: root.targetScreen
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "omascape"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        Rectangle { anchors.fill: parent; color: root.scrim }
        MouseArea { anchors.fill: parent; onClicked: root.close() }

        Rectangle {
            id: card
            anchors.centerIn: parent; radius: root.cornerRadius
            color: root.background; border.width: 1; border.color: root.borderColor
            readonly property int pad: 16
            implicitWidth: canvas.implicitWidth + pad * 2
            implicitHeight: canvas.implicitHeight + pad * 2 + hint.height + 8
            MouseArea { anchors.fill: parent; onClicked: {} }

            Item {
                id: keyCatcher
                anchors.fill: parent; focus: true; Keys.priority: Keys.BeforeItem
                Keys.onPressed: function (e) {
                    if (e.key === Qt.Key_Escape) { root.close(); e.accepted = true }
                    else if (e.key >= Qt.Key_1 && e.key <= Qt.Key_9) { root.jump(e.key - Qt.Key_0); e.accepted = true }
                    else if (e.key === Qt.Key_0) { root.jump(10); e.accepted = true }
                    else if (e.key === Qt.Key_Left || e.key === Qt.Key_Up) { root.moveSel(-1); e.accepted = true }
                    else if (e.key === Qt.Key_Right || e.key === Qt.Key_Down) { root.moveSel(1); e.accepted = true }
                    else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                        if (root.selectedId >= 0) root.jump(root.selectedId); e.accepted = true
                    }
                }
            }

            Item {
                id: canvas
                x: card.pad; y: card.pad
                implicitWidth: 100; implicitHeight: 100

                // boxes layer
                Repeater {
                    model: root.opened ? root.boxes : []
                    Rectangle {
                        required property var modelData
                        readonly property bool isSel: modelData.workspaceId === root.selectedId
                        x: modelData.x; y: modelData.y; width: modelData.w; height: modelData.h
                        radius: 6
                        color: modelData.focused ? root.selBackground : "transparent"
                        border.width: isSel ? 3 : (modelData.focused ? 2 : 1)
                        border.color: isSel ? root.foreground
                                            : (modelData.focused ? root.selBackground : root.borderColor)
                        opacity: (modelData.occupied || modelData.focused) ? 1.0 : 0.5

                        Text {
                            anchors.centerIn: parent
                            text: modelData.workspaceId === 10 ? "0" : String(modelData.workspaceId)
                            color: modelData.focused ? root.selText : root.foreground
                            opacity: 0.25; font.pixelSize: 22
                        }
                        MouseArea {   // click empty area of a workspace => jump
                            anchors.fill: parent
                            onClicked: root.jump(modelData.workspaceId)
                        }
                    }
                }

                // tiles layer (siblings, above boxes)
                Repeater {
                    model: tilesModel
                    WindowTile {
                        required property var model
                        x: model.wx; y: model.wy; width: model.ww; height: model.wh
                        cls: model.cls
                        handle: root.handleByAddress[model.address] || null
                        // capMode chosen in Task 11/spike policy; default "live"
                        capMode: "live"
                        borderColor: root.borderColor; bg: root.background; fg: root.foreground
                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                            onClicked: function (m) {
                                if (m.button === Qt.MiddleButton)
                                    Hyprland.dispatch('hl.dsp.window.close({ window = "address:' + model.address + '" })')
                                else {
                                    Hyprland.dispatch('hl.dsp.focus({ window = "address:' + model.address + '" })')
                                    root.close()
                                }
                            }
                        }
                    }
                }
            }

            Text {
                id: hint
                anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 8 }
                text: "1–0 jump · arrows move · Enter select · drag a window · Esc close"
                color: root.foreground; opacity: 0.5; font.pixelSize: 11
            }
        }
    }
}
```

- [ ] **Step 2: Verify it validates**

Run: `omarchy plugin validate .`
Expected: exit 0.

- [ ] **Step 3: Live-test**

Copy over + restart (see Live-test loop), press SUPER+P.
Expected on screen (properties):
- One boxed row per monitor; numbered workspace boxes; focused workspace highlighted.
- Each window appears as a **tile at its real relative position** inside the right box —
  showing a live thumbnail (or the app icon per the spike policy).
- **No tile bleeds outside its box** into the row gaps (the containment property from Task 3).
- Number/arrow/Enter still jump; clicking a window focuses it and closes; middle-click closes
  the window; clicking a box's empty area jumps; Esc/scrim close.

- [ ] **Step 4: Commit**

```bash
git add Overview.qml
git commit -m "feat: rewrite Overview to canvas + boxes + reconciled live tiles"
```

---

## Task 11: Drag-and-drop between workspaces

Adds the drag `MouseArea` to tiles, the `dragging` guard, cancellations, the silent-move
dispatch, and post-move reconciliation with bounded recovery.

**Files:**
- Modify: `Overview.qml`

- [ ] **Step 1: Add drag state + post-move reconcile helpers to `root`**

Insert into `Overview.qml` `root` (near `draggingAddress`):

```qml
    property int _pendingTargetWs: -1
    property int _reconcileTries: 0
    Timer {
        id: reconcileTimer; interval: 120; repeat: true
        onTriggered: root._reconcileStep()
    }
    function _startMove(addr, targetWs) {
        root.draggingAddress = ""          // grab released by caller before this
        root._pendingTargetWs = targetWs
        root._reconcileTries = 0
        Hyprland.dispatch('hl.dsp.window.move({ workspace = ' + targetWs +
                          ', follow = false, window = "address:' + addr + '" })')
        if (typeof Hyprland.refreshToplevels === "function") Hyprland.refreshToplevels()
        if (typeof Hyprland.refreshWorkspaces === "function") Hyprland.refreshWorkspaces()
        reconcileTimer.restart()
    }
    function _reconcileStep() {
        root._reconcileTries++
        if (typeof Hyprland.refreshToplevels === "function") Hyprland.refreshToplevels()
        root.rebuild()                     // pull fresh geometry, re-place all tiles
        // Bounded recovery: after ~6 tries (~0.7s) stop regardless. rebuild() has already
        // snapped every tile to whatever Hyprland actually reports (authoritative), so a
        // failed/again-moved window is never left pinned to an optimistic spot.
        if (root._reconcileTries >= 6) { reconcileTimer.stop(); root._pendingTargetWs = -1 }
    }
```

Property: the tile's final position always comes from a real `rebuild()` over refreshed
Hyprland data — the timer only *bounds* how long we keep re-pulling, it is never the source of
the position. If the move failed, the window reappears at its real (unchanged) workspace on
the next rebuild; it is not stuck at the drop point.

- [ ] **Step 2: Replace the tile's `MouseArea` with a drag-capable one**

In the tiles `Repeater` delegate, replace the click-only `MouseArea` with:

```qml
                        MouseArea {
                            id: dragArea
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                            drag.target: undefined
                            property bool moved: false
                            onPressed: function (m) {
                                if (m.button !== Qt.LeftButton) return
                                root.draggingAddress = model.address
                                parent.z = 99999; moved = false
                                drag.target = parent
                            }
                            onPositionChanged: if (drag.active) moved = true
                            onReleased: function (m) {
                                if (m.button === Qt.MiddleButton) {
                                    Hyprland.dispatch('hl.dsp.window.close({ window = "address:' + model.address + '" })')
                                    return
                                }
                                drag.target = undefined; parent.z = 0
                                var addr = model.address
                                var wasMoved = moved
                                // Capture the drop-point centre in canvas coords FIRST — the
                                // rebinding below resets parent.x/y to model.wx, so reading the
                                // drop position after it would test the tile's ORIGINAL spot and
                                // no move would ever register.
                                var cx = parent.x + parent.width / 2
                                var cy = parent.y + parent.height / 2
                                // Dragging assigned parent.x/y imperatively, which DESTROYS the
                                // `x: model.wx` bindings. Restore them so snap-back and the
                                // post-move rebuild (which write model.wx via set()) actually
                                // move the tile. Without this the tile is frozen where dropped.
                                parent.x = Qt.binding(function () { return model.wx })
                                parent.y = Qt.binding(function () { return model.wy })
                                if (!wasMoved) {   // a click, not a drag
                                    root.draggingAddress = ""
                                    Hyprland.dispatch('hl.dsp.focus({ window = "address:' + addr + '" })')
                                    root.close(); return
                                }
                                var targetWs = Logic.hitWorkspace(root.boxes, cx, cy)
                                if (targetWs !== null && targetWs !== model.wsid) {
                                    root.draggingAddress = ""   // release grab; move will rebuild
                                    root._startMove(addr, targetWs)
                                } else {
                                    root.draggingAddress = ""; root.rebuild()   // snap back
                                }
                            }
                        }
```

Property: `hitWorkspace` (the same pure function Tier 1 tests) resolves the drop, so gesture
and tests agree; a drop on the source workspace or in a gap (`null`) is a no-op that snaps the
tile back; only a different workspace dispatches a **silent** (`follow = false`) move.

- [ ] **Step 3: Wire drag-cancellation on overview close**

In `close()`, cancel any in-flight grab:

```qml
    function close() { root.draggingAddress = ""; reconcileTimer.stop(); opened = false }
```

And guard the reconcile `rebuild` against removing the dragged tile — already handled in
`applyTiles` (the `draggingAddress` skips in update/remove). The `onRawEvent` Connection also
already skips rebuilds while `draggingAddress` is set, so a window closing mid-drag won't tear
down the grabbed delegate; the orphaned tile is cleaned up on the next rebuild after release.

- [ ] **Step 4: Live-test the drag**

Copy over + restart, SUPER+P. Properties to confirm:
- Dragging a window tile lifts it above the others and follows the cursor.
- Dropping it on another workspace box **moves the window there** and the tile settles into
  that box; the **active workspace does not change** (you stay where you were).
- Dropping on the same box or in a gap snaps the tile back, no move.
- Closing the window you're dragging (e.g. it crashes) or pressing Esc mid-drag does not
  freeze or crash the overlay.

- [ ] **Step 5: Commit**

```bash
git add Overview.qml
git commit -m "feat: drag-and-drop windows between workspaces (silent move + reconcile)"
```

---

## Task 12: Tier 2 — headless-Hyprland integration target

Asserts the drop's *effect* on real Hyprland: dispatch the silent move, confirm the window
lands on the target workspace and the active workspace is unchanged.

**Files:**
- Create: `tests/integration/move.sh`
- Modify: `mise.toml`

- [ ] **Step 1: Establish the headless launch (this task's first, uncertain step)**

Hyprland ships a headless backend (confirmed: the `Hyprland` binary references "headless").
The exact activation env is **not assumed here** — determine it empirically and record it in
the script's comments. Try, in order, until `hyprctl monitors` shows a `HEADLESS` output:

```bash
# candidate A (Aquamarine force-headless):
AQ_FORCE_HEADLESS=1 Hyprland &
# candidate B (wlroots-era var, may still be honoured):
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 Hyprland &
```

Run with a throwaway `HYPRLAND_INSTANCE_SIGNATURE`/`XDG_RUNTIME_DIR` sandbox so it does not
touch the live session. Confirm: `hyprctl monitors -j | jq '.[].name'` lists an output. Do
**not** proceed to Step 2 until one candidate works; pin it in the script.

- [ ] **Step 2: Write `tests/integration/move.sh`**

```bash
#!/usr/bin/env bash
# Tier 2: assert a silent move lands a window on the target workspace without
# changing the active workspace. Requires a headless Hyprland (see Step 1).
set -euo pipefail

# ... launch headless Hyprland into an isolated XDG_RUNTIME_DIR (pinned in Step 1) ...
hyprctl dispatch workspace 1
foot & sleep 0.5
ADDR=$(hyprctl activewindow -j | jq -r '.address')
ACTIVE_BEFORE=$(hyprctl activeworkspace -j | jq -r '.id')

hyprctl dispatch "hl.dsp.window.move({ workspace = 3, follow = false, window = \"address:${ADDR}\" })"
sleep 0.3

WS_OF_WIN=$(hyprctl clients -j | jq -r --arg a "$ADDR" '.[] | select(.address==$a) | .workspace.id')
ACTIVE_AFTER=$(hyprctl activeworkspace -j | jq -r '.id')

[[ "$WS_OF_WIN" == "3" ]] || { echo "FAIL: window on ws $WS_OF_WIN, expected 3"; exit 1; }
[[ "$ACTIVE_AFTER" == "$ACTIVE_BEFORE" ]] || { echo "FAIL: active ws changed ($ACTIVE_BEFORE->$ACTIVE_AFTER); follow=false broken"; exit 1; }
echo "PASS: silent move to ws 3, active ws unchanged"
```

Property this distinguishes: (a) the **exact dispatch string** Omascape sends actually moves
the window by address on real Hyprland — a syntax/typo regression goes red; (b) `follow =
false` genuinely does **not** switch the active workspace — a change to a following move goes
red. Both are asserted against `hyprctl`, values the compositor reports, not values the test
supplied.

- [ ] **Step 3: Add the task + verify locally**

Append to `mise.toml`:

```toml
[tasks.test-integration]
description = "Tier 2: headless-Hyprland integration (local; needs Hyprland + foot + jq)"
run = "bash tests/integration/move.sh"
```

Run: `mise run test-integration` → expect `PASS: silent move to ws 3, active ws unchanged`.

- [ ] **Step 4: Commit**

```bash
git add tests/integration/move.sh mise.toml
git commit -m "test(integration): headless-Hyprland silent-move assertion"
```

---

## Task 13: Docs, version bump, spike cleanup, final pass

**Files:**
- Modify: `DESIGN.md`, `ROADMAP.md`, `manifest.json`
- Delete: `spike/`

- [ ] **Step 1: Bump the manifest version**

`manifest.json`: `"version": "0.1.0"` → `"version": "0.2.0"`.

- [ ] **Step 2: Update `DESIGN.md` and `ROADMAP.md`**

- `DESIGN.md`: add a v2 section — live previews (per-case capture strategy from Task 8),
  drag-and-drop (silent move), the canvas/boxes/tiles structure, and the `logic.js` seam.
- `ROADMAP.md`: check off previews + drag-drop; note remaining deferred items (both-screens
  dimming, paging, floating reposition, rotated monitors) still stand.

- [ ] **Step 3: Remove the throwaway spike**

```bash
git rm -r spike/
```

- [ ] **Step 4: Full validation + final manual pass**

```bash
mise run test                       # Tier 1 green
omarchy plugin validate .       # exit 0
# copy over + omarchy restart shell, then SUPER+P
```

Manual checklist: previews render (per policy); drag moves silently to the right workspace;
click focuses; middle-click closes; theme switch (`omarchy theme next`) re-themes; if an
external monitor is available, two rows render and tiles land in the correct monitor's row.

- [ ] **Step 5: Commit**

```bash
git add DESIGN.md ROADMAP.md manifest.json
git commit -m "docs: v2 previews + drag-drop; bump version to 0.2.0; drop spike"
```

---

## Deferred (not in this plan — from the spec's out-of-scope)

Both-screens simultaneous render + non-active dimming; workspace paging; dragging to
reposition a floating window *within* its workspace; rotated-monitor (`transform`) handling;
full pointer-drag pixel e2e (Tier 3).
