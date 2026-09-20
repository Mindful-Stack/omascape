---
title: "The card shadow's alpha switches on the theme's luminance"
description: "The card shadow is 28 % black on light themes and 55 % on dark ones, decided by the card colour's luminance, because a 28 % shadow vanished on Tokyo Night; the tile shadow is left faint on dark themes on purpose."
tags: [frameworks, quickshell, qml, ui]
confidence: verified
source: developer-input
date: 2026-09-20
---

# The card shadow's alpha switches on the theme's luminance

Found in the theme sweep of `docs/specs/2026-09-10-theme-polish-design.md`, checked live on
Rosé Pine Dawn (light) and Tokyo Night (dark). A single shadow alpha does not read on both: 28 %
black is right on a light card and disappears on a dark one. The shadow is therefore

```qml
color: Qt.rgba(0, 0, 0, root.darkTheme ? 0.55 : 0.28)
```

with `darkTheme` derived from the card colour's luminance, not from the theme's name — a theme
Omascape has never seen still lands on the right side. The floating-tile shadow is naturally
faint on dark themes and is deliberately left as it is.

## The rule

A shadow, plate or scrim that reads on one theme has not been checked until it has been looked
at on a light *and* a dark one. When it fails on one side, switch on luminance rather than adding
a per-theme override; the overlay does not know theme names, only colours.

## See also

- [[frameworks/quickshell/theming-and-motion]] — every colour is an overridable `property color`, and why `"#fff"` on the hover plate is not a violation.
- [[general/layout-and-sizing]] — the card's margins and elevation.
