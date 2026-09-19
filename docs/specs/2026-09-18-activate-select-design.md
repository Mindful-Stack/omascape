# Omascape — activate: select first, enter second (design)

Date: 2026-09-18 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1 ·
builds on actions and the Tab/arrow split (`main` at `5790e24`).
Status: **approved design, pre-implementation** (revised after a design review, 2026-09-19: the
find × click conflict and the missing-box digit).
Branch `select-then-enter`.

## Goal

An opt-in policy where a digit or a click *selects* rather than leaves. Nothing takes you out of
the overview until you commit: `Enter`, the same digit again, or a double-click. The overview
becomes somewhere you can look around before deciding, instead of a menu that fires on touch.

## Scope

**In:** one config key `activate` with the policies `"enter"` (today, the default) and `"select"`;
under `"select"` — digits select a workspace, tile and well clicks select, a repeated digit and a
double-click commit, the pointer stops resolving targets, and `Enter`/`Ctrl+W` act on the
selection; how a click interacts with a live find query; what a digit with no box does; the
digit latch and the target precedence as pure functions; an auto-repeat guard; the
hint row reading the active policy; Tier 1 tests and a `tests/ui/activate.qml` scene; a README
entry.

**Out:** any change to `"enter"` behaviour (it is today's code path, untouched); a runtime
keybinding or menu item to flip the policy (config file only, watched, like every other key); a
third policy; select-mode variants of the context menu, the drag-and-drop paths, middle-click or
the fullscreen badge — all four are direct manipulation on the thing under the pointer and are
identical in both policies; a hold-to-preview gesture (that is `peek`, its own spec).

## Decisions (brainstorm 2026-09-18)

- **The mode is one idea, so it is one key.** `activate` covers the keyboard and the mouse
  together. Separate `activateKeys`/`activateMouse` keys were rejected: they permit a
  configuration where the ring means "what `Enter` will do" for one device and nothing for the
  other, and they double what the spec, the hint row and the tests must cover for a combination
  nobody asked for. A string enum rather than a boolean, matching `motion`: it names a choice of
  how activation works, and leaves room for a third policy without a second key.

- **Under `"select"` the pointer stops being a targeting device entirely.** This is the core of
  the design and it replaces a weaker idea (a click that *pins* the target against later mouse
  movement). A pin is a latch plus an exception: hover would still resolve targets, so the mode
  would carry two notions of "the target" and the user would have to know which actions consult
  which. Making pointing non-targeting collapses both into one rule — **pointing highlights,
  clicking selects** — and it *improves* what is on screen rather than complicating it: hover is
  already decorative (`WindowTile.qml:114`, a 1.03 lift and the title label), and the only target
  indicator drawn anywhere is the cursor ring. Today, while `pointerLive`, the thing `Enter` would
  act on carries no ring at all. Under `"select"` the ring always marks the target, because the
  only way to become the target is to be selected.

- **Therefore `Ctrl+W` follows the selection under `"select"`.** `logic.js:1292` calls the
  existing behaviour "do this to what I am pointing at", which is the right rule while pointing
  targets. Once it does not, that sentence has no referent, and a `Ctrl+W` that still consulted
  hover would close a window with no ring on it while a ringed window sat elsewhere. The
  invariant that survives both policies is the one worth keeping: **an action acts on the target,
  and the target is what the resolve rule names.** Only the rule changes.

- **Middle-click and right-click do not change.** Neither resolves a target: both act on the tile
  they were delivered to. Middle-click closes that window, right-click opens the menu on that
  window, well or badge. They are direct manipulation, the same gesture in both policies, and
  making them select-aware would mean inventing a selection step for gestures that already name
  their object unambiguously.

- **The digit repeat has no timer.** A digit selects; if the very next input is that same digit,
  it enters. The timed double-tap was rejected for the reason the peek design rejected
  tap-to-latch: a timing-dependent gesture fails silently and differently on a loaded machine
  than on an idle one, and "it did the wrong thing" has no visible cause. The latch also keeps
  the whole rule pure — a function of (key, latch), asserted in the Tier 1 suite with no fake
  clock. A third variant, "a digit whose workspace is already selected enters it", was rejected
  because it needs no state at all but fires on a *single* press whenever that workspace was
  already selected — including at open, where the focused workspace is selected before the user
  has touched anything, so the focused workspace's own digit would skip the selection step.

- **A mouse move does not clear the digit latch.** Only another key, or a click, does. Under
  `"select"` a bare mouse move changes nothing — it does not retarget, because the pointer does
  not target — so clearing the latch on movement would turn `2` → nudge the mouse → `2` into a
  dead press with no visible cause and nothing on screen having changed. A key and a click both
  *do* move the selection, so both invalidate a pending repeat, and the rule reads as: the latch
  survives exactly as long as the selection it refers to is still the one the user just made.

- **A double-click is a click plus an enter of what that click selected.** Not a separate gesture
  with its own resolution. This is what makes it safe against Qt's press/release/clicked ordering
  around `doubleClicked`: whether or not the first click's `select` also fires, the second step
  enters the same thing, because selection is idempotent. The interval is `MouseArea`'s own — the
  platform's double-click time — so the overview does not ship a magic constant that disagrees
  with the rest of the desktop.

- **A click inside a live query moves the match; a click outside it ends the query.** `target()`
  ranks the find match *above* the cursor and the selected workspace (`logic.js:1140`), and that
  precedence is terminal by design — so a click that only set `cursorAddress` and `selectedIndex`
  would ring the clicked tile while `Enter` and `Ctrl+W` went on acting on the match, and the
  next `rematchAfterRebuild` → `followMatch` (`Overview.qml:802`) would drag the box selection
  back to the match and `applyTiles` would then clear the orphaned cursor. Two rules, split on
  something the user can already see (matches ring in the accent, non-matches are dimmed):
  - **The clicked tile is a current match** → it becomes the *selected match*: `matchIndex` moves
    to it, the query survives, the cursor is not touched. A click is then simply another way to
    do what `Tab` does, the filter is kept for further cycling, and the selection survives a
    rebuild for free, because `rematchAfterRebuild` already preserves `selectedMatchAddress`.
  - **The clicked tile is not a match, or it is a well** → the query is cleared first, then the
    normal selection is made. Clicking a dimmed tile is an unambiguous statement that the filter
    is no longer what the user wants; ignoring it would make a visible tile inert. Ordering
    matters: `setQuery("")` runs `restorePreQuerySelection()`, so the click's own selection must
    be applied after it, not before.

  The double-click needs no case of its own: it is still a click plus an enter of whatever that
  click selected, and it composes with all three branches unchanged.

- **A digit with no box is inert under `"select"`, and does not arm the latch.** `hasWs()` tests
  an id for validity, not a box for existence (`logic.js:1309`), and `jump()` leans on that
  deliberately — under `"enter"`, pressing `7` with no workspace 7 dispatches to it and Hyprland
  creates it. Under `"select"` there is nothing to ring, and the mode's whole contract is that
  the ring marks what a commit will do; a digit that cannot produce a ring therefore must not
  arm one either, or a second press would enter a workspace the user never saw selected. So the
  digit does nothing at all — no selection, no dispatch — **and clears the latch**, like any
  other key: leaving the latch standing would make `2`, `7`, `2` enter workspace 2 with a
  keystroke in between that silently did not count. The asymmetry with `"enter"` is the point:
  that policy fires a dispatcher, this one moves a ring. Nor is a capability lost at the default
  `workspaces: 10`, where ids 1–10 always have a box and entering an empty one still creates the
  workspace — `workspaces` exists precisely so "every number key has a visible target", and only
  a user who has turned that padding off can reach a digit with no box.

- **A tile click sets the selected workspace as well as the cursor.** Not a stylistic choice:
  `applyTiles` clears `cursorAddress` whenever the cursor is not on `selectedId`
  (`Overview.qml:1180`), so a click that set only the cursor would lose its ring at the next
  rebuild — a selection that silently evaporates a frame later, seemingly at random.

## Behaviour

Policy `"enter"` is today's overview, unchanged in every row. Policy `"select"`:

| Input                                       | effect                                                        |
|---------------------------------------------|---------------------------------------------------------------|
| `1`–`9`, `0`                                | select that workspace; clear the window cursor                |
| the same digit again, immediately           | enter that workspace (dispatch + close)                       |
| a digit held down (auto-repeat)             | selects once; the repeats do nothing                          |
| a different digit                           | selects the new one; the latch moves with it                  |
| a digit whose workspace has no box          | nothing at all; the latch is cleared, not armed               |
| any other key after a digit                 | that key's own effect; the latch is cleared                   |
| a mouse move after a digit                  | nothing; the latch **survives**                               |
| left-click a tile                           | select it: cursor onto that window, selection onto its workspace |
| double-click a tile                         | enter it (focus + close)                                      |
| left-click a well (empty canvas in a box)   | select that workspace; clear the cursor                       |
| double-click a well                         | enter that workspace                                          |
| left-click a tile **that is a match**, query live | it becomes the selected match; the query survives; no cursor |
| left-click a **non-matching** tile, query live | the query is cleared, then the tile is selected normally   |
| left-click a well, query live               | the query is cleared, then the workspace is selected          |
| double-click any of the three, query live   | the same, then enter what was just selected                   |
| hover a tile                                | the tile lifts and shows its title; **no** target change      |
| `Enter`                                     | enters the selection — the workspace, or the cursor's window  |
| `Ctrl+W`                                    | closes the selected window; nothing when a workspace is selected |
| middle-click a tile                         | closes that window (unchanged)                                |
| right-click anywhere                        | opens the menu on what was clicked (unchanged)                |
| drag a tile onto another box                | moves it silently (unchanged); a moved drag is not a click    |
| `Tab` / `Shift+Tab`, arrows, `Esc`, typing  | unchanged                                                     |

Find's *keyboard* behaviour is unchanged under both policies and needs no rule of its own: it is
already select-then-enter (a query selects the best match, `Tab` cycles, `Enter` focuses), and
while a query is live digits are query characters, never selection (`logic.js:1075`) — so the
latch cannot exist on that branch, and the missing-box rule cannot either. Only clicking needed a
rule, because only clicking can name a window the query did not.

The scratchpad row follows the same rules as any other box, because it *is* one: its tiles select
and enter, and `Enter` on the row shows the scratchpad.

## The pure layer

**`Logic.target(input)`** (`logic.js:1140`) takes a new `selectMode` boolean and skips its pointer
branch when set:

    if (!input.selectMode && input.pointerLive) { … }

The rule stays where the Tier 1 suite can assert it, rather than being short-circuited by passing
`pointerLive: false` from `resolveTarget()`. The difference matters: with the flag in the pure
layer, "the pointer does not target in select mode" is a tested property of the precedence rule,
and a later refactor that tidies the QML cannot reopen hover-targeting without a test going red.
`resolveTarget()` (`Overview.qml:443`) passes `selectMode: config.activate === "select"` and may
skip the hit test entirely when it is set, since nothing consumes the result.

**`Logic.digitActivate(key, latch, boxes)`** — new. Maps a bare digit key to an action, the box to
act on, and the next latch value:

    { action: "select" | "enter" | "none", id: <1..10>, index: <box index or -1>, latch: <key or 0> }

`id` is `Qt.Key_1`–`Qt.Key_9` → 1–9 and `Qt.Key_0` → 10, the mapping the digit branch already
uses. It takes `boxes` — plain layout data, so the function stays pure — and resolves the box
itself through the existing `indexOfWorkspace` (`logic.js:935`), returning that index so the
caller can assign `selectedIndex` without repeating the lookup. Then:

- no box for `id` (`index < 0`) → `{ action: "none", latch: 0 }`, whatever the latch held;
- `latch !== key` → `{ action: "select", latch: key }`;
- `latch === key` → `{ action: "enter", latch: 0 }` (the overview is closing; the latch must not
  survive into the next open).

Returns `null` for a non-digit. The box test comes first, so a box that *disappears between the
two presses* degrades to `"none"` with no special case: the second press cannot enter a workspace
that is no longer on screen. The overview holds one int, `digitLatch`, cleared to `0` by every other
key at the top of the key handler and by every click, and reset by `open()`.

**`Logic.parseConfig`** (`logic.js:994`) gains `activate: (o.activate === "select") ? "select" :
"enter"` — the same shape as `motion`, so an unknown or absent value is the safe default and a
malformed config never changes behaviour.

## Overview wiring

- `OmascapeConfig.qml`: `property string activate: "enter"`, assigned in `apply()`.
- Key handler (`Overview.qml:1564`): the digit branch calls `Logic.digitActivate` under
  `"select"` and keeps `setCursor(""); jump(id)` under `"enter"`. Both guard on
  `!e.isAutoRepeat`, as `Ctrl+W` already does (`Overview.qml:1537`), so a held digit cannot
  select and then immediately enter.
- Latch clearing: one assignment at the top of the handler, before the branches, for every key
  the digit branch does not consume.
- `dragArea.onReleased` (`Overview.qml:1875`): under `"select"` a non-moved left release calls a
  new `selectTile(addr)` instead of `focusWindow(addr)`. `onDoubleClicked` calls
  `focusWindow(addr)`.
- **`selectTile(addr)`** — new, and the one place the find split lives, so neither mouse area has
  to know about it:

      if a query is live and `addr` is in `matches`:
          matchIndex = its index; applyMatchRoles(); followMatch()
      else:
          if a query is live: setQuery("")      // runs restorePreQuerySelection()
          selectedIndex = Logic.indexOfWorkspace(boxes, window's workspaceId)
          setCursor(addr)                       // after setQuery, never before

  `setCursor` is deliberately not called on the match branch: `setQuery` holds the invariant that
  find and the cursor are never both live (`Overview.qml:732`), and the match branch keeps the
  query.
- **`selectWorkspaceBox(id)`** — new, for wells: clears a live query first, then sets
  `selectedIndex` from `indexOfWorkspace` and `setCursor("")`.
- The well `MouseArea` (`Overview.qml:1693`): left click calls `selectWorkspaceBox` under
  `"select"`; `onDoubleClicked` jumps.
- The digit branch assigns `selectedIndex` from the returned `index` rather than calling
  `jump`/`hasWs`, and does nothing on `"none"`.
- Hints: `1–0` reads `jump` under `"enter"` and `select` under `"select"`; `↵` reads `select`
  under `"enter"` and `enter` under `"select"`. Both tiers are already model-driven
  (`Overview.qml:1995`), so this is a binding, not a new widget.

## Edge cases

- **The latch and a closing overview.** `enter` returns `latch: 0` and `open()` resets it, so a
  digit pressed as the last act of one session cannot arm a repeat in the next.
- **A digit for a workspace with no box** (`workspaces: 0`, or a digit above a smaller count).
  Inert under `"select"`, and the latch is cleared rather than armed — see the decision above.
  Unchanged under `"enter"`, where it still dispatches and Hyprland creates the workspace.
- **A box that disappears between the two digit presses.** Falls out of `digitActivate`'s
  ordering: the second press sees `index < 0` and returns `"none"`, so it neither enters nor
  leaves a latch behind.
- **A click on a match that stops matching before the second click of a double-click.** The
  second step enters `selectedMatchAddress`, which `rematchAfterRebuild` preserves while the
  window still exists; if the window itself is gone, `activateTarget` finds no target and does
  nothing, exactly as `Enter` on a vanished match does today.
- **The selection is a workspace when `Ctrl+W` is pressed.** Nothing happens — the same terminal
  "no window target" the current rule already produces (`closeTarget`, `Overview.qml:544`).
- **A drag that moved is not a click**, so it neither selects nor enters; the existing `moved`
  flag already distinguishes them.
- **Clicking outside every box** still closes the overview (the scrim, `Overview.qml:1459`): it is
  not a selection surface in either policy.
- **Changing `activate` while the overview is open.** The config is watched, so the policy can
  flip mid-session. The latch is cleared on the change; no other state is policy-specific, so
  nothing else can be left stale.
- **`"select"` and a summon that lands under the pointer.** The pointer-priming machinery
  (`pointerPrimed`, `Overview.qml:411`) exists to stop a resting cursor from arming liveness on a
  keyboard summon. Under `"select"` liveness is never consulted, so the concern cannot arise; the
  machinery is left alone rather than made conditional, since `"enter"` still needs it.

## Tests

**Tier 1 (pure, `tests/tst_layout.qml` and `tests/tst_actions.qml`):**

- `parseConfig`: absent, `"enter"`, `"select"`, an unknown string, a non-string — only `"select"`
  yields `"select"`.
- `digitActivate`: first press selects; the same key again enters; a different key selects and
  moves the latch; `enter` returns `latch: 0`; a non-digit returns `null`; `Qt.Key_0` resolves to
  id 10 and to that box's index.
- `digitActivate` with a `boxes` array that has no box for the id → `{ action: "none", index: -1,
  latch: 0 }`, **including when the latch already held that key** (the disappeared-box case) and
  when it held a different one (an inert digit must still clear a pending repeat).
- `target` with `selectMode: true`: a live pointer over a tile is ignored and the cursor wins; a
  live pointer over a tile with no cursor and no query falls to the selected workspace; with
  `selectMode: false` the existing pointer precedence still holds (the current assertions, kept).

**Tier 2 (`tests/ui/activate.qml`, added to `tests/ui/run.sh`):**

- a digit selects without closing and rings the box; the repeat closes; a held digit does not
  close; a mouse move between two digit presses does not break the repeat;
- a tile click rings the tile and sets the selected workspace, and the ring survives a rebuild
  (the `applyTiles` trap); a double-click closes;
- `Ctrl+W` with the pointer over a *different* tile closes the selected one.

**Tier 2, find × click** — the scenario that motivated the rule, run in `tests/ui/activate.qml`
against a fixture where the query matches some windows and not others:

- search, then click a **matching** tile on another workspace: the query is still live, the
  clicked tile is the selected match, `Tab` still cycles the same match set, and both `Enter` and
  `Ctrl+W` act on the clicked window — asserted *after a rebuild*, which is where the naive
  wiring loses the selection to `followMatch`;
- search, then click a **dimmed non-matching** tile: the query is cleared, the match ring is gone
  from every tile, the clicked tile is ringed as the cursor, and it survives a rebuild;
- search, then click a **well**: the query is cleared and that workspace is selected, with no
  cursor;
- a double-click in each of the three cases enters the window or workspace the single click
  would have selected.

**Tier 2, padding off** — a second scene (or the same one re-run with `workspaces: 0` and no
workspace 7 created): pressing `7` selects nothing and leaves the overview open; pressing `7`
again still does nothing; and `2`, `7`, `2` leaves the overview open, proving the inert digit
cleared the latch rather than letting it stand.

Finally, the whole existing suite is re-run under the default `"enter"` policy, which must be
unchanged.

## Documentation

README's *Fast selection* bullet gains the policy, and the config table gains `activate`.
ROADMAP gets the entry. The hint row is self-documenting for whichever policy is active.
