# Omascape — shove: Shift+arrow moves the target (design)

Date: 2026-09-18 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1 ·
builds on actions (`actions-omascape` at `da9075b`).
Status: **approved design, pre-implementation; revised 2026-09-18 after review** (three
corrections, marked ✎). One compositor probe blocks part of it — see "Probe required".
Branch `shove`.

## Goal

`Shift`+arrow takes the current target one step in that direction. A window moves to the
neighbouring workspace; a workspace moves to the neighbouring monitor, or — when the neighbour is
on the same monitor — trades contents with it. Repeatable: `Shift+Right Shift+Right` walks a
window two workspaces over without releasing anything.

## Scope

**In:** a `Shift`+arrow branch in the key handler; window shove via the existing silent-move
dispatch; workspace shove branching on the destination's monitor; a new atomic content-swap
chunk; selection following the shoved thing; `Logic.isActionKey` learning about `Shift`; hint row;
tests. ✎ Added after review: an `effectiveWorkspaceOf(addr)` accessor over `pendingMoves`, the
hover-consuming latch, a correction to the cursor-survival check at `Overview.qml:1177`, and a
`tests/ui/shove.qml` suite for the three of those that no pure test can reach.

**Out:** `Shift`+digit (shove to a numbered workspace); shoving with the mouse beyond the existing
drag-and-drop; wrapping past the grid edges; reordering workspace *numbers* (Hyprland has no such
dispatcher — see Decisions); shoving the scratchpad workspace itself; undo.

## Decisions (brainstorm 2026-09-18)

- **One sentence defines the whole feature: `Shift`+arrow takes the target one container in that
  direction.** A window's container is a workspace; a workspace's container is a monitor. Plain
  arrows move the *view*; `Shift`+arrows move the *thing*.

- **`Shift`+arrow is an ACTION key, and it CONSUMES the hover it read.** ✎ *(revised after review
  2026-09-18 — the original "reads liveness and leaves it unchanged" was wrong, see below.)*
  Ordering is the whole of it:

  1. **Reads** pointer liveness, so hovering a tile and tapping `Shift+Right` shoves the window
     you are pointing at. `Logic.isActionKey` must therefore return true for it, so the blanket
     `if (!isActionKey(...)) pointerLive = false` at `Overview.qml:1518` does **not** pre-clear.
     It grows a `shift` parameter: `Shift` is deliberately absent from the `chord` mask
     (`Overview.qml:1497`), so it cannot be inferred and must be passed.
  2. **Latches** the resolved target onto the keyboard — `cursorAddress` for a window,
     `selectedId` for a workspace.
  3. **Clears** `pointerLive`, *after* resolving.

  Why the clear is mandatory rather than tidy: `resolveTarget()` hit-tests the pointer position
  afresh on every press (`Overview.qml:445`). Keep liveness and the second `Shift+Right` of a
  repeat re-hit-tests a *stationary* pointer against a grid the first shove just changed — the
  window has left, so the press lands on whatever slid under the cursor, or on the origin
  workspace box. The feature's headline claim would be false on its second keystroke. Latching
  also solves the other half: a hover-only target has **no** `cursorAddress` at all, so "the
  cursor follows the window" has nothing to follow until the shove establishes one.

  This is a refinement of the action-key doctrine, not a reversal of it. `Ctrl+W` may leave
  liveness alone because closing removes its own target; a shove leaves its target alive and
  somewhere new, so it has to say where. Real pointer movement re-arms liveness through the
  existing `notePointerMove` path (`Overview.qml:414`), so hovering elsewhere and shoving that
  works exactly as before — the clear ends a *repeat chain*, not hover targeting.

- **The branch runs before the `finding` split**, so `Shift`+arrow works during a find. Plain
  arrows there drive `navigateMatch`; `Shift`+arrows shove the match. Same target rule, no mode.

- **A window shove uses the window's OWN workspace box as the origin, not the selected one.** The
  same distinction `menuItems` already makes (`logic.js:1117`) — under a hover target the window
  may well not be on the selected workspace, and navigating from the wrong origin would send it
  somewhere neither the pointer nor the grid pointed at.

- **Edges are inert, with no edge logic.** `Logic.navigate` (`logic.js:783`) already returns the
  *current* index when nothing lies in that direction. A shove whose destination equals its origin
  dispatches nothing — but it still latches (see `latch()` below), so pressing into an edge and
  reversing acts on the thing you were pushing. No wrap, deliberately: wrapping would teleport a
  window from workspace 1 to workspace 10 on a keypress meant to nudge it.

- **Selection follows the shoved thing.** After a window shove the selection moves to the
  destination workspace and the cursor holds the moved window; after a workspace shove the
  selection follows the contents (for a monitor move, contents and id move together, so it stays
  on the same id). This is what makes the gesture repeatable, which is the whole reason to have it
  rather than using the context menu.

- **A repeat shove reads the PENDING destination, not the reported one.** ✎ *(added after review
  2026-09-18.)* `pendingMoves[addr].workspaceId` (`Overview.qml:387`, set at `:894` and `:935`)
  holds an optimistic destination for up to 1800 ms while `refreshToplevels` is in flight;
  `_windowByAddress[addr].workspaceId` is what the compositor last *reported*. Shoves can easily
  outrun a round trip, and a second press that read the reported workspace would compute its
  origin as the box the window has already left — dispatching a second move to the *same*
  destination and stalling the chain at one hop. So one accessor decides:

  ```
  effectiveWorkspaceOf(addr) = pendingMoves[addr] ? pendingMoves[addr].workspaceId
                                                  : _windowByAddress[addr].workspaceId
  ```

  The drag path reads `win.workspaceId` directly (`Overview.qml:921`, "model.wsid may still be
  optimistic") and is right to: a drag begins from a fresh grab, which supersedes pending state by
  definition. A repeat shove has no grab and must consult it. Each shove `supersedePending`s its
  own previous entry (`Overview.qml:526`) before writing the new one — the window is going to
  ws 5 now, not ws 4, and the fresh `window.move` dispatch is correct whether or not the first
  one has landed.

- **The cursor must survive its own shove.** ✎ *(added after review 2026-09-18.)* The reconcile at
  `Overview.qml:1177` drops `cursorAddress` when its window's reported workspace differs from
  `selectedId`. A shove sets `selectedId` to the destination while the compositor still reports
  the origin, so the very next rebuild would clear the cursor and break the chain. That check
  moves onto `effectiveWorkspaceOf` as well. This is a **general** correction, not a shove
  special case: a cursor should not be dropped mid-flight during a drag either.

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
| workspace, either side empty or synthetic | still swaps — the empty side contributes nothing and the occupied side moves across (see the chunk's case table) |
| workspace, both empty           | nothing — no chunk is generated, no dispatch is made                |
| scratchpad row as a destination | valid for a **window** shove (via `wsSelector`), when the row is shown |
| scratchpad row as the target    | nothing — it has no monitor to move between and no peer to swap with |
| no target                       | nothing                                                             |

## The QML side — `shoveTarget(dir)`

```
t = resolveTarget()                      // reads pointer liveness, exactly as closeTarget() does
if (!t) return

if (t.kind === "window")
    addr = t.address
    i = Logic.indexOfWorkspace(boxes, effectiveWorkspaceOf(addr))   // PENDING-aware origin
    j = Logic.navigate(boxes, i, dir);  if (j === i) { latch(); return }
    dest = boxes[j].workspaceId

    supersedePending(addr)                                 // drop this window's previous optimism
    pendingMoves[addr] = { workspaceId: dest, pos: null, deadline: Date.now() + 1800 }
    tilesModel row for addr: wsid = dest                   // optimistic, as the drag path does
    dispatch silent move -> dest                           // the drag path's chunk, unchanged
    scheduleRebuild(); reconcileTimer.restart()            // the drag path's tail, unchanged

    cursorAddress = addr                                   // LATCH: may be the first cursor ever,
    selectedId    = dest                                   //   under a hover-only target
    pointerLive   = false                                  // end the hit-test chain (see Decisions)

else                                     // workspace
    i = Logic.indexOfWorkspace(boxes, t.id)
    b = boxes[i]
    j = Logic.navigate(boxes, i, dir);   if (j === i) { latch(); return }
    d = boxes[j]
    if (b.special || d.special) { latch(); return }
    if (d.monitorName !== b.monitorName)
        dispatch Logic.workspaceMoveLua(b.workspaceId, d.monitorName)
        selectedId = b.workspaceId                         // same workspace, new monitor
    else if (b.windowCount || d.windowCount)
        dispatch Logic.swapWorkspaceContentsLua(b, d)
        selectedId = d.workspaceId                         // follow the contents
    else return                                            // both empty: no chunk, no dispatch
    setCursor("")                                          // a workspace shove owns no window
    pointerLive = false
```

`latch()` is the no-op-but-still-consume path: an inert shove (edge, scratchpad, both-empty) still
sets the keyboard target and clears liveness, so pressing into an edge and then reversing acts on
the thing you were pushing rather than re-hit-testing the pointer.

`Logic.shoveDestination(boxes, origin, dir)` is extracted as a pure function returning
`{kind: "none" | "window" | "moveMonitor" | "swapContents", ...}` so the branch itself is Tier 1
tested rather than living inside a QML handler. It takes the origin *workspace id* — the caller
resolves `effectiveWorkspaceOf` — so the pure function stays ignorant of pending state.

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
    -- SYMMETRIC. Neither side errors on a workspace the compositor does not have: a
    -- synthetic pad workspace is the NORMAL case under the default `workspaces: 10`, and
    -- either end of a swap can be one. A missing workspace is an empty snapshot, full stop.
    local la = (wa and wa.get_windows) and snapshot(wa) or {}   -- addresses, normalised to 0x…
    local lb = (wb and wb.get_windows) and snapshot(wb) or {}
    -- BOTH lists are read before ANYTHING moves. Reading B after moving A into it would
    -- find the windows just moved and send them straight back: the swap would be a no-op
    -- that looks like a bug. This ordering is the single load-bearing fact of the chunk.
    for _, addr in ipairs(la) do guarded: window.move{ workspace = "B", follow = false } end
    for _, addr in ipairs(lb) do guarded: window.move{ workspace = "A", follow = false } end
    if #la > 0 then <retarget the monitor to B — see "Probe required"> end
  end)
  if ok and #failed > 0 then ok, err = false, table.concat(failed, "; ") end
  report('swap workspaces')
  restoreCursor(cur)
end
```

- **Each move is guarded individually**, `closeAllLua`-style: one window refusing must not strand
  the other half of the swap, and failures are reported together as one notification rather than
  one per window.
- **Either workspace may be missing, and the two cases are symmetric.** ✎ *(corrected after review
  2026-09-18 — the first draft copied `closeAllLua`'s `error("workspace not found")` for A, which
  was wrong: `closeAllLua` is only ever reached from a menu row that requires `windowCount > 1`,
  so its A always exists. A shove has no such gate, and with the default `workspaces: 10` padding
  a synthetic never-created workspace is the ordinary case on either side.*) Whichever side is
  missing contributes `{}`, the swap degenerates to a one-way move, and Hyprland creates the
  destination on the first `window.move`. The three live cases:

  | A | B | result |
  |---|---|---|
  | occupied | occupied | true exchange; monitor retargets to B |
  | occupied | missing/empty | all of A moves to B; monitor retargets to B |
  | missing/empty | occupied | all of B moves to A; **no retarget** (see below) |

  Both empty never reaches the chunk — the QML side refuses on `windowCount`.
- **The retarget is conditional on `#la > 0`**, which is also the defined outcome for an empty
  `la` that the focus fallback would otherwise have no window to use. The retarget exists so a
  monitor follows A's contents to B; if A had no contents, nothing went to B and there is nothing
  to follow. The monitor stays on A — which has just *gained* B's windows, so the user's screen
  fills rather than emptying. Well defined, and the right picture either way.
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
   focusing any window now on B switches to B. The window to focus is `la[1]` (a window that was
   on A and is now on B), not the previously-active window, which may have been on a third
   workspace entirely. `la[1]` is guaranteed to exist wherever the retarget runs at all: the
   retarget is gated on `#la > 0` for exactly this reason, so the fallback has no empty case.

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

**UI suite (`tests/ui/shove.qml`, the real `Overview` against the stubbed compositor).** All three
of the following exist because a pure test cannot reach them — they are about pointer state,
optimistic state and reconcile timing, none of which `logic.js` knows about. The fixture drives
reconciliation through explicit `view.rebuild()` calls, so "the compositor has not answered yet"
is expressed simply by not calling it.
- **Repeated shove, stationary pointer** (issue 1): hover a window, press `Shift+Right` three
  times without moving the mouse, rebuild between each. Assert three dispatches moving *the same
  address* to three successive workspaces — the direct regression for re-hit-testing a stale
  pointer position.
- **The first shove establishes a cursor** from a hover-only target: assert `cursorAddress` is ""
  before and the shoved address after, and that `pointerLive` is false after.
- **Repeated shove with acknowledgement delayed** (issue 2): press `Shift+Right` twice with *no*
  rebuild in between, so `_windowByAddress` still reports the origin for both. Assert the second
  dispatch targets ws origin+2, not origin+1 — the regression for reading reported instead of
  pending state.
- **The cursor survives the reconcile** (issue 2): shove, then `view.rebuild()` while the stub
  still reports the old workspace. Assert `cursorAddress` is unchanged. Without the
  `effectiveWorkspaceOf` correction at `Overview.qml:1177` this fails.
- **Pointer movement re-arms hover targeting**: shove, move the pointer over a different tile,
  shove again, assert the second acted on the newly hovered window — the check that the liveness
  clear ends a repeat chain rather than disabling hover.
- **An inert shove still latches**: press into the grid edge from a hover target, assert
  `cursorAddress` is set and `pointerLive` cleared, then reverse direction and assert the reversal
  acts on that same window.

**Lua behaviour (`tests/lua-check.sh`, mock `hl`):**
- Swap of a 2-window A with a 1-window B issues exactly 3 `window.move` dispatches and ends with
  every address on the other workspace.
- **The ordering case:** A has windows, B is empty. Assert the windows end on B and are *not*
  moved back — the direct regression for reading B after moving A.
- Swap with a non-existent B moves all of A and issues no moves back.
- **The symmetric case (issue 3):** A does not exist, B has two windows. Assert both move to A,
  the chunk raises nothing, and **no retarget dispatch is issued** — the `#la > 0` gate.
- A swap where A exists but is empty behaves identically to A not existing at all.
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
