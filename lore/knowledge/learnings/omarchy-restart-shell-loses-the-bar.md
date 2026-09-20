---
title: "`omarchy restart shell` can lose the bar, and a stale environment variable is why"
description: "omarchy-restart-shell only derives HYPRLAND_INSTANCE_SIGNATURE when the variable is empty, so a stale non-empty value kills the shell and then respawns it into a dead socket; take the signature from systemctl --user show-environment instead."
tags: [omarchy, hyprland, dev-workflow, tooling]
confidence: verified
source: developer-input
date: 2026-09-20
---

# `omarchy restart shell` can lose the bar, and a stale environment variable is why

Hit 2026-09-18, diagnosed 2026-09-19.

`omarchy restart shell` spawns the replacement *through the compositor*:

```
hyprctl dispatch 'hl.dsp.exec_cmd("omarchy-launch-shell")'
```

but it only derives `HYPRLAND_INSTANCE_SIGNATURE` when that variable is **empty**. A stale
non-empty value therefore defeats the guard entirely, and the two halves of the restart fail
asymmetrically:

- `quickshell kill` needs no signature, so it lands regardless and the bar goes away.
- The respawn dispatch then hits a dead socket, fails, and its error goes to `/dev/null`.

The result is kill-then-pray with no supervisor to recover it. You are left with no bar and no
error message.

## What to do instead

Take the signature from `systemctl --user show-environment`, which UWSM finalises at session
start, rather than trusting the ambient environment. That is the same source
`omarchy-restart-shell` already uses for `OMARCHY_PATH`, so it is not a new dependency.

Establish that the launch channel answers *before* killing anything, so a caller with a stale
environment cannot destroy the running shell with nothing able to bring it back.

## Why this bites agents especially

An agent tool call, a TTY, or an ssh session all routinely carry a stale or absent
`HYPRLAND_INSTANCE_SIGNATURE`, which is exactly the condition that breaks the guard. Do not run
`omarchy restart shell` from a tool call without establishing the signature first.

## See also

- [[adrs/0001-dev-install-path]] — the restart machinery this shaped.
- [[learnings/quickshell-list-is-display-scoped]] — the other half of verifying a restart.
- Recorded as a suggested upstream fix under "Deliberately out of scope" in
  `docs/specs/2026-09-19-dev-link-design.md`. Not filed.
