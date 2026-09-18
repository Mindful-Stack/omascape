# Omascape — peek: hold Space to preview the target (design)

Date: 2026-09-18 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1 ·
builds on actions (`actions-omascape` at `da9075b`).
Status: **approved design, pre-implementation.** Branch `peek`.

## Goal

Hold `Space` to blow the current target up to 60% of the screen — a Quick Look for the overview.
Release to dismiss. Navigation keeps working underneath while it is held, so `Space`+`Tab` is a
big flip-through: hold, Tab to the right window, release, Enter.

## Scope

**In:** a `Space`-held preview layer sized to 60% of the screen; window targets rendered as one
large live capture; workspace targets rendered as a full mini-map at peek size; the peek
following a changing target while held; `Space` ceasing to be a find-query character; auto-repeat
and focus-loss guards; a hint row entry; tests.

**Out:** a latched/toggled peek (tap-to-pin was considered and rejected — see Decisions); peeking
from outside the overview; a config key for the 60% figure; peek of anything that is not a
resolved target; zoom/pan inside the peek; a peek for the monitor-group header.

## Decisions (brainstorm 2026-09-18)

- **The peek shows whatever `Logic.target` resolves, and nothing else.** A window target (hover,
  Tab cursor, or find match) peeks that window; a workspace target (hover over empty canvas, or
  the selected workspace with no cursor) peeks that whole workspace; **no target peeks nothing**.
  This is not a new targeting rule — it is the existing one (`logic.js:1015`), which already
  treats "no target" as terminal rather than falling back. The peek therefore cannot show
  something the user is not looking at, for the same reason `Ctrl+W` cannot close one.

- **`Space` always peeks, unconditionally — it is no longer a query character.** The one conflict
  is that `Space` currently extends an active find query. It is being taken, because the state
  where peek is most valuable is exactly the state find puts you in: you searched, you got a
  match, you want to confirm it is the right window before committing with Enter. The cost is
  small and measurable: find is a *subsequence* fuzzy (`fuzzyScore`, `logic.js:906`), so `googlec`
  matches "Google Chrome" just as `google c` does. `_wordStart` reads the **haystack**, not the
  needle, so the `c` still collects its +3 word-start bonus either way; only the space's own +1
  and its consecutive-adjacency bonus are lost, which does not reorder realistic results.

- **The peek follows the target while held.** It is a `readonly property` derived from
  `resolveTarget()`, which already recomputes on every hover, cursor and match change. "Following"
  is therefore the *absence* of a snapshot, not a mechanism: there is no state machine, no
  press-time capture, and no way for the peek and the grid to disagree about what is targeted.

- **Hold only; no tap-to-latch.** A tap-latches-open variant was considered and rejected: it makes
  the gesture timing-dependent, and tap/hold ambiguity is a reliable source of "it did the wrong
  thing". Hold has exactly two states and both are visible in the user's own hand.

- **A workspace peek is a real mini-map with fresh captures, not an upscale.** Scaling the
  existing tile delegates up would be nearly free, but grid thumbnails are captured at roughly
  370×230; blown up ~3× they are visibly soft, which defeats the point of looking closer. The
  re-layout is cheap because `_tileRect(win, mon, box, P, slot)` (`logic.js:44`) already maps a
  window into an **arbitrary** box — the peek passes a box of peek size and gets tile rects back.

- **60% is a box, not a stretch.** Content is fitted inside a 60%×60% box preserving aspect ratio.
  A window peek uses the window's own `sw`/`sh`; a workspace peek uses `_monLogical(mon).w/h` —
  the same aspect `cellHeightFor` uses for grid cells, so the peek and the cell can never disagree
  about a monitor's shape.

## Behaviour

| Input                                  | effect                                                       |
|----------------------------------------|--------------------------------------------------------------|
| `Space` down, target is a window       | peek layer opens showing that window at peek size            |
| `Space` down, target is a workspace    | peek layer opens showing that workspace's mini-map           |
| `Space` down, no target                | nothing; no layer, no flicker                                |
| `Space` down, menu or dialog open      | nothing (both already consume every key, see below)          |
| `Space` held, `Tab` / `Shift+Tab`      | cursor advances; **peek re-targets live**                    |
| `Space` held, arrows                   | selection or match moves; peek re-targets live               |
| `Space` held, pointer moves            | hover retargets; peek follows                                |
| `Space` held, target disappears        | peek closes; the hold does not re-open it for a new target   |
| `Space` up                             | peek closes; selection/cursor stand where navigation left them |
| `Space`, any state                     | never extends the find query                                  |
| `Escape` while peeking                 | keeps its existing meaning (clear cursor / clear query / close); the peek is bound to the held key alone |

The peek changes no compositor state whatsoever. Releasing `Space` leaves exactly the selection,
cursor and query that the keys pressed during the hold would have left on their own.

## The peek layer

A new item in `panel`, a sibling of `card`, stacked above it. It needs no z-order arbitration
against the menu or the confirmation dialog: `Keys.onPressed` returns early for both
(`Overview.qml:1490` for `confirmOpen`, `:1492` for `menuOpen`), so `Space` cannot reach the peek
while either is open, and neither can open while `Space` is down.

```
peekBoxW = Math.round(panel.width  * 0.6)
peekBoxH = Math.round(panel.height * 0.6)
k        = Math.min(peekBoxW / aspectW, peekBoxH / aspectH)     // fit, never stretch
```

Backdrop: the existing `root.scrim`, at a step above the card's own, so the grid reads as
"behind" rather than as competing content. The peek carries the same `cardRadius` and the card's
`SoftShadow` treatment so it reads as the same material as the picker.

**Window target.** One `ScreencopyView` on `handleByAddress[addr]`, the same path `WindowTile.qml`
uses, with the existing icon fallback for windows that have no toplevel handle. The ROADMAP's
verified facts apply unchanged: screencopy works occluded, cross-output, and on workspaces not
shown on any monitor, so a peek of a window on a hidden workspace is live, not a placeholder.

**Workspace target.** `Logic.peekTiles(windows, mon, boxW, boxH, P)` — a new pure function that
calls the existing `_tileRect` with a synthetic box `{x: 0, y: 0, w: boxW, h: boxH}` and returns
the same `{address, x, y, w, h, layer, fullscreen}` rows the grid already consumes. Rendered with
the existing tile delegate at peek size, each with its own `ScreencopyView`. This means a second
set of live captures exists while the peek is held — bounded by one workspace's window count, and
torn down on release.

## Edge cases

- **Key auto-repeat.** A held `Space` repeats at the compositor's rate. The press handler guards
  on `e.isAutoRepeat`, so the peek opens once; repeats are swallowed, not re-entered.
- **Focus loss mid-hold.** The overlay holds `OnDemand` keyboard focus (`Overview.qml:1419`). If
  focus leaves while `Space` is down, the release event never arrives and the peek would stick
  open forever. `peeking` is force-cleared when `opened` drops and when the panel loses keyboard
  focus — the release handler is a second path to the same clear, never the only one.
- **Target vanishes while held** (the window closes, the workspace empties). The peek closes: its
  target property resolves to null and the layer is a binding on it. It does not silently slide to
  a neighbour, which would be a target the user never chose.
- **Peeking a fullscreen window.** Peeks at the window's real aspect like any other; the grid's
  recovered-slot handling is a grid-layout concern and does not apply to a single large capture.
- **Peeking the scratchpad row.** A normal workspace target; the row must be shown (`Ctrl+S`) for
  it to be targetable at all, which is already true of every other action.
- **A window with no handle.** Icon fallback at peek size, exactly as the grid tile does. A large
  icon on a plain field is the honest rendering of "there are no pixels to show".
- **`Space` while the overview is closing.** `opened` is already false, the key handler is not
  reached, and the force-clear has already run.

## Tests

**Tier 1 (`logic.js`, pure, CI):**
- `peekTiles` returns the same relative geometry as the grid for the same workspace at a
  different box size — a window centred in its cell stays centred; ratios between tiles hold.
- `peekTiles` on an empty workspace returns `[]`.
- `peekTiles` clamps to `minTileW`/`minTileH` the way `_tileRect` does, at peek scale.
- The fit calculation preserves aspect: a 16:9 window in a 60% box of a 16:10 screen is
  letterboxed vertically, never stretched.
- `appendQueryText` continues to reject a leading space (unchanged), and the key-handler-level
  interception of `Qt.Key_Space` is asserted in the key-routing suite rather than in the matcher.

**Key routing:**
- `Space` with an active query does not change the query.
- `Space` with `menuOpen` or `confirmOpen` reaches neither the peek nor the query.
- An auto-repeat `Space` press is a no-op when already peeking.

**Tier 2 (nested Hyprland):**
- Hold `Space` over a hovered tile, confirm one large capture appears and the grid is still live.
- Hold `Space`, press `Tab` twice, confirm the peek shows the third window without releasing.
- Release and confirm the cursor sits where `Tab` left it and no compositor state changed.
