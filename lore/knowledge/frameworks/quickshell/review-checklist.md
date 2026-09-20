---
title: Quickshell review checklist
description: What to check on a QML change here — Qt 6.4 validity, leaf components that neither size nor theme themselves, no literal duration or colour at a use site, `visible:` rather than Loader, a UI suite registered in tests/ui/run.sh, and the manifest entry point still resolving.
tags: [frameworks, quickshell, qml, review, testing]
---

# Quickshell review checklist

The short form of [[frameworks/quickshell/component-patterns]] and
[[frameworks/quickshell/theming-and-motion]], ordered by how expensive the mistake is to find
later. Everything here is a rule the tree currently follows.

## Will it compile on CI?

CI's Qt is the authority and it is older than the local one — see
[[adrs/0004-qt-compatibility-floor]]. A local pass is not evidence.

- [ ] No legacy reserved word used as an identifier: `long`, `short`, `int`, `char`, `float`,
      `double`, `byte`, `boolean`, `final`, `native`. Fine locally, a syntax error on CI.
- [ ] No property newer than Qt 6.4. Per-corner radius (`topLeftRadius` and friends) and
      per-side borders are 6.7+ — draw the effect another way.
- [ ] No typed function signature (`function f(x: int): void`). Signals take types; functions
      do not.
- [ ] `gh pr checks` after the push. An unknown property is a compile error, not a warning, and
      the failure names a property that plainly exists on your machine.

## Is the component still a leaf?

- [ ] It does not instantiate a sibling, read `Overview`'s state, or reach through `parent` for
      anything but layout. Values come in as properties; news goes out as a signal.
- [ ] It does not size itself — no `anchors.fill: parent` on the root. The caller sizes it.
- [ ] Root `id` is a short descriptive noun, not `root`. `root` belongs to `Overview.qml`.
- [ ] Imports are unversioned, ordered `QtQuick` → submodules/`Quickshell*`/`qs.*` →
      `"logic.js" as Logic`, and it imports nothing it does not use.
- [ ] Only `Overview.qml` gained `Hyprland.*` calls, `qs.Commons`/`qs.Ui` imports, or new
      functions. See [[general/architecture]].

## Are the contracts intact?

- [ ] No literal in a `duration:` or `easing.type:` — both dereference `motion`, and
      `fast` pairs with `hover`, `normal` with `move`.
- [ ] Every `Behavior` carries an `enabled:` guard.
- [ ] A new animating component declares `required property QtObject motion` and the caller
      binds it.
- [ ] A hex literal is the default of a `property color` declaration — or, at a use site, half
      of a self-contained fixed pair like the title plate's white-on-black
      (`WindowTile.qml:271-272`). A lone literal over a themed surface is a bug.
- [ ] A new `Color.<namespace>` reference has a matching rewrite in `tests/ui/prepare.py`. An
      unresolved `Color.*` is a runtime warning, not a compile error — it renders wrong and the
      suite still passes.

## Structure and lifetime

- [ ] Properties, then signals, then functions, then children.
- [ ] No `Loader`, inline `Component {` or `sourceComponent`. Show and hide with `visible:`;
      use `Repeater`, or `Variants` for per-screen surfaces.
- [ ] A new `FileView` sets `watchChanges`, `printErrors: false`, `onFileChanged: reload()` and
      an `onLoadFailed` that applies a safe default.
- [ ] A new `Process` collects through `StdioCollector` and hands the raw text to a `Logic.*`
      parser — no parsing in QML.
- [ ] Anything a test needs to find has a stable `objectName`.

## Logic and the compositor

- [ ] Decisions and maths went into `logic.js`, not the QML — see
      [[languages/javascript/code-style]].
- [ ] A new compositor command is a `*Lua()` builder dispatched through `run(`, not a bare
      `hl.dispatch` — see [[adrs/0002-compositor-dispatch-errors]] and
      [[languages/lua/chunk-authoring]].

## Before merge

- [ ] `mise run test` passes, and any new `tests/ui/*.qml` suite has its `cp` line in
      `tests/ui/run.sh` — without it the suite never runs and nothing says so. See
      [[general/testing]].
- [ ] `omarchy plugin validate .` passes: `manifest.json` still points at an entry-point file
      that exists, and no symlink was committed. See [[general/release-and-distribution]].
- [ ] The comment block cites the `docs/specs/` file the change implements.
- [ ] The PR body names which of the manual checks in `README.md` § Testing were run — no tier
      covers them.

## See also

- [[learnings/right-click-cancels-a-mousearea-drag]] — the cancel path a `MouseArea` change must keep clean.
- [[learnings/item-owns-a-final-layer-property]] — check a new property name against `Item` first.

- [[general/testing]] — which tier a new test belongs in.
- [[learnings/plugin-hot-reload-serves-cached-source]] — why you are not seeing your change.
