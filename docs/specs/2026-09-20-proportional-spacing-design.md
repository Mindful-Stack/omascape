# Omascape — proportional spacing: the gap is a fraction of the cell (design)

Date: 2026-09-20 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1 ·
builds on the bar drop-down (`docs/specs/2026-09-19-bar-dropdown-design.md`).
Status: **implemented and swept 2026-09-21** (brainstorm 2026-09-20; review corrections applied the
same day — integer fitting, the missing-width fallback, and the external-screen figures). The
derivation and tables below are at the 0.08 the design was worked out at; the sweep moved
production to **0.04** — see "After the sweep" at the end.

## Goal

The grid should look the same on every screen: tiles that fill the width they are given, with a
gap between them that is proportional to the tiles, and the same gap between the outer tiles and
the edge. In CSS terms, a flex row with `justify-content: space-between` and `padding: 0 gap`,
where the tiles are the flexible part.

## Scope

**In:** a gap that is a fraction of the cell width; edge padding equal to one gap, inside the
canvas; cell width derived from what is left, fitted to whole pixels; the row spacing between
sub-rows, between monitor groups and above the scratchpad following the same gap; `maxCellW`
raised from a size to a sanity cap; tests; the README's note on layout constants.

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

- **Edge padding equals one gap, inside the canvas.** The canvas is `cols·cw + (cols+1)·gap`
  wide and boxes start at `x = gap`. Putting the edge in `layout()` rather than in the QML keeps
  the invariant the Flickable comment states: the canvas starts at x = 0, so every hit test and
  the drag keep working. The Flickable still centres a canvas narrower than the card.

- **Cell width takes what is left, fitted to whole pixels.** Written as integers throughout,
  because the review of the first draft found the real-valued version overflowing the viewport
  by 1–2 px at both of the author's widths. The rule, in the order it runs:

  1. `gapMin = round(minCellW · r)` — the gap the narrowest legal cell would get (11 at
     140 × 0.08).
  2. `cols = clamp(floor((availW − gapMin) / (minCellW + gapMin)), 1, maxCols)` — the most
     columns of minimum cells that fit *including both outer gaps*, i.e. the largest `n` with
     `n·minCellW + (n+1)·gapMin ≤ availW`.
  3. `cw = clamp(floor(availW / (cols + (cols+1)·r)), minCellW, maxCellW)`, then
     `gap = round(cw · r)`.
  4. **Fit:** while `cols·cw + (cols+1)·gap > availW` and `cw > minCellW`, decrement `cw` and
     recompute `gap`. The real-valued estimate overshoots by at most `(cols+1)/2` px from the
     gap's rounding, and one step of `cw` removes at least `cols` px, so the loop runs at most
     once — verified by sweeping every `availW` from 162 to 8000: no overflow, never more than
     one step. The only way the canvas is ever wider than `availW` is `minCellW` binding, and
     then it overflows exactly as the pixel model already does.

  The canvas is therefore **never wider than `availW`** (bar the `minCellW` case) and at most
  `2·cols` px narrower when the cap does not bind. The fit condition is strict, so a step only
  runs on an overshoot of at least 1 px, and it removes at most `cols + (cols+1)` px — the
  overshoot it removed plus what it over-removed, less the pixel that triggered it. Widths that
  take no step leave less: at most `cols + (cols+1)·(r + ½)`, which ties `2·cols` only at one
  column. Measured: exactly 2, 4, 6, 8, 10 for one to five columns. That remainder is centred
  by the Flickable, as slack is today.

  | screen (bar mode, `availW`) | today `cw` / gap | **new `cw` / gap** | canvas | row height (16:10) |
  |---|---|---|---|---|
  | laptop, 2024 | 380 / 4 | **368 / 29** (one fit step) | 2014 | 230 |
  | external, 2536 | 380 / 4 | **462 / 37** | 2532 | 289 |
  | 4K at 1×, 3816 | 380 / 4 | **696 / 56** | 3816 | 435 |
  | laptop, centred card, 1820 | 360 / 4 | **331 / 26** (one fit step) | 1811 | 207 |

  The cost, stated plainly: the laptop's tiles shrink 380 → 368 in bar mode and 360 → 331
  centred, to pay for the gap. The ratio is the one knob; 0.08 was picked from these numbers,
  not from a screen, and the first restart may move it.

- **`maxCellW` becomes a sanity cap: 800.** It never binds on anything up to 4K at 1× (696).
  Past it — an 8K panel, a 6000-logical ultrawide — cells stop growing (`availW` 6000: `cw` 800,
  gap 64, canvas 4384), the canvas is narrower than the card, and the Flickable centres it as
  today. This is the only path that still produces large slack, and the bar-mode centring test
  moves there.

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

- `logic.js` `layout()`: the derivation above; `rowGap` variable replacing the three
  `P.rowSpacing` reads; `edge` added to every box `x` and every group `x`; `canvasW` includes
  `2·edge`. Guard `gapRatio` with `isFinite` like every other input.
- `Overview.qml` params: `gapRatio: 0.08`, `maxCellW: 800`. `cellSpacing` and `rowSpacing` stay,
  now documented as the fallback. The Flickable comment about 108 px of slack on a 2048 panel is
  rewritten: slack is now the fit step's few pixels, or `maxCellW` binding.
- `README.md` "Layout constants" sentence names `gapRatio`.
- `lore/knowledge/general/layout-and-sizing.md` gains the ratio rule under "A maximum is a cap,
  not a floor" (through the KB's PR flow, `make validate`).

## Edge cases

- **One column.** `cols` = 1: the row is `cw + 2·gap` wide, `cw = floor(availW / (1 + 2r))`,
  fitted. Edges still apply, so a single tile does not touch the card.
- **Widest group narrower than `cols`.** A group with three workspaces on a five-column layout
  keeps the five-column pitch (columns line up across groups) and its canvas is centred by the
  Flickable, as today.
- **`availW` missing or not positive.** The fallback is `maxCols·minCellW + (maxCols+1)·gapMin`
  — 766 at the chosen params, *both* outer gaps included. Step 2 then resolves `cols` to
  `maxCols` exactly (the first draft's fallback omitted the edges and lost a column to the
  real-valued column test; the integer step 2 is what makes it consistent), step 3 clamps `cw`
  to `minCellW`, and the canvas is exactly 766: finite, valid geometry, one column short of
  nothing.
- **`minCellW` binds.** A very narrow screen: `cw` = 140, `gap` = 11, and the row may overflow
  `availW`, exactly as the pixel model already can — the Flickable scrolls it. `cols` drops to 1
  before that, so it takes an `availW` under 162 to reach it.
- **Rounding.** Covered by the fit step above: never wider, at most `2·cols` narrower
  (measured: exactly 2, 4, 6, 8, 10 for one to five columns).

## Tests

Tier 1, `tests/tst_layout.qml`, ratio on:

- the four rows of the table above, pinned: `cw`, `gap`, canvas width, box `x` for the first two
  columns (`gap` and `gap + cw + gap`). The two one-fit-step rows (2024 and 1820) are the ones
  the review found overflowing, so they are the ones that prove the fit step
- a sweep: for every integer `availW` from 162 to 4384 (the last width before the cap binds; from 4385 the cell pins at 800), the canvas is
  `≤ availW` and `≥ availW − 2·cols`, plus a finiteness check per width; a single loop, one assertion each way, stated as the
  property it is
- `availW` missing (absent, `0`, negative, `NaN`): `cols` = 5, `cw` = 140, `gap` = 11, canvas 766
- `rowSpacing` is ignored in ratio mode: second sub-row `y` = `gch + gap`; second monitor group
  `y` accounts for `gap`, not `rowSpacing`; scratchpad group likewise
- `maxCellW` binds on a 6000 `availW`: `cw` = 800, `gap` = 64, canvas 4384
- `cols` drops below `maxCols` when `n·minCellW + (n+1)·gapMin` no longer fits (at 765 it is 4,
  at 766 it is 5), and floors at 1
- `gapRatio` absent, `0`, `NaN`, `Infinity`, a string: output identical to the pixel model, byte
  for byte against a run without the key
- every box and group is finite for every case above (the NaN floor)

Tier 1, `tests/ui/dropdown.qml`:

- `test_the_grid_is_centred_when_narrower_than_the_card` seeds a panel wide enough for
  `maxCellW` to bind (6000 logical) instead of 2048, keeping its slack precondition honest
- a new test at 2048: the canvas fills the card to within `2·cols` px, and the first box
  starts at `card.pad + gap`, not at `card.pad`

Sweep by eye after `mise run link` and a restart on both screens: the ratio, and whether the top
padding wants to follow the gap (out of scope here, noted for the sweep).

## After the sweep (2026-09-21)

On both of the author's screens 0.08 read as too much gap for the tile it bought, and so did
0.06 on a second look, so production runs `gapRatio` = 0.04. Same rule, same fit; only the
number moved. The logic tests keep pinning
0.08 as their fixture ratio, because they pin the algorithm; the offscreen UI test reads the real
params object and pins the production row.

| screen (bar mode, `availW`) | at 0.08 `cw` / gap | at 0.06 | **at 0.04 `cw` / gap** | canvas |
|---|---|---|---|---|
| laptop, 2024 | 368 / 29 | 377 / 23 | **386 / 15** | 2020 |
| external, 2536 | 462 / 37 | 473 / 28 | **483 / 19** | 2529 |
| 4K at 1×, 3816 | 696 / 56 | 711 / 43 | **728 / 29** | 3814 |
| laptop, centred card, 1820 | 331 / 26 | 339 / 20 | **347 / 14** | 1819 |

At 0.04 the cap first binds at `availW` 4192 (canvas frozen at 5·800 + 6·32 = 4192), the minimum
gap is 6, and the missing-width fallback is 736. Still open after the sweep: whether the top
padding should follow the gap, and whether the 15 px drag dead-band between tiles bites in use.
