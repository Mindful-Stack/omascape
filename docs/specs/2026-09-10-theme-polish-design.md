# Omascape — theme polish (2026-09-10)

Branch `theme-polish`, based on `ws-badge`. Small style pass agreed after the restyle; motion is
still a separate follow-up.

## Changes

- **Theme typography.** Badge, monitor chips, key hints and tile titles use the shell's menu
  font family (`Style.font.menuFamily`) and size tokens (`bodySmall` for labels, `caption` for
  hints and titles). Card padding uses `Style.space`. The picker therefore follows
  `omarchy display text size` and `OMARCHY_MENU_FONT` like every other summoned surface.
- **Tighter grid.** Cell gap 6 → 4, row gap 10 → 8. Hover scale (1.03) is kept.
- **Floating window shadow.** Floating tiles cast a small `SoftShadow` (blur 12, 3px down,
  35 % black), hidden while the tile is the drag ghost. Tiled windows cast none, so the two roles
  read at a glance as they do on the desktop.
- **Empty wells one step lower.** Empty workspaces fill at half `normalFillAlpha`; occupied ones
  keep the full step.
- **Key caps.** The hint line is a row of small caps (well tone, radius 4) with labels, and can be
  switched off with `"hint": false` in `~/.config/omarchy/omascape.json`. When off, the card gives
  the space back.
- **`SoftShadow.qml`** replaces `CardShadow.qml`: same shader, now generic (`target`, `radius`,
  `blur`, `offset`, `color` overridable) so the card and tiles share it.

## Blurred scrim (Hyprland side, optional)

Hyprland's Lua config can blur the picker's layer:

```lua
hl.layer_rule({ match = { namespace = "omascape" }, blur = true, ignore_alpha = 0.3 })
```

This needs `decoration.blur.enabled = true` and lives in the user's Hyprland config, not the
plugin. Tested live via `hyprctl eval` on Hyprland 0.56.2: the desktop frosts behind the card
and the card stays crisp. Documented in the README; left to the user to enable.

## Theme sweep

Checked live on Rosé Pine Dawn (light) and Tokyo Night (dark). Everything reads on both; the
one change it prompted is the card shadow alpha, 28 % on light themes and 55 % on dark ones
(decided by the card colour's luminance), because 28 % black vanished on Tokyo Night. The
floating-tile shadow is naturally faint on dark themes and left as is.

## Tests

Offscreen: the floating-tile shadow is hidden for a tiled window, shown once the window floats,
and hidden again while that tile is dragged. Fixture stubs `SoftShadow`, the config, the font
tokens and `Style.space`.
