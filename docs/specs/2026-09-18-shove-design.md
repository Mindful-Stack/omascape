# Omascape — shove: Shift+arrow moves the target (design)

Date: 2026-09-18 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1 ·
builds on actions (`actions-omascape` at `da9075b`).
Status: **approved design, pre-implementation. One compositor probe blocks part of it — see
"Probe required".** Branch `shove`.

## Goal

`Shift`+arrow takes the current target one step in that direction. A window moves to the
neighbouring workspace; a workspace moves to the neighbouring monitor, or — when the neighbour is
on the same monitor — trades contents with it. Repeatable: `Shift+Right Shift+Right` walks a
window two workspaces over without releasing anything.

## Scope

**In:** a `Shift`+arrow branch in the key handler; window shove via the existing silent-move
dispatch; workspace shove branching on the destination's monitor; a new atomic content-swap
chunk; selection following the shoved thing; `Logic.isActionKey` learning about `Shift`; hint row;
tests.

**Out:** `Shift`+digit (shove to a numbered workspace); shoving with the mouse beyond the existing
drag-and-drop; wrapping past the grid edges; reordering workspace *numbers* (Hyprland has no such
dispatcher — see Decisions); shoving the scratchpad workspace itself; undo.

## Decisions (brainstorm 2026-09-18)

- **One sentence defines the whole feature: `Shift`+arrow takes the target one container in that
  direction.** A window's container is a workspace; a workspace's container is a monitor. Plain
  arrows move the *view*; `Shift`+arrows move the *thing*.

- **`Shift`+arrow is an ACTION key, not a navigation key.** It reads pointer liveness and leaves
  it unchanged, exactly as `Ctrl+W` does — so hovering a tile and tapping `Shift+Right` shoves the
  window you are pointing at. The alternative (treating it as navigation) would clear liveness on
  entry and silently retarget to the Tab cursor, which is the precise failure `isActionKey` was
  written to prevent. `Logic.isActionKey` grows a `shift` parameter: `Shift` is deliberately
  absent from the `chord` mask (`Overview.qml:1497`), so it cannot be inferred and must be passed.

- **The branch runs before the `finding` split**, so `Shift`+arrow works during a find. Plain
  arrows there drive `navigateMatch`; `Shift`+arrows shove the match. Same target rule, no mode.

- **A window shove uses the window's OWN workspace box as the origin, not the selected one.** The
  same distinction `menuItems` already makes (`logic.js:1117`) — under a hover target the window
  may well not be on the selected workspace, and navigating from the wrong origin would send it
  somewhere neither the pointer nor the grid pointed at.

- **Edges are inert, with no edge logic.** `Logic.navigate` (`logic.js:783`) already returns the
  *current* index when nothing lies in that direction. A shove whose destination equals its origin
  dispatches nothing. No wrap, deliberately: wrapping would teleport a window from workspace 1 to
  workspace 10 on a keypress meant to nudge it.

- **Selection follows the shoved thing.** After a window shove the selection moves to the
  destination workspace and the cursor stays on the moved window; after a workspace shove the
  selection follows the contents. This is what makes the gesture repeatable, which is the whole
  reason to have it rather than using the context menu.

- **Workspace shoves branch on where the arrow LANDS, not on which arrow it was.** Different
  monitor → move the workspace there. Same monitor → swap contents with it. Direction-keyed rules
  were rejected because they break on the default configuration: with `workspaces: 10` and
  `maxCols: 5`, every single-monitor user has two sub-rows, so `navigate("down")` from ws 3 lands
  on ws 8's box *on the same monitor* — and "down = move to another monitor" would be dead for
  them. Branching on the landing site works identically on one monitor or three.

- **Cross-monitor uses the native dispatcher.** `moveworkspacetomonitor` is one atomic dispatch
  and already drives the `move:<mon>` menu rows (`workspaceMoveLua`, `logic.js:768`). Reusing it
  is strictly better than a per-window loop across screens.

- **Same-monitor swaps CONTENTS, because Hyprland cannot reorder workspaces.** There is no
  workspace-reorder dispatcher; workspace identity is its number. So "move ws 3 right" can only
  mean "ws 3's windows and ws 4's windows trade places". This was flagged during brainstorming as
  the risky half — `docs/roadmap-v3-ideas.md` parked drag-to-reorder-workspaces as "fragile on
  Hyprland" — and is being built anyway, deliberately, to be evaluated on real hardware. The
  fragility is contained by doing the whole exchange inside **one atomic chunk** with both address
  lists snapshotted before anything moves.

- **After a swap, the monitor follows the contents.** Swapping the live ws 3 rightward with ws 4
  leaves your screen looking unchanged and moves the *label*: the monitor retargets to ws 4. The
  alternative — staying on ws 3 and watching its contents swap out underneath you — reads as "my
  windows teleported away" rather than "the workspace moved".

## Behaviour

| Target                          | `Shift`+arrow                                                      |
|---------------------------------|---------------------------------------------------------------------|
| window (hover / cursor / match) | move it to the destination workspace, silently; selection + cursor follow |
| window, no box in that direction| nothing                                                             |
| workspace, destination on another monitor | move the workspace to that monitor; selection stays on the same id |
| workspace, destination on the same monitor | swap the two workspaces' contents; selection follows to the destination |
| workspace, both empty           | nothing — no chunk is generated, no dispatch is made                |
| scratchpad row as a destination | valid for a **window** shove (via `wsSelector`), when the row is shown |
| scratchpad row as the target    | nothing — it has no monitor to move between and no peer to swap with |
| no target                       | nothing                                                             |

## The QML side — `shoveTarget(dir)`

```
t = resolveTarget()                      // pointer-live aware, exactly as closeTarget() is
if (!t) return

if (t.kind === "window")
    w  = _windowByAddress(t.address)
    i  = Logic.indexOfWorkspace(boxes, w.workspaceId)      // the WINDOW's box
    j  = Logic.navigate(boxes, i, dir);  if (j === i) return
    dispatch silent move -> boxes[j].workspaceId           // the drag path's chunk, unchanged
    optimistic tile update, then reconcile                 // the drag path's tail, unchanged
    selectedId = boxes[j].workspaceId                      // cursorAddress unchanged: it follows

else                                     // workspace
    i = Logic.indexOfWorkspace(boxes, t.id)
    b = boxes[i]
    j = Logic.navigate(boxes, i, dir);   if (j === i) return
    d = boxes[j]
    if (b.special || d.special) return
    if (d.monitorName !== b.monitorName) Logic.workspaceMoveLua(b.workspaceId, d.monitorName)
    else if (b.windowCount || d.windowCount) Logic.swapWorkspaceContentsLua(b, d)
    selection follows per the table above
```

`Logic.shoveDestination(boxes, origin, dir)` is extracted as a pure function returning
`{kind: "none" | "window" | "moveMonitor" | "swapContents", ...}` so the branch itself is Tier 1
tested rather than living inside a QML handler.

## The compositor side — `swapWorkspaceContentsLua(a, b)`

Modelled directly on `closeAllLua` (`logic.js:705`), which already reads a workspace's window
list **inside** the compositor via `HL.Workspace:get_windows()` rather than trusting the
overview's layout — so windows the overview never laid out are swapped too.

```
function()
  dispatchGuard
  local cur = hl.get_cursor_pos()
  local failed = {}
  local ok, err = pcall(function()
    local wa, wb = hl.get_workspace("A"), hl.get_workspace("B")
    if not wa or not wa.get_windows then error("workspace A not found", 0) end
    local la = snapshot(wa)                       -- addresses, normalised to 0x…
    local lb = (wb and wb.get_windows) and snapshot(wb) or {}
    -- BOTH lists are read before ANYTHING moves. Reading B after moving A into it would
    -- find the windows just moved and send them straight back: the swap would be a no-op
    -- that looks like a bug. This ordering is the single load-bearing fact of the chunk.
    for _, addr in ipairs(la) do guarded: window.move{ workspace = "B", follow = false } end
    for _, addr in ipairs(lb) do guarded: window.move{ workspace = "A", follow = false } end
    <retarget the monitor to B — see "Probe required">
  end)
  if ok and #failed > 0 then ok, err = false, table.concat(failed, "; ") end
  report('swap workspaces')
  restoreCursor(cur)
end
```

- **Each move is guarded individually**, `closeAllLua`-style: one window refusing must not strand
  the other half of the swap, and failures are reported together as one notification rather than
  one per window.
- **A destination that does not exist is fine.** `hl.get_workspace("4")` returns nil for a
  synthetic pad workspace Hyprland never created; `lb` is then `{}` and the swap degenerates to
  "move all of A to B", which is exactly right. Hyprland creates the workspace on the first move.
- **Focus is deliberately not restored**, following `workspaceMoveLua`'s precedent: the operation's
  entire purpose is to change which workspace is showing, so re-focusing the previous window would
  undo the thing the user asked for. Only the cursor is warped back.

### Probe required

**How a chunk retargets a specific monitor to a workspace is unverified.** The mock's `hl.dsp`
table (`tests/lua/mock_hl.lua:190`) models only what existing chunks use, and none of them
switches a monitor's active workspace; the real Lua dispatcher table is larger, but its shape here
has not been read from the 0.56.2 source or probed live. Two candidates, to be settled by a probe
script under `tests/integration/` **before** the chunk is written:

1. A direct workspace-focus dispatcher, if one exists in `hl.dsp.workspace`. Preferred: one
   dispatch, no focus side effects.
2. **Fallback, using only dispatchers already proven:** focus a window that ended up on B.
   `mock_hl.lua:210` records a live-probed fact — *focus carries the workspace* on 0.56.2 — so
   focusing any window now on B switches to B. The window to focus is the first entry of `la`
   (a window that was on A and is now on B), not the previously-active window, which may have
   been on a third workspace entirely.

If neither lands, the swap still ships without the retarget and the monitor keeps showing A; that
degradation is a worse gesture, not a broken one, and should be called out rather than papered over.

## Tests

**Tier 1 (`logic.js`, pure, CI):**
- `shoveDestination` returns `none` when `navigate` clamps at an edge.
- `shoveDestination` returns `moveMonitor` for a vertical hop across monitor rows and
  `swapContents` for a vertical hop between sub-rows of the *same* monitor — the case that killed
  the direction-keyed rule.
- `shoveDestination` returns `none` for a scratchpad origin, and `window` for a scratchpad
  destination under a window target.
- `isActionKey(Left, 0, Ctrl, shift=true)` is true; `isActionKey(Left, 0, Ctrl, shift=false)` is
  false — so a plain arrow still clears pointer liveness and a shove still reads it.
- `swapWorkspaceContentsLua` emits no chunk when both workspaces are empty.
- Shape test: every dispatch in the new chunk goes through `run(`, never bare `hl.dispatch(`.

**Lua behaviour (`tests/lua-check.sh`, mock `hl`):**
- Swap of a 2-window A with a 1-window B issues exactly 3 `window.move` dispatches and ends with
  every address on the other workspace.
- **The ordering case:** A has windows, B is empty. Assert the windows end on B and are *not*
  moved back — the direct regression for reading B after moving A.
- Swap with a non-existent B moves all of A and issues no moves back.
- An injected failure on the second `window.move` still moves the rest and reports one
  notification naming the failed address.
- `cursor.move` is the last dispatch in the chunk.
- **Chunk count guard: `tests/lua-check.sh:84` goes 24 → 25.** (The ROADMAP says 23; it is stale.)
- Any new dispatcher the chunk uses must be **added to `tests/lua/mock_hl.lua` with its real side
  effect**, never stubbed as a no-op — a mock that does not reproduce the effect cannot test the
  ordering that exists to get it right.

**Tier 2 (nested Hyprland):**
- `Shift+Right` on a hovered window moves it one workspace and the overview reconciles.
- Three consecutive `Shift+Right` presses walk a window three workspaces without a release.
- `Shift+Right` on a workspace swaps contents and the monitor ends on the destination.
- `Shift+Down` on a single-monitor rig with two sub-rows swaps rather than attempting a move.

**Unverified on this machine (single monitor), as with the existing Move/Swap rows:**
a workspace shove that crosses monitors. It is listed in the ROADMAP's open items and this
spec adds to that list rather than claiming coverage it cannot have.
