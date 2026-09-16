# Omascape v3 Milestone A — design

Date: 2026-09-09 · Target: Omarchy Quattro, Hyprland 0.56.2, Quickshell 0.3.1 · builds on v2.
Status: **approved design, pre-implementation.** Ideas/priority: `docs/roadmap-v3-ideas.md`.

## Goal

Four improvements to the shipped v2 overview, keeping the shared-canvas / per-monitor-rows
identity and the pure-`logic.js` seam:

1. **Bigger tiles** via consistent-size cells that fit 5 across the screen and **wrap** beyond.
2. **Monitor distinction** — a name chip per monitor group + a theme accent on the focused one.
3. **Hover/select zoom** on window tiles (mouse hover only).
4. **Drag polish + style** — drop-target highlight during drag, rounded thumbnails, soft
   selection glow, centralized easing.

## Scope

**In:** the four features above.
**Out (Milestone B):** semantic "animate from real position" motion, spring settle,
in-workspace rearrange, per-monitor-aspect cells, empty-workspace wallpaper crops, tile-level
keyboard navigation.

## Feature 1 — bigger tiles: fit-5-across + wrap (`logic.js`)

Cells are a **consistent size** sized so 5 fit across the focused screen; a monitor with more
than 5 workspaces wraps into additional **sub-rows of ≤5** — cells never shrink to cram more in.

### Sizing (computed in `layout()`, was fixed `params.cellW/cellH`)
- `availW` is a new input = the canvas's available logical width (Overview passes
  `panel width − 2·cardPad − safety`).
- **Adaptive column count — 5 is a cap, not a floor.** `cols = clamp(floor((availW +
  cellSpacing) / (minCellW + cellSpacing)), 1, params.maxCols)` — as many minimum-width columns
  as actually fit, capped at `maxCols` (5). A narrow screen gets **fewer** columns (cells stay a
  consistent, legible size) instead of forcing 5 cells offscreen — 5 min-width cells + gaps need
  ~732 logical px, which a small display doesn't have, and vertical scroll can't fix a horizontal
  overflow.
- `cw = clamp((availW − (cols−1)·cellSpacing) / cols, minCellW, maxCellW)`.
- `aspect = focusedMonitorLogicalW / focusedMonitorLogicalH` (fallback 16/10);
  `ch = round(cw / aspect)` — cells are shaped like the focused monitor to **minimize**
  letterbox (see the aspect note under Feature-1 details), not eliminate it.
- Clamp values: `minCellW = 140`, `maxCellW = 380`.
- Degenerate case (`availW < minCellW`): `cols = 1`; if even one min cell exceeds `availW`, the
  canvas may also scroll horizontally (the Flickable is 2-D, below).

### Wrap + placement
- Monitor groups keep focused-first-then-by-x order (v2).
- Within a group, sort workspaces by id and **chunk into sub-rows of `cols`** (with `cols = 5`,
  8 workspaces → a sub-row of 5 then a sub-row of 3).
- Each **monitor group** has one header row (its chip, Feature 2) above its first sub-row; its
  sub-rows stack directly under it. Box `x = col·(cw+cellSpacing)`; `y` accumulates down through
  headers, sub-rows (`ch`), and spacings.
- `canvasSize.w` = widest actual sub-row; `canvasSize.h` = total stacked height. Cells carry
  `w:cw, h:ch`.

### `_tileRect` refactor
`_tileRect` currently reads `P.cellW/P.cellH` for the mini-map size. Change it to read
**`box.w`/`box.h`** instead, so tile mapping follows each box's actual (now computed) size. No
other tile math changes — bigger cells give bigger tiles for free. `hitWorkspace` is unchanged
(point-in-box over all boxes still resolves wrapped layouts).

### Aspect / letterbox note (clarification)
Cell aspect uses the **whole** monitor, but `_tileRect` fits the monitor's **usable rect**
(minus reserved bar) into the cell's **inset** area. Those two aspect ratios differ, so a small
letterbox remains **even on the focused monitor** — shaping cells to the monitor aspect only
*minimizes* it. This is accepted (the inset padding is intended); the sizing rule is not changed
to chase exact fit. Tests assert containment, not zero-padding.

### Scrolling & overflow (canvas is a `Flickable`)

The canvas lives inside a **`Flickable`** (`contentWidth/Height = canvasSize`), scrollable when
content exceeds the viewport — vertical is the normal case; horizontal only in the degenerate
narrow case above. Cells never shrink below `minCellW`.

**Coordinate rule (load-bearing).** Boxes and tiles are children of the Flickable's
`contentItem`, so all their positions — and every `Logic.hitWorkspace` call — are in **content
coordinates**. The dragged tile's position, the drop-target hit-test, and release all use the
same content-coordinate basis, so they agree regardless of scroll offset.

**Dragging to an off-screen workspace (resolves gap #2).** Scrolling is *not* disabled during a
drag (that would make a wrapped, off-screen destination unreachable). Instead:
- **Edge auto-scroll:** while a tile is being dragged, if the pointer is within an edge band of
  the viewport (top/bottom, and left/right if 2-D) and content overflows that way, a timer nudges
  the Flickable's `contentY`/`contentX` toward that edge.
- **Tile tracks the pointer:** when auto-scroll moves content, the dragged tile is shifted by the
  same delta so it stays under the cursor (its content-position advances with the scroll).
- **Highlight re-evaluates on scroll, not just on pointer move:** the drop-target
  (`root.dropTargetWs`) is recomputed whenever the pointer moves **or** `contentY/contentX`
  changes — so a stationary pointer over freshly-scrolled content updates the highlighted box.
- **Direct-manipulation Flickable during drag:** suppress the Flickable's own flick/drag gesture
  while a tile drag is active (`interactive: !dragging`) so the two gestures don't fight; edge
  auto-scroll is the only scroll source mid-drag.

**Keyboard selection stays visible (resolves gap #3).** `moveSel()` today only changes an index;
with scrolling that can select an off-screen box and `Enter` would act on an invisible one.
Require: on **open**, on every **arrow navigation**, and whenever the selected index is
re-derived in `rebuild()`, **scroll the selected box's rect fully into the viewport** (adjust
`contentY`/`contentX` minimally). Also **clamp** `contentY`/`contentX` to
`[0, contentSize − viewportSize]` whenever content shrinks (e.g. windows/workspaces close), so a
prior scroll offset can't leave the viewport past the end.

### `logic.js` input/param changes
- `input` gains `availW` (number, logical px).
- `params` gains `maxCols`, `minCellW`, `maxCellW`; drops the fixed `cellW`/`cellH` (now derived);
  keeps `cellInset, cellSpacing, rowSpacing, headerH (was rowLabelH), minTileW, minTileH`.
- `layout()` **output** gains `cell: { w, h, cols }` (the computed size) and
  `groups: [{ monitorName, x, y, headerH, focused }]` (one per monitor group, for the chips in
  Feature 2); boxes gain `monFocused`. `boxes`, `tiles`, `canvasSize` stay as v2.
- **Tier 1 tests** updated: existing box/tile cases re-expressed against computed `cw/ch`; new
  cases for (a) 5-across sizing from a wide `availW` with the clamps, (b) wrap at >`cols` into
  sub-rows, (c) `canvasSize` with wrapping, (d) `_tileRect` using `box.w/h`, and (e) **a narrow
  `availW` → `cols < maxCols` and `canvasSize.w ≤ availW`** (no horizontal overflow), incl. the
  degenerate `availW < minCellW` → `cols == 1`.

## Feature 2 — monitor distinction (`Overview.qml`)

- The header row (`headerH`, raised from 16 to ~22) renders a **monitor name chip** per group —
  a small rounded `Rectangle` with the monitor name (e.g. `eDP-1`), anchored at the group's
  top-left.
- **Accent:** the **focused monitor's** group gets the theme accent — the chip filled with the
  accent, plus a thin accent strip along the header. Non-focused groups get a neutral/muted chip
  (border color) and no strip. The chip name disambiguates multiple non-focused monitors.
- Accent token: the active Omarchy theme's accent (reuse `Color.menu.selectedBackground` or the
  nearest accent token; confirm the exact token during implementation). Neutral = `Color.menu.border`.

## Feature 3 — hover/select zoom (`WindowTile.qml`), QML only

- Tiles rest at `scale 0.95`; on **mouse hover** they animate to `1.05` and raise `z` above
  siblings (draws over neighbors, **no reflow** — position/size unchanged), via one
  `Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutQuad } }`,
  `transformOrigin: Item.Center`.
- On hover, a small **label** fades in at the bottom of the tile showing the **window title**
  (fallback: the app class). Title is view-only data — plumbed `buildInput` (`o.title`) → the
  tiles `ListModel` → a new `WindowTile.title` property. It does **not** go through `logic.js`
  (not layout-relevant), keeping the pure module unchanged for this. (Confirm `lastIpcObject`
  exposes `.title` during implementation.)
- Hover is a separate `HoverHandler` (or `hoverEnabled` flag) that must **not** interfere with
  the existing drag `MouseArea`; the drag's `z=99999` still wins over the hover z-raise.
- Keyboard navigation still targets workspace boxes, but is **no longer purely index-only**: it
  must scroll the selected box into view (see Scrolling & overflow → keyboard). No `logic.js`
  change → visual test only.

## Feature 4 — drag polish + style

- **Drop-target highlight during drag:** the tile's drag handler computes
  `Logic.hitWorkspace(boxes, cx, cy)` in **content coordinates** (§Scrolling) and sets
  `root.dropTargetWs`; the matching workspace box renders an accent border/glow while
  `root.draggingAddress` is set, re-evaluated on pointer move **and** on scroll.
- **Unified drag teardown (clarification):** a single teardown runs on **release**, on
  **cancellation** (dragged window disappears), and on **overview close** — clearing
  `dropTargetWs` and `draggingAddress`, restoring the dragged tile's `z` and its `x/y` bindings
  (the v2 `Qt.binding` restore), stopping the edge-scroll timer, and re-enabling
  `Flickable.interactive`. Never leave highlight, stacking, or scroll state stuck after a drag.
- **Rounded thumbnails:** wrap the `ScreencopyView` in `Quickshell.Widgets.ClippingRectangle`
  (radius + GPU clip, confirmed available in 0.3.1) — replaces the current square `clip: true`.
  Icon fallback stays layered as today.
- **Soft selection glow:** the selected/focused box gets a soft glow/shadow (`QtQuick.Effects`
  `MultiEffect` shadow, or a blurred offset duplicate) + an **animated** border, instead of the
  hard 3px outline. Glow on boxes only (few), not on every tile.
- **Centralized easing:** a small `readonly property var anim` (durations + easing) block in
  `Overview.qml`, applied uniformly to hover, selection, and the drop-highlight `Behavior`s.

## Architecture / components

- **`logic.js`** (pure) — sizing + wrap + placement; the only Tier-1-tested change.
- **`Overview.qml`** — passes `availW`; renders monitor headers/chips/accent; Flickable canvas;
  drop-target highlight; soft selection; easing constants.
- **`WindowTile.qml`** — hover zoom + label; `ClippingRectangle` rounding.
- No new files required. A tiny constants block (accents + easing) lives in `Overview.qml`.

## Testing

- **Tier 1 (CI):** the sizing/wrap/placement logic in `logic.js`, numeric — the only unit-tested
  part (see Feature 1 test list). Existing Tier 1 cases adjusted to computed cell sizes.
- **Visual / behavioral (live, by the user) — must include the review-driven cases the old
  checklist would miss:**
  - bigger tiles + wrap render correctly; monitor chips + focused accent; hover zoom doesn't
    reflow; rounded thumbnails; soft selection.
  - **Narrow screen:** on a small display the grid uses fewer columns and does **not** run off
    the right edge.
  - **Drag to an off-screen workspace:** dragging a tile toward the viewport edge auto-scrolls,
    the tile stays under the cursor, the highlighted target updates as content scrolls under a
    held pointer, and the drop lands on the highlighted workspace.
  - **Keyboard + scroll:** arrow-navigating (and opening) always scrolls the selected box into
    view; `Enter` never acts on an off-screen selection.
  - **Scroll clamp:** closing windows/workspaces so content shrinks never leaves the viewport
    scrolled past the end.
  - **Drag teardown:** releasing, the dragged window closing mid-drag, and pressing `Esc`
    mid-drag each fully restore highlight, tile stacking/position, and scroll interactivity.
- **Tier 2:** unaffected.

## Risks / gotchas

- **Flickable vs drag:** resolved in §Scrolling — `interactive:false` mid-drag so the Flickable
  doesn't steal the tile gesture, with **edge auto-scroll** as the only scroll source during a
  drag and the tile shifted by the scroll delta to stay under the cursor. The fiddly part is
  keeping tile position, hit-test, and highlight all in **content coordinates**; get that wrong
  and the drop lands on the wrong workspace after scrolling.
- **Hover vs drag on the same tile:** keep hover-scale (HoverHandler) and drag (MouseArea)
  independent so hover doesn't fight `drag.target`; verify hover-zoom is suppressed mid-drag.
- **`availW` units:** must be **logical** px (the card's coordinate space), not physical — derive
  from the panel/card width, not raw `screen.width·devicePixelRatio`.
- **ClippingRectangle composition:** confirm the icon-fallback layer and border still compose
  correctly inside the clip.
- **Accent token:** confirm the theme exposes a usable accent distinct from background/border.
- **`headerH` height bump** must be reflected in `canvasSize.h` and box `y` math (it's in logic).

## Sequencing (for the plan)

1. `logic.js` — computed sizing + wrap + `_tileRect` box.w/h + Tier 1 tests (green in CI).
2. `Overview.qml` — pass `availW`; Flickable canvas; render bigger wrapped boxes (verify live).
3. Monitor chips + focused-accent header.
4. `WindowTile` — `ClippingRectangle` rounding; hover zoom + label.
5. Drop-target highlight during drag + soft selection glow + centralized easing.
6. Docs + version bump (0.3.0) + live pass; Tier 2 re-run.
