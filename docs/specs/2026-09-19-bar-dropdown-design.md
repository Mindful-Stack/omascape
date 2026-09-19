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
  in ordinary use: `Overview.qml:1518` sizes the card to its content and the cap only bites on
  overflow. At 1080 with a 26px bar the cap sits at 1000 while a single-monitor ten-workspace card
  measures roughly 550–600.

- **Full width refunds what card presence cost.** That spec booked its own price: cells shrank
  380 → 360 because the 5% margin takes its cut before `maxCellW` binds. Dropping the horizontal
  margin returns `cw` to ~372 at 1920 logical. Bar mode is a roomier grid, not only a different
  position.

- **The border is the card's own, with its sides pushed off-screen.** Qt 6.4 (CI) has neither
  per-side borders nor per-corner radius — `topLeftRadius` is 6.7+, and an unknown property there
  is a COMPILE error, not a no-op. The prototype answered with three cover-up strips. This is
  cleaner: make the card **2px wider than the panel and sit it at `x = −1`**, so its native border
  runs its left and right edges off-screen. What survives is the bottom edge — and because it is
  Qt's own border it follows the `radius: 20` corner arcs, which an inset strip Rectangle cannot.
  `topFill` from the prototype is kept to erase the top edge (a line along the join would separate
  the card from the bar it is meant to be continuous with); `topEdgeL` and `topEdgeR` are deleted.

  **This cannot bleed onto another monitor**, for two independent reasons. The picker is a single
  layer surface bound to one output (`Overview.qml:1441`, `screen: root.targetScreen`), and a
  layer-shell `wl_surface` is composited onto that output only. And the window is the render
  target: QML draws the scene graph into a framebuffer sized to the window, so the column at
  `x = −1` is discarded by the rasterizer. This is the window boundary, not the QML `clip`
  property. The codebase already depends on the first fact — the `omascape-catcher` PanelWindows
  (`:1407`) exist precisely because the picker's surface cannot reach neighbouring screens.

- **Background follows the surface class.** `Color.bar.background` in bar mode, honouring its
  alpha; `Color.menu.background` unchanged in centred mode. Attached surfaces match the bar,
  detached ones match the menus. This also guarantees the PR cannot alter what PR #24 shipped.

  A translucent `bar.background-alpha` therefore makes a translucent picker. With `scrim: true`
  (the default) the card sits over the scrim, so that reads as a tint over a dimmed desktop, not
  as live windows through the grid. With `scrim: false` it does show live windows; that is the
  user's own combination of settings and is left alone.

## Geometry

| | centred (default) | bar mode |
|---|---|---|
| card anchors | `centerIn: parent` | `left`/`right` at **−1**, `top` at `reservedTop` |
| `transformOrigin` | `Item.Center` | `Item.Top` |
| `availCanvasW` | `panel.width − 2·pad − 2·screenMargin` | `panel.width − 2·pad` |
| `maxCardH` | `panel.height − 2·screenMargin` | `panel.height − reservedTop − screenMargin` |
| scrim top | 0 | `reservedTop` |
| card colour | `Color.menu.background` | `Color.bar.background` |

```qml
readonly property int reservedTop: {
    var m = Hyprland.focusedMonitor, r = m && m.lastIpcObject ? m.lastIpcObject.reserved : null
    return (r && r.length > 1 && isFinite(r[1]) && r[1] > 0) ? Math.round(r[1]) : 0
}
readonly property bool barMode: config.anchor === "bar" && reservedTop > 0
```

Anchoring both `left` and `right` overrides `implicitWidth`, so in bar mode `card.width` is
`panel.width + 2` and the `Behavior on implicitWidth` goes inert. That is correct — the width is
the screen and never animates — but `flick.width` must subtract the 2px overhang rather than
inherit it, or the viewport is two pixels wider than the card's usable interior and the UI test's
width assertion is quietly off by two.

## The staged entrance

**The canvas has no rows.** `canvas` is an `Item` holding absolutely-positioned Repeaters over flat
models; boxes carry `bx/by/bw/bh` (`Overview.qml:1668`) and tiles `wx/wy` (`:1757`). There is no
row object to hang a delay on. `tilesModel` is also reconciled **in place** (`set`, not reassign —
`:478`), so delegates persist across rebuilds and a per-delegate `Component.onCompleted` timer
would fire once at startup and never again.

So the entrance is **one root-level progress property with N bindings**, not N timers:

- `root.entranceProgress`, a real 0 → 1, driven by a single `NumberAnimation` of **fixed** total
  duration (~220 ms) started by `open()`.
- `Logic.rowRanks(boxes)` → `{ ranks: { workspaceId: k }, rowCount: n }`, ranking distinct box `y`
  values ascending, globally across monitor groups so the stagger sweeps the whole card. It reads
  `layout()`'s own `box.y`, upstream of the `by` role mapping at `:1098`.
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

`rowPhase` returns **1** on a non-finite input, not 0. A NaN must never leave the grid invisible —
the same reasoning as `screenMargin`'s guard, where the failure mode was an invisible overlay
holding keyboard focus.

The card's own `enterAnim` (0.96 → 1 from `Item.Top`) is kept: the shade drops, then the rows fill
in. Whether those two together are one gesture or one too many is a by-eye call, listed below.

## Edge cases

- **No top bar** (`reserved[1]` is 0 — a side or bottom bar, or a hidden one): `barMode` is false
  and everything falls back to centred, including the margin, the radius and the background token.
- **`panel.width` is 0 before the surface maps.** The existing guards are untouched; `screenMargin`
  still guards independently.
- **Monitors at different scales.** `reservedTop` is read from the focused monitor and the overlay
  maps on the focused screen, so the two always agree.
- **The bar is hidden mid-session.** `reserved` updates, `barMode` drops to false, and the card
  re-anchors to centred on the next binding evaluation. Harmless; the picker is normally closed.
- **`Style.cornerRadius` is irrelevant here.** `cardRadius` is `boxRadius + pad` = 20, hardcoded,
  so the bottom arcs are a known quantity rather than a theme-dependent one.

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
- Card spans the panel, allowing exactly the 1px overhang per side.
- An overflowing three-monitor layout still honours the bottom cap, and the Flickable still
  scrolls rather than clipping.
- **`reserved[1]` of 0 falls back to centred** — a margin on both sides, as PR #24 asserts.
- `anchor: "center"` leaves the card exactly where `tests/ui/presence.qml` already asserts it is.

**Shared-fixture risk.** `tests/ui/prepare.py`'s config stub needs an `anchor` property, and that
file backs seven suites. The change is purely additive and the default is `"center"`, so no
existing suite's behaviour moves — but this is the highest-stakes edit in the plan, because a
fixture that is wrong here makes every downstream assertion agree with it.

**Visual (manual, both themes) — the two calls that cannot be made from the source:**

- Whether the card's scale entrance **plus** the row stagger is one gesture or one too many. If it
  is too much, the scale is what goes: the stagger is the feature.
- Whether the rounded bottom corners (r=20) read correctly on a full-width surface, or want
  squaring off into a true shade.
- That `Color.bar.background` is genuinely continuous with the bar on a theme that ships a
  `shell.toml` diverging it from `menu.background` — rose-pine-dark cannot show this, as it ships
  no `shell.toml` and both tokens fall through to the same value.
