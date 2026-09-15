# Omyview — actions: target, window cursor, close, context menu (design)

Date: 2026-09-15 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1 ·
builds on find, the scratchpad row and the workspace lock (`main` at `26c6c11`).
Status: **approved design, pre-implementation.** Branch `actions`.

## Goal

Act on what the overview shows without leaving it: close a window, float or fullscreen it, lock a
workspace, move or swap a workspace between monitors, close everything on a workspace — by mouse
(a right-click menu) and by keyboard (a window cursor plus Ctrl+W). The same "target" notion is
what the later preview feature (hold Space) will zoom.

## Scope

**In:** a single target rule shared by every action; a Tab-driven window cursor inside the selected
workspace; Ctrl+W; a right-click context menu on tiles and wells; the actions Close, Float/Tile,
Fullscreen/Exit fullscreen (window) and Lock/Unlock, Move to ‹monitor›, Swap with ‹monitor›, Close
all windows (workspace); a two-tier hint row; tests.

**Out:** the preview itself (its own spec, next), a keyboard-opened menu (the Menu key / Shift+F10
— decided against for now; every workspace action has a key already except Move/Swap, which are
mouse-only until asked for), a hover close button on tiles, drag-to-trash, confirmation dialogs
(apps prompt for unsaved work themselves), per-item disabled states (what does not apply is
hidden), persisting the hint tier across shell restarts, pinning, grouping, renaming workspaces.

## Decisions (brainstorm 2026-09-15)

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
  *live* (moved since the last key press).
- **Hints in two tiers**, toggled by `?`: the primary row stays short; the advanced keys live on a
  second line shown on demand.
- **Swap is two moves in one chunk**, not `workspace.swap_monitors`: verified in the 0.56.2 source
  (`LuaBindingsDispatchers.cpp`) that `swap_monitors` swaps the two monitors' *active* workspaces
  only, while `hl.dsp.workspace.move({ monitor, workspace })` moves any workspace, hidden ones
  included (`hlWorkspaceMove` → `dsp_moveWorkspaceToMonitor`). Two moves generalise the swap to any
  workspace.
- **Every new action is one atomic guarded Lua chunk** in the existing style, except Close, which
  stays the plain `window.close` dispatch the middle click already uses.

## The target — `Logic.target(input)`

The window or workspace an action applies to, resolved *at the moment of the action* by one pure
function. Input: whether the pointer is live and its canvas position, the tiles and boxes, the
selected find match, the cursor address and the selected workspace id. Output: `{ kind: "window",
address }`, `{ kind: "workspace", id }`, or `null`.

1. **Pointer live and inside the canvas** → the topmost tile under it (`Logic.tileAt`), else the
   well under it (`Logic.hitWorkspace`).
2. **Otherwise the keyboard target** → the selected find match while a query is active, else the
   Tab cursor, else the selected workspace.

`Logic.tileAt(tiles, x, y)` prefers a higher `layer` (floating over tiled over backdrop) and, within
a layer, the later tile in model order (stacking). It uses the same canvas-space point drop
targeting uses (`dragPointer()`: viewport point + scroll offset) and never relies on overlapping
`HoverHandler`s.

`pointerLive` is a root property: set `true` by a canvas-level `HoverHandler` whenever its point
moves inside the canvas and cleared on every key press in the key catcher and whenever the pointer
leaves the canvas. The right-click menu does not consult it — a right press *is* the pointer being
live — and records its target explicitly when it opens.

## The window cursor

`cursorAddress: string` on the root (`""` = none), mirrored into a `cursor` tile role. The tile
draws it as the accent ring find already draws (`matchOutline`: `matched || cursor` shows the ring,
`selectedMatch || cursor` makes it 2 px). Find and cursor never coexist: `setQuery()` with a
non-empty query clears the cursor, and Tab with a query cycles matches as today.

| Key (query empty)  | effect                                                                                  |
|--------------------|-----------------------------------------------------------------------------------------|
| Tab / Shift+Tab    | next / previous window of the selected workspace in reading order, wrapping; none → first / last; empty workspace → nothing |
| ← → ↑ ↓, digits    | as today, and clear the cursor                                                           |
| Enter              | with a cursor: focus that window (the tile-click path, scratchpad raise included) and close; without: jump |
| Esc                | clear the cursor if set; else (as today) clear the query if set; else close              |
| Ctrl+W             | close the target if it is a window; if that window is the cursor, move the cursor to its successor first (next in cycle order, or none), so repeated Ctrl+W clears a workspace; workspace target → nothing |
| Ctrl+L             | unchanged (locks the *selected workspace*, not the target — a cursor never changes what Ctrl+L does) |

Reading order is `Logic.cycleWindows(tiles, wsId, current, step)`: the workspace's tiles sorted by
`y` then `x` (canvas rects, so a fullscreen window's recovered slot counts, and floating windows
sort by where they are). Pure, Tier 1 tested.

On a rebuild the cursor survives if its window is still on the selected workspace; otherwise it
clears (no successor rule — unlike find, nothing was typed to preserve). `open()` clears it.

## The menu

**Component.** `ContextMenu.qml`, drawn like the rest of the plugin (no Qt Quick Controls): a
card-coloured `Rectangle` with `boxRadius` and a `SoftShadow`, one row per item, hover and keyboard
highlight both painted `selBackground`/`selText`. Width follows the longest label plus padding.
Inputs: `items` (`[{ id, label, glyph? }]`), `index` (keyboard highlight, -1 none), theme and
`motion`. Signals: `activated(id)`, `dismissed()`. Display-only: no key handling, no focus — the key
catcher stays the single focus item.

**Placement.** In the canvas layer above the drag ghost (`z` above 99999), at the press point in
canvas coordinates, nudged left/up so it stays fully inside the Flickable viewport. It does not
scroll with the canvas: a wheel/edge scroll while open dismisses it.

**Opening.** A right press on a tile (`dragArea` gains `Qt.RightButton`; a right press never starts
a drag and never counts as a click) opens the window menu for that tile's address. A right press on
a well's empty area (the box `MouseArea`) opens the workspace menu for that workspace. The menu
records `menuTarget` when it opens; pointer moves afterwards cannot change what it acts on. A right
press during a drag is ignored. A right press on the scrim closes the overview like a left click.

**Items — `Logic.menuItems(target, ctx)`.** Pure, Tier 1 tested. `ctx` carries the window record
(floating, fullscreen mode, workspace id), the box record (occupied, armed, special, synthetic,
monitorName) and the monitor list. Hidden, never greyed:

| target    | item                       | shown when                                                  |
|-----------|----------------------------|-------------------------------------------------------------|
| window    | Close                      | always                                                      |
| window    | Float / Tile               | always; label by `floating`                                 |
| window    | Fullscreen / Exit fullscreen | always; "Exit fullscreen" when `fullscreen > 0` (maximized included) |
| workspace | Lock / Unlock              | always; label by `armed`                                    |
| workspace | Move to ‹monitor›          | one per *other* monitor, glyph as the chips (laptop/screen); not on the scratchpad, not on a synthetic (uncreated) workspace, never with one monitor |
| workspace | Swap with ‹monitor›        | same conditions as Move                                     |
| workspace | Close all windows          | `occupied` only                                             |

Order as listed. Windows on a placeholder box have no tiles, so no menu; the well's menu still
offers Lock/Unlock (and Close all if occupied). Item ids: `close`, `float`, `fullscreen`, `lock`,
`move:<monitor>`, `swap:<monitor>`, `closeAll`.

**While open** (`menuOpen`, a key-catcher branch checked *before* `finding`):

| input                     | effect                                                       |
|---------------------------|--------------------------------------------------------------|
| ↑ / ↓                     | move the highlight, wrapping; ↓ from none → first             |
| Enter                     | activate the highlighted item (none → nothing)                |
| Esc                       | dismiss                                                       |
| any other key             | dismiss and swallow (a letter does not start a query)         |
| press inside the menu     | activate that row                                             |
| press anywhere else       | dismiss and swallow — including on the scrim, so a stray click can never both dismiss the menu and close the overview; a full-card transparent `MouseArea` below the menu and above everything else, visible only while `menuOpen` |
| hover a row               | highlight follows the pointer (same `index`)                  |

Activation dismisses first, then dispatches. The menu also dismisses when a rebuild finds its target
gone (window closed, workspace destroyed), on `close()`, and on a scroll.

## Compositor side

All in `logic.js`, one line each, parse- and behaviour-tested by `tests/lua-check.sh` against the
mock `hl`, using `dispatchGuardLua`, `pcall`, `reportLua(what)` and — wherever a dispatcher can move
focus or the cursor — `restoreFocusLua`. Address prefix handling as in `restoreFocusLua` (Lua may
report addresses without `0x`).

- **Close** — `hl.dsp.window.close({ window = "address:…" })`, the existing plain dispatch,
  shared by Ctrl+W, middle-click and the menu.
- **Float / Tile** — `toggleFloatLua(addr)`: `run(hl.dsp.window.float({ window = sel, action =
  "toggle" }))` inside the guard, focus and cursor restored. Works on hidden workspaces.
- **Fullscreen / Exit** — `setFullscreenLua(addr, mode)` generalises `unfullscreenLua` (which
  becomes `setFullscreenLua(addr, 0)`) around the existing `fullscreenBodyLua`. Entering uses mode
  2. The badge's optimistic `pendingFullscreen` already records a target `mode`, so both
  directions use it: the badge hides now for an exit, and for an entry nothing is optimistic (no
  badge to hide; the slot changes when data lands).
- **Lock / Unlock** — `lockToggleSelected()` generalised to `lockToggle(wsId)`; Ctrl+L calls it
  with `selectedId`, the menu with its target. Same ordering as today: memory → sync → persist.
- **Move to ‹monitor›** — `workspaceMoveLua(wsId, monitorName)`: `run(hl.dsp.workspace.move({
  monitor = "<name>", workspace = "<id>" }))`. The compositor decides what each monitor shows
  afterwards (a moved active workspace leaves its old monitor on another workspace); the overview
  stays on its own screen and rebuilds. Groups key on the lowest workspace id per monitor, so
  moving ws 3 to a monitor that held 6–10 can reorder the groups; layout motion glides it.
  Monitor names are interpolated from `Hyprland.monitors` and validated
  (`/^[A-Za-z0-9._-]+$/`) before they can reach a chunk.
- **Swap with ‹monitor›** — `workspaceSwapLua(wsId, monitorName)`: in Lua, read the target's own
  monitor (`hl.get_workspace("<id>").monitor`) and the other monitor's active workspace
  (`hl.get_active_workspace("<name>")`), move the target to the other monitor, then move the
  other workspace back to the target's original monitor. One chunk, so nothing renders between
  the two moves. If the other monitor has no active workspace (cannot happen on a mapped monitor,
  guarded anyway) only the first move runs. If the target's monitor *is* the other monitor,
  nothing happens.
- **Close all windows** — `closeAllLua(wsId)`: Lua reads the workspace's own window list
  (`HL.Workspace:get_windows()` per the stubs — **its return shape is the plan's first task, a live
  probe on 0.56.2**, like the lock spec's rule-semantics probe) and dispatches one `window.close`
  per address, each step guarded on its own so one refusal never stops the rest. Lua reads the
  list rather than the overview passing it, so windows the overview never laid out (a `null`
  `_tileRect`) are closed too. Special workspaces by name (`wsSelector`).

Failures surface through the existing path: compositor log line + notification naming the step.

## Data flow and optimistic state

No new optimistic rows. Every action produces compositor events (`closewindow`, `changefloatingmode`,
`fullscreen`, `moveworkspacev2`, `workspacev2`, …) that already trigger `scheduleRebuild()`, and the
settle rebuild shows the truth within a few ticks. Specifically:

- **Close**: the tile vanishes on the rebuild that no longer lists the window (as with the middle
  click today). The cursor, if it was that window, has already moved to the successor.
- **Close all**: cursor clears when its window goes; the well shows empty on the next rebuild.
- **Move / Swap**: boxes move between groups on the rebuild; the selection follows the workspace
  id (existing rule); the menu is already dismissed.
- **Float / Fullscreen**: the tile re-lays out from fresh geometry; `pendingFullscreen` as above.

`Overview` gains: `pointerLive: bool`, `pointerCanvasX/Y: real`, `cursorAddress: string`,
`menuOpen: bool`, `menuTarget: var`, `menuItems: var`, `menuIndex: int`, `menuX/Y: real`,
`hintsExpanded: bool`. `open()` resets everything but `hintsExpanded`.

## Hints — two tiers

The primary row: `1–0 jump`, `↑ ↓ ← → move`, `↵ select`, `drag move window`, `type find`,
`esc close`, `? more`. Pressing `?` with an empty query, or clicking the `? more` cap, toggles
`hintsExpanded`, which shows a second line beneath: `tab window`, `ctrl+w close`, `right-click
menu`, `ctrl+s scratchpad`, `ctrl+l lock` (and `space preview` once that ships). With a query
active, `?` appends to the query as today (`appendQueryText` is unchanged; the key handler checks
`query.length` first). The `? more` cap reads `? less` while expanded. The state lives on the
kept-loaded component, so it persists between summons until a shell restart, and is not written to
config. `card.hintSpace` reserves one line, or two while expanded, and the card height glides
(`layoutMotion`). The find bar replaces both tiers while a query is active, as it replaces the one
row today. `config.hint: false` hides both tiers.

## Edge cases

- **Pointer parked over a tile, keyboard in use**: `pointerLive` is false after the first key, so
  Ctrl+W, Enter and (later) Space act on the keyboard target. Moving the mouse makes it live again.
- **Tab cursor set, then the mouse moves over another tile**: the pointer is live, so Ctrl+W acts
  on the hovered tile; the ring stays where it was (it shows the *keyboard* target, which is still
  valid the moment the keyboard is used again).
- **Cursor window moved by a drag** (the user drags the ringed tile elsewhere): after the drop the
  window is no longer on the selected workspace → the cursor clears on the rebuild.
- **Menu open, target closes underneath** (another actor): dismissed on the rebuild that drops it.
- **Menu open, overview toggled with SUPER+P**: `close()` dismisses it.
- **Move/Swap to a monitor unplugged between open and click**: the chunk's `run()` raises on the
  compositor's error; reported like any other failed step. `menuItems` is recomputed from
  `Hyprland.monitors` at open, so this window is a few hundred milliseconds at most.
- **Lock from the menu on a placeholder box**: exactly Ctrl+L on it — the unresolved/malformed
  locks-file guards apply unchanged.
- **Right press while a query is active**: allowed; the menu opens, the query stays; a menu key
  press is consumed by the menu branch first.
- **Hyprland forwards SUPER chords** over the overlay (verified in v1): SUPER+W would close the
  *desktop's* focused window, not the target — unchanged, and why the overview has Ctrl+W.

## Tests

- **Tier 1, `tests/tst_actions.qml`** (pure): `tileAt` — topmost by layer then order, miss →
  null; `target` — live pointer over tile / well / nothing, stale pointer falls through to match,
  cursor, workspace, in that order, `null` when nothing is selected; `cycleWindows` — reading
  order (y then x), wrap both ways, none → first/last, empty workspace → `""`, current not on the
  workspace → first; `menuItems` — each row of the table above (window floating/tiled/fullscreen/
  maximized; workspace armed/unarmed, occupied/empty, scratchpad, synthetic, one vs two vs three
  monitors, monitor glyph by connector name); monitor-name validation refuses anything outside
  `[A-Za-z0-9._-]`.
- **Tier 1, Lua suite (`tests/lua/tst_chunks.lua`)**, mock `hl` extended with `hl.dsp.window.close`,
  `hl.dsp.window.float`, `hl.dsp.workspace.move`, `hl.get_workspace(sel).monitor`,
  `hl.get_active_workspace(monitorSel)` and `HL.Workspace:get_windows()` — applied in
  `hl.dispatch`, never no-ops: `toggleFloatLua` flips `floating` and restores focus + cursor; a
  throwing float is reported; `setFullscreenLua(addr, 2)` on a tiled window ends fullscreen 2,
  `(addr, 0)` on a maximized one ends 0, either on an already-matching window dispatches nothing;
  `workspaceMoveLua` dispatches one move with the right monitor and workspace strings;
  `workspaceSwapLua` dispatches exactly two moves in order (target out, other back) and one when
  the other monitor's active workspace is nil, none when the target already sits on that
  monitor; `closeAllLua` closes every window the workspace lists (including one the input never
  showed) and a refused close still lets the others run, reported once; every chunk parses.
- **Tier 1, offscreen UI (`tests/ui/actions.qml`)**: Tab rings the first window in reading order,
  Tab again the second, Shift+Tab wraps; an arrow clears the ring; Enter with a cursor dispatches
  `focus` for that address and closes; Ctrl+W on a cursor window dispatches `close` for it and
  moves the ring to the next; Ctrl+W with a workspace target dispatches nothing; **parked-mouse
  rule**: a synthetic pointer move over a tile then a key press → Ctrl+W acts on the keyboard
  target; a pointer move after the key → Ctrl+W acts on the hovered tile; right press on a tile
  opens the window menu with Close/Float/Fullscreen and does not start a drag; right press on a
  well opens the workspace menu; a single-monitor seed shows no Move/Swap, a two-monitor seed
  shows one of each naming the other monitor; ↓ ↓ Enter activates the second item and dispatches
  the expected chunk; Esc dismisses without dispatching; a press outside dismisses and the overview
  stays open (positive control: the same press with no menu closes it); the menu dismisses when a
  rebuild removes its window; typing a letter with the menu open dismisses it and does not start a
  query; middle-click still dispatches `close`; `?` toggles the second hint line and the card's
  hint space, and `?` with a query active appends instead; `open()` clears cursor and menu but
  keeps `hintsExpanded`.
- **Tier 2 / live (plan's first task)**: probe `get_windows()`'s return shape and address format on
  0.56.2; then, on the nested Hyprland rig, move a hidden workspace to the other monitor, swap a
  non-active workspace with the other monitor's active one, and close-all on a workspace with a
  floating and a tiled window, asserting end state through `hyprctl -j`.
