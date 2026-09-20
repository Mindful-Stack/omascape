---
title: "Hyprland animates layers too, so omascape needs a no_anim layer rule"
description: "Hyprland fades layer surfaces itself, so without a `no_anim` layer rule for the `omascape` namespace every open and close animates twice — the compositor's fade on top of the overlay's own; Omarchy gives its shell overlays the same rule, and README documents it."
tags: [hyprland, compositor, omarchy, ui]
confidence: verified
source: developer-input
date: 2026-09-20
---

# Hyprland animates layers too, so omascape needs a `no_anim` layer rule

Hyprland applies its own fade animation to layer-shell surfaces. The overlay animates its
entrance and exit itself (`frameworks/quickshell/theming-and-motion`), so without a layer rule
the two stack: the compositor fades the surface in while the card is already scaling up, and the
close plays a fade on top of the overlay's own.

Omarchy gives its shell overlays a `no_anim` rule for exactly this reason. The plugin cannot
install one for itself — plugins do not write Hyprland config — so `README.md` § Let the picker
animate itself tells the user to add:

```lua
hl.layer_rule({ match = { namespace = "omascape" }, no_anim = true, animation = "none" })
```

The spec that found it is `docs/specs/2026-09-10-motion-design.md` § Hyprland also animates
layers.

## The rule

A new layer surface with its own motion needs the same rule under its own namespace, and its
README entry. The lock frame (`omascape-lockframe`) is the precedent for a second namespace: its
rule is installed from Lua at runtime because it is `no_screen_share`, which the user must not be
asked to add by hand — see [[adrs/0005-lock-state-persistence]].

## See also

- [[frameworks/quickshell/theming-and-motion]] — the overlay's own entrance and exit.
- [[frameworks/hyprland/compositor-state]] — the rest of the compositor boundary.
