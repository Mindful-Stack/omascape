---
title: "ADR-0005: Lock state persists as atomic JSON, with one writer per file"
description: "Armed workspaces persist in ~/.config/omarchy/omascape-locks.json written atomically by the shell, while the compositor observer owns a separate runtime file, because two writers on one file would race and a half-written file would disable live rules."
tags: [adr, persistence, quickshell, qml, compositor]
status: accepted
date: 2026-09-20
deciders: [Daniel Thyselius]
confidence: high
---

# ADR-0005: Lock state persists as atomic JSON, with one writer per file

## Status

Accepted (retrospective) 2026-09-20; the decision predates this record. First dependent code:
`OmascapeLocks.qml`.

## Context

A workspace lock must outlive the shell. The user arms a workspace, the shell restarts, and the
rules the compositor holds have to be re-established from somewhere.

Two independent pieces of state are involved, and they have different lifetimes and different
owners. The *set of armed workspaces* is a user preference that must survive a reboot. Whether
screen sharing is currently active is a property of this session only, and the compositor
observer is what knows it.

Two failure modes drove the design. A half-written or unreadable file read back as "no locks"
would silently disarm workspaces the user armed, and the compositor would keep holding rules the
shell no longer believes in. And the file is watched, so the shell can read back its own write
while it is still in progress.

## Considered options

- **One file holding both pieces of state** — a single place to look, and a single load path.
- **One file per writer, chosen by lifetime** — the config file survives reboots, the runtime
  file does not, and no file has two writers to race.
- **Keep armed state in memory and re-derive it from the compositor's live rules on startup** —
  nothing to persist, and no file to corrupt.

## Decision

Each piece of state lives in its own file with exactly one owner, chosen by lifetime:

- `~/.config/omarchy/omascape-locks.json` holds `{ "armed": ["3", "special:scratchpad"] }` and is
  written **only** by the shell, with `atomicWrites: true` on its `FileView`. Atomicity is
  delegated to Quickshell rather than hand-rolled as write-to-temp-and-rename.
- `$XDG_RUNTIME_DIR/omascape/share-state` holds `"1"` or `"0"` and is written **only** by the
  compositor observer. It is runtime state and is correctly lost on reboot.

Two rules protect the read path:

- `armed` is `null` until the first load resolves, and the Overview must never sync an unresolved
  set. Syncing `null` as "empty" would disable rules the compositor still holds after a restart.
- A load error is classified, not collapsed. `FileViewError` distinguishes "no such file" — a
  genuine first run, which resolves to `[]` — from every other failure such as a permission
  problem or a directory in its place. Those must **not** be treated as missing, or a merely
  unreadable file would reset `armed` to `[]` and silently disarm everything.

## Consequences

- The on-disk format is now a compatibility surface. The file exists on users' machines, so its
  shape cannot change without a migration path, which is what makes this expensive to reverse.
- Two files means two watchers and two load paths to reason about, and a reader has to know which
  file owns which fact. A single file would be simpler to describe.
- Delegating atomicity to `FileView` means the guarantee is only as good as Quickshell's
  implementation, and it is not visible in this repository's code or tests.
- The shell still reads back its own writes through the watcher, so the load path has to tolerate
  seeing its own bytes arrive — the classification rules above are what make that safe rather
  than merely unlikely.
- Workspace selectors are stored as strings (`"3"`, `"special:scratchpad"`) so a special
  workspace and a numbered one share one representation. That keeps the format uniform and means
  a malformed selector is only caught when it is used.

## Assumptions and invalidation triggers

- *Assumes `FileView`'s `atomicWrites` really is atomic.* Trigger: a truncated or interleaved
  locks file is observed in the wild ⇒ supersede with an explicit temp-and-rename.
- *Assumes armed state is small enough for a whole-file rewrite per change.* Trigger: the state
  grows to where rewriting it per toggle is noticeable ⇒ supersede.
- *Assumes share state is worthless across reboots.* Trigger: a requirement to remember sharing
  state between sessions ⇒ amend and move it out of `$XDG_RUNTIME_DIR`.
- *Assumes the format can stay unversioned.* Trigger: the first change to the JSON shape
  ⇒ amend and add a version field with a migration.

## See also

- [[adrs/0002-compositor-dispatch-errors]] — how the armed set reaches the compositor.
- [[general/workspace-grid-defaults]] — why a numbered and a special workspace share one
  string representation.
- `docs/specs/2026-09-12-lock-design.md`; implementation `OmascapeLocks.qml`, UI fixture
  `tests/ui/lock.qml`.
