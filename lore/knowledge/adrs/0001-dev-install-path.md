---
title: "ADR-0001: Development builds are linked, not copied"
description: "`mise run link` takes the single Omarchy plugin install directory over with a symlink to the current worktree, because the shell's hot reload serves cached source — so a copy-based deploy would need the same restart and add per-edit syncing for nothing."
tags: [adr, dev-workflow, omarchy, quickshell, tooling]
status: accepted
date: 2026-09-20
deciders: [Daniel Thyselius]
confidence: high
---

# ADR-0001: Development builds are linked, not copied

## Status

Accepted (retrospective) 2026-09-20; the decision predates this record. First dependent code:
`scripts/dev-link.sh`.

## Context

Omascape ships under one global plugin id, `se.mindfulstack.omascape`, so Omarchy gives it exactly
one install directory: `~/.config/omarchy/plugins/se.mindfulstack.omascape/`. Development happens
in several git worktrees at once.

Getting a development checkout into that one directory was undocumented. The README described
editing the installed clone in place, or cloning elsewhere, and never bridged the two; the bridge
everyone improvised was `cp`. Three things followed from that. The live directory lied about
itself — it is a clone of this repo, so `git log` there reported a different commit than the code
actually running. Whoever copied last won, silently, across every worktree. And there was no way
to ask which checkout was live.

The scanned plugins path is hardcoded (`PluginRegistry.qml:11`, and again in the CLI catalog), so
`XDG_CONFIG_HOME` cannot redirect it to a per-worktree location.

## Considered options

- **Copy the runtime file set into the install directory** — the install stays a real directory,
  so it looks exactly like a released install and `omarchy plugin update` keeps working.
- **Symlink the install path at the worktree** — one filesystem operation, nothing to re-sync
  per edit, and the running code is by construction the code in the checkout.
- **Edit the installed clone directly, as the README said** — nothing to set up at all, and the
  file you edit is unambiguously the file that loads.

## Decision

`mise run link` replaces the install path with a symlink to the worktree it is run from, because
the shell's plugin hot reload rebuilds components from cached compilation units and therefore
cannot make a copy any cheaper than a link.

That reasoning is measured, not assumed. The reload genuinely fires and genuinely destroys and
re-creates the component, but it serves the engine's cached source: editing an imported `.js` and
then the `.qml` of a live plugin both produced a fresh component logging the *old* version string,
with no restart in between. Only files the engine has never compiled load fresh. So every deploy
mechanism needs a full shell restart per edit — and a copy would need that restart *and*
per-edit syncing, for no gain.

The rules this implies:

- Take the install path over with a symlink; stash any real install beside it as
  `.se.mindfulstack.omascape.install`, because dot-prefixed entries are ignored by three
  independent scans and so can never collide on plugin id.
- Restart the shell against a positively identified session, then verify a replacement instance.
  Never assume the restart worked.
- Ignore `XDG_CONFIG_HOME`; linking anywhere else produces a link that resolves and a build that
  never loads.
- `mise run unlink` reverses it, and must not be blockable by a broken development manifest —
  restoring the real install is the recovery path.

## Consequences

- Whichever worktree linked last is live, and `readlink` on the install path is the only way to
  know which. This record's own handover brief asserted the wrong checkout was live within a day
  of being written.
- The installed directory stops being a clone, so `omarchy plugin update` does not apply to it
  until `unlink` puts the real install back.
- A linked worktree is invisible to the shell's file watcher: `inotifywait -r` does not descend
  symlinks, so edits inside the worktree fire zero reload events. `touch -h` on the symlink is
  also not in the watched event set.
- Editing plugin source never hot reloads in any case, so a restart is mandatory per edit. The
  shell README's claim that saving a file reloads plugin code is misleading as written.
- Verifying a true release install — a real directory, as a user would receive it — now needs a
  separate mechanism. None exists yet.

## Assumptions and invalidation triggers

- *Assumes the plugin hot reload cannot pick up changed source.* Trigger: upstream fixes the dead
  `Qt.clearComponentCache` guard in `finishPluginReload` (`shell.qml:757`) so reloads serve fresh
  code ⇒ amend; the mandatory restart may go away, but the link still beats a copy.
- *Assumes one global plugin id, and so one install directory.* Trigger: Omarchy supports
  per-worktree or versioned plugin installs ⇒ supersede.
- *Assumes dot-prefixed siblings stay invisible to all three scans.* Trigger: any of those scans
  starts including them ⇒ supersede, because the stash location stops being safe.
- *Assumes the plugins path stays hardcoded.* Trigger: `PluginRegistry` honours
  `XDG_CONFIG_HOME` ⇒ amend.

## See also

- [[learnings/omarchy-restart-shell-loses-the-bar]] — why the restart identifies its session
  positively.
- [[learnings/plugin-hot-reload-serves-cached-source]] — the measurement that rejected copying.
- [[learnings/quickshell-list-is-display-scoped]] — why the restart check filters by config path.
- `docs/specs/2026-09-19-dev-link-design.md` — findings 1–12, the design, the failure table and
  the full measurement. Implementation: `scripts/dev-link.sh`; tests `tests/dev-link.sh`
  (95 assertions, Tier 1).
