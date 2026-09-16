# Omascape — visual restyle (2026-09-10)

Branch `restyle` (worktree), based on `drag-ghost`. Motion/animation work is deferred to a
follow-up spec; this one only changes surfaces, radii, and what marks selection.

## Why

Compared with end-4's overview the picker reads as "boxes in boxes": card border, workspace
border and tile border are three nested 1px lines on one flat tone. end-4 uses tone steps
instead of lines, concentric corner radii, a soft shadow for elevation, and a single accent
frame for selection. The card here was square because it bound to `Style.cornerRadius`, which
mirrors Hyprland `decoration:rounding` (0 on the author's machine).

## Design

- **Card.** Own radius (`boxRadius + pad` = 20), padding 12, no border, soft
  `RectangularShadow` (QtQuick.Effects, Qt ≥ 6.9; no offscreen layer). Colour stays
  `Color.menu.background`.
- **Scrim.** Kept, `Color.menu.scrim`, now switchable via config (see below). Scrim-click
  dismissal works regardless.
- **Workspace wells.** No border. Fill = menu text colour at `Style.normalFillAlpha` (0.04
  default). Focused workspace = `Color.menu.selectedBackground`. Drop target while dragging =
  text colour at `Style.selectedFillAlpha`. Radius 8. Cell gap 6, inset 3, row gap 10.
- **Numeral.** Large DemiBold workspace number behind the windows, ~45 % of cell height,
  10 % opacity.
- **Selection frame.** One 2px `Color.menu.selectedText` (accent) rounded frame drawn above
  the tiles on the keyboard-selected box. Drags never move it (it recedes to 40 % while a
  drag is in progress). Replaces the 1/2/3px border ladder.
- **Drop cue, always above the previews.** With previews at scale 1 and a 3px inset, a
  fullscreen or densely tiled workspace covers nearly all of its well, so a well tint alone can
  vanish. The cue is therefore layered above the tiles: when a tiled drag has an insertion
  anchor, the accent half on that tile (existing); otherwise (floating drags, empty targets,
  grouped/fullscreen sources) an accent **wash** over the whole target box at 22 % plus a 2px
  accent edge, `z` above every resting tile and below the drag ghost. The well fill at
  `Style.selectedFillAlpha` remains underneath as a secondary hint. Keeping selection and drop
  apart means the selection never "flies" to the drop target and back.
- **Window tiles.** Rest at scale 1 (was 0.95, so previews never filled their rect), hover
  1.03. No border except a 12 % hairline so adjacent previews with zero Hyprland gaps do not
  merge, and a 2px accent border when the tile is the tiled-insert anchor. Radius 5
  (box radius minus inset).
- **Monitor chip.** Plain text, no border; accent for the focused monitor. `Logic.layout`
  decides: the header band (`params.headerH`) is laid out only when more than one monitor has
  workspaces, and each group reports the resulting `headerH`. `Overview.qml` renders chips
  only when the layout produced more than one group, so both follow the same rule.
- **Hint.** Unchanged text, 40 % opacity.

## Config

`~/.config/omarchy/omascape.json` (watched, optional):

```json
{ "scrim": true }
```

Missing file or key = default. Loaded by `OmascapeConfig.qml`; the offscreen test fixture stubs
it and `CardShadow.qml` with plain items.

## Acceptance checks

Offscreen (`tests/ui/drag.qml`): a floating drag over a workspace whose only window is
fullscreen shows the wash on that box, stacked above the preview, and hides it on release; a
tiled drag with an insertion anchor shows no wash.

Manual, in a light theme (Rosé Pine Dawn) and a dark one (Tokyo Night):

- Floating drag onto a workspace with one fullscreen window: the wash is visible over the
  preview the whole time the pointer is inside the box.
- Floating drag onto a densely tiled workspace (4+ windows, zero gaps): same.
- Tiled drag onto a tiled workspace: the insertion half shows on the anchor tile, no wash.
- Drag onto an empty workspace: wash over the empty well.
- The keyboard selection frame never moves during any of the above.

## Out of scope

Easing/animation block, hover tint, glide timing tuning — next spec.
