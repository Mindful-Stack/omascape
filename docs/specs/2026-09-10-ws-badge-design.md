# Omascape — workspace number badge (2026-09-10)

Branch `ws-badge`, based on `restyle`. Follow-up to the visual restyle.

## Problem

The restyle put a large low-contrast numeral behind each workspace's windows. With every
workspace occupied (the common case), the numeral is hidden by the previews and the number keys
(1–0) have no visible anchor.

## Options considered

1. **Corner badge** — small chip in each well's top-left corner, above the tiles. Chosen.
2. Number strip inside the well — no overlap but costs preview height and a `logic.js` change.
3. Label outside the well — cleanest separation, but adds a row per cell row.
4. Show on hover/selection only — does not help scanning for "which one is 7".

## Design

- **Badge.** One chip per box at (x+6, y+6), height 18, width fits the label (min 18),
  radius 5, `z` 40 (above resting and hovered tiles, below the selection frame at 50, the drop
  wash at 60 and the drag ghost). Fill = card background at 88 % alpha; label = menu text,
  11px DemiBold. The focused workspace's badge is filled with the accent and its label uses
  the card background, so "you are here" reads at a glance.
- **Label.** Same mapping as the keys: workspace 10 shows "0".
- **Numeral.** The big 10 % numeral remains, but only on empty workspaces (`!occupied`).
- **No mouse handling** on the badge: clicks fall through to the tile or the box.

## Tests

Offscreen (`tests/ui/drag.qml`): one badge per box, positioned inside its box and stacked above
a resting tile; the big numeral is hidden on the occupied workspace and visible on the empty one.
