# Omascape — Card Presence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the picker a real margin from the screen edge on every display size, and enough elevation that the margin reads as deliberate rather than as a layout accident.

**Architecture:** One pure `Logic.screenMargin(px)` — 5% of the panel dimension, floored at 16 — replaces two unrelated hardcoded constants (`- 16` in `availCanvasW`, `- 16`/`- 64` in `maxCardW`/`maxCardH`) that had drifted apart by `2 * card.pad`. Elevation is a 1px accent-derived border plus a deeper shadow at the card's own `SoftShadow` use site, leaving `SoftShadow.qml`'s defaults (and therefore `WindowTile`'s shadow) untouched. An optional final commit tints the card 8% toward accent and rebases `badgeColor` onto the card colour.

**Tech Stack:** QML/Qt Quick (Qt 6.11 local, **Qt 6.4 on CI**), Quickshell 0.3.1. Tests: `mise run test` → `tests/run.sh` (Tier 1 `tests/tst_*.qml`, offscreen UI `tests/ui/*.qml`, Lua parse/behaviour). No compositor work, no new Lua chunks, so `tests/lua-check.sh`'s chunk-count guard is **not** touched by this plan.

**Spec:** `docs/specs/2026-09-18-card-presence-design.md` — read it first. "The bug", "Decisions" and "Changes" are normative.

---

## Conventions (every task)

**Branch:** `git checkout -b presence ce868ce` (the commit carrying the specs). Work in `~/Source/omascape`.

> ⚠️ `ce868ce` currently sits on `tier2-hidden-drop-focus`, not on `actions-omascape` — the spec commits landed there. Nothing in this plan depends on which branch it is; if those commits get moved or rebased first, branch `presence` from wherever the spec ends up instead.

**Test loop:** `mise run test`. Single suites:
- Tier 1: `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/tst_layout.qml`
- UI: `bash tests/ui/run.sh Presence::test_name`

**Fixture facts you need for this plan** (all verified against `tests/ui/prepare.py`, 2026-09-18):
- `Style.space(12)` is rewritten to the literal `12`, so **`card.pad` is exactly 12** in the UI suite. Every number below depends on that.
- `PanelWindow` becomes a plain `Item`, and `anchors { top: true; … }` becomes `width: 1200; height: 800` (`prepare.py:70`). That is a constant binding, not a binding to anything — assigning `view.testPanel.width = 1920` overwrites it cleanly. **No change to `prepare.py` is required by this plan**, which matters: it is shared by seven suites.
- `SoftShadow.qml` is replaced by a stub that **already declares** `target`, `radius`, `blur`, `offset` and `color` (`prepare.py:243`). Adding `blur:` and `offset:` at the card's use site therefore cannot break the fixture. The stub draws nothing, so **no offscreen test can assert anything about the shadow** — it is covered by the manual sweep in Task 4 only.
- `root` exposes `testPanel`, `testCard`, `testFlick`, `testCanvas` aliases.

**Gotcha — Qt 6.4 on CI** rejects legacy reserved words as identifiers (`float`, `int`, `long`, `char`, `byte`, `double`, `boolean`, `final`, `native`). Check `gh pr checks` after every push.

**Commit style:** `feat(presence): …`, `test(presence): …`, `docs(presence): …`; body says *why*; end every message with:
```
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
```

---

## Task 1: `Logic.screenMargin` — the pure function

**Files:**
- Modify: `logic.js` (add near the other layout helpers, above `layout()`)
- Test: `tests/tst_layout.qml` (existing file; auto-discovered, no registration needed)

**What Tier 1 can and cannot cover here.** `screenMargin` is fully testable. The *wiring* is not: `Logic.layout()` receives `availW` as an input and has no idea whether its caller subtracted a margin, so a pure test of `layout()` asserting "the canvas leaves room" would simply be re-asserting the number the test itself passed in. That whole class of check lives in Task 2's UI suite instead. Do not add one here.

- [ ] **Step 1: Write the failing test**

Append to `tests/tst_layout.qml`, inside the `TestCase`:

```qml
    // Breathing room between the picker and the screen edge. A FRACTION, because the two
    // absolute constants this replaces were sized for a ~1600-logical card and left 10 px on
    // a 1920-logical one (a 4K panel at 2x — the commonest laptop logical width there is).
    function test_screen_margin_is_five_percent_with_a_floor() {
        compare(Logic.screenMargin(1920), 96, "4K at 2x: the reported case")
        compare(Logic.screenMargin(2048), 102, "2560 at 1.25x: rounds down from 102.4")
        compare(Logic.screenMargin(1080), 54, "the vertical axis uses the same function")
    }
    // The floor is what keeps a genuinely narrow screen behaving as it does today rather than
    // losing its margin entirely: 5% of 200 is 10, less than the 16 the old constants used.
    function test_screen_margin_floors_at_sixteen() {
        compare(Logic.screenMargin(200), 16, "the floor binds below 320")
        compare(Logic.screenMargin(320), 16, "exactly at the floor's crossover")
    }
    // panel.width is 0 until the surface maps, and a NaN would flow into availW, cell width,
    // every box, the canvas and finally the card — which a Rectangle paints as nothing at all.
    // The same failure mode as the phantom-monitor guard above.
    function test_screen_margin_never_yields_a_non_number() {
        compare(Logic.screenMargin(0), 16, "unmapped surface")
        compare(Logic.screenMargin(-5), 16, "nonsense width")
        compare(Logic.screenMargin(NaN), 16, "NaN must not propagate")
        compare(Logic.screenMargin(undefined), 16, "missing argument")
    }
```

**What these distinguish:** the first fails if the fraction or the rounding is wrong (`Math.floor` instead of `Math.round` turns 102.4 into 102 *coincidentally* but 1920×0.05 = 96 exactly, so `1080 → 54` is the case that discriminates rounding). The second fails if the floor is missing or applied after rounding. The third fails if the guard is missing — and it is the one that matters most, because its failure mode is an invisible overlay that still takes keyboard focus, not a visible error.

- [ ] **Step 2: Run it to verify it fails**

```bash
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/tst_layout.qml
```
Expected: three FAILs, each reporting `undefined` — `Logic.screenMargin is not a function`. If any test fails for a different reason, stop: the function name or the import is wrong, not the logic.

- [ ] **Step 3: Write the implementation**

In `logic.js`, immediately above `function layout(input) {`:

```js
// Breathing room between the picker and the screen edge, both axes. A FRACTION, because the two
// absolute constants this replaces (`availCanvasW`'s `- 16` and the card's `- 16` / `- 64`) were
// sized for a ~1600-logical card: at 1920 logical — a 4K panel at 2x, and the commonest laptop
// logical width there is — they left the grid 10 px from the edge. Floored so a genuinely narrow
// screen keeps today's behaviour rather than losing its margin altogether. Guarded like every
// other layout input: a NaN here would reach the card as a zero-size Rectangle, i.e. an invisible
// overlay that still holds keyboard focus.
function screenMargin(px) {
    var n = Number(px)
    if (!isFinite(n) || n <= 0) return 16
    return Math.round(Math.max(16, n * 0.05))
}
```

- [ ] **Step 4: Run it to verify it passes**

```bash
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/tst_layout.qml
```
Expected: PASS, and the existing layout tests still pass — `screenMargin` is additive and nothing calls it yet.

- [ ] **Step 5: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "feat(presence): a shared, tested screen margin

Two constants sized for a ~1600-logical card left the grid 10px from the
edge at 1920 logical. One derived function so they cannot drift apart
again; nothing calls it yet.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Wire the margin, proven by the real card

**Files:**
- Create: `tests/ui/presence.qml`
- Modify: `tests/ui/run.sh` (one `cp` line — a new UI suite is **not** auto-discovered)
- Modify: `Overview.qml:257` (`availCanvasW`), `Overview.qml:1463-1464` (`maxCardW`, `maxCardH`)

**This is the task that actually fixes the bug.** Task 1's function can be perfect, fully tested, and simply never wired in — or wired into one of the three bindings and not the others, which is precisely the drift that caused the original defect. Only something that measures the real card can tell, which is why the test comes first here and why it asserts *user-visible geometry* rather than the constants.

**The arithmetic these assertions rest on** (production params: `maxCols 5, minCellW 140, maxCellW 380, cellInset 3, cellSpacing 4`; fixture `card.pad` = 12; one monitor, so `multi` is false and `inset`/`headerH` are 0):

| | today | after |
|---|---|---|
| `screenMargin(1920)` | — | 96 |
| `availCanvasW` | 1920 − 24 − 16 = 1880 | 1920 − 24 − 192 = **1704** |
| `cw` | min(380, ⌊1864/5⌋) = 372 | min(380, ⌊1688/5⌋) = **337** |
| `canvas.implicitWidth` | 5·372 + 4·4 = 1876 | 5·337 + 4·4 = **1701** |
| `card.width` | min(1900, 1904) = **1900** | min(1725, 1728) = **1725** |
| per side | **10 px** | **97 px** |

- [ ] **Step 1: Write the failing UI suite**

Create `tests/ui/presence.qml`:

```qml
import QtQuick
import QtTest
import "../logic.js" as Logic

// Offscreen UI suite for the card-presence spec (docs/specs/2026-09-18-card-presence-design.md).
// The fixture (tests/ui/prepare.py) runs the real Overview with the compositor replaced by a
// stub, so buildInput(), Logic.layout() and the card's own sizing bindings are production code
// here. That is the entire point of this suite: Logic.screenMargin() is unit-tested in
// tests/tst_layout.qml and proves nothing about whether Overview.qml actually uses it.
TestCase {
    id: tc
    name: "Presence"
    when: windowShown
    width: 1920; height: 1080; visible: true
    property var view

    Component { id: overview; Overview {} }

    function client(addr, cls, x) {
        return { address: addr, at: [x, 1500], size: [400, 400], floating: false,
                 title: cls, "class": cls, fullscreen: 0 }
    }
    function wsRow(id, monitor, clients) {
        return { id: id, monitor: monitor,
                 toplevels: { values: clients.map(function (c) { return { lastIpcObject: c } }) } }
    }
    function makeMon(name, y) {
        return { name: name, x: 0, y: y, width: 1920, height: 1080, scale: 1,
                 lastIpcObject: { reserved: [0, 26, 0, 0], transform: 0,
                                  activeWorkspace: { id: 1 }, specialWorkspace: { id: 0, name: "" } } }
    }

    // `mons` is a list of monitors; each gets `perMon` workspaces, numbered consecutively.
    // The panel is sized BEFORE open() so the first rebuild already sees the real width:
    // availCanvasW is what feeds Logic.layout's availW, and open() rebuilds once immediately.
    function seed(mons, perMon) {
        view = createTemporaryObject(overview, tc)
        verify(view)
        view.testPanel.width = 1920
        view.testPanel.height = 1080
        var wss = [], id = 1
        for (var m = 0; m < mons.length; m++)
            for (var k = 0; k < perMon; k++, id++)
                wss.push(wsRow(id, mons[m], id === 1 ? [client("0xA", "alpha", 100)] : []))
        view.compositor.monitors = { values: mons }
        view.compositor.focusedMonitor = mons[0]
        view.compositor.focusedWorkspace = { id: 1 }
        view.compositor.workspaces = { values: wss }
        view.open()
        wait(120)
    }

    // THE regression. On the pre-fix code the card is 1900 wide on a 1920 panel: 10 px of air.
    function test_the_card_keeps_a_real_margin_from_the_screen_edge() {
        seed([makeMon("eDP-1", 0)], 5)
        var margin = Logic.screenMargin(1920)
        compare(margin, 96, "guard: the suite's arithmetic assumes a 96 px margin")
        verify(view.testCard.width <= 1920 - 2 * margin,
               "card is " + view.testCard.width + ", must be <= " + (1920 - 2 * margin))
    }

    // Isolates the availCanvasW binding from the maxCardW one. If only the CARD cap learned
    // about the margin, cw stays 372, the canvas stays 1876, and the card clamps to 1728 — so
    // the assertion above would pass while the grid scrolls sideways on a screen with 195 px
    // of unused room. This is the only assertion that can tell those two states apart.
    function test_the_grid_fits_without_scrolling_sideways() {
        seed([makeMon("eDP-1", 0)], 5)
        verify(view.testFlick.contentWidth <= view.testFlick.width,
               "content " + view.testFlick.contentWidth + " must fit viewport " + view.testFlick.width)
    }

    // The vertical margin's only coverage. maxCardH does not bind in ordinary layouts, so an
    // unwired height binding would go unnoticed until someone docked a third monitor.
    function test_a_tall_layout_respects_the_vertical_margin() {
        seed([makeMon("eDP-1", 0), makeMon("HDMI-A-1", 1080), makeMon("DP-1", 2160)], 10)
        // Fixture precondition: this case is worthless unless the content genuinely overflows.
        // Three monitors x 10 workspaces is two sub-rows each; if a params change ever made that
        // fit, the assertions below would pass without exercising the cap at all.
        verify(view.testCanvas.implicitHeight > 1080 - 2 * Logic.screenMargin(1080),
               "fixture must produce a layout taller than the cap, got " + view.testCanvas.implicitHeight)
        verify(view.testCard.height <= 1080 - 2 * Logic.screenMargin(1080),
               "card is " + view.testCard.height + ", must be <= " + (1080 - 2 * Logic.screenMargin(1080)))
        verify(view.testFlick.contentHeight > view.testFlick.height,
               "a capped card must still scroll, not clip")
    }
}
```

Register it — `tests/ui/run.sh`, after the `monitors.qml` line:

```bash
cp "$src/tests/ui/presence.qml" "$fixture/tst_presence_ui.qml"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/ui/run.sh Presence
```
Expected: `test_the_card_keeps_a_real_margin_from_the_screen_edge` FAILs with `card is 1900, must be <= 1728`. That exact number is the proof the suite is measuring the real bug — **if it reports 1200-ish, the panel resize did not take and `view.testPanel.width = 1920` needs fixing before anything else in this task means anything.** The other two tests may pass or fail; only this one is diagnostic at this step.

- [ ] **Step 3: Wire all three bindings**

`Overview.qml`, replace the `availCanvasW` property (around line 257):

```qml
    // Card interior logical width available to the canvas: panel.width (logical, not
    // screen.width*dpr) minus the card's own padding and the screen margin. Shares
    // Logic.screenMargin with the card's own caps below so the two cannot drift apart —
    // they previously disagreed by 2 * card.pad, which is how the grid came to sit 10 px
    // from the edge of a 1920-logical screen.
    readonly property real availCanvasW:
        panel.width > 0 ? panel.width - 2 * card.pad - 2 * Logic.screenMargin(panel.width) : 1600
```

and the two card caps (around lines 1463-1464):

```qml
            // Cap the card to the screen so the Flickable viewport can be smaller than the
            // content. With availCanvasW taking the same margin, the width cap is a backstop
            // that only binds in the degenerate narrow-screen case; the HEIGHT cap does real
            // work whenever there are enough monitor groups to overflow.
            readonly property real maxCardW: panel.width  > 0 ? panel.width  - 2 * Logic.screenMargin(panel.width)  : 1616
            readonly property real maxCardH: panel.height > 0 ? panel.height - 2 * Logic.screenMargin(panel.height) : 900
```

- [ ] **Step 4: Run the whole suite**

```bash
mise run test
```
Expected: all three Presence tests PASS, and **every existing suite still passes**. Pay attention to `Drag`, `Actions` and `Monitors` — they run at the fixture's default 1200×800, where `screenMargin(1200)` = 60 rather than the old 16, so cell widths shift and any test asserting an absolute canvas or card coordinate will move with them. If one fails, it is reporting a genuine coordinate change, not a regression: re-derive its expected value rather than reverting the binding.

- [ ] **Step 5: Commit**

```bash
git add Overview.qml tests/ui/presence.qml tests/ui/run.sh
git commit -m "fix(presence): the grid no longer fills the screen edge to edge

availCanvasW and maxCardW each subtracted their own absolute constant and
disagreed by 2*card.pad. At 1920 logical -- a 4K panel at 2x -- that left
10px per side. Both now take Logic.screenMargin.

tests/ui/presence.qml measures the real card, because a pure layout() test
cannot: layout() receives availW as an input and cannot tell whether its
caller subtracted anything.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Border and deeper shadow

**Files:**
- Modify: `Overview.qml:1450` (the card's `SoftShadow` use site), and the `card` Rectangle

Nothing here is offscreen-testable: the fixture replaces `SoftShadow.qml` with a stub that draws nothing, and an assertion like `compare(card.border.width, 1)` would only re-read the literal written one line earlier. Both are verified by eye, in both themes, per the spec.

- [ ] **Step 1: Add the border**

On the `card` Rectangle, beside `radius: root.cardRadius`:

```qml
            // Now that there is real air around the card it must read as elevated rather than as
            // a lighter rectangle. Accent-derived rather than a fixed neutral: a black hairline
            // looks like a bug on a light card and a white one vanishes on it. `accent` is
            // already `selText` and already tracks the theme, so this needs no new colour.
            // One logical px is two device px at 2x — crisp at exactly the scale that reported it.
            border.width: 1
            border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)
```

- [ ] **Step 2: Deepen the shadow**

Replace the card's `SoftShadow` line:

```qml
        // A 28% shadow reads on light themes but vanishes on dark ones (Tokyo Night sweep),
        // so the alpha follows the card's luminance. Deeper than SoftShadow's defaults because
        // this is the one surface that must lift off the desktop; overridden at the USE SITE so
        // WindowTile's own blur: 12 shadow is untouched.
        SoftShadow { target: card; scale: card.scale; opacity: card.opacity
                     blur: 48; offset: Qt.vector2d(0, 12)
                     color: Qt.rgba(0, 0, 0, root.darkTheme ? 0.65 : 0.38) }
```

- [ ] **Step 3: Confirm the fixture still compiles**

```bash
mise run test
```
Expected: PASS, unchanged. `prepare.py`'s `SoftShadow.qml` stub already declares `blur` and `offset` (verified 2026-09-18), so this cannot break the suites — but run it, because an undeclared property on the stub is a *compile* error that takes down all seven UI suites at once, and you want to see that now rather than after the next task.

- [ ] **Step 4: Visual sweep, both themes**

```bash
LIVE="$HOME/.config/omarchy/plugins/se.mindfulstack.omascape"
cp logic.js Overview.qml "$LIVE"/ && omarchy restart shell
```
Then SUPER+P on a dark theme and on a light one. Confirm, and note in the commit which themes you actually looked at:
1. The border reads on both without ringing or looking like a selection state.
2. The deeper shadow does not muddy the light theme.
3. **`WindowTile`'s shadow is visibly unchanged** — the check that the override stayed at the use site. Compare a floating tile against `git stash` if unsure.

QML errors: `journalctl --user -t omarchy-shell -n 60`.

- [ ] **Step 5: Commit**

```bash
git add Overview.qml
git commit -m "feat(presence): a border and a deeper shadow lift the card

With a real margin the card needs to read as elevated, not just as a
lighter rectangle. Accent-derived border so it works on light and dark;
shadow deepened at the use site only, leaving WindowTile's alone.

Swept on <themes you checked>.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 4 (OPTIONAL — land Tasks 1-3 and live with them first)

**Files:** `Overview.qml` (the theme block near line 62, and `card.color`)

The spec specifies this as an opt-in second commit precisely so the margin can be judged on its own. **Only do this if, after using Tasks 1-3, the card still does not stand out enough.** A full accent background was rejected outright — it would collapse `wellColor`, `emptyWellColor`, `dropWellColor`, `hairline`, `badgeColor` and `groupBackdropColor`, which are all tone steps over `background`. An 8% tint keeps every one of those relationships.

- [ ] **Step 1: Add the tinted card colour and rebase the badge**

In the theme block:

```qml
    // The card's own ground: the theme background nudged 8% toward accent, so the picker has a
    // colour identity without becoming an accent surface. A full accent card would erase
    // groupBackdropColor (accent at 0.08 — the focused-monitor cue) and flatten the three well
    // shades, which are all tone() steps tuned against `background`. 8% moves contrast against
    // `foreground` negligibly and cannot flip `darkTheme`.
    readonly property color cardColor: Qt.rgba(background.r * 0.92 + accent.r * 0.08,
                                               background.g * 0.92 + accent.g * 0.08,
                                               background.b * 0.92 + accent.b * 0.08, 1)
```

Change `badgeColor` to follow the card rather than the background — its own comment already says "the card colour":

```qml
    readonly property color badgeColor: Qt.rgba(cardColor.r, cardColor.g, cardColor.b, 0.88)
```

And on the card Rectangle, `color: root.background` becomes `color: root.cardColor`.

- [ ] **Step 2: Run the suite**

```bash
mise run test
```
Expected: PASS. `prepare.py` rewrites `Color.menu.*` to `"#888888"`, so `background` and `accent` are the same grey in the fixture and the tint is a no-op there — which is why this step is a compile-and-regression check, not a colour check.

- [ ] **Step 3: Visual sweep, both themes**

Deploy as in Task 3. The specific thing to look at, because it is what the full-accent version would have destroyed: **the focused monitor's group backdrop (accent at 0.08) must still be legible against the tinted card.** Also check the workspace number badges still read over a busy thumbnail.

- [ ] **Step 4: Commit**

```bash
git add Overview.qml
git commit -m "feat(presence): tint the card 8% toward accent

Gives the picker a colour identity without becoming an accent surface: the
wells, hairline and group backdrop are all tone steps over background and
collapse against a full accent card. badgeColor rebased onto the card
colour, which its own comment already asked for.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Record it

**Files:** `ROADMAP.md`, `docs/specs/2026-09-18-card-presence-design.md`

- [ ] **Step 1: Add a ROADMAP entry**

Under "Next steps", following the numbering already there:

```markdown
### 11. ~~Card presence: screen margin and elevation~~ ✅ done (2026-09-18)
`Logic.screenMargin` (5%, floored at 16) replaces two drifted absolute constants; card border
and a deeper shadow. Fixes a grid that sat 10 px from the edge on a 1920-logical screen (a 4K
panel at 2x). See `docs/specs/2026-09-18-card-presence-design.md`.
```

Also correct the stale chunk count in the maintenance gotchas — it says 23, `tests/lua-check.sh:84` guards on 24:

```markdown
- **Every new compositor chunk must raise the count guard in `tests/lua-check.sh`** (currently 24)
```

- [ ] **Step 2: Update the spec's status line**

```markdown
Status: **implemented 2026-09-18.** Branch `presence`.
```

- [ ] **Step 3: Commit and open the PR**

```bash
git add ROADMAP.md docs/specs/2026-09-18-card-presence-design.md
git commit -m "docs(presence): roadmap entry, spec status, stale chunk count

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
git push -u origin presence
gh pr create --fill
gh pr checks --watch
```

CI runs Qt 6.4. If it fails and local passed, the reserved-word gotcha is the first thing to check.
