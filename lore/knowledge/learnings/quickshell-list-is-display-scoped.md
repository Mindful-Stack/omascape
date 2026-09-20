---
title: "`quickshell list -p <config>` is scoped to the caller's Wayland display"
description: "With WAYLAND_DISPLAY unset — a TTY, ssh, or an agent tool call — quickshell list reports no running instances while the shell is running, so a naive restart check calls a successful restart a failure; list --all and filter by config_path."
tags: [omarchy, quickshell, dev-workflow, testing]
confidence: verified
source: developer-input
date: 2026-09-20
---

# `quickshell list -p <config>` is scoped to the caller's Wayland display

Verified 2026-09-19.

`quickshell list -p <config>` only reports instances on the caller's own Wayland display. With
`WAYLAND_DISPLAY` unset — a TTY, an ssh session, an agent tool call — it reports **no running
instances** while the shell is in fact running perfectly.

`ping` answers regardless, so it cannot be used to contradict the empty list.

The trap: a restart check that shells out to `quickshell list -p` will call a *successful*
restart a failure, and will do so only in the contexts where a human is not watching.

## What to do instead

List with `--all` and filter by `config_path`. That fixes both halves of the problem:

- it sees instances regardless of the caller's display, and
- it stops another config's shell being mistaken for your replacement instance.

## See also

- [[adrs/0001-dev-install-path]] — the restart verification this shaped.
- [[learnings/omarchy-restart-shell-loses-the-bar]] — the other display/environment trap in the
  same restart path.
- `docs/specs/2026-09-19-dev-link-design.md`, findings 1–12.
