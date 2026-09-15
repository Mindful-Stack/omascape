# Omyview — design (v1)

Date: 2026-09-06 · Omarchy 4.0.2 (Quattro) · Hyprland 0.56.2 · Quickshell shell

A Quickshell workspace overview for Omarchy, triggered by SUPER+P. Replaces the
dead v3 `workspace-picker.sh` (which relied on `walker`, removed in Quattro).

## Goal

Press SUPER+P to get a visual overview of all workspaces (grouped by monitor) and
jump to one — keyboard or mouse.

## Scope

**v1 (this design):**
- One overlay, on the **active monitor only**.
- Shows **every connected monitor's workspaces**, grouped into one boxed **row per
  monitor** (dynamic via Hyprland's workspace→monitor mapping). Docked → two rows
  (laptop eDP-1, external HDMI-A-1); undocked → collapses to just the laptop's row.
- **No dimming** (everything is on one screen).

**Deferred (v2, not now):**
- Rendering the overlay on *both* physical screens simultaneously, with the
  non-active monitor's section dimmed.
- Live pixel thumbnails per window (via Quickshell screencopy). Drops in per-window
  without changing the architecture. Zero idle cost (only captures while open), so
  safe to add later; kept out of v1 only to avoid the Hyprland toplevel-export
  dependency risk on the first build.

## Behavior

- **Trigger:** SUPER+P **toggles** the overlay (open *and* close), via `omarchy-shell
  shell toggle`. Esc, a scrim click (outside the rows), and selecting a workspace also
  close it. Verified 2026-09-06: the overlay uses *exclusive* keyboard focus so bare keys
  (numbers/arrows/Esc) reach it, **and** Hyprland still processes the SUPER+P keybind over
  that exclusive focus — so both coexist. (An earlier assumption that exclusive focus
  would swallow SUPER+P was disproved by testing; no on-demand-focus change needed.)
- **Cells:** one per workspace. Windows drawn as a **spatial mini-map** — each window a
  rounded box at its real relative position/size with the app icon (title if it fits).
  Focused workspace = accent border; empty = dimmed. `special:scratchpad` is excluded by
  default and shown as its own row on Ctrl+S (see the scratchpad spec).
- **`mode` setting** (one property, default `full`):
  - `full` — all pinned workspaces for each monitor, empties dimmed (stable positions).
  - `occupied` — only workspaces with windows.
- **Select:** number keys jump (1-9, `0`=10) · arrow keys move highlight + Enter ·
  mouse click · Esc cancels. Jump via Hyprland dispatch `workspace <id>` · type to find
  (fuzzy, class+title; Enter focuses the window) · Ctrl+S shows the scratchpad row (Enter on
  it brings the scratchpad up).
- **Styling:** pulls the active Omarchy theme (colors/fonts) so it matches the bar and
  re-themes automatically.

## Layout

```
              ACTIVE MONITOR (overlay, centered)
┌─ Laptop · eDP-1 ─────────────────────────────────┐
│  [1★]   [2]    [3]    [4]    [5]                  │
└──────────────────────────────────────────────────┘
┌─ External · HDMI-A-1 ────────────────────────────┐
│  [6]    [7]    [8]    [9]    [10]                 │
└──────────────────────────────────────────────────┘
              1-0 jump · click · Esc close
```

## Architecture / integration

- Omarchy-shell **user plugin**: `~/.config/omarchy/plugins/se.mindfulstack.omyview/`
  (`manifest.json` + `Overview.qml` + any JS helpers). Lives in the user config dir →
  survives `omarchy update`; hot-reloads on save (`omarchy-shell shell rescanPlugins`
  to force).
- Toggled via `omarchy-shell shell toggle se.mindfulstack.omyview`, bound to **SUPER+P** in
  `~/.config/hypr/bindings.lua` (replacing the walker picker line).
- Built on the shell's shared overlay (`Ui/Panel.qml`) + Hyprland service. Data:
  `Hyprland.workspaces` (each with `.toplevels` = its windows incl. geometry + app id,
  `.monitor`), `Hyprland.focusedWorkspace`, `Hyprland.focusedMonitor`.

## Resolved architecture facts (from shell sources)

- Surface = a `PanelWindow` (Quickshell.Wayland), **not** `Ui/Panel.qml` (that is only
  the IPC open/close lifecycle base). Mirror Clipboard's `PanelWindow`: fullscreen
  anchors, `color:"transparent"`, `WlrLayershell.layer: WlrLayer.Overlay`,
  `WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive`, `exclusionMode: Ignore`,
  a scrim `Rectangle` (`Color.menu.scrim`) + a scrim `MouseArea{onClicked: close()}`,
  and a focusable `keyCatcher` `Item{ focus:true; Keys.priority: BeforeItem }`.
- Clipboard sets no `screen:`, so we must: set the `PanelWindow.screen` to the
  Quickshell screen whose `.name` matches `Hyprland.focusedMonitor.name`, resolved when
  opening.
- Window geometry (`toplevel.lastIpcObject.at/size/class`) can be **stale** — call
  `Hyprland.refreshToplevels()` on open and bind to the resulting updates.
- Coordinates: window `at`/`size` are global **logical** px; monitor origin is
  `Hyprland monitor .x/.y` (logical), monitor logical size = physical/scale. Convert to
  monitor-local logical (subtract origin) before scaling into a cell. Real numbers:
  eDP-1 origin (0,1440), 2560×1600 @ scale 1.25 → 2048×1280 logical.

## Open implementation questions (resolve in the build plan)

- App-icon resolution from app id / class (find the shell's icon-lookup helper).
- Which dispatch form actually switches workspace from an overlay (`Hyprland.dispatch`
  vs shelling `hyprctl dispatch` with the lua `hl.dsp.focus` form the bar widget uses).

---

## v2 — live previews + drag-and-drop (2026-09-09)

v2 replaces the icon mini-map with live window thumbnails and adds drag-and-drop of windows
between workspaces. See `docs/specs/2026-09-08-omyview-previews-drag-drop-design.md` (design)
and `docs/plans/2026-09-08-v2-previews-drag-drop.md` (task-by-task build).

- **Shared canvas, per-monitor rows kept.** The card holds one non-clipped canvas with two
  sibling layers: workspace **boxes** (drop targets) and absolutely-positioned window **tiles**.
  Tiles are canvas-level siblings so one can be dragged across the whole surface onto any box.
- **Pure logic seam (`logic.js`).** All coordinate math, monitor-row ordering, the usable-rect
  window→tile mapping (one reference rect per monitor: `size − reserved`, letterboxed +
  centered; fullscreen fills it, others clip to it), `hitWorkspace`, and the address-keyed
  reconcile diff live in a dependency-free `.pragma library` module — unit-tested offscreen via
  `qmltestrunner` (Tier 1 CI). `Overview.qml` only wires Quickshell singletons to it.
- **Live previews (`WindowTile.qml`).** A `ScreencopyView` fed the wl `Toplevel` handle,
  resolved by joining `ToplevelManager.toplevels[].HyprlandToplevel.address` to the window's
  Hyprland address. `capMode` (`live`/`snapshot`/`icon`) with an icon fallback; captures run
  only while open. Cross-output live capture verified on Hyprland 0.56.2.
- **Drag-safe reconcile.** The tiles model is an address-keyed `ListModel` reconciled in place
  (never wholesale-reassigned), and the dragged address is never removed/replaced mid-drag —
  so the pointer grab and its `ScreencopyView` survive refreshes.
- **Silent move + reconcile.** On drop, `hl.dsp.window.move({ workspace, follow = false, … })`
  (typed dispatch in Hyprland Lua configuration mode; works via Quickshell and `hyprctl`),
  then `refreshToplevels()` and a bounded reconcile so the tile settles on real geometry.
- **Testing.** Tier 1 numeric unit tests (`logic.js`) in CI; Tier 2 nested-Hyprland integration
  (`tests/integration/move.sh`) asserts the silent-move semantics on a real, isolated Hyprland.

## Drag repair and polish (2026-09-09)

- Refresh each existing tile's floating role; changing a window from tiled to floating must
  immediately enable floating placement.
- Hold optimistic drop geometry per address until fresh client workspace/coordinates match.
  After 1.8 seconds, rejected moves return to compositor geometry. Separate grabs can have
  independent pending moves. A new grab supersedes its address's old pending destination.
- For floating workspace transfers, send position only after the target workspace appears
  in fresh client data. Coordinates are quoted global logical pixels, bounded by the full
  window's extent and the target monitor's usable area.
- Centralize release/cancellation/close cleanup. Tile stacking stays a declarative binding
  to dragging/hover state. A missing dragged client cancels the gesture on refresh.
- Edge scrolling ramps within 48 logical pixels of the viewport boundary. Content changes
  offset the held tile equally, keeping it under the pointer and updating the target highlight.
  Background refreshes no longer scroll back to the keyboard-selected workspace.
- Offscreen Qt tests cover real mouse events and binding restoration. The integration test
  exercises production Overview methods through real Quickshell in a disposable Lua session.

## Tiled drops replay a native drag-and-drop (2026-09-10)

Hyprland has no "insert this window next to that one" IPC, but its own drag-and-drop is not a
swap either: the dragged window is floated at drag start and simply **re-tiled at the cursor**
on release (`DragController` → `changeFloatingMode` → `DwindleAlgorithm::addTarget`, 0.56).
Dwindle then splits the node under the cursor (closest node by geometry when nothing is
under it, which also covers hidden workspaces) and picks the side by its smart-split rule:
the slope of (cursor − node centre) against the node's aspect ratio gives left/right for
shallow angles and top/bottom for steep ones.

Omyview replays exactly that in **one atomic Lua chunk** (Lua-config Hyprland evaluates a
`dispatch` payload as `hl.dispatch(<payload>)` and accepts a function; nothing renders in
between): float the window → move it silently to the target workspace if needed → warp the
cursor onto the anchor → un-float → restore the cursor. Two config values are overridden for
the duration and restored afterwards, even if a step throws: `dwindle:smart_split = true`, so the
side follows the cursor regardless of the user's `force_split`; and
`dwindle:use_active_for_splits = false` when the target is the focused monitor's active
workspace, so the anchor is the window under the cursor rather than the focused window (hidden
workspaces keep it on: dwindle already falls back to the closest node there). Focus is never
touched — focusing a window warps the cursor and would corrupt the drop point. The request is
sent as a single line: Quickshell's dispatch path drops multi-line requests silently.

The overview decides **what** to do, the compositor decides **where**. `Logic.tiledDropPlan`
picks the anchor (tile under the pointer, else the closest tiled tile in that box) and the
side by the smart-split rule (`Logic.dropSide`), and is the single eligibility check behind
both the drag preview and the release — what is highlighted is exactly what a drop does. The
Lua chunk receives the anchor's address and the side, not a point: floating the dragged window
detaches it and re-lays out the workspace (its neighbours grow into its slot), so any point
taken from the pre-drop layout can land on the wrong side of the anchor or in another window.
After the float, Lua reads the anchor's fresh `at`/`size` and warps the cursor to the midpoint
of the requested edge, inset by 2px; under the slope rule that edge midpoint always resolves to
that side. A global fallback point is used only when the destination has nothing tiled.
Two windows therefore swap; more get re-organised around the hovered window. A drop back onto
the window's own slot, a lone tiled window dropped into its own workspace, and grouped or
fullscreen windows do nothing (grouped/fullscreen cross-workspace drops still transfer), and
none of these previews an insertion. The tile holds the drop point until fresh geometry
differs from the pre-drop one.

**Drag ghost and pointer targeting.** In transit the tile scales to 0.6 around the grab point
(a `Scale` transform with its origin at the press position, so that point stays under the
pointer and the ghost never covers the highlight) at 0.6 opacity, both animated. Tiled
targeting — workspace hit, anchor tile and side — uses the pointer's canvas position (the
edge-scroll viewport point plus scroll offset), matching the native drag where the cursor
decides; the ghost's geometry is irrelevant to it. Floating placement still uses the ghost's
unscaled top-left, i.e. "the point you grabbed lands under the pointer". A re-grab during the
release animation (scale still ≠ 1) would displace the tile by (grab − oldOrigin)·(1 − scale)
when the origin moves; `WindowTile.beginGrab` offsets x/y by exactly that, so the grabbed point
never leaves the pointer.

Verified with real Quickshell on a nested Lua Hyprland: a lower window dropped at the upper
window's bottom edge of a vertical stack stays below it (the anchor doubles in height when the
window detaches), insert left of / above the hovered window on the active workspace, and right
of a window on a hidden workspace, with the active workspace, cursor and both config values
unchanged afterwards.

## Visual restyle (2026-09-10)

Tone steps instead of outlines, end-4 style: a borderless card with its own radius and a soft
`RectangularShadow` (`SoftShadow.qml`), workspace wells filled with the menu text colour at the
theme's `normalFillAlpha`, a large low-contrast numeral behind the windows, and one 2px accent
selection frame that follows keyboard selection only (it recedes during a drag and never moves
to the drop target). The drop cue is drawn above the previews: the tiled-insert half on the
anchor tile when there is one, otherwise an accent wash over the target well. Tiles rest at
scale 1 with only a 12 % hairline. Monitor chips are plain text; `Logic.layout` lays out their
header band only when more than one monitor has workspaces. The scrim is configurable via
`~/.config/omarchy/omyview.json` (`OmyviewConfig.qml`).
Design: `docs/specs/2026-09-10-restyle-design.md`. Motion is deferred to a follow-up spec.

## Workspace number badge (2026-09-10)

Each box carries a small number chip in its top-left corner, drawn above the previews (card
colour at 88 %, accent-filled for the focused workspace), so the 1–0 keys always have a visible
anchor. The big low-contrast numeral is kept for empty workspaces only.
Design: `docs/specs/2026-09-10-ws-badge-design.md`.

## Monitor groups and always-shown workspaces (2026-09-11)

Groups are ordered by the lowest workspace id each monitor holds (so 1..5 above 6..10) instead
of focused-first; opening the picker from the other screen never swaps them, and focus is shown,
not sorted. With more
than one group each group is inset (`groupInset`, 6 px) around its chip band and rows, and
`Logic.layout` returns the group's full bounds so the view can draw an 8 % accent backdrop behind
the focused monitor's group. The chip is a Nerd Font glyph — laptop for eDP/LVDS/DSI connectors,
external screen otherwise — plus the connector name. A single group keeps no band and no inset.
Each group's cells take the aspect ratio of their own monitor (cell width stays shared), so the
picture is identical whichever screen has focus and previews no longer letterbox inside a cell
shaped like the other monitor.

Hyprland only reports workspaces it has created (a `persistent:true` workspace whose monitor is
unplugged is destroyed once empty), so `Logic.padWorkspaces` fills ids `1..workspaces` (config,
default 10) as empty wells next to their numeric neighbours (the monitor of the nearest lower real
workspace, else the nearest higher; the focused monitor only when nothing real exists). They are
flagged `synthetic` and ignored by the group-order key, so neither placement nor order can change
with focus. Hyprland picks the real monitor when the workspace is created on jump or drop; the next
rebuild shows it. A config change to `workspaces` while open triggers an immediate rebuild.

## Theme polish (2026-09-10)

Typography comes from the shell (`Style.font.menuFamily`, `bodySmall`, `caption`) and the card
padding from `Style.space`, so the picker follows `omarchy display text size`. Empty wells sit one
tone step below occupied ones; floating windows cast a small `SoftShadow`; the key hints are key
caps with labels and can be switched off (`hint` in `~/.config/omarchy/omyview.json`). Cell gaps
tightened to 4/8. Design: `docs/specs/2026-09-10-theme-polish-design.md`.

## Window states: fullscreen and floating (2026-09-10)

Spec: `docs/specs/2026-09-10-window-states-design.md`; plan: `docs/plans/2026-09-10-window-states.md`.

- **Fullscreen windows are drawn in their tiled slot, not filling the cell.** Hyprland publishes
  only the fullscreen rect for such a window, but the other tiled windows on the workspace keep
  their geometry (fullscreen hides them without moving them), so `Logic.recoverSlot` derives the
  slot from what they leave uncovered: grid the usable rect on every window edge, seed on the
  uncovered cell with the largest minimum side (a gap strip only wins that if a gap is as thick as the slot's thinnest cell), grow while whole
  neighbouring columns/rows are uncovered, trim outer strips thinner than `slotGapTolerance`
  (defaults to 24 when the caller omits it) cumulatively per side — at most one gap band is lost
  off each edge, not one thin cell peeled off at a time. A lone fullscreen window still fills the
  cell; an ambiguous result draws as a backdrop below the tiled tiles; a floating fullscreen
  window is centred at 60%. Both modes (2 fullscreen, 1 maximized) are treated alike; `layout()`
  tiles carry a `layer` role (0 backdrop / 1 tiled / 2 floating) and a `fullscreen` role (the mode).
- **Badge.** A drawn corner glyph marks fullscreen/maximized tiles (hover label prefixed
  "Fullscreen ·"/"Maximized ·"). Its own `MouseArea` sits above the drag area with
  `preventStealing: true`, so a click never drags and a middle click on the badge is swallowed
  rather than closing the window; only a left click dispatches `Logic.unfullscreenLua` — one
  chunk, its toggle wrapped in `pcall`, that re-reads the window and toggles only if it is still
  fullscreen — with no focus change and the overview open. The badge hides optimistically
  (`pendingFullscreen`) until fresh data confirms or the 1.8s deadline returns it.
- **Drops.** Fullscreen windows are ordinary tiled peers. `tiledInsertLua` strips the target
  workspace's fullscreen window and the dragged window's mode *before* the float (so the anchor
  is measured in its tiled slot) and re-applies them after the un-float — the dragged window's
  own mode only for a same-workspace re-tile; cross-workspace it arrives tiled. A re-tile is
  acknowledged when the dragged window's workspace/geometry **or the anchor's geometry** changed,
  since an in-place re-tile of a fullscreen window ends in the same fullscreen rect.
- **Stacking.** A tile's own `z` is `tileLayer * 10 + hover` (`WindowTile`'s `tileLayer` property,
  seeded from the model's `layer` role — `Item` already owns a final `layer` property group, so
  the tile can't be named `layer` itself), dragging excepted: floating tiles always paint above
  tiled ones, and a hovered tiled tile never covers a floating one.
- **Focus/cursor bookkeeping.** Fullscreening a window on the *active* workspace leaves Hyprland
  0.56.2 with no active window (a hidden workspace's fullscreen leaves focus untouched instead),
  so every chunk that touches fullscreen — `unfullscreenLua`, and `tiledInsertLua`'s re-tile,
  which strips and re-applies fullscreen modes around the float/un-float — records the active
  window and cursor position first and restores them at the end via `Logic.restoreFocusLua`, which
  re-focuses only if the active window changed and always warps the cursor back; that
  dispatcher-can-drop-focus behaviour is what the probe script
  (`tests/integration/probe-fullscreen.sh`) established. Separately, `dwindle:preserve_split`
  defaults to `false`, under which dwindle re-derives a container's split axis from its aspect
  ratio on every recalculation — a fullscreen enter/exit is one — so a re-tile next to another
  window that is later un-fullscreened (or a re-tile of a fullscreen window) can come back split
  on the other axis; that is Hyprland's own behaviour, identical for a native drag.
- **Testing.** `tests/lua-check.sh` (`qml6` + `lua5.4`) parses every Lua chunk `logic.js`
  generates through a real Lua interpreter, as part of `mise run test`, so an unparseable chunk
  (silently dropped by the compositor otherwise) fails the build. `tests/integration/fullscreen.sh`
  runs 8 cases — a0 (exact focus/cursor/workspace check for a badge un-fullscreen on a hidden
  workspace), a (badge un-fullscreen is silent on the active workspace), four `b` cases (a drop
  onto each side of a fullscreen anchor), c (in-place re-tile of a fullscreen window keeps it
  fullscreen), and d (a fullscreen window dragged cross-workspace arrives tiled and splits its
  target) — checked against wall-clock acknowledgement bounds, not tick counts, since every poll
  is its own IPC round trip. The rig pins `dwindle:preserve_split = true` so split axes stay
  deterministic across the run.

## Motion (2026-09-10)

One vocabulary: a `motion` block on the Overview root owns every duration (fast 90 ms, normal
160 ms, enter 200 ms, exit 120 ms) and easing (`OutCubic` for movement, `OutQuad` for hover and
lift, a small-overshoot `OutBack` entrance); tiles receive it as a property. Policy: config
`motion` is `"auto"` (follow Hyprland `animations:enabled`, probed with `hyprctl -j getoption`
once per open, cached in `OmyviewConfig.hyprAnimations` and folded into the derived
`motionEffective`), `"full"` or `"off"` (every duration 0, every Behavior disabled). Open/close
are explicit animations; the `PanelWindow` stays mapped while `card.opacity > 0` and drops
keyboard focus the moment `opened` clears. Layout motion is `Behavior`s on tile, box, badge and
card geometry, gated on `root.layoutMotion` (motion on, the picker open, the entrance not
running, and the 300 ms open-settle window elapsed — so the first layout and the settle
rebuilds place rather than glide, including a rebuild fired while the surface is still
mapping, and reconcile rebuilds after close start no glide that could finish under the next
entrance). A tile's glide
runs on `targetX`/`targetY`, not on `x`/`y`: the grab detaches `x`/`y` with a plain write
(`beginGrab`) and the drag owns them, so a glide still in flight can never fight the pointer;
release parks the targets at the drop point and rebinds them to the model, which is the settle.
Boxes are a reconciled `ListModel`
(`applyBoxes`, keyed by workspace id) for the same reason tiles are: recreated delegates cannot
glide. `applyTiles`/`applyBoxes` compare a row before `set`, so an identical rebuild emits
nothing. Drop wash and insertion half fade in/out on `motion.fast` and keep their last
geometry while fading out; a window opened while the picker shows fades and scales its tile
in (`WindowTile.appear`, skipped during the entrance and the open settle); a closed window's
tile vanishes at once.
Give the layer a `no_anim` rule so the compositor does not fade it a second time (README).
Design: `docs/specs/2026-09-10-motion-design.md`.
