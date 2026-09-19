# Bar Drop-Down Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or
> executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for
> tracking.

**Goal:** Offer the picker as an opt-in full-width shade that drops out of the top bar and reads as
continuous with it, leaving today's centred card as the default.

**Architecture:** One config key (`anchor`) switches a handful of mode-dependent bindings in
`Overview.qml`. In bar mode the card squares off, spans the panel exactly, hangs from the focused
screen's reserved top strip, and paints the bar's own colour. The entrance becomes opacity-only,
with a per-row stagger driven by a single root-level progress property and two pure functions in
`logic.js`.

**Tech Stack:** Quickshell 0.3.1 / QML (Qt 6.11 local, **Qt 6.4 on CI**), plain-JS `logic.js`,
`qmltestrunner` Tier 1 + offscreen UI suites.

Spec: `docs/specs/2026-09-19-bar-dropdown-design.md`.

---

## Environment and toolchain assumptions

These are requirements, not background. Violate one and the build breaks somewhere other than here.

- **Qt 6.4 on CI, 6.11 locally.** An unknown QML property is a **compile error** on 6.4, not a
  no-op. `topLeftRadius` and per-corner radius are 6.7+; per-side borders do not exist. Nothing in
  this plan uses either — that is deliberate, and any "simplification" that reintroduces them will
  pass locally and fail CI.
- **Legacy reserved words cannot be identifiers on 6.4** (`float`, `int`, `char`, …). Do not name a
  variable `int` or `float` anywhere in `logic.js`.
- **The UI suites are not auto-discovered.** Tier 1 `tests/tst_*.qml` are found by
  `qmltestrunner -input tests/`; every UI suite is copied by hand in `tests/ui/run.sh`. A new suite
  that is not added there silently never runs.
- **`tests/ui/prepare.py` is shared by eight suites.** Task 4 edits it. Treat it as the
  highest-stakes task in this plan.
- **Commands.** Full suite: `mise run test`. One Tier 1 test:
  `/usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_name` (use `qmltestrunner6` on
  Debian/Ubuntu). One UI test: `bash tests/ui/run.sh Dropdown::test_name` — the positional
  argument is a **`TestCase::function` selector**, not a suite name; passing a bare suite name
  matches nothing and exits green, which looks like a pass.

## File structure

| File | Responsibility | Tasks |
|---|---|---|
| `logic.js` | `parseConfig.anchor`, `rowRanks`, `rowPhase` — all pure, all Tier 1 | 1, 2, 3 |
| `tests/tst_layout.qml` | Tier 1 coverage for the three above | 1, 2, 3 |
| `tests/ui/prepare.py` | Fixture: `anchor` on the config stub, `Color.bar.*` rewrite | 4 |
| `OmascapeConfig.qml` | Loads `anchor` from `~/.config/omarchy/omascape.json` | 5 |
| `Overview.qml` | `reservedTop`, `barMode`, mode-dependent geometry, entrance | 6, 7, 8, 9 |
| `WindowTile.qml` | `entranceOpacity` / `entranceOffsetY` hooks, composed into existing bindings | 9 |
| `tests/ui/dropdown.qml` | New offscreen suite for everything bar-mode | 6, 7, 8, 9 |
| `tests/ui/run.sh` | Registers the new suite | 6 |
| `ROADMAP.md` | Item 12 repointed from the parked prototype to this work | 10 |

---

### Task 1: `anchor` reaches `parseConfig`

**Files:**
- Modify: `logic.js` (the `parseConfig` return object)
- Test: `tests/tst_layout.qml`

- [ ] **Step 1: Write the failing test**

Append inside the existing `TestCase` in `tests/tst_layout.qml`:

```qml
    // Config keys are validated, never trusted: an unknown value must fall back rather than
    // reach a binding. The "left" case is the one that discriminates real validation from
    // `o.anchor || "center"`, which would happily return "left" and anchor the card nowhere.
    function test_anchor_accepts_only_the_two_known_modes() {
        compare(Logic.parseConfig('{"anchor":"bar"}').anchor, "bar", "the opt-in value")
        compare(Logic.parseConfig('{"anchor":"center"}').anchor, "center", "the default, stated")
        compare(Logic.parseConfig('{"anchor":"left"}').anchor, "center", "unknown value")
        compare(Logic.parseConfig('{"anchor":7}').anchor, "center", "wrong type")
        compare(Logic.parseConfig('{}').anchor, "center", "missing key")
        compare(Logic.parseConfig('not json').anchor, "center", "unparseable file")
    }
```

**What this distinguishes:** with no `anchor` key in the return object every line fails on
`undefined`. With a naive `o.anchor || "center"` the `"left"` and `7` lines fail. Both are real
failure modes — the second is the one a hurried implementation actually produces.

- [ ] **Step 2: Run it and watch it fail for that reason**

```bash
/usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_anchor_accepts_only_the_two_known_modes
```

Expected: FAIL — `Actual (): undefined`, `Expected (): bar`.

- [ ] **Step 3: Implement**

In `logic.js`, inside `parseConfig`'s returned object, after the `motion:` line:

```js
        // Which presentation the picker uses. "bar" hangs it off the top bar full-width;
        // anything else keeps the centred card. Validated like `motion` — an unknown value is
        // a typo in a hand-edited file, and a typo must not change how the picker is anchored.
        anchor: (o.anchor === "bar" || o.anchor === "center") ? o.anchor : "center",
```

- [ ] **Step 4: Run it and watch it pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "feat(dropdown): parseConfig validates the anchor key"
```

---

### Task 2: `Logic.rowRanks`

**Files:**
- Modify: `logic.js` (new function, place it immediately above `screenMargin`)
- Test: `tests/tst_layout.qml`

- [ ] **Step 1: Write the failing test**

```qml
    // Fed the REAL output of layout(), not hand-written boxes. That is the whole point: a
    // hand-built input would only prove the function sorts, while saying nothing about whether
    // boxes that share a row actually carry an identical `y`. If layout() ever computed row y
    // per-box instead of from one accumulator, hand-built inputs would keep passing while the
    // stagger tore rows in half on screen.
    function test_row_ranks_come_from_real_layout_rows() {
        var mons = []
        var wss = []
        for (var m = 0; m < 3; m++) {
            mons.push({ name: "M" + m, x: 0, y: m * 1080, width: 1920, height: 1080, scale: 1,
                        reserved: [0, 26, 0, 0], transform: 0 })
            for (var w = 1; w <= 10; w++)
                wss.push({ id: m * 10 + w, monitorName: "M" + m, focused: false, occupied: false })
        }
        // `params` is the TestCase property already defined at the top of this file, and
        // layout() reads it as input.params -- omit it and the call throws rather than fails.
        // There is no availH: layout() takes availW only.
        var out = Logic.layout({ monitors: mons, workspaces: wss, windows: [],
                                 focusedMonitorName: "M0", availW: 1876, params: params })
        var r = Logic.rowRanks(out.boxes)
        // 10 workspaces at maxCols 5 is two sub-rows per monitor, three monitors. Verified by
        // executing logic.js directly: the distinct y values are 28, 246, 498, 716, 968, 1186.
        compare(r.rowCount, 6, "six distinct row y values across the three groups")
        // THE discriminator between global and per-monitor ranking: monitor 1's first sub-row
        // must rank 2, not 0. Rank per group and the stagger restarts at every monitor.
        compare(r.ranks[11], 2, "M1's first sub-row follows M0's two")
        compare(r.ranks[1], 0, "M0's first sub-row is the top one")
        compare(r.ranks[6], 1, "M0's second sub-row")
        // Boxes sharing a row must share a rank exactly -- this is the float-equality claim.
        compare(r.ranks[1], r.ranks[5], "same sub-row, same rank")
    }

    function test_row_ranks_survive_a_degenerate_layout() {
        var r = Logic.rowRanks([])
        compare(r.rowCount, 0, "no boxes")
        compare(JSON.stringify(r.ranks), "{}", "no ranks")
        var bad = Logic.rowRanks([{ workspaceId: 1, y: NaN }, { workspaceId: 2, y: 40 }])
        compare(bad.ranks[1], 0, "a NaN y ranks first rather than propagating")
        compare(bad.rowCount, 1, "only the finite y counts as a row")
    }
```

**What this distinguishes:** the `ranks[11] === 2` line fails if ranking is done per monitor group
(a natural way to write it) — it would be 0. The `rowCount === 6` line fails if distinct-y
deduplication is missing (it would be 30). The NaN line fails if the guard is absent.

**Property the implementation must achieve:** boxes in one sub-row share a rank, ranks are global
and ascend down the whole canvas, and no input can produce `NaN` or `undefined` as a rank.

- [ ] **Step 2: Run it and watch it fail**

```bash
/usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_row_ranks_come_from_real_layout_rows
```

Expected: FAIL — `ReferenceError: rowRanks is not defined` (qmltestrunner reports it as the test
function throwing).

- [ ] **Step 3: Implement**

In `logic.js`, immediately above `function screenMargin(px) {`:

```js
// Row ordinal for every workspace box, taken from the layout's own y values and shared by the
// boxes and by the tiles inside them, so one row of the bar-mode entrance moves as a unit.
//
// Ranks are GLOBAL, not per monitor group: the stagger sweeps down the whole card, and restarting
// the count at each monitor would make the second screen's first row appear before the first
// screen's second.
//
// Exact float equality is safe here and is not an accident to be defended with a tolerance:
// layout() assigns `y: y` from one running accumulator, so every box in a sub-row carries the
// identical value by construction. A tolerance would only hide it if that ever stopped being true.
function rowRanks(boxes) {
    if (!boxes || !boxes.length) return { ranks: {}, rowCount: 0 }
    var ys = [], i, v
    for (i = 0; i < boxes.length; i++) {
        v = Number(boxes[i].y)
        if (isFinite(v) && ys.indexOf(v) < 0) ys.push(v)
    }
    ys.sort(function (a, b) { return a - b })
    var ranks = {}
    for (i = 0; i < boxes.length; i++) {
        v = Number(boxes[i].y)
        // A non-finite y ranks first rather than yielding undefined: the entrance must never be
        // handed a rank it cannot turn into a phase, which would leave that box invisible.
        ranks[boxes[i].workspaceId] = isFinite(v) ? ys.indexOf(v) : 0
    }
    return { ranks: ranks, rowCount: ys.length }
}
```

- [ ] **Step 4: Run both tests and watch them pass**

```bash
/usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_row_ranks_come_from_real_layout_rows
/usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_row_ranks_survive_a_degenerate_layout
```

Expected: PASS, PASS.

**If `rowCount` is not 6:** do not adjust the expectation to match. Print `out.boxes` and check
`maxCols` in `Overview.qml`'s layout params — the fixture assumes 5 columns, and a params change
would make the test's premise wrong rather than the function wrong.

- [ ] **Step 5: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "feat(dropdown): rowRanks turns layout y values into row ordinals"
```

---

### Task 3: `Logic.rowPhase`

**Files:**
- Modify: `logic.js` (immediately below `rowRanks`)
- Test: `tests/tst_layout.qml`

- [ ] **Step 1: Write the failing test**

```qml
    // The stagger's whole observable behaviour. Note what is NOT asserted: any particular
    // duration. The animation's length lives in Overview.qml; this function only decides how a
    // shared 0..1 progress is divided between rows.
    function test_row_phase_staggers_rows_without_lengthening_the_entrance() {
        // THE discriminator. Get the rank wiring backwards, or drop the stride entirely, and
        // every row returns the same phase -- which still animates, and still looks plausible,
        // and is not a stagger at all.
        verify(Logic.rowPhase(0.3, 1, 3) < Logic.rowPhase(0.3, 0, 3), "row 1 lags row 0")
        verify(Logic.rowPhase(0.3, 2, 3) < Logic.rowPhase(0.3, 1, 3), "row 2 lags row 1")
        // Every row completes exactly at the end -- the property that keeps the total fixed
        // however many rows there are.
        for (var k = 0; k < 3; k++) compare(Logic.rowPhase(1, k, 3), 1, "row " + k + " done at 1")
        for (var j = 0; j < 8; j++) compare(Logic.rowPhase(1, j, 8), 1, "8 rows also done at 1")
        // ...and the last row is genuinely still moving just before the end, so "done at 1" is
        // not merely the p >= 1 guard firing early for everyone.
        verify(Logic.rowPhase(0.99, 2, 3) < 1, "the last row is still arriving at 0.99")
        verify(Logic.rowPhase(0.99, 7, 8) < 1, "still true with more rows")
    }

    function test_row_phase_is_total_at_the_ends_and_safe_in_between() {
        compare(Logic.rowPhase(0, 0, 3), 0, "nothing has started")
        compare(Logic.rowPhase(0, 2, 3), 0, "including the last row")
        compare(Logic.rowPhase(0.5, 0, 1), 0.5, "a single row just follows progress")
        // A NaN must leave the grid VISIBLE, not invisible. The opposite default would produce
        // a card that holds keyboard focus while painting nothing -- the same failure mode
        // screenMargin's guard exists to prevent.
        compare(Logic.rowPhase(NaN, 0, 3), 1, "NaN progress")
        compare(Logic.rowPhase(0.5, NaN, 3), Logic.rowPhase(0.5, 0, 3), "NaN rank ranks first")
        compare(Logic.rowPhase(0.5, 0, NaN), 0.5, "NaN rowCount degrades to no stagger")
        compare(Logic.rowPhase(0.5, 99, 3), Logic.rowPhase(0.5, 2, 3), "rank clamps to the last row")
    }
```

**What this distinguishes:** the first test fails if rows are not offset from one another, or if
the last row's ramp is allowed to run past 1 (then `rowPhase(1, 2, 3)` is under 1) or to finish
early (then `rowPhase(0.99, 2, 3)` is already 1). The second fails if any guard is missing.

- [ ] **Step 2: Run them and watch them fail**

```bash
/usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_row_phase_staggers_rows_without_lengthening_the_entrance
```

Expected: FAIL — `rowPhase is not defined`.

- [ ] **Step 3: Implement**

In `logic.js`, directly below `rowRanks`:

```js
// How far into its own arrival row `rank` is, given one 0..1 progress shared by every row.
//
// Each row's ramp occupies ROW_SPAN of the timeline and the starts are spread across what is
// left, so the LAST row finishes exactly at 1 by construction. Adding rows therefore tightens
// the stagger rather than lengthening the entrance -- a three-monitor layout must not take
// noticeably longer to appear than a one-monitor layout.
var ROW_SPAN = 0.6
function rowPhase(progress, rank, rowCount) {
    var p = Number(progress)
    // Non-finite means fully arrived, never fully hidden: a NaN reaching a delegate's opacity
    // must leave the grid visible. An invisible card that still holds keyboard focus is the
    // worst outcome available here. The shared invariant is that NO guard returns 0 for a
    // non-finite input -- they degrade differently (progress -> 1, rank -> rank 0,
    // rowCount -> no stagger) but none of them vanishes.
    if (!isFinite(p)) return 1
    if (p <= 0) return 0
    if (p >= 1) return 1
    var n = Math.round(Number(rowCount))
    if (!isFinite(n) || n < 2) return p          // one row (or nonsense) means no stagger
    var k = Math.round(Number(rank))
    if (!isFinite(k)) k = 0
    k = Math.max(0, Math.min(n - 1, k))
    var t = (p - k * ((1 - ROW_SPAN) / (n - 1))) / ROW_SPAN
    return t <= 0 ? 0 : (t >= 1 ? 1 : t)
}
```

- [ ] **Step 4: Run both and watch them pass**

```bash
/usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_row_phase_staggers_rows_without_lengthening_the_entrance
/usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_row_phase_is_total_at_the_ends_and_safe_in_between
```

Expected: PASS, PASS.

- [ ] **Step 5: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "feat(dropdown): rowPhase divides one progress between staggered rows"
```

---

### Task 4: Fixture support — `anchor` and the bar colour token

**⚠ This is the highest-stakes task in the plan.** `tests/ui/prepare.py` builds the fixture that
all eight UI suites assert against. A defect here does not fail loudly; it makes every downstream
assertion agree with a fixture that does not resemble production.

**What the fixture must genuinely reproduce for later tasks:**
- `config.anchor` must default to `"center"`, so the seven existing suites keep their behaviour.
- `compositor.monitorFor(screen)` must keep matching **by name** — Task 6's whole point is that the
  reservation is read through the picker's own screen, and a fixture that resolved it any other way
  would make that test pass without exercising the fix.
- `compositor.focusedMonitor` must stay **independently settable** from `targetScreen`. If the
  fixture ever tied them together, Task 6's test could not tell the bug from the fix — that is the
  one property that must not collapse.

**What the environment cannot supply:** there is no compositor and no `Color` singleton. The
fixture substitutes a literal for theme colours, so this plan's tests can assert *geometry and
opacity* but never that the card's colour genuinely equals the bar's. That claim is live-check
only and is listed in the spec's visual section; do not add a fixture test that appears to cover it.

**Files:**
- Modify: `tests/ui/prepare.py:33` (Color rewrite), `tests/ui/prepare.py:~184` (config stub)

- [ ] **Step 1: Record the current suite totals**

```bash
mise run test 2>&1 | grep -E "^Totals|^PASS:"
```

Write the numbers down. They are the baseline for Step 4. At the time of writing: `Totals: 266
passed, 0 failed`, `PASS: 24 generated Lua chunks`.

- [ ] **Step 2: Add the `Color.bar.*` rewrite**

`Overview.qml` is about to reference `Color.bar.background` (Task 7). `prepare.py:32` strips the
`qs.Commons` import, and line 33 only rewrites `Color.menu.*` — so the new reference would reach
the fixture unresolved and **every UI suite would fail to compile at once**. Immediately after the
existing `Color\.menu\.` line:

```python
# Bar-mode paints Color.bar.background (Bar.qml:71), a different token from the menu one. Same
# treatment as Color.menu.*: there is no Color singleton here, and an unresolved reference is a
# compile error that takes all eight suites down together, not just the one under test.
qml = re.sub(r'Color\.bar\.\w+', '"#777777"', qml)
```

**Property:** the literal must differ from the `Color.menu.*` literal (`"#888888"`). Same value and
a test could not tell "bar mode uses the bar token" from "bar mode changed nothing".

- [ ] **Step 3: Add `anchor` to the config stub**

In the `OmascapeConfig.qml` stub string, after the `motion` line:

```python
    '           property string anchor: "center"\n'
```

**Property:** the default must be `"center"` — the seven existing suites must be unable to notice
this change.

- [ ] **Step 4: Verify no existing suite moved**

```bash
mise run test 2>&1 | grep -E "^Totals|^PASS:"
```

Expected: **identical** to Step 1. Any change in the counts means this task altered an existing
suite and must be investigated before going further — do not proceed on the assumption it is benign.

- [ ] **Step 5: Commit**

```bash
git add tests/ui/prepare.py
git commit -m "test(fixture): stub the anchor key and the bar colour token"
```

---

### Task 5: `OmascapeConfig.qml` loads `anchor`

**Files:**
- Modify: `OmascapeConfig.qml` (property declaration and `apply()`)

- [ ] **Step 1: Add the property**

After the `motion` property declaration:

```qml
    // "center" (default) keeps the centred card; "bar" hangs the picker off the top bar,
    // full-width. Bar mode needs an actual top bar to hang from — a side, bottom or hidden bar
    // reserves nothing at the top and falls back to centred on its own (Overview.qml barMode).
    property string anchor: "center"
```

- [ ] **Step 2: Assign it in `apply()`**

In `function apply(raw)`, after `cfg.motion = o.motion`:

```qml
        cfg.anchor = o.anchor
```

**Property:** `apply()` must assign every key `parseConfig` returns. A missing line here is the
defect that makes the key look implemented while a live edit to `omascape.json` does nothing — and
no test in this plan covers it, because the fixture replaces this whole component. Check it by
eye against `parseConfig`'s return object.

- [ ] **Step 3: Confirm nothing broke**

```bash
mise run test 2>&1 | grep -E "^Totals|failed"
```

Expected: unchanged from Task 4.

- [ ] **Step 4: Commit**

```bash
git add OmascapeConfig.qml
git commit -m "feat(dropdown): the anchor key reaches the component"
```

---

### Task 6: `reservedTop` and `barMode`, resolved from the picker's own screen

**Files:**
- Modify: `Overview.qml` (new properties near the layout params, ~line 244)
- Create: `tests/ui/dropdown.qml`
- Modify: `tests/ui/run.sh`

- [ ] **Step 1: Create the suite and register it**

Create `tests/ui/dropdown.qml`:

```qml
import QtQuick
import QtTest
// NOT "../logic.js": prepare.py writes logic.js into the fixture root beside the copied suite,
// so the parent directory is /tmp and the import fails with `Script file:///tmp/logic.js
// unavailable`. The flat form is what prepare.py's own config stub uses.
import "logic.js" as Logic

// Offscreen UI suite for the bar drop-down (docs/specs/2026-09-19-bar-dropdown-design.md).
// The fixture runs the real Overview against a stubbed compositor, so buildInput(),
// Logic.layout() and every binding under test here is production code.
TestCase {
    id: tc
    name: "Dropdown"
    when: windowShown
    width: 1920; height: 1080; visible: true
    property var view
    property var screenA
    property var screenB

    Component { id: overview; Overview {} }
    // focusedScreen() hands one of these back and open() stores it as targetScreen; the fixture
    // resolves monitorFor() against compositor.monitors BY NAME, exactly as the real one does.
    Component {
        id: screenStub
        QtObject { property string name: ""; property int width: 1920; property int height: 1080 }
    }

    // `top` is the monitor's reserved TOP strip — the bar. 26 is Omarchy's default bar height
    // (Style.qml:342, size-horizontal).
    function monitor(name, y, top) {
        return { name: name, x: 0, y: y, width: 1920, height: 1080, scale: 1,
                 lastIpcObject: { reserved: [0, top, 0, 0], transform: 0,
                                  activeWorkspace: { id: 1 },
                                  specialWorkspace: { id: 0, name: "" } } }
    }

    // One monitor, `perMon` workspaces, bar reserving `top`. The panel is sized BEFORE open()
    // so the first rebuild already sees the real width.
    function seed(top, perMon, anchor) {
        view = createTemporaryObject(overview, tc)
        verify(view)
        screenA = createTemporaryObject(screenStub, tc, { name: "A" })
        view.testConfig.anchor = anchor === undefined ? "bar" : anchor
        view.testPanel.width = 1920
        view.testPanel.height = 1080
        var monA = monitor("A", 0, top)
        var wss = []
        for (var k = 1; k <= perMon; k++) wss.push({ id: k, monitor: monA, toplevels: { values: [] } })
        view.compositor.monitors = { values: [monA] }
        view.compositor.focusedMonitor = monA
        view.compositor.focusedWorkspace = { id: 1 }
        view.compositor.workspaces = { values: wss }
        view.testScreens = [screenA]
        view.open()
        wait(120)
    }

    function cleanup() { if (view) view.close() }

    function test_the_card_hangs_from_the_reserved_top_strip() {
        seed(26, 10)
        compare(view.testCard.y, 26, "the card's top edge meets the bar's bottom edge")
    }

    // The fallback. A side, bottom or hidden bar reserves nothing at the top, and the picker
    // must return to the centred card rather than anchoring to an edge with nothing on it.
    function test_no_top_reservation_falls_back_to_centred() {
        seed(0, 10)
        verify(!view.barMode, "barMode must be false with nothing reserved")
        verify(view.testCard.x > 0, "a centred card keeps a side margin, got x=" + view.testCard.x)
    }
}
```

Register it in `tests/ui/run.sh`, after the `presence.qml` line:

```bash
cp "$src/tests/ui/dropdown.qml" "$fixture/tst_dropdown_ui.qml"
```

**Property:** without this `cp` the suite never runs and every later task's tests silently pass by
not existing. Confirm registration worked by checking the test count rises in Step 3.

- [ ] **Step 2: Run and watch it fail**

```bash
bash tests/ui/run.sh Dropdown::test_the_card_hangs_from_the_reserved_top_strip
```

Expected: FAIL — the card is centred, so `card.y` is a few hundred, not 26.

- [ ] **Step 3: Implement**

In `Overview.qml`, immediately after the layout-params block (the `readonly property var P:` object
ending around line 244):

```qml
    // ---- Bar attachment ------------------------------------------------------------------
    // The reserved TOP strip of the screen the picker is ON. The overlay is an Overlay-layer
    // surface with exclusionMode Ignore, so panel.height is the WHOLE screen and the bar sits
    // underneath it; `reserved` is the only thing that says where the bar ends.
    //
    // Resolved through targetScreen, NOT through Hyprland.focusedMonitor. open() captures
    // targetScreen once, but focus keeps moving: focus landing on a monitor that reserves a
    // different amount — or nothing — would otherwise re-anchor the card, resize its height cap
    // and flip bar mode off underneath an open picker.
    //
    // monitorEpoch is the dependency, exactly as the reminder frame's binding uses it:
    // monitorFor() is a one-shot C++ invokable and nothing notifies QML when Hyprland REPLACES
    // the monitor object for a screen, so without it this keeps a stale or null pointer.
    readonly property int reservedTop: {
        var m = (root.monitorEpoch,
                 root.targetScreen ? Hyprland.monitorFor(root.targetScreen) : null)
        var r = m && m.lastIpcObject ? m.lastIpcObject.reserved : null
        return (r && r.length > 1 && isFinite(r[1]) && r[1] > 0) ? Math.round(r[1]) : 0
    }
    // No top bar to hang from (a side, bottom or hidden bar) means no attachment: the picker
    // keeps the centred card rather than squaring itself against nothing.
    readonly property bool barMode: config.anchor === "bar" && reservedTop > 0
```

- [ ] **Step 4: Run both and watch them pass**

```bash
bash tests/ui/run.sh Dropdown::test_the_card_hangs_from_the_reserved_top_strip
bash tests/ui/run.sh Dropdown::test_no_top_reservation_falls_back_to_centred
```

Expected: the first still FAILS (the card's anchors are Task 7's job; only `barMode` exists yet),
the second PASSES. That is correct — leave the first failing and move on. If the second also fails,
`barMode` or the fixture registration is wrong; fix that before Task 7.

- [ ] **Step 5: Commit**

```bash
git add Overview.qml tests/ui/dropdown.qml tests/ui/run.sh
git commit -m "feat(dropdown): resolve the bar reservation from the picker's own screen"
```

---

### Task 7: Bar-mode geometry

**Files:**
- Modify: `Overview.qml` — `availCanvasW` (~line 257), scrim (~line 1460), card block (~1470-1530)
- Test: `tests/ui/dropdown.qml`

- [ ] **Step 1: Write the failing tests**

Append to `tests/ui/dropdown.qml`:

```qml
    // Full width is what makes the attachment read: Omarchy's bar is edge-to-edge and flush
    // (Bar.qml:1027), so a card inset from the screen edges always looks like a separate object
    // hanging underneath rather than an extension of the bar.
    function test_the_card_spans_the_screen_exactly() {
        seed(26, 10)
        compare(view.testCard.x, 0, "flush with the left edge")
        compare(view.testCard.width, 1920, "and the right")
    }

    // Isolates the availCanvasW binding from the card's width. Wire only the card and the grid
    // still lays out for a 96px-margin canvas, leaving unused room inside a full-width card --
    // which the assertion above cannot see.
    function test_the_grid_uses_the_full_width() {
        seed(26, 10)
        verify(view.testFlick.contentWidth <= view.testFlick.width,
               "content " + view.testFlick.contentWidth + " must fit " + view.testFlick.width)
        verify(view.testFlick.contentWidth > 1700,
               "the grid must actually use the new room, got " + view.testFlick.contentWidth)
    }

    function test_the_card_squares_off_against_the_bar() {
        seed(26, 10)
        compare(view.testCard.radius, 0, "no rounded corners in bar mode")
        compare(view.testCard.border.width, 0, "the card's own border is off; the rule is a child")
    }

    // The bottom cap. Only bites on overflow -- the card is content-sized -- so the fixture
    // must genuinely overflow or this proves nothing.
    function test_a_tall_layout_stops_short_of_the_bottom_edge() {
        seed(26, 40)
        verify(view.testCanvas.implicitHeight > 1080 - 26 - Logic.screenMargin(1080),
               "fixture must overflow, got " + view.testCanvas.implicitHeight)
        compare(view.testCard.height, 1080 - 26 - Logic.screenMargin(1080), "the cap binds")
        verify(view.testFlick.contentHeight > view.testFlick.height, "a capped card still scrolls")
    }

    // The scrim must not dim the bar the card is supposed to be continuous with.
    function test_the_scrim_starts_below_the_bar() {
        seed(26, 10)
        compare(view.testScrim.y, 26, "the scrim begins where the bar ends")
    }
```

**What these distinguish:** `test_the_card_spans_the_screen_exactly` fails if the card keeps
`screenMargin`; `test_the_grid_uses_the_full_width`'s **second** assertion is the one that catches
wiring the card but not `availCanvasW` — the first would pass either way. `radius`/`border.width`
fail if the mode-dependent bindings are missing. The tall-layout test's first line is a fixture
precondition: if it trips, the assertion below it is meaningless, not wrong.

- [ ] **Step 2: Run them and watch them fail**

```bash
bash tests/ui/run.sh Dropdown::test_the_card_spans_the_screen_exactly
```

Expected: FAIL — `Actual 96, Expected 0` (the centred card's margin).

- [ ] **Step 3: Implement**

**3a.** Add the bar colour to the palette block (`Overview.qml`, after `property color scrim:`):

```qml
    // The bar's own ground, a DIFFERENT token from the menu one (Bar.qml:71). Both fall through
    // to Color.background on a theme without a shell.toml, so they match by accident there; a
    // theme that sets [bar] background diverges them, and an attached card must follow the bar.
    property color barBackground: Color.bar.background
```

**3b.** `availCanvasW` — bar mode takes no side margin:

```qml
    readonly property real availCanvasW:
        panel.width > 0
            ? panel.width - 2 * card.pad - (root.barMode ? 0 : 2 * Logic.screenMargin(panel.width))
            : 1600
```

**3c.** The scrim (`Overview.qml` ~line 1460) starts below the bar:

```qml
        // Starts BELOW the bar when the card is attached to it: a card meeting a dimmed bar
        // reads as covering it, not as hanging from it, which is the whole point of attaching.
        Rectangle { id: scrimRect
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                              top: parent.top; topMargin: root.barMode ? root.reservedTop : 0 }
                    color: root.scrim; visible: config.scrim; opacity: 0 }
```

**3d.** The card. Replace `anchors.centerIn: parent` with explicit anchors plus a width binding —
`horizontalCenter` with an explicit `width` avoids ever having `centerIn` and `left`/`right` set at
the same time, which is an anchor conflict QML resolves by warning and ignoring one of them:

```qml
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: root.barMode ? undefined : parent.verticalCenter
            anchors.top: root.barMode ? parent.top : undefined
            anchors.topMargin: root.reservedTop
            // Full width in bar mode. Setting `width` overrides the implicitWidth binding, so
            // the Behavior on implicitWidth goes inert there — correct, since the width is the
            // screen and must never animate.
            width: root.barMode ? panel.width : implicitWidth
            // Square against the bar, and no border of its own: with no radius there are no top
            // corners to hide, so nothing is ever painted OVER the card. That matters because
            // barBackground may carry alpha, and two stacked translucent fills composite darker
            // than one (two at 50% give 75%), which is what a cover-up strip would produce.
            radius: root.barMode ? 0 : root.cardRadius
            border.width: root.barMode ? 0 : 1
            color: root.barMode ? root.barBackground : root.background
```

**3e.** `maxCardH` — room below the bar, less one margin at the bottom:

```qml
            readonly property real maxCardH: panel.height > 0
                ? panel.height - (root.barMode ? root.reservedTop + Logic.screenMargin(panel.height)
                                               : 2 * Logic.screenMargin(panel.height))
                : 900
```

**3f.** The bottom rule, as a **child** of the card (not a cover-up — it is a hairline drawn on the
card's own fill, so the card's background is still painted exactly once). Put it immediately after
the card's `MouseArea { anchors.fill: parent; onClicked: {} }`:

```qml
            // The card's only visible edge in bar mode: the top is the join with the bar, the
            // sides are the screen edges. A child rather than the card's own border, because the
            // border would also draw down both sides and along the join.
            Rectangle {
                id: bottomRule
                visible: root.barMode
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 1
                color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)
            }
```

- [ ] **Step 3g: Add the translucency guard the spec calls for**

The spec requires a test that a translucent card composites to exactly **one** fill. The design no
longer contains anything that could break this — there is no cover-up strip any more — so this is a
**regression guard**, not a discriminator, and the plan says so rather than pretending otherwise:
it goes red if someone reintroduces a rectangle painted over the card in `card.color`, which is
precisely how the first draft of the spec was wrong.

```qml
    // Two stacked 50% fills composite to 75%, and the result looks deliberate unless something
    // measures it. Sampled at x=5 -- inside card.pad, so left of the Flickable -- where the only
    // thing painted is the card's own background.
    //
    // Limitation, stated so nobody reads more into a pass than is there: the fixture rewrites
    // Color.bar.* to a literal, so this proves uniformity of the fill, NOT that the colour equals
    // the bar's. That claim is live-check only.
    function test_a_translucent_card_composites_to_a_single_fill() {
        seed(26, 10)
        // Breaks the colour binding deliberately: the fixture's literal is opaque, and an
        // opaque card cannot show the doubling this guards against.
        view.testCard.color = Qt.rgba(0.5, 0.5, 0.5, 0.5)
        wait(60)
        var img = grabImage(view.testCard)
        var top = img.pixel(5, 3)
        var mid = img.pixel(5, 300)
        verify(Qt.colorEqual(top, mid),
               "the top edge must be the same fill as the body, got " + top + " vs " + mid)
    }
```

**What this distinguishes:** a `Rectangle` of `card.color` anchored over the card's top — the
`topFill` construct the spec review rejected — makes `top` measurably denser than `mid`.

- [ ] **Step 4: Run the whole suite and watch it pass**

```bash
bash tests/ui/run.sh Dropdown::test_the_card_spans_the_screen_exactly
bash tests/ui/run.sh Dropdown::test_the_grid_uses_the_full_width
bash tests/ui/run.sh Dropdown::test_the_card_squares_off_against_the_bar
bash tests/ui/run.sh Dropdown::test_a_tall_layout_stops_short_of_the_bottom_edge
bash tests/ui/run.sh Dropdown::test_the_scrim_starts_below_the_bar
bash tests/ui/run.sh Dropdown::test_a_translucent_card_composites_to_a_single_fill
bash tests/ui/run.sh Dropdown::test_the_card_hangs_from_the_reserved_top_strip
mise run test 2>&1 | grep -E "^Totals|failed"
```

Expected: all PASS, and `Totals` shows the Presence suite still green — Task 7 touches bindings
that PR #24's tests assert on, so a regression there is the likely failure.

- [ ] **Step 5: Commit**

```bash
git add Overview.qml tests/ui/dropdown.qml
git commit -m "feat(dropdown): full-width square card attached to the bar"
```

---

### Task 8: Opacity-only entrance in bar mode

**Files:**
- Modify: `Overview.qml:1310` (`enterAnim` scale), `Overview.qml:1320` (`exitAnim` scale)
- Test: `tests/ui/dropdown.qml`

- [ ] **Step 1: Write the failing test**

```qml
    // Sampled DURING the animation, not at rest. At rest a scaled and an unscaled card are
    // identical, so an end-state assertion passes against exactly the bug it should catch.
    //
    // mapToItem gives the card's REAL rendered edges: it applies the full transform chain, so
    // this states the property (the card's painted bounds stay pinned to the screen edges) and
    // not the mechanism. A later switch to a vertical-only Scale transform would still pass;
    // reinstating the uniform `scale` property would not.
    //
    // enterAnim scales 0.96 -> 1 about the top CENTRE: transformOrigin changes the pivot but
    // not the fact that scaling is uniform, so on a 1920 panel the sides would travel 38.4px
    // inward on entrance and 19.2px on exit -- with a full-width card, visibly off both edges.
    function test_the_card_stays_pinned_to_the_screen_edges_while_animating() {
        view = createTemporaryObject(overview, tc)
        verify(view)
        screenA = createTemporaryObject(screenStub, tc, { name: "A" })
        // Stretch the entrance so sampling is not a race: durations are Math.round(200 * scale).
        view.motion.scale = 10
        view.testConfig.anchor = "bar"
        view.testPanel.width = 1920
        view.testPanel.height = 1080
        var monA = monitor("A", 0, 26)
        var wss = []
        for (var k = 1; k <= 10; k++) wss.push({ id: k, monitor: monA, toplevels: { values: [] } })
        view.compositor.monitors = { values: [monA] }
        view.compositor.focusedMonitor = monA
        view.compositor.focusedWorkspace = { id: 1 }
        view.compositor.workspaces = { values: wss }
        view.testScreens = [screenA]

        view.open()
        for (var i = 0; i < 4; i++) {
            wait(120)
            var l = view.testCard.mapToItem(view.testPanel, 0, 0).x
            var r = view.testCard.mapToItem(view.testPanel, view.testCard.width, 0).x
            fuzzyCompare(l, 0, 0.5, "left edge during entrance, sample " + i)
            fuzzyCompare(r, 1920, 0.5, "right edge during entrance, sample " + i)
        }
        view.close()
        for (var j = 0; j < 3; j++) {
            wait(120)
            var l2 = view.testCard.mapToItem(view.testPanel, 0, 0).x
            var r2 = view.testCard.mapToItem(view.testPanel, view.testCard.width, 0).x
            fuzzyCompare(l2, 0, 0.5, "left edge during exit, sample " + j)
            fuzzyCompare(r2, 1920, 0.5, "right edge during exit, sample " + j)
        }
    }

    // ...and the centred card must KEEP its scale entrance. Without this, "fix" the bug by
    // deleting the scale animation outright and every other test still passes.
    function test_the_centred_card_still_scales_on_entry() {
        view = createTemporaryObject(overview, tc)
        verify(view)
        screenA = createTemporaryObject(screenStub, tc, { name: "A" })
        view.motion.scale = 10
        view.testConfig.anchor = "center"
        view.testPanel.width = 1920
        view.testPanel.height = 1080
        var monA = monitor("A", 0, 26)
        view.compositor.monitors = { values: [monA] }
        view.compositor.focusedMonitor = monA
        view.compositor.focusedWorkspace = { id: 1 }
        view.compositor.workspaces = { values: [{ id: 1, monitor: monA, toplevels: { values: [] } }] }
        view.testScreens = [screenA]
        view.open()
        wait(120)
        verify(view.testCard.scale < 1,
               "the centred entrance still scales, got " + view.testCard.scale)
    }
```

**What these distinguish:** the first goes red the moment the uniform scale is applied in bar mode —
at sample 0 the left edge is ~38 rather than 0. The second goes red if the scale animation is
removed for *both* modes rather than just bar mode, which is the obvious over-correction.

- [ ] **Step 2: Run and watch the first fail**

```bash
bash tests/ui/run.sh Dropdown::test_the_card_stays_pinned_to_the_screen_edges_while_animating
```

Expected: FAIL — `left edge during entrance, sample 0`, actual ≈ 38.4, expected 0.

- [ ] **Step 3: Implement**

`Overview.qml`, in `enterAnim`:

```qml
        // Bar mode does not scale. transformOrigin would move the pivot but not stop horizontal
        // scaling, and a full-width card that shrinks away from both screen edges contradicts
        // the one thing the attachment is for. The row stagger carries the motion instead.
        NumberAnimation { target: card; property: "scale"
                          from: root.barMode ? 1 : 0.96; to: 1
                          duration: root.motion.enter; easing.type: root.motion.entrance
                          easing.overshoot: root.motion.overshoot }
```

and in `exitAnim`:

```qml
        NumberAnimation { target: card; property: "scale"; to: root.barMode ? 1 : 0.98
                          duration: root.motion.exit; easing.type: root.motion.move }
```

**Property:** `card.scale` must remain exactly 1 for the whole of both animations in bar mode, and
must still leave 1 during the centred entrance. Keeping the animations (rather than removing them)
means `_showVisuals`, the `motion.scale` test hook and `SoftShadow`'s `scale: card.scale` binding
all keep working untouched.

- [ ] **Step 4: Run both and watch them pass**

```bash
bash tests/ui/run.sh Dropdown::test_the_card_stays_pinned_to_the_screen_edges_while_animating
bash tests/ui/run.sh Dropdown::test_the_centred_card_still_scales_on_entry
```

Expected: PASS, PASS.

- [ ] **Step 5: Commit**

```bash
git add Overview.qml tests/ui/dropdown.qml
git commit -m "fix(dropdown): bar mode must not scale horizontally on entry or exit"
```

---

### Task 9: The staged row entrance

**Files:**
- Modify: `Overview.qml` — root properties, `applyBoxes` (~1098), `open()` (~1244), box delegate
  (~1676), tile delegate (~1765)
- Test: `tests/ui/dropdown.qml`

- [ ] **Step 1: Write the failing test**

```qml
    // The stagger's observable contract, asserted on the delegates rather than on the pure
    // function (which tst_layout.qml already covers): rows must differ from one another
    // mid-entrance, and everything must end fully visible.
    function test_rows_arrive_staggered_and_all_end_visible() {
        view = createTemporaryObject(overview, tc)
        verify(view)
        screenA = createTemporaryObject(screenStub, tc, { name: "A" })
        view.motion.scale = 10
        view.testConfig.anchor = "bar"
        view.testPanel.width = 1920
        view.testPanel.height = 1080
        var monA = monitor("A", 0, 26)
        var wss = []
        // One window on workspace 6 -- the SECOND row -- so the tile path is covered too.
        var win = { address: "0xA", at: [100, 1500], size: [400, 400], floating: false,
                    title: "alpha", "class": "alpha", fullscreen: 0 }
        for (var k = 1; k <= 10; k++)
            wss.push({ id: k, monitor: monA,
                       toplevels: { values: k === 6 ? [{ lastIpcObject: win }] : [] } })
        view.compositor.monitors = { values: [monA] }
        view.compositor.focusedMonitor = monA
        view.compositor.focusedWorkspace = { id: 1 }
        view.compositor.workspaces = { values: wss }
        view.testScreens = [screenA]
        view.open()
        wait(150)
        // Ten workspaces at maxCols 5 is two rows. Workspace 1 is in the first, 6 in the second.
        var first = view.boxOpacityFor(1)
        var second = view.boxOpacityFor(6)
        verify(first > second,
               "row 0 must lead row 1 mid-entrance, got " + first + " and " + second)
        // The tile path, which is wired through WindowTile's entranceOpacity rather than its
        // opacity. Without this the tile wiring is never exercised and a tile left at full
        // opacity while its well fades in would ship unnoticed.
        fuzzyCompare(view.tileEntranceFor("0xA"), second, 0.01,
                     "a tile must share its box's phase exactly")
        wait(3000)
        fuzzyCompare(view.boxOpacityFor(1), 1, 0.01, "row 0 ends visible")
        fuzzyCompare(view.boxOpacityFor(6), 1, 0.01, "row 1 ends visible")
    }

    // A rebuild mid-session must not replay the entrance. boxesModel is reconciled in place, so
    // a stagger keyed on delegate creation would be invisible here but a stagger re-triggered by
    // a rebuild would flash the whole grid every time a window moved.
    function test_a_rebuild_does_not_replay_the_stagger() {
        seed(26, 10)
        wait(400)
        fuzzyCompare(view.boxOpacityFor(1), 1, 0.01, "precondition: the entrance has finished")
        view.compositor.rawEvent({ name: "openwindow", data: "" })
        view.rebuild()
        wait(30)
        fuzzyCompare(view.boxOpacityFor(1), 1, 0.01, "a rebuild must not restart the entrance")
        fuzzyCompare(view.boxOpacityFor(6), 1, 0.01, "nor for the later row")
    }

    // Motion off means arrived, not hidden.
    function test_motion_off_shows_every_row_immediately() {
        view = createTemporaryObject(overview, tc)
        verify(view)
        screenA = createTemporaryObject(screenStub, tc, { name: "A" })
        view.motion.scale = 0                 // disables root.motion.enabled
        view.testConfig.anchor = "bar"
        view.testPanel.width = 1920
        view.testPanel.height = 1080
        var monA = monitor("A", 0, 26)
        var wss = []
        for (var k = 1; k <= 10; k++) wss.push({ id: k, monitor: monA, toplevels: { values: [] } })
        view.compositor.monitors = { values: [monA] }
        view.compositor.focusedMonitor = monA
        view.compositor.focusedWorkspace = { id: 1 }
        view.compositor.workspaces = { values: wss }
        view.testScreens = [screenA]
        view.open()
        wait(30)
        compare(view.entranceProgress, 1, "progress is set directly, not animated")
        fuzzyCompare(view.boxOpacityFor(6), 1, 0.01, "the last row is visible at once")
    }
```

**What these distinguish:** the first fails if every row shares one phase (no stagger) or if rows
never reach 1. The second fails if the stagger is keyed to anything a rebuild re-triggers. The
third fails if the motion policy is not honoured — which would leave the grid invisible when the
user has animations off, the worst available outcome.

**Test helper required.** These read box opacity by workspace id, which needs a hook. Add to the
fixture's alias block in `tests/ui/prepare.py` — this is a *second* edit to the shared fixture, so
re-run the full suite after it as in Task 4:

```python
    '''    function boxOpacityFor(wsid) {
        for (var i = 0; i < boxRepeater.count; i++) {
            var b = boxRepeater.itemAt(i)
            if (b && b.model && b.model.workspaceId === wsid) return b.opacity
        }
        return -1
    }
    function tileEntranceFor(addr) {
        for (var i = 0; i < tileRepeater.count; i++) {
            var t = tileRepeater.itemAt(i)
            if (t && t.tileAddress === addr) return t.entranceOpacity
        }
        return -1
    }
'''
```

and give the boxes Repeater an id in `Overview.qml` (`Repeater { id: boxRepeater; model: boxesModel`)
so the helper can reach it. **Property:** `boxOpacityFor` must return `-1` for an unknown id, never
0 — a 0 would read as "fully transparent" and make a broken lookup look like a passing stagger
assertion.

- [ ] **Step 2: Run and watch it fail**

```bash
bash tests/ui/run.sh Dropdown::test_rows_arrive_staggered_and_all_end_visible
```

Expected: FAIL — both rows report opacity 1, so `first > second` is false.

- [ ] **Step 3: Implement**

**3a.** Root properties, next to `barMode`:

```qml
    // One progress for the whole bar-mode entrance; every row derives its own phase from it.
    // Root-level and not per-delegate: tilesModel and boxesModel are reconciled IN PLACE, so
    // delegates persist across rebuilds and a per-delegate Component.onCompleted would fire once
    // at startup and never again. It also means a mid-session rebuild cannot replay the
    // entrance — progress is already 1 by then.
    property real entranceProgress: 1
    property var rowRankMap: ({})
    property int rowCount: 0
    NumberAnimation {
        id: staggerAnim
        target: root; property: "entranceProgress"
        from: 0; to: 1; duration: root.motion.enter; easing.type: root.motion.move
    }
```

**3b.** In `applyBoxes(boxes)` (~line 1098), before the model reconcile loop:

```qml
        // Row ordinals for the bar-mode entrance. Recomputed on every rebuild so the map stays
        // correct as the layout changes; that costs nothing visually, because entranceProgress
        // is already 1 outside the entrance itself.
        var rr = Logic.rowRanks(boxes)
        root.rowRankMap = rr.ranks
        root.rowCount = rr.rowCount
```

**3c.** In `open()` (~line 1244), after `opened = true`:

```qml
        // The staged entrance is bar-mode only: a top-down stagger under a card that scales from
        // its centre reads as a bug. With motion off, progress is SET, never animated — an
        // unplayed animation would leave every row at 0, i.e. an invisible grid.
        staggerAnim.stop()
        if (root.barMode && root.motion.enabled) { root.entranceProgress = 0; staggerAnim.start() }
        else root.entranceProgress = 1
```

**3d.** The box delegate (`Repeater { id: boxRepeater; model: boxesModel` → its `Rectangle`), after
the `color:` binding:

```qml
                            // Arrival phase for this box's row. A Translate, not a `y` change:
                            // the y binding already carries the layout-motion Behavior, and the
                            // entrance must never fight a glide still in flight.
                            // NO `|| 0` on the lookup. Rank 0 is a legitimate value (every
                            // layout has a top row), so `|| 0` would turn a MISS into a silent
                            // "first row". A miss cannot happen -- every box gets a rank, and
                            // logic.js:360 skips any window whose workspace has no box, so no
                            // tile can reference a rankless workspace -- and if that invariant
                            // ever breaks it must be visible, not smoothed over. rowPhase's own
                            // non-finite guard is the single fail-safe.
                            readonly property real rowPhase: root.barMode
                                ? Logic.rowPhase(root.entranceProgress,
                                                 root.rowRankMap[model.workspaceId],
                                                 root.rowCount)
                                : 1
                            opacity: rowPhase
                            transform: Translate { y: (1 - boxItem.rowPhase) * 10 }
```

**3e.** `WindowTile.qml` needs two new hooks first. **Do not bind the delegate's `opacity` or
`transform` directly** — `WindowTile.qml:118` already binds `opacity` (drag, find-dimming, closing)
and `:123` already holds a `transform: Scale` for the drag ghost. Overriding either from the
delegate silently breaks drag opacity, query dimming and the hover scale, which several existing
suites assert on. **And do not reuse `appearScale`/`appearOpacity`:** `appearAnim` (`:107`) writes
to those directly when a single tile is created mid-session, so a binding there would fight a
running animation.

Add to `WindowTile.qml`, beside the existing `appearScale`/`appearOpacity` declarations (~line 98):

```qml
    // The CARD's staged entrance (bar mode), driven from Overview so a tile arrives with the row
    // of boxes it sits in. Deliberately separate from appearScale/appearOpacity: those belong to
    // a single tile appearing mid-session and are written by appearAnim, not bound.
    property real entranceOpacity: 1
    property real entranceOffsetY: 0
```

Multiply the opacity hook into the existing binding (`WindowTile.qml:118`) rather than replacing it:

```qml
    opacity: (dragging ? dragOpacity : ((dimmed || closing) ? 0.35 : 1)) * appearOpacity * entranceOpacity
```

and make `transform` a **list** so the drag ghost survives (`WindowTile.qml:123`):

```qml
    transform: [
        Scale {
            id: ghost
            origin.x: tile.grabX; origin.y: tile.grabY
            xScale: tile.dragging ? tile.dragScale : 1
            yScale: xScale
            Behavior on xScale { enabled: tile.motion.enabled
                NumberAnimation { duration: tile.motion.fast; easing.type: tile.motion.hover } }
        },
        Translate { y: tile.entranceOffsetY }
    ]
```

**Property:** every existing tile behaviour must be unchanged when `entranceOpacity` is 1 and
`entranceOffsetY` is 0, which is their state in centred mode and after any entrance completes. The
drag suite is the one that proves it — run `bash tests/ui/run.sh` with no argument after this edit.

Then wire the delegate in `Overview.qml` (under `tileRepeater`, after `cursorTarget:`):

```qml
                            // Tiles take their BOX's rank, looked up by workspace id, so a tile
                            // can never stagger out of step with the well it sits in.
                            // Same rule as the box delegate: no `|| 0`. See the comment there.
                            readonly property real rowPhase: root.barMode
                                ? Logic.rowPhase(root.entranceProgress,
                                                 root.rowRankMap[model.wsid],
                                                 root.rowCount)
                                : 1
                            entranceOpacity: rowPhase
                            entranceOffsetY: (1 - rowPhase) * 10
```

- [ ] **Step 4: Run all three, then the whole suite**

```bash
bash tests/ui/run.sh Dropdown::test_rows_arrive_staggered_and_all_end_visible
bash tests/ui/run.sh Dropdown::test_a_rebuild_does_not_replay_the_stagger
bash tests/ui/run.sh Dropdown::test_motion_off_shows_every_row_immediately
mise run test 2>&1 | grep -E "^Totals|failed"
```

Expected: all PASS, and no existing suite regressed. **`opacity` on the box delegate is the likely
regression site** — several suites assert on tile and box visibility, and a `rowPhase` that
returns anything but 1 in centred mode would break them all at once.

- [ ] **Step 5: Commit**

```bash
git add Overview.qml WindowTile.qml tests/ui/prepare.py tests/ui/dropdown.qml
git commit -m "feat(dropdown): rows arrive staggered under the bar"
```

---

### Task 10: The focus-change regression test, and the docs

**Files:**
- Test: `tests/ui/dropdown.qml`
- Modify: `ROADMAP.md`

- [ ] **Step 1: Write the focus-change test**

This is Task 6's fix proven, and it is deliberately last so it runs against the finished geometry.

```qml
    // Finding 3 from the spec review. open() captures targetScreen once; focus keeps moving.
    // Reading live focus would re-anchor the card and resize its height cap underneath an open
    // picker whenever focus landed on a monitor reserving a different amount -- or flip bar mode
    // off entirely on a monitor with no top bar.
    //
    // The fixture keeps compositor.focusedMonitor independently settable from testScreens, which
    // is the one property that makes this test able to tell the bug from the fix.
    function test_focus_moving_to_another_monitor_does_not_move_the_card() {
        view = createTemporaryObject(overview, tc)
        verify(view)
        screenA = createTemporaryObject(screenStub, tc, { name: "A" })
        screenB = createTemporaryObject(screenStub, tc, { name: "B" })
        view.testConfig.anchor = "bar"
        view.testPanel.width = 1920
        view.testPanel.height = 1080
        var monA = monitor("A", 0, 26)          // the picker's screen: a 26px bar
        var monB = monitor("B", 1080, 52)       // a 2x-scaled screen: a 52px bar
        view.compositor.monitors = { values: [monA, monB] }
        view.compositor.focusedMonitor = monA
        view.compositor.focusedWorkspace = { id: 1 }
        view.compositor.workspaces = { values: [
            { id: 1, monitor: monA, toplevels: { values: [] } },
            { id: 2, monitor: monB, toplevels: { values: [] } } ] }
        view.testScreens = [screenA, screenB]
        view.open()
        wait(120)
        compare(view.targetScreen, screenA, "precondition: opened on A")
        compare(view.reservedTop, 26, "precondition: A's bar")
        var y = view.testCard.y, h = view.testCard.height

        // Focus moves to B without the picker closing.
        view.compositor.focusedMonitor = monB
        view.monitorEpoch++
        wait(60)
        compare(view.reservedTop, 26, "still A's reservation, not B's 52")
        compare(view.testCard.y, y, "the card must not re-anchor")
        compare(view.testCard.height, h, "nor resize")

        // ...and a focused monitor with NO top bar must not drop bar mode either.
        view.compositor.monitors = { values: [monA, monitor("B", 1080, 0)] }
        view.compositor.focusedMonitor = view.compositor.monitors.values[1]
        view.monitorEpoch++
        wait(60)
        verify(view.barMode, "bar mode must survive focus landing on a bar-less monitor")
        compare(view.testCard.y, y, "and the card stays put")
    }
```

**What this distinguishes:** with `Hyprland.focusedMonitor` in the binding, `reservedTop` becomes
52 and the card jumps by 26px; the last block drops `barMode` and re-centres the card entirely.
With `monitorFor(targetScreen)` nothing moves. **The `monitorEpoch++` lines matter** — without
them the binding would not re-evaluate and the test would pass even against the buggy version, for
the wrong reason.

- [ ] **Step 2: Run it**

```bash
bash tests/ui/run.sh Dropdown::test_focus_moving_to_another_monitor_does_not_move_the_card
```

Expected: PASS, because Task 6 already implemented the fix. **Then prove the test can fail:**
temporarily change `reservedTop` to read `Hyprland.focusedMonitor` instead, re-run, confirm it
goes red, and revert. A regression test that has never been seen to fail is not yet a test.

- [ ] **Step 3: Update `ROADMAP.md`**

Item 12 currently records the bar drop-down as prototyped and parked, citing `fd6fbe4`. That
prototype is superseded — its three cover-up strips, centred attachment and scale entrance are all
gone. Repoint it at the spec and this plan, and mark it done.

- [ ] **Step 4: Full suite, clean**

```bash
mise run test
```

Expected: every tier green. Confirm the Lua chunk count is still **24** — this plan adds no
compositor chunks, so a change there means something unrelated crept in.

- [ ] **Step 5: Commit**

```bash
git add tests/ui/dropdown.qml ROADMAP.md
git commit -m "test(dropdown): pin the reservation to the picker's own screen"
```

---

## Notes for the implementer

- **Do not restyle Omarchy's bar.** This plan changes only how omascape presents itself. The bar
  belongs to the shell.
- **Check `apply()` in `OmascapeConfig.qml` by eye** (Task 5, Step 2). The fixture replaces that
  whole component, so no test in this plan can catch a missing assignment there.
- **Two tasks edit `tests/ui/prepare.py`** (4 and 9). After each, re-run the full suite and compare
  totals against the previous baseline. A fixture defect makes downstream assertions agree with it
  rather than fail.
- **Two things are live-check only**, because the fixture has no compositor and no `Color`
  singleton: that the card's colour genuinely **matches the bar**, and how the whole thing looks in
  both themes. Task 7 Step 3g covers fill *uniformity* under alpha, which is a different and
  weaker claim — do not let a pass there be read as the colour having been checked.
