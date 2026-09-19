# Omascape — dev link: run this worktree's build locally (design)

Date: 2026-09-19 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1 ·
tooling only, no runtime code touched.
Status: **approved design, pre-implementation** (brainstormed 2026-09-19).
Branch `dev-link`.

## Goal

One command makes the worktree you are standing in the build the live Omarchy shell loads, and
says so in a receipt you can trust:

```
$ mise run link
linked  se.mindfulstack.omascape -> /home/daniel/Source/omascape
branch  presence @ 40abb73 (dirty)
hypr    …_1789641915_…  (probed, live)
restart ok — shell answered ping in 1.4s
```

`mise run unlink` puts the ordinary clone install back.

## The problem

Four worktrees (`presence`, `peek`, `review/pr-23`, a locked `select-then-enter`) share **one**
global plugin id, so one install directory: `~/.config/omarchy/plugins/se.mindfulstack.omascape/`.
Three things follow.

- Getting a dev checkout into that directory is **undocumented**. README § Local development loop
  says to edit the installed clone directly *or* clone elsewhere, and never bridges the two. The
  bridge everyone improvises is `cp logic.js *.qml manifest.json …`.
- After a `cp`, the live directory **lies about itself**. It is a clone of this repo, so `git log`
  there answers `d5cccde` (main) while the running behaviour is whatever branch was copied last.
  That is the state it is in right now, with `Overview.qml` and `logic.js` as uncommitted
  modifications.
- Whoever copies last wins, silently, across four worktrees.

## Scope

**In:** two mise targets (`link`, `unlink`) over one script, `scripts/dev-link.sh`; taking over the
install path by symlink while stashing any real install; resolving the live Hyprland instance by
probing; the restart; a receipt; a stub-driven test suite in Tier 1; the README rewrite.

**Out:** copying a runtime file set (a `deploy` target for verifying a true install before a
release — worth having, not now); a nested throwaway Hyprland to preview a build without touching
the live shell (`tests/integration/lib.sh` stubs the `qs.Commons` theme singletons and runs
headless, so it is a test rig, not a place to look at the thing); watching files to restart on
save; anything that changes plugin *runtime* code.

## Findings that shaped it (verified 2026-09-19)

1. **A symlinked install is discovered.** `omarchy-plugin-catalog` walks the user plugin dir with
   `find -L … -mindepth 2 -maxdepth 2 -type f -name manifest.json`, so a symlink at the install
   path resolves and the manifest is found through it.
2. **A dot-prefixed sibling is invisible to it.** That same walk excludes
   `! -path "$user_dir/.*/*"`. So the displaced real install can be stashed *next to* the symlink
   as `.se.mindfulstack.omascape.install` without ever colliding on id.
3. **Enablement survives.** It is stored by id — `shell.json:78` holds `se.mindfulstack.omascape`
   — not by path, so re-pointing the symlink does not disturb it.
4. **`omarchy restart shell` spawns the replacement through the compositor**, not as its own child:
   `hyprctl dispatch 'hl.dsp.exec_cmd("omarchy-launch-shell")'`. Nothing dies with the caller's
   process group. (This supersedes the earlier "dies with the tool's process group" reading of the
   2026-09-18 incident, which was wrong.)
5. **It only derives `HYPRLAND_INSTANCE_SIGNATURE` when that variable is empty.** A stale non-empty
   value — which is what Claude Code's Bash environment carries on this machine — defeats the
   guard. `quickshell kill` needs no signature and kills the shell in a loop; the following
   `hyprctl dispatch` then hits a dead socket and fails into `/dev/null`. Kill-then-pray: the
   shell is stopped before anything establishes that the respawn channel works. **That is the
   whole of the 2026-09-18 bar outage.**
6. **Newest-mtime is not a safe way to find the live instance.** `$XDG_RUNTIME_DIR/hypr/` holds 171
   directories on this machine, nearly all of them dead nested-Hyprland leftovers from
   `mise run test-integration`. Exactly one answers `hyprctl version`. Probing is the only
   trustworthy resolution.
7. **The restart's own readiness poll is 2s** (20 × 0.1s). A plugin-heavy shell can exceed that, so
   a non-zero exit from `omarchy restart shell` is not by itself proof the shell failed to come up.

## Design

### Targets

```toml
[tasks.link]
description = "Point the live Omarchy plugin dir at this worktree and restart the shell"
run = "bash scripts/dev-link.sh"

[tasks.unlink]
description = "Restore the ordinary clone install and restart the shell"
run = "bash scripts/dev-link.sh --unlink"
```

One script, two modes, so stash and restore stay in one place. Style follows
`scripts/add-keybind.sh`: `#!/bin/bash`, a header comment that explains itself to a reader who is
about to run it, `set -euo pipefail`, a `fail()` helper, refuse rather than clobber, and
`PLUGIN_ID="se.mindfulstack.omascape"` hardcoded — CI installs no `jq`.

### Link mode, in order

1. **Validate.** `omarchy plugin validate .`; a bad manifest refuses before anything is touched.
2. **Take over the install path**, `${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID`:
   - a symlink already → note the old target, `ln -sfn` to this worktree;
   - a real directory → `mv` it to `.$PLUGIN_ID.install`, then link;
   - that stash path already occupied → **refuse**, change nothing;
   - nothing there → link.

   The install path is never `rm -rf`'d. Only a symlink is `rm`'d; a directory is only ever moved.
3. **Probe for the live compositor.** For each `${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr/*/`, try
   `HYPRLAND_INSTANCE_SIGNATURE=$sig hyprctl version`; keep the one that answers, preferring the
   inherited environment value when it is among the answerers. Never newest-mtime (finding 6).
4. **Restart** with that signature: `env HYPRLAND_INSTANCE_SIGNATURE=$live omarchy restart shell`.
5. **Confirm ourselves.** Poll `omarchy-shell shell ping` for up to 10s, because of finding 7.
6. **Print the receipt:** link target, branch + short sha + dirty flag, the signature used, restart
   outcome and ping latency.

`--unlink` mirrors it: drop the symlink, restore the stash if there is one, then steps 3–6
unchanged.

### Failure behaviour

| Condition | Result |
| --- | --- |
| Manifest fails validation | exit 1, nothing touched |
| Stash path occupied | exit 1, nothing touched |
| No instance answers the probe | link done, restart skipped with a reason, **exit 0** — the deploy half is the point, and a linked-but-not-restarted state is legitimate over ssh |
| Shell never answers ping in 10s | exit 1, with the `journalctl --user -t omarchy-shell -n 60` hint |

## Tests

`tests/dev-link.sh`, wired into `tests/run.sh` so `mise run test` covers it, and green on CI with no
compositor and no Omarchy: the script takes `HYPRCTL`, `OMARCHY` and `OMARCHY_SHELL` from the
environment, defaulting to the real binaries, and the suite points them at stubs with `HOME` in a
temp dir.

Cases:

- a real install directory is stashed, its contents intact, and the symlink created;
- an existing symlink is re-pointed, and no second stash is made;
- an occupied stash path refuses with exit 1 and leaves the install path exactly as it was;
- no answering instance → links, skips the restart, exits 0;
- among many dead runtime dirs, the one live signature is what reaches the restart — the stub
  records the environment it was called with;
- a ping that never succeeds → exit 1;
- `--unlink` removes the symlink and puts the stashed clone back.

## Docs

Rewrite README § Local development loop (`README.md:396`) around `mise run link`, and state the
multi-worktree fact plainly: one global plugin id, several worktrees, `readlink` answers which one
is live. Keep the existing warning that editing QML needs a restart rather than a rescan; it is
still true and is now handled for you.

## Deliberately out of scope

- **An upstream Omarchy issue** for findings 5 and 4 together: `omarchy-restart-shell` kills the
  running shell before establishing that it can spawn a replacement, and a stale non-empty
  `HYPRLAND_INSTANCE_SIGNATURE` defeats its derivation guard. A caller with a stale environment
  loses the bar with no supervisor to recover it.
- **The 171 stale `$XDG_RUNTIME_DIR/hypr/*` directories** the integration suite leaves behind.
