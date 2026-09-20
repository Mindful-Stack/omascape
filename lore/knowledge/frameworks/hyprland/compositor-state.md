---
title: Reading compositor state — snapshots, refresh and the monitor epoch
description: Quickshell's Hyprland models are snapshots, not live views: lastIpcObject changes only when a refresh replaces it, refresh is an async IPC round trip so never rebuild in the same tick, monitorFor() is a one-shot invokable needing the monitorEpoch dependency, and Hyprland.monitors holds non-screens.
tags: [frameworks, hyprland, quickshell, qml, architecture]
---

# Reading compositor state — snapshots, refresh and the monitor epoch

[[adrs/0002-compositor-dispatch-errors]] covers the **write** side: how a Lua chunk reaches the
compositor and how its errors surface. This node is the **read** side, which has its own set of
traps and no record until now.

Measured 2026-09-20 against `origin/main` (`7200771`): **39 `Hyprland.*` references in
production QML and all 39 are in `Overview.qml`**. `LockFrame.qml` is the only other production
file naming Hyprland at all — four lines, every one inside a `//` comment. The layering in
[[general/architecture]] holds without exception.

## Two kinds of read, and only one of them is reactive

| Form | Reactive? | Used as |
|---|---|---|
| `Hyprland.monitors`, `Hyprland.workspaces` | yes, `.values` is a model | `buildInput()` iterates them |
| `Hyprland.focusedMonitor`, `Hyprland.focusedWorkspace` | yes | read inside `buildInput()` |
| `Hyprland.monitorFor(screen)` | **no — one-shot C++ invokable** | needs `monitorEpoch` |
| `monitor.lastIpcObject` | **no — a snapshot object** | needs a `refresh*()` to be replaced |

The last two are where bugs come from, because both *look* like ordinary bindings.

## `lastIpcObject` is a snapshot

`LockFrame.qml:56-59` states it in the source:

> `lastIpcObject` is a SNAPSHOT, not a live view: `Overview.qml` asks for a fresh one
> (`Hyprland.refreshMonitors()`) on the raw events that can change which workspace a monitor
> shows. It is a QML property, so replacing it re-evaluates this binding — which is the whole
> update path for the frame.

So a binding on `lastIpcObject` updates **only** when something calls a `refresh*()`. A component
that binds to it and never triggers a refresh shows the state as of the last time someone else
happened to refresh, indefinitely. That is a stale frame, not a crash — nothing reports it.

## Every refresh call is `typeof`-guarded

Six refresh calls, six guards, no exceptions:

```qml
if (typeof Hyprland.refreshToplevels === "function") Hyprland.refreshToplevels()
if (typeof Hyprland.refreshWorkspaces === "function") Hyprland.refreshWorkspaces()
```

`Overview.qml:1288-1289` (`_reconcileStep`), `1601` (`open`), `1697-1698` (`requestRefresh`) and
`1746` (the event handler). Write the guard. It is the same defensive posture as
[[adrs/0004-qt-compatibility-floor]]: the host Quickshell is whatever the user's Omarchy shipped,
and an ungated call to a method an older build lacks is a `TypeError` inside a signal handler.

## Refresh is asynchronous — never rebuild in the same tick

The comment at `Overview.qml:1689-1695` is the rule:

> Ask Hyprland for fresh client data, then rebuild every 60ms until five quiet ticks have passed,
> so a window opened while the overview is visible appears once its async geometry arrives — **a
> single immediate rebuild would read stale/empty `lastIpcObject` geometry.**

The shape is `requestRefresh()` to ask, `scheduleRebuild()` to start a settle timer, and the
rebuild on the tick. The settle logic also bounds the cost: the first event of a burst refreshes
at once, events arriving while the timer runs extend the window and owe *one* refresh paid on the
next tick — so **at most one refresh per tick regardless of event rate**.

**A refresh is an IPC round trip.** That is why the event handlers filter rather than refreshing
on the whole stream: `Logic.lockFrameRefreshEvent(event.name)` selects the events after which the
workspace a monitor shows may have changed, and `Logic.focusStealingEvent(event.name)` the ones
that took focus. Adding a refresh to the raw event stream is the easy way to make the overlay
cost more than the compositor.

## `monitorFor()` needs the epoch, and the comma operator is how

`Hyprland.monitorFor(screen)` is a C++ invokable returning a one-shot value. **Nothing notifies
QML when Hyprland replaces the `HyprlandMonitor` object for a screen** — a monitor reconfigure
across `configreloaded` does exactly that, without `Quickshell.screens` changing — so a plain
binding keeps a stale or null pointer and that screen's UI stays wrong for good.

`root.monitorEpoch` (`Overview.qml:137`) is bumped wherever the monitor snapshots are refreshed
(`:1749`), and the two bindings that call `monitorFor()` read it through the comma operator so
the dependency is captured:

```qml
monitor: (root.monitorEpoch, Hyprland.monitorFor(modelData))
```

Both sites do this — `reservedTop` (`:289-293`) and the `LockFrame` in `Variants` (`:1776`). **A new
call to `monitorFor()` in a binding needs the same prefix.** Without it there is no error, no
warning and no test failure; the binding simply never re-evaluates.

## `Hyprland.monitors` is not a list of screens

`buildInput()` filters it, and `Overview.qml:389-395` says why: a workspace Hyprland reports on
no monitor (`"monitor": "?"` — a persistent rule whose monitor is absent, or one left behind by
an unplugged display) makes Quickshell **materialise a placeholder monitor of that name with
every field zeroed**, and it arrives the moment a refresh touches that workspace.

Admitted as a screen it turns a one-display machine multi-monitor, and its 0×0 logical size
divides 0 by 0 for the group's cell aspect — the `NaN` reaches the canvas and a card with a NaN
height **paints nothing at all**: the overview maps its surface, takes focus, draws the scrim and
shows no picture. That one was found on a real desktop (`:396-397`), not in a test.

The guard is a zero-size check, and it is one line:

```js
if (!(m.width > 0 && m.height > 0)) continue
```

Two rules follow. **Anything new that iterates `Hyprland.monitors.values` applies the same
check.** And **apply it at the boundary, not at the point of use** — the source comment is
explicit that it is skipped in `buildInput()` rather than filtered later in `layout()` so that
`monNames`, `activeByMon` and the menu's monitor list all agree on what a monitor is. A second
filter downstream is how those three drift apart.

## Leaves receive a monitor, they do not ask for one

The root resolves the `HyprlandMonitor` and passes it down as a plain property:

```qml
LockFrame {
    frameScreen: modelData
    monitor: (root.monitorEpoch, Hyprland.monitorFor(modelData))
}
```

The leaf then reads live properties off it (`monitor.scale`, which *is* reactive) and binds to
`monitor.lastIpcObject` (which is not). This is what keeps the "only `Overview.qml` talks to the
compositor" rule true while leaves still show per-monitor state — see
[[frameworks/quickshell/component-patterns]].

## Unverified assumptions

Three things this node and the actions doctrine lean on have been read from Hyprland's source or
inferred from one machine, never observed:

- **Move and Swap between monitors.** The semantics of `moveworkspacetomonitor` and
  `swapactiveworkspaces` were read from `CWorkspacePlacementController`; the overlay has only ever
  run with one monitor connected during development (`ROADMAP.md` item 10, `DESIGN.md` § Actions).
- **`hl.get_workspace()` with the `special:…` name form.** Close-all on the scratchpad row depends
  on it. If it is not accepted, that row closes nothing and reports "workspace not found" — wrong
  but inert and visible.
- **The docked two-row layout and the external monitor's mini-map coordinates.** The origin and
  scale conversion was checked on `eDP-1` only (`ROADMAP.md` item 1); an unconfigured hotplugged
  monitor is a known, uncaptured misbehaviour (`ROADMAP.md` item 15).

Each is a Tier 2 case waiting to be written. Until then, a change that touches one of them is
changing behaviour nobody has seen.

## See Also

- [[adrs/0002-compositor-dispatch-errors]] — the write side: dispatch, Lua chunks, error surfacing.
- [[learnings/preserve-split-rederives-the-split-axis]] — a compositor default the integration rig has to pin.
- [[learnings/no-anim-layer-rule-stops-double-animation]] — the compositor animating the overlay's layer.
- [[general/architecture]] — why every compositor call is in one file.
- [[frameworks/quickshell/component-patterns]] — how a leaf receives what it needs.
- [[learnings/quickshell-list-is-display-scoped]] — the same snapshot-vs-live trap outside QML.
- [[languages/lua/chunk-authoring]] — what `Hyprland.dispatch` is given.
- [[learnings/overlay-layer-focus-must-be-ondemand]] — the layer-shell side of the same
  compositor boundary.
