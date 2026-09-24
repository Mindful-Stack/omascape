# Omascape — bar icon: a button in the Omarchy bar that toggles the overview (design)

Date: 2026-09-24 · Target: Omarchy Quattro, Quickshell 0.3.1 · Record:
`lore/knowledge/adrs/0011-bar-icon-surface.md` (proposed).
Status: **designed, not built.** Blocked on the enable-coupling probe below.

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
   so the overlay unloads and SUPER+TAB stops working.
2. **Existing installs** keep their `plugins` entry, so the plugin is already enabled. No icon
   appears until the user runs `omarchy bar put se.mindfulstack.omascape --after
   omarchy.workspaces`.
3. **Both entries present:** removing the icon deletes the bar entry first, and the `plugins`
   entry keeps the overlay alive.

Probe, on a real shell against a dev-linked build (Tier 2 / by hand), recorded in this spec:

- (a) remove the existing entry, `omarchy plugin enable`, confirm the icon appears after the
  workspaces, remove it from the bar, then press SUPER+TAB;
- (b) with only a `plugins` entry, confirm there's no icon, run `omarchy bar put`, and confirm it appears;
- (c) with both entries, remove the icon, then press SUPER+TAB.

The README wording follows the result. If (a) loses the overlay, the README says so next to the
enable instructions and points to `omarchy bar move` instead of removal. If users hit it anyway,
ADR-0011's trigger moves the icon to a `type: "qml"` module.

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

- README: a "Bar icon" section covering what it does, how to move it (`omarchy bar move`), how to
  add it on an existing install, how to change the glyph, and the enable caveat.
- ROADMAP: a new item.
- ADR-0011 flips to `accepted` when `BarWidget.qml` lands.
