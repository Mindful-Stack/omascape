---
title: "An overlay layer takes OnDemand keyboard focus, never Exclusive"
description: Hyprland 0.56 routes every pointer event to exclusive layer surfaces while any exists, so an Exclusive overlay made every other monitor dead to clicks; OnDemand still grabs focus on map, and the per-monitor catchers must be None.
tags: [frameworks, hyprland, quickshell, qml, compositor]
confidence: verified
source: developer-input
date: 2026-09-20
---

# An overlay layer takes OnDemand keyboard focus, never Exclusive

Verified against Hyprland 0.56. The overview is a layer-shell overlay on every screen: one
`PanelWindow` for the picker on the target screen, and a transparent **catcher** on each other
screen whose only job is to close the overview when clicked.

The obvious setting for "this overlay owns the keyboard" is
`WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive`. It breaks the pointer on every other
monitor.

## What Exclusive actually does

Hyprland's `InputManager.cpp` (`mouseMoveUnified`, the "forced above all" path) routes **every**
pointer event to exclusive layer surfaces while any exists. When the cursor is over none of them
it still hands the event to the first one — at out-of-bounds coordinates.

The symptom: a click on another monitor never reached that monitor's catcher, and that screen's
ordinary windows went dead too. Nothing logs it. It reads as "the other monitor stopped working
while the overview is up".

## The arrangement that works

| Surface | `keyboardFocus` | Why |
|---|---|---|
| the picker's `PanelWindow` | `OnDemand` while open, `None` otherwise | still grabs focus on map; pointer routing stays the normal per-monitor hit test |
| each off-screen catcher | **`None`** | never `Exclusive`, and never `OnDemand` either |

An `OnDemand` overlay layer **still grabs keyboard focus the moment it maps** —
`LayerSurface.cpp`, `GRABSFOCUS` — so nothing is lost by not being exclusive. It keeps that focus
while the pointer is over it *or over a focus-less surface*, because the refocus in
`mouseMoveUnified` only fires for surfaces whose interactivity is not `none`. **That is why the
catcher must be `None`**: a focus-less catcher lets the keys stay with the picker however far the
pointer wanders, while a catcher with any interactivity would steal them.

## The keybind is a separate path and is not affected

A configured Hyprland keybind never reaches the surface. `scripts/add-keybind.sh` binds the key to
`omarchy-shell shell toggle se.mindfulstack.omascape`, so the compositor executes it and the shell
calls `toggle()`. That is why the summon key also closes the overview while bare keys are still
being delivered to the overlay — two different delivery paths, not one focus rule with an
exception.

## See also

- [[frameworks/hyprland/compositor-state]] — the other half of the compositor boundary.
- [[frameworks/quickshell/component-patterns]] — lifetime and visibility of these surfaces.
- [[adrs/0008-keep-loaded-overlay]] — why the always-on surfaces can exist between summons.
- Implementation: `Overview.qml`'s `panel` and the catcher `Variants` block, each with the
  reasoning in a comment beside the property.
