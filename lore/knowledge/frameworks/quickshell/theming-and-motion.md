---
title: Quickshell theming and motion
description: Only Overview.qml knows the theme and the motion timings; leaves take overridable `property color` defaults and a `required property QtObject motion`, so no duration, easing or real colour is ever a literal at a use site.
tags: [frameworks, quickshell, qml, ui, omarchy]
---

# Quickshell theming and motion

Two contracts with the same shape: the composition root resolves a value once, and every leaf
receives it as a property. Measured 2026-09-20 across the ten production components.

## Colour: leaves declare defaults, the root supplies the truth

Real colours come from the host shell's singletons, `Color` (from `qs.Commons`) and `Style` (from
`qs.Ui`), and **`Overview.qml` is the only file that imports either**:

```qml
// Overview.qml:71-81 — theme — tone steps, not lines
property color background: Color.menu.background
property color foreground: Color.menu.text
property color scrim: Color.menu.scrim
property color barBackground: Color.bar.background
```

Derived shades go through two helpers rather than more tokens —
`function tone(a) { return Qt.rgba(foreground.r, foreground.g, foreground.b, a) }`
(`Overview.qml:82`) and `glass(a)` (`:93`, which calls `Logic.glassMix`) — feeding `wellColor`,
`hairline`, `badgeColor` and the rest. Alpha steps use a `Style.*` token where one exists
(`Style.normalFillAlpha`) and a bare number otherwise.

A leaf never sees any of that. It declares an overridable default and the root binds over it:

```qml
// ContextMenu.qml:15-18
property color background: "#222"
property color foreground: "#ddd"
property color selBackground: "#444"
property color selText: "#fff"
```

`HintCap.qml:3-4` states the rule: *"the colours and fonts come from the Overview root, which is
the only thing that knows the theme."*

**A hex literal is a default on a `property color` declaration** — 17 of the 18 hex literals in
the tree are exactly that. The single use-site hex is `WindowTile.qml:272`, and it is legitimate:
the hover title `Text` is `"#fff"` because it sits on a deliberately theme-independent plate,
`color: Qt.rgba(0, 0, 0, 0.55)` on the line above. White-on-black is the contract there, so
theming either half would break it. That is the only shape in which a use-site literal is
correct — a self-contained pair where both colours are fixed together. A lone literal over a
themed surface is a bug. `"transparent"` at a use site is always fine (10 uses).

The practical reason this matters beyond tidiness: **an unresolved `Color.*` reference does not
fail to compile.** It is a runtime `QWARN` and the element renders wrong while the test suite
passes. `tests/ui/prepare.py` greps for surviving `Color.` references precisely because nothing
else would catch it — so a new `Color.<namespace>` needs a rewrite added there too. See
[[general/testing]].

## Motion: one definition, guarded behaviours, no literals

Every timing lives once, in a `readonly property QtObject motion` at `Overview.qml:243-261`:

```qml
readonly property QtObject motion: QtObject {
    property real scale: 1
    readonly property bool enabled: config.motionEffective !== "off" && config.motionResolved && scale > 0
    readonly property int fast:   enabled ? Math.round(90 * scale) : 0
    readonly property int normal: enabled ? Math.round(160 * scale) : 0
    readonly property int enter:  enabled ? Math.round(200 * scale) : 0
    readonly property int exit:   enabled ? Math.round(120 * scale) : 0
    readonly property int move: Easing.OutCubic     // layout movement
    readonly property int hover: Easing.OutQuad     // hover, lift, release
    readonly property int entrance: Easing.OutBack
}
```

It is passed down explicitly (`motion: root.motion`) into a `required property QtObject motion`
slot — `ContextMenu.qml:22`, `PeekLayer.qml:43`, `WindowTile.qml:56`. `required` is the right
qualifier: a component that animates cannot be instantiated without being told how.

The rules this enforces, all of them currently exceptionless:

- **No literal durations or easings.** All 34 `duration:` and all 35 `easing.type:` occurrences
  dereference `motion`. A number in a `duration:` is a bug.
- **Pair the token with its easing.** `motion.fast` always goes with `motion.hover`;
  `motion.normal` always with `motion.move`. Do not mix them.
- **Every `Behavior` is guarded.** There is no unguarded `Behavior` in the tree. The guard is on
  the `Behavior` line and the `NumberAnimation` on the next:

  ```qml
  Behavior on opacity { enabled: menu.motion.enabled
      NumberAnimation { duration: menu.motion.fast; easing.type: menu.motion.hover } }
  ```

  Layout movement uses the coarser `root.layoutMotion` gate instead
  (`Overview.qml:2287`), and the distinction is documented at `Overview.qml:262-268`.
- **`NumberAnimation` only.** `PropertyAnimation`, `SequentialAnimation` and `Transition` are
  never used, and `states`/`State` is effectively absent (one match in 4000 lines). Animation is
  26 `Behavior on` blocks, 35 `NumberAnimation`s and 3 `ParallelAnimation`s. Reaching for a state
  machine here would be a new pattern, not an existing one.

`motion.enabled` folding to `0` rather than disabling the `Behavior` is deliberate: the animation
still runs, instantly, so nothing has to branch on whether motion is on. `motion.scale` and the
`config.motionResolved` gate come from `OmascapeConfig.qml`, which probes the compositor's own
animation setting before the first frame.

## See also

- [[frameworks/quickshell/component-patterns]] — where these properties sit in a component.
- [[general/architecture]] — why only the root resolves either contract.
- [[general/workspace-grid-defaults]] — another root-owned display default.
