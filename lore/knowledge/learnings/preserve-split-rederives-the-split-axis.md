---
title: "dwindle:preserve_split=false re-derives the split axis on every fullscreen change"
description: "Under Hyprland's default `dwindle:preserve_split = false` a container's split axis is recomputed from its aspect ratio on every recalculation, and a fullscreen enter or exit is one, so a re-tile can come back split the other way. The integration rig pins it true."
tags: [hyprland, compositor, testing]
confidence: verified
source: developer-input
date: 2026-09-20
---

# `dwindle:preserve_split=false` re-derives the split axis on every fullscreen change

Hyprland's dwindle layout, under its default `dwindle:preserve_split = false`, recomputes a
container's split axis from its aspect ratio on every recalculation. A fullscreen enter or exit
is a recalculation. So a tile dropped next to a fullscreen anchor, or an in-place re-tile of a
fullscreen window, can come back split on the other axis once the fullscreen ends.

That is Hyprland's own behaviour and it is identical for a native drag, so the overlay does not
try to correct it (`DESIGN.md` § Fullscreen). What it does affect is the **tests**: a Tier 2
case asserting "split on this axis" would flap.

## What the rig does

`tests/integration/fullscreen.sh` starts its nested compositor with
`dwindle = { preserve_split = true }` (and zero gaps, so slot arithmetic is exact), so split axes
stay deterministic across the run. A new integration case that asserts on tiling geometry needs
the same pin, and the comment at the top of that file says why.

## See also

- [[languages/bash/test-harnesses]] — the integration harness and its `lib.sh`.
- [[frameworks/hyprland/compositor-state]] — the snapshot the overlay reads tiling from.
- [[adrs/0002-compositor-dispatch-errors]] — the chunks whose results these tests check.
