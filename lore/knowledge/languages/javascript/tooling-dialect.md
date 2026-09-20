---
title: JavaScript in the KB tooling and workspace scripts
description: The JavaScript under lore/_tools/ and scripts/*.mjs is ordinary modern Node with zero runtime dependencies and the built-in node:test runner; it never loads into the QML engine, so ADR-0004's Qt 6.4 floor does not reach it and logic.js's ES5 rules must not be carried across.
tags: [languages, javascript, tooling, testing, dev-workflow]
---

# JavaScript in the KB tooling and workspace scripts

There are **two unrelated bodies of JavaScript in this repository**, and they are written in
opposite dialects on purpose. Mixing up which rules apply is the failure this node exists to
prevent.

| | `logic.js` | `lore/_tools/`, `scripts/*.mjs` |
|---|---|---|
| Runs in | the QML engine, inside Quickshell | Node, from a terminal or `make` |
| Ships to users | yes, it is the plugin | no, it is workspace tooling |
| Dialect | ES5-style, `var` only | modern Node, `const`/arrow/async |
| Governed by | [[languages/javascript/code-style]] | this node |

If the file is imported by a `.qml` file, it is the first column and
[[adrs/0004-qt-compatibility-floor]] binds it. Otherwise it is the second, and the floor is
irrelevant — Node is whatever the developer has installed, not Qt's QML parser.

Measured 2026-09-20 across all 18 tooling files (6244 lines).

## The dialect is just modern Node

| Construct | Count |
|---|---|
| `const` | 808 |
| `let` | 46 |
| arrow functions | 524 |
| `async` | 47 |
| `var` | **0** |
| classes | 0 |

The six textual matches for `var` are all the English phrase "env var" in a comment or a test
name. So the inversion is exact: `logic.js` is 202 `var` and zero `const`; the tooling is 808
`const` and zero `var`. **Neither file's rules are a style opinion you can carry to the other.**

Classes are the one construct absent from both. Nothing here needs instance state; the tooling is
pure functions over paths and strings, exported and called.

## Two module systems, split by directory

| Tree | System | Files | Marker |
|---|---|---|---|
| `lore/_tools/` | CommonJS | 10 | `require(…)`; `module.exports` in 4 of the 5 modules — `cli.js` is the executable |
| `scripts/` | ESM | 8 | `import … from`, `.mjs` extension |

This is not drift. `lore/_tools/` is vendored from the witan-household template and stays on its
upstream module system so an update applies cleanly; `scripts/*.mjs` uses the extension that
makes ESM work without a `"type": "module"` field in any enclosing `package.json`. **Match the
directory you are editing.** Three `lore/_tools/` files also carry `'use strict'`; add it when
you add a file there.

## Zero runtime dependencies, built-in test runner

`lore/_tools/package.json` declares no `dependencies` and no `devDependencies`. Its only script
is:

```json
"test": "node --test __tests__/*.test.js"
```

Tests use `node:test` and `node:assert` — no framework, no config file. Nine test files,
`*.test.js` beside the tooling in `__tests__/`, `*.test.mjs` next to the script in `scripts/`.

**Do not add a dependency to this tree.** These scripts run before anything is installed, on a
machine that may have nothing but `node` and `git`; a dependency turns a working checkout into a
broken one.

## Running the checks

Only the `make` targets are valid entry points. A bare `node lore/_tools/cli.js validate` from
the repository root resolves to a nonexistent `./knowledge` and **exits zero having read
nothing**, and the individual `_tools/*.js` files are modules with no CLI entrypoint. Use
`make validate` and `make doctor`. `CLAUDE.md` carries this rule too, because it is the one that
produces a false pass.

## See Also

- [[languages/javascript/code-style]] — the other body of JavaScript, and why it is ES5.
- [[adrs/0004-qt-compatibility-floor]] — the floor that binds `logic.js` and not this tree.
- [[general/testing]] — Omascape's own test tiers, which none of this tooling is part of.
