# Omascape — proportional spacing: the gap is a fraction of the cell (design)

Date: 2026-09-20 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1 ·
builds on the bar drop-down (`docs/specs/2026-09-19-bar-dropdown-design.md`).
Status: **approved, not yet implemented** (brainstorm 2026-09-20).

## Goal

The grid should look the same on every screen: tiles that fill the width they are given, with a
gap between them that is proportional to the tiles, and the same gap between the outer tiles and
the edge. In CSS terms, a flex row with `justify-content: space-between` and `padding: 0 gap`,
where the tiles are the flexible part.

## Scope

**In:** a gap that is a fraction of the cell width; edge padding equal to one gap, inside the
canvas; cell width derived from what is left; the row spacing between sub-rows, between monitor
groups and above the scratchpad following the same gap; `maxCellW` raised from a size to a sanity
cap; tests; the README's note on layout constants.

**Out:** a config key for the ratio (it is a params constant, tuned by eye); top and bottom
padding inside the card (stays `card.pad`, revisit by eye after the sweep); `cellInset`, `headerH`
and `groupInset`, which stay fixed pixels; per-monitor ratios; touching the tile placement inside
a cell (`placeWindows`).

## The problem

Column count is capped at 5 and cell width at `maxCellW` = 380, with a fixed 4 px gap, so the
row is 1916 px wide on any screen that can fit it and everything else is centred as dead space.
In bar mode the card is the full screen width, so the dead space is inside the card:

| screen | logical width | `availW` (bar mode) | slack beside the row |
|---|---|---|---|
| author's laptop, eDP-1 2560×1600 at 1.25× | 2048 | 2024 | 108 |
| author's external, HDMI-A-1 2560×1440 at 1× | 2560 | 2536 | 620 |
| a 4K panel at 1× | 3840 | 3816 | 1900 |

Reported 2026-09-20 on the external: 310 px of empty card each side, and five tiles 4 px apart in
the middle of it, which reads as cramped precisely because the room is there and unused.

## Decisions (brainstorm 2026-09-20)

- **The gap is a fraction of the cell width, not of the screen.** `gapRatio` = 0.08. A gap
  relative to the tile looks the same whether the screen fitted five columns or two, and it
  scales to 4K with no extra rule. Considered and rejected: growing the gap alone up to a cap and
  keeping tiles at 380 (fixes the laptop, wastes a 4K panel); growing the tiles alone (refills
  the laptop's width with 4 px gaps, the very look being fixed); `space-evenly` (edges would take
  the same share as gaps, which is what the ratio does anyway, more simply).

- **Edge padding equals one gap, inside the canvas.** The canvas is `2·gap + cols·cw +
  (cols−1)·gap` wide and boxes start at `x = gap`. Putting the edge in `layout()` rather than in
  the QML keeps the invariant the Flickable comment states: the canvas starts at x = 0, so every
  hit test and the drag keep working. The Flickable still centres a canvas narrower than the
  card, which is the only case where slack now exists (below).

- **Cell width takes what is left.** A row of `n` cells at width `w` is `w·(n + (n+1)·r)` wide.
  So `cols` is the largest `n ≤ maxCols` with `minCellW·(n + (n+1)·r) ≤ availW`, floored at 1,
  and `cw = clamp(floor(availW / (cols + (cols+1)·r)), minCellW, maxCellW)`. Then
  `gap = round(cw · r)`.

  | screen (bar mode, `availW`) | today `cw` / gap | **new `cw` / gap** | row height (16:10) |
  |---|---|---|---|
  | laptop, 2024 | 380 / 4 | **369 / 30** | 231 |
  | external, 2536 | 380 / 4 | **463 / 37** | 289 |
  | 4K at 1×, 3816 | 380 / 4 | **696 / 56** | 435 |
  | laptop, centred card, 1820 | 360 / 4 | **332 / 27** | 208 |

  The cost, stated plainly: the laptop's tiles shrink 380 → 369 in bar mode and 360 → 332
  centred, to pay for the gap. The ratio is the one knob; 0.08 was picked from these numbers,
  not from a screen, and the first restart may move it.

- **`maxCellW` becomes a sanity cap: 800.** It never binds on anything up to 4K at 1× (696).
  Past it — an 8K panel, a 6000-logical ultrawide — cells stop growing, the canvas is narrower
  than the card, and the Flickable centres it as today. This is the only path that still produces
  slack, and the bar-mode centring test moves there.

- **Vertical spacing follows the gap.** `rowSpacing` between sub-rows of one group, between
  monitor groups, and above the scratchpad group all become `gap`. A 5×2 grid with 37 px between
  columns and 8 px between rows would look wrong. Taller rows on wide screens are absorbed by the
  card's existing height cap and the Flickable.

- **The fixed-pixel path stays as the fallback.** `gapRatio` absent or not a positive finite
  number means `cellSpacing` and `rowSpacing` apply exactly as today, edge padding 0. This is
  the standing rule from `lore/knowledge/general/layout-and-sizing.md`: a new layout input's
  fallback is the behaviour that existed before the input did. It also leaves every existing
  `tst_layout.qml` fixture — all of which pin absolute x/y literals — untouched; the new tests
  turn the ratio on.

## Changes

- `logic.js` `layout()`: the `cols` / `cw` / `gap` derivation above; `rowGap` variable replacing
  the three `P.rowSpacing` reads; `edge` added to every box `x` and every group `x`; `canvasW`
  includes `2·edge`. Guard `gapRatio` with `isFinite` like every other input.
- `Overview.qml` params: `gapRatio: 0.08`, `maxCellW: 800`. `cellSpacing` and `rowSpacing` stay,
  now documented as the fallback. The Flickable comment about 108 px of slack on a 2048 panel is
  rewritten: slack now only exists when `maxCellW` binds.
- `README.md` "Layout constants" sentence names `gapRatio`.
- `lore/knowledge/general/layout-and-sizing.md` gains the ratio rule under "A maximum is a cap,
  not a floor" (through the KB's PR flow, `make validate`).

## Edge cases

- **One column.** `cols` = 1: the row is `2·gap + cw` wide, `cw = availW / (1 + 2r)`. Edges
  still apply, so a single tile does not touch the card.
- **Widest group narrower than `cols`.** A group with three workspaces on a five-column layout
  keeps the five-column pitch (columns line up across groups) and its canvas is centred by the
  Flickable, as today.
- **`availW` missing.** The existing fallback (`maxCols·minCellW + (maxCols−1)·gap`) stays; in
  ratio mode it is computed with `gap = round(minCellW · r)` so `cols` still resolves to `maxCols`
  and `cw` to `minCellW`. Finite geometry either way.
- **`minCellW` binds.** A very narrow screen: `cw` = 140, `gap` = 11, and the row may overflow
  `availW` by a few pixels exactly as the pixel model already can — the Flickable scrolls it.
- **Rounding.** `cw` floors, `gap` rounds; the canvas can be up to `cols + 1` px narrower than
  `availW`, which the Flickable centres. Never wider.

## Tests

Tier 1, `tests/tst_layout.qml`, ratio on:

- the three bar-mode rows of the table above, pinned: `cw`, `gap`, box `x` for the first two
  columns (`gap` and `gap + cw + gap`), `canvasW` = `availW` minus rounding
- `rowSpacing` is ignored in ratio mode: second sub-row `y` = `gch + gap`; second monitor group
  `y` accounts for `gap`, not `rowSpacing`; scratchpad group likewise
- `maxCellW` binds on a 6000 `availW`: `cw` = 800, `canvasW` < `availW`
- `cols` drops below `maxCols` when `minCellW·(n + (n+1)·r)` no longer fits, and floors at 1
- `gapRatio` absent, `0`, `NaN`, `Infinity`, a string: output identical to the pixel model, byte
  for byte against a run without the key
- every box and group is finite for every row above (the NaN floor)

Tier 1, `tests/ui/dropdown.qml`:

- `test_the_grid_is_centred_when_narrower_than_the_card` seeds a panel wide enough for
  `maxCellW` to bind (6000 logical) instead of 2048, keeping its slack precondition honest
- a new test at 2048: the canvas fills the card to within `cols + 1` px, and the first box starts
  at `card.pad + gap`, not at `card.pad`

Sweep by eye after `mise run link` and a restart on both screens: the ratio, and whether the top
padding wants to follow the gap (out of scope here, noted for the sweep).
