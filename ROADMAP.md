# Omascape — roadmap / next steps

**Status:** **v2 shipped (2026-09-09).** Overlay on SUPER+P; per-monitor rows; **live window
thumbnails** (Quickshell `ScreencopyView`); **drag-and-drop of windows between workspaces**
(silent move); number/arrow/Enter selection; click-to-focus / middle-click-close. Coordinate
math + reconcile in a unit-tested `logic.js` (Tier 1 CI); Tier 2 nested-Hyprland integration.
Maintained as a standalone public repo (`Mindful-Stack/omascape`). See `DESIGN.md` (what/why),
`docs/specs/` + `docs/plans/` (the v2 design + build), and `PLAN.md` (v1 build log). Window
states (2026-09-10): fullscreen windows drawn in their recovered slot with an un-fullscreen
badge; floating tiles stack above tiled. Hardening (2026-09-10, review follow-up): atomic
floating move, guarded chunk cleanup + error reporting, dwindle guard, event-flood-safe
refresh, selection by workspace id, Lua behaviour suite in CI. Find (2026-09-11): type-ahead
fuzzy window search, see docs/specs/2026-09-11-find-design.md. Scratchpad row (2026-09-12):
Ctrl+S shows special:scratchpad as a trailing row, see docs/specs/2026-09-12-scratchpad-design.md.
Workspace lock (2026-09-12): Ctrl+L arms a workspace's windows black in every screen capture,
see docs/specs/2026-09-12-lock-design.md. Actions (2026-09-17): a single target rule, a
Tab-driven window cursor, Ctrl+W, and a right-click context menu (Close, Float/Tile,
Fullscreen/Exit, Lock/Unlock, Move/Swap monitors, Close all windows), plus a two-tier `?` hint
row, see docs/specs/2026-09-15-actions-design.md.

## Next steps

### 1. Verify when docked (not yet tested — no external display at build time)
- [ ] Overlay opens on the **focused** monitor, not always the primary
      (`focusedScreen()` matches `Hyprland.focusedMonitor.name` → `Quickshell.screens`).
- [ ] Two-row layout renders: laptop `eDP-1` (1–5) and external `HDMI-A-1` (6–10),
      grouped by each workspace's `.monitor`; collapses to one row when undocked.
- [ ] Window mini-map coordinates are correct on the **external** monitor too (the
      origin/scale conversion was only checked on `eDP-1`, origin `(0,1440)` scale `1.25`).

### 2. v2 — both-screens rendering with dimming (the original idea)
Currently a single overlay on the active monitor shows every monitor's workspaces as
stacked rows. v2: render the overlay on **every** screen at once, each screen showing its
own workspaces prominent and the **other** monitor's section **dimmed**. Likely a
`Variants`/per-screen `PanelWindow` keyed on `Quickshell.screens`.

### 3. ~~v2 — live window thumbnails (screencopy)~~ ✅ done (2026-09-09)
Real scaled window pixels via Quickshell `ScreencopyView`, captures only while open. The
toplevel-export path cooperates with Quickshell on Hyprland 0.56.2 — verified live across all
cases: occluded, **cross-output** (a window on another monitor renders live), and **hidden
workspaces** (a workspace not shown on any monitor still captures — case B confirmed). So
`capMode` stays `live` everywhere; the icon fallback remains for windows without a handle.

### 4. ~~v2 — drag-and-drop between workspaces~~ ✅ done (2026-09-09)
Drag a window tile onto another workspace box → `hl.dsp.window.move(follow=false)` (silent).
Overview stays open; post-move `refreshToplevels()` reconcile with bounded recovery.

### 5. Polish / accuracy
- [ ] Better app-icon resolution: current is `Quickshell.iconPath(class.toLowerCase())`
      with a letter fallback; reverse-DNS or mismatched classes fall back to a letter.
      Improve with `DesktopEntries` heuristic lookup or a class→icon map.
- [x] Subtract each monitor's reserved bar area (`monitor.reserved`) — done: the v2 usable-rect
      model maps against `monitor size − reserved`.

### 6. ~~Extract to a standalone repo~~ ✅ done
Extracted from the author's dotfiles into `Mindful-Stack/omascape` (2026-09-07). Installed
per-machine with `omarchy plugin add https://github.com/Mindful-Stack/omascape.git --enable`
and updated with `omarchy plugin update se.mindfulstack.omascape`. See `README.md` for the
consumer-side install + SUPER+P bind.

### 7. ~~Find — type-ahead window search~~ ✅ done (2026-09-11)
Type any letter to fuzzy-filter windows by class and title; see
`docs/specs/2026-09-11-find-design.md`.

### 8. ~~Scratchpad row~~ ✅ done (2026-09-12)
`Ctrl+S` shows `special:scratchpad` as a trailing row; see
`docs/specs/2026-09-12-scratchpad-design.md`.

### 9. ~~Workspace lock~~ ✅ done (2026-09-12)
`Ctrl+L` arms the selected workspace for screen sharing; see
`docs/specs/2026-09-12-lock-design.md`.

### 10. ~~Actions: target, cursor, close, menu~~ ✅ done (2026-09-17), two things unverified
Tab cursor, Ctrl+W, right-click menu (window and workspace actions); see
`docs/specs/2026-09-15-actions-design.md`. Left open, both requiring a check this single-monitor
dev machine cannot do:
- [ ] Move/Swap between monitors, on a real two-monitor rig — the code follows
      `CWorkspacePlacementController` as read from the 0.56.2 source, but the live probe has one
      monitor and skipped both cases by design.
- [ ] Whether `hl.get_workspace()` accepts the `special:…` name form, which Close all on the
      scratchpad row depends on — unprobed; if it's rejected, that row closes nothing and reports
      "workspace not found" instead of silently doing the wrong thing.

### 11. ~~Card presence: screen margin and elevation~~ ✅ done (2026-09-18)
`Logic.screenMargin` (5%, floored at 16) replaces two drifted absolute constants; card border
and a deeper shadow. Fixes a grid that sat 10 px from the edge on a 1920-logical screen (a 4K
panel at 2x) — reported by a tester, never visible on the author's 2048-logical one, where
`maxCellW` clamps first. See `docs/specs/2026-09-18-card-presence-design.md`. The border and
shadow are **unswept by eye** as of this entry.

### 12. Bar-attached drop-down — prototyped, parked (2026-09-18)
Anchor the card to the focused monitor's reserved top strip instead of centring it, so it hangs
off the bar. **Prototyped on branch `dropdown` (`fd6fbe4`), reverted to centred for now** — it
works and the tests pass, but it wants to land on its own terms rather than inside the presence
PR. Two requirements before it ships:
- **It must be a config key, not a replacement.** Centred stays the default; the user chooses.
  `OmascapeConfig` + `Logic.parseConfig` is the place, alongside `scrim`/`hint`/`motion`.
- **Its own PR**, on top of card presence (it depends on `Logic.screenMargin`).

What the prototype already establishes, so it need not be rediscovered:
- `reserved[1]` from `Hyprland.focusedMonitor.lastIpcObject` is the only source for where the bar
  ends — the overlay is an Overlay-layer surface with `exclusionMode: Ignore`, so `panel.height`
  is the whole screen and the bar sits underneath it.
- The entrance is free: `enterAnim` already scales `0.96 → 1`, and `transformOrigin: Item.Top`
  turns it into a drop. No new animation.
- **Square top corners cannot use per-corner radius.** `topLeftRadius` is Qt 6.7+ and an unknown
  property is a *compile* error on CI's Qt 6.4, so it passes locally and breaks the build. Qt 6.4
  has no per-side borders either. The prototype uses three strips over the card's top edge (a
  cover in the card colour, which also removes the top border segment, plus two 1px side strips).
- The scrim must start below the bar, or the card appears to cover the bar rather than hang from it.
- The vertical invariant changes: an attached card keeps no top margin by design, so
  `maxCardH` becomes `panel.height − cardTopY − screenMargin` and tall layouts scroll sooner.
- **Unverified:** whether `card.color` (`Color.menu.background`) reads as continuous with the
  bar's own ground across themes. That is the whole risk of the square-corner treatment and it
  has not been looked at by eye.

## Maintenance gotchas (verified in-session)
- **Editing `Overview.qml` requires `omarchy restart shell`** — `omarchy-shell shell
  rescanPlugins` reloads the registry but NOT the live QML component.
- New plugins default **disabled** — `omarchy plugin enable se.mindfulstack.omascape` (stored
  in `~/.config/omarchy/shell.json` `plugins[]`).
- `omarchy plugin add` clones into `~/.config/omarchy/plugins/<manifest id>/`, i.e.
  `se.mindfulstack.omascape/` — the folder is named after the manifest `id`, not the repo.
- SUPER+P toggles open AND close even under the overlay's exclusive keyboard focus
  (Hyprland forwards configured keybinds over the layer); bare keys still reach the overlay.
- **Every compositor operation is one atomic Lua chunk** (`logic.js`: `tiledInsertLua`,
  `floatingMoveLua`, `unfullscreenLua`) — kept on its own merits, not because of `keepLoaded`.
  Chunk failures are printed to the Hyprland log (`[Lua] omascape: … failed: …`) and shown as a
  notification. `manifest.json` sets `keepLoaded: true` (the exit fade needs the component
  alive after `close()`, and the reconcile tail that clears optimistic display state can then
  finish too; no compositor operation depends on it — each is a single atomic chunk), so
  cross-summon state now exists: `tilesModel`/`boxesModel` and the
  Flickable's scroll position survive between summons. `open()` reconciles it — `rebuild()`
  re-derives the models from fresh compositor data, and the scroll position is reset to
  `(0, 0)` so a kept-loaded offset never leaks into the next summon.
- **`hl.dispatch` never raises** (0.56.2 `hlDispatch`): a failed dispatcher returns
  `{ ok = false, error = … }`. Every chunk defines `run(d)` that raises on that inside its pcall;
  dispatch a guarded step through `run(`, never bare `hl.dispatch(` (the shape test enforces it).
- `tests/lua-check.sh` runs the generated chunks against a mock `hl` (`tests/lua/`); a new
  dispatcher used by a chunk must be added to the mock, never stubbed as a no-op.
- Coalesced refresh: an event while the settle timer runs *owes* a refresh on the next tick.
  Never skip it — a request already in flight cannot contain the change the event announces
  (the nested-compositor un-fullscreen case catches this).
- **Every new compositor chunk must raise the count guard in `tests/lua-check.sh`** (currently 24)
  — it fails the build if fewer chunks than expected parse, which is the only thing standing
  between a chunk that silently failed to generate and a green test run.
- **Right-button presses must stay out of the drag release path.** `onReleased` submits a drop or
  a click only for `Qt.LeftButton`; treating every non-middle release as a possible drop (the
  pre-actions behaviour) would let a right release during a left drag submit a drop instead of
  opening a menu.
- **A mock that doesn't reproduce the side effect a chunk exists to undo can't test that chunk's
  ordering.** The Lua mock's `window.float` was extended to actually move the active window onto
  the floated window, because `restoreFocusLua`'s whole job is moving focus back — a mock that
  leaves focus alone gives the ordering nothing to restore and nothing to fail on if it breaks.
