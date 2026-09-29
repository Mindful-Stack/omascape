---
title: "ADR-0011: The bar icon is a host-owned bar widget, and the shell owns its placement"
description: "Omascape adds a bar icon by declaring the bar-widget kind beside overlay, with defaultSection left, because the Omarchy shell already owns widget placement in shell.json; Omascape adds no placement key of its own."
tags: [adr, architecture, omarchy, quickshell, qml]
status: accepted
date: 2026-09-24
deciders: [Daniel Thyselius]
confidence: low
---

# ADR-0011: The bar icon is a host-owned bar widget, and the shell owns its placement

## Status

Proposed 2026-09-24. Design: `docs/specs/2026-09-24-bar-icon-design.md`.

Open before acceptance: whether it is acceptable that removing the icon from a fresh install
unloads the overlay, taking SUPER+TAB and the share reminder frame with it while the blanking
holds. Probes (a′) and (b) ran on 2026-09-24; the results are in the spec.

Decided 2026-09-24 (Daniel Thyselius): **the coupling is accepted.** Removing the icon never
exposes an armed workspace, because the blanking holds. What it costs is convenience and the
reminder, and both come back when the plugin is re-enabled. The README states the consequence
next to the icon instructions. Existing installs migrate with `omarchy plugin disable
se.mindfulstack.omascape && omarchy plugin enable se.mindfulstack.omascape --section left`,
marked "not during a share". Acceptance still waits on the first dependent code.

Accepted 2026-09-26. First dependent code: `BarWidget.qml`, `manifest.json` (branch `feat/bar-icon`).

## Context

Omascape is summoned only by a keybind today (`omarchy-shell shell toggle
se.mindfulstack.omascape`). A bar icon gives a mouse path to the same toggle. The request was an
icon beside the workspaces widget, with its position configurable as left, center or right.

The Omarchy shell (read from `/usr/share/omarchy/shell`) already has everything this needs:

- A plugin may declare the `bar-widget` kind next to its other kinds, with an
  `entryPoints.barWidget` component. `omarchy.menu` does exactly this (`kinds: ["menu",
  "bar-widget"]`), and its button is a 20-line `BarWidget` + `WidgetButton`.
- `manifest.barWidget.defaultSection` picks the section on first enable. `PluginRegistry.barTarget`
  then inserts the widget after a per-section anchor, and the left anchor is `omarchy.workspaces`.
- After that, placement lives in `shell.json` `bar.layout`, and the user changes it by dragging,
  with `omarchy bar move` / `omarchy bar put`, or through the install prompt, which offers the
  section with `defaultSection` preselected.

A third-party plugin counts as enabled when its id is found in `bar.layout` **or** in
`plugins` (`PluginRegistry.isEnabled` → `findEntryLocation`), and `shell.qml` loads overlays only
for enabled ids. So one id now serves two surfaces with one enable switch. This is read from code
and not yet observed on a running shell.

## Considered options

- **A second kind on the existing plugin (`overlay` + `bar-widget`).** Native install prompt,
  placement, drag and theming; the same model as the first-party menu.
- **A `type: "qml"` custom bar module shipped in the repo.** No manifest change, and removing the
  icon can never disable the overlay, because the module is not the plugin's id.
- **An Omascape config key (`omascape.json`) for left / center / right**, applied by Omascape
  calling `omarchy bar move`. Keeps every Omascape preference in one file, as the request framed it.

## Decision

**Omascape declares `bar-widget` beside `overlay` and sets `barWidget.defaultSection: "left"`;
placement is owned by the shell's `bar.layout`, and no Omascape config key, script or component
ever reads or writes the icon's position.**

Rules this implies:

- `BarWidget.qml` only toggles the overlay through `omarchy-shell shell toggle
  se.mindfulstack.omascape`, the keybind's command, so both routes run the same `open()`
  ([[adrs/0008-keep-loaded-overlay]]).
- The widget is static: no polling, no compositor calls, no state mirrored from the overlay. Left
  click only; the toggle takes no payload, so no argument contract exists.
- The glyph is the only knob, and it is a per-entry shell setting (`settings.icon`), set with
  `omarchy bar set`, not an `omascape.json` key.

## Consequences

- Placement has one source of truth. An `omascape.json` key would have given two, which disagree
  the moment the user drags the icon.
- The icon inherits the bar's theme, vertical-bar handling and widget picker at no cost.
- **Negative: enable is shared, and so is the share reminder.** On a fresh `omarchy plugin add
  --enable`, the id goes only into `bar.layout`. Removing the icon from the bar then likely
  unloads the whole overlay component. That takes SUPER+TAB with it, and it also takes the
  `LockFrame` share-time reminder, which lives in `Overview.qml`. The reminder is the reason
  [[adrs/0008-keep-loaded-overlay]] keeps the component loaded, so a bar gesture can now undo
  what that record relies on, even in the middle of a share. Probe (a′) measured it: the frame
  goes, and the armed workspace **stays blanked**, because the `no_screen_share` rules and the
  share observer live in the compositor's Lua state, not in QML.
- **Negative: existing installs get no icon on their own.** Their `plugins` entry already counts
  as enabled. `omarchy bar put` then inserts nothing, and it prints "is on the bar" and exits 0
  (probe (b)). Two migrations were verified: `omarchy plugin disable` then `enable --section
  left`, which gives the fresh-install state; or a hand-added bar entry beside the `plugins`
  entry, which keeps the overlay loaded when the icon is removed.
- `manifest.json` changes `kinds` and `entryPoints`, which is visible to the marketplace and rides
  the next release.
- `BarWidget.qml` imports `qs.Ui` from the host, so its Tier 1 fixture needs stubs for
  `BarWidget` and `WidgetButton`, and those stubs can drift from the real ones.
- "Nothing runs until you summon it" stays true: a static button does no work.

## Assumptions and invalidation triggers

- *Assumes the shell keeps `bar-widget` and `defaultSection` stable.* Trigger: Omarchy renames
  or drops either, or `omarchy plugin validate` rejects the manifest ⇒ amend.
- *Assumes the enable coupling is tolerable once documented.* Trigger: the blanking stops
  surviving an unload (probe (a′) showed it does today), or users report losing the keybind or the
  reminder that way ⇒ supersede with the `type: "qml"` module option.
- *Assumes one left-click action is enough.* Trigger: a second click action is wanted ⇒ amend;
  it needs a toggle-payload contract, which is its own decision.

## See also

- [[adrs/0008-keep-loaded-overlay]] — the `open()` path both routes share, and the idle-cost
  promise.
- [[adrs/0003-test-tiers]] — why real placement is Tier 2 / hand-verified, not CI.
- [[adrs/0004-qt-compatibility-floor]] — the widget stays inside Qt 6.9.
