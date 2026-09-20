---
title: Layout and sizing — derived constants, caps, and the NaN floor
description: Sizes are derived from one pure function rather than duplicated as constants, maxCols is a cap and never a floor, and every layout input is guarded because a NaN reaches the card as a zero-size rectangle — an invisible overlay that still takes keyboard focus and draws the scrim.
tags: [architecture, javascript, qml, ui, testing]
---

# Layout and sizing — derived constants, caps, and the NaN floor

All of it is pure `logic.js`, which is why it is all Tier 1 testable. Measured 2026-09-20 against
`origin/main` (`7200771`). [[general/architecture]] covers why the maths lives there at all.

## A size that appears twice is derived once

`Logic.screenMargin(panelW)` is the pattern:

```js
function screenMargin(px) {
    var n = Number(px)
    if (!isFinite(n) || n <= 0) return 16
    return Math.round(Math.max(16, n * 0.05))
}
```

It replaced three hand-written constants — `availCanvasW`'s `- 16`, the card's `- 16` and its
`- 64` — which had been sized for a ~1600-logical card and left the grid 10 px from the edge on a
1920-logical panel. **One function now drives both the horizontal and the vertical margin, so
they cannot drift apart again**, and it lands in the Tier 1 suite like every other layout
decision.

The rule generalises: **when two call sites need the same size, extract the function, do not copy
the number.** And state the cost when you pick the constant — the card-presence spec chose 5%
over 4% with the trade-off written down, including that the author's own cells shrink 380 → 360.

## A maximum is a cap, not a floor

```js
var cols = Math.max(1, Math.min(P.maxCols,
    Math.floor((availW + gap) / (P.minCellW + gap))))
var cw = Math.max(P.minCellW, Math.min(P.maxCellW,
    Math.floor((availW - (cols - 1) * gap) / cols)))
```

The params are `maxCols: 5, minCellW: 140, maxCellW: 380` (`Overview.qml:273`), and the comment
says it outright: *"maxCols is a CAP, not a floor."* A narrow screen gets fewer columns; it does
not get five squeezed ones. Cell width is then clamped between `minCellW` and `maxCellW` — so
`maxCellW` stops binding as soon as the margin takes its cut, which is exactly why the margin
change above shrank the author's cells from 380.

Since 2026-09-20 the cell is no longer the thing that is capped in practice. With `gapRatio`
set (0.08 in production) the gap is that fraction of the cell width, both edges of the canvas
carry one gap, and the cell takes what is left — fitted to whole pixels so the canvas is never
wider than `availW`:

```js
cw = clamp(floor(availW / (cols + (cols + 1) * ratio)), minCellW, maxCellW)
gap = round(cw * ratio)
while (cols * cw + (cols + 1) * gap > availW && cw > minCellW) { cw--; gap = round(cw * ratio) }
```

`maxCellW` is 800 now and only binds once the card offers more than 4384 logical px of
interior width; below that it is a sanity cap that never fires. The
row spacing between sub-rows, monitor groups and the scratchpad follows the same gap. Without
`gapRatio` — absent, or anything but a positive finite number — the pixel `cellSpacing` and
`rowSpacing` apply exactly as before, which is the fallback rule below applied to a new input.
The derivation, the fit step's proof and the measured table are in
`docs/specs/2026-09-20-proportional-spacing-design.md`.

## Every layout input has a finite fallback

**15 `isFinite` guards** in `logic.js`, and they exist for one failure:

> A NaN here reaches every box, the canvas and the card, and a card with a NaN height **paints
> nothing at all** — found on a real desktop, 2026-09-18.

That is the worst failure mode in the codebase: the overlay maps its surface, takes keyboard
focus, draws the scrim, and shows no picture. Nothing errors. So every input carries a fallback
that is *valid geometry*, not zero:

| Input | Fallback | Effect |
|---|---|---|
| `availW` missing or ≤ 0 | `maxCols * minCellW + (maxCols - 1) * gap` | `cols` resolves to `maxCols`, `cw` clamps to exactly `minCellW` |
| `panelW` non-finite | `16` | the floor margin, i.e. the pre-change behaviour |
| a monitor with non-positive logical size | the default aspect | same path a missing monitor takes |

**A new layout input needs the same treatment**, and the fallback should be the behaviour that
existed before the input did. The placeholder monitor is dropped upstream in `buildInput()` — see
[[frameworks/hyprland/compositor-state]] — and these guards are the floor under that, not a
substitute for it.

## Fullscreen tiles are drawn in a recovered slot

`Logic.recoverSlot(R, others, P)` answers "where does this window go when it stops being
fullscreen". Fullscreen hides the other windows **without moving them**, so the hole they leave in
the usable rect *is* the slot the window returns to. Building the answer from the hole rather than
re-running the tiling layout is what makes the tile appear where the window will actually land.

The algorithm is grid → seed → grow → trim: build a grid from the distinct x/y edges of `R` and
every other window, seed on the uncovered cell with the largest **minimum side** (so a thin gap
strip is never chosen over a squarer hole), grow one grid row/column at a time while the extension
stays uncovered, then trim outer bands whose cumulative coverage is below tolerance
(`P.slotGapTolerance`, default 24).

It is pure, so a change to it is a Tier 1 change. It is also the reason each tile carries a
`layer` role — `0` backdrop, `1` tiled, `2` floating.

## See also

- [[languages/javascript/code-style]] — the dialect all of this is written in.
- [[general/architecture]] — why the maths is here and not in a binding.
- [[general/testing]] — the tier that covers it, and how a test states what it falsifies.
- [[frameworks/hyprland/compositor-state]] — where a zeroed placeholder monitor comes from.
- [[general/workspace-grid-defaults]] — the other sizing default, and its config key.
- `docs/specs/2026-09-09-milestone-a-design.md`, `2026-09-10-window-states-design.md`,
  `2026-09-18-card-presence-design.md`.
