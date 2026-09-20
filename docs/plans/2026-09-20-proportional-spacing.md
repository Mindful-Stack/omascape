# Proportional Spacing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or
> executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for
> tracking.

**Goal:** Make the gap between workspace tiles a fraction of the tile width, pad both edges of
the grid by the same gap, and let the tiles take the rest of the width, so the picker fills a
2560- or 3840-logical screen instead of centring a 1916 px row in it.

**Architecture:** One pure change inside `Logic.layout()` in `logic.js`: a second spacing model
switched on by a new `gapRatio` param, with the cell width fitted to whole pixels so the canvas is
never wider than the width it was given. The row spacing follows the same gap. `Overview.qml`
only changes its `params` object; the canvas still starts at x = 0, so every hit test and the
drag stay untouched. Without the param the pixel model runs byte for byte as before, which is
what keeps every existing layout fixture green.

**Tech Stack:** Quickshell 0.3.1 / QML (Qt 6.11 local, **Qt 6.9 on CI**), ES5-style
`logic.js`, `qmltestrunner` Tier 1 logic suites + the offscreen UI fixture.

Spec: `docs/specs/2026-09-20-proportional-spacing-design.md` (commit `7cdb4b2`). The numbers
below are the spec's numbers; the spec's table is the source of truth if the two ever differ.

---

## Conventions (every task)

- **Work in the `feat/proportional-spacing` worktree** at
  `/home/daniel/Source/omascape/.claude/worktrees/spacing`. The main checkout carries
  somebody's uncommitted edits to `Overview.qml` and two UI suites; do not touch it.
- **`logic.js` is ES5 by convention** (`lore/knowledge/languages/javascript/code-style.md`):
  `var`, no arrow functions, no template literals, no `let`/`const`. It references no QML type.
- **Never name an identifier `long`, `short`, `int`, `char`, `float`, `double`, `byte`,
  `boolean`, `final` or `native`** — Qt 6.9 rejects them in `.qml` files and 6.11 does not, so
  the mistake is invisible locally (`lore/knowledge/adrs/0004-qt-compatibility-floor.md`). Nothing
  in this plan uses one; keep it that way when renaming.
- **Every test carries a `Distinguishes:` line** naming the wrong implementation it would catch
  (`lore/knowledge/general/testing.md`). Prefer `compare` over `verify`; it prints both values.
- **Tier 1 logic tests are auto-discovered** (`tests/tst_*.qml`); this plan adds to the existing
  `tests/tst_layout.qml`, so nothing is registered. The UI suite edited here
  (`tests/ui/dropdown.qml`) is already in `tests/ui/run.sh`.
- **Commands.** Full suite: `mise run test` (about a minute). One Tier 1 test:
  `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_name`.
  One UI test: `bash tests/ui/run.sh Dropdown::test_name` — the positional argument is a
  **`TestCase::function` selector**; a bare suite name matches nothing and exits green, which
  looks like a pass. Run the whole `Layout` case with `-input tests/tst_layout.qml`.
- **A `SKIP:` is not a pass.** Read the runner's summary line, not just the exit code.
- **Conventional Commits, scoped `spacing`**, body says why, and the trailer
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- **Editing plugin source never hot reloads.** The by-eye sweep in Task 9 needs `mise run link`
  (which restarts the shell safely: `scripts/dev-link.sh` resolves the session's
  `HYPRLAND_INSTANCE_SIGNATURE` itself). Do not run a bare `omarchy restart shell`.

## The numbers every task pins

Production params after this plan: `maxCols 5, minCellW 140, maxCellW 800, gapRatio 0.08`. All
of these were recomputed with a scratch script while writing this plan; the sweep in Task 4
re-proves them in the suite.

| `availW` | `cols` | `cw` | `gap` | canvas `cols·cw + (cols+1)·gap` | fit steps |
|---|---|---|---|---|---|
| 2024 (laptop, bar mode) | 5 | 368 | 29 | 2014 | 1 |
| 2536 (external, bar mode) | 5 | 462 | 37 | 2532 | 0 |
| 3816 (4K at 1×) | 5 | 696 | 56 | 3816 | 0 |
| 1820 (laptop, centred card) | 5 | 331 | 26 | 1811 | 1 |
| 765 (column boundary, below) | 4 | 173 | 14 | 762 | 0 |
| 766 (column boundary, at) | 5 | 140 | 11 | 766 | 0 |
| 100 (`minCellW` binds) | 1 | 140 | 11 | 162 — wider than `availW`, allowed | 0 |
| 6000 (`maxCellW` binds) | 5 | 800 | 64 | 4384 | 0 |
| missing (absent, 0, −5, NaN) | 5 | 140 | 11 | 766 | 0 |

Row heights follow the monitor's aspect: the test fixture's `edp()` is 2048×1280 logical
(aspect 1.6), so `h = round(cw / 1.6)`: 230, 289, 435, 207 for the first four rows.

## File structure

| File | Responsibility | Tasks |
|---|---|---|
| `tests/tst_layout.qml` | Ratio-mode params, the `fiveOn` helper, every new Tier 1 test | 1–6 |
| `logic.js` `layout()` (lines 356–366, 405–407, 419–427, 438–450, 476) | The two spacing models, the fit step, edge padding, `rowGap` | 2–5 |
| `Overview.qml:296-297` params, `:2381-2386` Flickable comment | Turn the ratio on in production; rewrite the stale slack comment | 7 |
| `tests/ui/dropdown.qml:550-566` | Move the centring test to a width where the cap binds; add the 2048 fill test | 7 |
| `README.md:398-400` | Name `gapRatio` among the layout constants | 8 |
| `lore/knowledge/general/layout-and-sizing.md` | The ratio rule under "A maximum is a cap, not a floor" | 8 |
| `ROADMAP.md` | Item 16, done | 8 |

---

### Task 1: The pixel model is untouched by an invalid ratio (regression guard, green first)

This test is **green before any implementation exists**, by design. It is the guard for the
fallback the spec promises: `gapRatio` absent or invalid must leave `layout()`'s output identical
to today's. It will go red the moment Task 2 reads `P.gapRatio` without the type guard, which is
the plausible wrong implementation (`Number(undefined)` is NaN and poisons every width;
`Number("0.08")` is 0.08 and would let a string turn the mode on).

**Files:**
- Modify: `tests/tst_layout.qml` (after the `params` property, line 11)

- [ ] **Step 1: Add the ratio params and the `fiveOn` helper**

Insert after the closing `})` of `readonly property var params` (line 11):

```qml
    // The production spacing params after docs/specs/2026-09-20-proportional-spacing-design.md:
    // the gap is 8% of the cell, both edges carry one gap, and maxCellW is only a sanity cap.
    // `params` above stays on the pixel model on purpose — every fixture in this file pins
    // absolute x/y literals against it, and the ratio must not move them.
    readonly property var ratioParams: ({
        maxCols: 5, minCellW: 140, maxCellW: 800, cellInset: 3, cellSpacing: 4,
        rowSpacing: 8, headerH: 22, groupInset: 6, minTileW: 8, minTileH: 6, slotGapTolerance: 24,
        gapRatio: 0.08
    })

    // One monitor (eDP-1, aspect 1.6), five empty workspaces, no windows: the smallest input
    // that exercises every column. `availW` may be anything, including undefined.
    function fiveOn(availW, p) {
        var wss = []
        for (var i = 1; i <= 5; i++)
            wss.push({ id: i, monitorName: "eDP-1", focused: i === 1, occupied: false })
        return Logic.layout({ monitors: [edp()], workspaces: wss, windows: [],
                              focusedMonitorName: "eDP-1", availW: availW,
                              params: p === undefined ? ratioParams : p })
    }

    function withRatio(base, value) {
        var p = {}
        for (var k in base) p[k] = base[k]
        p.gapRatio = value
        return p
    }

    // Every box and group finite — the NaN floor (lore/knowledge/general/layout-and-sizing.md).
    function assertFinite(r, label) {
        verify(isFinite(r.canvasSize.w) && isFinite(r.canvasSize.h), label + ": canvas " + JSON.stringify(r.canvasSize))
        for (var i = 0; i < r.boxes.length; i++) {
            var b = r.boxes[i]
            verify(isFinite(b.x) && isFinite(b.y) && isFinite(b.w) && isFinite(b.h) && b.w > 0 && b.h > 0,
                   label + ": box " + b.workspaceId + " " + JSON.stringify([b.x, b.y, b.w, b.h]))
        }
        for (var g = 0; g < r.groups.length; g++) {
            var gr = r.groups[g]
            verify(isFinite(gr.x) && isFinite(gr.y) && isFinite(gr.w) && isFinite(gr.h),
                   label + ": group " + gr.monitorName + " " + JSON.stringify([gr.x, gr.y, gr.w, gr.h]))
        }
    }
```

Property these helpers must have: `fiveOn(w)` with no second argument uses `ratioParams`, and
`fiveOn(w, params)` uses the file's pixel params — Task 1's test depends on the second form and
every later task on the first.

- [ ] **Step 2: Write the identity test**

Append inside the `TestCase`, right after the helpers:

```qml
    // ---- proportional spacing (docs/specs/2026-09-20-proportional-spacing-design.md) ----

    // Distinguishes: an implementation that reads `gapRatio` unguarded — Number(undefined) is
    // NaN and would poison every width — or one that lets 0, a negative, Infinity, a numeric
    // STRING or `true` switch the ratio model on. Green before the feature exists, on purpose:
    // it is the regression guard for the pixel model every other fixture in this file pins.
    function test_an_invalid_ratio_leaves_the_pixel_model_untouched() {
        var base = JSON.stringify(fiveOn(1632, params))
        var invalid = [undefined, null, 0, -0.1, NaN, Infinity, -Infinity, "0.08", true, {}]
        for (var i = 0; i < invalid.length; i++) {
            var out = JSON.stringify(fiveOn(1632, withRatio(params, invalid[i])))
            compare(out, base, "gapRatio = " + String(invalid[i]) + " must not change the layout")
        }
    }
```

Property: `base` is computed from `params`, which has **no** `gapRatio` key at all, and the
comparison is the whole serialised layout, so any field the ratio path touches (box `x`,
`canvasSize`, group `x`, row `y`) shows up.

- [ ] **Step 3: Run it — it must pass now**

```
cd /home/daniel/Source/omascape/.claude/worktrees/spacing
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_an_invalid_ratio_leaves_the_pixel_model_untouched
```

Expected: `PASS`. If it fails here, the helpers are wrong (most likely `fiveOn` ignoring its
second argument), not the code under test — fix the helper.

- [ ] **Step 4: Commit**

```bash
git add tests/tst_layout.qml
git commit -m "test(spacing): the pixel model is untouched by an invalid gapRatio

Green before the feature: this is the guard for the fallback the spec promises,
and it goes red on the plausible wrong implementation — reading gapRatio
without a type guard.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Ratio mode fits the row to whole pixels (the table)

**Files:**
- Modify: `tests/tst_layout.qml`
- Modify: `logic.js:356-366` (the `gap` / `availW` / `cols` / `cw` block) and `:405-407`
  (box `x`), `:476` (the return)

- [ ] **Step 1: Write the failing test**

Append after Task 1's test:

```qml
    // Distinguishes: the real-valued formula the first spec draft carried, which put the 2024
    // and 1820 rows 1-2 px OVER availW (found in review, 2026-09-20), and a fit step that shrinks
    // when it need not (2536 and 3816 take no step and must not lose a pixel).
    function test_ratio_mode_fits_the_row_to_whole_pixels() {
        var rows = [ { availW: 2024, cw: 368, gap: 29, canvas: 2014, h: 230 },   // one fit step
                     { availW: 2536, cw: 462, gap: 37, canvas: 2532, h: 289 },
                     { availW: 3816, cw: 696, gap: 56, canvas: 3816, h: 435 },
                     { availW: 1820, cw: 331, gap: 26, canvas: 1811, h: 207 } ]  // one fit step
        for (var i = 0; i < rows.length; i++) {
            var e = rows[i], r = fiveOn(e.availW), b1 = boxById(r, 1), b2 = boxById(r, 2), b5 = boxById(r, 5)
            var at = "availW " + e.availW + ": "
            compare(b1.w, e.cw, at + "cell width")
            compare(b1.h, e.h, at + "cell height follows the monitor's 1.6 aspect")
            compare(b1.x, e.gap, at + "the first box starts one gap in from the edge")
            compare(b2.x, e.gap + e.cw + e.gap, at + "the second column is one cell and one gap on")
            compare(b5.x + b5.w + e.gap, e.canvas, at + "the last box ends one gap short of the canvas edge")
            compare(r.canvasSize.w, e.canvas, at + "canvas width")
            verify(r.canvasSize.w <= e.availW, at + "the canvas must never be wider than availW")
            assertFinite(r, at)
        }
    }
```

Property: the assertions on `b5` and `canvasSize.w` together pin **both** edges, so an
implementation that pads the left edge only, or pads the canvas without moving the boxes, fails.

- [ ] **Step 2: Run it to verify it fails**

```
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_ratio_mode_fits_the_row_to_whole_pixels
```

Expected: `FAIL` on the very first `compare`: `Actual (b1.w): 380`, `Expected (e.cw): 368` —
the pixel model ignores the ratio and caps at the old 380. (`ratioParams` sets `maxCellW: 800`,
so if the actual is 401 the pixel model is honouring the raised cap; still a fail, still the
right reason.)

- [ ] **Step 3: Implement the two spacing models in `layout()`**

Replace `logic.js` lines 356–366 — from the comment `// adaptive cell size — maxCols is a CAP,
not a floor` through the `var cw = …` statement — with:

```js
    // adaptive cell size — maxCols is a CAP, not a floor
    //
    // Two spacing models (docs/specs/2026-09-20-proportional-spacing-design.md). With a valid
    // `gapRatio` the gap is that fraction of the cell width, both edges of the canvas carry one
    // gap, and the cell takes what is left. Without one — absent, non-numeric, zero, negative
    // or infinite — the pixel `cellSpacing` / `rowSpacing` apply and the edges are 0: exactly
    // the geometry that existed before the ratio did, so every fixture written against it
    // still holds. `typeof` and not Number(): a numeric string must not switch the mode on.
    var ratio = P.gapRatio
    var proportional = typeof ratio === "number" && isFinite(ratio) && ratio > 0
    // The gap the narrowest legal cell would get — the one the column count is decided with.
    var gapMin = proportional ? Math.round(P.minCellW * ratio) : P.cellSpacing
    var edges = proportional ? 2 : 0                       // outer gaps a row carries
    // safe default when availW is missing/invalid: maxCols cells at minCellW with every gap
    // the row carries included — the (maxCols-1) between them plus the outer ones — so cols
    // resolves to maxCols and cw clamps to exactly minCellW: finite, valid geometry instead
    // of NaN.
    var availW = (typeof input.availW === "number" && input.availW > 0)
        ? input.availW - 2 * inset
        : (P.maxCols * P.minCellW + (P.maxCols - 1 + edges) * gapMin)
    // The most columns of minimum cells that fit, outer gaps included: the largest n with
    // n * minCellW + (n - 1 + edges) * gapMin <= availW.
    var cols = Math.max(1, Math.min(P.maxCols,
        Math.floor((availW - (edges - 1) * gapMin) / (P.minCellW + gapMin))))
    var cw, gap
    if (proportional) {
        // A row of n cells at width w is w * (n + (n+1) * ratio) wide.
        cw = Math.max(P.minCellW, Math.min(P.maxCellW,
            Math.floor(availW / (cols + (cols + 1) * ratio))))
        gap = Math.round(cw * ratio)
        // Fit to whole pixels. The real-valued estimate can overshoot availW by up to
        // (cols+1)/2 px from the gap's rounding, and one step of cw removes at least cols px,
        // so this runs at most once (the spec swept every width 162..8000). minCellW binding
        // is the only way a row is ever wider than availW — the pixel model overflows there
        // too, and the Flickable scrolls it.
        while (cols * cw + (cols + 1) * gap > availW && cw > P.minCellW) {
            cw -= 1
            gap = Math.round(cw * ratio)
        }
    } else {
        gap = gapMin
        cw = Math.max(P.minCellW, Math.min(P.maxCellW,
            Math.floor((availW - (cols - 1) * gap) / cols)))
    }
    // What the canvas carries on each side, and the spacing between rows of cells: the gap
    // itself in ratio mode, the old constants otherwise.
    var edge = proportional ? gap : 0
    var rowGap = proportional ? gap : P.rowSpacing
```

Property this must keep: with `proportional` false, `gapMin === P.cellSpacing`, `edges === 0`,
and the three derived expressions reduce **exactly** to the lines they replaced —
`floor((availW + gap) / (minCellW + gap))` for `cols`, `maxCols*minCellW + (maxCols-1)*gap` for
the fallback, `edge === 0` and `rowGap === P.rowSpacing`. Task 1's identity test is what proves
it; if Task 1 goes red after this step, one of those reductions is wrong.

Then change the box `x` in the group loop (line 405–407, the `var box = {` literal):

```js
                            special: "", x: edge + inset + c * (cw + gap), y: y, w: cw, h: gch,
```

and the group literal at line 398 (`var group = { monitorName: name, special: "", x: 0,`) to
`x: edge,`.

And the return (line 476):

```js
    return { canvasSize: { w: canvasW + 2 * edge, h: y }, boxes: boxes, tiles: tiles,
```

`canvasW` stays the width of the widest group *without* edges throughout the function — the
scratchpad row (Task 5) centres itself against that content width — and only the reported
canvas size adds the two edges.

- [ ] **Step 4: Run the new test and the guard**

```
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_ratio_mode_fits_the_row_to_whole_pixels
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_an_invalid_ratio_leaves_the_pixel_model_untouched
```

Expected: both `PASS`. Then the whole file, because every other fixture pins pixel-model
literals and must not have moved:

```
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/tst_layout.qml
```

Expected: `Totals: N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "feat(spacing): the gap is a fraction of the cell, fitted to whole pixels

With gapRatio set the gap is that fraction of the cell width, both edges carry
one gap, and the cell takes what is left; a one-step fit keeps the canvas
inside availW where the real-valued formula overshot by 1-2 px. Without the
param the pixel model runs unchanged.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Column selection and the missing-width fallback

**Files:**
- Modify: `tests/tst_layout.qml`

Task 2's implementation already computes these; this task pins the boundaries the spec calls
out, because they are where the first draft was wrong.

- [ ] **Step 1: Write the tests**

Append after Task 2's test:

```qml
    // Boxes sharing the first row's y ARE the first row; with five workspaces that is `cols`
    // whenever cols <= 5.
    function firstRowCount(r) {
        var y0 = r.boxes[0].y, n = 0
        for (var i = 0; i < r.boxes.length; i++) if (r.boxes[i].y === y0) n++
        return n
    }

    // Distinguishes: a column test that forgets the outer gaps — `(availW + gapMin) /
    // (minCellW + gapMin)`, the pixel formula — which gives five columns at 765 and then a row
    // 766 px wide in a 765 px canvas. The integer rule is the largest n with
    // n*140 + (n+1)*11 <= availW: 766 is the first width that seats five.
    function test_column_count_counts_both_outer_gaps() {
        var below = fiveOn(765), at = fiveOn(766)
        compare(firstRowCount(below), 4, "765: four columns")
        compare(boxById(below, 1).w, 173, "765: cells widen to fill four columns")
        compare(below.canvasSize.w, 762, "765: 4*173 + 5*14")
        compare(firstRowCount(at), 5, "766: five columns of the minimum cell")
        compare(boxById(at, 1).w, 140, "766: minCellW")
        compare(at.canvasSize.w, 766, "766: 5*140 + 6*11, exactly the width")
        assertFinite(below, "765"); assertFinite(at, "766")
    }

    // Distinguishes: a fallback that omits the outer gaps (744, the first draft's) — step 2 then
    // resolves FOUR columns at 169 wide instead of five at the minimum — and a fallback that
    // takes 0, a negative or NaN as a width. The output must be the same for every shape of
    // "no width", and it must be the five-column minimum grid the pixel model also falls to.
    function test_a_missing_width_falls_back_to_five_minimum_columns() {
        var shapes = [undefined, 0, -5, NaN, null, "2024"]
        for (var i = 0; i < shapes.length; i++) {
            var r = fiveOn(shapes[i]), at = "availW " + String(shapes[i]) + ": "
            compare(firstRowCount(r), 5, at + "five columns")
            compare(boxById(r, 1).w, 140, at + "minCellW")
            compare(boxById(r, 1).x, 11, at + "one minimum gap in")
            compare(r.canvasSize.w, 766, at + "5*140 + 6*11")
            assertFinite(r, at)
        }
    }

    // Distinguishes: a column floor that lets cols reach 0 (a division by zero in cw) and a fit
    // step that shrinks BELOW minCellW to satisfy a width nothing legal fits — at 100 the row
    // is 162 wide and that overflow is the documented behaviour, not a bug to fit away.
    function test_a_width_below_one_minimum_cell_still_lays_out_one_column() {
        var r = fiveOn(100)
        compare(firstRowCount(r), 1, "one column")
        compare(boxById(r, 1).w, 140, "the cell does not go below minCellW")
        compare(boxById(r, 1).x, 11, "one gap in")
        compare(r.canvasSize.w, 162, "140 + 2*11: wider than the 100 it was given, by design")
        compare(r.boxes.length, 5, "all five workspaces are laid out, one per row")
        assertFinite(r, "100")
    }
```

Property: `firstRowCount` counts the boxes on the first row rather than reading the
`cell.cols` field `layout()` also returns, so the column count is checked against where the
boxes actually landed, not against what the implementation says it decided. (`r.cell.cols`
exists and may be compared to it as a cross-check; it must not replace it.)

- [ ] **Step 2: Run them**

```
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_column_count_counts_both_outer_gaps
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_a_missing_width_falls_back_to_five_minimum_columns
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_a_width_below_one_minimum_cell_still_lays_out_one_column
```

Expected: all three `PASS` against Task 2's implementation. If `test_column_count…` fails at
765 with five columns, the `(edges - 1) * gapMin` term has the wrong sign. If the fallback test
fails with 744, the fallback's `(P.maxCols - 1 + edges)` lost `edges`.

These are green-on-arrival because Task 2 implemented the integer rule in one piece; they exist
so that a later "simplification" of that block back to the real-valued form cannot pass.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_layout.qml
git commit -m "test(spacing): pin the column boundary and the missing-width fallback

Both are where the first spec draft was wrong: a column test without the outer
gaps seats five columns one pixel too early, and a fallback without them loses
a column to the integer rule.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: The width sweep — never wider, never more than `2·cols` narrower

**Files:**
- Modify: `tests/tst_layout.qml`

- [ ] **Step 1: Write the property test**

Append after Task 3's tests:

```qml
    // Distinguishes: a missing fit step (some width in 162..4384 overflows — the first draft
    // did at 2024 and 1820) and an over-eager one (a canvas more than 2*cols px short of
    // the width it was given, the most a single strict-condition step can leave behind; widths
    // that take no step leave less). Stated once as the property, for every integer width up to
    // 4384, the last width before maxCellW binds (from 4385 the cell pins at 800 and the canvas
    // freezes at 5*800 + 6*64 = 4384), rather than for the widths the table happens to name.
    function test_ratio_mode_never_overflows_and_never_over_shrinks() {
        var worstSlack = 0
        for (var w = 162; w <= 4384; w++) {
            var r = fiveOn(w), cols = firstRowCount(r), canvas = r.canvasSize.w
            if (!isFinite(canvas)) fail("availW " + w + ": canvas is not finite")
            if (canvas > w)
                fail("availW " + w + ": canvas " + canvas + " overflows")
            if (canvas < w - 2 * cols)
                fail("availW " + w + ": canvas " + canvas + " is " + (w - canvas) + " short with " + cols + " columns")
            if (w - canvas > worstSlack) worstSlack = w - canvas
        }
        compare(worstSlack, 10, "five columns leave at most 10 px, at availW 791 (cols 5, cw 143, gap 11, canvas 781)")
    }
```

Property: `fail(...)` inside the loop, not `compare`, so the first offending width is named
and the loop stops; 4223 `compare` calls would drown the report. The lower bound uses the row's
**own** column count, since below 766 the sweep passes through 1, 2, 3 and 4 columns.

Cost: 4223 layouts of five boxes each — expect this single test to take one to two seconds.

- [ ] **Step 2: Run it**

```
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_ratio_mode_never_overflows_and_never_over_shrinks
```

Expected: `PASS`. To see it distinguish, temporarily comment out the `while` loop in
`layout()` and rerun: expected `FAIL` at `availW 173` or thereabouts with "overflows". Restore
the loop before committing.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_layout.qml
git commit -m "test(spacing): sweep every width for overflow and over-shrink

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Row spacing follows the gap, and the canvas edge frames every group

**Files:**
- Modify: `tests/tst_layout.qml`
- Modify: `logic.js:419-427` (the two `P.rowSpacing` reads in the group loop), `:438`
  (the scratchpad's `P.rowSpacing`), `:439-450` (the scratchpad group and box `x`)

- [ ] **Step 1: Write the failing test**

Append after Task 4's test:

```qml
    // Two monitors (so the group inset and header band are on), six workspaces on the first
    // so it wraps into a second sub-row, and the scratchpad shown: every vertical seam the
    // layout has. availW 2024 less the 2*6 inset is 2012 — cw 367, gap 29, no fit step.
    function multiWithScratchpad() {
        var wss = []
        for (var i = 1; i <= 6; i++) wss.push({ id: i, monitorName: "eDP-1", focused: i === 1, occupied: false })
        for (var j = 7; j <= 8; j++) wss.push({ id: j, monitorName: "HDMI-A-1", focused: false, occupied: false })
        wss.push({ id: Logic.SCRATCHPAD_ID, monitorName: "eDP-1", special: "scratchpad",
                   focused: false, occupied: true })
        return Logic.layout({ monitors: [edp(), hdmi()], workspaces: wss, windows: [],
                              focusedMonitorName: "eDP-1", availW: 2024, params: ratioParams })
    }

    // Distinguishes: an implementation that widened the columns and left every row seam on
    // the 8 px `rowSpacing` — a 5x2 grid 29 px apart sideways and 8 px apart downwards — at any
    // of the three seams: between sub-rows, between monitor groups, and above the scratchpad.
    // The wrong values are 265, 529 and 798; each is 21 short of the right one.
    function test_every_row_seam_is_the_ratio_gap() {
        var r = multiWithScratchpad()
        compare(boxById(r, 1).w, 367, "precondition: 2012 / 5.48 floors to 367")
        compare(boxById(r, 1).h, 229, "precondition: eDP row height")
        compare(boxById(r, 7).h, 206, "precondition: HDMI row height (16:9)")
        // group 0: inset 6 + header 22 = 28, first row at 28, second sub-row after 229 + gap 29
        compare(boxById(r, 1).y, 28, "first row sits under the chip band")
        compare(boxById(r, 6).y, 28 + 229 + 29, "the sub-row seam is the gap, not rowSpacing")
        // group 0 ends at 28 + 229 + 29 + 229 + inset 6 = 521; group 1 starts one gap later
        compare(r.groups[0].h, 521, "group 0 height")
        compare(r.groups[1].y, 521 + 29, "the monitor-group seam is the gap")
        // group 1: 28 in, one 206 row, inset 6 -> ends at 550 + 28 + 206 + 6 = 790
        compare(r.groups[1].y + r.groups[1].h, 790, "group 1 bottom")
        compare(r.groups[2].special, "scratchpad", "precondition: the third group is the scratchpad")
        compare(r.groups[2].y, 790 + 29, "the scratchpad seam is the gap")
        assertFinite(r, "multi")
    }

    // Distinguishes: an edge applied to the boxes but not the group backdrops (a backdrop
    // hugging x = 0 while its cells start 29 px in), or to the monitor groups but not the
    // scratchpad row, or a canvas width that forgot to add the edges back. Every group starts
    // one gap in; the canvas is the widest group plus two gaps; the scratchpad cell is centred
    // on that canvas.
    function test_the_edge_frames_every_group_and_the_canvas_reports_it() {
        var r = multiWithScratchpad(), gap = 29, inset = 6
        for (var g = 0; g < r.groups.length; g++)
            compare(r.groups[g].x, gap, "group " + g + " starts one gap in")
        compare(boxById(r, 1).x, gap + inset, "the first cell sits inside the edge and the inset")
        compare(boxById(r, 7).x, gap + inset, "so does the second monitor's")
        var widest = 5 * 367 + 4 * gap + 2 * inset              // 1963
        compare(r.groups[0].w, widest, "group width excludes the edge")
        compare(r.canvasSize.w, widest + 2 * gap, "the canvas adds one gap each side: 2021")
        verify(r.canvasSize.w <= 2024, "and still fits the width it was given")
        var s = boxById(r, Logic.SCRATCHPAD_ID)
        compare(s.x + s.w / 2, r.canvasSize.w / 2, "the scratchpad cell is centred on the canvas")
        compare(r.groups[2].w, widest, "the scratchpad row spans the widest group")
    }
```

Property: the seam values are derived in the comments from the heights the test first pins as
preconditions, so a reader can recompute them; and the *wrong* values (21 px short) are named
in the `Distinguishes:` line so the failure is recognisable.

- [ ] **Step 2: Run to verify it fails**

```
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_every_row_seam_is_the_ratio_gap
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_the_edge_frames_every_group_and_the_canvas_reports_it
```

Expected: the first fails at the sub-row seam: `Actual: 265, Expected: 286`. The second fails
on the scratchpad group's `x` (Task 2 set `edge` on monitor groups but the scratchpad literal
still says `x: 0`) — `Actual: 0, Expected: 29` — or on the scratchpad centring.

- [ ] **Step 3: Implement**

In `logic.js`, the group loop (the three `P.rowSpacing` reads become `rowGap`):

```js
            if (s + cols < wss.length) y += rowGap              // between sub-rows of one group
```
```js
        if (r < order.length - 1) y += rowGap                   // between monitor groups
```

The scratchpad block (line 438 onwards):

```js
        if (groups.length) y += rowGap
        var sgroup = { monitorName: sws.monitorName, special: sws.special, x: edge, y: y, w: 0, h: 0,
                       inset: inset, headerH: P.headerH, focused: false }
```

and its box `x` (line 447):

```js
                     special: sws.special, x: edge + inset + Math.round((rowW - 2 * inset - cw) / 2), y: y, w: cw,
```

`rowW` and `canvasW` on that path stay as they are: both are content widths without the edge,
which is what makes the centring arithmetic and the return's `canvasW + 2 * edge` agree.

- [ ] **Step 4: Run the two tests, then the whole `Layout` case**

```
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/tst_layout.qml
```

Expected: `0 failed`. The pre-existing scratchpad tests (around lines 880–960) pin the pixel
model's centring and must not have moved — `edge` is 0 there.

- [ ] **Step 5: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "feat(spacing): row seams and the scratchpad row follow the ratio gap

A 5x2 grid 29 px apart sideways and 8 px apart downwards reads wrong; every
vertical seam takes the same gap, and the scratchpad row sits inside the same
edge as the monitor groups.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `maxCellW` is a sanity cap

**Files:**
- Modify: `tests/tst_layout.qml`

- [ ] **Step 1: Write the test**

```qml
    // Distinguishes: a cap applied before the fit (fit would then "repair" the slack and shrink
    // the cell below 800 for no reason) or a cap that stopped binding altogether when the
    // formula changed. At 6000 the cell stops at 800, the gap at 64, and the 1616 px left over
    // is slack for the Flickable to centre — the one path that still produces real slack.
    function test_max_cell_width_caps_the_cell_and_leaves_the_rest_as_slack() {
        var r = fiveOn(6000)
        compare(boxById(r, 1).w, 800, "capped")
        compare(boxById(r, 1).x, 64, "gap is 8% of the CAPPED width")
        compare(r.canvasSize.w, 5 * 800 + 6 * 64, "4384: the canvas does not stretch to fill")
        verify(r.canvasSize.w < 6000, "so the width it was given is not consumed")
        assertFinite(r, "6000")
    }
```

- [ ] **Step 2: Run it**

```
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_max_cell_width_caps_the_cell_and_leaves_the_rest_as_slack
```

Expected: `PASS` (Task 2's clamp order is cap-then-fit, and 4384 ≤ 6000 means the loop never
runs).

- [ ] **Step 3: Commit**

```bash
git add tests/tst_layout.qml
git commit -m "test(spacing): maxCellW binds as a sanity cap and leaves slack

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Turn it on in production, and the offscreen proof

**Files:**
- Modify: `Overview.qml:296-297` (params), `:2381-2386` (the Flickable comment)
- Modify: `tests/ui/dropdown.qml:550-566`

- [ ] **Step 1: Write the failing UI test and move the centring test**

In `tests/ui/dropdown.qml`, replace the comment and function
`test_the_grid_is_centred_when_narrower_than_the_card` (lines 550–566) with:

```qml
    // The grid must sit in the middle of a full-width card, not hug its left edge. layout()
    // places boxes from x = 0 and the canvas is exactly the grid's width, so wherever the
    // canvas is narrower than the card the remainder is pure slack. Since proportional
    // spacing (docs/specs/2026-09-20-proportional-spacing-design.md) the cells fill the width
    // and slack only survives where maxCellW binds: 6000 logical is past that (cells 800, gap
    // 64, canvas 4384), which is why the width moved from the 2048 that first reported this.
    // Distinguishes: a Flickable pinned at x = card.pad with the slack dumped on the right —
    // the original bug — on the one path that still produces slack.
    function test_the_grid_is_centred_when_narrower_than_the_card() {
        seed(26, 10, "bar", 6000)
        var avail = view.testCard.width - view.testCard.pad * 2
        var slack = avail - view.testFlick.width
        verify(slack > 20,
               "precondition: this panel must actually leave slack, got " + slack)
        compare(view.testFlick.x, view.testCard.pad + Math.round(slack / 2),
                "the slack must be split evenly, not left on one side")
        // ...and the grid still fits, i.e. centring did not shrink the viewport below content.
        verify(view.testFlick.contentWidth <= view.testFlick.width,
               "content " + view.testFlick.contentWidth + " must fit " + view.testFlick.width)
    }

    // The real case: the author's 2048-logical laptop in bar mode. Before proportional spacing
    // the cells capped at 380 and 108 px of card sat empty; now the canvas fills the card to
    // within the fit step's remainder and the first cell starts one gap in.
    // Distinguishes: production params still on the pixel model (canvas 1916, first box at
    // x = 0) — the whole feature switched off by a params object nobody updated — and a
    // gapRatio wired into the params but read by nothing.
    function test_the_grid_fills_a_laptop_width_with_a_gap_at_each_edge() {
        seed(26, 10, "bar", 2048)
        var avail = view.testCard.width - view.testCard.pad * 2
        compare(avail, 2024, "precondition: bar mode gives the canvas the panel minus the pad")
        var canvas = view.testFlick.contentWidth
        verify(canvas <= avail, "the canvas fits: " + canvas + " in " + avail)
        verify(avail - canvas <= 10, "five columns leave at most 2*5 px, left " + (avail - canvas))
        var first = view.boxes[0]
        verify(first.x > 0, "the first cell does not touch the canvas edge")
        compare(first.x, Math.round(first.w * view.params.gapRatio),
                "the edge is one gap, and the gap is gapRatio of the cell")
        compare(first.w, 368, "the spec's laptop row: cell 368")
        compare(first.x, 29, "gap 29")
    }
```

Property: the second test reads `view.params.gapRatio` from production, so it fails if the
key is missing (`Math.round(NaN)` is NaN and `compare(29, NaN)` fails) rather than passing
against a value the test supplied.

- [ ] **Step 2: Run both to verify they fail for the right reasons**

```
bash tests/ui/run.sh Dropdown::test_the_grid_is_centred_when_narrower_than_the_card
bash tests/ui/run.sh Dropdown::test_the_grid_fills_a_laptop_width_with_a_gap_at_each_edge
```

Expected: the first **passes** already (at 6000 the old 380 cap leaves even more slack, and the
centring code is on `main`); it is being moved, not written. The second fails at
`verify(avail - canvas <= 10)` with `left 108`, or at `first.x > 0` — the production params are
still the pixel model.

- [ ] **Step 3: Update the production params and the stale comment**

`Overview.qml:294-297`, the params object, becomes:

```qml
    // headerH is the chip band per monitor group; logic.js lays it out only when more than
    // one monitor has workspaces (see Logic.layout), so a single monitor gets no band.
    // gapRatio makes the gap 8% of the cell and pads each edge by one gap, with the cell taking
    // what is left (docs/specs/2026-09-20-proportional-spacing-design.md); cellSpacing and
    // rowSpacing are the fixed-pixel fallback layout() uses when gapRatio is absent, and
    // maxCellW is a sanity cap that binds nowhere below a 4400-logical canvas.
    readonly property var params: ({
        maxCols: 5, minCellW: 140, maxCellW: 800, cellInset: 3, cellSpacing: 4,
        rowSpacing: 8, headerH: 22, groupInset: 6, minTileW: 8, minTileH: 6, slotGapTolerance: 24,
        gapRatio: 0.08
    })
```

The Flickable comment (`Overview.qml:2381-2386`, from `// Centred on the card when the grid is
narrower…` through `…and the grid would hug the left edge.`) becomes:

```qml
                // Centred on the card when the grid is narrower than the room available.
                // layout() lays boxes out from x = 0 and the canvas is exactly the grid's
                // width, edges included. In centred mode the card shrinks to the grid, so there
                // is never any slack; a full-width bar-mode card leaves the fit step's few
                // pixels (at most 2*cols), and real slack only where maxCellW binds — a
                // canvas past 4384 logical. Either way the remainder must not sit on one side.
```

The paragraph below it (`It is the FLICKABLE that moves…`) stays exactly as it is: the invariant
it states is the reason the edge lives in `layout()`.

- [ ] **Step 4: Run the UI suite and the whole Tier 1**

```
bash tests/ui/run.sh Dropdown
mise run test
```

Expected: `Dropdown` `0 failed`; `mise run test` ends with every runner green and no `SKIP:`
in its output. Watch `tests/ui/monitors.qml`, `peek.qml` and `actions.qml` in particular: they
drive real geometry through the production params, and anything that pinned an absolute box
`x` or `contentWidth` will now be off by the edge or the new cell width. Fix such a test by
deriving the expectation from `view.boxes` / `view.params` rather than restoring the old literal
— the literal encoded the pixel model.

- [ ] **Step 5: Commit**

```bash
git add Overview.qml tests/ui/dropdown.qml
git commit -m "feat(spacing): turn the ratio on — gap 8% of the cell, edges to match, cap 800

The bar-mode centring test moves to a width where the cap binds, the only
path that still leaves slack; a new test pins the laptop row the feature was
asked for.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: The record — README, knowledge base, roadmap

**Files:**
- Modify: `README.md:398-400`
- Modify: `lore/knowledge/general/layout-and-sizing.md` (the "A maximum is a cap, not a floor"
  section)
- Modify: `ROADMAP.md` (after item 15)

- [ ] **Step 1: README**

The sentence at `README.md:398-400`

> Layout constants live in the `params` object near the top of `Overview.qml` (cell size caps,
> `cellInset`, `cellSpacing`, `rowSpacing`, the `minTileW`/`minTileH` clamps).

becomes:

> Layout constants live in the `params` object near the top of `Overview.qml`: `gapRatio`
> (the gap between tiles as a fraction of the tile width, also the padding at each edge —
> tiles take whatever width is left), the cell size caps, `cellInset`, the
> `minTileW`/`minTileH` clamps, and the fixed-pixel `cellSpacing`/`rowSpacing` that apply only
> when `gapRatio` is removed.

- [ ] **Step 2: Knowledge base**

In `lore/knowledge/general/layout-and-sizing.md`, after the paragraph that ends
`…which is exactly why the margin change above shrank the author's cells from 380.`, add:

```markdown
Since 2026-09-20 the cell is no longer the thing that is capped in practice. With `gapRatio`
set (0.08 in production) the gap is that fraction of the cell width, both edges of the canvas
carry one gap, and the cell takes what is left — fitted to whole pixels so the canvas is never
wider than `availW`:

```js
cw = clamp(floor(availW / (cols + (cols + 1) * ratio)), minCellW, maxCellW)
gap = round(cw * ratio)
while (cols * cw + (cols + 1) * gap > availW && cw > minCellW) { cw--; gap = round(cw * ratio) }
```

`maxCellW` is 800 now and binds nowhere below a 4384-logical canvas; it is a sanity cap. The
row spacing between sub-rows, monitor groups and the scratchpad follows the same gap. Without
`gapRatio` — absent, or anything but a positive finite number — the pixel `cellSpacing` and
`rowSpacing` apply exactly as before, which is the fallback rule below applied to a new input.
The derivation, the fit step's proof and the measured table are in
`docs/specs/2026-09-20-proportional-spacing-design.md`.
```

Then, from the worktree root, through the `make` target (the bare `node lore/_tools/cli.js`
invocation resolves to a nonexistent directory, reads nothing and exits 0, per `CLAUDE.md`):

```
cd /home/daniel/Source/omascape/.claude/worktrees/spacing && make validate
```

Expected: the validator reports the frontmatter, wikilinks and orphan checks passing with no
new warnings. The node's frontmatter is untouched, so the only way this fails is a stray
`[[…]]` in the new paragraph — there is none.

- [ ] **Step 3: ROADMAP**

After item 15 in `ROADMAP.md`, add:

```markdown
### 16. ~~Proportional spacing~~ ✅ done (2026-09-20)
The gap between tiles is 8% of the tile width, each edge carries one gap, and the tiles take
the rest — so a 2560- or 3840-logical screen fills instead of centring a 1916 px row with 4 px
gaps in it. `maxCellW` is a sanity cap at 800 now. Cells shrink 380 → 368 on a 2048 laptop in
bar mode to pay for the gap. See `docs/specs/2026-09-20-proportional-spacing-design.md`.
**Unswept by eye** as of this entry: the 0.08 ratio, and whether the top padding should
follow the gap.
```

- [ ] **Step 4: Commit**

```bash
git add README.md lore/knowledge/general/layout-and-sizing.md ROADMAP.md
git commit -m "docs(spacing): README, the layout standard and the roadmap carry the ratio rule

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Verify on hardware, then the PR

**Files:** none edited by this task unless the sweep moves the ratio.

- [ ] **Step 1: Full Tier 1, read the whole output**

```
mise run test 2>&1 | tail -40
```

Expected: every runner's totals line shows `0 failed`, and the output contains no `SKIP:`.
Paste the totals lines into the PR description.

- [ ] **Step 2: Link and look**

```
mise run link
```

This restarts the shell through `scripts/dev-link.sh`, which resolves the session's
`HYPRLAND_INSTANCE_SIGNATURE` itself. Then open the picker on **both** screens (the laptop
panel and the external), in bar mode and, after toggling `anchor` off in the settings panel,
centred. What to look at, per the spec's sweep note:

- the laptop, bar mode: tiles 368 wide with 29 px between them and at each edge, none
  touching the card;
- the external: tiles 462 wide, 37 px gaps, the card full to its edges;
- with both monitors connected, the seams between sub-rows and between the two monitor
  groups are the same width as the gaps between columns;
- whether 0.08 feels right, and whether the 12 px top padding now reads as too tight against
  29–37 px side padding. Both are one-line changes in the params object, and the second is
  explicitly out of the spec's scope — note it in the PR rather than doing it.

If the ratio moves, update `gapRatio` in `Overview.qml`, the numbers in
`test_the_grid_fills_a_laptop_width_with_a_gap_at_each_edge` (it pins 368 / 29 — recompute with
the fit rule), the README's parenthetical, the KB node's "(0.08 in production)", the ROADMAP
entry, and the spec's table, in one `fix(spacing):` commit that says what the eye found.

- [ ] **Step 3: Unlink**

```
mise run unlink
```

- [ ] **Step 4: Open the PR**

```bash
git push -u origin feat/proportional-spacing
gh pr create --title "feat(spacing): the gap is a fraction of the cell" --body "$(cat <<'EOF'
## What

The gap between workspace tiles is 8% of the tile width, each edge of the grid carries one
gap, and the tiles take whatever width is left — fitted to whole pixels. Row seams follow the
same gap. `maxCellW` becomes a sanity cap at 800. Without `gapRatio` the pixel model runs
byte for byte as before.

Spec: `docs/specs/2026-09-20-proportional-spacing-design.md`. Plan:
`docs/plans/2026-09-20-proportional-spacing.md`.

## Measured

| availW | cw / gap | canvas |
|---|---|---|
| 2024 (laptop, bar) | 368 / 29 | 2014 |
| 2536 (external, bar) | 462 / 37 | 2532 |
| 3816 (4K at 1x) | 696 / 56 | 3816 |
| 1820 (laptop, centred) | 331 / 26 | 1811 |

The sweep test proves no width from 162 to 4384 overflows or is more than 2·cols px short.

## Corrected during review of the spec

The first draft's real-valued formula overflowed by 1–2 px at both of the author's widths, and
its missing-width fallback lost a column. Both are pinned by tests now.

## Deliberately not done

- No config key for the ratio.
- Top/bottom padding inside the card stays `card.pad`; noted for the sweep.

## Tier 1

<paste the totals lines from `mise run test`>

## By eye

<which screens, which modes, what the ratio looked like>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Then `gh pr checks --watch` — CI runs Qt 6.9, and an unknown property or a reserved-word
identifier fails there and nowhere else. Nothing in this plan adds a QML property, but check
anyway; it is part of the loop, not an afterthought.

**Do not merge while a marketplace release request is pending** (memory:
`omascape-release-train-freeze`).

---

## Self-review against the spec (done while writing)

- **Coverage.** Goal and the ratio decision → Tasks 2, 7. Edge padding inside the canvas →
  Tasks 2, 5. Integer fitting with its four table rows → Task 2; the sweep → Task 4; the
  column boundary and the fallback → Task 3; `minCellW` binding → Task 3; `maxCellW` cap →
  Task 6; vertical seams → Task 5; the fixed-pixel fallback and identity → Task 1; NaN floor →
  `assertFinite` in every logic test; the moved centring test and the 2048 fill test → Task 7;
  README, KB, ROADMAP → Task 8; the by-eye sweep and the out-of-scope top padding → Task 9.
- **Would-it-fail.** Task 1 and Task 3's tests are green on arrival and say so, with the wrong
  implementation each one traps named in its `Distinguishes:` line. Task 7's fill test reads
  `gapRatio` from production rather than supplying it. The sweep uses `fail` so an overflow
  names its width.
- **Type consistency.** `fiveOn`, `firstRowCount`, `assertFinite`, `withRatio`, `ratioParams`,
  `multiWithScratchpad` are defined once (Tasks 1, 3, 5) and used by name afterwards; `edge`,
  `rowGap`, `gapMin`, `edges`, `proportional` are Task 2's names and Task 5 uses the same ones.
- **Spec conflicts.** None found; the plan's numbers are the spec's post-review numbers. The
  spec says the canvas is "at most `2·cols` narrower when the cap does not bind" and the
  sweep pins exactly that.
