---
title: JavaScript code style (logic.js)
description: logic.js is a dependency-free `.pragma library` holding the layout maths and reconcile diff; it is written in a deliberately conservative ES5-style dialect because Qt 6.4 is the compatibility floor, and it must never reference a QML or Quickshell type.
tags: [languages, javascript, qml, testing]
---

# JavaScript code style (`logic.js`)

Almost all of Omascape's JavaScript lives in one file. `logic.js` is 1886 lines and 82
top-level functions holding the layout maths, the reconcile diff, search ranking, key handling
and the Lua chunk builders. Counts taken 2026-09-20 against this branch's base, `a72ecda`;
`main` has moved on since, so the totals read low. The rules, not the totals, are the standard.

Its first line is the whole architecture:

```js
.pragma library
```

QML components import it as `import "logic.js" as Logic` — `Overview.qml`, `OmascapeLocks.qml`,
`OmascapeConfig.qml`, `LockFrame.qml` and the test fixtures all do. `DESIGN.md` puts the rule
plainly: `Overview.qml` only wires Quickshell singletons to it.

## It stays dependency-free

`logic.js` imports nothing and references no QML or Quickshell type at runtime. A `.pragma
library` has no QML engine context, so this is not a style preference — it is what makes the
module loadable and unit-testable offscreen.

The convention shows up most clearly in key handling, which hardcodes Qt's key codes as numeric
literals and keeps the name in a comment:

```js
    return key === 0x01000020 ||   // Qt.Key_Shift
           key === 0x01000021 ||   // Qt.Key_Control
```

Writing `Qt.Key_Shift` would be shorter and would break the module. When you need a Qt constant,
inline its value and name it in a comment.

**Layout maths belongs here, not in a QML binding.** That is what makes it testable: the logic
suites run it under `qmltestrunner` with no compositor.

## The dialect is deliberately conservative

Measured across the file:

| Construct | Count |
|---|---|
| `var` | 202 |
| `let` / `const` | 0 |
| arrow functions | 0 |
| template literals | 0 |
| classes | 0 |

Use `var`. No arrow functions, no template literals, no classes. The 161 backticks in the file are
all markdown prose inside comments, not template literals.

This is not nostalgia: Qt 6.4 is the compatibility floor and its JS parser is what CI compiles
against — see [[adrs/0004-qt-compatibility-floor]]. The same record carries the identifier rule
that bites hardest here: never name a variable `long`, `short`, `int`, `char`, `float`, `double`,
`byte`, `boolean`, `final` or `native`. The file currently has zero violations; each one is a
green local run and a red build.

## Naming

- Functions that emit Lua end in `Lua`, without exception — see
  [[languages/lua/chunk-authoring]].
- Module-private helpers take a leading underscore: 12 of the 82 functions, among them `_index`,
  `_placeWindows`, `_tileRect`, `_readingOrder`, `_navigateTiles`. The underscore means "not part
  of the surface a QML component should call", and it is a convention, not enforcement.
- Everything else is lowerCamelCase.

## Errors

Inside generated Lua, raise with an explicit level 0 — `error(msg, 0)` — so no
`[string "..."]:N:` prefix reaches a user-facing notification or the compositor log. All 13
`error()` calls in the file do this. The reasoning and the failure path are
[[adrs/0002-compositor-dispatch-errors]].

Text interpolated into a chunk is truncated **before** it is escaped, never after. See
[[languages/lua/chunk-authoring]].

## Tests

Every function here is expected to be reachable from the Tier 1 logic suites
(`tests/tst_layout.qml`, `tst_find.qml`, `tst_actions.qml`, `tst_motion.qml`), which run
offscreen with no compositor. A change to `logic.js` that cannot be exercised from a test is a
sign the logic belongs somewhere else, or that the function is doing QML's job.

## See Also

- [[adrs/0004-qt-compatibility-floor]] — why the dialect is pinned this far back.
- [[languages/lua/chunk-authoring]] — the chunk builders that live in this file.
- [[adrs/0003-test-tiers]] — where the logic suites run.
