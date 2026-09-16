# Omascape — window states: fullscreen and floating (design)

Date: 2026-09-10 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1 ·
builds on v2 + Milestone A + the tiled-drop work on `drag-ghost`.
Status: **approved design, pre-implementation.**

## Goal

Make the overview treat a workspace with a fullscreen window as the tiled workspace it really is,
and make floating windows always visible on top of tiled ones.

1. **Fullscreen windows do not show as fullscreen.** The cell draws every window in the slot it
   occupies in the layout — the windows hidden behind the fullscreen one included — so the
   workspace can be read and re-tiled while the fullscreen window stays fullscreen.
2. **A badge marks the fullscreen window**, and clicking it turns fullscreen off without leaving
   the overview.
3. **Floating windows stack above tiled windows** in the cell, so a floating window dropped on
   (or already living in) a workspace with tiled windows is never hidden behind them.

## Scope

**In:** the three items above, for both Hyprland fullscreen modes (`fullscreen` 2 = fullscreen,
1 = maximized); drop rules for workspaces that hold a fullscreen window; tests.

**Out:** pinned windows (shown on every workspace), z-order *among* floating windows (stays model
order), making a window fullscreen from the overview, per-window fullscreen animations, and
`special:` workspaces (still excluded).

## Background facts (verified 2026-09-10 on the live session)

- Hyprland reports a fullscreen window's `at`/`size` as the fullscreen rect. Neither `hyprctl
  clients` nor the Lua `HL.Window` object exposes the pre-fullscreen geometry.
- The **other windows on that workspace keep their tiled geometry** while one is fullscreen —
  fullscreen only hides them; their dwindle nodes are untouched. On workspace 8 right now, Teams
  reports its tiled slot (x 0–825, full usable height) behind a fullscreen Chrome (mode 2).
  Un-fullscreening returns Chrome to exactly the rectangle Teams leaves uncovered.
- Hyprland allows one fullscreen window per workspace.
- Omarchy's SUPER+F is true fullscreen (mode 2); app maximize requests are suppressed by an
  Omarchy window rule, so mode 1 is rare here but is handled identically.
- Omarchy sets `misc:on_focus_under_fullscreen = 1`: focusing a window that sits under a
  fullscreen one makes Hyprland un-fullscreen the fullscreen window. That is compositor
  behaviour the overview does not fight (it only matters for a plain tile click, which already
  focuses + closes).
- The typed Lua dispatcher `hl.dsp.window.fullscreen({ mode, action })` exists on 0.56.2.
  **Verified 2026-09-10** (`tests/integration/probe-fullscreen.sh`, nested Lua Hyprland): it
  *does* accept a `window` selector — `hl.dsp.window.fullscreen({ window = sel, mode =
  "fullscreen", action = "toggle" })` fullscreens the named window while the focused window's
  own mode stays untouched, and a second identical call toggles it back off. **But the probe
  also showed `hyprctl activewindow` reporting `null` afterwards** (the named window was on the
  active workspace; the previously focused window lost focus). The dispatcher is therefore not
  focus-neutral on its own: every chunk that uses it records the active window and cursor first
  and restores both at the end if they moved. See "Dispatching fullscreen" below.

## Feature 1 — fullscreen windows drawn in their recovered slot (`logic.js`)

### The rule
A **tiled** window with `fullscreen > 0` is drawn in its **recovered slot**: the bounding box of
the part of the monitor's usable rect **not covered by the other tiled windows** on the same
workspace. Dwindle slots partition the usable rect, so that uncovered rectangle *is* the slot the
window returns to on un-fullscreen — derived from published data, not estimated. The other
windows are drawn from their real geometry, as today.

### `recoverSlot(R, others, P)` — new pure function
- `R` is the usable rect (`_usableRect(mon)`) and `others` the rects of the workspace's other
  **tiled, non-fullscreen** windows, converted to usable-rect-local coordinates and clipped to
  `R`. Floating windows never participate.
- **Grid.** Build the grid from the distinct x/y edges of `R` and every `other`; a cell is
  *covered* when any `other` contains it. Gap strips (between neighbours, and along `R`'s sides
  when `gaps_out > 0`) show up as thin uncovered cells; the slot shows up as one or more large
  uncovered cells (large because projected edges of other windows may split it).
- **Seed.** Pick the uncovered cell with the largest **minimum side**. A gap strip's minimum
  side is the gap, while the slot always owns a cell whose minimum side is a real window
  dimension, so the seed is always inside the slot — no knowledge of the gap configuration is
  needed, and no size threshold decides this step.
- **Grow.** Extend the seed rectangle one grid column/row at a time in each direction while the
  whole new column/row is uncovered; stop when any direction meets a covered cell. Directly
  adjacent gap strips are absorbed (padding); strips beyond a neighbour are not, because the
  neighbour blocks the way. Surviving outer strips can therefore never stretch the result to
  the whole rect.
- **Trim.** On each side, drop the outer band of grid columns/rows whose **cumulative**
  thickness stays below `P.slotGapTolerance` (24 logical px; no real slot is that thin, no sane
  gap is thicker). Cumulative, not per cell: thin projected-edge cells just inside the slot would
  otherwise be peeled one after another (a randomised sweep showed up to 45 px lost). At most
  `tol` px of a slot edge can be lost. This removes the absorbed gap padding so the tile matches
  its neighbours' inset. If the trimmed rect's minimum side is `<= slotGapTolerance`, or there
  was no uncovered cell at all, return `null` (ambiguous → the caller's backdrop fallback). A
  missing `slotGapTolerance` defaults to 24 so the null guard can never be disabled silently.
- Grouped (tabbed) windows share one geometry, so they neither break the partition nor the hole.

### Cases
| Situation | Tile rect | Stacking layer |
| --- | --- | --- |
| Fullscreen window, ≥1 other tiled window | recovered slot | tiled |
| Fullscreen window, no other tiled window | whole usable rect (as today) | tiled |
| Recovered slot is `null` (ambiguous or stale data, e.g. others cover everything) | whole usable rect | **backdrop** (below tiled) |
| Fullscreen window that is itself floating (`floating && fullscreen`) | centred, 60 % of the usable rect | floating |
| Non-fullscreen window whose geometry equals the whole output | unchanged: fills the usable rect (existing heuristic kept for unflagged windows) | tiled |

### `_tileRect` / `layout()` changes
- `input.windows[].fullscreen` becomes the **mode integer** (`o.fullscreen`, 0/1/2) instead of a
  boolean. All existing `!!win.fullscreen` truthiness keeps working.
- `_tileRect(win, mon, box, P, slot)` gains an optional `slot` (usable-rect-local rect). When
  given, it is used instead of the window's own geometry and the full-output shortcut is
  skipped. Everything else (scale `k`, offsets, min-size clamps, clipping) is unchanged.
- `layout()` groups tiled non-fullscreen windows per workspace once, then for each tiled
  fullscreen window calls `recoverSlot` and passes the result as `slot`. Floating fullscreen
  windows get the centred-60 % rect as `slot`.
- **Output:** each tile gains `layer`: `0` backdrop, `1` tiled, `2` floating; and
  `fullscreen` (the mode). `Overview.applyTiles` carries both into the `ListModel` roles
  (adds *and* updates, like `floating` today).

## Feature 2 — fullscreen badge (`WindowTile.qml` + `Overview.qml`)

### Look
- A small chip (≈16 px, rounded, theme background + border) in the tile's **top-right corner**,
  visible while the tile's `fullscreen` role is `> 0` and no un-fullscreen is pending.
- The glyph is **drawn** (four corner brackets from thin `Rectangle`s), so it needs no symbol
  font and no icon theme. Same glyph for both modes.
- The existing hover label reads `Fullscreen · <title>` / `Maximized · <title>` for such tiles.

### Click
- The badge has its **own `MouseArea` with `z: 1`**, above the drag area that Overview adds to
  every tile, so a badge press never starts a drag and never counts as a tile click.
- Clicking emits `unfullscreenRequested()` (the delegate knows its address); Overview dispatches the un-fullscreen chunk
  (below), records `pendingFullscreen[addr] = { mode: 0, deadline: now + 1800 }`, restarts
  `reconcileTimer`, and calls `scheduleRebuild()`.
- **No focus change, no workspace switch, overview stays open.** A plain click on the tile body
  still focuses the window and closes the overview, leaving fullscreen as it is.

### Optimistic state
- While `pendingFullscreen[addr]` exists the badge is hidden and the tile keeps its recovered
  slot (which is where the window lands anyway). `reconcileMoves` clears the entry once fresh
  data reports `fullscreen === pending.mode`, or at the deadline (rejected: badge returns).
- A new grab of the same address deletes its pending entry, matching `pendingMoves`.

### Dispatching fullscreen — one atomic Lua chunk, `Logic.unfullscreenLua(addr)`
The chunk re-reads the window and does nothing unless it is still fullscreen, so a stale click
is harmless:

```
function()
  local sel = "address:<addr>"
  local prevW, cur = hl.get_active_window(), hl.get_cursor_pos()
  <fullscreenBodyLua(sel, 0): re-read the window; toggle only if its mode differs>
  <if the active window changed: focus prevW again>   -- the probe showed focus can drop to nil
  <restore the cursor>                                 -- focusing warps it
end
```

`<toggle …>` had two candidate forms; **Task 1's probe (`tests/integration/probe-fullscreen.sh`,
run 2026-09-10) confirmed the preferred form works** on the nested Lua Hyprland (0.56.2):
1. **Preferred — this is what Task 2 implements:**
   `hl.dispatch(hl.dsp.window.fullscreen({ window = sel, mode = "fullscreen", action = "toggle" }))`.
   The typed dispatcher accepts a `window` selector the way `window.float` does: it fullscreened
   the named (non-focused) window, left the focused window's mode untouched, and a second
   identical call toggled it back off. Because the probe saw the active window drop to `null`,
   the chunk wraps the body with a focus + cursor save/restore (`hl.get_active_window`,
   `hl.get_cursor_pos`; re-focus by address only when the active window differs afterwards).
   `tiledInsertLua` gets the same focus restore next to its existing cursor restore.
2. **Fallback (not needed — kept here for reference):** if fullscreen only acted on the focused
   window, the chunk would instead remember the active workspace, focused window and cursor;
   `focus({ window = sel })`; toggle fullscreen; focus the previous window (or the previous
   workspace when there was none); restore the cursor. Same restore-even-on-throw pattern as
   `tiledInsertLua` (`pcall` + unconditional restore).

The same helper (`fullscreenBodyLua(sel, modeExpr)`) is reused by Feature 3 to strip and
re-assert fullscreen states inside `tiledInsertLua`.

## Feature 3 — drops on and of fullscreen windows (`Overview.qml`, `logic.js`)

Fullscreen tiled windows become **ordinary tiled peers** for every drop rule. The previous
"fullscreen ⇒ not tiled" exclusions in `tiledAnchorCandidates`, `submitDrop` and
`updateDropTarget` go away; only `floating` and `grouped` still exclude a window from the tiled
DRAG path; anchor candidates exclude floating and backdrop (`layer 0`) tiles (a grouped window's
tiled node can anchor). What is highlighted is still exactly what a drop does.

### `tiledInsertLua`: strip fullscreen first, re-apply last
The chunk measures the anchor's geometry inside the compositor *after* detaching the dragged
window. A fullscreen anchor would report the fullscreen rect there, so the chunk now runs in
this order, all inside the same atomic call:

1. Record the **target workspace's** fullscreen window and mode (`ws.fullscreen_window`,
   `ws.fullscreen_mode`), and the **dragged window's** own fullscreen mode.
2. Turn fullscreen **off** for both (they may be the same window), so every window on the
   workspace is laid out in its real tiled slot.
3. Float the dragged window → move it silently if the workspace differs → read the anchor's
   now-tiled `at`/`size` → warp the cursor to the requested edge → un-float. Unchanged.
4. Re-apply: the target workspace's recorded fullscreen window (if any) gets its recorded mode
   back; the dragged window gets its own mode back only for a **same-workspace** re-tile (in
   that case both records name the same window and it is re-applied once).
5. Restore config and cursor, as today, even if a step threw.

Outcomes:
- **Tiled drop into a workspace that has a fullscreen window.** Any tiled tile there can
  anchor, the recovered slot included; the highlighted side is the side the compositor uses.
  The workspace still opens fullscreen when you navigate to it.
- **Re-tiling the fullscreen window inside its own workspace.** Allowed and previewed like any
  tile. Net effect: still fullscreen, now in the new slot.
- **Dragging a fullscreen window to another workspace.** Same path; fullscreen is **not**
  re-applied, so it arrives as a normal tiled window at the drop point (accepted as simplest;
  also avoids fighting a fullscreen window the target workspace may already have).
- **Floating window dropped into a fullscreen workspace.** Unchanged silent move + position.
  Hyprland renders it beneath the fullscreen window until that ends; the overview still draws
  its tile on top (Feature 4). Noted, not fought.

### Acknowledging a re-tile
A same-workspace re-tile of a fullscreen window ends with the window reporting the **same
workspace and the same fullscreen rect**, so the existing "geometry differs from before" check
would hold the pending state until its 1.8 s deadline. The pending record therefore also stores
the anchor's pre-drop geometry (`before.anchor = { address, ax, ay, sw, sh }`, absent when the
anchor is `""`). `reconcileMoves` acknowledges a tiled insert when **any** of these holds in
fresh data: the dragged window's workspace changed; its geometry changed; the anchor's geometry
changed. Every successful insert splits the anchor, so the third condition clears the pending
state on the next refresh in the fullscreen case; the deadline remains the rejection path.

## Feature 4 — floating windows stack above tiled (`WindowTile.qml`)

- `WindowTile` gets `property int tileLayer` bound to the model role `layer` (backdrop 0, tiled 1,
  floating 2; the property cannot be called `layer` — QML `Item` owns a final `layer` group).
  Its z becomes `dragging ? 99999 : tileLayer * 10 + (hovered ? 1 : 0)`: hover
  raises a tile **within its layer only**, so a hovered tiled tile draws over its tiled
  neighbours but never over a floating tile. Dragging is the single global exception.
- Because `floating`/`layer` roles are refreshed on every rebuild (adds and updates), a floating
  window is on top the moment its drop is acknowledged, and a floating window created before its
  tiled neighbours is no longer hidden either.
- The tiles `ListModel` is **not** reordered (a model move would recreate delegates and break
  the drag-safe reconcile). Order among floating windows stays model order.

## Architecture / components

| Unit | Change |
| --- | --- |
| `logic.js` | `recoverSlot`, `_tileRect` slot override, `layout()` per-tile `layer`/`fullscreen`, `fullscreenBodyLua`, `restoreFocusLua`, `unfullscreenLua`, strip/re-apply fullscreen in `tiledInsertLua`, anchor geometry in the pending record, `params.slotGapTolerance` |
| `Overview.qml` | integer `fullscreen` in `buildInput`, new model roles, `pendingFullscreen` + reconcile, badge signal → dispatch, drop rules without fullscreen exclusions |
| `WindowTile.qml` | `tileLayer`, `fullscreen`, badge + its `MouseArea`, `unfullscreenRequested`, hover-label prefix |
| `DESIGN.md`, `README.md` | short sections describing the new behaviour and the badge |

## Testing

**Tier 1 (`tests/tst_layout.qml`, pure numbers):**
- `recoverSlot`: two windows (left/right); nested three-way split (left column split top/bottom,
  hole on the right); the same with `gaps_in 5 / gaps_out 10` (padding trimmed, result is the
  slot inset like its neighbours); **`gaps_out 40`, above `slotGapTolerance`** (surviving outer
  strips must not widen the result); the slot as the smallest window among six, split by
  projected edges (seed still lands in the slot); no others → `R`; others covering `R` →
  `null`; a window straddling `R`'s edge is clipped.
- `layout()`: fullscreen tiled window lands in the recovered slot with `layer 1`; lone fullscreen
  fills the usable rect; stale full coverage → usable rect with `layer 0`; floating fullscreen →
  centred 60 % with `layer 2`; floating window → `layer 2`; `fullscreen` mode carried through.
- `tiledInsertLua` output strips fullscreen **before** the float and re-applies it after the
  un-float (order asserted on the string), with the same-workspace/cross-workspace distinction
  for the dragged window; `unfullscreenLua` contains the `w.fullscreen == 0` guard; both are
  single-line.
- `reconcileMoves` acknowledgement: a pending tiled insert whose dragged window reports
  unchanged workspace and geometry is cleared when the anchor's geometry changed, and kept
  (until the deadline) when nothing changed.

**Tier 1 offscreen UI (`tests/ui`):** after a floating tile is dropped into a cell with a tiled
tile, the floating tile's `z` is above the tiled tile's; **a hovered tiled tile stays below an
un-hovered floating tile**; a badge press does not start a drag and emits
`unfullscreenRequested`; the badge hides while the pending entry exists and returns at the
deadline.

**Tier 2 nested Hyprland (`tests/integration`):** (a) badge un-fullscreen leaves the active
workspace, focused window and cursor unchanged and the window tiled in its old slot; (b) drops
onto **each of the four sides of a fullscreen anchor** land on that side and leave the anchor
fullscreen afterwards; (c) re-tiling the fullscreen window in its own workspace restores
fullscreen in the new slot and the pending state clears on the first refresh, not at the
deadline; (d) a fullscreen window dragged to another workspace arrives tiled at the drop point. Task 1 of the
plan settles the dispatcher form (preferred vs fallback) on this rig before anything else.

## Risks / gotchas

- **Dispatcher selector support** is the one open verification; the fallback keeps the feature
  buildable either way, at the cost of a longer chunk.
- The chunk assumes turning fullscreen off re-lays the workspace synchronously so the anchor's
  `at`/`size` are fresh before the float, the same assumption the float step already relies
  on (verified for float). Integration test (b) is the proof for the fullscreen step.
- `recoverSlot` needs no gap configuration: the seed rule cannot pick a strip and the grow rule
  cannot cross a neighbour. Gaps thicker than `slotGapTolerance` (24 px) merely survive the
  trim as padding; a slot thinner than that is reported as `null` → backdrop.
- Quickshell drops multi-line dispatch requests silently; every chunk stays single-line
  (existing `.replace(/\n\s*/g, ' ')` pattern).
- Fullscreening a window **on the active workspace** by selector leaves Hyprland (0.56.2) with
  **no active window**, and focusing another window on that workspace exits the fullscreen. So
  `restoreFocusLua` has nothing to hand back in that state (`prevW` is nil) and correctly does
  nothing; the invariant the chunks keep is "focus is unchanged", not "focus is a window".
  On a *hidden* workspace neither happens — focus and the active workspace stay put, which is
  what the badge and the drop chunks rely on (integration (a0)/(a)/(b)). Observed on Hyprland
  0.56.2 in the nested rig: once the active window is null and the overview's layer holds the
  keyboard grab, three focus dispatch forms in a row were no-ops (`focus({window})` twice, and
  `focus({workspace})` followed by `focus({window})`), so nothing can re-establish an active
  window until the overview closes. The exact "focus is still `a`" assertion is therefore only
  expressible for a fullscreen window on *another* workspace, which is case (a0). Note that
  neither (a0) nor (a) exercises `restoreFocusLua`'s re-focus branch — the toggle does not move
  focus in either situation — so what those cases prove is the invariant "focus unchanged", not
  the restore itself.
- `dwindle:preserve_split` defaults to **false**, and then dwindle re-derives a container's split
  orientation from its aspect ratio on every recalculation — a fullscreen enter/exit is one. So
  for a user running the default, a window re-tiled next to another and then un-fullscreened (or
  a re-tile of a fullscreen window) can come back split along the other axis — left/right becomes
  top/bottom on a tall container. That is Hyprland's own behaviour, identical for a native drag,
  and nothing the chunks can or should correct; `preserve_split = true` is the user-side cure.
  The fullscreen integration rig pins it so the assertions are about the code, not the shape of
  the nested output.
- The nested output in the integration rig takes the size of *its window in the host session*
  (the `hl.monitor` mode is advisory), so it is portrait in one run and landscape in the next.
  Geometry assertions there must be shape-independent: `fullscreen.sh` **measures** the anchor's
  tiled slot before fullscreening it rather than deriving it from the monitor rect (the border
  inset defeats complement arithmetic), and case (c) re-tiles the fullscreen window to the side of
  the anchor it is *not* already on — dropping it back where it is moves nothing, and an
  acknowledgement with no geometry change to observe can only come from the deadline.
- `restoreFocusLua` re-focuses after the fullscreen re-apply; with Omarchy's
  `misc:on_focus_under_fullscreen = 1`, re-focusing a window under a just-re-applied fullscreen
  window would exit it. Not reachable in the tested paths: a hidden target leaves `prevW`
  pointing elsewhere (not under the re-applied fullscreen window), and an active target leaves
  `prevW` nil (see the active-workspace bullet above), so the re-focus branch never fires against
  a live fullscreen window in the cases this suite covers.
- Mode 1 (maximized) round-tripping through `tws.fullscreen_mode` in `tiledInsertLua`'s re-apply
  step is unproven by integration — Omarchy suppresses maximize, so the nested rig cannot drive a
  window into that mode to exercise it. If `tws.fullscreen_mode` is not an integer, the re-apply
  falls back to `"fullscreen"`.
- Backdrop windows (`layer 0`) cannot be re-tiled inside their own workspace: their `own` slot is
  the whole cell (no other free area to move into), so a same-workspace drop of a backdrop window
  is a no-op — by design, not a bug.

## Sequencing (for the plan)

1. Verify the fullscreen dispatcher form on the nested rig; write `unfullscreenLua`/`fullscreenLua`.
2. `recoverSlot` + `_tileRect` slot override + `layout()` layers (Tier 1 tests first).
3. Model roles + `layer` z in `WindowTile` (Feature 4 lands here, with the UI test).
4. Badge + pending state + dispatch (Feature 2).
5. Drop-rule changes + `tiledInsertLua` guard + integration tests (Feature 3).
6. Docs.
