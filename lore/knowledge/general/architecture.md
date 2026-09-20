---
title: Architecture — one composition root, one pure logic module
description: Overview.qml is the only component that composes others, owns the theme and is the only file allowed to touch Hyprland; every other component is a leaf configured by properties, and all decisions and maths live in the pure logic.js.
tags: [architecture, qml, quickshell, javascript, omarchy]
---

# Architecture — one composition root, one pure logic module

Omascape is a single Omarchy plugin: `manifest.json` plus QML plus one JavaScript module, loaded
into the running Quickshell shell. There is no build step and no bundler — the files in the
repository are the files that run. Counts below were taken 2026-09-20 against `origin/main`.

Production code is **2048 lines of `logic.js`** and **4000 lines of QML** across ten root-level
`.qml` files. Tests are 11412 lines, more than both together.

## Overview.qml is the only composite

Of the ten production components, **nine instantiate at most one sibling**; `Overview.qml`
instantiates nine. The dependency graph is a DAG three deep at its worst:

```
Overview ──> ContextMenu ──> SoftShadow
         ──> PeekLayer ──> WindowTile ──> SoftShadow
         ──> FindBar, HintCap, LockFrame, OmascapeConfig, OmascapeLocks, SoftShadow, WindowTile
```

**No leaf reaches back up.** Grepping the seven leaf components for `Overview.` finds seven hits
and every one is inside a `//` comment — there is not a single runtime reference from a leaf to
the root. A leaf that needs something asks for it as a property, and a leaf that needs to report
something declares a signal. There are six signals in the whole codebase
(`ContextMenu.qml:24-25`, `OmascapeLocks.qml:15-17`, `WindowTile.qml:31`).

The rules that follow from this:

- **A new component is a leaf.** It declares what it needs as properties, and `Overview.qml`
  binds them. It does not import a sibling, read the root's state, or reach through `parent`
  for anything but layout.
- **Wiring lives in `Overview.qml`.** That is why it is 2873 lines: it is the composition root,
  not a god object by accident.
- **Only `Overview.qml` talks to the compositor.** All 22 `Hyprland.dispatch` calls and every
  other `Hyprland.*` access are in that one file. No other component imports
  `Quickshell.Hyprland`.
- **Only `Overview.qml` knows the theme.** See [[frameworks/quickshell/theming-and-motion]].

## logic.js holds the decisions; QML holds the wiring

`logic.js` is a `.pragma library` with no imports. Geometry, the reconcile diff, search ranking,
key handling and every compositor command string are computed there, and it may never name a QML
or Quickshell type — see [[languages/javascript/code-style]].

Five of the ten components import it, with a byte-identical line, `import "logic.js" as Logic`:
`Overview.qml:8`, `OmascapeConfig.qml:4`, `OmascapeLocks.qml:4`, `LockFrame.qml:4`,
`PeekLayer.qml:2`. There are **136 `Logic.*` call sites**, 116 of them in `Overview.qml`.

The payoff is the test pyramid: because the maths is in a plain JS module, 188 of the 532 test
functions load it directly with no Qt scene at all. See [[general/testing]].

Compositor commands are the same idea taken one step further — they are *built* as Lua strings
in `logic.js` and only *dispatched* from QML, which is what makes them testable without a
compositor. See [[languages/lua/chunk-authoring]] and
[[adrs/0002-compositor-dispatch-errors]].

## Where state lives

| State | Owner | Form |
| --- | --- | --- |
| User settings | `OmascapeConfig.qml` | `~/.config/omarchy/omascape.json`, read-only, watched |
| Armed workspaces | `OmascapeLocks.qml` | `~/.config/omarchy/omascape-locks.json`, atomic write |
| Share-active flag | compositor-side observer | `$XDG_RUNTIME_DIR/omascape/share-state` |
| Everything else | `Overview.qml` | in-memory, lost on shell restart |

Each persisted file has exactly one writer, by lifetime rather than by lock — see
[[adrs/0005-lock-state-persistence]]. `README.md` § What it touches on your system is the
user-facing statement of the same surface; keep the two in step.

## What is not documented anywhere else

`DESIGN.md` is an append-only log of dated design sections, not a current-state document — the
architecture sections near the top describe the v1 build and have not been revised since. Per
feature, `docs/specs/` is authoritative, and QML comments cite it: 20 `docs/specs/` references
across eight of the ten components. When a comment and `DESIGN.md` disagree, the comment and the
spec it cites are newer.

## See also

- [[frameworks/quickshell/component-patterns]] — how an individual component is written.
- [[general/testing]] — how the layering is exploited by the test tiers.
- [[general/release-and-distribution]] — how this repository reaches users.
- [[adrs/0004-qt-compatibility-floor]] — the QML dialect the whole tree must stay inside.
- [[frameworks/hyprland/compositor-state]] — what the root does with the compositor access it
  keeps to itself, and why the models need refreshing by hand.
