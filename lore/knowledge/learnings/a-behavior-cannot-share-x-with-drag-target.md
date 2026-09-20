---
title: "A Behavior cannot share x/y with drag.target"
description: "The tile glide runs on separate targetX/targetY properties because a Behavior on x fights the drag's direct writes, and gating it on !dragging is not enough: a disabled Behavior does not stop a transition already in flight, and the QML binding re-asserts on its next tick."
tags: [frameworks, quickshell, qml, ui]
confidence: verified
source: developer-input
date: 2026-09-20
---

# A `Behavior` cannot share `x`/`y` with `drag.target`

Recorded from `docs/specs/2026-09-10-motion-design.md` § Tile glide vs drag, where it was found
while building the settle animation.

A `MouseArea` drag writes the target's `x`/`y` directly from C++. Putting a `Behavior on x` on
the same property makes the two fight: the drag writes a position, the Behavior animates towards
it, and the tile lags the pointer. The obvious fix — `enabled: !dragging` on the Behavior — does
not work, for two reasons:

- disabling a `Behavior` does not stop a transition that is already in flight, and
- the C++ drag write leaves the QML binding installed, so the glide re-asserts on its next tick.

## What the code does instead

The glide runs on separate `targetX`/`targetY` properties. `beginGrab` detaches `x`/`y` with a
plain write and the drag owns them; release parks the targets at the drop point and rebinds them
to the model, and that rebind *is* the settle. The `Behavior` never sees a drag write.

Two neighbours of the same rule, from the same spec:

- **Boxes are reconciled, never recreated.** A `Repeater` over a plain array recreates every
  delegate on rebuild, at its new position, so a tile gliding into a box that has already jumped
  looks wrong. Boxes are an address-keyed `ListModel` reconciled in place, like tiles.
- **`ListModel.set` with equal values still emits.** `Behavior`s fire on *changes*, and a rebuild
  that re-sets identical values would still trigger them. Compare before setting.

## See also

- [[frameworks/quickshell/theming-and-motion]] — the root-owned `motion` object every animation dereferences.
- [[learnings/listmodel-roles-are-fixed-at-first-append]] — the other `ListModel` trap.
- [[learnings/right-click-cancels-a-mousearea-drag]] — the other thing the drag machinery cannot control.
