---
title: "ADR-0008: The overlay stays loaded between summons"
description: "manifest.json sets keepLoaded: true, so the component outlives close(): the exit fade can finish, the reconcile tail can clear optimistic state, and the share reminder frame can exist at all — at the cost of cross-summon state that open() must reconcile rather than assume away."
tags: [adr, architecture, quickshell, qml, omarchy]
status: accepted
date: 2026-09-20
deciders: [Daniel Thyselius]
confidence: high
---

# ADR-0008: The overlay stays loaded between summons

## Status

Accepted (retrospective) 2026-09-20; the decision predates this record. Recorded in
`manifest.json` as `"keepLoaded": true`. First dependent code: `Overview.qml`'s `close()` tail
and the `LockFrame` `Variants` block.

## Context

Omascape is an Omarchy overlay plugin. An overlay is summoned, used and dismissed, and the
obvious lifecycle is to load it on summon and unload it on close — nothing running when the user
is not looking at it, which is also what the plugin's own description promises ("nothing runs
until you summon it").

Three things turned out to need the component alive while the picker is not on screen.

The **exit fade** is an animation that runs after `close()`. The **reconcile tail** clears
optimistic display state — `pendingMoves`, `fsPending`, `pendingCloses` — on deadlines up to
1.8 s, so a re-summon inside that window shows authoritative state rather than a stale optimistic
one. And the **share-time reminder frame** is not part of the picker at all: it is four
layer-shell strips per screen that must be on screen *while a share runs*, whether or not the
picker is open.

## Considered options

- **Unload on close.** Nothing runs between summons. The exit fade has to become instant or be
  faked, optimistic state is discarded rather than reconciled, and the reminder frame needs a
  separate always-loaded component or a second plugin.
- **Keep loaded.** The component persists; everything above works as ordinary QML; the cost is
  that state now survives a summon and has to be handled deliberately.

## Decision

**`keepLoaded: true`.** The component outlives `close()`, and the parts that are not the picker
are gated on that fact — the `LockFrame` `Variants` block lives outside the overview's own
`PanelWindow` precisely because the manifest keeps the component alive.

**No compositor operation depends on it.** Every compositor operation is a single atomic Lua
chunk that completes on its own (see [[adrs/0002-compositor-dispatch-errors]]), so nothing
in-flight is orphaned by an unload. `keepLoaded` buys UI lifetime, not transactional safety, and
the two must not be conflated.

**What survives a summon is reconciled, not assumed.** `open()` re-derives the models from fresh
compositor data rather than trusting what is there, and anything whose carry-over would be wrong
is reset explicitly.

## Consequences

- **Cross-summon state exists, and every new property has to answer for it.** `tilesModel` and
  `boxesModel` are reconciled in place and their delegates persist across rebuilds — which is
  also why the bar-mode entrance progress is root-level: a per-delegate
  `Component.onCompleted` would fire once at startup and never again.
- **Scroll position leaks unless it is reset.** `open()` sets `flick.contentX/contentY` to 0 with
  the reason in the line itself. Anything similar needs the same treatment.
- **Some carry-over is deliberate.** `hintsExpanded` survives a summon but not a shell restart,
  and is deliberately not written to config — a transient affordance, not a preference.
- **Captures are gated on visibility, not on lifetime.** `capMode: (panel.visible && !boxArmed) ?
  "live" : "icon"` — the component being loaded does not mean it is capturing. This is what keeps
  "nothing runs until you summon it" true while the component is resident.
- Turning `keepLoaded` off would not merely change performance: the share reminder frame would
  stop existing between summons, which is the feature working exactly backwards.
- The component holds memory for the whole session. Nothing measures that today.

## Assumptions and invalidation triggers

- *Assumes a resident overlay's idle cost is negligible.* Trigger: the resident component shows
  measurable CPU or memory cost while the picker is closed ⇒ amend, and move the always-on parts
  into their own lightweight component.
- *Assumes Omarchy keeps honouring `keepLoaded`.* Trigger: the host unloads plugins regardless
  ⇒ supersede; the reminder frame needs another home.
- *Assumes no compositor operation ever needs to outlive a chunk.* Trigger: an operation that
  cannot be expressed as one atomic chunk ⇒ amend, and the lifetime becomes load-bearing for
  correctness rather than only for UI.
- *Assumes cross-summon carry-over stays small enough to enumerate.* Trigger: a bug caused by
  state surviving a summon that nobody remembered ⇒ amend, and `open()` gets an explicit reset
  list rather than reset lines scattered through it.

## See also

- [[general/architecture]] — the composition root that holds all of this state.
- [[adrs/0002-compositor-dispatch-errors]] — why no operation depends on the component's lifetime.
- [[adrs/0009-live-window-previews]] — what `panel.visible` gates, and why.
- [[frameworks/quickshell/component-patterns]] — lifetime by `visible:` rather than `Loader`.
- [[general/release-and-distribution]] — `manifest.json` is also the file a failed validation
  strands users on.
