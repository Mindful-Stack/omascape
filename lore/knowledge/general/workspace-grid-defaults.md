---
title: Workspace grid defaults
description: The overview always shows workspaces 1..10 even when Hyprland has not created them, so every number key has a visible target; the `workspaces` config key turns it off.
tags: [ui, hyprland, omarchy]
---

# Workspace grid defaults

## Workspaces 1–10 are always shown

The overview renders workspaces `1` through `10` whether or not Hyprland has created them yet.

The reason is keyboard reachability: number keys `1`–`9` and `0` jump straight to a workspace, so
every one of those keys needs a visible target. If the grid showed only workspaces the compositor
had created, the set of working number keys would change as the user opened and closed things, and
pressing `7` would sometimes do nothing with no indication why.

Hyprland creates a workspace lazily, on first use. So "not created yet" is the normal state for
most of the range on a fresh session, not an edge case.

This is a **default, not an invariant**. The `workspaces` key in the config controls it, and
setting it to `0` turns the behaviour off. Do not write code that assumes ten boxes are always
present.

## See Also

- [[adrs/0005-lock-state-persistence]] — workspace selectors are stored as strings, so a
  numbered and a special workspace share one representation.
- `README.md` § Always 1–0 for the user-facing description.
