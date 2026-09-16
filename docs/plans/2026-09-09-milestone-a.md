# Omascape v3 Milestone A — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Four polish features on the shipped v2 overview — bigger auto-sized tiles (≤5 across, wrap), monitor name chips + focused accent, mouse hover/select zoom, and drag/style polish on a scrolling canvas.

**Architecture:** All sizing/wrap/placement math stays in the pure `.pragma library` `logic.js` (Tier-1 unit-tested offscreen); the canvas becomes a `Flickable`, and all visual behaviour (chips, zoom, rounded thumbnails, drop highlight, edge auto-scroll, teardown) lives in `Overview.qml` / `WindowTile.qml` and is verified live.

**Tech Stack:** QML/Qt Quick, Quickshell 0.3.1 (`ScreencopyView`, `ToplevelManager`, `Quickshell.Widgets.ClippingRectangle`, `QtQuick.Effects.MultiEffect`), Hyprland 0.56.2. Tests: `mise run test` (Qt6 `qmltestrunner` offscreen via `tests/run.sh`).

**Spec:** `docs/specs/2026-09-09-milestone-a-design.md` (read it first). Branch: `v3-milestone-a`.

---

## Conventions (every task)

**Branch:** `v3-milestone-a` (already created; the spec is committed on it). `git checkout v3-milestone-a` first.

**Unit-test loop:** `mise run test` (offscreen `qmltestrunner`; all logic tests must stay green).

**Live-test loop (QML tasks):** copy changed files into the installed clone and restart the shell (QML edits need a full restart, not a rescan):
```bash
LIVE="$HOME/.config/omarchy/plugins/se.mindfulstack.omascape"
cp logic.js WindowTile.qml Overview.qml "$LIVE"/ 2>/dev/null; omarchy restart shell
```
Then SUPER+P and observe.

**New layout params (used across logic + tests):**
`{ maxCols:5, minCellW:140, maxCellW:380, cellInset:6, cellSpacing:8, rowSpacing:12, headerH:22, minTileW:8, minTileH:6 }` — note `cellW`/`cellH` are **removed** (now computed) and `rowLabelH`→`headerH`.

**Clean test anchor:** with `availW = 1632` and the eDP monitor (2560×1600 @1.25 → 2048×1280 logical, aspect 1.6): `cols = 5`, `cw = 320`, `ch = 200`. These exact values are used in the sizing tests so expectations stay integer.

---

## Task 1: `logic.js` — adaptive sizing + wrap + `_tileRect` on box size (Tier-1 core)

This is the only unit-tested task and everything visual depends on its geometry — treat it as the highest-stakes task. It **replaces the fixed-grid layout** with computed cell sizes and sub-row wrapping, and returns `cell` + `groups` metadata the view needs.

**Files:**
- Modify: `logic.js`
- Modify: `tests/tst_layout.qml` (params reshaped; sizing/wrap tests added; `_tileRect` tests re-based on `box.w/h`)

- [ ] **Step 1: Reshape the shared test fixture + write the new sizing/wrap failing tests**

In `tests/tst_layout.qml`, change the shared `params` to the new shape and add an `availW` to the input helpers, then add these tests. (Keep `edp()` as-is; add `hdmi()`.)

```qml
    readonly property var params: ({
        maxCols: 5, minCellW: 140, maxCellW: 380, cellInset: 6, cellSpacing: 8,
        rowSpacing: 12, headerH: 22, minTileW: 8, minTileH: 6
    })
    function hdmi() {
        return { name: "HDMI-A-1", x: 2560, y: 0, width: 1920, height: 1080,
                 scale: 1, reserved: [0, 26, 0, 0], transform: 0 }
    }
    // wide anchor: availW 1632 => cols 5, cw 320, ch 200 (eDP aspect 1.6)
    function test_cell_size_and_boxes_wide() {
        var r = Logic.layout({ monitors:[edp()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:true,occupied:true},
                        {id:2,monitorName:"eDP-1",focused:false,occupied:false},
                        {id:3,monitorName:"eDP-1",focused:false,occupied:true}],
            windows:[], focusedMonitorName:"eDP-1", availW:1632, params:params })
        compare(r.cell.cols, 5); compare(r.cell.w, 320); compare(r.cell.h, 200)
        var b1=boxById(r,1), b2=boxById(r,2)
        compare(b1.x,0);   compare(b1.y,22)            // below the headerH header
        compare(b2.x,328)                              // 320 + 8 gap
        compare(r.canvasSize.w, 976)                   // 3*320 + 2*8
        compare(r.canvasSize.h, 222)                   // headerH 22 + ch 200
    }
    // narrow screen: fewer columns, never wider than availW
    function test_narrow_adaptive_cols_no_overflow() {
        var r = Logic.layout({ monitors:[edp()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:true,occupied:true},
                        {id:2,monitorName:"eDP-1",focused:false,occupied:false},
                        {id:3,monitorName:"eDP-1",focused:false,occupied:false}],
            windows:[], focusedMonitorName:"eDP-1", availW:600, params:params })
        compare(r.cell.cols, 4)                        // floor((600+8)/148)=4, capped at 5 (n/a)
        verify(r.canvasSize.w <= 600)                  // a full row fits by construction
    }
    // degenerate: below minCellW => 1 column, cell clamped up to minCellW
    function test_degenerate_narrow_clamps_to_min() {
        var r = Logic.layout({ monitors:[edp()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:true,occupied:true}],
            windows:[], focusedMonitorName:"eDP-1", availW:100, params:params })
        compare(r.cell.cols, 1); compare(r.cell.w, 140)   // clamped up; may exceed availW (2-D scroll)
    }
    // >cols workspaces wrap into sub-rows
    function test_wrap_into_subrows() {
        var wss=[]; for (var i=1;i<=7;i++) wss.push({id:i,monitorName:"eDP-1",focused:i===1,occupied:true})
        var r = Logic.layout({ monitors:[edp()], workspaces:wss, windows:[],
            focusedMonitorName:"eDP-1", availW:1632, params:params })
        compare(boxById(r,5).y, 22)                    // first sub-row
        compare(boxById(r,6).x, 0)                     // second sub-row, first column
        compare(boxById(r,6).y, 234)                   // 22 + ch200 + rowSpacing12
        compare(r.canvasSize.h, 434)                   // 22 + 200 + 12 + 200
    }
    // two monitors stack, focused group first, groups metadata present
    function test_two_monitor_groups() {
        var r = Logic.layout({ monitors:[edp(),hdmi()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:true,occupied:true},
                        {id:6,monitorName:"HDMI-A-1",focused:false,occupied:true}],
            windows:[], focusedMonitorName:"eDP-1", availW:1632, params:params })
        compare(r.groups.length, 2)
        compare(r.groups[0].monitorName, "eDP-1"); verify(r.groups[0].focused)
        compare(r.groups[0].y, 0); compare(r.groups[1].y, 234)   // eDP header0+row → 222, +rowSpacing12
        verify(boxById(r,1).y < boxById(r,6).y)
    }
```

Property each distinguishes: `_cell_size_and_boxes_wide` pins the exact adaptive-sizing math and header offset (breaks if `cols`, `cw`, `ch`, or header spacing is wrong). `_narrow_adaptive_cols_no_overflow` is the gap-#1 guard — it fails if `cols` stays pinned at 5 and the row runs past `availW`. `_degenerate` pins the min clamp + 1-column floor. `_wrap_into_subrows` fails if wrapping doesn't start a new sub-row at the right y/x. `_two_monitor_groups` fails if the `groups` metadata (needed for chips) is missing or mis-positioned.

- [ ] **Step 2: Run — expect FAIL**

Run: `mise run test`
Expected: the five new tests FAIL — `r.cell`/`r.groups` are `undefined` and `availW` is ignored (old layout still uses fixed `cellW`). Distinguishes that the new geometry genuinely isn't implemented (not a typo).

- [ ] **Step 3: Rewrite `layout()` for computed sizing + wrap + groups; refactor `_tileRect`**

Replace `layout()` and `_tileRect` in `logic.js` with:

```js
function _tileRect(win, mon, box, P) {
    var l = _monLogical(mon), R = _usableRect(mon)
    var mmW = box.w - 2 * P.cellInset, mmH = box.h - 2 * P.cellInset   // was P.cellW/P.cellH
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
    tx = Math.max(box.x + P.cellInset, Math.min(tx, box.x + box.w - P.cellInset - tw))
    ty = Math.max(box.y + P.cellInset, Math.min(ty, box.y + box.h - P.cellInset - th))
    return { x: tx, y: ty, w: tw, h: th }
}

function layout(input) {
    var P = input.params
    var monByName = _index(input.monitors, "name")
    var order = _orderedMonitorNames(input.monitors, input.workspaces, input.focusedMonitorName)

    // adaptive cell size — maxCols is a CAP, not a floor
    var gap = P.cellSpacing
    var cols = Math.max(1, Math.min(P.maxCols,
        Math.floor((input.availW + gap) / (P.minCellW + gap))))
    var cw = Math.max(P.minCellW, Math.min(P.maxCellW,
        Math.floor((input.availW - (cols - 1) * gap) / cols)))
    var fmon = monByName[input.focusedMonitorName]
    var aspect = fmon ? _monLogical(fmon).w / _monLogical(fmon).h : (16 / 10)
    var ch = Math.round(cw / aspect)

    var wsByMon = {}
    for (var i = 0; i < input.workspaces.length; i++) {
        var ws = input.workspaces[i]; if (ws.id < 0) continue
        ;(wsByMon[ws.monitorName] = wsByMon[ws.monitorName] || []).push(ws)
    }
    for (var mn in wsByMon) wsByMon[mn].sort(function (a, b) { return a.id - b.id })

    var boxes = [], boxByWs = {}, groups = [], y = 0, canvasW = 0
    for (var r = 0; r < order.length; r++) {
        var name = order[r], wss = wsByMon[name] || []
        if (!wss.length) continue
        var focusedGroup = name === input.focusedMonitorName
        groups.push({ monitorName: name, x: 0, y: y, headerH: P.headerH, focused: focusedGroup })
        y += P.headerH
        for (var s = 0; s < wss.length; s += cols) {
            var chunk = wss.slice(s, s + cols)
            for (var c = 0; c < chunk.length; c++) {
                var box = { workspaceId: chunk[c].id, monitorName: name, monFocused: focusedGroup,
                            x: c * (cw + gap), y: y, w: cw, h: ch,
                            focused: !!chunk[c].focused, occupied: !!chunk[c].occupied }
                boxes.push(box); boxByWs[box.workspaceId] = box
            }
            var rowW = chunk.length * cw + (chunk.length - 1) * gap
            if (rowW > canvasW) canvasW = rowW
            y += ch
            if (s + cols < wss.length) y += P.rowSpacing        // between sub-rows of one group
        }
        if (r < order.length - 1) y += P.rowSpacing             // between monitor groups
    }

    var tiles = []
    for (var wi = 0; wi < input.windows.length; wi++) {
        var win = input.windows[wi], wbox = boxByWs[win.workspaceId]; if (!wbox) continue
        var wmon = monByName[wbox.monitorName]; if (!wmon) continue
        var t = _tileRect(win, wmon, wbox, P)
        if (t) { t.address = win.address; t.workspaceId = win.workspaceId; tiles.push(t) }
    }
    return { canvasSize: { w: canvasW, h: y }, boxes: boxes, tiles: tiles,
             groups: groups, cell: { w: cw, h: ch, cols: cols } }
}
```

Property this must achieve: `cols` is bounded by both `maxCols` and how many `minCellW` cells fit `availW`, so a full sub-row never exceeds `availW` (except the sub-`minCellW` degenerate case); `_tileRect` now derives the mini-map from `box.w/h`, so tiles scale with the computed cell.

- [ ] **Step 4: Update the carried-over `_tileRect` behaviour tests to the new box size**

The existing fullscreen / clip / off-area / min-clamp / hitWorkspace / diffByAddress tests still hold, but their windows now land in a 320×200 cell (`availW:1632`). Update each existing test to pass `availW:1632` and the new `params`, and re-base the fullscreen assertion on the new mini-map height `mmH = box.h − 2*inset = 200 − 12 = 188`:

```qml
    function test_fullscreen_flag_fills_R_even_when_geometry_small() {
        var r = Logic.layout({ monitors:[edp()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:true,occupied:true}],
            windows:[{address:"0xFS",cls:"x",ax:500,ay:400,sw:300,sh:200,
                      workspaceId:1,floating:false,fullscreen:true}],
            focusedMonitorName:"eDP-1", availW:1632, params:params })
        var t = tilesByAddr(r,"0xFS")
        verify(t !== null)
        fuzzyCompare(t.h, 188, 0.5, "fullscreen fills R height = box.h-2*inset")
        verify(t.w > 100)
    }
```
Keep the **property-based** ones (containment within `[box.x+inset, box.x+box.w-inset]`, off-area → no tile, min-clamp stays inside the cell, `hitWorkspace` centre/gap, `diffByAddress`) — they need no magic numbers, only the new `params`/`availW`. Verify the fullscreen test still FAILS if the `if (isFull)` branch is removed (t.h would clip to a small value).

- [ ] **Step 5: Run — expect PASS**

Run: `mise run test`
Expected: all logic tests pass (the smoke test + the reshaped `tst_layout` suite).

- [ ] **Step 6: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "feat(logic): adaptive fit-<=5-across + wrap + box-sized tiles"
```

---

## Task 2: `Overview.qml` — scrolling canvas, computed sizes, keyboard-into-view

Wires the new `logic.js` output into the view: pass `availW`, render the (bigger, wrapped) boxes inside a `Flickable`, and keep keyboard selection visible. Live-verified.

**Files:**
- Modify: `Overview.qml`

- [ ] **Step 1: Feed `availW` + params and consume `cell`/`groups`/`canvasSize`**

- Update `root.params` to the new shape (Conventions block).
- In `buildInput()`, add `availW: root.availCanvasW`. Add a reactive property
  `readonly property real availCanvasW: panel.width > 0 ? panel.width - 2 * card.pad - 16 : 1600`
  and re-run `rebuild()` when it changes (a `onAvailCanvasWChanged: if (opened) rebuild()`).
- In `rebuild()`, set `canvas.implicitWidth = res.canvasSize.w`, `canvas.implicitHeight = res.canvasSize.h`, and store `root.groups = res.groups`.

Property: `availW` is the card's **logical** width (from `panel.width`, not `screen.width·dpr`); cells resize when the panel width changes.

- [ ] **Step 2: Put the canvas in a `Flickable` and keep the selected box in view**

Wrap the existing `canvas` `Item` in a `Flickable` sized to the viewport (card interior minus the hint line), with `contentWidth/Height` bound to `canvas.implicitWidth/Height`, `boundsBehavior: Flickable.StopAtBounds`. Boxes and tiles stay children of `canvas` (the content item) so their coordinates are **content coordinates**.

Add `function ensureSelectedVisible()` that adjusts `flick.contentY` (and `contentX`) minimally so the selected box's rect is fully inside the viewport, and call it from `open()`, `moveSel()`, and after `rebuild()` re-derives the selection. Add a clamp: on `canvas.implicitHeight`/`Width` change, `flick.contentY = Math.max(0, Math.min(flick.contentY, flick.contentHeight - flick.height))` (same for X).

```qml
    function ensureSelectedVisible() {
        if (selectedIndex < 0 || selectedIndex >= boxes.length) return
        var b = boxes[selectedIndex]
        if (b.y < flick.contentY) flick.contentY = b.y
        else if (b.y + b.h > flick.contentY + flick.height) flick.contentY = b.y + b.h - flick.height
        if (b.x < flick.contentX) flick.contentX = b.x
        else if (b.x + b.w > flick.contentX + flick.width) flick.contentX = b.x + b.w - flick.width
    }
```

Property: after any arrow-nav or open, the selected box is fully within `[contentY, contentY+height]`; `Enter` therefore never acts on an off-screen box. On content shrink, `contentY/X` never exceeds `content − viewport`.

- [ ] **Step 3: Live-verify**

Copy over + restart, SUPER+P. Confirm (spec acceptance): tiles are visibly **bigger**; a monitor with >5 workspaces **wraps**; when content is taller than the screen the canvas **scrolls**; arrow-navigating to a workspace below the fold **scrolls it into view**; closing windows never leaves the view scrolled past the end. Report what you saw.

- [ ] **Step 4: Commit**

```bash
git add Overview.qml
git commit -m "feat(overview): Flickable canvas + computed sizes + keyboard scroll-into-view"
```

---

## Task 3: Monitor chips + focused accent (Overview.qml)

**Files:**
- Modify: `Overview.qml`

- [ ] **Step 1: Render a chip per group + focused accent**

Add a `Repeater` over `root.groups` inside `canvas` (above the boxes layer), each rendering a chip at `(modelData.x, modelData.y)`:

```qml
                Repeater {
                    model: root.opened ? root.groups : []
                    Rectangle {
                        required property var modelData
                        x: modelData.x; y: modelData.y
                        height: modelData.headerH - 4
                        radius: 4
                        readonly property color accent: root.selBackground
                        color: modelData.focused ? accent : "transparent"
                        border.width: 1
                        border.color: modelData.focused ? accent : root.borderColor
                        implicitWidth: chipText.implicitWidth + 12
                        Text {
                            id: chipText; anchors.centerIn: parent
                            text: modelData.monitorName
                            color: modelData.focused ? root.selText : root.foreground
                            opacity: modelData.focused ? 1.0 : 0.6
                            font.pixelSize: 11
                        }
                    }
                }
```

Property: every monitor group shows its name; the **focused** monitor's chip is filled with the theme accent (`Color.menu.selectedBackground`, via `root.selBackground`) while others are muted — so multiple monitors are always distinguishable by name, and the active one by colour. (Confirm `selBackground` reads as a distinct accent under a couple of themes; if it equals the background, switch to the nearest accent token.)

- [ ] **Step 2: Live-verify** — chip per monitor row; focused monitor's chip accented; readable across a theme switch (`omarchy theme next`). Report.

- [ ] **Step 3: Commit**

```bash
git add Overview.qml
git commit -m "feat(overview): monitor name chips + focused-monitor accent"
```

---

## Task 4: `WindowTile.qml` — rounded thumbnails + hover zoom + title label

**Files:**
- Modify: `WindowTile.qml`

- [ ] **Step 1: Round the thumbnail via `ClippingRectangle`**

Replace the square `clip: true` container's clipping with `Quickshell.Widgets.ClippingRectangle` (`import Quickshell.Widgets`) wrapping the `ScreencopyView`, `radius: 6`. Keep the icon-fallback layer and border. Property: the live thumbnail has **rounded** corners (not a square clip), and the icon fallback still shows when there's no handle/content.

- [ ] **Step 2: Hover zoom (mouse-only, no reflow) + title label**

Add a `title` property and a `HoverHandler`; rest scale at `0.95`, hovered at `1.05`, z-raised, one `Behavior`:

```qml
    property string title: ""
    property bool dragging: false      // set by Overview during a drag to suppress hover-zoom
    HoverHandler { id: hh; enabled: !tile.dragging }
    scale: hh.hovered ? 1.05 : 0.95
    transformOrigin: Item.Center
    z: hh.hovered ? 10 : 0
    Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutQuad } }
    // title label (bottom), fades in on hover
    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: lbl.implicitHeight + 4
        color: Qt.rgba(0,0,0,0.55); visible: hh.hovered && lbl.text.length > 0
        opacity: hh.hovered ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 100 } }
        Text { id: lbl; anchors.centerIn: parent; color: "#fff"; font.pixelSize: 10
               elide: Text.ElideRight; width: parent.width - 8
               text: tile.title.length ? tile.title : tile.cls }
    }
```

In `Overview.qml`, plumb the title: `buildInput` reads `o.title` into the window data; add `title` to the tiles `ListModel` rows (`applyTiles` append/set) and bind `WindowTile.title: model.title`; set `WindowTile.dragging: root.draggingAddress === model.address`. (Confirm `lastIpcObject.title` exists; fall back to `cls`.)

Property: hover scales **only** the hovered tile and raises it above neighbours with **no position/size reflow** of others; the drag `MouseArea`'s `z=99999` still wins; hover-zoom is suppressed while that tile is being dragged.

- [ ] **Step 3: Live-verify** — rounded thumbnails; hovering a tile pops it above neighbours without shoving them; title shows on hover; dragging a tile doesn't also hover-zoom it. Report.

- [ ] **Step 4: Commit**

```bash
git add WindowTile.qml Overview.qml
git commit -m "feat(tile): ClippingRectangle rounding + hover zoom + title label"
```

---

## Task 5: Drag polish — drop-target highlight, edge auto-scroll, unified teardown

The behaviourally-trickiest task (spec §Scrolling). All in `Overview.qml`. Live-verified — the acceptance cases here are the ones the old visual checklist would miss.

**Files:**
- Modify: `Overview.qml`

- [ ] **Step 1: Drop-target highlight in content coordinates**

Add `property int dropTargetWs: -1`. In the tile drag handler, on `onPositionChanged` (while dragging) compute the target from the tile's **content-coordinate** centre and set it; the boxes `Repeater` delegate renders an accent border/glow when `root.draggingAddress && modelData.workspaceId === root.dropTargetWs`.

```qml
        function updateDropTarget(tile) {
            var cx = tile.x + tile.width / 2, cy = tile.y + tile.height / 2   // content coords
            root.dropTargetWs = Logic.hitWorkspace(root.boxes, cx, cy)
        }
```
Call it from `onPositionChanged` and from a handler on `flick.contentY/contentX` changes (so a held pointer over scrolled content updates). On release, resolve the move from the **same** `updateDropTarget` result (not a fresh viewport-coord read).

Property: the highlighted box always equals where a release would drop; it updates when content scrolls under a stationary pointer.

- [ ] **Step 2: Edge auto-scroll during drag (reach off-screen workspaces)**

Suppress the Flickable's own gesture during a tile drag (`flick.interactive: !root.draggingAddress`). Add an edge-scroll `Timer` (repeat, ~16ms) active only while dragging: if the pointer is within an edge band of the viewport and content overflows that way, advance `flick.contentY`/`contentX` toward the edge **and** shift the dragged tile by the same delta so it stays under the cursor; then `updateDropTarget`.

```qml
    property real _dragViewportY: 0        // pointer Y within the viewport, updated onPositionChanged
    Timer {
        id: edgeScroll; interval: 16; repeat: true; running: false
        property Item tile: null
        onTriggered: {
            if (!root.draggingAddress || !tile) { stop(); return }
            var band = 48, step = 18, dy = 0
            if (root._dragViewportY < band && flick.contentY > 0) dy = -step
            else if (root._dragViewportY > flick.height - band &&
                     flick.contentY < flick.contentHeight - flick.height) dy = step
            if (dy !== 0) {
                var ny = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + dy))
                var applied = ny - flick.contentY
                flick.contentY = ny
                tile.y += applied          // keep tile under the cursor
                root.updateDropTarget(tile)
            }
        }
    }
```
Start it `onPressed` of a tile drag (setting `edgeScroll.tile`), stop it in teardown.

Property: a workspace scrolled off-screen can be reached by dragging toward the edge; the tile visually tracks the cursor during auto-scroll; no scroll happens when content doesn't overflow.

- [ ] **Step 3: Unified drag teardown (release, cancel, close)**

Add `function endDrag(tileItem)` that: clears `dropTargetWs` and `draggingAddress`, restores the tile's `z` and `x/y` `Qt.binding`s (the v2 restore), stops `edgeScroll`, and re-enables `flick.interactive`. Call it from the tile's `onReleased` (after computing the drop), from the rebuild path when the dragged address disappears (cancel), and from `close()`. `close()` becomes:
```qml
    function close() { if (root.draggingAddress) root.endDrag(null); reconcileTimer.stop(); settleTimer.stop(); opened = false }
```

Property: after any drag end — normal drop, the window closing mid-drag, or `Esc` — highlight, tile stacking/position, edge-scroll timer, and Flickable interactivity are all restored; nothing stays stuck.

- [ ] **Step 4: Live-verify (the review-driven cases)** — drag a tile to a workspace that's scrolled off-screen (auto-scrolls, tile tracks cursor, target highlights, drop lands right); the highlighted box updates when content scrolls under a held pointer; releasing / closing the dragged window / pressing Esc mid-drag each fully restore state (no stuck highlight, no frozen tile, scroll works again). Report each.

- [ ] **Step 5: Commit**

```bash
git add Overview.qml
git commit -m "feat(overview): drop-target highlight, edge auto-scroll, unified drag teardown"
```

---

## Task 6: Soft selection glow + centralized easing

**Files:**
- Modify: `Overview.qml`

- [ ] **Step 1: Centralized easing constants**

Add near `root`:
```qml
    readonly property var anim: ({ fast: 100, med: 160, easing: Easing.OutQuad })
```
Use it for the hover, selection, and drop-highlight `Behavior`s (durations/easing) so motion is uniform.

- [ ] **Step 2: Soft selection glow**

Give the selected/focused box a soft shadow/glow via `QtQuick.Effects` `MultiEffect` (`shadowEnabled: true`, a soft blur + accent `shadowColor`) applied to the box, or a blurred offset duplicate `Rectangle` behind it, plus an **animated** border (`Behavior on border.width/color` using `anim`). Glow on **boxes only** (few), not on every tile. Property: the selected box reads as lifted/glowing rather than a hard 3px outline; no visible per-tile cost.

- [ ] **Step 3: Live-verify** — selection looks softer/animated; theme switch still fine; no jank with many tiles. Report.

- [ ] **Step 4: Commit**

```bash
git add Overview.qml
git commit -m "feat(overview): soft selection glow + centralized easing"
```

---

## Task 7: Docs + version bump + final pass

**Files:**
- Modify: `manifest.json`, `DESIGN.md`, `ROADMAP.md`

- [ ] **Step 1: Bump version** — `manifest.json` `"version": "0.2.0"` → `"0.3.0"`.

- [ ] **Step 2: Docs** — add a short v3 Milestone A section to `DESIGN.md` (adaptive sizing/wrap, chips+accent, hover zoom, scrolling canvas + edge auto-scroll, teardown) and check the four items off in `ROADMAP.md` / the v3 ideas doc; note Milestone B still pending.

- [ ] **Step 3: Full verification** — `mise run test` (green), `omarchy plugin validate .` (exit 0), and a final live pass over the whole acceptance checklist in the spec (bigger tiles, wrap, chips, hover zoom, rounded thumbnails, narrow-screen no-overflow, drag-to-off-screen, keyboard scroll-into-view, scroll clamp, teardown). `mise run test-integration` (Tier 2 unaffected).

- [ ] **Step 4: Commit**

```bash
git add manifest.json DESIGN.md ROADMAP.md
git commit -m "docs: v3 Milestone A; bump to 0.3.0"
```

---

## Out of scope (Milestone B)
Semantic "animate from real position" motion, spring settle, in-workspace rearrange (floating reposition + tiled swap), per-monitor-aspect cells, empty-workspace wallpaper crops, tile-level keyboard navigation.
