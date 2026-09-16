# Omascape v2 — live previews + drag-and-drop (design)

Date: 2026-09-08 · Target: Omarchy Quattro (4.x), Hyprland 0.56.2, Quickshell 0.3.1
Status: **approved design, pre-implementation**

## Goal

Bring Omascape's overview closer to [end-4's dots-hyprland overview](https://github.com/end-4/dots-hyprland):

1. **Live window previews** — each window drawn as a real, live thumbnail of its
   contents instead of an icon box.
2. **Drag-and-drop between workspaces** — grab a window tile and drop it on another
   workspace to move it there (silently, without switching to that workspace).

While keeping Omascape's identity: workspaces stay grouped into **one row per monitor**
(not end-4's flat rows×columns grid), and the overlay stays a single on-demand
`PanelWindow` on the focused monitor.

## Feasibility (confirmed, not assumed)

- **Screencopy works on Hyprland natively.** end-4 runs live thumbnails on Hyprland via
  Quickshell's `ScreencopyView` — no `hyprpm` / toplevel-export plugin. Our Quickshell
  0.3.1 ships `Quickshell.Wayland._Screencopy` (`ScreencopyView` with `captureSource`,
  `live`, `hasContent`) and `_ToplevelManagement` (`ToplevelManager`, `Toplevel`).
- **The capture handle ↔ Hyprland join:** iterate `ToplevelManager.toplevels`, read
  `toplevel.HyprlandToplevel.address`, and match to the window's Hyprland address. We
  already read geometry from `Hyprland.toplevels[].lastIpcObject` in v1, so we do **not**
  adopt end-4's `hyprctl clients -j` polling.
- **Silent move dispatch:** `hl.dsp.window.move({ workspace = N, follow = false, window =
  "address:0x…" })`. v1 already uses `hl.dsp.*` (`hl.dsp.focus`), so the typed dispatcher
  is known-good on our Hyprland.

The **one residual risk** — whether a *background / occluded* window captures real pixels
(vs. black) on our exact Quickshell/Hyprland versions — is settled by a step-0 spike below,
not by this design.

## Scope

**In:**
- Live-thumbnail window tiles with icon fallback.
- Drag a tile onto another workspace → silent move.
- Refactor: a dependency-free logic module (for testability, see Testing).
- Reserved-bar-area subtraction so tiles don't sit under the bar.
- Tier 1 unit tests (CI) + Tier 2 integration test (local).

**Out (deferred, explicitly YAGNI for v2):**
- Both-screens simultaneous render + non-active dimming (still a future item).
- Workspace **paging** (all workspaces shown in rows, as v1).
- Dragging to **reposition a floating window within** its own workspace (end-4 does this).
- **Rotated-monitor** (`transform`) handling.
- Full pointer-drag pixel e2e (Tier 3).

## Architecture

The overlay is unchanged at the shell level: a `PanelWindow` on the focused monitor with a
scrim, exclusive keyboard focus, and a centered card (v1's structure). What changes is the
**inside of the card**: v1's clipped per-cell mini-maps become a single **non-clipped
canvas** carrying two sibling layers.

```
card
└── canvas  (Item, non-clipped, size = logic.canvasSize)
    ├── boxes layer     Repeater over logic.boxes    → workspace Rectangle + number + DropArea
    └── tiles layer     Repeater over logic.tiles     → WindowTile (ScreencopyView + icon + drag MouseArea)
```

Tiles are **canvas-level siblings** drawn above the boxes, not children of a cell — that is
what lets a tile be dragged across the whole surface and dropped on any box. Box positions
still describe per-monitor rows, so visually it reads like v1; the windows just float on a
layer above and can cross boundaries.

### Components

**1. `logic.js` — a pure JS module, no Quickshell imports.**
A `.pragma library` JS module, imported by both `Overview.qml` and the test QML as
`import "logic.js" as Logic`. Given plain data, computes the layout. No side effects, no
singletons.

```
layout(input) -> {
  canvasSize: { w, h },
  boxes:  [{ workspaceId, monitorName, x, y, w, h, focused, occupied }],
  tiles:  [{ address, workspaceId, x, y, w, h }],   // canvas-absolute
}

hitWorkspace(boxes, px, py) -> workspaceId | null    // point → drop target

input = {
  monitors:   [{ name, x, y, width, height, scale, reserved:[l,t,r,b], transform }],
  workspaces: [{ id, monitorName, focused, occupied }],
  windows:    [{ address, cls, ax, ay, sw, sh, workspaceId, floating, fullscreen }],
  focusedMonitorName: "eDP-1",
  params:     { cellW, cellH, cellInset, cellSpacing, rowSpacing, rowLabelH, minTileW, minTileH }
}
```

Responsibilities: row grouping by monitor (rows ordered `focusedMonitorName` first then by
monitor `x`), box placement, the coordinate mapping below, and skipping `id < 0` / special
workspaces.

### Coordinate mapping (one reference rectangle, per monitor)

**All lengths are monitor *logical* pixels** (physical ÷ `scale`). Hyprland `at`/`size` are
global logical px; `reserved:[l,t,r,b]` are logical insets. Rotated monitors (`transform`
odd) are out of scope for v2 and left unmapped.

1. **Monitor logical size:** `monLogW = width/scale`, `monLogH = height/scale`.
2. **Usable rectangle `R`** — the single reference rect everything derives from, in
   monitor-local logical coords:
   - `R.x = reserved.l`, `R.y = reserved.t`
   - `R.w = monLogW − reserved.l − reserved.r`, `R.h = monLogH − reserved.t − reserved.b`
3. **Mini-map area inside a cell:** `mmW = cellW − 2·inset`, `mmH = cellH − 2·inset`.
4. **Fit `R` into the mini-map (letterbox), with centering:**
   - `k = min(mmW / R.w, mmH / R.h)`
   - `offX = inset + (mmW − R.w·k)/2`, `offY = inset + (mmH − R.h·k)/2`
5. **Per-window tile rect.** Convert the window to monitor-local logical, *relative to `R`'s
   origin*: `wx = (win.ax − mon.x) − R.x`, `wy = (win.ay − mon.y) − R.y`; `ww = win.sw`,
   `wh = win.sh`. Then classify:
   - **Fullscreen** (`win.fullscreen` true, or geometry ≈ full output within 1px): the window
     covers the whole output including under the bar, so its raw rect pokes above `R`. Render
     it to **fill `R` exactly** — tile = `(box.x+offX, box.y+offY, R.w·k, R.h·k)`. This is the
     explicit fullscreen-vs-usable distinction.
   - **Inside/overlapping `R`:** clip the window rect to `R` (`intersect([wx,wy,ww,wh], [0,0,R.w,R.h])`);
     if the intersection is empty, **skip the tile**. Otherwise map the *clipped* rect:
     `tileX = box.x + offX + cx·k`, `tileY = box.y + offY + cy·k`, `tileW = cw·k`,
     `tileH = ch·k` (with min-size clamps for visibility). Clipping keeps every tile inside its
     box so nothing bleeds into the row gap on the non-clipped canvas.

`k`, `offX/offY`, and the clip all come from `R` alone — one rectangle, no second reference
frame. This block is the whole coordinate-math surface and the whole Tier 1 test surface.

`hitWorkspace` is the pure point→box test used by Tier 1; the live view can rely on each
box's `DropArea` for hover feedback and use `hitWorkspace` as the authoritative drop
resolver so gesture and tests agree.

**2. `Overview.qml` — the view.** Wires Quickshell singletons to the logic and renders.
- Builds `input` from `Hyprland.workspaces`, `.monitor`, `lastIpcObject`, `monitor.reserved`.
- Builds `handleByAddress` (`address → wl Toplevel`) from `ToplevelManager.toplevels`, and
  **keeps it live**: rebuilds when toplevels are added/removed while open (bind to
  `ToplevelManager.toplevels` changes) so new windows gain previews and closed ones release
  captures.
- Calls `logic.layout(input)`; renders boxes + a **tiles model keyed by `address`** (see
  drag safety below — reconciled in place, not reassigned wholesale).
- Owns interaction (keyboard, click, drag) and dispatch. Keeps v1's open/close/refresh,
  focused-screen targeting, number/arrow/Enter selection, Esc/scrim close.

**3. `WindowTile` (inline component or `WindowTile.qml`).** One window; stable per `address`.
- `ScreencopyView { captureSource: (root.opened && handle) ? handle : null; live: (capMode === "live") }`
  where `capMode` (`"live"｜"snapshot"｜"icon"`) is the per-case strategy the spike selects (§Step 0) — a tile on an
  inactive workspace may use snapshot instead of `live`.
- App-icon overlay (`Quickshell.iconPath(cls.toLowerCase(), true)`), small in a corner;
  centered/enlarged when the tile is very small (end-4's `compactMode`).
- Rounded corners via `layer.effect: OpacityMask` over a rounded mask (end-4's approach).
- **Fallback:** show the icon box (v1 look) when there is no handle, or when capture is not
  usable for this tile per the spike rules. Note `hasContent` only means *a buffer arrived* —
  it does **not** prove the frame is non-black or updating, so it gates readiness only, never
  correctness; a tile whose class the spike marked black/frozen uses the icon (or snapshot)
  path by policy, not by inspecting `hasContent` at runtime.
- `MouseArea` with `drag.target: tile`, `z` raised while dragging; click / middle-click.

## Data flow

```
open()
  → Hyprland.refreshMonitors() / refreshToplevels()
  → build input {monitors, workspaces, windows}  (from Hyprland singletons + lastIpcObject)
  → build handleByAddress  (from ToplevelManager.toplevels[].HyprlandToplevel.address)
  → logic.layout(input) → {boxes, tiles, canvasSize}
  → reconcile tiles model by address (see below); each tile looks up handleByAddress[address]

refresh (on Hyprland toplevel/workspace events + ToplevelManager changes, while open)
  → rebuild input + handleByAddress + layout → reconcile tiles model by address
```

### Tiles model: keyed by address, reconciled in place (drag safety)

The tiles are **not** a plain array reassigned on every rebuild — reassigning a `Repeater`
model destroys and recreates delegates ([Qt Repeater docs](https://doc.qt.io/qt-6/qml-qtquick-repeater.html)),
which would tear down the tile holding the pointer grab mid-drag and drop the gesture (and
needlessly rebuild every `ScreencopyView`). Instead the model is **keyed by window
`address`** and reconciled: add rows for new addresses, remove rows for departed ones, and
update `x/y/w/h/handle` on surviving rows **in place**, so a window that persists keeps its
delegate (grab intact, capture uninterrupted).

**Hard rule during an active drag:** while `dragging`, the reconcile never removes or
replaces the dragged `address`'s row; other rows may still update. If a full rebuild would be
disruptive, it is **coalesced** and applied once on release. Cancellation paths:
- **Dragged window disappears** (address leaves the window set): cancel the drag — release the
  grab, no dispatch, remove the now-orphaned tile on the next reconcile.
- **Overview closes mid-drag** (Esc/scrim/lost focus): cancel the drag, then close; nothing is
  dispatched.

### Post-move reconciliation (not just a timer)

`lastIpcObject` is a *cached* object; waiting and re-reading it can return the same stale
geometry indefinitely. So after a drop dispatches `hl.dsp.window.move`:
1. **Optimistic:** immediately move the tile to the target box and mark it
   `pending{ address, targetWs }` (instant feedback).
2. **Request fresh data:** call `Hyprland.refreshToplevels()` (and `refreshWorkspaces()`) —
   an explicit refresh, not a passive wait ([Quickshell Hyprland API](https://quickshell.org/docs/v0.3.0/types/Quickshell.Hyprland/Hyprland/)).
3. **Reconcile on arrival:** when refreshed data shows `windowByAddress[address].workspaceId
   === targetWs`, clear `pending` and re-layout from real data (authoritative position).
4. **Bounded recovery:** retry step 2 up to `K` times with backoff (a timer *bounds* the
   wait, it is not the mechanism). If still unreconciled — move failed, or the window closed —
   drop the optimistic override and re-layout from whatever real data says (the tile lands
   where Hyprland actually has it, or is removed). The tile is never left pinned to an
   optimistic position forever.

## Interaction model

| Action | Effect |
| --- | --- |
| **Drag tile → drop on another workspace box** | `hl.dsp.window.move({ workspace = N, follow = false, window = "address:ADDR" })` (silent). **Overview stays open.** Tile shows optimistically at the target, then reconciles to real geometry (§Post-move); drop on same/none → snap back. |
| **Left-click tile** | `hl.dsp.focus({ window = "address:ADDR" })` + close overview. |
| **Middle-click tile** | `hl.dsp.window.close({ window = "address:ADDR" })`. |
| **Click empty workspace box** | `hl.dsp.focus({ workspace = N })` + close (v1). |
| **Number / arrows / Enter** | Jump / move highlight / select (v1, unchanged). |
| **Esc / scrim click** | Close (v1, unchanged). |

Drag detail: on press set `dragging = true`, `Drag.active`, hotspot to cursor, and record the
source workspace + dragged `address`; box `DropArea`s give hover feedback, but the drop target
is resolved authoritatively by `logic.hitWorkspace` (so gesture and Tier 1 tests agree). On
release, dispatch only if the target differs from the source (else snap back), run the
post-move reconciliation, and clear `dragging` (which applies any coalesced rebuild). See
§drag safety for the mid-drag disappearance/close cancellations.

## Step 0 — screencopy spike (gates the build)

A throwaway `qs -p spike/shell.qml` (kept out of the plugin) that renders `ScreencopyView`s
on our Quickshell 0.3.1 / Hyprland 0.56.2. An occluded window on the *active* workspace is
only the easy case — this overview shows windows the compositor is **not currently
presenting** (other workspaces, other monitors), which is exactly where per-toplevel capture
tends to degrade. All of these cases must be checked **before** choosing live capture:

| # | Case | Notes |
|---|------|-------|
| A | Occluded window, **active** workspace | baseline |
| B | Window on an **inactive** workspace (not visible) | the common overview case |
| C | Window on **another monitor** | docked; if no external available, mark *unverified-when-docked*, don't claim pass |
| D | Window with **animating content** (video / blinking cursor) | detects frozen first-frame-only capture |

**Verification method — `hasContent` is not a correctness signal.** Per the
[ScreencopyView docs](https://quickshell.org/docs/v0.3.0/types/Quickshell.Wayland/ScreencopyView/),
`hasContent` means a buffer arrived — it does **not** prove the frame is non-black or
updating. So the spike judges each case by:
- **not-black:** sample pixels of the captured frame; a uniformly black/empty frame fails.
- **live vs frozen:** for case D, capture two frames a short interval apart and compare — if
  identical while the source is animating, capture is frozen (snapshot-grade, not live).

**Record the outcome and fallback per case** (a table in the implementation plan), because
behaviour can differ by case and the plugin can therefore mix strategies per tile:

| Result for a case | Strategy for tiles in that situation |
|---|---|
| live, non-black | `live:true` tile |
| non-black but frozen | **snapshot-on-open** (`live:false` + `captureFrame()`) — a static thumbnail is still useful |
| black / no usable frame | **icon tile** (v1 look) |

`WindowTile.capMode` is chosen from these per-case rules (e.g. keyed on whether
the window's workspace is currently visible). **Drag-and-drop ships regardless** — it does not
depend on capture. The spike is deleted before v2 lands; its result table goes in the plan.

## Testing

**Tier 1 — pure-logic unit tests (CI, offscreen, no compositor).** Confirmed available:
`qmltestrunner`, the `QtTest` QML module, and the `offscreen` QPA plugin are all installed.
Tests load `logic.js` (no Quickshell imports) and assert on `layout()` / `hitWorkspace()`
with **exact numeric expectations** (the coordinate mapping is the point):
- **Usable-rect origin:** a window at the usable-area top-left (`ax=mon.x+reserved.l`,
  `ay=mon.y+reserved.t`) maps to exactly `(box.x+offX, box.y+offY)` — *not* offset by the
  reserved amount, and *not* at the bare inset.
- **Fullscreen vs usable:** a window flagged fullscreen (spanning the whole output, poking
  above `R`) fills `R` exactly (`box.x+offX, box.y+offY, R.w·k, R.h·k`); an identical-geometry
  window *not* flagged fullscreen is clipped to `R` instead. Assert the two differ.
- **Fractional scaling:** scale `1.25` and `1.5` (e.g. 2560×1600@1.25 → 2048×1280 logical);
  assert `k`, `offX/offY`, and a sample window's tile rect to the pixel.
- **Unequal aspect ratios:** an ultrawide monitor (usable `R` wider than the cell's `mm`
  aspect) letterboxes with vertical centering (`offY>inset`, `offX≈inset`); a tall `R` does
  the opposite. Assert the centering axis and magnitude.
- **Clipping:** a window straddling the reserved edge is clipped to `R` (tile origin at the
  box inset edge, reduced size); a window fully outside `R` yields **no tile**.
- **Rows/order:** two monitors → two rows, `focusedMonitorName` first then by `x`; a window on
  monitor 2 lands in row 2's band.
- **`hitWorkspace`:** correct workspace for points inside each box, `null` in the gaps/labels.
- **Edge cases:** empty workspace (box, no tiles), `id < 0` skipped, min-size clamp applied to
  a tiny window.

Runs via `QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/` in GitHub Actions on push.

**Tier 2 — headless-Hyprland integration (local target, e.g. `just test-integration`).**
Hyprland ships the headless backend; `foot` (test client) and `wtype` are installed. The
test: start Hyprland headless in a nested session, spawn two `foot` clients on different
workspaces, dispatch the **drop's effect** — `hl.dsp.window.move({ workspace = N, follow =
false, window = "address:ADDR" })` — then assert `hyprctl clients -j` shows the window on
workspace N and that the **active** workspace did **not** change (proves `follow = false`).
This validates the exact dispatch syntax + address targeting on real Hyprland. It does not
drive the mouse gesture; it covers everything downstream of "released over workspace N."

**Not covered by tests (honest boundary):** whether a live preview shows real pixels of a
background window is GPU/screencopy-dependent and not reliably assertable in headless CI —
that stays the step-0 spike (cases A–D) plus the per-case capture/fallback policy it produces.
Full pointer-drag pixel e2e (Tier 3) is out of scope (needs `ydotool`, flaky, low marginal
value).

## Risks & gotchas (from end-4 + v1)

- **Occluded / inactive-workspace / other-monitor capture** — the step-0 spike gates this
  across cases A–D; per-case fallbacks defined (§Step 0).
- **`hasContent` ≠ correctness** — it gates readiness only; black/frozen frames are handled by
  policy from the spike, not by trusting `hasContent` at runtime.
- **Capture perf** — `captureSource: null` when closed so screencopy never runs idle.
- **Coordinate mapping** — one usable rect `R` per monitor drives scale/centering/clip;
  fullscreen windows fill `R`, others clip to it. Rotated monitors (`transform`) deferred.
- **Drag vs model churn** — reconcile the tiles model by `address` and never remove/replace the
  dragged row; coalesce rebuilds until release; cancel on window-gone / overview-close.
- **Post-move staleness** — `lastIpcObject` is cached; a timer alone can reread stale data
  forever. Explicitly `refreshToplevels()` and reconcile when real data shows the new
  workspace, with bounded fallback to real geometry (§Post-move).
- **Handle-map freshness** — rebuild `handleByAddress` on toplevel add/remove while open.
- **QML reload** — editing `Overview.qml` needs `omarchy restart shell`, not just rescan.
- **Special/lock workspaces** — skip `id < 0` (v1 already does).

## File / repo changes

```
Overview.qml            (rewritten: canvas + boxes + tiles + DnD)
logic.js               (new: pure layout/join/hit-testing)     ← Tier 1 target
WindowTile.qml          (new, optional: per-window preview tile)
tests/tst_layout.qml    (new: QtTest cases over logic.js)
justfile                (new: `test`, `test-integration` targets)
.github/workflows/ci.yml(new: Tier 1 on push)
manifest.json           (version → 0.2.0)
DESIGN.md / ROADMAP.md  (updated to reflect v2)
```

`manifest.json` gains no new entry points (still `overlay: Overview.qml`); the logic module
and tile are plain imports, not manifest-declared.

## Sequencing (for the implementation plan)

1. Step-0 screencopy spike across cases A–D → record result table, pick per-case capture policy.
2. Extract `logic.js` from v1's `monitorRows()`: usable-rect mapping, canvas-absolute tiles,
   fullscreen/clip handling, `hitWorkspace`.
3. Tier 1 tests (numeric, incl. fullscreen/fractional-scale/unequal-aspect/clipping) + CI green.
4. Rewrite `Overview.qml` to the canvas/boxes/tiles structure with the address-keyed,
   reconciled tiles model (still icon tiles) + live `handleByAddress`.
5. Add `WindowTile` previews per spike policy + reserved-bar subtraction.
6. Add drag-and-drop: `dragging` guard + cancellation, dispatch, post-move
   `refreshToplevels()` reconciliation with bounded recovery.
7. Tier 2 integration target.
8. Update `DESIGN.md` / `ROADMAP.md`, bump version, manual multi-monitor pass.
