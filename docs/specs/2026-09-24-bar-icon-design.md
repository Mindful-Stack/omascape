# Omascape — bar icon: a button in the Omarchy bar that toggles the overview (design)

Date: 2026-09-24 · Target: Omarchy Quattro, Quickshell 0.3.1 · Record:
`lore/knowledge/adrs/0011-bar-icon-surface.md` (proposed).
Status: **designed, not built.** Probes ran 2026-09-24 (results below). The coupling is accepted,
and existing installs migrate with disable + enable (see the decision below).

## Goal

A mouse path to the overview. It's an icon in the top bar, beside the workspaces widget by default
and movable to the left, center or right section. Clicking it does exactly what SUPER+TAB does.

## Scope

**In:** the `bar-widget` kind and its manifest block; `BarWidget.qml`; a per-entry glyph
override; Tier 1 coverage; README and upgrade instructions; the probe.

**Out:** any `omascape.json` key for placement; right or middle click actions; an "overview is
open" highlight; an argument payload on the toggle; editing `shell.json` from Omascape or its
scripts.

## What the shell already provides

Read from `/usr/share/omarchy/shell`:

| fact | source |
|---|---|
| A plugin can be several kinds; `omarchy.menu` is `["menu", "bar-widget"]` with `entryPoints.barWidget` | `plugins/menu/manifest.json` |
| The menu's button is a `BarWidget` wrapping a `WidgetButton` that calls `bar.run(...)` | `plugins/menu/BarWidget.qml` |
| `barWidget.defaultSection` (`left`/`center`/`right`, else `center`) picks the section on first enable | `services/PluginRegistry.qml` `defaultBarWidgetSection` |
| With no explicit placement, the widget goes right after the section's anchor, and the left anchor is `omarchy.workspaces` | `PluginRegistry.qml` `barTarget` |
| `omarchy plugin add` asks for the section, with `defaultSection` preselected | `bin/omarchy-plugin-add` `select_bar_widget_placement` |
| Users move widgets by dragging, `omarchy bar move <id> <section>`, `omarchy bar put <id> --after <id>` | `plugins/bar/README.md`, `bin/omarchy-bar` |
| Widgets receive `bar`, `moduleName` and a per-entry `settings` object, set with `omarchy bar set` | `plugins/bar/README.md` |
| A third-party id is enabled if found in `bar.layout` **or** `plugins`; overlays load only when enabled | `PluginRegistry.qml` `isEnabled`, `shell.qml:331` |

So "configurable left/center/right" already exists, in the shell. Omascape only picks the default.

## Decisions

- **Manifest.**
  ```json
  "kinds": ["overlay", "bar-widget"],
  "entryPoints": { "overlay": "Overview.qml", "barWidget": "BarWidget.qml" },
  "barWidget": {
    "displayName": "Omascape",
    "description": "Opens the workspace overview",
    "category": "Compositor",
    "defaultSection": "left",
    "allowMultiple": false
  }
  ```
  The `description` gains one clause mentioning the optional bar button.

- **Component.** A root-level `BarWidget.qml`, modelled on the menu's: `BarWidget { moduleName:
  "se.mindfulstack.omascape" }` wrapping a `WidgetButton` in the bar's font. On a left press it
  calls `root.bar.run("omarchy-shell shell toggle se.mindfulstack.omascape")`, and it ignores
  other buttons. It has no state, no timers and no Hyprland calls.

- **Glyph.** Default `󰕰` (nf-md-view_grid, U+F0570). If `settings.icon` is a non-empty string it
  replaces the default, set with `omarchy bar set se.mindfulstack.omascape icon <glyph>`. This is
  the only setting.

- **Placement is not ours.** No key in `omascape.json`, and nothing in the plugin writes
  `shell.json`. `OmascapeConfig.qml` stays read-only towards the shell's config.

- **Publishing.** `scripts/publish.sh` already ships every root `.qml`, so `BarWidget.qml` needs
  no change there. The publish run's `omarchy-plugin-validate` gate covers the new manifest.

## The enable coupling, and the probe that gates the build

Reading the code predicts:

1. **Fresh enable** puts the id only in `bar.layout`. Removing the icon removes the only entry,
   so the whole overlay component unloads. That takes more than the keyboard route with it:
   - SUPER+TAB stops working;
   - the **share-time reminder frame** goes away. `LockFrame` lives inside `Overview.qml`, and
     ADR-0008 keeps the component loaded precisely so that the frame exists between summons.
     Removing the icon mid-share would drop the reminder while the share is still running.
   - The blanking itself is compositor-side (`no_screen_share` window and layer rules set by
     Lua chunks, `logic.js`), and probe (a′) confirmed it survives the unload.
2. **Existing installs** keep their `plugins` entry, so the plugin is already enabled.
   **`omarchy bar put` does not add the icon there.** `putBarWidget` returns early only when the
   id is already *in the bar*. Otherwise it calls `setEnabled`, which finds the `plugins` entry
   and inserts nothing. Its fallback `moveBarEntry` then fails with "could not find widget",
   `setEnabled` ignores that and returns true, and `put` reports success. This was confirmed by
   review against the installed registry's functions, and by probe (b). Two migrations, both
   verified by probe (b):
   - `omarchy plugin disable se.mindfulstack.omascape`, then
     `omarchy plugin enable se.mindfulstack.omascape --section left`. Disable removes the
     `plugins` entry (a third-party id is not added to `disabledPlugins`), and enable then takes
     the bar-widget insert path. The result is state 1, coupling included. It also unloads the
     overlay for a moment, so it must not be run during a share.
   - Hand-add `{ "id": "se.mindfulstack.omascape" }` to `bar.layout.left` after
     `omarchy.workspaces`, keeping the `plugins` entry. The result is state 3. No CLI command
     reaches it.
3. **Both entries present:** removing the icon should delete the bar entry first
   (`findEntryLocation` checks the bar before `plugins`), and the `plugins` entry should keep the
   overlay loaded.

Probe, on a real shell against a dev-linked build (Tier 2 / by hand), recorded in this spec:

- (a) **Fresh enable.** Remove the existing entry and run `omarchy plugin enable`. Confirm the
  icon appears after the workspaces, remove it from the bar, then press SUPER+TAB.
- (a′) **Removal during a share.** Starting from (a), arm a workspace and start a screen share
  showing it. Confirm the reminder frame is visible. Remove the icon, then record whether the
  frame disappears and whether the armed workspace is still blanked in the share. Re-enable, and
  record whether frame and blanking come back.
- (b) **Migration**, which gates the upgrade instructions. With only a `plugins` entry, confirm
  that `omarchy bar put` reports success and adds nothing. Then try each candidate above and
  record the resulting `shell.json` and whether the icon appears. Only a candidate that passes
  goes into the README. If neither passes, the README tells existing users to wait rather than
  giving them a command that silently does nothing.
- (c) **Both entries.** Remove the icon, then press SUPER+TAB, and check whether a share
  reminder survives the removal.

### Probe results (2026-09-24)

Run on Hyprland 0.56.2 with one monitor (eDP-1). The build was dev-linked: this spec's manifest
plus a probe `BarWidget.qml`, since discarded. Workspace 1 was armed, and the share was faked with
a `grim` loop at about 6 Hz. That drives `screenshare.state`, and `share-state` read `1`
throughout. Readings:

- **frame** — the `omascape-lockframe` layer count;
- **overlay** — whether a toggle produced the `omascape` layer;
- **blanking** — the mean grey of a crop of the armed workspace's window (0 means black);
- **icon** — a screenshot of the bar.

| step | `shell.json` after | overlay | frame | blanked | icon |
|---|---|---|---|---|---|
| baseline, `plugins` only | `plugins` | loaded | 4 | yes | none |
| (b) `omarchy bar put … --after omarchy.workspaces` | **unchanged**; printed "is on the bar", exit 0 | loaded | 4 | yes | **none** |
| (b) hand-add a bar entry, keep `plugins` | both | loaded | 4 | yes | after workspaces, live, no restart |
| (c) `omarchy plugin disable` with both entries | `plugins` (bar entry removed) | **loaded** | **4** | yes | gone |
| (b) candidate 1, step 1: `disable` again | neither | **unloaded** | **0** | **yes** | none |
| (b) candidate 1, step 2: `enable --section left` | bar `left[2]`, no `plugins` | loaded | 4 | yes | after workspaces |
| (a′) `disable`, from bar-only, mid-share | neither | **unloaded** | **0** | **yes** | gone |
| (a′) `enable` again | bar `left[2]` | loaded | 4 | yes | after workspaces |

What this settles:

- **`omarchy bar put` is worse than a no-op on existing installs.** It claims success: "is on the
  bar". It must never appear in the README.
- **Both migration candidates work.**
  - Candidate 1 (`disable` then `enable --section left`) leaves the fresh-install state, with the
    coupling. It also unloads the overlay, and the frame with it, for the moment in between.
  - The hand edit leaves the both-entries state. Removing the icon there keeps the overlay and
    the frame, but it takes a JSON edit, and `plugin disable` then needs two runs to really
    disable the plugin. Its first run prints "Disabled" while the plugin stays enabled.
- **(a′) The coupling costs the reminder, not the protection.** When the icon is removed from a
  fresh install mid-share, the overlay unloads and the reminder frame disappears. The armed
  workspace **stays blanked** in the capture, because the `no_screen_share` rules and the share
  observer live in the compositor's Lua state (`_G.omascape_lock`), not in QML. Re-enabling brings
  the frame back at once.
- **Not verified:** a real pointer click on the icon, since no pointer tool was available. The
  button runs the same toggle command as the keybind, which the probe did exercise. Also not
  checked: whether a window opened on the armed workspace *while the overlay is unloaded* is
  blanked. The rule matches the workspace, so it should be.
- **A fresh install cannot drop the button from the CLI alone.** Every CLI enable path puts the
  id into `bar.layout`, so removing the button disables the plugin. The icon-less setup is the
  both-entries state from (c): hand-add a `plugins` entry, then one `plugin disable`. The README
  documents it.

### Hand verification (2026-09-26)

Confirmed by hand on the same Hyprland 0.56.2, one-monitor setup, after the probe above:

- **0.** Before migrating (plugins-only): `omarchy plugin list` reports `disabled … overlay,bar-widget`
  while SUPER+TAB still opens the overview — confirms the README wording.
- **1.** `plugin disable` then `plugin enable --section left` puts the button right after
  `omarchy.workspaces`; `plugin list` now shows `enabled`.
- **2.** Mouse (by the owner): left click opens; right- and middle-click do nothing; hover shows
  the tooltip "Workspace overview". **A second click without moving the pointer does nothing** —
  see the bug below; moving the pointer first, then clicking, closes it.
- **3.** `omarchy bar move … center` places it after `omarchy.weather`; `… right` places it after
  `omarchy.tray`; `… left` restores it after the workspaces.
- **4.** `omarchy bar set … icon 󰍺` changes the glyph; `icon ""` restores the default grid glyph.
- **5.** Tooltip: covered in 2.
- **7.** `omarchy bar position left` renders the button in the vertical bar below the workspaces;
  restored to `top` afterward.

#### The dead second click — Hyprland 0.56, not the button

When a layer surface maps under a stationary cursor with keyboard interactivity, Hyprland 0.56.2
(`src/desktop/view/LayerSurface.cpp:203`, commit efb5099) sends `wl_pointer.enter` with the
monitor's layout position subtracted twice (`m_geometry` is already global — `Renderer.cpp`
`arrangeLayerArray` builds it from `full_area = {monitor.position, …}`). On a monitor not at
(0,0) the overview therefore believes the pointer is far outside itself, and a click before any
motion is dropped. Measured with a standalone Quickshell repro under `WAYLAND_DEBUG`: cursor at
(849,2650) on a monitor at (200,1440) → enter at (449.1, −229.8), expected (649, 1210). The
keybind summon has the same dead first click; the button only makes it obvious. Upstream already
removed that code on `main` in d29916a (hyprwm/Hyprland#15899, 2026-08-21), not in any release as
of v0.56.2. A same-position `hl.dsp.cursor.move` after the map makes Hyprland send a correct
motion (verified in the repro); Omascape takes that workaround in a separate PR.

**Decided 2026-09-24: accepted, with the disable + enable migration.** The question was: is it acceptable that removing the icon from a
fresh install unloads the overlay, taking SUPER+TAB and the share reminder frame with it while
the blanking holds (probe (a′))? The answer is the owner's. If it is not acceptable, the icon moves to a `type: "qml"` module whose
removal cannot touch the overlay (ADR-0011's first alternative), and the manifest keeps
`kinds: ["overlay"]`.

## Testing

- **Tier 1, manifest:** `kinds` includes both kinds, `entryPoints.barWidget` names an existing
  root file, and `barWidget.defaultSection` is `"left"`.
- **Tier 1, offscreen UI fixture** (`tests/ui/barwidget.qml`): loads `BarWidget.qml` against stub
  `qs.Ui` `BarWidget` / `WidgetButton` types and a stub `bar` that records `run()` calls. It
  checks that a left press runs the toggle command once, other buttons run nothing, the default
  glyph shows, and `settings.icon` overrides it.
- **Qt 6.9** (ADR-0004): no newer properties and no reserved-word identifiers. `gh pr checks` after
  every push.
- **Not in CI:** real placement beside the workspaces, vertical bars, theming, and the probe. The
  PR says so.

## Docs

- README: a "Bar button" section covering what it does, how to move it (`omarchy bar move`), how to
  add it on an existing install, how to change the glyph, and the enable caveat. The caveat
  covers both SUPER+TAB and the share reminder. The existing-install step contains only a
  migration that probe (b) verified. Without one it says the icon is for fresh installs for now,
  and never shows `omarchy bar put`, which reports success and does nothing.
- ROADMAP: a new item.
- ADR-0011 flips to `accepted` when `BarWidget.qml` lands, and only after the share-reminder
  decision above has been made and written into the record.
