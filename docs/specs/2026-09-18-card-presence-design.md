# Omascape — card presence: screen margin and elevation (design)

Date: 2026-09-18 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1 ·
builds on actions (`actions-omascape` at `da9075b`).
Status: **approved design, pre-implementation; revised 2026-09-18 after review** (a UI-level
assertion of the real card bounds, marked ✎). Branch `presence`.

## Goal

The picker should sit *on* the desktop, not fill it. Two halves: give it a real margin that
scales with the screen (it currently has almost none on a 1920-logical display), and give it
enough elevation that the margin reads as deliberate.

## Scope

**In:** one shared, testable screen margin replacing two unrelated hardcoded constants; a card
border; a deeper card shadow; an optional accent tint on the card with `badgeColor` rebased to
follow it; tests.

**Out:** per-monitor margin configuration; a config key for the margin fraction; changing
`maxCellW`, `minCellW` or `maxCols`; restyling the wells, chips or the focused-group backdrop;
touching `WindowTile`'s own shadow.

## The bug

Reported 2026-09-18 by a tester on a 3840×2160 laptop panel at 2× — **1920 logical** — where the
grid renders to within ~10 px of the screen edge. It is not his setup. Two constants, written for
a ~1600-logical card and never revisited, are each independently too small and disagree with each
other by `2 * card.pad`:

| | |
|---|---|
| `Overview.qml:257` | `availCanvasW = panel.width - 2 * card.pad - 16` |
| `Overview.qml:1463` | `maxCardW = panel.width - 16` |

At 1920 logical: `availW` = 1880 → `cols` = 5 → `cw` = `min(maxCellW 380, floor(1864/5) = 372)` =
**372**. Canvas 1876, card 1900 on a 1920 screen: **10 px per side.**

It has never shown on the author's own 2560×1440 at 1.25× (2048 logical), where `cw` clamps at
`maxCellW` = 380 and leaves 54 px per side. 1920 logical is the width at which the grid almost
exactly consumes the viewport *before* `maxCellW` can cap it — which is the most common laptop
logical width there is.

## Decisions (brainstorm 2026-09-18)

- **One margin, derived, tested, shared.** A pure `Logic.screenMargin(panelW)` drives both
  constants, so they cannot drift apart again, and lands in the Tier 1 suite like every other
  layout decision in this codebase.

- **5% of the panel width, floored at 16.** Chosen over 4%; both were on the table.

  | screen | today | 4% | **5% (chosen)** |
  |---|---|---|---|
  | 1920 logical (the reported case) | `cw` 372, **10 px/side** | `cw` 345, 78 px/side | `cw` 337, **97 px/side** |
  | 2048 logical (author's) | `cw` 380, 54 px/side | `cw` 368, 84 px/side | `cw` 360, **104 px/side** |

  **The cost, stated plainly: the author's own cells shrink 380 → 360**, because `maxCellW` never
  binds once the margin takes its cut. That is the knob to turn if the picture feels cramped — 4%
  keeps cells near today's size and still fixes the reported case. Nothing else depends on the
  figure.

- **The same function governs the vertical**, replacing the bare `- 64` at `Overview.qml:1464`.
  At 1080 logical the vertical margin goes 32 → 54 per side. `maxCardH` only binds when there are
  enough rows to reach it, so this changes nothing for ordinary layouts and adds air to tall ones.

- **Elevation is a border plus a deeper shadow — not a recoloured card.** Now that there is real
  air around the card, it needs to read as elevated rather than as a lighter rectangle.
  - **Border:** 1 logical px at `Qt.rgba(accent.r, accent.g, accent.b, 0.35)`. `accent` is already
    `selText` and already tracks the theme, so this needs no new colour. One logical px is 2
    device px at 2× — crisp at exactly the scale where the problem was reported.
  - **Shadow:** the card's `SoftShadow` use site (`Overview.qml:1450`) overrides `blur` 28 → 48 and
    `offset` (0, 6) → (0, 12), and the existing luminance-driven alpha goes 0.55 → 0.65 dark,
    0.28 → 0.38 light. These are use-site overrides; `SoftShadow.qml`'s defaults are untouched, so
    `WindowTile`'s own `blur: 12` shadow is unaffected.

- **The accent card background, as raised in the brainstorm: available, but as a TINT, not a
  swap.** A full accent background would not be a colour change, it would be a rewrite of the
  picker's entire visual system, which is built as tone steps over `background`:

  | derived from `background` | breaks how |
  |---|---|
  | `wellColor`, `emptyWellColor`, `dropWellColor`, `hairline` | all `tone(a)` = foreground at alpha, tuned for contrast *against the background*; over accent they lose their separation from each other |
  | `badgeColor` | literally `background` at 0.88 — its comment says "the card colour" |
  | `groupBackdropColor` | accent at 0.08, i.e. the focused-monitor cue **disappears into an accent card** |
  | `darkTheme` | computed from `background` luminance; drives the shadow alpha and would flip on light accents |

  The version that gives the colour identity without the collapse: mix `background` toward
  `accent` by **8%**, and rebase `badgeColor` onto the card colour rather than `background` (a
  one-line change that its own comment already asks for). Contrast against `foreground` moves
  negligibly, `darkTheme` cannot flip, and the three well shades keep their relationships. This is
  specified as an **opt-in second commit** so the margin fix can land and be judged on its own.

## Changes

```js
// logic.js
// Breathing room between the picker and the screen edge, both axes. A FRACTION, because the
// two constants this replaces were absolute and sized for a ~1600-logical card: at 1920
// logical — the commonest laptop logical width, and a 4K panel at 2× — they left 10 px.
// Floored so a genuinely small screen still gets the old behaviour rather than none.
function screenMargin(px) {
    var n = Number(px)
    if (!isFinite(n) || n <= 0) return 16
    return Math.round(Math.max(16, n * 0.05))
}
```

```qml
// Overview.qml
readonly property real availCanvasW:
    panel.width > 0 ? panel.width - 2 * card.pad - 2 * Logic.screenMargin(panel.width) : 1600

// card
readonly property real maxCardW: panel.width  > 0 ? panel.width  - 2 * Logic.screenMargin(panel.width)  : 1616
readonly property real maxCardH: panel.height > 0 ? panel.height - 2 * Logic.screenMargin(panel.height) : 900
border.width: 1
border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)

SoftShadow { target: card; scale: card.scale; opacity: card.opacity
             blur: 48; offset: Qt.vector2d(0, 12)
             color: Qt.rgba(0, 0, 0, root.darkTheme ? 0.65 : 0.38) }
```

Optional second commit:

```qml
readonly property color cardColor: Qt.rgba(background.r * 0.92 + accent.r * 0.08,
                                           background.g * 0.92 + accent.g * 0.08,
                                           background.b * 0.92 + accent.b * 0.08, 1)
// card.color: root.cardColor
readonly property color badgeColor: Qt.rgba(cardColor.r, cardColor.g, cardColor.b, 0.88)
```

## Edge cases

- **`panel.width` is 0 before the surface maps.** Both properties already guard on it and fall
  back to their literals; `screenMargin` guards independently so it can never return `NaN` into
  the layout math.
- **A genuinely narrow screen.** The 16 px floor means nothing regresses below ~320 logical, and
  `DESIGN.md`'s existing "degenerate narrow screen 2-D scrolls" behaviour is unchanged: `cols`
  drops before `cw` does.
- **The hint row widening a narrow card.** `implicitWidth` already takes `max(canvas, hintBox)`
  and clamps to `maxCardW`; a larger margin lowers that clamp, so on a very narrow screen the
  hints clip slightly sooner. The existing `?` second tier is what keeps that row short.
- **`Style.cornerRadius` may be 0** (it mirrors Hyprland rounding), but the card owns its own
  `cardRadius = boxRadius + pad`, so the border always follows the card's actual corners.
- **Light themes.** The border is accent-derived, not a fixed neutral, so it stays visible on a
  light card where a black hairline would look like a bug and a white one would vanish.

## Tests

**Tier 1 (`logic.js`, pure, CI):**
- `screenMargin(1920)` = 96, `screenMargin(2048)` = 102, `screenMargin(0)` = 16,
  `screenMargin(NaN)` = 16, `screenMargin(200)` = 16 (the floor binds).
- The regression that names the bug: for a 1920 panel, `layout()` yields `cols` 5 and a canvas
  no wider than `1920 − 2 × pad − 2 × screenMargin(1920)`. Asserted as an inequality *against
  `screenMargin` itself*, not against the literal 337, so changing 5% to 4% does not require
  rewriting the test — only the table above.
- `layout()` is unchanged for the `availW`-missing path — the existing safe-default assertions
  must still pass untouched.

**UI suite (`tests/ui/presence.qml`, the real `Overview` against the stubbed compositor).** ✎
*(added after review 2026-09-18.)* The pure test above **cannot catch this bug**, which is the
point: `screenMargin` could be correct, fully tested and simply never wired into `maxCardW` — or
wired into one of the two bindings and not the other, which is precisely the drift that caused the
original defect. Only something that measures the real card can tell.
- At `width: 1920; height: 1080`, open the overview with a default ten-workspace layout and assert
  `card.width <= 1920 - 2 * Logic.screenMargin(1920)` — i.e. at least 96 px per side, versus the
  10 px the current code produces. This is the test that would have failed before the fix.
- Assert `flick.contentWidth <= card.width - 2 * card.pad`, so the canvas binding is checked
  independently of the card binding. One assertion per binding: neither can be omitted silently.
- **A tall layout at the same size** — enough monitor groups to drive `canvas.implicitHeight` past
  `maxCardH` — asserting `card.height <= 1080 - 2 * Logic.screenMargin(1080)` and that the
  Flickable still scrolls (`contentHeight > flick.height`). This is the only coverage the vertical
  margin gets; `maxCardH` does not bind in ordinary layouts, so an unwired height binding would
  otherwise go unnoticed until someone docked a third monitor.

**Visual (manual, both themes):**
- Light and dark sweep confirming the 0.35 border reads on both without ringing, and that the
  deeper shadow does not muddy light themes.
- Confirm `WindowTile`'s shadow is visibly unchanged — the check that the override stayed at the
  use site.
- If the tint commit lands: confirm the focused-group backdrop (accent at 0.08) is still legible
  against the tinted card, which is the specific cue the full-accent version would have erased.
