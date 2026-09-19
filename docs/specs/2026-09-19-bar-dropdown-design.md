# Omascape — bar drop-down: anchoring the picker to the top bar (design)

Date: 2026-09-19 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1 ·
builds on card presence (`presence`, PR #24).
Status: **designed, not built.** Supersedes the parked prototype on branch `dropdown` (`fd6fbe4`),
which is kept only because ROADMAP item 12 cites it.

## Goal

Offer the picker as a full-width shade that drops out of the top bar and reads as continuous with
it, as an alternative to today's centred card. Opt-in: a config key, centred stays the default.

## Scope

**In:** an `anchor` config key; bar-attached geometry at full width; a bottom-edge-only border;
the bar's own background token; a staged per-row entrance; Tier 1 and UI coverage.

**Out:** bottom / left / right bars; per-monitor anchoring; blur behind the card; any change to
the centred mode's appearance; restyling Omarchy's bar itself (omascape is a plugin and does not
own that surface).

## What the bar actually is

Read from `/usr/share/omarchy/shell` rather than assumed, because three of these contradict the
obvious guess:

| fact | source |
|---|---|
| The bar is **full-bleed and flush** — anchored `top/left/right`, zero margins, square corners | `plugins/bar/Bar.qml:1027` |
| Its height is `Style.bar.sizeHorizontal`, default **26** | `Commons/Style.qml:342` |
| It paints **`Color.bar.background`**, a token omascape does not use (we paint `Color.menu.background`) | `Bar.qml:71` |
| Real popups (bluetooth, wifi) are **detached** — `margin: Style.gapsOut` below the bar, fully rounded, border `Color.popups.border` = accent at **alpha 1.0, 2px** | `Ui/PopupCard.qml` |
| The bar can be hidden; hiding parks it off-screen and flips it to `ExclusionMode.Ignore` | `Bar.qml:1013` |

Two consequences drive the design. Because the bar is edge-to-edge, only a **full-width** card can
read as continuous with it — a centred one always reads as a separate object hanging underneath.
And because `bar.background` is a distinct token, "match the bar" is a token change, not a shade
tweak: on a theme without a `shell.toml` (rose-pine-dark, the author's) both fall through to
`Color.background` and match by accident, so the difference is invisible until a theme diverges
them.

The popup border is deliberately **not** adopted. That border belongs to a floating, rounded,
detached card; on a flush full-width surface its left and right runs would sit on the screen edge
and ring the display.

## Decisions

- **One key, two coherent looks.** `anchor: "center" | "bar"`, default `"center"`. Full width is
  not a second key: it is what bar mode *is*. Validated in `Logic.parseConfig` exactly like
  `motion` — an unknown value falls back to the default and never changes behaviour.

- **Top bar only.** `reserved[1]` is the top strip. A left, right or bottom bar reports 0 there,
  and so does a hidden bar. Both fall back to centred, silently and correctly. Following the bar
  to another edge would flip the stagger direction and the corner treatment; not until asked.

- **Full width, with the bottom cap kept.** `maxCardH` still subtracts one `screenMargin`, so an
  overflowing layout stops short of the screen edge instead of running into it. This is invisible
  in ordinary use: `Overview.qml:1526` sizes the card to its content and the cap only bites on
  overflow. At 1080 with a 26px bar the cap sits at 1000 while a single-monitor ten-workspace card
  measures roughly 550–600.

- **Full width refunds what card presence cost.** That spec booked its own price: cells shrank
  380 → 360 because the 5% margin takes its cut before `maxCellW` binds. Dropping the horizontal
  margin returns `cw` to ~372 at 1920 logical. Bar mode is a roomier grid, not only a different
  position.

- **Square corners in bar mode, and the border is a hairline child.** ✎ *(rewritten after review,
  2026-09-19 — the first draft got this wrong twice; see "What the review changed".)* In bar mode
  the card takes `radius: 0` and `border.width: 0`, spans exactly `panel.width`, and carries the
  bottom rule as a 1px child `Rectangle` anchored to its bottom edge, full width, accent at 0.35.

  Squaring the bottom is not a taste call any more — it is what makes the surface correct. With
  no radius there are no top corners to hide, so nothing is painted over the card; there are no
  bottom arcs for a strip to fail to follow; and the card needs no horizontal overhang, so nothing
  depends on geometry sitting off-screen. The background is painted exactly **once**, which is the
  only way the chosen translucent `bar.background` can composite correctly.

  A full-width shade with a square bottom edge is also the standard idiom for this shape — a
  notification shade, a browser find bar — so the simpler construction is also the better-looking
  one.

- **Background follows the surface class.** `Color.bar.background` in bar mode, honouring its
  alpha; `Color.menu.background` unchanged in centred mode. Attached surfaces match the bar,
  detached ones match the menus. This also guarantees the PR cannot alter what PR #24 shipped.

  A translucent `bar.background-alpha` therefore makes a translucent picker. With `scrim: true`
  (the default) the card sits over the scrim, so that reads as a tint over a dimmed desktop, not
  as live windows through the grid. With `scrim: false` it does show live windows; that is the
  user's own combination of settings and is left alone.

- **The bar is resolved from `targetScreen`, not from live focus.** ✎ *(added after review.)*
  `open()` captures `root.targetScreen` once (`Overview.qml:1449` binds the surface to it), but
  `Hyprland.focusedMonitor` is live. Focus can move to another monitor while the picker is open,
  and the two monitors may reserve different amounts — different bar scales, or no top bar at all.
  Reading live focus would then re-anchor the card, resize `maxCardH`, or flip `barMode` off
  underneath an open picker. `reservedTop` must resolve through `Hyprland.monitorFor(targetScreen)`,
  using the established `monitorEpoch` comma-dependency (`Overview.qml:108`, `:1407`) because
  `monitorFor` is a one-shot C++ invokable that nothing re-notifies when Hyprland replaces the
  monitor object for a screen.

- **No card scale in bar mode.** ✎ *(added after review.)* `enterAnim` scales the card 0.96 → 1
  and `exitAnim` to 0.98 (`Overview.qml:1310`, `:1320`). `transformOrigin: Item.Top` moves the
  pivot to the top *centre* — it does not stop horizontal scaling. On a 1920 panel the card's
  sides would travel **38.4 px inward during the entrance and 19.2 px during the exit**, which is
  precisely the failure the first draft's off-screen border depended on not happening. Squaring the
  corners removes the off-screen dependency, but a card that visibly shrinks away from both screen
  edges still contradicts "continuous with the bar". So in bar mode the entrance and exit are
  **opacity only**, and the row stagger carries the motion. This also settles, in the same stroke,
  the open question about whether scale plus stagger was one gesture too many.

## Geometry

| | centred (default) | bar mode |
|---|---|---|
| card anchors | `verticalCenter` | `AnchorChanges` in a `State` — `top` at `reservedTop` † |
| card width | content, capped by `maxCardW` | exactly `panel.width` |
| `radius` / `border` | 20 / 1px accent all round | **0 / none** — bottom rule is a child |
| entrance + exit | opacity **and** scale | **opacity only** |
| `availCanvasW` | `panel.width − 2·pad − 2·screenMargin` | `panel.width − 2·pad` |
| `maxCardH` | `panel.height − 2·screenMargin` | `panel.height − reservedTop − screenMargin` |
| scrim top | 0 | `reservedTop` |
| card colour | `Color.menu.background` | `Color.bar.background` |

```qml
// Resolved from the screen the picker is ON, not from live focus: open() captures
// targetScreen once, and focus may move to a monitor reserving a different amount --
// or none. monitorEpoch is the dependency, per the reminder frame's binding (:1407).
readonly property int reservedTop: {
    var m = (root.monitorEpoch,
             root.targetScreen ? Hyprland.monitorFor(root.targetScreen) : null)
    var r = m && m.lastIpcObject ? m.lastIpcObject.reserved : null
    return (r && r.length > 1 && isFinite(r[1]) && r[1] > 0) ? Math.round(r[1]) : 0
}
readonly property bool barMode: config.anchor === "bar" && reservedTop > 0
```

† **Not a ternary yielding `undefined`.** ✎ *(added after review, 2026-09-19.)* A QML binding whose
expression evaluates to `undefined` is **destroyed**, not skipped for that evaluation, so
`verticalCenter: barMode ? undefined : parent.verticalCenter` survives exactly one flip and then
stays corrupt — silently, with no anchor-conflict warning. Reproduced: centred y=100 → bar y=26 →
back to centred y=**26**. The card is never recreated across `open()`/`close()` and `barMode` can
flip live (hiding the bar drops `reservedTop` to 0), so one occurrence permanently corrupts the
**default** centred mode for every user. `AnchorChanges` inside a `State` is what QML provides for
this; it reverses cleanly on state exit and is Qt 5.0+, so CI-safe. Verified over three cycles.

Anchoring both `left` and `right` overrides `implicitWidth`, so in bar mode `card.width` is
`panel.width` and the `Behavior on implicitWidth` goes inert. That is correct — the width is the
screen and never animates. `flick.width` needs no correction, since the card no longer overhangs.

## The staged entrance

**The canvas has no rows.** `canvas` is an `Item` holding absolutely-positioned Repeaters over flat
models; boxes carry `bx/by/bw/bh` (`Overview.qml:1676`) and tiles `wx/wy` (`:1765`). There is no
row object to hang a delay on. `tilesModel` is also reconciled **in place** (`set`, not reassign —
`:478`), so delegates persist across rebuilds and a per-delegate `Component.onCompleted` timer
would fire once at startup and never again.

So the entrance is **one root-level progress property with N bindings**, not N timers:

- `root.entranceProgress`, a real 0 → 1, driven by a single `NumberAnimation` started by `open()`
  over `root.motion.enter` — the existing 200 ms token, not a new constant, so the entrance keeps
  following the motion policy and the suites' `motion.scale` hook for free.
- `Logic.rowRanks(boxes)` → `{ ranks: { workspaceId: k }, rowCount: n }`, ranking distinct box `y`
  values ascending, globally across monitor groups so the stagger sweeps the whole card. It reads
  `layout()`'s own `box.y`, upstream of the `by` role mapping at `:1106`.
- `Logic.rowPhase(progress, rank, rowCount)` → 0..1 for that row. Each row's ramp occupies a fixed
  `span` ≈ 0.6 of the timeline and the starts are spread across the remainder —
  `stride = (1 − span) / (rowCount − 1)`, with a single row being simply `progress`. So **more rows
  tighten the stagger and the total never grows**, and the last row lands exactly at 1 by
  construction rather than by tuning.
- Each box binds `opacity: phase` and a `Translate { y: (1 − phase) · 10 }`. A transform, not `y`,
  so the entrance never fights the existing `Behavior on y` layout motion. Tiles look up their rank
  by `workspaceId`, so a tile can never stagger out of step with the box it sits in.

Exact float equality is safe: `logic.js:263` assigns `y: y` from one shared accumulator, so every
box in a sub-row carries the identical value by construction, not by coincidence.

Three properties this must hold:

- **Once per open.** Because progress is root-level and delegates persist, a mid-session reconcile
  (a window moved, a workspace switched) cannot re-trigger it — progress is already 1. Only
  `open()` restarts it.
- **Motion policy is obeyed.** `motionEffective === "off"`, or `!config.motionResolved`, sets
  progress to 1 immediately with no animation. Motion never starts on a guess, per the existing
  rule.
- **Bar mode only.** A top-down stagger under a card that scales from its centre reads as a bug.

`rowPhase` never returns **0** for a non-finite input. ✎ *(corrected 2026-09-19: an earlier draft
said it "returns 1", which is true only of a non-finite `progress`. A non-finite `rank` degrades to
rank 0 and a non-finite `rowCount` to no stagger — all still visible, none of them 1.)* A NaN must
never leave the grid invisible — the same reasoning as `screenMargin`'s guard, where the failure
mode was an invisible overlay holding keyboard focus.

The card's own scale animation is **not** used in bar mode (see the decision above): the shade
fades in at full size while the rows drop into it. `card.scale` stays 1, so `SoftShadow`'s
`scale: card.scale` binding needs no special case either.

## Edge cases

- **No top bar** (`reserved[1]` is 0 — a side or bottom bar, or a hidden one): `barMode` is false
  and everything falls back to centred, including the margin, the radius and the background token.
- **`panel.width` is 0 before the surface maps.** The existing guards are untouched; `screenMargin`
  still guards independently.
- **Monitors at different scales.** `reservedTop` is read from the focused monitor and the overlay
  maps on the focused screen, so the two always agree.
- **The bar is hidden mid-session.** Now that `reservedTop` keys off `targetScreen`, only hiding
  the bar on the picker's *own* screen can affect it: `reserved` updates, `barMode` drops, and the
  card re-anchors to centred. That re-anchor is correct — there is no longer a bar to hang from —
  and it is the one case where a live re-anchor is wanted, as against the focus-change case above,
  where it is not.
- **`Style.cornerRadius` is irrelevant here.** `cardRadius` is `boxRadius + pad` = 20, hardcoded
  rather than theme-derived — and in bar mode it is not used at all, since the card squares off.

## Tests

**Tier 1 (`logic.js`, pure, CI):**

- `parseConfig`: `anchor` accepted for `"center"` and `"bar"`; an unknown string, a non-string and
  a missing key all yield `"center"`.
- `rowRanks`: fed the **real output of `layout()`** for a three-monitor fixture, not hand-written
  boxes. This is the assertion that matters — a hand-built input would prove the ranking function
  sorts, while saying nothing about whether real layout rows share an exact `y`. Assert
  `rowCount` equals the number of sub-rows across all groups, and that a workspace in the second
  monitor's first sub-row ranks above 0 — which is what distinguishes global ranking from
  per-monitor ranking.
- `rowPhase`: `0` at `progress` 0 and `1` at 1 for every rank; **row 1 strictly lags row 0 at a
  mid-timeline progress** (the discriminator — wire the rank wrong, or drop the stride, and these
  collapse to equal); the last row has not yet reached 1 just before the end; a non-finite input
  returns 1.

**UI — new `tests/ui/dropdown.qml`**, registered by hand in `tests/ui/run.sh` (the UI suites are
not auto-discovered):

- Card top equals `reservedTop`.
- Card spans the panel exactly — `card.width === panel.width`, `card.x === 0`.
- An overflowing three-monitor layout still honours the bottom cap, and the Flickable still
  scrolls rather than clipping.
- **`reserved[1]` of 0 falls back to centred** — a margin on both sides, as PR #24 asserts.
- `anchor: "center"` leaves the card exactly where `tests/ui/presence.qml` already asserts it is.

✎ *(the three below were added after review, 2026-09-19.)*

- **Rendered bounds stay pinned to the screen edges throughout entrance AND exit.** Sample
  `card.x` and `card.width` mid-animation — not only at rest — and assert the card still spans
  the panel. This is the assertion the first draft needed and did not have: at rest, a scaled and
  an unscaled card are identical, so an end-state-only check passes against the very bug it is
  supposed to catch. Drive it through the existing `motion.scale` test hook (`Overview.qml:215`)
  rather than by waiting on wall-clock.
- **Focus moving to a monitor with a different top reservation does not move the card.** Open on
  a monitor reserving 26, then point `Hyprland.focusedMonitor` at one reserving 52, and assert
  `card.y` and `maxCardH` are unchanged. Also flip the second monitor to reserving 0 and assert
  `barMode` does not drop — the picker must not re-anchor underneath itself.
- **A translucent `bar.background` composites to exactly one fill.** Set the card colour to 50%
  alpha and assert no region of the card reads more opaque than another — specifically that no
  band exists along the top edge. This is what would have caught `topFill`: two stacked 50% fills
  yield 75%, and the end result looks deliberate unless something measures it.

**Shared-fixture risk.** `tests/ui/prepare.py`'s config stub needs an `anchor` property, and that
file backs seven suites. The change is purely additive and the default is `"center"`, so no
existing suite's behaviour moves — but this is the highest-stakes edit in the plan, because a
fixture that is wrong here makes every downstream assertion agree with it.

**Visual (manual, both themes) — the two calls that cannot be made from the source:**

- Whether an opacity-only entrance feels flat without the scale. If it does, the fallback is a
  **vertical-only** `Scale` transform (`xScale` pinned to 1, `origin.y: 0`) — never the uniform
  `scale` property, which is what broke the first draft.
- That the 1px accent rule reads on the bottom edge at full width without looking like a seam.
- That `Color.bar.background` is genuinely continuous with the bar on a theme that ships a
  `shell.toml` diverging it from `menu.background` — rose-pine-dark cannot show this, as it ships
  no `shell.toml` and both tokens fall through to the same value.

## What the review changed

Three defects were found in the first draft of this spec (2026-09-19), all of them mine, all
confirmed against the source before being accepted:

1. **The scale animation broke the off-screen border.** The draft pushed the card 1px past each
   screen edge so its side borders fell outside the surface, then kept a uniform 0.96 → 1 scale.
   `Item.Top` moves the pivot but does not stop horizontal scaling: the sides would travel 38.4 px
   inward on entrance and 19.2 px on exit, displaying the borders the whole trick existed to hide.
2. **`topFill` could not cover a translucent card.** The draft kept the prototype's rectangle
   painted over the card's top in `card.color`, while simultaneously specifying a background that
   honours alpha. Two stacked 50% fills composite to 75%, and the border beneath stays partly
   visible.
3. **`reservedTop` followed live focus rather than the picker's own screen.** `open()` captures
   `targetScreen` once; `Hyprland.focusedMonitor` keeps moving.

(1) and (2) shared a root cause — the overhang and the cover-up were two workarounds for the same
thing, keeping a 20px corner radius on a surface that is flush on three sides. Squaring the corners
in bar mode removes both workarounds instead of repairing them, and the resulting construction is
strictly simpler: one fill, no overhang, no cover-up strips, and no dependence on off-screen
geometry. (3) is fixed by resolving through `Hyprland.monitorFor(targetScreen)`.

The draft's own "visual check" list had named the bottom-corner radius as an open taste call. It
was not a taste call; it was load-bearing, and leaving it open is what let two defects through.
