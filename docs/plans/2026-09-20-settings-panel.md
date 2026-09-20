# Settings Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or
> executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for
> tracking.

**Goal:** A keyboard-driven settings panel inside the picker, so omascape's eight settings are
discoverable and seven of them changeable without hand-editing JSON.

**Architecture:** A presentation-only `SettingsPanel.qml` (sibling to `FindBar.qml` /
`ContextMenu.qml` / `HintCap.qml`) renders rows and emits a change request. Three pure functions
in `logic.js` own the model, the cycling and the file payload. `OmascapeConfig.qml` persists
atomically. `Overview.qml` routes `ctrl+,` and owns the modal state.

**Tech Stack:** Quickshell 0.3.1 / QML (Qt 6.11 local, **Qt 6.4 on CI**), plain-JS `logic.js`,
`qmltestrunner` Tier 1 + offscreen UI suites.

Spec: `docs/specs/2026-09-20-settings-panel-design.md`.

---

## Environment and toolchain assumptions

- **Qt 6.4 on CI, 6.11 locally. An unknown QML property is a COMPILE error on 6.4**, not a no-op.
  No per-corner radius (6.7+), no per-side borders.
- **Never put a ternary on an `anchors.*` property.** A QML binding that evaluates to `undefined`
  is *destroyed*, not skipped — this cost a Critical on the drop-down branch. Use `AnchorChanges`
  in a `State`.
- **Assigning imperatively to a property that carries a binding destroys that binding.** Grep for
  imperative writes before adding any binding.
- `logic.js` is plain JavaScript (`.pragma library`), no imports. Legacy reserved words (`float`,
  `int`, `char`) cannot be identifiers on 6.4.
- **UI suites are not auto-discovered**, and **sibling components are not either** — both are
  copied by hand in `tests/ui/run.sh` and `tests/ui/prepare.py:254-256` respectively. A component
  that is not copied makes the suite fail to load; a suite that is not registered silently never
  runs.
- `tests/ui/prepare.py` **refuses to build** if any `Color.` reference survives its rewrites,
  comments included. Write theme-token names as prose in comments.
- Full suite: `mise run test` (~3 min; the UI tier alone is ~2.5). One Tier 1 test:
  `/usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_name`. One UI test:
  `bash tests/ui/run.sh Settings::test_name` — a **`TestCase::function` selector**; a bare suite
  name matches nothing and exits GREEN.
- Baseline before this work: **199 Tier 1 / 368 UI / 0 failed / 24 Lua chunks**.

## File structure

| File | Responsibility | Tasks |
|---|---|---|
| `logic.js` | `settingsRows`, `nextSettingValue`, `configWithKey` — pure, Tier 1 | 1, 2, 3 |
| `tests/tst_layout.qml` | Tier 1 coverage for those three | 1, 2, 3 |
| `SettingsPanel.qml` | **New.** Renders rows, owns selection, emits `changeRequested` | 4 |
| `tests/ui/prepare.py` | Copies the new component; stubs `save()` recording writes | 4, 5 |
| `OmascapeConfig.qml` | `save(key, value)`, `writeFailed(why)` from `onSaveFailed` | 5 |
| `Overview.qml` | `ctrl+,`, modal routing, Esc, peek interaction, the instance | 6, 7 |
| `tests/ui/settings.qml` | **New.** Routing and interaction | 6, 7 |
| `tests/ui/run.sh` | Registers the new suite | 6 |
| `README.md` | Documents the panel and its key | 8 |

**The three pure functions come first on purpose.** They carry every claim that can be checked
without a compositor, and the UI tasks then only have to prove wiring.

---

### Task 1: `Logic.settingsRows`

**Files:** Modify `logic.js` · Test `tests/tst_layout.qml`

- [ ] **Step 1: Write the failing test**

```qml
    // The panel's model. The FIRST assertion is the one that matters long-term: every key
    // parseConfig returns must appear exactly once. Without it, a future setting gets added to
    // the schema and simply never shows up in the panel — silently, with every test still green.
    function test_settings_rows_cover_every_config_key() {
        var cfg = Logic.parseConfig("{}")
        var rows = Logic.settingsRows(cfg)
        var keys = []
        for (var i = 0; i < rows.length; i++) keys.push(rows[i].key)
        var schema = []
        for (var k in cfg) schema.push(k)
        compare(keys.slice().sort().join(","), schema.slice().sort().join(","),
                "every parseConfig key needs a row, and no row may invent one")
        // lockBorder is present but not editable: a colour needs a real picker.
        for (var j = 0; j < rows.length; j++)
            if (rows[j].key === "lockBorder")
                compare(rows[j].editable, false, "lockBorder is shown, not edited")
        // ...and everything else IS editable, or the panel is decorative.
        var editable = rows.filter(function (r) { return r.editable }).length
        compare(editable, rows.length - 1, "seven of the eight must be editable")
    }

    function test_settings_rows_carry_the_current_values() {
        var rows = Logic.settingsRows(Logic.parseConfig('{"anchor":"bar","scrim":false}'))
        function row(k) { return rows.filter(function (r) { return r.key === k })[0] }
        compare(row("anchor").value, "bar", "a set value is shown, not the default")
        compare(row("scrim").value, false, "including a false boolean, which must not read as unset")
        compare(row("motion").value, "auto", "and an unset one shows its default")
    }
```

**What these distinguish:** the first goes red the moment a config key exists with no row — the
only way this rots silently. The `scrim: false` case catches a truthiness bug that would make a
disabled boolean display as its default.

- [ ] **Step 2: Run it and watch it fail**

`/usr/lib/qt6/bin/qmltestrunner -input tests/ Layout::test_settings_rows_cover_every_config_key`
Expected: FAIL — `settingsRows is not defined`.

- [ ] **Step 3: Implement**

In `logic.js`, above `function parseConfig(raw) {`:

```js
// The settings panel's model: one row per key parseConfig returns, in display order.
//
// Derived from the CONFIG OBJECT rather than a hand-written list, so a key added to parseConfig
// and forgotten here shows up as a missing row in the Tier 1 test rather than as a setting the
// panel silently cannot see.
//
// `lockBorder` is deliberately not editable: it is an rgb(hhhhhh) string and wants a real colour
// picker. It is still listed, because a setting you cannot see is worse than one you cannot
// change from here.
var SETTING_LABELS = {
    anchor: "anchor", activate: "activate", scrim: "scrim", hint: "hints",
    motion: "motion", workspaces: "workspaces", lockBorderSize: "lock frame",
    lockBorder: "lock colour"
}
var SETTING_ORDER = ["anchor", "activate", "scrim", "hint", "motion",
                     "workspaces", "lockBorderSize", "lockBorder"]
function settingsRows(cfg) {
    if (!cfg) return []
    var rows = [], seen = {}, i, k
    for (i = 0; i < SETTING_ORDER.length; i++) {
        k = SETTING_ORDER[i]
        if (!(k in cfg)) continue
        seen[k] = true
        rows.push({ key: k, label: SETTING_LABELS[k] || k, value: cfg[k],
                    editable: k !== "lockBorder" })
    }
    // Anything parseConfig returns that SETTING_ORDER has not been told about still gets a row,
    // at the end, rather than vanishing. The Tier 1 test fails on it, which is the point -- but
    // a user on a build where that slipped through still sees the setting exists.
    for (k in cfg)
        if (!seen[k]) rows.push({ key: k, label: k, value: cfg[k], editable: false })
    return rows
}
```

**Property:** the row set must be derived from `cfg`, not from a literal list alone — a
hand-maintained list that drifts is exactly the failure the first test exists to catch, and the
fallback loop is what keeps a drifted build honest to the user.

- [ ] **Step 4: Run both and watch them pass** · **Step 5: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "feat(settings): settingsRows derives the panel's model from the config schema"
```

---

### Task 2: `Logic.nextSettingValue`

**Files:** Modify `logic.js` · Test `tests/tst_layout.qml`

- [ ] **Step 1: Write the failing test**

```qml
    // Cycling. Every enum wraps in both directions and every stepper clamps -- and the function
    // is TOTAL: anything it does not understand comes back unchanged, because a settings panel
    // that silently rewrites a value it did not recognise is worse than one that does nothing.
    function test_next_setting_value_cycles_and_clamps() {
        compare(Logic.nextSettingValue("anchor", "center", 1), "bar", "two-state forward")
        compare(Logic.nextSettingValue("anchor", "bar", 1), "center", "and wraps")
        compare(Logic.nextSettingValue("anchor", "center", -1), "bar", "backwards wraps too")
        compare(Logic.nextSettingValue("scrim", true, 1), false, "booleans toggle")
        compare(Logic.nextSettingValue("scrim", false, -1), true, "in both directions")
        // THE three-state case: a two-state implementation passes every line above.
        compare(Logic.nextSettingValue("motion", "auto", 1), "full", "three-state steps")
        compare(Logic.nextSettingValue("motion", "full", 1), "off", "through the middle")
        compare(Logic.nextSettingValue("motion", "off", 1), "auto", "and wraps at the end")
        // Steppers CLAMP rather than wrap: wrapping 0 -> 20 on a Left press would be startling.
        compare(Logic.nextSettingValue("workspaces", 10, 1), 11, "steppers step")
        compare(Logic.nextSettingValue("workspaces", 20, 1), 20, "and clamp at the top")
        compare(Logic.nextSettingValue("workspaces", 0, -1), 0, "and at the bottom")
        compare(Logic.nextSettingValue("lockBorderSize", 6, -1), 5, "the other stepper too")
    }

    function test_next_setting_value_is_total() {
        compare(Logic.nextSettingValue("lockBorder", "rgb(ff4444)", 1), "rgb(ff4444)",
                "a non-editable key is never rewritten")
        compare(Logic.nextSettingValue("nosuchkey", "x", 1), "x", "nor is an unknown one")
        compare(Logic.nextSettingValue("workspaces", NaN, 1), 0, "a non-finite number restarts at 0")
        compare(Logic.nextSettingValue("anchor", "barr", 1), "center",
                "an out-of-set value lands on the first valid one, not on itself")
    }
```

**What these distinguish:** the `motion` lines fail against a two-state toggle, which passes
every boolean and every two-state enum above it. The clamp lines fail against a wrapping
implementation. `test_..._is_total` fails against anything that rewrites a key it does not own.

- [ ] **Step 2: Run and watch it fail** — `nextSettingValue is not defined`.

- [ ] **Step 3: Implement**

```js
// The next value for a setting, `dir` +1 or -1.
//
// TOTAL: an unknown key, a non-editable one, or a value outside the set comes back as something
// valid rather than throwing or inventing. A panel that silently rewrote a value it did not
// recognise would be worse than one that did nothing.
//
// Enums WRAP; the two numeric settings CLAMP. Wrapping a stepper from 0 round to 20 on a single
// Left press would be startling, and there is no way to express "I meant the end" on a keyboard
// row.
var SETTING_CYCLES = {
    anchor: ["center", "bar"],
    activate: ["enter", "select"],
    motion: ["auto", "full", "off"],
    scrim: [true, false],
    hint: [true, false]
}
var SETTING_RANGES = { workspaces: [0, 20], lockBorderSize: [0, 20] }
function nextSettingValue(key, current, dir) {
    var step = Number(dir) < 0 ? -1 : 1
    var cycle = SETTING_CYCLES[key]
    if (cycle) {
        var at = cycle.indexOf(current)
        if (at < 0) return cycle[0]                 // out of set: land somewhere valid
        return cycle[(at + step + cycle.length) % cycle.length]
    }
    var range = SETTING_RANGES[key]
    if (range) {
        var n = Number(current)
        if (!isFinite(n)) return range[0]
        return Math.max(range[0], Math.min(range[1], Math.round(n) + step))
    }
    return current                                   // not ours to change
}
```

**Property:** every return must be a value `parseConfig` would accept for that key — the panel
writes this straight to the file, so a value the parser rejects would be written and then
silently defaulted on the next read.

- [ ] **Step 4: Run both and watch them pass** · **Step 5: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "feat(settings): nextSettingValue cycles enums and clamps steppers"
```

---

### Task 3: `Logic.configWithKey` — the payload

**Files:** Modify `logic.js` · Test `tests/tst_layout.qml`

**This is the task that can destroy a user's file.** Everything else is recoverable by pressing a
key again.

- [ ] **Step 1: Write the failing test**

```qml
    // The write payload. Four of these came out of a review that found the first design
    // unsafe, and each one corresponds to a way a real file gets damaged.
    function test_config_with_key_writes_without_losing_the_rest() {
        // The ordinary case, and the one that stops defaults being pinned into the file: only
        // what was there plus the change.
        var out = Logic.configWithKey('{"scrim":false}', "anchor", "bar")
        var back = JSON.parse(out)
        compare(back.anchor, "bar", "the change lands")
        compare(back.scrim, false, "and the existing key survives")
        compare(Object.keys(back).length, 2, "nothing else is added — no pinned defaults")

        // THE guarantee that matters across versions: a key this build has never heard of must
        // not be deleted by it. An older panel must not eat a newer version's setting.
        var future = JSON.parse(Logic.configWithKey('{"futureThing":42}', "anchor", "bar"))
        compare(future.futureThing, 42, "an unknown key survives")

        // A file that does not exist yet.
        compare(JSON.parse(Logic.configWithKey("", "anchor", "bar")).anchor, "bar",
                "an empty file becomes a file with just this key")
        compare(JSON.parse(Logic.configWithKey("   \n ", "anchor", "bar")).anchor, "bar",
                "and so does a whitespace-only one")
    }

    function test_config_with_key_refuses_what_it_cannot_safely_edit() {
        // Verified behaviour, not theory: setting a property on a parsed array is DROPPED by
        // stringify, on null it THROWS, and on a scalar it is dropped. Each would either lose
        // the user's change silently or destroy a file they were mid-way through writing.
        compare(Logic.configWithKey("[1,2]", "anchor", "bar"), "", "a JSON array root")
        compare(Logic.configWithKey("null", "anchor", "bar"), "", "a null root")
        compare(Logic.configWithKey("42", "anchor", "bar"), "", "a scalar root")
        compare(Logic.configWithKey('"a string"', "anchor", "bar"), "", "a string root")
        // ...and the obvious one.
        compare(Logic.configWithKey('{"scrim":false,', "anchor", "bar"), "",
                "a file that does not parse is never overwritten with a guess")
    }
```

**What these distinguish:** `Object.keys(back).length === 2` fails against an implementation that
spreads defaults in. `futureThing` fails against one that rebuilds the object from a known key
list. The whole second test fails against the *original* design, which rejected only unparseable
text — every one of those four roots parses.

- [ ] **Step 2: Run and watch it fail** — `configWithKey is not defined`.

- [ ] **Step 3: Implement**

```js
// The file's new text after setting one key, or "" when the existing text cannot be edited
// safely. The caller writes nothing on "".
//
// An OBJECT root is required -- not merely parseable text, which was the first design and is
// unsafe. Verified against the engine: setting a property on a parsed array is silently dropped
// by stringify (the user presses a key, sees nothing change, and their file is rewritten without
// the setting), on `null` the assignment throws, and on a scalar it is dropped the same way as
// the array.
//
// What this preserves, precisely: unknown keys survive SEMANTICALLY and insertion order survives,
// which is what stops an older build deleting a newer version's setting. It is not a lossless
// editor -- a round trip normalises 9007199254740993 to ...992, 1e400 to null, and collapses
// duplicate keys. That is acceptable for a file holding small numbers, short strings and
// booleans, and is documented rather than hidden.
function configWithKey(rawText, key, value) {
    var text = String(rawText === undefined || rawText === null ? "" : rawText)
                   .replace(/^\s+|\s+$/g, "")
    var obj
    if (text.length === 0) obj = {}
    else {
        try { obj = JSON.parse(text) } catch (e) { return "" }
        if (obj === null || typeof obj !== "object" || Array.isArray(obj)) return ""
    }
    obj[key] = value
    return JSON.stringify(obj, null, 2) + "\n"
}
```

**Property:** for any input this returns non-`""`, `JSON.parse` of the result must contain every
key the input contained, plus `key` at `value`. That is the whole contract; the tests above are
its instances.

- [ ] **Step 4: Run both and watch them pass** · **Step 5: Commit**

```bash
git add logic.js tests/tst_layout.qml
git commit -m "feat(settings): configWithKey edits one key without eating the rest"
```

---

### Task 4: `SettingsPanel.qml`

**Files:** Create `SettingsPanel.qml` · Modify `tests/ui/prepare.py`

**⚠ Shared-fixture task.** `prepare.py` backs nine suites. Record `mise run test` totals before
and after; they must be **identical** apart from the new suite, which does not exist yet — so at
this task they must be **exactly** identical.

**What the fixture must reproduce:** the component is copied *verbatim* like `FindBar.qml`
(`prepare.py:254`) because it has no shell imports. **If it is not copied, every UI suite fails to
load once `Overview.qml` references it** — loudly, which is the good failure. What the fixture
cannot supply is a real theme; colours arrive as properties, so the panel must take every colour
and font from its caller and hard-code none.

- [ ] **Step 1: Create the component**

```qml
import QtQuick

// The settings panel: rows, a selection, and a request to change one value. It reads no config
// and writes no file -- Overview owns both -- so every claim it makes can be checked by handing
// it a model and reading back what it emits.
Rectangle {
    id: panel
    // Everything visual is injected, exactly as FindBar and HintCap do it: this component never
    // imports the shell, which is what lets the offscreen fixture copy it verbatim.
    property var rows: []
    property int index: 0
    property color background: "#222"
    property color foreground: "#ddd"
    property color accent: "#8ab"
    property color rowFill: "#333"
    property string fontFamily: ""
    property int fontSize: 11
    property string filePath: ""
    signal changeRequested(string key, int dir)

    radius: 8
    color: background
    implicitWidth: 420
    implicitHeight: list.implicitHeight + pathLabel.implicitHeight + 34

    Column {
        id: list
        x: 12; y: 12
        width: parent.width - 24
        spacing: 2
        Repeater {
            model: panel.rows
            Rectangle {
                required property var modelData
                required property int index
                width: list.width
                height: 26
                radius: 4
                color: index === panel.index ? panel.rowFill : "transparent"
                Text {
                    anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                    text: modelData.label
                    color: panel.foreground
                    opacity: modelData.editable ? 0.85 : 0.5
                    font.family: panel.fontFamily; font.pixelSize: panel.fontSize
                }
                Text {
                    anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    // The non-editable row says WHY it cannot be changed here, rather than
                    // looking like a control that does not respond.
                    text: modelData.editable
                          ? ("‹ " + String(modelData.value) + " ›")
                          : (String(modelData.value) + "   (edit the file)")
                    color: index === panel.index && modelData.editable ? panel.accent : panel.foreground
                    opacity: modelData.editable ? 1 : 0.5
                    font.family: panel.fontFamily; font.pixelSize: panel.fontSize
                }
            }
        }
    }
    Text {
        id: pathLabel
        anchors { left: parent.left; leftMargin: 20; bottom: parent.bottom; bottomMargin: 10 }
        text: panel.filePath
        color: panel.foreground; opacity: 0.45
        font.family: panel.fontFamily; font.pixelSize: panel.fontSize - 1
    }

    // Key handling lives here so Overview routes ONE call rather than reimplementing the rows'
    // semantics. Returns true when the key was consumed.
    function handleKey(e) {
        if (e.key === Qt.Key_Up)   { panel.index = Math.max(0, panel.index - 1); return true }
        if (e.key === Qt.Key_Down) { panel.index = Math.min(panel.rows.length - 1, panel.index + 1); return true }
        var row = panel.rows[panel.index]
        if (!row || !row.editable) return true          // consumed: the panel is modal
        if (e.key === Qt.Key_Left)  { panel.changeRequested(row.key, -1); return true }
        if (e.key === Qt.Key_Right) { panel.changeRequested(row.key, 1); return true }
        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { panel.changeRequested(row.key, 1); return true }
        return true
    }
}
```

**Property:** the component must hold no config knowledge. Handed `rows`, it renders them; asked
for a change, it names a key and a direction and nothing else. If a later task finds itself
importing `logic.js` here, the boundary has been crossed.

- [ ] **Step 2: Copy it into the fixture**

In `tests/ui/prepare.py`, beside the other verbatim copies (line ~254):

```python
(dest / 'SettingsPanel.qml').write_text((source / 'SettingsPanel.qml').read_text())  # no shell imports: verbatim
```

**Property:** without this line, every UI suite fails to load as soon as Task 6 references the
component from `Overview.qml`. Verify by running the full suite at Step 3 — this task is the only
chance to catch it in isolation.

- [ ] **Step 3: Verify nothing moved**

Run `mise run test`. Expected: **exactly** the baseline (199 Tier 1 / 368 UI / 0 failed / 24 Lua
chunks) — nothing references the panel yet, so any change means this task altered an existing
suite.

- [ ] **Step 4: Commit**

```bash
git add SettingsPanel.qml tests/ui/prepare.py
git commit -m "feat(settings): a presentation-only settings panel component"
```

---

### Task 5: `OmascapeConfig.save`

**Files:** Modify `OmascapeConfig.qml` · Modify `tests/ui/prepare.py`

**The offscreen fixture cannot prove this works.** It replaces `OmascapeConfig.qml` wholesale, so
the stub can only record that a save was *requested*. Preservation is covered by Task 3's Tier 1
tests; the real write path is a **live check**, listed at the end of this plan. Do not add a test
that appears to cover it.

- [ ] **Step 1: Implement the save path**

In `OmascapeConfig.qml`, after the existing `file` FileView:

```qml
    // Emitted when the file could not be written. Mirrors OmascapeLocks: FileView raises
    // `onSaveFailed`, and this is the component's own signal on top of it.
    signal writeFailed(string why)

    // Persist one setting. Reads the file's CURRENT text rather than rebuilding from the parsed
    // properties, so keys this build does not know about are carried through (see
    // Logic.configWithKey). An unparseable file is refused, not overwritten: the user may be
    // mid-edit, and replacing their work with { changedKey: value } would be worse than doing
    // nothing.
    function save(key, value) {
        var next = Logic.configWithKey(file.text(), key, value)
        if (next.length === 0) {
            cfg.writeFailed("the file could not be parsed; fix it before changing settings here")
            return false
        }
        file.setText(next)
        return true
    }
```

and on that FileView add both the atomic write and the failure path — neither exists today
(verified: `OmascapeConfig.qml` has no `atomicWrites`, no `onSaveFailed` and no `setText`):

```qml
        atomicWrites: true
        onSaveFailed: function (error) { cfg.writeFailed(FileViewError.toString(error)) }
```

matching `OmascapeLocks.qml:65` and `:77`. Without `onSaveFailed` a failed write is silent, which
is the failure mode this whole feature exists to remove.

**Property:** `save` must never write when `configWithKey` returns `""`. That is the only thing
standing between a half-typed config file and being replaced by a one-key object.

- [ ] **Step 2: Stub it in the fixture, recording requests**

In `tests/ui/prepare.py`'s `OmascapeConfig.qml` stub, alongside the existing properties:

```python
    '           property var writes: []\n'
    '           signal writeFailed(string why)\n'
    '           function save(key, value) { writes = writes.concat([key + "=" + value]); return true }\n'
```

**What this stub can and cannot show:** it proves `Overview` asked for the right change. It proves
nothing about preservation, atomicity or failure handling — the locks stub disclaims the same
thing for the same reason. Record that in a comment beside it.

- [ ] **Step 3: Run the full suite** — unchanged from baseline.

- [ ] **Step 4: Commit**

```bash
git add OmascapeConfig.qml tests/ui/prepare.py
git commit -m "feat(settings): persist one setting without rebuilding the file"
```

---

### Task 6: Open it, and make Esc close the panel only

**Files:** Modify `Overview.qml` · Create `tests/ui/settings.qml` · Modify `tests/ui/run.sh`

- [ ] **Step 1: Create the suite and register it**

Create `tests/ui/settings.qml` with the fixture shape used by `tests/ui/dropdown.qml` (copy its
`TestCase` header, `monitor()`, `screenStub` and `seed()` helpers verbatim; they are the
established fixture for this component), then:

```qml
    function test_ctrl_comma_opens_the_panel() {
        seed()
        verify(!view.settingsOpen, "precondition: closed")
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        verify(view.settingsOpen, "ctrl+, opens it")
    }

    // THE interaction most likely to be got wrong. Esc must close the PANEL and leave the
    // picker up.
    function test_escape_closes_the_panel_not_the_picker() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        verify(view.settingsOpen, "precondition: open")
        keyClick(Qt.Key_Escape)
        verify(!view.settingsOpen, "the panel closes")
        verify(view.opened, "and the picker is still up")
    }

    // ...and the companion, which stops the fix being "Esc never closes the picker". It must
    // first establish that no EARLIER branch owns Esc: today Esc clears the window cursor, then
    // the query, and only then closes (Overview.qml:2150-2153).
    function test_escape_still_closes_the_picker_with_no_panel() {
        seed()
        compare(view.cursorAddress, "", "precondition: no window cursor")
        compare(view.query, "", "precondition: no query")
        verify(!view.menuOpen, "precondition: no menu")
        verify(!view.confirmOpen, "precondition: no confirmation dialog")
        verify(!view.settingsOpen, "precondition: no panel")
        keyClick(Qt.Key_Escape)
        verify(!view.opened, "Esc still closes the picker")
    }

    // Esc's existing sequence must survive the new branch being added ahead of it.
    function test_escape_still_clears_the_query_before_closing() {
        seed()
        view.setQuery("fire")
        keyClick(Qt.Key_Escape)
        compare(view.query, "", "the query clears first")
        verify(view.opened, "without closing the picker")
    }
```

Register in `tests/ui/run.sh` beside the others:

```bash
cp "$src/tests/ui/settings.qml" "$fixture/tst_settings_ui.qml"
```

**What these distinguish:** the first two fail with no implementation. The third fails against
"Esc never closes the picker", and its four preconditions are what stop it passing for the wrong
reason against an earlier branch. The fourth fails against a panel branch placed *before* the
query-clearing one.

- [ ] **Step 2: Run and watch them fail** — `settingsOpen is not defined`.

- [ ] **Step 3: Implement the state and routing**

In `Overview.qml`, beside `menuOpen`:

```qml
    property bool settingsOpen: false
    // Swallows the auto-repeats of the key that closed the panel, so holding Esc cannot dismiss
    // the panel and then the picker in one press. Same device as menuDismissKey (:996).
    property int settingsDismissKey: 0

    function openSettings() {
        peekAbort()                                  // a modal and a peek are never both up
        settingsDismissKey = 0
        settingsPanel.index = 0                      // the panel owns it; seed, never bind
        settingsIndex = 0
        settingsOpen = true
    }
    property int settingsIndex: 0
```

In the key handler, **after** the `confirmOpen` and `menuOpen` branches (they stay ahead) and
**before** the `chord` branch:

```qml
                    if (root.settingsOpen) {
                        // Space must not start a peek on release just because it was pressed
                        // while a modal was up -- the confirmation branch does exactly this
                        // (:2093), and the release handler (:2210) still needs to run.
                        if (!(e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
                                && e.key === Qt.Key_Space) {
                            root.peekKeyDown = true
                            root.peekAbort()
                        }
                        if (e.key === Qt.Key_Escape) {
                            root.settingsDismissKey = e.key
                            root.settingsOpen = false
                            return
                        }
                        settingsPanel.handleKey(e)
                        return
                    }
                    // ...and the key that dismissed it keeps swallowing its own repeats.
                    if (root.settingsDismissKey !== 0 && e.key === root.settingsDismissKey) {
                        if (!e.isAutoRepeat) root.settingsDismissKey = 0
                        return
                    }
```

and in the `chord` branch (`:2143`), beside the existing shortcuts:

```qml
                        else if (chord === Qt.ControlModifier && e.key === Qt.Key_Comma && !finding) root.openSettings()
```

**Property:** the panel branch must sit *after* `confirmOpen` and `menuOpen` — a modal already up
keeps its keys — and *before* the ordinary Esc branch, or Esc clears the cursor/query instead of
closing the panel.

**The `!finding` guard is a decision, not an oversight.** The existing ctrl chords all fire during
a query (`Overview.qml:2143-2147`), so without it the panel would open mid-search by inheritance
rather than by choice. It does not open mid-search: a query is a transient mode with its own
Esc semantics, and stacking a modal on top of it gives Esc three meanings. Clear the query first.
Task 7 tests this.

- [ ] **Step 4: Run all four, then the full suite** — the new suite passes, nothing else moves.

- [ ] **Step 5: Commit**

```bash
git add Overview.qml tests/ui/settings.qml tests/ui/run.sh
git commit -m "feat(settings): ctrl+, opens the panel; Esc closes it, not the picker"
```

---

### Task 7: Wire the rows, the changes and the peek interaction

## ⚠ Carried from Task 5's review — a lost update in the FILE, not just the display

`FileView.text()` is a cache that only updates on `operationFinished`, and `saveAsync()` captures
its payload *before* cancelling any in-flight write (verified in Quickshell 0.3.1's
`src/io/fileview.cpp:321-338`). So two `save()` calls in quick succession do this:

1. save#1 builds new text from `text()`, starts a write.
2. save#2 — before that write finishes — reads `text()`, **which still returns the ORIGINAL
   content**, builds its own new text from it, and cancels write#1.
3. The file ends up with change#2 only. **Change#1 is lost.**

This is reachable by the exact scenario this task tests: two quick Rights on `workspaces`. And
`test_two_quick_presses_do_not_collapse_into_one_value` would **pass anyway**, because the stub
records two distinct requests — the loss happens in a write path the fixture does not have.

**So `applySettingChange` must pass the whole pending set, not one key.** `root.settingsPending`
already holds every unconfirmed change (it exists for the displayed-value version of this same
bug). Applying all of them to the file's text on every save makes write#2's payload a superset of
write#1's, so a cancelled write loses nothing:

```qml
    function applySettingChange(key, dir) {
        var row = null
        for (var i = 0; i < root.settingsRows.length; i++)
            if (root.settingsRows[i].key === key) row = root.settingsRows[i]
        if (!row || !row.editable) return
        var current = root.settingValue(key)
        var next = Logic.nextSettingValue(key, current, dir)
        if (next === current) return                 // clamped: nothing to write
        var pending = {}
        for (var k in root.settingsPending) pending[k] = root.settingsPending[k]
        pending[key] = next
        root.settingsPending = pending
        // The WHOLE pending set, not just `key`: FileView.text() is a cache that does not
        // update until a write completes, and a second save cancels the first while having
        // built its payload from the pre-first-write text. Sending every unconfirmed change
        // each time makes each payload a superset of the last, so a cancelled write loses
        // nothing. Verified against fileview.cpp:321-338.
        if (!config.saveAll(pending)) {
            var revert = {}
            for (var j in root.settingsPending) if (j !== key) revert[j] = root.settingsPending[j]
            root.settingsPending = revert
        }
    }
```

`OmascapeConfig` gains `saveAll(obj)` beside `save(key, value)` — applying each key in turn
through `Logic.configWithKey`, refusing entirely if any step returns `""`, and writing once:

```qml
    // Applies several settings in ONE write. See the caller's comment: a second write cancels
    // the first and builds its payload from stale cached text, so each payload must carry every
    // unconfirmed change rather than only the newest.
    function saveAll(values) {
        if (!readableForSave) {
            cfg.writeFailed("the file could not be read; fix that before changing settings here")
            return false
        }
        var next = file.text()
        for (var k in values) {
            next = Logic.configWithKey(next, k, values[k])
            if (next.length === 0) {
                cfg.writeFailed("the file could not be parsed; fix it before changing settings here")
                return false
            }
        }
        file.setText(next)
        return true
    }
```

Clear `settingsPending` on `config`'s reload, as the plan already specifies. `FileView` also has
a `saved()` signal (`fileview.hpp:342`) if a tighter clear is wanted later.

**Test it:** the existing two-quick-presses test stays (it pins the *request* side). Add one
asserting the second request carries BOTH changes — that is the half the stub can actually see:

```qml
        // The second write must carry the first change too, or a cancelled write loses it.
        verify(String(view.testConfig.writes[before + 1]).indexOf("workspaces") >= 0,
               "the second save still carries workspaces")
```

Adjust the stub to record the whole map rather than one `key=value` string.


**Files:** Modify `Overview.qml` · Modify `tests/ui/settings.qml`

- [ ] **Step 1: Write the failing tests**

```qml
    function test_arrows_move_and_cycle() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        compare(view.settingsIndex, 0, "starts at the top")
        keyClick(Qt.Key_Down)
        compare(view.settingsIndex, 1, "down moves")
        keyClick(Qt.Key_Up)
        compare(view.settingsIndex, 0, "up moves back")
        var before = view.testConfig.writes.length
        keyClick(Qt.Key_Right)
        compare(view.testConfig.writes.length, before + 1, "right requests a change")
        // The panel's first row is `anchor`, whose cycle is center -> bar.
        compare(String(view.testConfig.writes[before]), "anchor=bar",
                "and asks for the NEXT value, not an arbitrary one")
    }

    // A non-editable row consumes its keys rather than falling through to the picker beneath.
    function test_a_non_editable_row_changes_nothing() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        // lockBorder is last by SETTING_ORDER; step to it with real presses.
        for (var d = 0; d < view.settingsRows.length - 1; d++) keyClick(Qt.Key_Down)
        var before = view.testConfig.writes.length
        keyClick(Qt.Key_Right)
        compare(view.testConfig.writes.length, before, "no write is requested")
        verify(view.settingsOpen, "and the key did not escape to the picker")
    }

    // The panel does not open mid-search. Deliberate: a query has its own Esc semantics, and a
    // modal on top would give Esc three meanings. Fails against a ctrl+, that simply inherits
    // the chord branch's behaviour, which fires during a query like every other ctrl shortcut.
    function test_the_panel_does_not_open_during_a_search() {
        seed()
        view.setQuery("fire")
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        verify(!view.settingsOpen, "a query owns the screen; clear it first")
        compare(view.query, "fire", "and the chord did not disturb the query")
    }

    // A clamped stepper must not rewrite the file on every press.
    function test_a_clamped_stepper_writes_nothing() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        // Navigate with real presses: `settingsIndex` is a read-back mirror now, not a
        // control, so writing it would move nothing. SETTING_ORDER puts workspaces at index 5.
        for (var d = 0; d < 5; d++) keyClick(Qt.Key_Down)
        for (var i = 0; i < 25; i++) keyClick(Qt.Key_Right)   // drive it to the 20 ceiling
        var atCeiling = view.testConfig.writes.length
        keyClick(Qt.Key_Right)
        compare(view.testConfig.writes.length, atCeiling,
                "at the ceiling a further press must write nothing")
    }

    // Two quick presses must produce two DIFFERENT values. This is the lost-update case: read
    // each next value off `config` -- which only updates when the watcher reloads -- and both
    // presses compute from the same stale number and request the same one twice.
    function test_two_quick_presses_do_not_collapse_into_one_value() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        for (var d = 0; d < 5; d++) keyClick(Qt.Key_Down)   // workspaces, default 10
        var before = view.testConfig.writes.length
        keyClick(Qt.Key_Right)
        keyClick(Qt.Key_Right)                        // no reload in between: the stub never writes a file
        compare(view.testConfig.writes.length, before + 2, "both presses request a change")
        verify(String(view.testConfig.writes[before]) !== String(view.testConfig.writes[before + 1]),
               "and they must differ: got " + view.testConfig.writes[before]
               + " then " + view.testConfig.writes[before + 1])
    }

    // Opening the panel aborts an in-flight peek: a modal and a peek are never both up.
    function test_opening_the_panel_aborts_a_peek() {
        seed()
        keyPress(Qt.Key_Space)
        wait(60)
        verify(view.peeking, "precondition: a peek is up")
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        verify(!view.peeking, "opening settings aborts it")
        keyRelease(Qt.Key_Space)
    }
```

**What these distinguish:** `"anchor=bar"` fails against a panel that emits a raw direction the
caller misreads, or one that cycles the wrong row. The non-editable test fails against a
`handleKey` that returns without consuming. The peek test fails against an `openSettings` missing
its `peekAbort()`.

- [ ] **Step 2: Run and watch them fail.**

- [ ] **Step 3: Implement the wiring**

In `Overview.qml`, a bound model and the change handler:

```qml
    // Reads through settingValue(), so a change shows immediately and the NEXT press computes
    // from it rather than from the not-yet-reloaded file.
    readonly property var settingsRows: Logic.settingsRows({
        scrim: settingValue("scrim"), hint: settingValue("hint"),
        workspaces: settingValue("workspaces"), motion: settingValue("motion"),
        anchor: settingValue("anchor"), activate: settingValue("activate"),
        lockBorder: settingValue("lockBorder"), lockBorderSize: settingValue("lockBorderSize")
    })
    // Pending values, applied optimistically. WITHOUT this the panel would compute each change
    // from `config.*`, which only updates once the watcher has re-read the file -- so two quick
    // Right presses on `workspaces` would both read 10 and both request 11, and one increment
    // would vanish. This is the defect the spec review caught in the design; reading the row's
    // value straight off `config` reintroduces it.
    //
    // Cleared per key when the watcher's reload confirms that key, so the panel stops guessing
    // as soon as the file agrees with it.
    property var settingsPending: ({})
    function settingValue(key) {
        return (key in root.settingsPending) ? root.settingsPending[key] : config[key]
    }
    function applySettingChange(key, dir) {
        var row = null
        for (var i = 0; i < root.settingsRows.length; i++)
            if (root.settingsRows[i].key === key) row = root.settingsRows[i]
        if (!row || !row.editable) return
        var current = root.settingValue(key)
        var next = Logic.nextSettingValue(key, current, dir)
        if (next === current) return                 // clamped: nothing to write
        var pending = {}                             // a NEW object: mutating in place would
        for (var k in root.settingsPending) pending[k] = root.settingsPending[k]
        pending[key] = next                          // not re-evaluate the binding below
        root.settingsPending = pending
        if (!config.save(key, next)) {
            // Refused (an unparseable file). Drop the optimistic value so the panel shows what
            // the file still says rather than a change that never happened.
            var revert = {}
            for (var j in root.settingsPending) if (j !== key) revert[j] = root.settingsPending[j]
            root.settingsPending = revert
        }
    }
    Connections {
        target: config
        // The file agreed with us: stop guessing for the keys it now confirms.
        function onConfigChanged() {
            var still = {}
            for (var k in root.settingsPending)
                if (root.settingsPending[k] !== config[k]) still[k] = root.settingsPending[k]
            root.settingsPending = still
        }
    }
```

and the instance, inside the card after `bottomBarGlass`:

```qml
            SettingsPanel {
                id: settingsPanel
                visible: root.settingsOpen
                anchors.centerIn: parent
                rows: root.settingsRows
                // NO `index: root.settingsIndex` binding. ✎ (corrected after Task 4's review.)
                // handleKey assigns panel.index imperatively on Up/Down, and an imperative write
                // to a property that carries a binding DESTROYS that binding permanently -- the
                // same mechanism that cost this branch a Critical with the anchor ternaries.
                // Verified on the engine: after one such write the caller can no longer drive
                // the child at all. So the panel OWNS its index; Overview seeds it on open and
                // mirrors it back for read-only use.
                onIndexChanged: root.settingsIndex = index
                background: root.background
                foreground: root.foreground
                accent: root.accent
                rowFill: root.wellColor
                fontFamily: root.fontFamily
                fontSize: root.labelSize
                filePath: "~/.config/omarchy/omascape.json"
                onChangeRequested: function (key, dir) { root.applySettingChange(key, dir) }
            }
```

**Property:** `settingsRows` must be built from the live `config` properties, not a snapshot, so a
change applied by the watcher is reflected without reopening the panel. And `applySettingChange`
must not write when the value is unchanged — a clamped stepper at its limit would otherwise
rewrite the file on every keypress.

- [ ] **Step 4: Run all three, then the full suite.**

- [ ] **Step 5: Commit**

```bash
git add Overview.qml tests/ui/settings.qml
git commit -m "feat(settings): arrows cycle a setting and persist it"
```

---

### Task 8: Document it

**Files:** Modify `README.md`

- [ ] **Step 1: Document the panel** in the Configuration section: `ctrl+,` opens it, arrows move
  and cycle, Esc closes it, seven settings are editable there and `lockBorder` is file-only.
  Keep the existing JSON block — the file remains the source of truth and the only way to set a
  value the panel does not offer (a `workspaces` above 20, or a lock colour).

- [ ] **Step 2: Add the key to the keybindings table** beside `ctrl+s` / `ctrl+l` / `ctrl+w`.

- [ ] **Step 3: Full suite, then commit**

```bash
git add README.md
git commit -m "docs(settings): document the panel and ctrl+,"
```

---

## Live checks — not covered by any test here

The offscreen fixture has no compositor and stubs `OmascapeConfig` wholesale. These must be
checked by hand:

- **The real write path.** Change a setting with a hand-edited `omascape.json` containing an
  unknown key and unusual ordering; confirm both survive, and that only the changed key differs.
- **A malformed file.** Break the JSON, open the panel, press Right: it must refuse and notify,
  and the file must be untouched.
- **Rapid presses.** Hold Right on `workspaces`: the value must climb by one per press, not stall
  or skip — this is the lost-update case the optimistic-in-memory design exists to prevent.
- **How the panel reads over the drop-down's wallpaper backing**, where the card's ground is a
  photograph rather than a flat colour.
- **That `ctrl+,` is free in a real Hyprland session**, not only inside this plugin.
