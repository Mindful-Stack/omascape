---
title: "ADR-0009: Tiles show live Wayland captures, with the icon as a first-class render"
description: "A tile's picture is a ScreencopyView fed by a wl toplevel handle joined to the Hyprland address through ToplevelManager, not by polling hyprctl; the app icon is not an error state but the honest \"no pixels to show\" render, which is what makes an armed workspace's denial look deliberate."
tags: [adr, architecture, quickshell, qml, compositor]
status: accepted
date: 2026-09-20
deciders: [Daniel Thyselius]
confidence: high
---

# ADR-0009: Tiles show live Wayland captures, with the icon as a first-class render

## Status

Accepted (retrospective) 2026-09-20; the decision predates this record. Design:
`docs/specs/2026-09-08-omascape-previews-drag-drop-design.md` § Feasibility. First dependent
code: `WindowTile.qml`'s `ScreencopyView`, `Overview.qml`'s `handleByAddress`.

## Context

v1 drew each window as an icon box. The whole point of v2 was that a tile should show the
window — "each window a real thumbnail in its true position", as the manifest still puts it.

That needs two things the overview did not have: a capture surface, and a way to know *which*
capture belongs to the window Hyprland is telling us about. The overview's model is built from
Hyprland's IPC objects, which are keyed by address; a Wayland screencopy handle is a
`Toplevel` from a different protocol with no Hyprland address on it.

A capture can also be unavailable, and for more than one reason: the window has no handle yet,
the surface is not mapped, or the compositor refuses outright — an armed workspace's windows are
denied capture, which is the whole point of arming one.

## Considered options

- **Poll `hyprctl clients -j` for geometry and drive captures from that**, as the reference
  implementation this was modelled on does.
- **Join the two protocols at the boundary**: iterate `ToplevelManager.toplevels`, read
  `toplevel.HyprlandToplevel.address`, and build an address → handle map the tiles index into.
- **Keep the icon box and drop live previews.** No new protocol surface, no join, no fallback
  policy.

## Decision

**Join the protocols once, in one map.** `Overview.qml` builds `handleByAddress` from
`ToplevelManager.toplevels.values`, keyed by `HyprlandToplevel.address`, and each tile receives
`handle: root.handleByAddress[model.address] || null`. Geometry keeps coming from the Hyprland
IPC objects the overview already reads — **`hyprctl clients -j` polling was explicitly not
adopted**, because v1 already had the data.

**The icon is a render, not an error.** `WindowTile.qml` has three declared capture modes —
`"live"`, `"snapshot"`, `"icon"` — and the icon path is a first-class one: `Quickshell.iconPath`,
its own size cap, its own layout. A tile with no handle and a tile whose capture is refused look
the same, and both look deliberate.

**`hasContent` gates readiness, never correctness.** It means a buffer arrived. It does not
prove the frame is non-black or updating, so it decides *when* to show the capture
(`visible: tile.wantCapture && cap.hasContent`) and never *whether* a capture is trustworthy.
That call is policy, made above the tile.

**Capture is gated on the surface being mapped, not on the component being loaded.**
`capMode: (panel.visible && !boxArmed) ? "live" : "icon"` — see
[[adrs/0008-keep-loaded-overlay]]. An armed box falls back to its icon whether or not a share is
running, because the compositor denies the capture either way; capturing anyway would show the
"permission denied" texture rather than the window.

## Consequences

- **A window Hyprland reports but Wayland has no handle for renders as an icon, with nothing
  logged.** The two protocols can disagree, and the tile's fallback is what absorbs it.
- **The join is by address string, and it is reassembled by hand.** `buildHandles()` writes
  `map["0x" + h.address]` because `HyprlandToplevel.address` arrives without the prefix the
  Hyprland IPC objects carry. Anything that changes either spelling breaks previews **silently**
  — every tile falls back to its icon, which is a working UI, so nothing fails loudly and no test
  outside the fixture would notice.
- **`"snapshot"` is declared and never selected.** `live: tile.capMode === "live"` would make a
  non-live capture work, and the property comment lists the mode, but nothing in the tree sets
  it — the only two values assigned on `main` are `"live"` and `"icon"`. It is a working
  affordance with no caller, not a feature.
- **The icon-then-capture race is visible and had to be handled.** The peek carries an
  `iconGraceMs` opt-in that holds the icon off while a capture is genuinely in flight
  (`wantCapture` true, `cap.hasContent` still false), because the peek opens on every `Space`
  press and the icon would otherwise win for a frame and be yanked away. The grid does not need
  it: its race is over before the eye arrives. **Zero means the icon appears the instant there is
  nothing to show**, which is the honest default.
- Arming a workspace has a visible, non-accidental effect in the overview itself, not only in a
  share — the tiles show icons. That is a feature of the fallback being first-class.
- Reversing to icon-only would be easy in the tile and invisible in the model; reversing the
  *join* would mean finding another way to identify a capture, which is the expensive half.

## Assumptions and invalidation triggers

- *Assumes `HyprlandToplevel.address` stays the join key.* Trigger: Quickshell stops exposing it,
  or Hyprland changes address formatting ⇒ supersede; the join needs another key.
- *Assumes a denied capture is indistinguishable from an absent one, to the user.* Trigger: a
  need to tell the user *why* a tile shows an icon ⇒ amend; the icon stops being one state.
- *Assumes background and occluded windows capture real pixels.* This was the design's one
  residual risk, settled by a spike rather than by the design. Trigger: a compositor version
  where an occluded window captures black ⇒ amend, and `"snapshot"` finally acquires a caller.
- *Assumes captures are cheap enough to run for every visible tile.* Trigger: a many-window
  session where live capture is measurably expensive ⇒ amend and cap the live set.

## See also

- [[adrs/0008-keep-loaded-overlay]] — why `panel.visible` and not component lifetime is the gate.
- [[adrs/0005-lock-state-persistence]] — where `armed` comes from.
- [[frameworks/hyprland/compositor-state]] — the other protocol surface, and its refresh rules.
- [[frameworks/quickshell/component-patterns]] — `WindowTile` is a leaf and takes `handle` as a
  property.
- `docs/specs/2026-09-08-omascape-previews-drag-drop-design.md`; implementation `WindowTile.qml`,
  `Overview.qml` `buildHandles()`.
