---
title: Quickshell component patterns
description: A component is a leaf with a descriptive root id, its properties grouped at the top, no size of its own and no knowledge of the theme; non-visual components are a QtObject holding typed FileView/Process properties, and lifetime is `visible:` rather than Loader.
tags: [frameworks, quickshell, qml, architecture]
---

# Quickshell component patterns

How an individual `.qml` file is written here. [[general/architecture]] covers how they fit
together. Measured 2026-09-20 across the ten production components at the repository root
(4000 lines); `tests/` excluded.

## Imports

Unversioned Qt 6 form, never pinned — 0 of 10 files carry a version on any import. Fixed order:
`QtQuick` first, then Qt submodules and `Quickshell*`/`qs.*`, then the relative `logic.js` last.

```qml
import QtQuick
import Quickshell
import Quickshell.Io
import "logic.js" as Logic
```

There are **no `pragma` statements** of any kind — no `pragma Singleton`, no
`pragma ComponentBehavior`.

**Import only what the component genuinely uses.** Four of the ten are pure `QtQuick`, and
`PeekLayer.qml:7-8` states the reasoning as a rule: *"No Quickshell import here: everything that
touches a wl toplevel or a layer-shell surface is WindowTile's business, not this component's."*
`Overview.qml` is the only file importing the host shell's `qs.Commons` / `qs.Ui`.

## The root element

A short descriptive lowercase `id` naming the thing — `menu`, `bar`, `cap`, `frame`, `cfg`,
`locks`, `peek`, `tile`. `Overview.qml` uses `id: root`, which is correct for the composition
root and should not be copied into a leaf. `SoftShadow.qml` declares no root `id`, which is
tolerable only because it is 17 lines with no internal references.

**A component does not size itself.** No root `Item` sets `anchors.fill: parent`; sizing is the
caller's job, stated at `PeekLayer.qml:9-11`. The one root-level `anchors.fill` in the tree is
`SoftShadow.qml:10`, filling its `target` property rather than its parent.

`LockFrame.qml:45` roots at `Scope` because it owns four `PanelWindow` surfaces; `QtObject` roots
the two non-visual components. Everything else is `Item`, or `Row` for the one pure positioner.

## The public surface comes first

Properties, then signals, then functions, then child elements — in five of the six components
small enough to test the claim mechanically. 265 property declarations across the tree: 170
plain, 79 `readonly`, 16 `required`, **0 `default property`** and one `property alias`
(`WindowTile.qml:143`).

`required property` has exactly two uses: `modelData` / `model` / `index` inside a `Repeater`
delegate, and the cross-component `motion` contract (see
[[frameworks/quickshell/theming-and-motion]]).

**Signal parameters are typed; function signatures are not.** All four parametered signals
declare types — `signal activated(string id)`, `signal writeFailed(string why)` — while all 120
function declarations use the untyped `function name(args)` form, with zero typed signatures
anywhere. Keep both halves: the typed form on a function is a Qt 6.4 compatibility risk that
buys nothing here.

Functions belong to the composite. `Overview.qml` holds 108 of the 120; the four display-only
components (`FindBar`, `HintCap`, `LockFrame`, `SoftShadow`) declare none. A leaf that needs a
function is usually a leaf that has been handed the wrong property.

The `_` prefix marks private-by-convention, and is used sparingly — `Overview.qml:1287
_reconcileStep()`, `:1650 _showVisuals()`, and the `root._clsByAddress` family of backing
properties.

## Non-visual components: QtObject holding typed instances

`QtObject` has no default children property, so a `FileView` or `Process` cannot be a plain child.
Both `OmascapeConfig.qml` and `OmascapeLocks.qml` use a typed property instead, and every
instance in the tree follows that shape:

```qml
property FileView file: FileView { … }
property Process wallpaperProc: Process { … }
```

Four `FileView`, two `Process`, zero `IpcHandler`. Every `FileView` carries the same four
settings — `watchChanges: true`, `printErrors: false`, `onFileChanged: reload()`, and an
`onLoadFailed` that applies a safe default rather than leaving the property undefined. Every
`Process` collects with `stdout: StdioCollector { waitForEnd: true; onStreamFinished: … }` and
hands the raw text straight to a `Logic.*` parser — no parsing in QML.

## Lifetime is `visible:`, not create-and-destroy

**There is no `Loader`, no inline `Component {`, and no `sourceComponent` in production code** —
the only delegate mechanisms are `Repeater` (11) and `Variants` over `Quickshell.screens` (2).
Components are created once and shown or hidden. `LockFrame.qml:19-20` gives the reason:
*"Existence is 'visible:', never create/destroy: mapping and unmapping a layer surface per share
edge is what the hysteresis exists to avoid in the first place."*

That reason is layer-shell-specific but the convention is tree-wide, and it is what makes the
offscreen fixture viable — see [[general/testing]].

The layer-shell triple is copy-identical on all five static surfaces:

```qml
WlrLayershell.layer: WlrLayer.Overlay
WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
exclusionMode: ExclusionMode.Ignore
```

`Overview.qml:1832` is the one dynamic variant, switching `keyboardFocus` to `OnDemand` while
open.

## objectName is the test handle

24 `objectName:` assignments across six files (`FindBar.qml:29 objectName: "findGlyph"`,
`Overview.qml:2283 objectName: "wsBox"`). **None is read by production QML** — they exist so the
offscreen fixture can find an element without depending on layout. Add one when you add
something a test will need to locate; keep the string stable, because the suite depends on it.

## Comments

Every comment is a `//` line comment — **zero block comments** in 4000 lines, no QDoc headers.
Density is 33.7% full-line comments and blank lines are rare (2.8%). Eight of ten files open
with a prose block between the imports and the root element, and 20 comments cite the
`docs/specs/` file the code implements, usually in that block's first line:

```qml
// Right-click menu (docs/specs/2026-09-15-actions-design.md).
```

Cite the spec. It is the only link between a component and the reasoning behind it.

## See also

- [[frameworks/quickshell/theming-and-motion]] — the colour and animation contracts.
- [[frameworks/quickshell/review-checklist]] — the short form, for review.
- [[adrs/0004-qt-compatibility-floor]] — the dialect limits all of this sits inside.
- [[learnings/plugin-hot-reload-serves-cached-source]] — why editing a component needs a restart.
- [[frameworks/hyprland/compositor-state]] — what a leaf may assume about a `HyprlandMonitor`
  handed to it, and what it must not.
- [[adrs/0009-live-window-previews]] — `WindowTile` as the worked example: a leaf handed a
  capture handle as a property.
