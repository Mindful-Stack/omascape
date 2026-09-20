---
title: Ubiquitous language — the words Omascape's code and specs share
description: The overview's vocabulary, each term defined where the code defines it: card, well, box, tile, group, chip band, cursor vs selection vs target, synthetic workspaces, slots, reconcile, latch, armed, peek and mini-map — plus the one word that is specced but not built.
tags: [domain, architecture, qml, javascript]
---

# Ubiquitous language — the words Omascape's code and specs share

The specs, the QML and `logic.js` all use the same words, and none of them defines those words in
one place. This is that place. Counts and locations are 2026-09-20 against `origin/main`
(`7200771`).

Read [[domain/targeting-and-pointer-liveness]] for how *target*, *cursor* and *selection* interact
— this node only says what each one is.

## The surface

| Term | What it is |
|---|---|
| **overview** / **picker** | The whole overlay. One `PanelWindow` per screen, summoned and dismissed, not a persistent surface. |
| **card** | The picker's own visible surface — the rounded, elevated panel the grid sits on. Distinct from the scrim behind it, which fills the screen. |
| **bar mode** | `barMode` (`Overview.qml:297`): `config.anchor === "bar" && reservedTop > 0`. The card squares itself against the top bar instead of floating centred. **A side, bottom or hidden bar means no attachment** — there is nothing to hang from, so the card stays centred. |
| **scrim** | The dimmed ground painted over the desktop while the picker is up. |

## The grid

| Term | What it is |
|---|---|
| **well** | A workspace's place in the grid — the container a workspace's tiles are drawn in. 35 references. |
| **box** | The laid-out rectangle for one well, as `Logic.layout()` computes it. `boxes` is the array; `boxesModel` is the QML model reconciled from it; `Logic.hitWorkspace(boxes, …)` hit-tests it. |
| **tile** | One window's rectangle inside a well — `WindowTile.qml`, `tilesModel`, `Logic.tileAt(candidates, …)`. A tile is a window; a box is a workspace. |
| **group** | A monitor's set of wells. Groups are ordered by the lowest **real** workspace id each monitor holds, so they read 1..10 top to bottom, and the ordering is **fixed regardless of focus** — the focused group is *marked*, not moved (`logic.js:9-13`). |
| **chip band** | The per-group header carrying the monitor chips (`headerH`). Laid out **only when there is more than one monitor group**; the scratchpad group is extra and always carries its own chip. |
| **synthetic** / **padded** | A well for a workspace the compositor does not have, added by `Logic.padWorkspaces` (`logic.js:158`) so the grid shows a stable 1..N. Synthetic wells never take part in the monitor ordering key, because they are the one thing that can differ between two focus states. See [[general/workspace-grid-defaults]]. |
| **placeholder** | A monitor entry Quickshell materialised for a workspace on monitor `"?"`, with every field zeroed. Not a screen — see [[frameworks/hyprland/compositor-state]]. |

## Selection, cursor, target

These three are distinct and the specs never use one for another:

| Term | What it is |
|---|---|
| **selection** | `selectedId` — the **workspace** the keyboard is on. |
| **cursor** | `cursorAddress` — the **window** the keyboard is on, within a workspace. Always a window; "cursor" never means the mouse pointer in this codebase. The mouse is the **pointer**. |
| **target** | The subject of the next action, resolved from pointer, query, cursor and selection by `Logic.target`. May be `null`, and `null` is a real answer. |
| **pointer liveness** | `pointerLive` — whether the mouse has moved since the overview opened, and therefore whether it gets to name the target. |
| **action key** | A key that acts on the target and so reads liveness rather than clearing it: `Ctrl+W`, `Return`/`Enter`, `Space`. |

## State and mechanics

| Term | What it is |
|---|---|
| **reconcile** | Updating a model **in place**, keyed by identity, rather than rebuilding it — so delegates persist across a rebuild and animations are not restarted. `tilesModel` and `boxesModel` are both reconciled this way (`Overview.qml:324-327`, `:1411`). |
| **pending move** | An optimistic local move held in `pendingMoves` with a deadline, waiting for the compositor to confirm it. Past the deadline the tile returns to authoritative geometry. |
| **slot** | A dwindle slot — the partition of a workspace's usable rect that a window occupies. It matters because fullscreen hides the other windows *without moving them*, so the hole a fullscreen window leaves is the slot it returns to (`logic.js:89-90`). |
| **latch** | A one-press memory that makes the next press mean something different. Two exist: the `select` policy's digit latch, which stores the **previous key code** (`Logic.digitActivate`), and the peek's cancel latch, which holds a cancelled hold dead until `Space` is physically released. |
| **armed** | A workspace marked for the share-time reminder frame. `armed` is lock state, persisted by `OmascapeLocks.qml` — see [[adrs/0005-lock-state-persistence]]. Not a UI mode. |
| **scratchpad** | Hyprland's special workspace, remapped onto the constant `SCRATCHPAD_ID = -2` because Hyprland allocates special ids dynamically. `hasWs()` treats it as a real workspace; only `-1` means "none". |
| **peek** | Holding `Space` to preview the target: a window preview, or a **mini-map** of a whole workspace. The mini-map is the peek's workspace rendering, reconciled by identity like the main grid. |
| **motion** | The single root-owned animation object every `duration:` and `easing.type:` dereferences — see [[frameworks/quickshell/theming-and-motion]]. |

## One word that is not behaviour yet

**shove** — `Shift`+arrow taking the target one container in that direction (a window's container
is a workspace; a workspace's container is a monitor). It is fully specced and reviewed in
`docs/specs/2026-09-18-shove-design.md`, **and there are zero occurrences of it in production
code**. Its spec also proposes a refinement to the action-key doctrine — `Logic.isActionKey`
growing a `shift` parameter, and a latch-then-clear ordering — which is likewise not built:
`isActionKey` takes three parameters on `main`.

Treat that spec as a design, not a description. If you implement it, the doctrine node needs
updating in the same PR.

## See Also

- [[domain/targeting-and-pointer-liveness]] — how target, cursor, selection and liveness combine.
- [[general/architecture]] — which of these live in `logic.js` and which in QML.
- [[general/workspace-grid-defaults]] — why the grid pads to a fixed count.
- [[frameworks/quickshell/theming-and-motion]] — the card's colour and motion contracts.
