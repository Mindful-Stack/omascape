---
title: "A right click cancels a MouseArea drag, and QML cannot stop it"
description: "A MouseArea's exclusive grab is cancelled the instant a second accepted button completes a press-release while the first is held, regardless of drag.target; the tile drag relies on onCanceled → endDrag() so the tile returns cleanly, and fixing it properly would mean DragHandler."
tags: [frameworks, quickshell, qml, ui]
confidence: verified
source: developer-input
date: 2026-09-20
---

# A right click cancels a `MouseArea` drag, and QML cannot stop it

Verified against Qt 6.11.2 with a minimal probe, recorded in `DESIGN.md` § Actions. While the
left button is held on a `MouseArea` with `drag.target` set, pressing and releasing any other
accepted button cancels the area's exclusive grab. This is unconditional: it does not matter
which item accepts the second button, and nothing on `MouseArea` opts out of it.

## What the code guarantees instead

The cancellation runs the existing `onCanceled` → `endDrag()` path, so:

- the tile returns to where it came from,
- no drop is submitted, and
- no context menu opens (the right press is consumed by the cancellation).

Right-click-cancels-a-drag is a common enough convention elsewhere that this reads as a feature.
The proper fix — moving the tile drag from `MouseArea`/`drag.target` to `DragHandler` and
`TapHandler` — is a rewrite of the drag machinery and has been ruled out of scope.

## The rule

Any change to what the tile `MouseArea` accepts, or to `endDrag()`, has to keep the cancel path
clean: a cancelled drag must not fall into the drop path. [[learnings/only-left-button-submits-a-drop]]
is the guard on the other side of the same handler.

## See also

- [[learnings/only-left-button-submits-a-drop]] — why every release path guards on the button.
- [[learnings/a-behavior-cannot-share-x-with-drag-target]] — the other thing the drag owns outright.
- [[frameworks/quickshell/review-checklist]] — what to check in a component before merging.
