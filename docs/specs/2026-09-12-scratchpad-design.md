# Omyview — scratchpad row (design)

Date: 2026-09-12 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1 ·
builds on find (`main` at `4382847`).
Status: **approved design, pre-implementation.** Branch `scratchpad`.

## Goal

Show Omarchy's scratchpad (`special:scratchpad`, which holds e.g. Bitwarden and Spotify) in the
overview on demand, as its own row below the workspaces, hidden by default. It is a real box:
selectable, a drag target, searchable while shown, and later lockable.

## Scope

**In:** a per-summon toggle (Ctrl+S), a trailing layout group for the scratchpad, Enter/click
that brings the scratchpad up, drops onto it, find over its windows while shown, the sentinel
audit that makes a negative workspace id legal, tests.

**Out:** other special workspaces (the unnamed `special` only ever holds transient share
popups), persisting the shown state across summons, a config key for the default, a number
key for the scratchpad, tiled insertion into the scratchpad.

## Decisions (brainstorm 2026-09-12)

- **Hidden on every open.** Ctrl+S shows the row for this summon only. Bare letters type into
  find, so the toggle is a chord; it works with or without a query.
- **Enter / box click = bring the scratchpad up and close.** Same effect as SUPER+S when the
  scratchpad is hidden; guarded so it never *hides* an already-visible scratchpad.
- **Drops land as a plain silent move and keep their tiling state.** The tiled-insert plan is
  bypassed explicitly for the scratchpad target (not merely "no anchor found"): a floating window
  is moved and positioned, a tiled window is moved and stays tiled — Hyprland tiles it in the
  scratchpad's own layout, and the overview renders whatever geometry Hyprland then reports.
  Floating it explicitly was rejected: it would resize and reposition the window unpredictably,
  and a tiled scratchpad window drags back out through the normal tiled-insert path anyway.
- **Find matches scratchpad windows only while the row is shown.** Shown windows are in the
  layout input like any other; hidden ones are not.
- **Only `special:scratchpad`.** One row, one workspace.
- **An empty scratchpad still shows its row** when toggled: it is still a place to drop
  windows.
- **First-class box (approach A).** The scratchpad flows through the existing box/tile pipeline
  so thumbnails, drag, find, the selection frame and the future lock treat it uniformly. The
  cost is an audit of the "negative id means none" checks.
- **The overview's id for the scratchpad is a constant.** Hyprland allocates special-workspace
  ids dynamically (`WorkspaceQueryCore.cpp`: the next free id below -99), so the reported id is
  not stable across sessions or even across the scratchpad emptying and refilling. `buildInput()`
  identifies the scratchpad **by name** and remaps its reported id, and the `workspaceId` of
  every window on it, onto `Logic.SCRATCHPAD_ID = -2`. Everything downstream — boxes, tiles,
  selection, pending drops — keys on -2, so a synthetic empty row and a real scratchpad have the
  same id and there is no transition to handle. Dispatches use the name (`special:scratchpad`),
  never the id. -2 cannot collide: regular ids are ≥ 1, -1 is the "none" sentinel, and Hyprland's
  special ids are ≤ -99.

## Behaviour

| Key / action                    | effect                                                                 |
|---------------------------------|------------------------------------------------------------------------|
| Ctrl+S                          | toggle `scratchpadShown` (any query state); rebuild                    |
| digits                          | never target the scratchpad                                            |
| arrows                          | reach it spatially (it is the bottom row); with a query, only if a window in it matches |
| Enter on the scratchpad box     | dispatch the guarded show chunk (below), close                         |
| click on the empty box          | same as Enter                                                          |
| click on a tile in the row      | focus that window AND raise it by address with `alter_zorder({ mode = "top", window })` (`scratchpadFocusLua`): focus alone raises the scratchpad but leaves a floating window under its last-raised sibling, and `bring_to_top` acts on the active window, which the focus may not have made active yet |
| drop a window on the box        | `hl.dsp.window.move({ workspace = "special:scratchpad", follow = false })`, plus the floating position chunk for floating windows |
| drag a tile out of the row      | existing paths (floating move / tiled insert) to the numeric target    |
| Esc / SUPER+P                   | unchanged                                                              |

`scratchpadShown` is reset to false in `open()`. A rebuild while shown keeps the row; the row
never appears on its own after a compositor event.

**The show chunk** (`Logic.scratchpadShowLua()`), a single guarded line like every other chunk:
```lua
local ws = hl.get_active_special_workspace()
if not (ws and ws.name == "special:scratchpad") then run(hl.dsp.workspace.toggle_special("scratchpad")) end
```
wrapped in the standard `dispatchGuardLua` / `reportLua` frame. The lua-check mock gains
`get_active_special_workspace` and `workspace.toggle_special`; the behaviour suite covers both
branches (hidden → toggles; already active → no dispatch).

## Layout and data

- `buildInput()` includes a special workspace only when `scratchpadShown` and its name is
  `special:scratchpad`; the workspace record is emitted with `id: Logic.SCRATCHPAD_ID` (-2) and
  `special: "scratchpad"` (normal workspaces: `""`), and each of its windows is emitted with
  `workspaceId: -2` and `special: "scratchpad"`. Hyprland's reported id is never used downstream.
  If Hyprland reports no such workspace, a synthetic record with the same id and no windows is
  added on the focused monitor (the empty row).
- `Logic.layout` appends **one trailing group** after the monitor groups, separated by
  `rowSpacing`: a header band (`headerH`, always, even in single-monitor mode) whose chip reads
  `SCRATCHPAD`, and one box of the normal cell width whose height follows the scratchpad's own
  monitor. The group is never `focused` (no backdrop). Boxes carry `special` so the view can
  label them; the group carries `special` so the chip repeater can render it whether or not
  there is more than one monitor group.
- Labels: the badge and the empty-well numeral show `S` for the scratchpad (`wsLabel`).
- Tiles: unchanged — Hyprland reports real geometry for scratchpad windows, floating or tiled,
  relative to their monitor, so `_tileRect` places them like any other window.

## Sentinel audit

The scratchpad box id is -2. Today several places use `id >= 0` / `id < 0` to mean "has a
workspace". After this change:

- `-1` stays the one "none" sentinel (`selectedIndex`, `dropTargetWs`, `preQuerySelectedId`).
- `Logic.hasWs(id)` (`typeof id === "number" && isFinite(id) && id !== -1`) replaces every
  `>= 0` test on a workspace id: rebuild's `keepId`, `restorePreQuerySelection`, the drop
  release (`targetWs`), and Enter's `selectedId` check.
- Places that must **exclude specials** keep an explicit `ws.special` / `id < 0` test:
  `padWorkspaces`, `_orderedMonitorNames`, the monitor-group loop in `layout`, the digit keys.
- Dispatch targets: `Logic.wsSelector(id)` returns `"special:scratchpad"` for `SCRATCHPAD_ID`
  and the numeric id otherwise; `floatingMoveLua`, the plain move and the chunks' "already
  there" comparisons use it. `jump()` routes the scratchpad id to the show chunk and never to a
  workspace focus, so Enter and the box click share one guard.
- Pending-drop reconciliation: a pending move whose target is `SCRATCHPAD_ID` is acknowledged
  when the window's `workspaceId` from `buildInput()` is `SCRATCHPAD_ID` — which the remap
  guarantees as soon as Hyprland reports the window on `special:scratchpad`, whatever id it
  allocated. No change to the deadline logic.
- Drop planning: `updateDropTarget()` skips `tiledDropPlan` when `dropTargetWs ===
  SCRATCHPAD_ID` (explicit bypass), so a tiled source over the scratchpad shows the workspace
  wash, never an insertion half, and the release dispatches the plain move.

## Visuals

- Row placement: below the last monitor group, `rowSpacing` above it, the box left-aligned.
- Chip: same style as the monitor chips, text `SCRATCHPAD`, never accented.
- Badge / numeral: `S`.
- Drop cues, selection frame, find ring and dim: unchanged, they key on the box.
- Hint row: `ctrl+s · scratchpad` before `esc · close`.

## Edge cases

- Ctrl+S with the overlay showing a query: the row appears, its windows join the match list on
  the same rebuild; hiding it drops them and the successor rule picks the next match.
- A tiled window already in the scratchpad cannot be re-tiled *within* the scratchpad from the
  overview: the drop is a plain move, and a same-workspace plain move is a no-op. On a normal
  workspace the same gesture re-tiles. Accepted asymmetry of the "plain silent move" decision.
- A drag in flight when Ctrl+S is pressed: the row toggles; the drag continues; if the dragged
  window's own row disappears (dragging a scratchpad tile, then hiding the row) the drag is
  cancelled by `rebuild()`'s existing "dragged window no longer in the input → `endDrag()`"
  check, before the delegate is destroyed.
- **Showing the row scrolls it into view** without moving the selection: on an overflowing
  layout the row is appended below the fold, and Ctrl+S must produce a visible change.
- **Hiding the row with a drop into it still unacknowledged.** `applyTiles` keeps rows with a
  pending move, but a window on a hidden scratchpad is not in `buildInput()`, so nothing could
  acknowledge it and the optimistic tile would sit on the canvas until the 1.8 s deadline.
  Hiding the row — by Ctrl+S or by `open()`'s reset, one shared `hideScratchpad()` — therefore clears every `pendingMoves` entry whose target
  is `SCRATCHPAD_ID` before the rebuild, so `applyTiles` removes those rows at once. Showing the
  row again rebuilds from compositor data, so the window reappears in the scratchpad once
  Hyprland has moved it. The reverse case (a scratchpad tile dropped onto a workspace, then the
  row hidden) needs nothing: the window joins the input as a normal-workspace window when the
  move lands and is acknowledged as today.
- The scratchpad on another monitor (docked): the row height follows that monitor; the show
  chunk toggles on the focused monitor, which is how SUPER+S behaves too.
- Nested/CI fixture: the compositor stub seeds a negative-id workspace with `name:
  "special:scratchpad"` and floating clients; `buildInput()` reads `ws.name`.

## Tests

- **Tier 1, `tests/tst_layout.qml`**: trailing group appended below the groups with a header
  band in single-monitor mode; box height from the scratchpad's monitor; no group when the input
  has no special; `hasWs` accepts -2 and rejects -1/undefined; `wsSelector` returns the name for
  `SCRATCHPAD_ID` and the number otherwise; a tiled window on the scratchpad renders as a tiled
  tile; `floatingMoveLua` / the plain move chunk name `special:scratchpad` for the scratchpad
  target and never emit a dwindle preselect.
- **Tier 1, Lua behaviour suite**: `scratchpadShowLua` toggles when no special is active or a
  different one is; does nothing when `special:scratchpad` is active; dispatch failure reported.
- **Tier 1, offscreen UI (`tests/ui/scratchpad.qml`)**: Ctrl+S shows a box with id -2 and a
  tile for each seeded scratchpad window, Ctrl+S again hides both; reopen starts hidden; Enter on
  the box dispatches the show chunk and closes; a digit never selects it; Down from the last
  workspace row lands on it; with a query, its windows match only while shown; a drop on it
  dispatches a move naming `special:scratchpad`; a **tiled** source dropped on it dispatches the
  plain move (no insertion half while hovering, no dwindle chunk); an empty scratchpad still
  yields a box; the hint row carries `ctrl+s`. **Id independence:** the fixture seeds the
  scratchpad as `{ id: -73, name: "special:scratchpad" }` (not -98) and asserts the box and its
  tiles carry id -2; a pending drop is acknowledged when the fixture reports the window on the
  -73 workspace. **Hide during a pending drop:** drop a window on the box, press Ctrl+S before
  the fixture acknowledges, assert the tile row is gone and `pendingMoves` has no entry for it;
  seed the window on the scratchpad, press Ctrl+S, assert the tile is back in the row.
- **Tier 2**: nothing new (the show chunk is exercised by the Lua mock; a live check confirms
  the scratchpad rises on Enter).
