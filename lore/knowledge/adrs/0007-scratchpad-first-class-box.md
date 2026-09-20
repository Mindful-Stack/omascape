---
title: "ADR-0007: The scratchpad is a first-class box behind a constant id"
description: "Hyprland allocates special-workspace ids dynamically, so buildInput identifies the scratchpad by name and remaps it onto the constant -2; the cost was making -1 the only \"no workspace\" sentinel across the codebase, which is why hasWs() exists."
tags: [adr, architecture, javascript, compositor, domain]
status: accepted
date: 2026-09-20
deciders: [Daniel Thyselius]
confidence: high
---

# ADR-0007: The scratchpad is a first-class box behind a constant id

## Status

Accepted (retrospective) 2026-09-20; the decision predates this record. Design:
`docs/specs/2026-09-12-scratchpad-design.md`. First dependent code: `logic.js` `SCRATCHPAD_ID`,
`buildInput()` in `Overview.qml`.

## Context

Hyprland's special workspaces do not have stable ids. `WorkspaceQueryCore.cpp` allocates the next
free id below -99, so the id the compositor reports for `special:scratchpad` is not stable across
sessions — and not even across the scratchpad emptying and refilling.

The overview keys everything on workspace id: boxes, tiles, selection, pending drops, the find
index, the lock set. An unstable id therefore cannot be carried through the pipeline, and a
synthetic empty scratchpad row would have a different id from the real one that replaces it,
producing a transition to handle at exactly the moment the user is looking at it.

Meanwhile the codebase used `id >= 0` in several places to mean "has a workspace", which is a
different test that happened to agree while every real id was positive.

## Considered options

- **A side channel.** Keep the scratchpad out of the box/tile pipeline and render it as a special
  case, so no id question arises and no existing check changes.
- **Carry the compositor's reported id.** Use whatever Hyprland says, and re-key downstream state
  whenever it changes.
- **A first-class box behind a constant id.** Identify the scratchpad by *name* at the boundary
  and remap it, and everything it holds, onto a constant the rest of the code can rely on.

## Decision

**The scratchpad flows through the existing box/tile pipeline, keyed on `Logic.SCRATCHPAD_ID =
-2`.** `buildInput()` identifies it by name and remaps both its reported id and the `workspaceId`
of every window on it. Thumbnails, drag, find, the selection frame and the lock treat it exactly
like any other workspace, and a synthetic empty row and a real scratchpad share one id, so there
is no transition.

`-2` cannot collide: regular ids are ≥ 1, `-1` is the "none" sentinel, and Hyprland's special ids
are ≤ -99.

**Dispatches use the name, never the id.** `Logic.wsSelector(id)` returns `"special:scratchpad"`
for `SCRATCHPAD_ID` and the numeric id otherwise; `jump()` routes the scratchpad id to the show
chunk and never to a workspace focus, so `Enter` and a box click share one guard.

**The price was paid once, as an audit.** `Logic.hasWs(id)` — `typeof id === "number" &&
isFinite(id) && id !== -1` — replaces every `>= 0` test that meant "has a workspace". The
invariant is now: **`-1` is the only sentinel; a negative id is not automatically "none".** Places
that must genuinely exclude specials keep an explicit test (`padWorkspaces`,
`_orderedMonitorNames`, the monitor-group loop in `layout`, the digit keys).

## Consequences

- **`hasWs()` is load-bearing, not a convenience wrapper.** 15 call sites across `logic.js` and
  `Overview.qml`, and no `>= 0` workspace test survives — the only remaining match on `main` is
  the comment above `hasWs` describing what it replaced. Writing `id >= 0` again silently
  excludes the scratchpad from whatever that code does.
- **New code must pick a test deliberately.** "Has a workspace" is `hasWs()`. "Is a real numbered
  workspace" is an explicit specials check. The two are no longer the same expression.
- The remap happens at one boundary, so anything reading the compositor's own workspace list
  before `buildInput()` sees the unstable id. Nothing downstream should.
- Pending-drop reconciliation works without special-casing: a pending move targeting
  `SCRATCHPAD_ID` is acknowledged when `buildInput()` reports the window on `SCRATCHPAD_ID`,
  which the remap guarantees whatever id Hyprland allocated. The deadline logic is untouched.
- Drop planning needed one explicit bypass: `updateDropTarget()` skips `tiledDropPlan` when the
  target is `SCRATCHPAD_ID`, so a tiled source over the scratchpad shows the workspace wash
  rather than an insertion half.
- Reversing this now means re-auditing every `hasWs()` call site, which is what makes it
  expensive rather than merely tedious.

## Assumptions and invalidation triggers

- *Assumes only one special workspace matters.* Trigger: a second named special workspace has to
  appear in the grid ⇒ amend; one constant becomes a small set, and `isScratchpad` stops being
  the right question.
- *Assumes Hyprland keeps allocating special ids below -99.* Trigger: a Hyprland release
  allocates a special id in the `-1`/`-2` range ⇒ supersede; the constant would collide.
- *Assumes the name `special:scratchpad` is stable.* Trigger: Hyprland renames or namespaces
  special workspaces ⇒ amend the name constants.
- *Assumes `-1` can stay the only "none".* Trigger: a second sentinel is needed for a distinct
  "unresolved" state ⇒ amend, and `hasWs` grows a case.

## See also

- [[domain/ubiquitous-language]] — well, box, synthetic, and what "none" means.
- [[domain/targeting-and-pointer-liveness]] — `hasWs()` gates both terminal workspace branches
  of the target resolver.
- [[general/workspace-grid-defaults]] — how synthetic wells and the scratchpad row coexist.
- [[adrs/0005-lock-state-persistence]] — why a selector is a string, so `"3"` and
  `"special:scratchpad"` share one representation.
- `docs/specs/2026-09-12-scratchpad-design.md` § Sentinel audit — the original list of sites.
  Implementation: `logic.js:1560-1568`; UI fixture `tests/ui/scratchpad.qml`.
