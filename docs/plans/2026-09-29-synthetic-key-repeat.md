# Synthetic key repeat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A held key must count as held when an input method (fcitx5) delivers its repeats as
real release and press pairs. This fixes the flickering peek, and protects Ctrl+W, Ctrl+, the
select-mode digits, the dismiss-key swallow and the settings panel's Enter.

**Architecture:** A per-key tracker in `logic.js` makes a release provisional for
`KEY_RELEASE_GRACE_MS` (50). A press of the same key inside that window is a repeat, and the
pending release is dropped. `Overview.qml`'s key catcher asks the tracker once per press and
passes the answer everywhere that read `e.isAutoRepeat`. One timer runs the release effects that
survive the grace. Design: `docs/specs/2026-09-29-synthetic-key-repeat-design.md`.

**Tech Stack:** QML (Qt 6.9 floor), ES5 `logic.js`, qmltestrunner logic and UI suites.

**Worktree:** `/home/daniel/Source/omascape/.claude/worktrees/key-repeat`, branch
`fix/synthetic-key-repeat` (off `origin/dev`). PR targets `dev`.

Global constraints:
- `logic.js` is ES5: `var`, no arrows, no template literals.
- No QML API newer than Qt 6.9, and no reserved-word identifiers (`long`, `short`, `int`, `char`,
  `float`, `double`, `byte`, `boolean`, `final`, `native`).
- Test comments use `// Distinguishes:` (`lore/knowledge/general/testing.md`).
- Never run `omarchy restart shell` or `scripts/dev-link.sh`.
- The UI suite takes about 3 minutes, so use a long timeout. Run one UI suite at a time.

---

### Task 1: The tracker (logic.js)

**Files:**
- Modify: `logic.js`, directly after `digitActivate` (search `function digitActivate`)
- Create: `tests/tst_keyrepeat.qml`

- [ ] **Step 1: Write the failing logic tests.** Copy the header from `tests/tst_actions.qml`
  (`import QtQuick`, `import QtTest`, `import "../logic.js" as Logic`, `TestCase { name: "KeyRepeat" … }`):

```qml
import QtQuick
import QtTest
import "../logic.js" as Logic

TestCase {
    name: "KeyRepeat"

    // Distinguishes: a grace that drifted. 50 ms sits between fcitx5's measured 1 ms
    // release→press gap and the ~80 ms a person needs to re-press the same key.
    function test_the_grace_is_fifty_ms() {
        compare(Logic.KEY_RELEASE_GRACE_MS, 50)
    }
    // Distinguishes: an input-method repeat pair read as a real release and a fresh press — the
    // measured cause of the peek flicker. The press after a pending release is a repeat, and the
    // release is dropped so it never takes effect.
    function test_a_press_while_its_release_is_pending_is_a_repeat() {
        var tr = Logic.keyRepeatTracker()
        compare(Logic.trackPress(tr, Qt.Key_Space, false), false, "the first press is real")
        verify(Logic.trackRelease(tr, Qt.Key_Space, false, 1000), "a real release is recorded")
        compare(Logic.trackPress(tr, Qt.Key_Space, false), true, "same key while pending: a repeat")
        compare(Logic.dueReleases(tr, 5000, 50, false).length, 0, "the dropped release never takes effect")
    }
    // Distinguishes: a release that never takes effect. Past the grace, it is due exactly once.
    function test_a_release_takes_effect_once_after_the_grace() {
        var tr = Logic.keyRepeatTracker()
        Logic.trackRelease(tr, Qt.Key_Space, false, 1000)
        compare(Logic.dueReleases(tr, 1049, 50, false).length, 0, "not before the grace")
        compare(Logic.dueReleases(tr, 1050, 50, false), [Qt.Key_Space])
        compare(Logic.dueReleases(tr, 9999, 50, false).length, 0, "and only once")
        compare(Logic.hasPendingReleases(tr), false)
    }
    // Distinguishes: a detector that swallows a real second press. After the release has taken
    // effect, the next press of the same key is fresh.
    function test_a_press_after_the_release_took_effect_is_fresh() {
        var tr = Logic.keyRepeatTracker()
        Logic.trackRelease(tr, Qt.Key_2, false, 1000)
        Logic.dueReleases(tr, 1100, 50, false)
        compare(Logic.trackPress(tr, Qt.Key_2, false), false)
    }
    // Distinguishes: per-key state collapsed into one flag. Another key's press does not cancel
    // Space's pending release, and a force flush releases everything at once (focus loss).
    function test_keys_are_tracked_independently_and_force_flushes_all() {
        var tr = Logic.keyRepeatTracker()
        Logic.trackRelease(tr, Qt.Key_Space, false, 1000)
        compare(Logic.trackPress(tr, Qt.Key_W, false), false, "a different key is a fresh press")
        verify(Logic.hasPendingReleases(tr), "Space is still pending")
        Logic.trackRelease(tr, Qt.Key_W, false, 1010)
        var due = Logic.dueReleases(tr, 1011, 50, true)
        compare(due.length, 2, "force releases every pending key")
    }
    // Distinguishes: Qt's own repeat flag lost. A press Qt flags is a repeat; a release Qt flags
    // is ignored, as every release guard did before this change.
    function test_qt_flagged_repeats_keep_their_meaning() {
        var tr = Logic.keyRepeatTracker()
        compare(Logic.trackPress(tr, Qt.Key_Space, true), true)
        compare(Logic.trackRelease(tr, Qt.Key_Space, true, 1000), false, "ignored, not pending")
        compare(Logic.hasPendingReleases(tr), false)
    }
}
```

- [ ] **Step 2: Run and confirm red for the stated reason.**
  Run `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/tst_keyrepeat.qml 2>&1 | tail -15`.
  Expected: every test FAILs with a `TypeError`/`undefined` naming `KEY_RELEASE_GRACE_MS` or
  `keyRepeatTracker`.

- [ ] **Step 3: Implement** in `logic.js` after `digitActivate`:

```js
// Key repeats that arrive as real key events (docs/specs/2026-09-29-synthetic-key-repeat-design.md).
// Under an input method (fcitx5 — Omarchy's default — once a text-input window has had focus),
// a held key repeats as a release and a press 1 ms apart, BOTH with isAutoRepeat false (measured
// 2026-09-29), so every guard that trusted the flag read a hold as a stream of fresh presses: the
// peek flickered, and a held Ctrl+W would close a window per repeat. A release is therefore only
// provisional for KEY_RELEASE_GRACE_MS; a press of the same key inside it is a repeat and the
// release is dropped. 50 ms sits between the measured 1 ms gap and the ~80 ms a person needs to
// re-press a key. The tracker is a plain object so the pure functions below stay unit-testable;
// Overview.qml owns the one timer that lets a surviving release take effect.
var KEY_RELEASE_GRACE_MS = 50
function keyRepeatTracker() { return { pending: {} } }
// True when this press repeats a key already held: Qt says so, or the key's release is pending.
function trackPress(tr, key, qtRepeat) {
    var k = String(key)
    if (tr.pending.hasOwnProperty(k)) { delete tr.pending[k]; return true }
    return !!qtRepeat
}
// Records a real release as pending (true). A release Qt flags as a repeat is ignored (false).
function trackRelease(tr, key, qtRepeat, now) {
    if (qtRepeat) return false
    tr.pending[String(key)] = now
    return true
}
// The keys whose release has outlived the grace (every pending key when `force`), removed from
// the tracker so each takes effect exactly once.
function dueReleases(tr, now, grace, force) {
    var out = []
    for (var k in tr.pending) {
        if (!tr.pending.hasOwnProperty(k)) continue
        if (force || now - tr.pending[k] >= grace) out.push(parseInt(k, 10))
    }
    for (var i = 0; i < out.length; i++) delete tr.pending[String(out[i])]
    return out
}
function hasPendingReleases(tr) {
    for (var k in tr.pending) if (tr.pending.hasOwnProperty(k)) return true
    return false
}
```

- [ ] **Step 4: Run the logic suites.** Run `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests 2>&1 | tail -3`.
  Expected: `0 failed`, including the 6 new tests.

- [ ] **Step 5: Mutation check.** Change `trackPress` to skip the pending check (`return !!qtRepeat`
  only). `test_a_press_while_its_release_is_pending_is_a_repeat` must FAIL. Revert.

- [ ] **Step 6: Commit.** Run `git add logic.js tests/tst_keyrepeat.qml`, then
  `git commit -m "feat(logic): a key-repeat tracker that recognises repeats arriving as real key events"`
  with a trailer naming your model.

---

### Task 2: Wire it into the key catcher, and the fixture

**Files:**
- Modify: `Overview.qml`: root properties and functions, `open()`, the key catcher's
  `onActiveFocusChanged`, `Keys.onPressed` and `Keys.onReleased`
- Modify: `tests/ui/prepare.py`
- Test: `tests/ui/peek.qml`, `tests/ui/actions.qml`, `tests/ui/activate.qml`

- [ ] **Step 0: Record the baseline.** Run `bash tests/ui/run.sh 2>&1 | grep -E "^Totals"` and note the
  passed count.

- [ ] **Step 1: Root properties and functions.** Add them near the peek properties, just before
  `function peekKeyOf`:

```qml
    // Key repeats that arrive as real key events (Logic.keyRepeatTracker; spec
    // docs/specs/2026-09-29-synthetic-key-repeat-design.md). A release only takes effect once no
    // press of the same key has followed within the grace. At <= 0 it takes effect synchronously —
    // the offscreen fixture's setting (tests/ui/prepare.py), so the existing key tests keep their
    // semantics; the repeat tests set the production grace explicitly.
    property int keyReleaseGraceMs: Logic.KEY_RELEASE_GRACE_MS
    property var _keyRepeat: Logic.keyRepeatTracker()
    Timer { id: keyReleaseGrace; interval: root.keyReleaseGraceMs + 5; onTriggered: root.flushKeyReleases(false) }
    function flushKeyReleases(force) {
        var due = Logic.dueReleases(_keyRepeat, Date.now(), keyReleaseGraceMs, force)
        for (var i = 0; i < due.length; i++) handleKeyRelease(due[i])
        if (Logic.hasPendingReleases(_keyRepeat)) keyReleaseGrace.restart()
    }
```
  The `+ 5` makes the timer fire after the grace has fully passed, so a release is never re-armed
  because of millisecond rounding.

- [ ] **Step 2: Move the release body into `handleKeyRelease(key)`.** Define it right after
  `flushKeyReleases`. Its body is the current `Keys.onReleased` body minus `e.accepted`, with
  `e.key` → `key` and the three `!e.isAutoRepeat` conditions removed, because a Qt-flagged repeat
  release never reaches it now. Move the existing comment about the release clearing the cancel
  along with it:

```qml
    function handleKeyRelease(key) {
        if (menuDismissKey !== 0 && key === menuDismissKey) menuDismissKey = 0
        if (settingsDismissKey !== 0 && key === settingsDismissKey) settingsDismissKey = 0
        // (the existing comment: the release is the ONLY thing that clears the cancel …)
        if (key === Qt.Key_Space) { peekKeyDown = false; peekRelease() }
    }
```
  Then replace `Keys.onReleased` with:

```qml
                Keys.onReleased: function (e) {
                    e.accepted = true
                    // Provisional: see keyReleaseGraceMs. A Qt-flagged repeat release is ignored.
                    if (!Logic.trackRelease(root._keyRepeat, e.key, e.isAutoRepeat, Date.now())) return
                    if (root.keyReleaseGraceMs <= 0) { root.flushKeyReleases(true); return }
                    // Start, never restart: another key's repeats must not keep pushing a pending
                    // release back. flushKeyReleases re-arms while anything is still pending.
                    if (!keyReleaseGrace.running) keyReleaseGrace.start()
                }
```

- [ ] **Step 3: The press handler asks once.** In `Keys.onPressed`, directly after `e.accepted = true`:

```qml
                    // Releases whose grace has already passed take effect first, so a timer that fired
                    // late (a busy event loop) can never make a genuine re-press look like a repeat.
                    root.flushKeyReleases(false)
                    // One answer for every repeat guard below: Qt's flag, or a press of a key whose
                    // release is still pending (an input method's repeat — Logic.trackPress).
                    var rep = Logic.trackPress(root._keyRepeat, e.key, e.isAutoRepeat)
```
  Then change these, and only these:
  - `… e.key === Qt.Key_W && !e.isAutoRepeat) root.closeTarget()` becomes `… && !rep) root.closeTarget()`
  - `… e.key === Qt.Key_Comma && !finding && !e.isAutoRepeat) root.openSettings()` becomes `… && !rep) root.openSettings()`
  - `Logic.digitActivate(e.key, latch, root.boxes, e.isAutoRepeat)` becomes `Logic.digitActivate(e.key, latch, root.boxes, rep)`
  - `settingsPanel.handleKey(e)` becomes
    `settingsPanel.handleKey({ key: e.key, modifiers: e.modifiers, text: e.text, isAutoRepeat: rep })`.
    First check that `SettingsPanel.handleKey` reads no other field of `e`. If it does, add that
    field.

  Afterwards, `grep -n "isAutoRepeat" Overview.qml` must show no code use outside the
  `trackPress`/`trackRelease` calls. Comments may still mention it.

- [ ] **Step 4: Focus loss and `open()`.**
  - In the key catcher's `onActiveFocusChanged`, change `if (!activeFocus) root.peekAbort()` to
    `if (!activeFocus) { root.flushKeyReleases(true); root.peekAbort() }`. Add a one-line comment:
    a release that happened before the loss really happened. Flushing first means `peekAbort()`
    sees the key as up and latches nothing.
  - In `open()`, next to its existing `peekReset()` call (search inside `open()`; if `open()`
    doesn't call it directly, put this directly after `opened = true`), add
    `_keyRepeat = Logic.keyRepeatTracker()`.

- [ ] **Step 5: The fixture.** In `tests/ui/prepare.py`, next to the other simple substitutions
  (after the `Style.space` rewrite), add:

```python
# Key repeats (docs/specs/2026-09-29-synthetic-key-repeat-design.md): the fixture releases keys
# synchronously, exactly as before the tracker existed, so the ~80 existing press/release sites keep
# their semantics. The repeat tests set the production grace explicitly and cleanup() resets it.
qml = replaced(qml, 'property int keyReleaseGraceMs: Logic.KEY_RELEASE_GRACE_MS',
               'property int keyReleaseGraceMs: 0', 'keyReleaseGraceMs default')
```

- [ ] **Step 6: Run the UI suite. It must equal the Step 0 baseline**, 0 failed. This proves the
  fixture rewrite leaves every existing test's meaning intact.

- [ ] **Step 7: The repeat tests.** In each of the three suites, change
  `function cleanup() { view.close() }` to `function cleanup() { view.keyReleaseGraceMs = 0; view.close() }`.
  Then add:

  `tests/ui/peek.qml`. Before writing, read the neighbouring Space tests (~line 130) to see which
  target a bare `keyPress(Qt.Key_Space)` peeks in this fixture. If it needs a hover, add
  `hoverTile("0xB")` first.
```qml
    // Distinguishes: an input method's repeats read as real key events — the measured flicker.
    // Under fcitx5 a held Space repeats as release+press pairs with isAutoRepeat false; without the
    // tracker each pair ends the peek and re-opens it. Mutation check: make Logic.trackPress ignore
    // a pending release and this goes red on `changes`.
    function test_synthetic_repeats_keep_the_peek_open() {
        view.keyReleaseGraceMs = 50
        keyPress(Qt.Key_Space)
        verify(view.testPeek.shown, "the hold opened a peek")
        var changes = 0
        var count = function () { changes++ }
        view.peekingChanged.connect(count)
        for (var i = 0; i < 5; i++) { keyRelease(Qt.Key_Space); keyPress(Qt.Key_Space) }
        // Wait out the grace WHILE the key is still held (the last event is a press): a pair whose
        // release was wrongly kept pending would only take effect ~55 ms later, so a shorter wait
        // would stay green under the very bug this test names (plan review, verified).
        wait(120)
        view.peekingChanged.disconnect(count)
        compare(changes, 0, "no repeat pair may close or re-open the peek")
        keyRelease(Qt.Key_Space)
        verify(view.testPeek.shown, "a real release waits out the grace")
        wait(120)
        compare(view.testPeek.shown, false, "then the hold ends")
    }
```
  `tests/ui/actions.qml`, next to `test_repeated_ctrl_w_clears_the_workspace_without_repeating`:
```qml
    // Distinguishes: a held Ctrl+W under an input method closing a window per repeat. The repeat
    // pairs of W pass a guard that trusts isAutoRepeat. Mutation check: pass e.isAutoRepeat
    // instead of `rep` to the Ctrl+W guard and this goes red.
    function test_a_held_ctrl_w_under_synthetic_repeat_closes_once() {
        view.keyReleaseGraceMs = 50
        keyClick(Qt.Key_Right)
        compare(view.cursorAddress, "0xA")
        view.compositor.commands = []
        keyPress(Qt.Key_W, Qt.ControlModifier)
        for (var i = 0; i < 4; i++) { keyRelease(Qt.Key_W, Qt.ControlModifier); keyPress(Qt.Key_W, Qt.ControlModifier) }
        keyRelease(Qt.Key_W, Qt.ControlModifier)
        wait(120)
        var closes = 0
        for (var j = 0; j < view.compositor.commands.length; j++)
            if (view.compositor.commands[j].indexOf("window.close") >= 0) closes++
        compare(closes, 1, "one held chord closes one window")
    }
```
  `tests/ui/activate.qml`, in the select-mode `test_c_` block. Confirm that `init()` sets
  `activate = "select"` for these tests; if it's per test, do the same here:
```qml
    // Distinguishes: a held digit committing in select mode. A second press of the same digit
    // commits by design, and an input method's repeat pairs look exactly like one unless the
    // tracker marks them. Mutation check: pass e.isAutoRepeat to digitActivate and this goes red.
    function test_c_a_held_digit_under_synthetic_repeat_only_selects() {
        view.keyReleaseGraceMs = 50
        keyPress(Qt.Key_2)
        for (var i = 0; i < 4; i++) { keyRelease(Qt.Key_2); keyPress(Qt.Key_2) }
        keyRelease(Qt.Key_2)
        wait(120)
        compare(view.opened, true, "a held digit must not enter")
        compare(view.selectedId, 2)
        compare(view.compositor.commands.length, 0)
    }
    // Distinguishes: a tracker that swallows a real second press. A release that outlived the
    // grace was real, so pressing the same digit again is the deliberate "same digit enters" —
    // a tracker that called it a repeat would leave the overview open. (The Space branch never
    // reads the repeat answer, so this is tested on a digit: plan review, verified.)
    function test_c_a_slow_second_press_of_the_same_digit_enters() {
        view.keyReleaseGraceMs = 50
        keyPress(Qt.Key_2); keyRelease(Qt.Key_2); wait(120)
        compare(view.selectedId, 2)
        keyPress(Qt.Key_2); keyRelease(Qt.Key_2); wait(120)
        compare(view.opened, false, "the second, real press commits")
    }
```

- [ ] **Step 8: Run the UI suite.** Expected: the baseline plus the 4 new tests (peek ×1, Ctrl+W ×1, digit ×2) and nothing else, with 0 failed.

- [ ] **Step 9: Mutation checks**, one at a time, reverting each:
  1. Make `Keys.onPressed` use `var rep = e.isAutoRepeat`. The peek, Ctrl+W and held-digit tests
     must FAIL. The peek one fails because a wrongly kept pending release takes effect during its
     120 ms held wait.
  3. Make `Logic.trackPress` always return true. `test_c_a_slow_second_press_of_the_same_digit_enters`
     must FAIL.
  2. Make `Keys.onReleased` call `root.flushKeyReleases(true)` unconditionally.
     `test_synthetic_repeats_keep_the_peek_open` must FAIL.

- [ ] **Step 10: Commit.** Run
  `git add Overview.qml tests/ui/prepare.py tests/ui/peek.qml tests/ui/actions.qml tests/ui/activate.qml`, then
  `git commit -m "fix(overview): repeats an input method delivers as real key events count as held"`
  with a trailer naming your model.

---

### Task 3: The learning

- Create `lore/knowledge/learnings/fcitx5-key-repeat-is-real-events.md`. Use the frontmatter shape
  of `lore/knowledge/learnings/hyprland-056-layer-enter-offset.md`, with every value inline,
  `confidence: verified`, `source: developer-input`, `date: 2026-09-29`, and reused tags such as
  `[frameworks, quickshell, qml, compositor]`. Cover:
  - the symptom;
  - the measurement from the spec;
  - why Omascape can't opt out (a plain `Item` focus);
  - the rule: never trust `isAutoRepeat` alone, and go through `Logic.trackPress`;
  - the 50 ms grace and why;
  - the fixture's 0 grace.

  "See also" links go to [[learnings/hyprland-056-layer-enter-offset]] and
  [[frameworks/quickshell/component-patterns]]. Add a back-link from one of them so the learning
  isn't orphaned.
- Run `make validate`, which must be `[OK]`. Commit with
  `docs(lore): under an input method, key repeat arrives as real key events`.

---

### Task 4 (controller): full suite, hand verification, PR

Run `mise run test`. Dev-link this worktree. Then the owner's repro: open, SUPER+Q, hold Space,
and there must be no flicker; also a held Ctrl+W on a throwaway window must close only it.
Restore the `dev` link, push, and open the PR against `dev`. Then watch `gh pr checks`.
