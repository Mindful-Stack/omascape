# Activate: select first, enter second — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `activate: "select"` policy where a digit or a click selects rather than
leaves the overview, and `Enter`, a repeated digit or a double-click commits.

**Architecture:** Three pure additions to `logic.js` carry the whole rule — `parseConfig` gains the
key, `target()` gains a `selectMode` flag that switches off its pointer branch, and a new
`digitActivate()` maps a digit press to select/enter/none against the live box list. `Overview.qml`
holds one new int (`digitLatch`) and two new functions (`selectTile`, `selectWorkspaceBox`) and
otherwise just routes to those. The default policy `"enter"` is today's code path and must come out
byte-for-byte equivalent in behaviour.

**Tech Stack:** QML (Qt 6), plain-JS `logic.js`, `qmltestrunner` offscreen. Tier 1 = pure JS
(`tests/tst_*.qml`); Tier 2 = the real `Overview.qml` run offscreen against a stubbed compositor
(`tests/ui/*.qml`, built by `tests/ui/prepare.py`).

**Spec:** `docs/specs/2026-09-18-activate-select-design.md`

---

## Orientation — read this before Task 1

Things about this codebase that are not guessable and that this plan depends on:

- **Run Tier 1 + Tier 2 with `mise run test`** (or `bash tests/run.sh`). It runs the pure suites,
  then `tests/ui/run.sh`, then a Lua check. There is no watch mode.
- **`logic.js` uses raw hex key codes, not `Qt.Key_*`**, in pure functions — see `isActionKey`
  (`logic.js:1292`), which writes `0x57 // Ctrl+W (Qt.Key_W)`. Follow that. The digits are ASCII:
  `Qt.Key_0` is `0x30` … `Qt.Key_9` is `0x39`.
- **The Tier 2 fixture rewrites production QML** (`tests/ui/prepare.py`) and writes its own stub
  `OmascapeConfig.qml`. A new config key that is not added to that stub does not exist in any UI
  test — see Task 4, which exists for exactly this reason.
- **The fixture stub sets `workspaces: 0`** (no padding). So in every UI suite, only workspaces the
  seed actually creates have boxes. That is what makes the "digit with no box" case cheap to test —
  and it also means a test that needs box 7 to exist must create workspace 7 in its seed.
- **QtQuickTest runs test functions in alphabetical order, not declaration order.** Suites here
  therefore park the synthetic cursor off every tile in `init()` (`mouseMove(tc, -50, -50)`) so each
  test's own `hoverTile()` is a real move that arms `pointerLive`. Copy that line into any new
  suite; without it, pointer assertions fail for reasons unrelated to the code.
- **`prepare.py`'s `replaced()` helper fails loudly** if a block it patches no longer matches
  exactly once. None of this plan's edits touch those blocks, but if `prepare.py` starts raising
  `matches 0 time(s), expected 1`, that is why.

---

### Task 1: `parseConfig` accepts `activate`

**Files:**
- Modify: `logic.js:994-1009` (`parseConfig`)
- Test: `tests/tst_layout.qml` (beside the existing config tests at `:206`)

- [ ] **Step 1: Write the failing test**

In `tests/tst_layout.qml`, next to the other `parseConfig` tests:

```javascript
    // Distinguishes: a key that is read raw (any string becoming the policy) or not read at all
    // (always "enter"). The unknown-string and wrong-type cases are the ones that matter: a
    // malformed config must fall back, never change behaviour.
    function test_parseConfig_activate() {
        compare(Logic.parseConfig('').activate, "enter", "absent = today's behaviour")
        compare(Logic.parseConfig('{"activate": "enter"}').activate, "enter")
        compare(Logic.parseConfig('{"activate": "select"}').activate, "select")
        compare(Logic.parseConfig('{"activate": "Select"}').activate, "enter", "case-sensitive")
        compare(Logic.parseConfig('{"activate": "jump"}').activate, "enter", "unknown falls back")
        compare(Logic.parseConfig('{"activate": true}').activate, "enter", "wrong type falls back")
        compare(Logic.parseConfig('{"activate": "select"}').motion, "auto", "other keys keep defaults")
    }
```

- [ ] **Step 2: Run it and watch it fail for the right reason**

Run: `bash tests/run.sh 2>&1 | grep -A3 parseConfig_activate`
Expected: FAIL on the very first `compare` — `Actual (): undefined, Expected (): enter`.
**`undefined`, not a wrong string** — that is the signal the key is genuinely unread. A failure
that says `Actual: enter` means you wrote the implementation first.

- [ ] **Step 3: Implement**

In `logic.js`, inside `parseConfig`'s returned object, after the `motion` line:

```javascript
        activate: (o.activate === "select") ? "select" : "enter",
```

- [ ] **Step 4: Verify**

Run: `bash tests/run.sh`
Expected: PASS, whole suite green.

- [ ] **Step 5: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "feat(activate): parseConfig reads the activate policy"
```

---

### Task 2: `Logic.target` stops consulting the pointer in select mode

**Files:**
- Modify: `logic.js:1140` (`target`)
- Test: `tests/tst_actions.qml:55` (`input()` helper) and the target tests below it

**Property this task must achieve:** with `selectMode: true`, a live pointer over a tile must lose
to the keyboard — and with `selectMode: false` every existing precedence assertion in the file must
still pass unchanged. The second half is the real check: it proves the flag gates the branch rather
than deleting it.

- [ ] **Step 1: Add `selectMode` to the shared `input()` base**

`tests/tst_actions.qml:56` — add the key so every existing test states the old path explicitly:

```javascript
    function input(o) {
        var base = { pointerLive: false, pointerTileAddress: "", pointerWorkspaceId: -1,
                     query: "", matchAddress: "", cursorAddress: "", selectedId: -1,
                     selectMode: false }
        for (var k in o) base[k] = o[k]
        return base
    }
```

- [ ] **Step 2: Write the failing test**

Below `test_target_live_pointer_over_nothing_is_null`:

```javascript
    // Distinguishes: select mode honouring the pointer anyway (returns "0xP"), or switching the
    // pointer off for BOTH modes (the enter-mode assertions above would go red together with
    // this one). Each case below removes one keyboard level under a live pointer, so a resolver
    // that merely returned null in select mode also fails.
    function test_target_select_mode_ignores_a_live_pointer() {
        var t = Logic.target(input({ selectMode: true, pointerLive: true,
                                     pointerTileAddress: "0xP", cursorAddress: "0xC", selectedId: 3 }))
        compare(t.kind, "window"); compare(t.address, "0xC", "the cursor wins, not the pointer")

        var w = Logic.target(input({ selectMode: true, pointerLive: true,
                                     pointerTileAddress: "0xP", selectedId: 3 }))
        compare(w.kind, "workspace"); compare(w.id, 3, "falls to the selected workspace")

        var m = Logic.target(input({ selectMode: true, pointerLive: true, pointerTileAddress: "0xP",
                                     query: "sl", matchAddress: "0xM" }))
        compare(m.address, "0xM", "a live query still outranks everything")

        compare(Logic.target(input({ selectMode: true, pointerLive: true, pointerTileAddress: "0xP" })),
                null, "no keyboard target is still terminal")
    }
```

- [ ] **Step 3: Run it and watch it fail for the right reason**

Run: `bash tests/run.sh 2>&1 | grep -B2 -A6 select_mode_ignores`
Expected: FAIL at the first compare with `Actual (): 0xP, Expected (): 0xC` — the pointer branch
still running. Confirm the other target tests in the file are still **passing** at this point.

- [ ] **Step 4: Implement**

`logic.js`, first line of `target()`'s body:

```javascript
    if (!input.selectMode && input.pointerLive) {
```

Extend the function's comment block above it with one sentence, matching the file's voice:

```javascript
// Under the "select" activate policy the pointer is not a targeting device at all — pointing
// highlights, clicking selects — so the branch below is skipped entirely and the keyboard
// precedence is the whole rule. See docs/specs/2026-09-18-activate-select-design.md.
```

- [ ] **Step 5: Verify both halves**

Run: `bash tests/run.sh`
Expected: PASS. Specifically confirm `test_target_live_pointer_beats_the_cursor` and
`test_target_live_pointer_over_a_well` are still green — they are the "enter mode unchanged" half.

- [ ] **Step 6: Commit**

```bash
git add logic.js tests/tst_actions.qml
git commit -m "feat(activate): target() skips the pointer branch in select mode"
```

---

### Task 3: `Logic.digitActivate`

**Files:**
- Modify: `logic.js` (add beside `isActionKey`, `logic.js:1292`)
- Test: `tests/tst_actions.qml`

This is the whole digit rule, and it is pure, so it gets exhaustive Tier 1 coverage and almost no
UI coverage later.

- [ ] **Step 1: Write the failing test**

Add to `tests/tst_actions.qml`:

```javascript
    // Box list shaped like the real one: indexOfWorkspace() reads `workspaceId`.
    function boxesFor(ids) {
        var out = []
        for (var i = 0; i < ids.length; i++) out.push({ workspaceId: ids[i] })
        return out
    }
    // Distinguishes: a first press that enters (no select step at all), a second press that
    // re-selects instead of entering, and a latch that survives entering into the next summon.
    function test_digitActivate_select_then_enter() {
        var b = boxesFor([1, 2, 3])
        var first = Logic.digitActivate(0x32, 0, b, false)   // "2"
        compare(first.action, "select"); compare(first.id, 2)
        compare(first.index, 1, "index into boxes, not the workspace id")
        compare(first.latch, 0x32)

        var second = Logic.digitActivate(0x32, first.latch, b, false)
        compare(second.action, "enter"); compare(second.id, 2); compare(second.index, 1)
        compare(second.latch, 0, "the overview is closing; nothing may survive into the next open")
    }
    // Distinguishes: a latch keyed on the workspace rather than the key, which would let
    // 2 then 3 enter 3 on its first press.
    function test_digitActivate_a_different_digit_only_selects() {
        var b = boxesFor([1, 2, 3])
        var r = Logic.digitActivate(0x33, 0x32, b, false)    // "3" with "2" latched
        compare(r.action, "select"); compare(r.id, 3); compare(r.latch, 0x33)
    }
    // Distinguishes: Key_0 mapped to workspace 0 (no such workspace) or to index 0.
    function test_digitActivate_zero_is_workspace_ten() {
        var b = boxesFor([9, 10])
        var r = Logic.digitActivate(0x30, 0, b, false)       // "0"
        compare(r.action, "select"); compare(r.id, 10); compare(r.index, 1)
    }
    // Distinguishes: THE gap this rule exists for. hasWs() would accept 7 as a valid id and let
    // the latch arm, so a second press would enter a workspace that was never visibly selected.
    // The third case is a box that disappeared BETWEEN the two presses.
    function test_digitActivate_a_digit_with_no_box_is_inert() {
        var b = boxesFor([1, 2])
        var cold = Logic.digitActivate(0x37, 0, b, false)    // "7", nothing latched
        compare(cold.action, "none"); compare(cold.index, -1); compare(cold.latch, 0)

        var pending = Logic.digitActivate(0x37, 0x32, b, false)   // "7" while "2" was latched
        compare(pending.action, "none")
        compare(pending.latch, 0, "an inert digit still clears a pending repeat")

        var vanished = Logic.digitActivate(0x37, 0x37, b, false)  // "7" latched, its box now gone
        compare(vanished.action, "none")
        compare(vanished.latch, 0, "cannot enter a workspace that left the screen")
    }
    // Distinguishes: an auto-repeat that completes the gesture (hold "2" and you leave), and one
    // that clears the latch as if it were another key (hold "2", release, press "2" and nothing
    // happens). A repeat must be neither: a true no-op. This lives in Tier 1 because QtTest's QML
    // key API cannot set isAutoRepeat at all — see tests/ui/actions.qml:431.
    function test_digitActivate_an_auto_repeat_is_a_true_no_op() {
        var b = boxesFor([1, 2, 3])
        var held = Logic.digitActivate(0x32, 0x32, b, true)  // "2" latched, a repeat arrives
        compare(held.action, "none", "a repeat must never complete the gesture")
        compare(held.latch, 0x32, "and must not disturb the pending latch")

        var fresh = Logic.digitActivate(0x32, 0, b, true)
        compare(fresh.action, "none"); compare(fresh.latch, 0, "nothing latched stays nothing")

        var noBox = Logic.digitActivate(0x37, 0x32, b, true)
        compare(noBox.action, "none")
        compare(noBox.latch, 0x32, "a repeat is checked before the box, so it disturbs nothing")
    }
    // Distinguishes: a key range that swallows neighbouring ASCII. 0x2F is "/", 0x3A is ":".
    function test_digitActivate_ignores_non_digits() {
        var b = boxesFor([1, 2])
        compare(Logic.digitActivate(0x2F, 0, b, false), null)
        compare(Logic.digitActivate(0x3A, 0, b, false), null)
        compare(Logic.digitActivate(0x57, 0, b, false), null, "Qt.Key_W")
    }
```

- [ ] **Step 2: Run them and watch them fail for the right reason**

Run: `bash tests/run.sh 2>&1 | grep -c "digitActivate"`
Expected: all six FAIL with `TypeError: Property 'digitActivate' of object [object Object] is not
a function`. A different error means the test file itself is broken — fix that before implementing.

- [ ] **Step 3: Implement**

In `logic.js`, directly after `isActionKey`:

```javascript
// The "select" activate policy's digit rule (docs/specs/2026-09-18-activate-select-design.md).
// Pure: `boxes` is the same plain layout array indexOfWorkspace reads, so the whole gesture is
// decided here rather than half here and half in the key handler.
//
// The box test comes FIRST, and that ordering is the rule, not an optimisation. hasWs() tests an
// id for validity, not a box for existence, so without this a digit for a workspace with no box
// would arm the latch and a second press would enter a workspace the user never saw selected.
// Testing it first also covers, with no extra case, a box that disappears between the two presses.
//
// The latch is the PREVIOUS key code, not the previous workspace: "2" then "3" must select 3, not
// enter it. Returns null for anything that is not a digit; `latch` in the result is always what
// the caller should store.
//
// `autoRepeat` is handled here rather than by an early return in the key handler so that "a
// repeat is a true no-op" is a Tier 1 assertion: QtTest's QML key API cannot synthesise a real
// auto-repeat event (tests/ui/actions.qml:431), so the offscreen suite could never cover it.
// It is checked BEFORE the box lookup, because a repeat must change nothing at all — including
// the latch of a digit whose box has since gone.
function digitActivate(key, latch, boxes, autoRepeat) {
    if (key < 0x30 || key > 0x39) return null            // Qt.Key_0 .. Qt.Key_9 (ASCII)
    var id = (key === 0x30) ? 10 : key - 0x30            // Qt.Key_0 is workspace 10
    if (autoRepeat) return { action: "none", id: id, index: -1, latch: latch }
    var index = indexOfWorkspace(boxes || [], id)
    if (index < 0) return { action: "none", id: id, index: -1, latch: 0 }
    if (latch === key) return { action: "enter", id: id, index: index, latch: 0 }
    return { action: "select", id: id, index: index, latch: key }
}
```

- [ ] **Step 4: Verify**

Run: `bash tests/run.sh`
Expected: PASS, whole suite green.

- [ ] **Step 5: Commit**

```bash
git add logic.js tests/tst_actions.qml
git commit -m "feat(activate): digitActivate maps a digit to select, enter or none"
```

---

### Task 4: Config plumbing — production **and** fixture

**Files:**
- Modify: `OmascapeConfig.qml:9-24` (properties) and `:34-42` (`apply`)
- Modify: `tests/ui/prepare.py` (the stub `OmascapeConfig.qml` it writes, near the end of the file)
- Test: `tests/ui/activate.qml` (create) and `tests/ui/run.sh` (register it)

**This is the plan's shared-infrastructure task — treat it as the highest-stakes one.** Every UI
assertion in Tasks 5–9 depends on the fixture stub actually carrying `activate`. If it does not,
`config.activate` is `undefined` in the fixture, every `=== "select"` test is false, the overview
silently runs in `"enter"` mode, and the later suites pass while testing nothing. The first test
below exists solely to make that failure loud and immediate.

What the fixture must genuinely reproduce: a writable `activate` property that the real
`Overview.qml` reads by the same name as production. What it cannot supply: the `FileView` watch —
config *reloading* is not reproduced offscreen, so the "policy flips mid-session" edge case is
exercised by assigning `testConfig.activate` directly, which is the same binding the real reload
ends up driving.

- [ ] **Step 1: Add the property to production config**

`OmascapeConfig.qml`, after the `motion` property:

```qml
    // Activation policy (docs/specs/2026-09-18-activate-select-design.md).
    // "enter"  — a digit jumps and a click focuses, both leaving the overview.
    // "select" — both select instead; Enter, the same digit again, or a double-click commits.
    property string activate: "enter"
```

and in `apply()`, beside the others:

```qml
        cfg.activate = o.activate
```

- [ ] **Step 2: Add it to the fixture stub**

`tests/ui/prepare.py`, in the `OmascapeConfig.qml` the script writes — add the line so it reads:

```python
    'import QtQuick\nQtObject { property bool scrim: true; property bool hint: true\n'
    '           property int workspaces: 0\n'
    '           property string activate: "enter"\n'
    '           property string motion: "auto"; property string motionEffective: "full"\n'
```

- [ ] **Step 3: Create the suite with its fixture-health test first**

Create `tests/ui/activate.qml`. This is the full header and the seed the later tasks extend — do
not abbreviate it, later tasks add test functions to this file and nothing else.

```qml
import QtQuick
import QtTest

// Offscreen UI suite for the activate spec (docs/specs/2026-09-18-activate-select-design.md).
// The fixture (tests/ui/prepare.py) runs the real Overview against a stub compositor that records
// dispatches, so key handling, hit testing and model reconciliation are production code.
//
// NOTE: the fixture config sets `workspaces: 0` (no padding), so only workspaces seeded below have
// boxes. Workspace 7 deliberately does not exist: it is the "digit with no box" case.
TestCase {
    id: tc
    name: "Activate"
    when: windowShown
    width: 1200; height: 800; visible: true
    property var view
    property var mon

    Component { id: overview; Overview {} }

    function client(addr, cls, x) {
        return { address: addr, at: [x, 1500], size: [400, 400], floating: false,
                 title: cls, "class": cls, fullscreen: 0 }
    }
    function wsRow(id, clients) {
        return { id: id, monitor: mon,
                 toplevels: { values: clients.map(function (c) { return { lastIpcObject: c } }) } }
    }
    // Workspace 1: two tiled windows side by side. Workspace 2: one. Workspace 3: empty, so a
    // well click has a box with no tiles in it.
    function seed(v) {
        mon = { name: "TEST", x: 0, y: 1440, width: 1920, height: 1080, scale: 1,
                lastIpcObject: { reserved: [0, 26, 0, 0], transform: 0,
                                 activeWorkspace: { id: 1 }, specialWorkspace: { id: 0, name: "" } } }
        v.compositor.monitors = { values: [mon] }
        v.compositor.focusedMonitor = mon
        v.compositor.focusedWorkspace = { id: 1 }
        v.compositor.workspaces = { values: [
            wsRow(1, [client("0xA", "alpha", 100), client("0xB", "bravo", 900)]),
            wsRow(2, [client("0xC", "charlie", 100)]),
            wsRow(3, [])
        ] }
    }
    function init() {
        // QtQuickTest runs these alphabetically and the window is shared, so the synthetic cursor
        // arrives wherever the previous test left it. Parking it off every tile makes each test's
        // own hover a real move that arms pointerLive.
        mouseMove(tc, -50, -50)
        view = createTemporaryObject(overview, tc)
        verify(view !== null)
        view.motion.scale = 0            // no entrance/exit fade to wait for
        seed(view)
        view.testConfig.activate = "select"
        view.open()
        wait(400)
        view.compositor.commands = []    // drop the lock install/sync chunks open() dispatches
    }
    function cleanup() { view.close() }

    function tileCentre(addr) {
        for (var i = 0; i < view.testModel.count; i++) {
            var r = view.testModel.get(i)
            if (r.address !== addr) continue
            var p = view.testCanvas.mapToItem(view, r.wx + r.ww / 2, r.wy + r.wh / 2)
            return p
        }
        fail("no tile row for " + addr)
    }
    function hoverTile(addr) { var p = tileCentre(addr); mouseMove(view, p.x, p.y); wait(30) }
    function boxOf(wsId) {
        for (var i = 0; i < view.boxes.length; i++)
            if (view.boxes[i].workspaceId === wsId) return view.boxes[i]
        fail("no box for workspace " + wsId)
    }
    // A point inside a box but on no tile: the well. Workspace 3 is empty, so its centre works.
    function wellCentre(wsId) {
        var b = boxOf(wsId)
        return view.testCanvas.mapToItem(view, b.x + b.w / 2, b.y + b.h / 2)
    }

    // ---- fixture health ------------------------------------------------------------------
    // Distinguishes: a fixture whose stub config has no `activate` property. Then
    // config.activate is undefined, every `=== "select"` test in this file is silently false,
    // the overview runs in enter mode, and the whole suite passes while testing nothing.
    function test_a_the_fixture_carries_the_activate_policy() {
        compare(view.testConfig.activate, "select",
                "prepare.py's stub OmascapeConfig must declare `activate`")
        verify(view.testKeys.activeFocus, "keyCatcher must hold active focus after open()")
    }
    // Distinguishes: a seed where workspace 7 accidentally exists, which would make every
    // missing-box assertion in this file vacuous.
    function test_a_workspace_seven_has_no_box() {
        for (var i = 0; i < view.boxes.length; i++)
            verify(view.boxes[i].workspaceId !== 7, "workspace 7 must not have a box")
    }
}
```

- [ ] **Step 4: Register the suite**

`tests/ui/run.sh`, beside the other `cp` lines:

```bash
cp "$src/tests/ui/activate.qml" "$fixture/tst_activate_ui.qml"
```

- [ ] **Step 5: Verify the health tests catch the thing they are for**

First prove the guard works — temporarily revert Step 2 (remove the `activate` line from
`prepare.py`) and run:

Run: `bash tests/ui/run.sh 2>&1 | grep -B3 -A3 -E "fixture_carries|activate"`
Expected: FAIL, in one of two shapes depending on the Qt build — either
`TypeError: Cannot assign to non-existent property "activate"` thrown by `init()`'s
`view.testConfig.activate = "select"`, or the health test's own
`Actual (): undefined, Expected (): select`. Either is the guard firing; both must disappear once
the line is restored. What must **not** happen is a green run.
Then restore the line and re-run.
Expected: PASS.

This step is not ceremony: it is the only proof that the rest of the plan's UI coverage is real.

- [ ] **Step 6: Full suite, then commit**

```bash
bash tests/run.sh
git add OmascapeConfig.qml tests/ui/prepare.py tests/ui/activate.qml tests/ui/run.sh
git commit -m "feat(activate): the activate config key, in production and the fixture"
```

---

### Task 5: The pointer stops targeting; `Ctrl+W` follows the selection

**Files:**
- Modify: `Overview.qml:443-460` (`resolveTarget`)
- Test: `tests/ui/activate.qml`

- [ ] **Step 1: Write the failing tests**

Add to `tests/ui/activate.qml`:

```qml
    function ctrlW() { keyClick(Qt.Key_W, Qt.ControlModifier) }

    // Distinguishes: a resolveTarget that still passes pointerLive through in select mode, AND
    // one that switched the pointer off for both policies — the SAME hover is resolved under
    // each, so either mistake fails one half. The hover is a real move (pointerLive goes true):
    // the point is that liveness no longer reaches the resolver, not that the pointer stopped.
    //
    // The selection is the one open() makes, the focused workspace. Deliberately NOT set with a
    // digit: digits do not select until Task 6, and before that a digit jumps and closes the
    // overview out from under the test.
    function test_b_hover_does_not_retarget_in_select_mode() {
        compare(view.selectedId, 1, "open() selects the focused workspace")
        hoverTile("0xC")                         // a window on a DIFFERENT workspace
        compare(view.pointerLive, true, "the pointer really did move")

        var t = view.resolveTarget()
        compare(t.kind, "workspace")
        compare(t.id, 1, "select mode: the selection, not the hovered tile")

        view.testConfig.activate = "enter"
        var e = view.resolveTarget()
        compare(e.kind, "window")
        compare(e.address, "0xC", "enter mode: the same hover still names the tile")
    }
    // Distinguishes: Ctrl+W still acting on hover in select mode — the consequence the spec
    // accepted explicitly. Hovering 0xA while 0xC is selected must close 0xC.
    function test_d_ctrl_w_closes_the_selected_window_not_the_hovered_one() {
        var p = tileCentre("0xC")
        mouseClick(view, p.x, p.y)               // select 0xC (workspace 2)
        wait(30)
        view.compositor.commands = []
        hoverTile("0xA")
        ctrlW()
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf("0xC") >= 0,
               "closed " + view.compositor.commands[0] + ", expected the selected 0xC")
        verify(view.compositor.commands[0].indexOf("0xA") < 0)
    }
```

Note: the second test depends on click-to-select, which lands in Task 7. Expect it to fail until
then — that is intentional and is called out again in Task 7's verify step.

- [ ] **Step 2: Run and confirm the first test fails for the right reason**

Run: `bash tests/ui/run.sh 2>&1 | grep -A4 hover_does_not_retarget`
Expected: FAIL with `Actual (): window` / the hovered address — the pointer branch still winning.
Not a `TypeError`: `resolveTarget` already exists.

- [ ] **Step 3: Implement**

`Overview.qml`, in `resolveTarget()` — gate the hit test and pass the flag:

```qml
    function resolveTarget() {
        var selectMode = config.activate === "select"
        var live = false, tileAddr = "", wsId = -1
        if (!selectMode && pointerLive) {
            var p = pointerPoint()
            if (p.inView) {
                live = true
                tileAddr = Logic.tileAt(tileCandidates(), p.x, p.y)
                if (!tileAddr) {
                    var hit = Logic.hitWorkspace(boxes, p.x, p.y)
                    wsId = hit === null ? -1 : hit
                }
            }
        }
        return Logic.target({ selectMode: selectMode,
                              pointerLive: live, pointerTileAddress: tileAddr,
                              pointerWorkspaceId: wsId, query: root.query,
                              matchAddress: root.selectedMatchAddress,
                              cursorAddress: root.cursorAddress, selectedId: root.selectedId })
    }
```

**Property:** `Logic.target` must still receive `selectMode` explicitly even though the QML already
skipped the branch. The two are **behaviourally redundant** — mutation testing during Task 5
confirmed that either one alone passes the UI test and only removing both fails it — so the QML
short-circuit is an optimisation (it avoids building `tileCandidates()` and running `tileAt()`
for a result select mode discards), and the rule itself lives in the pure layer where Task 2's
tests assert it. Say that in the comment rather than implying two lines of defence.

- [ ] **Step 4: Verify**

Run: `bash tests/ui/run.sh 2>&1 | grep -A4 hover_does_not_retarget`
Expected: PASS. `test_d_ctrl_w_closes_the_selected_window_not_the_hovered_one` still fails — Task 7.

Run: `bash tests/run.sh 2>&1 | grep -E "Actions|Find|Close|Totals"`
Expected: every **other** UI suite still green. They all run in the default `"enter"` policy, so a
regression there means the flag leaked into enter mode.

- [ ] **Step 5: Commit**

```bash
git add Overview.qml tests/ui/activate.qml
git commit -m "feat(activate): the pointer stops resolving targets in select mode"
```

---

### Task 6: The digit branch and the latch

**Files:**
- Modify: `Overview.qml` — new `digitLatch` property, `open()` (`:1244`), the key handler
  (`:1527` top, `:1564` digit branch), a `Connections` on `config`
- Test: `tests/ui/activate.qml`

- [ ] **Step 1: Write the failing tests**

```qml
    // Distinguishes: a digit that still jumps (the overview would close and dispatch), or one
    // that selects without moving the box selection.
    function test_c_a_digit_selects_without_leaving() {
        keyClick(Qt.Key_2)
        compare(view.opened, true, "a first press must not leave the overview")
        compare(view.selectedId, 2)
        compare(view.compositor.commands.length, 0, "nothing dispatched on a select")
    }
    // Distinguishes: a latch keyed on the workspace instead of the key press, and a second press
    // that re-selects instead of committing.
    function test_c_the_same_digit_again_enters() {
        keyClick(Qt.Key_2)
        keyClick(Qt.Key_2)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf('workspace = "2"') >= 0,
               "dispatched: " + view.compositor.commands[0])
    }
    // Distinguishes: a latch that ignores intervening input — the bug where 2, 3, 2 enters 2.
    function test_c_a_different_digit_clears_the_latch() {
        keyClick(Qt.Key_2); keyClick(Qt.Key_3); keyClick(Qt.Key_2)
        compare(view.opened, true, "no press was ever a repeat")
        compare(view.selectedId, 2)
    }
    // Distinguishes: a latch cleared only by digits. Tab moves the selection, so a later repeat
    // of the old digit must not complete.
    function test_c_another_key_clears_the_latch() {
        keyClick(Qt.Key_2); keyClick(Qt.Key_Tab); keyClick(Qt.Key_2)
        compare(view.opened, true)
    }
    // Distinguishes: a latch cleared by pointer movement. Under select mode a mouse move changes
    // nothing at all, so it must not silently break a pending repeat.
    function test_c_a_mouse_move_does_not_clear_the_latch() {
        keyClick(Qt.Key_2)
        hoverTile("0xA")
        keyClick(Qt.Key_2)
        compare(view.opened, false, "the repeat must still complete after a mouse move")
    }
    // Distinguishes: THE missing-box gap. Workspace 7 has no box (see the seed), so neither
    // press may select, dispatch or leave — and the inert digit must also clear a pending latch,
    // or 2, 7, 2 would enter workspace 2 with a keystroke in between that did not count.
    function test_c_a_digit_with_no_box_is_inert() {
        keyClick(Qt.Key_7)
        compare(view.opened, true)
        compare(view.selectedId, 1, "selection untouched (workspace 1 is focused at open)")
        compare(view.compositor.commands.length, 0)

        keyClick(Qt.Key_7)
        compare(view.opened, true, "a second inert press must not enter either")
        compare(view.compositor.commands.length, 0)

        keyClick(Qt.Key_2); keyClick(Qt.Key_7); keyClick(Qt.Key_2)
        compare(view.opened, true, "the inert digit must have cleared the latch")
    }
    // Auto-repeat has NO test here on purpose: QtTest's QML key API cannot set isAutoRepeat
    // (tests/ui/actions.qml:431 says so for the Ctrl+W guard). That is why the rule lives in
    // digitActivate, where test_digitActivate_an_auto_repeat_is_a_true_no_op covers both
    // failure modes. Holding a digit is a live-check item, not an offscreen one.

    // Distinguishes: a latch that outlives the summon it was armed in, which would make the
    // first digit press of the NEXT open enter instead of select.
    function test_c_entering_leaves_no_latch_behind() {
        keyClick(Qt.Key_2); keyClick(Qt.Key_2)
        compare(view.opened, false)
        compare(view.digitLatch, 0, "the latch must not survive the close")
    }
    // Distinguishes: a policy flip that leaves a stale latch, so the first digit after switching
    // back completes a gesture begun under the old policy.
    function test_c_a_policy_change_clears_the_latch() {
        keyClick(Qt.Key_2)
        compare(view.digitLatch, Qt.Key_2)
        view.testConfig.activate = "enter"
        view.testConfig.activate = "select"
        compare(view.digitLatch, 0)
        keyClick(Qt.Key_2)
        compare(view.opened, true, "that press selects; it does not complete the old gesture")
    }
    // Distinguishes: the default policy regressing. Under "enter" a single digit still jumps.
    function test_c_enter_policy_is_unchanged() {
        view.testConfig.activate = "enter"
        keyClick(Qt.Key_2)
        compare(view.opened, false, "one press jumps under the default policy")
        compare(view.compositor.commands.length, 1)
    }
    // Distinguishes: the missing-box rule leaking into enter mode. Under "enter", 7 must still
    // dispatch and let Hyprland create workspace 7 — that is today's behaviour and it is not in
    // this feature's scope to change.
    function test_c_enter_policy_still_jumps_to_a_missing_workspace() {
        view.testConfig.activate = "enter"
        keyClick(Qt.Key_7)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf('workspace = "7"') >= 0)
    }
```

- [ ] **Step 2: Run and confirm the failures**

Run: `bash tests/ui/run.sh 2>&1 | grep -A3 "test_c_"`
Expected: `test_c_a_digit_selects_without_leaving` FAILs with `Actual (): false, Expected (): true`
for `view.opened` — the digit still jumped. The two `test_c_enter_policy_*` tests should already
PASS; if either does not, the default path is broken before you have touched it. The two latch
tests will fail on `view.digitLatch` not existing yet.

- [ ] **Step 3: Implement the state**

`Overview.qml`, beside `cursorAddress` (`:463`):

```qml
    // The "select" policy's digit latch: the key code of the digit press that made the current
    // selection, or 0. A press of the SAME key completes the gesture. Cleared by every other key
    // and by every click — but NOT by pointer movement, which changes nothing in select mode.
    property int digitLatch: 0
```

In `open()`, beside the other resets (`:1248`, the `resetFind(); setCursor("")` line):

```qml
        digitLatch = 0
```

Near the other `Connections`, so a mid-session policy change cannot leave a stale latch:

```qml
    Connections {
        target: config
        function onActivateChanged() { root.digitLatch = 0 }
    }
```

- [ ] **Step 4: Implement the handler**

In `Keys.onPressed`, immediately after the `chord`/`finding` locals are computed
(`Overview.qml:1527`), take and clear the latch in one move:

```qml
                    // Take the latch: EVERY key clears it, and only the digit branch below
                    // re-arms — from `latch`, the value as it was on entry. Pointer movement
                    // never reaches here, which is exactly why a mouse move cannot break a
                    // pending repeat.
                    var latch = root.digitLatch
                    root.digitLatch = 0
```

Then replace the two digit lines in the non-`finding` branch (`Overview.qml:1564-1565`):

```qml
                        if (e.key >= Qt.Key_0 && e.key <= Qt.Key_9) {
                            if (config.activate !== "select") {
                                root.setCursor("")
                                root.jump(e.key === Qt.Key_0 ? 10 : e.key - Qt.Key_0)
                                return
                            }
                            var d = Logic.digitActivate(e.key, latch, root.boxes, e.isAutoRepeat)
                            root.digitLatch = d.latch      // an auto-repeat hands `latch` back
                            if (d.action === "none") return
                            root.setCursor("")
                            root.selectedIndex = d.index
                            root.ensureSelectedVisible()
                            if (d.action === "enter") root.jump(d.id)
                            return
                        }
```

`d` cannot be null here: the QML range check and `digitActivate`'s own are the same range. The
range check stays anyway, so the branch reads as a digit branch.

**Properties this code must achieve**, each covered by a test:
- an auto-repeat neither enters nor disturbs the latch — Tier 1, since QtTest cannot synthesise
  one;
- an inert digit (`"none"`) leaves `selectedIndex`, the dispatch log and `opened` untouched, and
  leaves the latch at 0;
- the `"enter"` policy path returns before `digitActivate` is consulted, so it cannot inherit the
  missing-box rule — under `"enter"`, `7` must still dispatch and let Hyprland create workspace 7.

- [ ] **Step 5: Verify**

Run: `bash tests/ui/run.sh 2>&1 | grep -A3 "test_c_"`
Expected: all eight PASS.

Run: `bash tests/run.sh`
Expected: whole suite green — in particular `Find`'s digit tests, which assert digits type into a
live query and jump when it is empty.

- [ ] **Step 6: Commit**

```bash
git add Overview.qml tests/ui/activate.qml
git commit -m "feat(activate): digits select, and the same digit again enters"
```

---

### Task 7: Tile and well clicks select; a double-click enters

**Files:**
- Modify: `Overview.qml` — new `selectTile`/`selectWorkspaceBox` beside `focusWindow` (`:497`),
  the tile `MouseArea` (`:1875` release, plus a new `onDoubleClicked`), the well `MouseArea`
  (`:1693`)
- Test: `tests/ui/activate.qml`

**Environment note — the double-click helper.** QtTest has two: `mouseDoubleClick()` sends a single
`QEvent::MouseButtonDblClick`, while `mouseDoubleClickSequence()` sends the full press / release /
press / double-click / release run that a real mouse produces. The tile's `MouseArea` drives its
drag from `onPressed`/`onReleased` pairs, so only the **sequence** form exercises production code.
Use `mouseDoubleClickSequence`. If a Qt build in use does not expose it, the fallback is two
`mouseClick` calls with `delay` under the platform double-click interval — but check
`qmltestrunner --help` / the QtTest docs for the build in hand rather than assuming either way.

- [ ] **Step 1: Write the failing tests**

```qml
    // Distinguishes: a click that still focuses and closes, and one that sets only the cursor
    // without the workspace — applyTiles clears a cursor that is not on selectedId, so the
    // rebuild wait below is the real assertion, not padding.
    function test_d_a_tile_click_selects_and_survives_a_rebuild() {
        var p = tileCentre("0xC")                 // workspace 2
        mouseClick(view, p.x, p.y)
        wait(30)
        compare(view.opened, true, "a single click must not leave")
        compare(view.compositor.commands.length, 0)
        compare(view.cursorAddress, "0xC")
        compare(view.selectedId, 2, "the click must move the box selection too")

        view.rebuild()   // synchronous; the idiom every other UI suite uses
        compare(view.cursorAddress, "0xC", "the cursor must survive applyTiles")
        compare(view.selectedId, 2)
    }
    // Distinguishes: a double-click that focuses twice, or that leaves the overview open. The
    // command count is the sharp half: Qt delivers `released` around `doubleClicked` and both
    // paths run, so exactly one dispatch proves the guards hold.
    function test_d_a_double_click_enters_the_window() {
        var p = tileCentre("0xC")
        mouseDoubleClickSequence(view, p.x, p.y)
        wait(30)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1, "exactly one focus dispatch")
        verify(view.compositor.commands[0].indexOf("address:0xC") >= 0)
    }
    // Distinguishes: a well click that jumps (enter-mode behaviour) or that leaves a stale
    // window cursor behind, which would make Enter focus a window instead of entering the box.
    function test_d_a_well_click_selects_the_workspace() {
        var p = tileCentre("0xA")
        mouseClick(view, p.x, p.y)                // cursor onto a window first
        wait(30)
        var w = wellCentre(3)                     // workspace 3 is empty
        mouseClick(view, w.x, w.y)
        wait(30)
        compare(view.opened, true)
        compare(view.selectedId, 3)
        compare(view.cursorAddress, "", "a well click clears the window cursor")
    }
    // Distinguishes: a well double-click that selects twice instead of committing.
    function test_d_a_well_double_click_enters_the_workspace() {
        var w = wellCentre(3)
        mouseDoubleClickSequence(view, w.x, w.y)
        wait(30)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf('workspace = "3"') >= 0)
    }
    // Distinguishes: a click clearing the latch only for digits. A click makes a NEW selection,
    // so a pending repeat of the old digit must not complete afterwards.
    function test_d_a_click_clears_the_digit_latch() {
        keyClick(Qt.Key_2)
        var p = tileCentre("0xA")
        mouseClick(view, p.x, p.y)
        wait(30)
        keyClick(Qt.Key_2)
        compare(view.opened, true, "the click must have cleared the latch")
    }
    // Distinguishes: a drag that also counts as a click and so selects on drop.
    function test_d_a_moved_drag_does_not_select() {
        var from = tileCentre("0xA"), to = wellCentre(3)
        mousePress(view, from.x, from.y)
        mouseMove(view, to.x, to.y); wait(30)
        mouseRelease(view, to.x, to.y); wait(30)
        compare(view.cursorAddress, "", "a moved drag is not a click")
    }
    // Distinguishes: the default policy regressing. Under "enter" a single click still focuses.
    function test_d_enter_policy_click_still_focuses() {
        view.testConfig.activate = "enter"
        var p = tileCentre("0xC")
        mouseClick(view, p.x, p.y)
        wait(30)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1)
    }
```

- [ ] **Step 2: Run and confirm the failures**

Run: `bash tests/ui/run.sh 2>&1 | grep -A3 "test_d_"`
Expected: `test_d_a_tile_click_selects_and_survives_a_rebuild` FAILs on `view.opened` being `false`
— the click still focused and closed. `test_d_enter_policy_click_still_focuses` should already PASS.

- [ ] **Step 3: Implement the two selection functions**

`Overview.qml`, directly after `focusWindow` (`:497-503`). The query branch is a stub for now —
Task 8 fills it in; this task's tests never run with a live query.

```qml
    // Click-to-select under the "select" policy. Sets BOTH the window cursor and the box
    // selection: applyTiles clears a cursor that is not on selectedId (see :1180), so a click
    // that set only the cursor would lose its ring at the next rebuild.
    function selectTile(addr) {
        var win = _windowByAddress[addr]
        if (!win) return
        if (query.length) { selectMatchOrClearQuery(addr); return }
        selectedIndex = Logic.indexOfWorkspace(boxes, win.workspaceId)
        setCursor(addr)
        ensureSelectedVisible()
    }
    // Task 8 replaces this body with the match/non-match split.
    function selectMatchOrClearQuery(addr) {
        setQuery("")
        var win = _windowByAddress[addr]
        if (!win) return
        selectedIndex = Logic.indexOfWorkspace(boxes, win.workspaceId)
        setCursor(addr)
        ensureSelectedVisible()
    }
    // Click-to-select for a well. A live query is cleared first, then the box is selected; the
    // window cursor is dropped so Enter enters the workspace rather than a stale window.
    function selectWorkspaceBox(id) {
        if (query.length) setQuery("")         // runs restorePreQuerySelection(); must come first
        var idx = Logic.indexOfWorkspace(boxes, id)
        if (idx < 0) return
        selectedIndex = idx
        setCursor("")
        ensureSelectedVisible()
    }
```

- [ ] **Step 4: Implement the tile mouse area**

`Overview.qml`, the tile `dragArea`. Change the final line of `onReleased` (`:1875`):

```qml
                                    if (!wasMoved) {
                                        // A double-click's second `released` can arrive after
                                        // focusWindow() has already closed the overview; selecting
                                        // into a closed overview would leave stale state for the
                                        // next summon. The guard makes both delivery orders of
                                        // `doubleClicked` and `released` equivalent.
                                        if (!root.opened) return
                                        if (root.config.activate === "select") root.selectTile(addr)
                                        else root.focusWindow(addr)
                                    }
```

and add, as a sibling of `onReleased` inside the same `MouseArea`:

```qml
                                onDoubleClicked: function (m) {
                                    if (m.button !== Qt.LeftButton) return
                                    if (root.config.activate !== "select") return
                                    root.endDrag()
                                    root.focusWindow(model.address)
                                }
```

**Property:** a double-click must produce **exactly one** focus dispatch and leave the overview
closed, regardless of whether Qt delivers `doubleClicked` before or after the second `released`.
`focusWindow`'s own `close()` is idempotent (`:1268` early-returns when `!opened`) and the
`!root.opened` guard above stops the trailing release from re-selecting; between them both orders
converge. The test's `commands.length === 1` is what proves it.

- [ ] **Step 5: Implement the well mouse area**

`Overview.qml:1693-1700`:

```qml
                                onClicked: function (m) {
                                    if (m.button !== Qt.LeftButton) return
                                    if (root.config.activate === "select")
                                        root.selectWorkspaceBox(boxItem.model.workspaceId)
                                    else root.jump(boxItem.model.workspaceId)
                                }
                                onDoubleClicked: function (m) {
                                    if (m.button !== Qt.LeftButton) return
                                    if (root.config.activate !== "select") return
                                    root.jump(boxItem.model.workspaceId)
                                }
```

Keep the existing right-press branch in `onPressed` exactly as it is.

- [ ] **Step 6: Clear the latch on every click**

Both selection functions make a new selection, so add `digitLatch = 0` as the first statement of
`selectTile` and of `selectWorkspaceBox`.

- [ ] **Step 7: Verify, including Task 5's deferred test**

Run: `bash tests/ui/run.sh 2>&1 | grep -A3 -E "test_d_|ctrl_w_closes_the_selected"`
Expected: all seven `test_d_` PASS, **and**
`test_d_ctrl_w_closes_the_selected_window_not_the_hovered_one` from Task 5 now PASSes — it was
waiting on click-to-select.

Run: `bash tests/run.sh`
Expected: whole suite green. `Drag`, `Close` and `Actions` all exercise tile clicks under the
default policy and are the regression check on the `onReleased` edit.

- [ ] **Step 8: Commit**

```bash
git add Overview.qml tests/ui/activate.qml
git commit -m "feat(activate): clicks select, double-clicks enter"
```

---

### Task 8: A click inside a live query

**Files:**
- Modify: `Overview.qml` — replace `selectMatchOrClearQuery`'s stub body (from Task 7)
- Test: `tests/ui/activate.qml`

This is the gap the spec review found: `target()` ranks the find match above the cursor, so a click
that only set the cursor would ring one window while `Enter` and `Ctrl+W` acted on another — and
`rematchAfterRebuild` → `followMatch` would then drag `selectedIndex` back to the match and
`applyTiles` would clear the orphaned cursor. The rebuild assertions below are the sharp half of
every test here.

- [ ] **Step 1: Write the failing tests**

```qml
    function type(s) { for (var i = 0; i < s.length; i++) keyClick(s.charAt(i)) }

    // Distinguishes: a click on a MATCH that sets the cursor instead of moving the match — the
    // ring would then say one thing and Enter another, and followMatch would undo it on the next
    // rebuild. "a" matches alpha and charlie; the click picks the one find did not select.
    function test_e_clicking_a_match_moves_the_selected_match() {
        type("a")
        verify(view.query.length > 0)
        var p = tileCentre("0xC")
        mouseClick(view, p.x, p.y)
        wait(30)
        compare(view.query, "a", "the query survives a click inside it")
        compare(view.selectedMatchAddress, "0xC")
        compare(view.cursorAddress, "", "the match branch must never set the cursor")

        view.rebuild()   // synchronous; the idiom every other UI suite uses
        compare(view.selectedMatchAddress, "0xC", "rematchAfterRebuild must preserve it")

        var t = view.resolveTarget()
        compare(t.kind, "window"); compare(t.address, "0xC", "Enter and Ctrl+W act on the click")
    }
    // Distinguishes: a click on a DIMMED tile being ignored (a visible tile left inert), or
    // selecting while the query stays live — where target() would keep returning the old match.
    function test_e_clicking_a_non_match_clears_the_query() {
        type("bravo")                             // matches 0xB only
        compare(view.selectedMatchAddress, "0xB")
        var p = tileCentre("0xC")                 // charlie: not a match
        mouseClick(view, p.x, p.y)
        wait(30)
        compare(view.query, "", "clicking outside the filter ends it")
        compare(view.cursorAddress, "0xC")
        compare(view.selectedId, 2)

        view.rebuild()   // synchronous; the idiom every other UI suite uses
        compare(view.cursorAddress, "0xC", "and survives the rebuild")
        var t = view.resolveTarget()
        compare(t.address, "0xC")
    }
    // Distinguishes: restorePreQuerySelection running AFTER the click's own selection and
    // stomping it — the ordering trap called out in the spec.
    function test_e_clicking_a_well_clears_the_query_then_selects() {
        type("bravo")
        var w = wellCentre(3)
        mouseClick(view, w.x, w.y)
        wait(30)
        compare(view.query, "")
        compare(view.selectedId, 3, "the click's own selection must outlive setQuery(\"\")")
        compare(view.cursorAddress, "")
    }
    // Distinguishes: a double-click inside a query that selects twice instead of committing.
    function test_e_double_clicking_a_match_enters_it() {
        type("a")
        var p = tileCentre("0xC")
        mouseDoubleClickSequence(view, p.x, p.y)
        wait(30)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf("address:0xC") >= 0)
    }
```

- [ ] **Step 2: Run and confirm the failures**

Run: `bash tests/ui/run.sh 2>&1 | grep -A4 "test_e_"`
Expected: `test_e_clicking_a_match_moves_the_selected_match` FAILs with `view.query` already `""` —
the Task 7 stub cleared it unconditionally. That is the stub being replaced, not a broken test.

- [ ] **Step 3: Implement**

Replace `selectMatchOrClearQuery`'s body in `Overview.qml`:

```qml
    // A click while a query is live. target() ranks the match above the cursor and the selected
    // workspace, so a click that only set the cursor would ring one window and act on another.
    // The split is on something already visible: matches ring in the accent, non-matches are
    // dimmed. A click INSIDE the filter moves the selected match and keeps the query — the same
    // thing Tab does. A click OUTSIDE it ends the query, then selects normally.
    function selectMatchOrClearQuery(addr) {
        for (var i = 0; i < matches.length; i++) {
            if (matches[i].address !== addr) continue
            matchIndex = i
            applyMatchRoles()
            followMatch()            // moves selectedIndex and scrolls; the cursor stays empty,
            return                   // because setQuery holds find and the cursor as exclusive
        }
        setQuery("")                 // runs restorePreQuerySelection(); the click's own
        var win = _windowByAddress[addr]   // selection must be applied AFTER it, never before
        if (!win) return
        selectedIndex = Logic.indexOfWorkspace(boxes, win.workspaceId)
        setCursor(addr)
        ensureSelectedVisible()
    }
```

**Property:** on the match branch the window cursor must stay empty. `setQuery` holds the invariant
that find and the cursor are never both live (`Overview.qml:732`), and this branch keeps the query
— setting the cursor here would break that invariant in the one place that never calls `setQuery`.

- [ ] **Step 4: Verify**

Run: `bash tests/ui/run.sh 2>&1 | grep -A4 "test_e_"`
Expected: all four PASS.

Run: `bash tests/run.sh`
Expected: whole suite green, `Find` included.

- [ ] **Step 5: Commit**

```bash
git add Overview.qml tests/ui/activate.qml
git commit -m "feat(activate): a click inside a query moves the match, outside it ends the query"
```

---

### Task 9: The hint row reads the active policy

**Files:**
- Modify: `Overview.qml:1995` (the `hintKeys` model)
- Test: `tests/ui/activate.qml`

- [ ] **Step 1: Write the failing test**

```qml
    // Distinguishes: a hint row hard-coded to the enter-policy wording, which would tell a
    // select-mode user that a digit jumps. Reads the live model, so it also catches a row that
    // changed shape.
    function test_f_the_hint_row_follows_the_policy() {
        function labelFor(key) {
            var m = view.testHintModel
            for (var i = 0; i < m.length; i++) if (m[i].k === key) return m[i].l
            fail("no hint cap for " + key)
        }
        compare(labelFor("1–0"), "select")
        compare(labelFor("↵"), "enter")

        view.testConfig.activate = "enter"
        compare(labelFor("1–0"), "jump", "the default policy's wording")
        compare(labelFor("↵"), "select")
    }
```

Note the en-dash in `"1–0"` — it must match the model entry exactly.

- [ ] **Step 2: Run and confirm it fails for the right reason**

Run: `bash tests/ui/run.sh 2>&1 | grep -A3 hint_row_follows`
Expected: FAIL with `Actual (): jump, Expected (): select` — not `no hint cap for 1–0`, which
would mean the model shape changed and the test needs updating first.

- [ ] **Step 3: Implement**

`Overview.qml:1995`, first two entries of the `hintKeys` model:

```qml
                        model: [ { k: "1–0", l: config.activate === "select" ? "select" : "jump" },
                                 { k: "tab", l: "workspace" }, { k: "↑ ↓ ← →", l: "window" },
                                 { k: "↵", l: config.activate === "select" ? "enter" : "select" },
```

- [ ] **Step 4: Verify**

Run: `bash tests/run.sh`
Expected: PASS. `Scratchpad` and `Lock` both assert against `testHintModel`/`testHintModel2` — if
either goes red, the model's shape changed rather than just its labels.

- [ ] **Step 5: Commit**

```bash
git add Overview.qml tests/ui/activate.qml
git commit -m "feat(activate): the hint row names the active policy"
```

---

### Task 10: Documentation

**Files:**
- Modify: `README.md` (the *Fast selection* bullet, and the config table)
- Modify: `ROADMAP.md`
- Modify: `docs/specs/2026-09-18-activate-select-design.md` (status line)

- [ ] **Step 1: Add `activate` to the sample config block**

`README.md:303-312` — the JSON sample. Add the key after `workspaces`:

```json
  "workspaces": 10,
  "activate": "enter",
  "motion": "auto",
```

- [ ] **Step 2: Add the prose entry**

`README.md`, in the bullet list below that block, between the `workspaces` and `motion` entries:

```markdown
- `activate` — what a digit or a click does. `"enter"` (default) is the behaviour above: a digit
  jumps to that workspace and a click focuses that window, both leaving the overview. `"select"`
  makes both *select* instead — the ring moves, the overview stays — and you commit with `Enter`,
  with the same digit a second time, or with a double-click. Under `"select"` the pointer stops
  targeting entirely: hovering a tile lifts it but changes nothing, so `Ctrl+W` closes the
  selected window rather than the hovered one. With `workspaces: 0`, a digit whose workspace has
  no box does nothing at all.
```

- [ ] **Step 3: Extend the *Fast selection* feature bullet**

`README.md:44-48` — append one sentence to that bullet, no more:

```markdown
  Set `activate` to `"select"` if you would rather a number or a click *selected* a target and
  left committing to `Enter`, a second press of the same digit, or a double-click.
```

- [ ] **Step 4: ROADMAP entry**

Run: `grep -n "card-presence\|actions-design\|specs/" ROADMAP.md | head` to see the surrounding
entries' format, then add this feature in the same shape, marked shipped, citing
`docs/specs/2026-09-18-activate-select-design.md`.

- [ ] **Step 5: Flip the spec's status line**

`docs/specs/2026-09-18-activate-select-design.md`, the `Status:` line near the top — change
`**approved design, pre-implementation**` to `**implemented**`, keeping the parenthesised revision
note that follows it.

- [ ] **Step 6: Verify nothing else claims the old behaviour**

Run: `grep -rn "Number keys jump\|1–0.*jump" README.md docs/`
Expected: every remaining hit is either inside this spec's `"enter"`-policy description (correct,
that policy still exists) or has been updated. A bare claim that digits always jump is now wrong.

- [ ] **Step 7: Commit**

```bash
git add README.md ROADMAP.md docs/specs/2026-09-18-activate-select-design.md
git commit -m "docs(activate): README, roadmap and spec status"
```

---

## Final verification

- [ ] `bash tests/run.sh` — Tier 1, Tier 2 and the Lua check, all green.
- [ ] `git log --oneline origin/main..HEAD` — ten commits, each self-contained.
- [ ] Manual smoke, both policies, in a real session: with no `activate` key in
  `~/.config/omarchy/omascape.json`, confirm digits still jump and a click still focuses — the
  default must be indistinguishable from today. Then set `"activate": "select"` and confirm the
  file watch picks it up without a shell restart.
