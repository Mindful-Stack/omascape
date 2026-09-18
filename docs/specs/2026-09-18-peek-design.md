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
following a changing target while held; a hold cancelled by the target's disappearance or by a
modal opening; `Space` ceasing to be a find-query character and becoming an action key;
auto-repeat and focus-loss guards; the extraction of the grid's per-window placement into a
helper shared with the peek; a hint row entry; tests.

**Out:** a latched/toggled peek (tap-to-pin was considered and rejected — see Decisions); peeking
from outside the overview; a config key for the 60% figure; peek of anything that is not a
resolved target; zoom/pan inside the peek; a peek for the monitor-group header.

## Decisions (brainstorm 2026-09-18)

- **The peek shows whatever `Logic.target` resolves, and nothing else.** A window target (hover,
  Tab cursor, or find match) peeks that window; a workspace target (hover over empty canvas, or
  the selected workspace with no cursor) peeks that whole workspace; **no target peeks nothing**.
  This is not a new targeting rule — it is the existing one (`logic.js:1046`), which already
  treats "no target" as terminal rather than falling back. The peek therefore cannot show
  something the user is not looking at, for the same reason `Ctrl+W` cannot close one. That rule
  covers only the case where *nothing at all* is targetable; it does **not** make a peeked
  target's disappearance visible, because the fallbacks below it stay live — see the next
  decision.

- **A disappearing target cancels the hold; navigation retargets it.** `Logic.target` falls
  *through* on disappearance, it does not go null: a cleared cursor lands on the selected
  workspace, `cycleMatch` picks a successor match, and an emptied workspace stays targetable. So
  "the binding goes null" cannot be the mechanism. The peek instead remembers the identity it is
  showing — `peekedKey`, the window address or the workspace id — and watches the **model**, not
  the resolved target: when that identity leaves the model the hold is *cancelled*, and the layer
  goes and stays gone until `Space` is physically released. It therefore cannot re-open on a
  successor match, on a fallback to the selected workspace, or on a later hover. Navigation is the
  complement and needs no special case: `Tab`, the arrows, `Escape` and the pointer all change the
  *resolved* target while the old identity is still in the model, so they retarget the peek and
  `peekedKey` follows them. A workspace is gone when it leaves `boxes`; a workspace that merely
  empties is still a target and peeks as an empty mini-map.

- **Anything modal that opens cancels the peek.** A context menu opens from a right-click
  (`openMenu`, `Overview.qml:618`), which the key handler never sees, and `Ctrl+W` can raise the
  confirmation dialog from inside a hold — so "neither can open while `Space` is down" is not
  true, and the peek does need a rule. It yields rather than stacking: opening either one
  force-clears `peeking` and sets the cancel above, through the same path focus loss already uses.
  The menu never has to arbitrate z-order against the peek, and dismissing the menu does not pop
  the peek back up under a still-held key. Blocking the right-click instead (the `dragTile`
  guard's precedent, `Overview.qml:619`) was rejected: to stay uniform it would have to block
  `Ctrl+W` too, silently disabling an action because a key is held.

- **`Space` is an action key, so it peeks what the pointer is over.** Peek acts on the target
  exactly as `Enter` and `Ctrl+W` do, and the key handler clears `pointerLive` for every key that
  is *not* an action key, before any resolve can see it (`Overview.qml:1518`). Without this,
  hovering one window and pressing `Space` would preview the Tab cursor instead. `Qt.Key_Space`
  therefore joins `Logic.isActionKey` (`logic.js:1200`) rather than being special-cased in QML:
  the rule stays in the pure layer, where the Tier 1 suite asserts it alongside `Enter` and
  `Ctrl+W`. Only bare `Space` qualifies — a chorded `Space` falls through to the chord branch,
  where it matches nothing.

- **`Space` always peeks, unconditionally — it is no longer a query character.** The one conflict
  is that `Space` currently extends an active find query. It is being taken, because the state
  where peek is most valuable is exactly the state find puts you in: you searched, you got a
  match, you want to confirm it is the right window before committing with Enter. The cost is
  small and measurable: find is a *subsequence* fuzzy (`fuzzyScore`, `logic.js:937`), so `googlec`
  matches "Google Chrome" just as `google c` does. `_wordStart` reads the **haystack**, not the
  needle, so the `c` still collects its +3 word-start bonus either way; only the space's own +1
  and its consecutive-adjacency bonus are lost, which does not reorder realistic results.

- **The peek follows the target while held.** It is a `readonly property` derived from
  `resolveTarget()`, which already recomputes on every hover, cursor and match change. "Following"
  is therefore the *absence* of a snapshot, not a mechanism: there is no state machine, no
  press-time capture, and no way for the peek and the grid to disagree about what is targeted.
  The hold carries exactly three pieces of state and no more — `peeking` (the key is down and the
  hold is live), `peekedKey` (the identity on screen, for the disappearance test) and
  `peekCancelled` — and none of them is a copy of the target's geometry or its contents.

- **Hold only; no tap-to-latch.** A tap-latches-open variant was considered and rejected: it makes
  the gesture timing-dependent, and tap/hold ambiguity is a reliable source of "it did the wrong
  thing". Hold has exactly two states and both are visible in the user's own hand.

- **A workspace peek is a real mini-map with fresh captures, not an upscale.** Scaling the
  existing tile delegates up would be nearly free, but grid thumbnails are captured at roughly
  370×230; blown up ~3× they are visibly soft, which defeats the point of looking closer. The
  re-layout is cheap because the grid's placement already maps a window into an **arbitrary** box
  (`_tileRect(win, mon, box, P, slot)`, `logic.js:44`, and the slot/layer step above it) — the
  peek hands that same code a box of peek size and gets tile rects back. See *Workspace target*
  for why it must be that whole step and not `_tileRect` alone.

- **60% is a box, not a stretch.** Content is fitted inside a 60%×60% box preserving aspect ratio.
  A window peek uses the window's own `sw`/`sh`; a workspace peek uses `_monLogical(mon).w/h` —
  the same aspect `cellHeightFor` uses for grid cells, so the peek and the cell can never disagree
  about a monitor's shape.

## Behaviour

| Input                                  | effect                                                       |
|----------------------------------------|--------------------------------------------------------------|
| `Space` down, target is a window       | peek layer opens showing that window at peek size            |
| `Space` down, target is a workspace    | peek layer opens showing that workspace's mini-map           |
| `Space` down over a tile, keyboard target elsewhere | peeks the **hovered** tile (`Space` is an action key) |
| `Space` down, no target                | nothing; no layer, no flicker — and nothing for the rest of that hold |
| `Space` down, menu open                | dismisses the menu and nothing else; the still-held key does not then peek |
| `Space` down, dialog open              | consumed by the dialog; no peek                               |
| `Space` held, `Tab` / `Shift+Tab`      | cursor advances; **peek re-targets live**                    |
| `Space` held, arrows                   | selection or match moves; peek re-targets live               |
| `Space` held, pointer moves            | hover retargets; peek follows                                |
| `Space` held, `Escape` clears the cursor | target falls back to the selected workspace; peek retargets to it |
| `Space` held, target disappears        | hold **cancelled**: layer goes, and no target re-opens it before release |
| `Space` held, menu or dialog opens     | hold cancelled; the modal opens; dismissing it does not bring the peek back |
| `Space` held, overview loses focus     | hold cancelled and force-cleared; the release may never arrive |
| `Space` auto-repeat while peeking      | swallowed; never a second open, never a close                |
| `Space` up                             | peek closes; the cancel clears; selection/cursor stand where navigation left them |
| `Space`, any state                     | never extends the find query                                  |
| `Escape` while peeking                 | keeps its existing meaning (clear cursor / clear query / close); the peek is bound to the held key alone |

The peek changes no compositor state whatsoever. Releasing `Space` leaves exactly the selection,
cursor and query that the keys pressed during the hold would have left on their own.

## The peek layer

A new item in `panel`, a sibling of `card`, stacked above it. It needs no z-order arbitration
against the menu or the confirmation dialog, in both directions:

- **Modal first, then `Space`.** `Keys.onPressed` returns early for both (`Overview.qml:1507` for
  `confirmOpen`, `:1510` for `menuOpen`), so `Space` cannot reach the peek branch while either is
  open — it neither peeks nor reaches the query.
- **`Space` first, then modal.** The modal wins and the peek yields: `openMenu` and the dialog's
  open path both call the peek's force-clear, which drops `peeking` and sets `peekCancelled`.
  The two are therefore never on screen together, and the peek does not return when the modal
  goes while `Space` is still down.

```
peekBoxW = Math.round(panel.width  * 0.6)
peekBoxH = Math.round(panel.height * 0.6)
k        = Math.min(peekBoxW / aspectW, peekBoxH / aspectH)     // fit, never stretch
```

Backdrop: the existing `root.scrim`, at a step above the card's own, so the grid reads as
"behind" rather than as competing content, and following `config.scrim` the same way the card's
own scrim does — off means no backdrop, but the frame keeps its opaque background and shadow. The
peek carries the same `cardRadius` and the card's `SoftShadow` treatment so it reads as the same
material as the picker.

**Window target.** One `ScreencopyView` on `handleByAddress[addr]`, the same path `WindowTile.qml`
uses, with the existing icon fallback for windows that have no toplevel handle. The ROADMAP's
verified facts apply unchanged: screencopy works occluded, cross-output, and on workspaces not
shown on any monitor, so a peek of a window on a hidden workspace is live, not a placeholder.

**Workspace target.** `Logic.peekTiles(windows, mon, boxW, boxH, P)` — a new pure function
returning the same `{address, x, y, w, h, layer, fullscreen}` rows the grid already consumes,
rendered with the existing tile delegate at peek size, each with its own `ScreencopyView`. This
means a second set of live captures exists while the peek is held — bounded by one workspace's
window count, and torn down on release.

It must **not** call `_tileRect` on its own. `_tileRect` is only the last step of the grid's
placement: `buildLayout` first collects the workspace's non-fullscreen tiled rects in
usable-rect-local coordinates (`tiledByWs`, `logic.js:305`), then chooses a fullscreen window's
`slot` — `recoverSlot` for a tiled one, the 20%/60% inset box for a floating one, the whole
usable rect with `layer: 0` when recovery is ambiguous — and assigns `layer`/`fullscreen`
(`logic.js:318-339`). Skipping that, a fullscreen window would be placed by the bare geometry
heuristic and cover its neighbours in the peek, which the geometry-parity test below forbids.

So that whole per-window step is extracted into one pure helper — `_placeWindows(wins, mon, box,
P)`, taking the windows of a single workspace and the box to place them in, returning the rows —
and called from both sites:

```
_placeWindows(wins, mon, box, P)
  ├── buildLayout(...)   box = the workspace's grid cell
  └── peekTiles(...)     box = { x: 0, y: 0, w: boxW, h: boxH }
```

Parity then holds by construction rather than by review. The slot recovery is box-independent —
it works in usable-rect-local coordinates off the real monitor, never off the box — so the same
slot is recovered at cell size and at peek size, and only the final `_tileRect` mapping differs.

## Edge cases

- **Key auto-repeat.** A held `Space` repeats at the compositor's rate; the peek must open once,
  and a repeat must not re-evaluate the open decision either — after a cancel the repeats keep
  arriving and none of them may re-open the layer. The guard is therefore on **state, not on the
  flag**: the press handler returns early when `peeking || peekCancelled` is already true, and
  `e.isAutoRepeat` is at most a cheap early-out in front of it. That is deliberate and testable —
  QtTest's QML key API cannot set `isAutoRepeat` (`tests/ui/actions.qml:426`), so a flag-only
  guard would have no offscreen test at all, exactly as `Ctrl+W`'s does not. A second plain press
  while the key is held takes the same path a repeat would, which is what the UI suite asserts;
  true auto-repeat stays a Tier 2 live check. This is the same shape as the `menuDismissKey`
  latch, which keys on state for presses and on the flag only in the release handler.
- **Focus loss mid-hold.** The overlay holds `OnDemand` keyboard focus (`Overview.qml:1438`). If
  focus leaves while `Space` is down, the release event never arrives and the peek would stick
  open forever. `peeking` is force-cleared when `opened` drops and when the panel loses keyboard
  focus — the release handler is a second path to the same clear, never the only one. The clear
  also sets `peekCancelled`, so a `Space` that is still held when focus returns does not silently
  re-open a peek the user has stopped thinking about; the next *press* starts a fresh hold.
- **Target vanishes while held** (the peeked window closes; the peeked workspace is destroyed).
  The hold is cancelled, on the model test above — `peekedKey` is no longer among the windows, or
  no longer among `boxes` — not on the resolved target going null, which it does not do. The layer
  goes and does not come back until `Space` is released, so the peek never slides to a successor
  match, to the selected workspace, or to whatever the pointer happens to be over: all targets the
  user never chose. Releasing and pressing again is the whole recovery, and it is the same gesture
  the user was already making.
- **A peeked workspace empties but survives.** Not a disappearance: it is still in `boxes`, still
  targetable, and the peek keeps showing it as an empty mini-map. Only a workspace that leaves
  `boxes` cancels — which is also what a dynamic Hyprland workspace does when its last window goes,
  so the common case reads the same either way.
- **No target at the press.** The layer never opens, and does not open later in that hold even if
  the pointer moves onto a tile. Opening is decided once, at the press, for the same reason the
  hold does not re-open after a cancel: a preview that pops in under a key that is merely still
  held is the flicker this design set out to avoid. (This follows from the cancel rule rather
  than standing on its own; the alternative — a hold that arms and opens on the first valid
  target — was rejected with it.)
- **`Space` dismissing a menu.** The menu is open, `Space` goes down: `menuKey` dismisses it and
  records `menuDismissKey = Qt.Key_Space` (`Overview.qml:653`), which swallows that key's repeats
  until it is released (`:1512`, ahead of everything). So one press cannot both dismiss the menu
  and open a peek, the held key stays inert afterwards, and the release clears `menuDismissKey`
  the way it already does for every other dismissing key. No new code — but the peek branch must
  sit *below* that check, not above it.
- **A modal opens mid-hold.** Right-click while peeking, or `Ctrl+W` raising the confirmation
  dialog: the peek is cancelled and the modal opens alone. `Space` release while the modal is up
  is consumed by the modal's own branch and clears the cancel as usual, so the state left behind
  is identical whichever order the user lets go in.
- **Peeking a fullscreen window.** A *window* peek shows it at the window's real aspect like any
  other: slot recovery is a layout concern and there is no layout in a single large capture. A
  *workspace* peek containing one is the opposite case — it runs the full placement, slot recovery
  included, which is exactly why `peekTiles` shares the grid's helper.
- **Peeking the scratchpad row.** A normal workspace target; the row must be shown (`Ctrl+S`) for
  it to be targetable at all, which is already true of every other action.
- **A window with no handle.** Icon fallback at peek size, exactly as the grid tile does. A large
  icon on a plain field is the honest rendering of "there are no pixels to show".
- **`Space` while the overview is closing.** `opened` is already false, the key handler is not
  reached, and the force-clear has already run.

## Tests

**Tier 1 (`logic.js`, pure, CI)** — placement cases in `tests/tst_layout.qml`, the key
predicate in `tests/tst_actions.qml`:
- `peekTiles` returns the same relative geometry as the grid for the same workspace at a
  different box size — a window centred in its cell stays centred; ratios between tiles hold.
- `peekTiles` on an empty workspace returns `[]`.
- `peekTiles` clamps to `minTileW`/`minTileH` the way `_tileRect` does, at peek scale.
- The fit calculation preserves aspect: a 16:9 window in a 60% box of a 16:10 screen is
  letterboxed vertically, never stretched.
- `peekTiles` and `buildLayout` agree on a workspace holding **both** a fullscreen window and
  ordinary tiled ones: the fullscreen window lands in its recovered slot at peek scale, with the
  same `layer` and `fullscreen` values and the same relative rect, and does not cover its
  neighbours. Repeated for the ambiguous-recovery case (`layer: 0` backdrop) and for a floating
  fullscreen window (the 20%/60% inset box).
- `isActionKey` returns true for bare `Space` and false for every chorded `Space`, next to the
  existing `Enter`/`Ctrl+W` cases.
- `appendQueryText` continues to reject a leading space (unchanged), and the key-handler-level
  interception of `Qt.Key_Space` is asserted in the key-routing suite rather than in the matcher.

**Key routing** (a new offscreen UI suite, `tests/ui/peek.qml` — the real `Overview` with only
the compositor stubbed, the tier that owns key handling; `tests/tst_actions.qml` is pure `logic.js`
and cannot press a key):
- `Space` with an active query does not change the query.
- `Space` with `menuOpen` or `confirmOpen` reaches neither the peek nor the query.
- An auto-repeat `Space` press is a no-op when already peeking, **and** when the hold is cancelled.
- `Space` does not clear `pointerLive`: with the pointer over one tile and the Tab cursor on
  another, `Space` peeks the hovered one. Repeated for a pointer over empty canvas inside a
  workspace box (peeks that workspace, not the cursor's window), and asserted again after an
  auto-repeat so a repeat cannot quietly flip the resolution to the keyboard.

**Cancellation** (`tests/ui/peek.qml`):
- Window target closes mid-hold → layer gone; a subsequent `Tab`, arrow, or hover does not
  re-open it; release then press re-opens on the current target.
- Find target closes mid-hold and `cycleMatch` selects a successor → still cancelled, the
  successor is not peeked.
- Cursor target closes mid-hold so the target falls back to the selected workspace → still
  cancelled, the workspace is not peeked.
- Workspace target leaves `boxes` mid-hold → cancelled. A workspace that only empties → **not**
  cancelled, peek shows an empty mini-map.
- `Escape` clearing the cursor mid-hold retargets to the selected workspace and does **not**
  cancel — intentional navigation is distinguished from disappearance.
- `openMenu` while peeking clears `peeking`; dismissing the menu with `Space` still down does not
  re-open the peek; release clears the cancel.
- `Space` pressed while the menu is open dismisses the menu and opens no peek, and its repeats
  stay swallowed until release.
- Focus loss while `Space` is down clears `peeking` and cancels; no release event is required.
- A press with no target opens nothing, and hovering a tile later in the same hold still opens
  nothing.

**Tier 2 (nested Hyprland):**
- Hold `Space` over a hovered tile, confirm one large capture appears and the grid is still live.
- Hold `Space`, press `Tab` twice, confirm the peek shows the third window without releasing.
- Release and confirm the cursor sits where `Tab` left it and no compositor state changed.
- Hold `Space` on a workspace holding a fullscreen window plus tiled ones, and confirm the peek
  mini-map matches the grid cell's arrangement — the fullscreen window in its slot, neighbours
  visible — rather than covering the workspace.
- Hold `Space` over a window, close that window from another client, and confirm the layer goes
  and stays gone while the key is held.
- Hold `Space`, right-click, and confirm the menu opens with no peek behind it and none returns
  on dismiss.

## Verified facts (live, 2026-09-18, round 2)

Probed on this machine (Hyprland 0.56.2, nested instance on an offset headless output, `hyprctl`,
`quickshell`, `foot`, `jq`, `wtype` and `grim` all present) with `tests/integration/peek-probe.sh`,
via `mise run test-integration`. This probe covers exactly the four claims no offscreen tier can
reach — it is IPC-driven (`tests/integration/drag.qml`'s `dragtest` handler calling
`overview.peekHold()`/`peekRelease()`/`peekState()`/`peekRows()`/`peekBox()`/`selectWs()`/
`setCursor()` directly), so it proves the layer, the mini-map and cancellation-by-geometry, but
**not** `Space`'s own key routing — that is the offscreen UI suite's job, and (for a real held
key) case 4 below. It does **not** exercise every scenario the "Tier 2 (nested Hyprland)" list
above names (no `Tab`-while-held retargeting, no close-from-another-client, no right-click-
while-held) — those remain unverified live and are candidates for a future extension of this
probe, not claims this run makes.

**A first pass of this probe (round 1) had two false-positive PASSes**, caught by review and
described in full below: case 3 ("live pixels") passed even with every capture path in the shell
forced to its icon fallback — proven by mutation, see case 3 — and case 2 could still pass under
the same stale-model race its own fix was meant to close. Both are fixed in this round; the fixes
and the experiments that justify them are the point of this section, not just the final PASS
lines.

Verbatim output of the final run:

```
PASS 1 (workspace target): a peek hold changed no compositor state
PASS 1 (window target): a peek hold changed no compositor state
PASS 2: mini-map rows do not overlap (fullscreen modes [2,0])
PASS 3: the peek's content changed between frames, cropped to its own box (live capture)
FACT 4: before={"peeking":false,"key":"","cancelled":false} held={"peeking":true,"key":"s:1","cancelled":false} after={"peeking":false,"key":"","cancelled":false}
PASS 4: a 2s held Space opened a peek and closed on release
peek-probe: done
```

- **Case 1 — the peek changes no compositor state: PASS, run twice, and genuinely diffed.**
  `hc clients -j`, `hc workspaces -j`, `hc monitors -j`, `hc activewindow -j` and `hc cursorpos -j`,
  each `jq -S`-sorted and projected to the fields that cannot legitimately churn, were
  byte-identical before and after a `peekHold` / mid-hold `setCursor` (a live retarget, the same
  mechanism `Tab`/arrows use in production) / `peekRelease` round trip. Focus and cursor position
  are now snapshotted too (round 1 omitted both — exactly what `fullscreen.sh:44-51` guards
  elsewhere in this rig), and the round runs **twice**: once with the selected-workspace fallback
  target (round 1's only case) and once with an explicit window target (`setCursor` to a real
  window address). Confirms the spec's strongest claim, for both target kinds: the peek dispatches
  nothing.
- **Case 2 — the mini-map places a fullscreen window in its recovered slot: PASS, with a hard
  precondition now guarding the race that produced round 1's false positive.** With one window
  toggled fullscreen (`mode='fullscreen', action='toggle'` — see the dispatcher note below) and one
  left tiled, `peekRows()` reported two non-overlapping rows with `fullscreen` modes `[2,0]`.
  Two things were fixed here across the two review rounds:
    - *Round 1's race:* `peekRows()`, unlike this file's `drop()`/`dropPoint()`/`unfullscreen()`,
      read `overview._windows` without a preceding `overview.rebuild()`. The **first two live
      runs** (before that fix) reported `[0,0]` — both rows tiled — which still passed the
      non-overlap `jq` assertion for the trivial reason that ordinary tiles never overlap; slot
      recovery was never actually exercised. Adding `overview.rebuild()` closed it — briefly.
    - *Round 2's finding:* `rebuild()` alone only re-reads whatever Quickshell's Hyprland module
      currently has cached in each toplevel's `lastIpcObject` — the actual fetch
      (`Hyprland.refreshToplevels()`, wired through `Overview.qml`'s own `requestRefresh()`) is
      **asynchronous** (see that file's `settleTimer`, which polls after requesting a refresh
      rather than trusting one synchronous read). So `overview.rebuild()` alone was not guaranteed
      to close the race on a slower machine — it happened to on this one. `peekRows()` now calls
      `overview.requestRefresh()` before `overview.rebuild()`, and the probe itself polls
      `peekRows()` (like `wait_fs` polls `hyprctl`) until a row reports `fullscreen > 0` — true of
      both maximized (mode 1) and fullscreen (mode 2), since slot recovery runs for both, hence the
      message below names both — **failing loudly** ("no row is fullscreen or maximized: model
      stale, case 2 did not exercise slot recovery") if the poll times out, rather than silently
      falling through to the overlap check the way round 1 did. `wait_fs` alone was never
      sufficient here — it only proves `hyprctl` itself has the new state, never that Quickshell's
      own copy of it has caught up.
    - **Tooling note:** the brief's original script text dispatched `window.fullscreen` with a bare
      `action = "on"|"off"`; that form is not attested anywhere else in this repo (production
      `logic.js:603`, `fullscreen.sh`, `probe-fullscreen.sh` all use `{ mode = "fullscreen",
      action = "toggle" }`), so the probe uses the same toggle form instead of introducing an
      unverified dispatcher call. Confirmed correct by the reviewer independently.
- **Case 3 — live pixels: PASS, but round 1's PASS was proven worthless, and the fix is verified
  by mutation, not by inspection.** Round 1's case 3 held a peek and diffed two whole-screen `grim`
  captures 1.2s apart. Review proved by direct experiment that this established nothing: forcing
  `PeekLayer.qml`'s `WindowTile` to `capMode: "icon"` — the exact live-vs-icon distinction this
  case exists to make — **still printed `PASS 3`**; forcing the grid delegate's `capMode` to
  `"icon"` too, so that **no live capture existed anywhere in the shell**, still printed `PASS 3`.
  Three compounding causes, all fixed:
    1. An **uncropped** `grim` capture grabs the whole nested screen, so churn anywhere on it (a
       tile appear animation, the peek's own fade-in, the just-spawned scratch window) satisfies
       `cmp` regardless of what the peek itself is showing. Fixed by cropping to the peek's own
       fitted box via a new `peekBox()` IPC reporter, read fresh over IPC rather than hardcoded (a
       literal `grim -g` geometry would silently stop matching the peek the moment any layout
       constant changed) — `peekBox()` replicates `PeekLayer.qml`'s own `boxW`/`boxH`/`fit`
       geometry from data already available to the IPC handler and returns it in **global**
       compositor pixel coordinates (the nested output sits at a nonzero global y-offset —
       `start_nested`'s `position=0x1440` — so a screen-local rect would crop the wrong area of a
       `grim -g` capture, which takes global layout coordinates).
    2. `date +%%N` (a double `%`, a leftover escape from the plan's own heredoc) prints the literal
       string `%N`, not nanoseconds — so the "animating" window only actually changed while its
       terminal scrollback was still filling, not continuously. Fixed to `date +%N`.
    3. The hold was never asserted open before capturing, so a *cancelled* hold — capturing
       whatever the grid or backdrop happened to be doing — still passed. Fixed: `peekState`'s
       `peeking` field is now asserted `true` right after `peekHold`, the same way case 1 already
       did.
    Round 1 also peeked the **selected workspace** in every case, never a window — `pointerLive` is
    always false in this IPC-driven rig, so `Logic.target` fell through to `selectedId` on every
    prior run, and the single large `ScreencopyView` case 3 is *named after* (the window-peek
    path) was never exercised at this tier at all. Fixed via the new `setCursor()` reporter
    (`cursorAddress` outranks `selectedId`), used here to peek a dedicated third scratch window
    running `while :; do date +%N; sleep 0.2; done`, spawned and polled for the same way
    `spawn_window()` does it (round 1 used a bare `sleep 1.5` guess instead).
    **The fix was verified by mutation, per instruction, not merely by re-reading the diff:** a
    scratch copy of the tree with `PeekLayer.qml`'s window `WindowTile` and the grid delegate's
    `WindowTile` both hardcoded to `capMode: "icon"` was run against the fixed probe and printed
    `FAIL 3: two frames 1.2s apart, cropped to the peek's own box ... are identical — the peek is
    not showing live pixels`, exit 1 — the pristine tree prints `PASS 3` on the same run. That is
    the actual evidence this case now discriminates; the PASS line alone is not.
- **Case 4 — real auto-repeat: PASS on the narrower claim it can actually support, execution-
  verified in both directions.** `wtype -P space` (key down) held for 2s, then `wtype -p space`
  (key up), against the real nested compositor. The FACT line shows `peeking` went
  `false -> true -> false` across the hold — a real `wtype` virtual keyboard press **does** reach
  the overlay's key handler on this build and **does** open a peek that survives a 2s hold,
  closing cleanly on release. This was the case flagged most likely to come back `UNVERIFIED`
  (nothing in this repo had driven the overview with real keys before); it did not.
  **What this case does *not* establish, corrected from round 1's overclaim:** it cannot
  distinguish a *guarded* auto-repeat from an *unguarded* one that happens to re-enter the press
  branch and reassign `peeking = true` to an already-true bool — observationally identical to the
  guarded path from outside. So "the auto-repeat guard was verified" is not a fact this case
  produces; what it produces is narrower and still new — not a count of openings, which is exactly
  what telling guarded from unguarded would need: a real held key opens a peek and a real release
  closes it, on this build. Repeat-*swallowing* itself remains **inferred**, pinned
  instead by the offscreen, mutation-verified second-press proxy in `tests/ui/peek.qml`. Adding a
  production-side press counter to discriminate repeat-swallowing at this tier was considered and
  deliberately **not done** — the offscreen proxy already covers it and the cost is instrumenting
  production code for a Tier 2 corroboration alone; recorded here as an accepted limitation, not an
  oversight.
  The `UNVERIFIED 4` branch is **execution-verified, not merely inspection-verified**: holding
  `Shift_L` instead of `Space` (`wtype -P Shift_L` / `-p Shift_L`) produced `held.peeking == false`
  and printed `UNVERIFIED 4: the held key never opened a peek ...`, exit 0, with no `PASS 4`
  alongside it. Round 1's script had a real bug here — `[[ ... ]] || { echo UNVERIFIED ...; }`
  followed by an *unconditional* `echo "PASS 4: ..."` — so a genuinely unverified run would have
  printed both lines, exactly the dishonest "recorded as verified when it was never exercised"
  outcome this case exists to prevent. Fixed to a proper if/elif so the two outcomes are mutually
  exclusive; the `Shift_L` run above exercises that fix directly, not just the "held a real key"
  claim.
- **Not run this session:** offscreen Tier 1 (`167 passed, 0 failed`) and the offscreen UI suite
  (`288 passed, 0 failed`, 8 suites) were re-run via `mise run test` before this round of fixes and
  are unaffected by it — every change in both rounds touches only `tests/integration/*`, no
  production QML or `logic.js`.
