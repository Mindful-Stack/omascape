# Pointer re-seat on map Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A click made after the overview opens, before the pointer moves, must reach the
overview on monitors not at (0,0). It works around the Hyprland 0.56.2 layer-map enter-offset bug.

**Architecture:** On Hyprland's `openlayer>>omascape` raw event, while the overview is open,
dispatch the existing same-position cursor warp (`Logic.regrabFocusLua()`), so Hyprland sends a
motion with correct coordinates. A pure predicate in `logic.js` decides which events qualify.
Design: `docs/specs/2026-09-27-pointer-reseat-design.md`.

**Tech Stack:** QML (Qt 6.9 floor, ADR-0004), ES5 `logic.js`, qmltestrunner logic and UI suites.

**Worktree:** `/home/daniel/Source/omascape/.claude/worktrees/pointer-reseat`, branch
`fix/pointer-reseat-on-map` (off `origin/dev`). PR targets `dev`.

Global constraints: `logic.js` is ES5 (`var`, no arrows, no template literals). No QML API newer
than Qt 6.9, and no reserved-word identifiers (`long`, `short`, `int`, `char`, `float`, `double`,
`byte`, `boolean`, `final`, `native`). Test comments use the `// Distinguishes:` convention
(`lore/knowledge/general/testing.md`). Never run `omarchy restart shell` or `scripts/dev-link.sh`.
The UI suite (`bash tests/ui/run.sh`) takes about 3 minutes, so use a long timeout.

---

### Task 1: The predicate and the wiring

**Files:**
- Modify: `logic.js` (after `focusStealingEvent`, around line 857; add the name to the file's
  export list if it has one, the same way `focusStealingEvent` is exported)
- Modify: `Overview.qml` (the `Connections { target: Hyprland; function onRawEvent(event) … }` block, around line 1876)
- Test: `tests/tst_actions.qml` (after `test_focusStealingEvent_covers_every_compositor_refocus`)
- Test: `tests/ui/actions.qml` (after `test_a_window_closing_while_closed_regrabs_nothing`)

- [ ] **Step 1: Write the failing logic test** in `tests/tst_actions.qml`:

```qml
    // Distinguishes: re-seating the pointer for the wrong surface. Only the overview's own layer
    // (namespace exactly "omascape") grabs keyboard focus on map and so hits Hyprland 0.56's
    // double-offset enter; the catchers ("omascape-catcher") are keyboard-None and never do, and a
    // prefix match would warp on every catcher map. closelayer and malformed events must not qualify.
    function test_overviewMappedEvent_is_the_overviews_own_openlayer_only() {
        verify(Logic.overviewMappedEvent({ name: "openlayer", data: "omascape" }))
        verify(!Logic.overviewMappedEvent({ name: "openlayer", data: "omascape-catcher" }), "catchers never grab focus")
        verify(!Logic.overviewMappedEvent({ name: "openlayer", data: "omarchy-bar" }))
        verify(!Logic.overviewMappedEvent({ name: "closelayer", data: "omascape" }))
        verify(!Logic.overviewMappedEvent({ name: "openlayer", data: "" }))
        verify(!Logic.overviewMappedEvent({ name: "openlayer" }))
        verify(!Logic.overviewMappedEvent(null))
    }
```

- [ ] **Step 2: Run it and confirm it fails for the stated reason**

Run: `/usr/lib/qt6/bin/qmltestrunner -input tests/tst_actions.qml 2>&1 | grep -E "overviewMapped|Totals"`
(with `QT_QPA_PLATFORM=offscreen`).
Expected: FAIL with a `TypeError` naming `overviewMappedEvent`, because the function doesn't exist
yet.

- [ ] **Step 3: Implement the predicate** in `logic.js`, directly after `focusStealingEvent`:

```js
// The overview's own layer surface has just been mapped (`openlayer>>omascape`). Hyprland 0.56.2
// gives a layer that grabs keyboard focus a wl_pointer.enter with the monitor's layout offset
// subtracted twice (LayerSurface.cpp:203: m_geometry is already global), so on a monitor that is
// not at (0,0) the overview believes the pointer is far outside itself, and a click made before
// any motion is dropped. The caller answers with regrabFocusLua(): a same-position warp makes
// Hyprland send a motion with correct coordinates. Exact match: the catchers ("omascape-catcher")
// are keyboard-None, never take that path, and must not warp. Remove this, and its caller in
// Overview.qml, once Omarchy ships a Hyprland containing d29916a (hyprwm/Hyprland#15899), which
// replaces that computation with simulateMouseMovement(). See
// docs/specs/2026-09-27-pointer-reseat-design.md.
function overviewMappedEvent(event) {
    return !!event && event.name === "openlayer" && event.data === "omascape"
}
```

- [ ] **Step 4: Run the logic suite**

Run the logic suites only:
`QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests 2>&1 | tail -3`
Expected: `Totals: … 0 failed`, including the new test.

- [ ] **Step 5: Write the failing UI tests** in `tests/ui/actions.qml`, after
`test_a_window_closing_while_closed_regrabs_nothing`:

```qml
    // Distinguishes: the dead first click on an offset monitor. When the overview's layer maps,
    // Hyprland 0.56 sends its pointer-enter off by the monitor position, so a click before any
    // motion hits nothing; the same-position warp dispatched on openlayer is what corrects it.
    // Mutation check: delete the overviewMappedEvent branch in onRawEvent and this goes red.
    function test_the_overview_mapping_reseats_the_pointer() {
        view.compositor.commands = []
        view.compositor.rawEvent({ name: "openlayer", data: "omascape" })
        wait(30)
        var warps = 0
        for (var i = 0; i < view.compositor.commands.length; i++)
            if (view.compositor.commands[i].indexOf("cursor.move") >= 0) warps++
        compare(warps, 1, "exactly one cursor warp, to re-seat the pointer")
    }
    // Distinguishes: a prefix match that also warps when a catcher maps on another screen.
    function test_a_catcher_mapping_reseats_nothing() {
        view.compositor.commands = []
        view.compositor.rawEvent({ name: "openlayer", data: "omascape-catcher" })
        wait(30)
        compare(view.compositor.commands.length, 0)
    }
    // Distinguishes: warping on a stray openlayer while closed. The event can only matter while
    // the overview is up, because that is when a click on it is meant to land.
    function test_openlayer_while_closed_reseats_nothing() {
        view.close()
        view.compositor.commands = []
        view.compositor.rawEvent({ name: "openlayer", data: "omascape" })
        wait(30)
        compare(view.compositor.commands.length, 0)
    }
```

- [ ] **Step 6: Run the UI suite and confirm the first test fails for the stated reason**

Run: `bash tests/ui/run.sh 2>&1 | grep -E "reseat|Totals"` (long timeout).
Expected: `test_the_overview_mapping_reseats_the_pointer` FAILs with actual 0 and expected 1,
because nothing is wired yet. The other two pass already (nothing dispatches). That is expected:
they guard against over-matching, which only the implementation can introduce.

- [ ] **Step 7: Wire it** in `Overview.qml`'s `onRawEvent`, directly after the
`focusStealingEvent` branch (`if (event && root.opened && Logic.focusStealingEvent(event.name)) …`):

```qml
            // Our own layer just mapped: re-seat the pointer (Logic.overviewMappedEvent explains the
            // Hyprland 0.56 enter-offset bug this works around). Same warp as the focus regrab.
            if (event && root.opened && Logic.overviewMappedEvent(event))
                Hyprland.dispatch(Logic.regrabFocusLua())
```

- [ ] **Step 8: Run both suites**

Run: `bash tests/ui/run.sh 2>&1 | grep -E "reseat|Totals"`, then the logic suites as in Step 4.
Expected: all three new UI tests pass, and the Totals are the pre-change counts plus the new tests
with 0 failed. Record the pre-change UI Totals before Step 5, so the delta is visible.

- [ ] **Step 9: Mutation check**

Change the predicate to `event.data.indexOf("omascape") === 0` (a prefix match), run the UI
suite, and `test_a_catcher_mapping_reseats_nothing` must FAIL. Revert and re-run until green.

- [ ] **Step 10: Commit**

```bash
git add logic.js Overview.qml tests/tst_actions.qml tests/ui/actions.qml
git commit -m "fix(overview): re-seat the pointer when the overview maps (Hyprland 0.56 enter offset)"
```
The message ends with a `Co-Authored-By:` line naming the implementing model.

---

### Task 2: The learning

**Files:**
- Create: `lore/knowledge/learnings/hyprland-056-layer-enter-offset.md`

- [ ] **Step 1: Write it**, following the frontmatter shape of
`lore/knowledge/learnings/overlay-layer-focus-must-be-ondemand.md`. Every value goes inline on one
line, with `confidence: verified`, `source: developer-input`, `date: 2026-09-27`, and tags reused
from existing learnings (e.g. `[frameworks, hyprland, quickshell, compositor]`). Body sections:
  - the symptom;
  - the cause (quote the two-line `LOCAL` computation and why `m_geometry` is already global);
  - the evidence (the `WAYLAND_DEBUG` numbers from the spec);
  - the workaround and where it lives (`Logic.overviewMappedEvent`, `onRawEvent`);
  - why the catchers are exempt;
  - the removal condition (d29916a / hyprwm/Hyprland#15899 released and shipped by Omarchy);
  - "See also" wikilinks to [[learnings/overlay-layer-focus-must-be-ondemand]] and
    [[frameworks/hyprland/compositor-state]].

  Add a one-line wikilink back to this learning in the "See also" of
  `overlay-layer-focus-must-be-ondemand.md`, so it is not orphaned.

- [ ] **Step 2: Validate**

Run: `make validate`
Expected: `[OK]` frontmatter, links and orphans.

- [ ] **Step 3: Commit**

```bash
git add lore/knowledge/learnings/
git commit -m "docs(lore): Hyprland 0.56 hands a mapping layer an off-by-the-monitor pointer enter"
```

---

### Task 3 (controller): Hand verification, PR

- Full `mise run test`.
- Back up `~/.config/omarchy/shell.json`, `scripts/dev-link.sh --status`, then link this worktree.
  Put the bar button on the bar if it's present (it isn't on this branch, since it's off `dev`), or
  summon with SUPER+TAB. The owner clicks once on the scrim **without moving**, and the overview
  closes.
- Check the log: during the owner's test, the live shell's log (`quickshell log -i <id>`) shows
  no QML errors from the new branch.
- Restore the link and `shell.json`. Push, open the PR against `dev`, and watch `gh pr checks`.
