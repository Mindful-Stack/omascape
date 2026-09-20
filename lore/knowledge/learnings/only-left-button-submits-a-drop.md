---
title: "Only Qt.LeftButton may submit a drop"
description: "The tile MouseArea accepts left, middle and right so one area can serve drag, close and the context menu; every release path therefore guards on Qt.LeftButton explicitly, because a right release during a left drag would otherwise submit a drop instead of opening the menu."
tags: [frameworks, quickshell, qml, ui]
confidence: verified
source: developer-input
date: 2026-09-20
---

# Only `Qt.LeftButton` may submit a drop

Verified 2026-09-20 against `origin/main`. A window tile's `MouseArea` sets:

```qml
acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
```

One area serves three gestures — drag and drop, middle-click close, and the right-click context
menu — so **every release path guards on the button explicitly**:

```qml
onReleased: {
    if (m.button !== Qt.LeftButton) return
    …submit the drop or the click…
}
```

## The bug this prevents

The pre-actions behaviour treated every non-middle release as a possible drop. Press left, begin
dragging a tile, then press and release right: the right release reached the drop path and
**submitted the drop** at wherever the tile happened to be, instead of opening the context menu.
The window moved, and the menu the user asked for never appeared.

`if (m.button !== Qt.LeftButton) return` is the whole fix, and it has to be repeated per handler
rather than hoisted, because each handler serves a different button:

| Handler | Right | Middle | Left |
|---|---|---|---|
| `onPressed` | opens the window menu, returns | — | begins the grab |
| `onReleased` | falls to the left-button guard and returns | closes the window | drops, or counts as a click |
| `onDoubleClicked` | — | — | the only button that activates |

The reasoning sits in the code at the guard itself: *"Only the LEFT button ever drops or counts
as a click. Before the right button was accepted here, every non-middle release was treated as a
possible drop — a right click during a left drag would have moved the window."*

## The rule

**Widening `acceptedButtons` on an area that already owns a gesture means auditing every handler
on it**, not just the one you are adding. `onPressed`, `onReleased` and `onPositionChanged` each
decide independently which buttons they serve.

## See also

- [[frameworks/quickshell/review-checklist]] — what to check in a component before merging.
- [[domain/targeting-and-pointer-liveness]] — the keyboard half of "what does this act on".
- Implementation: the tile `MouseArea` in `Overview.qml`; drag coverage `tests/ui/drag.qml`,
  actions coverage `tests/ui/actions.qml`.
