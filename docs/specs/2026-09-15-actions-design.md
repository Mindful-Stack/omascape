# Omascape — actions: target, window cursor, close, context menu (design)

Date: 2026-09-15 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1 ·
builds on find, the scratchpad row and the workspace lock (`main` at `26c6c11`).
Status: **approved design, pre-implementation** (revised after a codex review, 2026-09-15, and a
second design review, 2026-09-16).
Branch `actions`.

## Goal

Act on what the overview shows without leaving it: close a window, float or fullscreen it, lock a
workspace, move or swap a workspace between monitors, close everything on a workspace — by mouse
(a right-click menu) and by keyboard (a window cursor plus Ctrl+W).

## Scope

**In:** a single target rule shared by every action; a Tab-driven window cursor inside the selected
workspace; Ctrl+W; a right-click context menu on tiles, wells and workspace badges; the actions
Close, Float/Tile, Fullscreen/Exit fullscreen (window) and Lock/Unlock, Move to ‹monitor›, Swap
with ‹monitor›, Close all windows (workspace); a two-tier hint row; tests.

**Out:** the preview (hold Space; its own spec, next — it will reuse the target rule, but nothing
here is justified by it), a keyboard-opened menu (the Menu key / Shift+F10 — decided against for
now: Close all, Move and Swap are therefore mouse-only until asked for; Lock has Ctrl+L, Close has
Ctrl+W), a hover close button on tiles, drag-to-trash, confirmation dialogs (apps prompt for unsaved
work themselves), per-item disabled states (what does not apply is hidden), persisting the hint tier
across shell restarts, a rollback for a partially failed compositor operation, pinning, grouping,
renaming workspaces.

**Build order (for the plan):** fundamentals first — target rule, cursor, Ctrl+W, hints — then the
menu with the window actions and Lock/Close all, then Move/Swap last, so the monitor operations can
ship (or be dropped) on their own.

## Decisions (brainstorm 2026-09-15; revisions from the codex review marked ✎)

- **One action surface for the mouse: a right-click menu.** Chosen over hover buttons (a close ×
  beside the fullscreen badge, a lock glyph on the number badge) because one menu covers every
  action including ones with no natural glyph (move to monitor), and over drag-to-trash because a
  bin competes with the edge-scroll band and the drop targets and adds a mode to the drag. Two-finger
  tap is a right click on the touchpad. **Middle-click still closes** and is now listed in the
  hints.
- **Keyboard: Ctrl+W closes the target, no keyboard-opened menu.** Ctrl+L keeps locking.
- **A Tab-driven window cursor**, because without one the keyboard can only name a window through
  find. "What happens if the workspace has several windows?" — Tab picks one.
- **Most recent input device wins.** A pointer parked over a tile must not hijack keyboard actions,
  and a stale Tab cursor must not hijack a mouse user; so the pointer only decides while it is
  *live* (moved since the last navigation or query key press). ✎ Modifier-only presses (Ctrl,
  Shift, Alt, Meta on their own) never change targeting, or hover + Ctrl+W could never work: the
  Ctrl press would go stale before the W arrived. ✎ Action keys (Ctrl+W, Enter) read liveness and
  leave it alone, so a second Ctrl+W cannot silently switch from the hovered window to the cursor.
- **Hints in two tiers**, toggled by `?`: the primary row stays short; the advanced keys live on a
  second line shown on demand.
- ✎ **Swap uses the native `workspace.swap_monitors`, and is offered only for a workspace that is
  active on its monitor.** Verified in the 0.56.2 source (`WorkspacePlacementController.cpp`,
  `swapActiveWorkspaces`): it exchanges the two monitors' active workspaces, each monitor then shows
  what it received, and focus goes to the last focused window of the workspace that arrived on the
  focused monitor. The first draft's "two moves" would have exchanged *ownership* of a hidden
  workspace without any defined effect on what either monitor shows (see Move below) — a swap in
  name only.
- ✎ **Every action sets an explicit state, never toggles**, so a menu item rendered from a
  snapshot cannot do the opposite of its label if the state changed meanwhile: `window.float` with
  `action = "on"`/`"off"` (verified: `parseToggleStr` accepts `on`/`off`/`enable`/`disable`;
  `Actions::floatWindow` returns early when the state already matches), fullscreen via the existing
  idempotent `fullscreenBodyLua(sel, mode)`, lock via an explicit arm/disarm. Close needs no state.
- **Every new action is one atomic guarded Lua chunk** in the existing style, except Close, which
  stays the plain `window.close` dispatch the middle click already uses.

## The target — `Logic.target(input)`

The window or workspace an action applies to, resolved *at the moment of the action* by one pure
function. Input: whether the pointer is live, the candidate tile under it and the well under it
(both resolved by the view, below), the selected find match, the cursor address and the selected
workspace id. Output: `{ kind: "window", address }`, `{ kind: "workspace", id }`, or `null`.

1. **Pointer live and inside the viewport** → the tile under it, else the well under it.
2. **Otherwise the keyboard target** → while a query is active, the selected find match **and
   nothing else**; otherwise the Tab cursor, else the selected workspace.

✎ **A query with no match yields no target at all** (found in implementation, 2026-09-16), rather
than falling through to the cursor or the workspace. Two reasons. The find spec's own rule is that
"Enter with a query but no match does nothing", and falling through would make a failed search plus
Enter teleport the user to whichever workspace happened to be selected — the opposite of harmless.
And the fall-through is unreachable anyway: starting a query clears the cursor, so "query active
and cursor set" cannot occur in the running overview. Keeping the rule uniform here means Enter,
Ctrl+W and the later preview all behave the same way while searching: they act on the match, or
they do nothing.

**Pointer liveness** (`pointerLive`, a root property) is decided in **panel (scene) coordinates**,
never canvas ones: a `HoverHandler` on the Flickable viewport records `point.scenePosition`; the
pointer is live once that position has changed since the last substantive key press, and only while
the point is inside the viewport's clipped area. ✎ Canvas coordinates shift under a stationary
pointer (edge/wheel scroll, a card resize, the entrance scale), so they cannot stand in for "the
user moved the mouse"; they are derived from the scene point only at resolve time, via
`flick.mapFromItem`. The right-click menu does not consult it — a right press *is* the pointer
being live — and records its target explicitly when it opens.

✎ **Which keys clear it, and when.** Keys fall in two classes. *Navigation and query keys* —
arrows, digits, Tab/Shift+Tab, Esc, Backspace, printable text, Ctrl+S, Ctrl+L, `?` — express
keyboard intent and **clear liveness on entry**, before anything else they do. *Action keys* —
Ctrl+W, Enter, and later Space — **resolve the target against liveness as it stands at event
entry and leave it unchanged**: an action does not say "I am on the keyboard now", it says "do
this to what I am pointing at". So with a window hovered, Ctrl+W twice closes it (the second press
finds it pending and is a no-op, see below) rather than silently switching to the Tab cursor, and
Enter after a hover focuses the hovered window. A lone modifier press belongs to neither class and
touches nothing. Liveness is also cleared when the point leaves the viewport.

**Tile under the pointer** ✎ is resolved against what is *drawn*, not the model: the view collects
each tile delegate's displayed rect (`x`, `y`, `width`, `height`, `scale` — so the hovered tile's
1.03 lift and an in-flight glide count) and effective `z`, and `Logic.tileAt(candidates, x, y)`
picks the containing rect with the highest `z`, later in model order on a tie — exactly the paint
order the `Repeater` produces. Pure and Tier 1 tested on the candidate list; the collection is a
thin loop in `Overview`. The well under the pointer is `Logic.hitWorkspace(boxes, …)` as today.

## The window cursor

`cursorAddress: string` on the root (`""` = none), mirrored into a `cursor` tile role. The tile
draws it as the accent ring find already draws (`matchOutline`: `matched || cursor` shows the ring,
`selectedMatch || cursor` makes it 2 px). Find and cursor never coexist: `setQuery()` with a
non-empty query clears the cursor, and Tab with a query cycles matches as today.

| Key (query empty)  | effect                                                                                  |
|--------------------|-----------------------------------------------------------------------------------------|
| Tab / Shift+Tab    | next / previous window of the selected workspace in reading order, wrapping; none → first / last; empty workspace → nothing. Windows with an outstanding close request (below) are skipped |
| ← → ↑ ↓, digits    | as today, and clear the cursor                                                           |
| Enter              | ✎ resolves the target: a live pointer over a tile focuses that window, over a well jumps to it; otherwise the keyboard target — with a cursor, focus that window (the tile-click path, scratchpad raise included) and close; without, jump to the selected workspace |
| Esc                | clear the cursor if set; else (as today) clear the query if set; else close              |
| Ctrl+W             | close the target if it is a window (below); workspace target → nothing; ignored while a drag is in flight and on key auto-repeat |
| Ctrl+L             | unchanged (locks the *selected workspace*, not the target — a cursor never changes what Ctrl+L does) |

Reading order is `Logic.cycleWindows(tiles, wsId, current, step, skip)`: the workspace's tiles
sorted by `y` then `x` (canvas rects, so a fullscreen window's recovered slot counts, and floating
windows sort by where they are), minus the addresses in `skip`. Pure, Tier 1 tested.

On a rebuild the cursor survives if its window is still on the selected workspace; otherwise it
clears (no successor rule — unlike find, nothing was typed to preserve). `open()` clears it.

**Ctrl+W and outstanding closes.** ✎ A close is a *request*: the app may prompt, delay or refuse,
and the window stays in the model until Hyprland reports it gone. So the overview keeps
`pendingCloses` (`addr → deadline`, 1.8 s like the other pending maps), a tile role `closing` that
dims the tile like a non-match, and:

- Ctrl+W on the cursor window adds it to `pendingCloses` and moves the cursor to the next window
  in cycle order *excluding pending ones* — the sole remaining window clears the cursor, so a
  repeated Ctrl+W never cycles back onto A while A and B are both still reported. On a hovered or
  find-selected window it just adds the entry (find's own successor rule runs when the window
  vanishes).
- An address leaves `pendingCloses` when the window disappears from the input or at the deadline
  (refused: the tile un-dims and is cyclable again). Ctrl+W on a pending window is a no-op until
  then.
- Ctrl+W with a query active closes the selected match the same way.

## The menu

**Component.** `ContextMenu.qml`, drawn like the rest of the plugin (no Qt Quick Controls): a
card-coloured `Rectangle` with `boxRadius` and a `SoftShadow`, one row per item, hover and keyboard
highlight both painted `selBackground`/`selText`. Width follows the longest label plus padding.
Inputs: `items` (`[{ id, label, glyph? }]`), `index` (keyboard highlight, -1 none), theme and
`motion`. Signals: `activated(id)`, `dismissed()`. Display-only: no key handling, no focus — the key
catcher stays the single focus item.

✎ **`motion` earns its place or it goes** (corrected in implementation, 2026-09-16). It was first
declared `required` and never read, which forces every use site to bind it for nothing. The menu
fades in and out on `motion.fast` with the plugin's hover easing, the same treatment the drop wash
and the match ring already get, so it appears the way everything else in the overview does. With
motion off — or in the offscreen fixture, which sets the motion scale to zero — every duration is
0 and the menu simply appears, so no test has to wait on it.

**Placement.** At **panel level**, above the dismissal catcher, positioned in panel coordinates
from the press point and nudged left/up so it stays fully inside the panel. Not in the canvas:
the Flickable has `clip: true`, so a canvas-level menu opened near the viewport's bottom edge
would be cut off. It does not scroll with the canvas either — a wheel/edge scroll while open
dismisses it.

**Opening.** A right press on a tile opens the window menu for that tile's address. A right press
on a well's empty area (the box `MouseArea`) or ✎ **on the workspace number badge** opens the
workspace menu for that workspace — the badge is the reliable target on a well a single tiled or
fullscreen window fills to the 3 px inset. The badge gains a `MouseArea` accepting only
`Qt.RightButton`, so left presses still fall through to the tile or well beneath. The menu records
`menuTarget` when it opens; pointer moves afterwards cannot change what it acts on. A right press
on the scrim closes the overview like a left click.

✎ **Right button and the drag machinery.** `dragArea` gains `Qt.RightButton`, and the drag code is
made left-button-only at *every* stage, not just the press: `onPressed` returns for any button but
left (today), `onPositionChanged` already requires `pressed && dragTile === windowTile`, and
`onReleased` submits a drop or a click **only for `Qt.LeftButton`** — today it treats every
non-middle release as a possible drop, so a right release during a left drag would drop the window.
A right press while a drag is in flight (`root.dragTile !== null`) opens nothing.

✎ **It also cancels the drag, and that cannot be prevented from QML** (found in implementation and
independently reproduced, Qt 6.11.2, 2026-09-17). A `MouseArea`'s exclusive grab is unconditionally
cancelled as soon as a second accepted button completes a press-release cycle while the first is
still held — regardless of `drag.target`, of which item accepts the second button, and reproducing
with a sibling `TapHandler` instead of a widened `MouseArea`. In a minimal probe the area's
`onCanceled` fired on the right release and its `onReleased` never fired for the left button at all.

So the earlier draft's "does not disturb the grab" is unachievable without moving the tile drag off
`MouseArea`/`drag.target` onto `DragHandler`/`TapHandler`, which is a rewrite of the drag machinery
and out of scope here. What matters is preserved: **no drop is submitted and no menu opens.** The
grab cancellation runs the existing `onCanceled` → `endDrag()` path, so the tile returns to its
model position cleanly. Right-click-cancels-a-drag is also a widespread convention, so this reads as
a feature rather than a glitch. The left-button-only guard in `onReleased` stays regardless: it is
what stops the *right* release itself from being treated as a drop.

Tests cover right-only press/move/release, and a right press+release during a left drag asserting
the three things that actually matter — nothing dispatched, no menu, and the drag cleanly ended.

**Items — `Logic.menuItems(target, ctx)`.** Pure, Tier 1 tested. `ctx` carries the window record
(floating, fullscreen mode, workspace id), the box record (occupied, armed, special, synthetic,
active, monitorName) and the monitor list. Hidden, never greyed:

| target    | item                       | shown when                                                  |
|-----------|----------------------------|-------------------------------------------------------------|
| window    | Close                      | always                                                      |
| window    | Float / Tile               | always; label by `floating`                                 |
| window    | Fullscreen / Exit fullscreen | always; "Exit fullscreen" when `fullscreen > 0` (maximized included) |
| workspace | Lock / Unlock              | always; label by `armed`                                    |
| workspace | Move to ‹monitor›          | one per *other* monitor, glyph as the chips (laptop/screen); not on the scratchpad, not on a synthetic (uncreated) workspace, never with one monitor |
| workspace | Swap with ‹monitor›        | as Move, and ✎ only when the workspace is **active on its monitor** (`box.active`) |
| workspace | Close all windows          | ✎ `box.windowCount > 1` only (2026-09-18; was `occupied`)    |

Order as listed. Windows on a placeholder box have no tiles, so no menu; the well's menu still
offers Lock/Unlock (and Close all above more than one window). Item ids: `close`, `float`, `tile`, `fullscreen`,
`unfullscreen`, `lock`, `unlock`, `move:<monitor>`, `swap:<monitor>`, `closeAll` — the id carries
the intended *state*, never a toggle.

✎ **Data the items need that the boxes do not carry today:** `Logic.layout()` drops the workspace
record's `synthetic` flag when it builds boxes, and nothing records whether a workspace is active on
its monitor. Both are propagated end to end — `buildInput()` sets `active` from the monitor
snapshot (`lastIpcObject.activeWorkspace.id`, the same field the lock frame reads, refreshed by the
same events) and `layout()` copies `synthetic` and `active` onto the box — and the Tier 1 layout
test asserts a padded well yields `synthetic: true` and a real workspace whose last window closed
(now a pad slot) does too, so a hand-built `menuItems` fixture cannot hide a missing field.

✎ **They stop at `root.boxes` and are deliberately NOT carried as `boxesModel` roles** (corrected in
implementation, 2026-09-16). The menu reads its box through `boxForWs()`, which returns `layout()`'s
raw output, so nothing would ever read `model.active`. Adding them to the model is not free: every
role is compared by `rowDiffers` on each rebuild, and `active` flips on every workspace switch — so
an unread role would fire `boxesModel.set()` for rows whose visible fields did not change, on a
monitor the user is not even looking at. (Contrast the `special` role, which is also unread today
but never changes, so carrying it costs nothing.)

✎ **A window's menu also carries its workspace's actions, below a separator** (added 2026-09-17,
after live use). Right-clicking the workspace number badge is a ~16 px target and is fiddly on a
trackpad, which is the whole reason the badge opener exists. Rather than enlarge it, a window's menu
now offers the workspace actions too, so any window is a route to its own workspace:

| row | group |
|-----|-------|
| Close | the window, and what it contains |
| Float / Tile | ″ |
| Fullscreen / Exit fullscreen | ″ |
| *(separator)* | |
| Lock / Unlock | the workspace as a container |
| Move to ‹monitor› | ″ |
| Swap with ‹monitor› | ″ |
| Close all windows | ″ |

✎ **Close all sits below the line, last in the workspace group** (2026-09-18, reversing this same
addendum's first answer). It was briefly placed beside Close, grouped by verb — both close things.
Grouping by **scope** is the better rule: nothing that acts on every window on the workspace should
sit among the rows that act on the one window the menu was opened on, one row under Close, reached
by the pointer that was already imprecise enough to motivate this addendum. Last in the group also
puts it as far from Close as the menu allows. The **confirmation** below stays; the two mitigations
are independent, and the destructive row now has both.

✎ **Close all needs more than one window** (2026-09-18). Above a single window it is Close wearing a
longer label and a confirmation dialog, and offering both invites picking the heavier one by
accident. The old rule — the workspace is `occupied` — was true of any workspace holding a window at
all, which on a *window's* menu is the ordinary case rather than the exception. The box therefore
carries `windowCount`, counted from the same toplevel list `occupied` comes from so the two can
never disagree, and the row appears only above `windowCount > 1`. A box with no count at all hides
the row: `undefined > 1` is false, so the destructive row fails closed.

The threshold is applied in `Logic.workspaceMenuRows`, the single builder both the window menu's
group and the well/badge menu use, so the two cannot disagree about what a workspace offers or in
what order.

The workspace rows act on **the window's own workspace**, which is not necessarily the selected one
— `ctx` therefore carries that box for a window target, where it used to be null.

**The separator is a border, not a row.** It is not hoverable, not activatable, and the keyboard
skips over it: `Logic.menuNavigate` takes the item list rather than a count so it can step past one,
and activating it does nothing. Two consequences worth stating, because both are easy to miss: the
menu's highlight-preservation fallback matches by *position* when an id changes, so a separator must
be counted consistently or the highlight drifts by a row when a toggle flips; and a separator must
never be the highlight's landing place when wrapping from either end.

✎ **Close all asks first** (added 2026-09-17), which reverses this spec's own "Out" line on
confirmation dialogs. That exclusion was reasoning about *unsaved work* — applications prompt for
that themselves, and they still do. This is a different risk: one mis-aimed pick closing every
window on a workspace, irreversibly, with no per-application prompt for anything already saved. The
shell's own `Ui/ConfirmDialog` is used rather than a new one: it is themed with everything else and
its `handleKey(event)` is built to be driven by a parent, which is exactly this component's
single-key-catcher architecture. It gates Close all from **every** entry point — window menu, well,
badge — so the guarantee does not depend on which one the user reached it through.

**While open** (`menuOpen`, a key-catcher branch checked *before* `finding`):

| input                     | effect                                                       |
|---------------------------|--------------------------------------------------------------|
| ↑ / ↓                     | move the highlight, wrapping; ↓ from none → first             |
| Enter                     | activate the highlighted item (none → nothing)                |
| Esc                       | dismiss                                                       |
| ✎ lone modifier press     | nothing — consumed, the menu stays; otherwise Ctrl (dismiss) then W (close a window) would let a chord act outside the menu |
| any other key             | dismiss and swallow — the substantive key of a chord included. ✎ The key that dismissed is remembered (`menuDismissKey`) until its real release (`Keys.onReleased` with `isAutoRepeat` false), and every auto-repeat of it in between is swallowed too, so holding a letter down through a dismissal cannot start a query; a *different* key after the dismissal is ordinary input |
| press inside the menu     | activate that row                                             |
| press anywhere else on the overview's screen | dismiss and swallow — ✎ a **panel-sized** transparent `MouseArea` (all buttons) below the menu and above the scrim's own click-to-close area, visible only while `menuOpen`, so a stray click on the scrim can never both dismiss the menu and close the overview; a press on **another monitor** closes the overview as it does today (the menu goes with it — the user asked to leave) |
| hover a row               | highlight follows the pointer (same `index`)                  |

Activation dismisses first, then dispatches. The menu also dismisses on `close()` and on a scroll.

✎ **Staleness.** Every rebuild while the menu is open recomputes `menuItems` for the recorded
`menuTarget` from fresh data: if the target is gone (window closed, workspace destroyed, its box
became a lock placeholder for a window target) the menu dismisses; if the item list changed (a
window floated by another actor, a monitor unplugged, a lock toggled elsewhere) the rows update in
place, keeping the highlight on the same row.

✎ **Matching the highlight by item id alone cannot work, and the reason is this spec's own doing**
(found in implementation, 2026-09-17). Ids name the state to set, so a toggle row's id is exactly
what flips when its state changes — `float` becomes `tile`, `lock` becomes `unlock` — and a state
change is precisely what triggers the refresh. An id search therefore fails every single time on
the rows it most needs to hold, and the highlight drops to none. So: **match by id first, and fall
back to the pre-refresh index clamped into the new list.** Id-matching still has to run first,
because a workspace menu's move and swap rows genuinely appear and disappear with the monitor
count, which moves every row below them; the index fallback only covers the case an id search
structurally cannot.

Activation is therefore
never more than one settle tick stale, and since every id names an explicit state, a stale
activation is at worst a no-op inside the compositor.

## Compositor side

All in `logic.js`, one line each, parse- and behaviour-tested by `tests/lua-check.sh` against the
mock `hl`, using `dispatchGuardLua`, `pcall`, `reportLua(what)`. Address prefix handling as in
`restoreFocusLua` (Lua may report addresses without `0x`). Monitor names are interpolated from
`Hyprland.monitors` and validated (`/^[A-Za-z0-9._-]+$/`) in JavaScript before they can reach a
chunk.

- **Close** — `hl.dsp.window.close({ window = "address:…" })`, the existing plain dispatch,
  shared by Ctrl+W, middle-click and the menu.
- **Float / Tile** — `setFloatLua(addr, floating)`: `run(hl.dsp.window.float({ window = sel,
  action = floating and "on" or "off" }))`, then `restoreFocusLua`. `Actions::floatWindow` raises
  the window when it becomes floating and re-lays out its workspace; it does not change focus
  itself, but the layout change can (parity with the badge's un-fullscreen, which also restores).
  Hyprland exits and re-applies fullscreen internally around a floating change, so a fullscreen
  window ends floating *and* fullscreen; the Tier 2 check covers that case.
- **Fullscreen / Exit** — `setFullscreenLua(addr, mode)` generalises `unfullscreenLua` (which
  becomes `setFullscreenLua(addr, 0)`) around the existing `fullscreenBodyLua`. Entering uses mode
  2. The badge's optimistic `pendingFullscreen` already records a target `mode`, so both
  directions use it: the badge hides now for an exit, and for an entry nothing is optimistic (no
  badge to hide; the slot changes when data lands).
- **Lock / Unlock** — `lockToggleSelected()` becomes `lockSet(wsId, armed)`; Ctrl+L calls it with
  `selectedId` and the opposite of the current state, the menu with the state its item names. Same
  ordering as today: memory → sync → persist.
- **Move to ‹monitor›** — `workspaceMoveLua(wsId, monitorName)`: `run(hl.dsp.workspace.move({
  monitor = "<name>", workspace = "<id>" }))`, then the cursor restored (below). ✎ What the
  compositor does, from `CWorkspacePlacementController::moveWorkspaceToMonitor` (0.56.2):
  - the workspace was **hidden** on its monitor → it arrives hidden on the destination; nothing on
    either screen changes; no focus or cursor change.
  - it was **active on a monitor that is not the focused one** → its old monitor switches to
    another of its workspaces (or a new lowest free id); the moved workspace arrives *hidden*
    on the destination.
  - it was **active on the focused monitor** → the old monitor switches as above, the moved
    workspace becomes the destination's active workspace, monitor focus follows it, and the
    compositor **warps the cursor to the destination's centre** (the Lua dispatcher does not expose
    `noWarpCursor`). The overview's surface stays on its own screen with the pointer now over the
    other screen's catcher, which is focus-less, so keys still reach it.
  The chunk records the cursor before the move and warps it back afterwards (`restoreCursorLua`,
  the cursor half of `restoreFocusLua`), so the pointer never leaves the overview's screen. Window
  focus is deliberately **not** restored: the compositor's own focus outcome stands (re-focusing
  the previous window would drag monitor focus back to a workspace the user just moved away). The
  overview only rebuilds; groups key on the lowest workspace id per monitor, so they may reorder,
  and layout motion glides it.
- **Swap with ‹monitor›** — `workspaceSwapLua(wsId, monitorA, monitorB)`, where A is the
  target's own monitor (from the box) and B the chosen one. ✎ The chunk carries the *workspace*
  identity, not just the monitors: `swap_monitors` acts on whatever is active on A at dispatch
  time, and A may have switched workspaces since the rebuild the menu was drawn from. So the chunk
  first reads `hl.get_active_workspace("<A>")` and **raises unless its id is `wsId`** ("workspace
  ‹id› is no longer active on ‹A›", reported through the usual path, nothing dispatched); only then
  `run(hl.dsp.workspace.swap_monitors({ monitor1 = "<A>", monitor2 = "<B>" }))`, then the cursor
  restored as for Move. Offered only for a workspace active on its monitor, so the compositor's
  semantics apply exactly: each monitor shows the workspace it received, focus goes to the last
  focused window on the workspace that arrived on the focused monitor. A single dispatcher, so
  nothing can half-fail.
- **Close all windows** — `closeAllLua(wsId)`: Lua reads the workspace's own window list
  (`ws:get_windows()` — ✎ verified in `LuaWorkspace.cpp`: a one-based table of `HL.Window`
  objects) and dispatches one `window.close` per address, each step guarded on its own so one
  refusal never stops the rest, reported once naming the failures. Lua reads the list rather than
  the overview passing it, so windows the overview never laid out (a `null` `_tileRect`) are
  closed too. Special workspaces by name (`wsSelector`) — ✎ **but whether Hyprland's own
  `hl.get_workspace()` accepts the `special:…` name form is NOT live-verified** (noted 2026-09-17).
  Only the numeric form was ever probed on this machine. If the name form is not accepted, Close all
  on the scratchpad row closes nothing and reports "workspace not found" — wrong, but inert and
  visible rather than silent or destructive. The mock pins our intent; the live check must settle
  the compositor's half. Every closed address is added to
  `pendingCloses` on the overview side, so the cursor and Tab behave as after Ctrl+W.

Failures surface through the existing path: compositor log line + notification naming the step.

## Data flow, pending state, drags

No new optimistic *geometry*. Every action produces compositor events (`closewindow`,
`changefloatingmode`, `fullscreen`, `moveworkspacev2`, `workspacev2`, …) that already trigger
`scheduleRebuild()`, and the settle rebuild shows the truth within a few ticks.

✎ **Pending moves.** `applyTiles()` skips both updates and removals for an address in
`pendingMoves` (the drop's optimistic row is authoritative until acknowledged or 1.8 s). Without
care, closing or floating a window right after dropping it would leave its stale tile on screen
until the deadline. So every window action (Ctrl+W, middle-click, any window menu item) first
**supersedes that address's pending visual state** exactly as a new grab does: delete its
`pendingMoves` and `pendingFullscreen` entries and clear `fsPending`. ✎ **Close all** does it for
every address whose model row sits on that workspace *or* whose pending move targets it (a window
dropped there a moment ago is on the compositor's list too, and the chunk closes it; its optimistic
row must not outlive it). Move and Swap do the same for every pending entry whose target or source
workspace is the moved one (their coordinates are meaningless on another monitor).

**Drags.** Window actions are ignored while a drag is in flight (`root.dragTile !== null`): Ctrl+W
does nothing, right presses open nothing. A cursor window that is dragged elsewhere is no longer on
the selected workspace after the drop, so the cursor clears on the rebuild.

`Overview` gains: `pointerLive: bool`, `pointerSceneX/Y: real`, `cursorAddress: string`,
`pendingCloses: var`, `menuOpen: bool`, `menuTarget: var`, `menuItems: var`, `menuIndex: int`,
`menuX/Y: real`, `menuDismissKey: int`, `hintsExpanded: bool`.

✎ **`open()` resets the interaction state, not the optimistic-decay maps** (corrected in
implementation, 2026-09-16). It clears the cursor, the query, the menu and pointer liveness. It
must **not** wipe `pendingCloses`, any more than it wipes `pendingMoves` or `pendingFullscreen`:
those three decay on their own 1.8 s deadlines, driven by the reconcile timer that deliberately
keeps running after `close()` so a quick re-summon still shows authoritative state. Wiping
`pendingCloses` on open would let Ctrl+W, Escape, and a re-summon inside that window present a
window with an outstanding close as perfectly normal, and a second Ctrl+W would dispatch a
duplicate close.

`open()` resets everything but `hintsExpanded`, the three pending maps,
and **`pointerSceneX/Y`, which must be left alone** (found in implementation,
2026-09-16). They are not state in the same sense: they are the last position motion was measured
against, and zeroing them makes the next hover reconciliation read as motion relative to `(0, 0)`,
which flips `pointerLive` straight back to true and defeats the reset. Clearing `pointerLive` alone,
with `notePointerMove`'s same-position early return, is what actually delivers the intended
behaviour — the keyboard owns the target after a summon until the mouse really moves.

## Hints — two tiers

The primary row: `1–0 jump`, `↑ ↓ ← → move`, `↵ select`, `drag move window`, `type find`,
`esc close`, `? more`. Pressing `?` with an empty query, or clicking the `? more` cap, toggles
`hintsExpanded`, which shows a second line beneath: `tab window`, `ctrl+w / mid-click close`,
`right-click menu`, `ctrl+s scratchpad`, `ctrl+l lock` (and `space preview` once that ships). With a
query active, `?` appends to the query as today (`appendQueryText` is unchanged; the key handler
checks `query.length` first). The `? more` cap reads `? less` while expanded. The state lives on the
kept-loaded component, so it persists between summons until a shell restart, and is not written to
config.

✎ **Height budget.** `card.hintSpace` keeps its rule — the larger of the find bar and the hints,
reserved whenever either could show — with "the hints" meaning the tier(s) currently shown: one line,
or two while expanded. The find bar replaces the hints inside that same budget, so typing never
moves the card, expanded or not; only toggling `?` changes the budget, and that glides
(`layoutMotion`). `config.hint: false` keeps its exception: no budget normally, the bar's height
only while a query is active.

## Edge cases

- **Pointer parked over a tile, keyboard in use**: `pointerLive` is false after the first
  navigation or query key, so Ctrl+W, Enter and (later) Space act on the keyboard target. Moving
  the mouse makes it live again. A lone Ctrl press changes nothing, so hover + Ctrl+W acts on the
  hovered tile, and so does a second Ctrl+W (a no-op on the now-pending window), since action keys
  never clear liveness.
- **Tab cursor set, then the mouse moves over another tile**: the pointer is live, so Ctrl+W acts
  on the hovered tile; the ring stays where it was (it shows the *keyboard* target, which is still
  valid the moment the keyboard is used again).
- **Scroll under a stationary pointer** (wheel, or edge scroll after a drop): the scene point did
  not change, so the pointer is not made live by it.
- **Menu open, target changes underneath**: dismissed or updated on the rebuild (Staleness).
- **Menu open, overview toggled with SUPER+P**: `close()` dismisses it.
- **Move/Swap to a monitor unplugged between the rebuild and the click**: the chunk's `run()`
  raises on the compositor's "Monitor not found"; reported like any other failed step. The window
  is one settle tick, since items are recomputed on every rebuild.
- **Lock from the menu on a placeholder box**: exactly Ctrl+L on it — the unresolved/malformed
  locks-file guards apply unchanged.
- **Right press while a query is active**: allowed; the menu opens, the query stays; a menu key
  press is consumed by the menu branch first.
- **Close refused** (the app shows a save prompt): the tile un-dims at the 1.8 s deadline and is
  cyclable and closable again; nothing is retried automatically.
- **Hyprland forwards SUPER chords** over the overlay (verified in v1): SUPER+W would close the
  *desktop's* focused window, not the target — unchanged, and why the overview has Ctrl+W.

## Tests

✎ **Harness changes named up front:** `tests/ui/run.sh` enumerates suites and `tests/ui/prepare.py`
copies components explicitly — `tests/ui/actions.qml`, `ContextMenu.qml` and `HintCap.qml` must be
registered in both. `tests/run.sh` needs no change for a Tier 1 file: it passes the `tests/`
directory to `qmltestrunner`, which discovers every `tst_*.qml` itself. The chunk-count guard in
`tests/lua-check.sh` must be raised once per new chunk. The mock `hl` gains
`hl.dsp.window.close`, `hl.dsp.workspace.move`, `hl.dsp.workspace.swap_monitors`,
`hl.get_workspace(sel).monitor` and `HL.Workspace:get_windows()`, applied in `hl.dispatch`, never
no-ops; its existing `window.float` (which only flips a boolean) is extended to **move the active
window onto the floated window**, so "restores focus" has something to restore.

- **Tier 1, `tests/tst_actions.qml`** (pure): `tileAt` — highest `z` wins, later in order on a tie,
  displayed rect includes scale, miss → null; `target` — live pointer over tile / well / nothing,
  stale pointer falls through to match, cursor, workspace, in that order, `null` when nothing is
  selected; `cycleWindows` — reading order (y then x), wrap both ways, none → first/last, empty
  workspace → `""`, current not on the workspace → first, skipped addresses never returned, all
  skipped → `""`; `menuItems` — each row of the table above (window floating/tiled/fullscreen/
  maximized; workspace armed/unarmed, occupied/empty, active/hidden, scratchpad, synthetic, one vs
  two vs three monitors, monitor glyph by connector name), ids carry states not toggles;
  monitor-name validation refuses anything outside `[A-Za-z0-9._-]`. `tst_layout.qml`: boxes carry
  `synthetic` and `active` from the input.
- **Tier 1, Lua suite (`tests/lua/tst_chunks.lua`)**: `setFloatLua(addr, true)` on a tiled window
  ends floating with the active window and cursor restored (the mock moved them), `(addr, false)`
  on a floating one ends tiled, either on an already-matching window dispatches nothing; a throwing
  float is reported; `setFullscreenLua(addr, 2)` on a tiled window ends fullscreen 2, `(addr, 0)`
  on a maximized one ends 0, either on an already-matching window dispatches nothing;
  `workspaceMoveLua` dispatches one move with the right monitor and workspace strings and restores
  the cursor but not focus; `workspaceSwapLua` dispatches exactly one `swap_monitors` with the two
  monitors in order when `wsId` is active on A, and **dispatches nothing and reports** when A's
  active workspace is another id; `closeAllLua` closes every window the workspace lists (including one the input
  never showed) and a refused close still lets the others run, reported once; every chunk parses.
- **Tier 1, offscreen UI (`tests/ui/actions.qml`)**: Tab rings the first window in reading order,
  Tab again the second, Shift+Tab wraps; an arrow clears the ring; Enter with a cursor dispatches
  `focus` for that address and closes; Enter with a live pointer over a tile focuses that tile's
  window, over a well jumps to it; Ctrl+W on a cursor window dispatches `close` for it, dims it,
  and moves the ring to the next *non-pending* window; two rapid Ctrl+W on a two-window workspace
  dispatch one close each and clear the ring; a third does nothing; the deadline un-dims a window
  still present; Ctrl+W with a workspace target dispatches nothing; Ctrl+W auto-repeat is ignored;
  Ctrl+W right after a drop removes the address's `pendingMoves` entry so the next rebuild drops
  the tile; **parked-mouse rule**: a synthetic pointer move over a tile then a key press → Ctrl+W
  acts on the keyboard target; a pointer move after the key → Ctrl+W acts on the hovered tile; a
  lone Ctrl press then W with the pointer parked over a tile since the last move → the hovered
  tile; **consecutive action keys**: with window H hovered (pointer live) and a Tab cursor on
  window C, Ctrl+W then Ctrl+W dispatches one close for H and none for C, and Enter after a
  hover focuses H not C, while an arrow in between makes the next Ctrl+W act on C; a scroll under
  a stationary pointer does not make it live; right press on a tile opens the
  window menu with Close/Float/Fullscreen and does not start a drag; a right press and release
  *during* a left drag neither drops nor opens, and the drag still completes on the left release;
  right press on a well opens the workspace menu, and so does a right press on the number badge of
  a well a fullscreen tile fills; a single-monitor seed shows no Move/Swap, a two-monitor seed shows
  Move naming the other monitor and Swap only on the active workspace; ↓ ↓ Enter activates the
  second item and dispatches the expected chunk; Esc dismisses without dispatching; a lone Ctrl
  press keeps the menu, Ctrl+W then dismisses it and dispatches no close; a press on the scrim
  dismisses and the overview stays open (positive control: the same press with no menu closes it);
  a rebuild that floats the target window relabels Float → Tile with the highlight kept, and one
  that removes it dismisses; typing a letter with the menu open dismisses it and does not start a
  query, **and holding that letter** (auto-repeat presses after the dismissal, then a real release,
  then the same letter again) starts a query only from the press after the release; middle-click
  still dispatches `close` and clears the address's pending state; Close all from the menu right
  after a drop into that workspace removes the dropped address's `pendingMoves` entry so the next
  rebuild drops its tile; `?` toggles
  the second hint line and the card's hint space, typing with expanded hints does not move the
  card, and `?` with a query active appends instead; `open()` clears the cursor and the menu but
  keeps `hintsExpanded` — and keeps `pendingCloses`, which decays on its own deadline like the
  other two pending maps (see "Data flow, pending state, drags"; an earlier draft of this line said
  the opposite).
- **Tier 2 / live (plan's first task)**: on the nested Hyprland rig, assert through `hyprctl -j
  monitors`/`workspaces`/`activewindow` and the cursor position: moving a hidden workspace to the
  other monitor changes no active workspace and no focus; moving the focused monitor's active
  workspace makes it active on the destination and the cursor comes back to where it was;
  `swap_monitors` leaves each monitor showing the workspace it received; close-all on a workspace
  with a floating and a tiled window empties it; floating a fullscreen window leaves it floating
  and fullscreen; and the overview still receives keys after each.

## Verified facts (live, 2026-09-16)

Probed on this machine (Hyprland 0.56.2, single monitor `eDP-1`) with
`tests/integration/actions-probe.sh`. Verbatim output (fix round 1: case 1 now asserts against a
scratch window it creates, rather than reading and eyeballing whatever the active workspace
happened to hold):

```
FACT get_windows: table n=2 first=0x556cc8db1f80 all=0x556cc8db1f80,0x556cc8d5f9d0
FACT hyprctl client count on ws 2: 2
FACT float base→false on→true on-again→true off→false
SKIP: cases 3 (workspace.move) and 4 (swap_monitors) need two monitors; run them on the nested rig
```

- **`HL.Workspace:get_windows()` returns a one-based Lua table**: `#t` equalled hyprctl's own
  client count for the probed workspace (2 = 2, guaranteed non-zero because the probed workspace
  is the scratch window's own) rather than off by one, and `t[1].address` was non-nil. Whether the
  table's elements are specifically `HL.Window` objects (as opposed to, say, plain address
  strings) is **read from the type stubs** (`/usr/share/hypr/stubs/hl.meta.lua`), not observed —
  the probe only calls `tostring(win.address)` on each element and never inspects the object's
  type or other fields.
- **Addresses carry the `0x` prefix, measured by direct comparison, not inferred from one
  sample.** The scratch window's address was read independently from `hyprctl -j clients`
  (`0x556cc8db1f80`) and found verbatim inside the comma-joined list of addresses
  `get_windows()` returned (`all=0x556cc8db1f80,0x556cc8d5f9d0`) — i.e. Lua's own string form of
  the address matches hyprctl's `0x...` form exactly, character for character. The probe fails
  loudly (`FAIL: get_windows() addresses ... did not include the scratch window's address ...
  verbatim`) if the two representations ever diverge (e.g. a build that reports addresses without
  the prefix), rather than only checking `t[1]` and hoping the scratch window sorted first.
- **`hl.dsp.window.float({ action = "on" | "off" })` is an absolute state, not a toggle.** A
  second `action = "on"` on an already-floating window stayed floating (`on-again→true`); a
  toggle implementation would have flipped it back to tiled and the assertion is written so that
  exact failure mode fails it (`[ "$F2" = true ]`). `action = "off"` then tiled it
  (`off→false`). The probe now also records the pre-dispatch baseline (`base→false`) so the FACT
  line is self-documenting about the window's starting state: three of the four reads (`on`,
  `on-again`, `off`) come from a fresh `hyprctl -j clients` lookup taken *after* their dispatch,
  and the fourth (`base`) is deliberately taken *before* any dispatch, which is the point of a
  baseline — none is derived from a value the script passed in.
- **Cases 3 (`workspace.move`) and 4 (`swap_monitors`) are NOT verified on this machine** — it
  has one monitor (`eDP-1`) and the probe SKIPs both by design rather than fabricating a
  two-monitor result. The move/swap semantics described above under "Move to ‹monitor›" and "Swap
  with ‹monitor›" remain **design-time claims from reading the 0.56.2 source**
  (`CWorkspacePlacementController`), not facts observed live; whether the moved-and-active-on-the-
  focused-monitor case actually warps the cursor, and whether `swap_monitors` really leaves each
  monitor showing what it received, are left for the plan's Task 13/14 live checks on the nested
  rig (`tests/integration/lib.sh`), which can bring up two monitors. When those checks run, note
  that the move sub-case the probe exercises (and the only one it safely can, without disturbing
  the user's own view) is specifically the **hidden-workspace** case: it now excludes the target
  monitor's own active workspace when picking a candidate to move, and records
  `active-on-<monitor>-before=false` explicitly in the FACT line, so "no cursor warp" (expected
  here) is never printed in a form indistinguishable from a genuine failure to warp in the
  active-on-the-focused-monitor case, which is not exercised live by this probe at all.
- **Tooling note, not a compositor fact:** `hyprctl eval <code>` does not print a Lua chunk's
  return value — only `ok` on success or `error: ...` on failure (confirmed against `hyprctl
  --help`'s own description of the two subcommands, and by direct test: `hyprctl eval "return
  42"` → `ok`, `hyprctl repl "return 42"` → `42`). `hyprctl repl <code>` is the subcommand that
  evaluates a one-shot Lua string and prints its result, and is what `actions-probe.sh`'s `ev()`
  helper uses to read `get_windows()`'s shape back out. This is a deviation from the brief's script
  text (which used `eval` in `ev()`); every other call in the probe is either an `hyprctl dispatch`
  (fire-and-forget, verified by a subsequent fresh `-j` read) or a plain `-j` read, so this affects
  only how a *test script* recovers a Lua return value, not any dispatcher contract the real
  plugin chunks rely on — but any later probe or Tier 2 live check that wants a Lua expression's
  value back, rather than just its side effect, needs `repl`, not `eval`. A second tooling note
  from the fix round: `hyprctl <unknown-subcommand>` prints `unknown request` and **exits 0** on
  this build, so `ev()` additionally proves `repl` itself is available and returns a value
  (`hyprctl repl 'return 1' | grep -qx 1`) before relying on it, and checks `hyprctl repl`'s exit
  status directly rather than through a pipe — a Lua error there exits 7, which is only visible to
  `set -e`/`pipefail` if the failing command is not laundered through `sed` or a second pipeline
  stage first.
