# Omascape — dev link: run this worktree's build locally (design)

Date: 2026-09-19 · Target: Omarchy Quattro `4.0.0.alpha`, Hyprland 0.56.2 (Lua config mode),
Quickshell 0.3.1 · tooling only, no runtime code touched.
Status: **approved design, pre-implementation; revised 2026-09-19 after review** (three
corrections, marked ✎).
Branch `dev-link`.

## Goal

One command makes the worktree you are standing in the build the live Omarchy shell loads, and
says so in a receipt you can trust:

```
$ mise run link
linked   se.mindfulstack.omascape -> /home/daniel/Source/omascape
branch   presence @ 40abb73 (dirty)
session  …_1789641915_…  (from systemctl --user show-environment; answers hyprctl)
restart  ok — instance mtsb1k5jllt (pid 2230186) replaced n8x2p0qr4ab (pid 2229103)
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
install path by symlink while stashing any real install; identifying the desktop session; the
restart, verified by instance replacement; a receipt; a stub-driven test suite in Tier 1; the README
rewrite.

**Out:** copying a runtime file set (a `deploy` target for verifying a true install before a
release — worth having, not now; finding 11 names a stronger reason it may earn its place, and the
experiment that would settle it); a nested
throwaway Hyprland to preview a build without touching the live shell
(`tests/integration/lib.sh` stubs the `qs.Commons` theme singletons and runs headless, so it is a
test rig, not a place to look at the thing); watching files to restart on save; anything that
changes plugin *runtime* code.

## Findings that shaped it (verified 2026-09-19 against Omarchy `4.0.0.alpha`)

1. **A symlinked install is discovered by the CLI catalog.** `omarchy-plugin-catalog` walks the user
   plugin dir with `find -L … -mindepth 2 -maxdepth 2 -type f -name manifest.json`, so a symlink at
   the install path resolves and the manifest is found through it.
2. **✎ And by the shell itself, which scans separately.** `PluginRegistry.rescan()`
   (`shell/services/PluginRegistry.qml:684`) runs its own bash:
   `for sub in "$dir"/*/; do [[ -f "$sub/manifest.json" ]] || continue; …`. A trailing-slash glob
   matches symlinks-to-directories and `-f` follows them. This is the component that actually loads
   the plugin, so it — not the catalog — is the one the design depends on.
3. **A dot-prefixed sibling is invisible, in three independent places.** The catalog excludes
   `! -path "$user_dir/.*/*"`; the shell's glob does not match leading dots; and
   `localPluginIdForPath` (`PluginRegistry.qml:708`) discards any relative path starting with `.`.
   So the displaced real install can be stashed *next to* the symlink as
   `.se.mindfulstack.omascape.install` without ever colliding on id.
4. **Enablement survives.** It is stored by id — `shell.json:78` holds `se.mindfulstack.omascape`
   — not by path, so re-pointing the symlink does not disturb it.
5. **`omarchy restart shell` spawns the replacement through the compositor**, not as its own child:
   `hyprctl dispatch 'hl.dsp.exec_cmd("omarchy-launch-shell")'`. Nothing dies with the caller's
   process group. (This supersedes the earlier "dies with the tool's process group" reading of the
   2026-09-18 incident, which was wrong.)
6. **It only derives `HYPRLAND_INSTANCE_SIGNATURE` when that variable is empty.** A stale non-empty
   value — which is what Claude Code's Bash environment carries on this machine — defeats the
   guard. `quickshell kill` needs no signature and kills the shell in a loop; the following
   `hyprctl dispatch` then hits a dead socket and fails into `/dev/null`. Kill-then-pray: the
   shell is stopped before anything establishes that the respawn channel works. **That is the
   whole of the 2026-09-18 bar outage.**
7. **✎ "An instance that answers" is not an identity.** `$XDG_RUNTIME_DIR/hypr/` holds 171
   directories on this machine, nearly all dead nested-Hyprland leftovers from
   `mise run test-integration` — but while that suite is *running*, its nested Hyprland answers
   `hyprctl version` too. Two answerers, and the stale inherited signature is no tie-breaker. The
   consequence is not a harmless mis-pick: `omarchy-restart-shell` kills matching shells with
   `--any-display` and then dispatches the launch into the *selected* compositor, so choosing the
   nested instance takes the desktop's bar down and starts its replacement inside a throwaway
   session. Neither probing nor mtime may decide this.
8. **✎ The desktop session has a positive identity.** `systemctl --user show-environment` carries
   `HYPRLAND_INSTANCE_SIGNATURE` (UWSM finalizes it at session start —
   `UWSM_WAIT_VARNAMES=HYPRLAND_INSTANCE_SIGNATURE`), and on this machine it is exactly the one
   live instance. `omarchy-restart-shell` already reads `OMARCHY_PATH` from that same source, so
   this is the house-consistent answer rather than a new invention.
9. **✎ `quickshell list` identifies instances — but `-p` filters by the caller's display.**
   ✎✎ `quickshell list -p <config>` reports only instances on the **caller's** `WAYLAND_DISPLAY`:
   with it unset (a TTY, ssh, a tool call) it prints *"No running instances"* while the desktop
   shell is running, which would turn a successful restart into a reported failure. Verified
   2026-09-19. So the listing must be `--all`, filtered by `config_path` in the script — which is
   also what keeps another config's shell from being mistaken for our replacement.
   `quickshell list --all --json` →
   `[{"id":"mtsb1k5jllt","pid":2230186,"launch_time":"2026-09-19T07:27:20",…}]`. A restart can
   therefore be verified by *replacement* — a pid absent from the outgoing set — rather than by
   something answering ping. ✎ Without `--show-dead` the listing holds only live instances, so the
   pid alone settles it; `launch_time` is reported in the receipt but never gated on, which keeps a
   clock or DST dependency out of the decision.
10. **✎ A successful ping proves nothing about the restart.** `omarchy-restart-shell` refuses
    outright while the session is locked ("Refusing to restart Omarchy shell while the session is
    locked.", exit 1) and leaves the old shell running and answering. It can also exit 1 after a
    *successful* restart when the re-lock does not re-secure. Its own readiness poll is 2s
    (20 × 0.1s), which a plugin-heavy shell can exceed, so a non-zero status alone does not mean
    failure either. Status, ping and replacement are three different facts.
11. **✎✎ There is a live inotify watcher, and a symlinked install is invisible to it.**
    `localPluginWatcher` (`PluginRegistry.qml:636`) runs `inotifywait -m -r` over the plugins dir
    and emits `localPluginChanged(id)`; `shell.qml:763` handles it and kicks
    `localPluginReloadTimer` → `reloadPlugins`. (An earlier revision of this spec claimed the
    signal had no consumer — that was a case-sensitive `grep` missing `onLocalPluginChanged`.
    Corrected 2026-09-19 after the journal showed `Local plugin changed, reloading:
    se.mindfulstack.omascape` during the first live `mise run link`.)

    The consequence for this design is unchanged, and now measured rather than predicted:
    `inotifywait -r` does not descend symlinks, so **edits inside a linked worktree reach nothing**
    — `touch Overview.qml` in the worktree produced zero reload events, as did `touch -h` on the
    symlink itself (an attribute change is not in the watched `close_write,create,delete,move`
    set). Only changes directly under the plugins directory are seen; creating the symlink itself
    fired two.

    **✎✎ Measured 2026-09-19 — the reload does NOT pick up changed source, so the restart stays
    mandatory and a copy-based `deploy` buys nothing here.** Method: a throwaway `keepLoaded`
    overlay plugin installed as a real directory (not a symlink) that logs a version string from its
    QML and from an imported `probe.js`, driven with no restart at all (one shell process, pid
    3108994, throughout):

    | Change on disk | Reload fired | Component re-created | Version logged |
    | --- | --- | --- | --- |
    | plugin first added | yes | yes | `qml=v1 js=v1` — a **new** file compiles fresh |
    | `probe.js` → v2 | yes | yes | `qml=v1 js=v1` — **stale** |
    | `Probe.qml` → v2 | yes | yes | `qml=v1 js=v1` — **stale** |

    The component really is destroyed and rebuilt each time (`Component.onCompleted` fires again),
    but it is rebuilt from the engine's cached compilation unit, so neither QML nor imported JS
    changes take effect. Only files the engine has never compiled load fresh.

    **Cause, and a second upstream bug:** `finishPluginReload` (`shell.qml:757`) guards its cache
    clear with `if (typeof Qt.clearComponentCache === "function")`, and `Qt.clearComponentCache` is
    **`undefined` in QML** — it exists only as the C++ `QQmlEngine::clearComponentCache()`. Verified
    directly (`typeof … = undefined` under `qmltestrunner`) and corroborated by the stale-source
    result. The intent is in the code; the call has never run.

    **Also measured:** omascape itself survives the reload cycle. It was unloaded and re-created
    several times during this experiment, and toggling the overview open and closed afterwards
    produced no errors — captures and lock rules re-establish cleanly. That matters for the shipped
    design, because `mise run link` writing the symlink triggers this same global reload before its
    restart.
12. **✎ The plugins directory is hardcoded, so `XDG_CONFIG_HOME` must be ignored.**
    `PluginRegistry.qml:11` is `home + "/.config/omarchy/plugins"` and the CLI catalog hardcodes
    the same path. Honoring `XDG_CONFIG_HOME` would link into a directory nothing scans: the link
    would succeed, the restart would succeed, and the checkout still would not load.

## Design

### Targets

```toml
[tasks."dev:link"]   # alias: link
[tasks."dev:unlink"] # alias: unlink
[tasks."dev:status"]
```

✎ Named after Omarchy's own `omarchy dev link` / `dev unlink` / `dev status`, which do the same
three things one level up (`/usr/share/omarchy/bin/omarchy-dev-{link,unlink,status}`); `link` and
`unlink` remain as short aliases. `dev:status` is read-only — it reports the link target, its
branch/sha/dirty state, any stashed install, and whether the **running** shell is actually that
build: a shell older than the link is still serving the previous checkout, because the engine
caches compiled source per path (finding 11). It therefore runs before the session-identity block,
which can refuse; a read-only command must never refuse.

One script, three modes, so stash and restore stay in one place. Style follows
`scripts/add-keybind.sh`: `#!/bin/bash`, a header comment that explains itself to a reader who is
about to run it, `set -euo pipefail`, a `fail()` helper, refuse rather than clobber, and
`PLUGIN_ID="se.mindfulstack.omascape"` hardcoded — CI installs no `jq`.

### Link mode, in order

1. **Validate — when linking only.** `omarchy plugin validate .`; a bad manifest refuses before
   anything is touched. ✎ `--unlink` does **not** validate the checkout: restoring the ordinary
   install is the recovery path, and a broken development manifest must not be able to block it. The
   restored install is validated afterwards as a *warning*, never fatally.
2. **Identify the desktop session, before touching anything.** Read `HYPRLAND_INSTANCE_SIGNATURE`
   and `OMARCHY_PATH` from `systemctl --user show-environment` (finding 8), then **verify** that
   signature answers `hyprctl version`. The inherited environment is never trusted, and no
   answering instance is ever *chosen* by probe or by mtime (finding 7) — probing only ever
   confirms or denies the identity the session already asserted. `$OMARCHY_PATH/shell` becomes
   `CONFIG_DIR`, the same derivation `omarchy-restart-shell` uses.

   ✎ A failing `systemctl --user show-environment` (no user bus) counts as "the session named
   nothing", and must not abort the script: under `set -euo pipefail` an unguarded pipeline failure
   kills it at the assignment, taking the skip path below with it.

   ✎ When the session's signature is missing or does not answer, the rule is **whether anything
   else is answering**, because that is exactly the condition under which a restart cannot be
   aimed safely:
   - nothing answers anywhere (a true no-session case — over ssh, or the desktop is gone) → the
     link proceeds, the restart is skipped with its reason, **exit 0**;
   - something answers but it is not the identified session (a nested integration Hyprland, or a
     desktop whose identity cannot be established) → **refuse, change nothing**. Never pick among
     answerers, and never restart into an unidentified compositor (finding 7).
3. **Take over the install path**, `$HOME/.config/omarchy/plugins/$PLUGIN_ID` — deliberately not
   `XDG_CONFIG_HOME`, with a comment naming finding 12 so nobody "fixes" it later.

   ✎ Two cases come first, before any mutation, because the worktree can *be* inside the plugins
   directory — the README's "edit the installed folder directly" loop is exactly that:
   - the install path is a real directory whose physical path **is** this worktree → it is already
     the live checkout; nothing to link, and only the restart is owed. (Stashing it and linking to
     `$REPO` would point the install path at itself, and the plugin would disappear.)
   - the worktree is somewhere else under the plugins directory → **refuse**: Omarchy would discover
     it a second time under the same id.

   Then, as before:
   - a symlink already → note the old target, `ln -sfn` to this worktree;
   - a real directory → `mv` it to `.$PLUGIN_ID.install`, then link;
   - that stash path already occupied → **refuse**, change nothing;
   - nothing there → link.

   The install path is never `rm -rf`'d. Only a symlink is `rm`'d; a directory is only ever moved.
4. **Record the outgoing instance.** `quickshell list -p "$CONFIG_DIR" --json` → `id`, `pid`,
   `launch_time` (finding 9). Zero instances is legitimate (nothing running yet) and is recorded
   as such.
5. **Restart** with the session's signature:
   `env HYPRLAND_INSTANCE_SIGNATURE=$session omarchy restart shell`, run as
   `if ! err=$(… 2>&1); then …` so a non-zero status neither aborts the script under `set -e` nor
   is mistaken for failure, and its stderr is kept for the receipt.
6. **Verify replacement, not liveness** (finding 10). ✎ Poll until **both** hold, within a 10s
   deadline: a `pid` from `quickshell list --all --json`, filtered to `$CONFIG_DIR/shell.qml`
   (finding 9 — never `-p`, which hides instances from a display-less caller), that was not in the
   outgoing set,
   *and* `omarchy-shell shell ping` answering. A replacement exists before its QML and IPC are up, so
   a single ping attempt taken the moment the pid appears would fail a healthy slow start. Four
   outcomes:
   - replaced and answering → **ok**, whatever the restart's exit status was; if that status was
     non-zero its stderr is printed as a warning (the re-lock case).
   - **not replaced** and the outgoing instance still answers → the restart **refused**. Print its
     stderr verbatim (e.g. the session-locked refusal) and say plainly that the old worktree is
     still loaded. Exit 1.
   - ✎ replaced but never answering within the deadline → exit 1, naming the new pid, with the
     `journalctl --user -t omarchy-shell -n 60` hint.
   - not replaced and nothing answers → the shell is down. Exit 1 with the
     `journalctl --user -t omarchy-shell -n 60` hint.
7. **Print the receipt:** link target, branch + short sha + dirty flag, the session signature and
   where it came from, and the instance transition.

`--unlink` mirrors it: drop the symlink, restore the stash if there is one, then steps 4–7
unchanged.

### Failure behaviour

| Condition | Result |
| --- | --- |
| Manifest fails validation | exit 1, nothing touched |
| ✎ Run from the installed checkout itself (`$REPO` *is* the install path) | nothing linked or stashed — it is already live; the restart still runs, exit 0 |
| ✎ Worktree elsewhere inside the plugins directory | exit 1, nothing touched — it would be discovered twice under one id |
| ✎ Replaced but never answering within the deadline | exit 1, names the new pid, journal hint |
| ✎ `--unlink` with an invalid manifest in the checkout | restores anyway, exit 0 — validation is link-only |
| ✎ Caller has no (or a foreign) `WAYLAND_DISPLAY` | unaffected: the listing is `--all` filtered by config path |
| ✎ No session signature (or it does not answer) **and something else answers** | exit 1, nothing touched — the restart cannot be aimed, and no answerer may be chosen |
| Stash path occupied | exit 1, nothing touched |
| ✎ No session signature **and nothing answers anywhere** (e.g. over ssh) | link done, restart skipped with its reason, **exit 0** — the deploy half is the point, and there is no compositor to endanger |
| ✎ Restart refused (session locked) | link is in place, exit 1, refusal printed verbatim, receipt says the old worktree is still loaded |
| ✎ Restarted but the re-lock warning fired | exit 0, warning printed |
| No replacement instance and nothing answers | exit 1, journal hint |

## Tests

`tests/dev-link.sh`, wired into `tests/run.sh` so `mise run test` covers it, and green on CI with no
compositor and no Omarchy: the script takes `HYPRCTL`, `OMARCHY`, `OMARCHY_SHELL_BIN`,
`QUICKSHELL`, `SYSTEMCTL` and `DEV_LINK_POLL_SECONDS` from the environment, defaulting to the real
binaries (✎ `OMARCHY_SHELL_BIN`, not `OMARCHY_SHELL`, so it cannot collide with anything
`omarchy-shell` itself reads), and the suite points them at stubs with `HOME` in a temp dir.

✎ The suite must pass with `WAYLAND_DISPLAY` set, unset, and set to a foreign value. The stub
models the real display filter, so a test that calls it the wrong way passes only on a machine whose
display name happens to match the fixture's — which is how CI caught a fixture self-check that was
green locally.

Cases:

- ✎ a manifest that fails `omarchy plugin validate` refuses with exit 1 before anything is touched;
- ✎ run from a copy of the script sitting at the install path (so `$REPO` *is* the install path) →
  exit 0, the directory untouched and **not** turned into a symlink to itself, nothing stashed, and
  the restart still happens;
- ✎ run from another checkout under the plugins directory → exit 1, nothing touched;
- ✎ `systemctl` exiting non-zero with nothing answering → links and skips the restart, exit 0 (the
  unguarded form aborts at the assignment instead), and the same with an answerer present → exit 1,
  nothing touched;
- ✎ a replacement pid that appears at once while ping answers only from its fourth attempt → exit 0;
- ✎ a caller on a foreign `WAYLAND_DISPLAY` still verifies the restart (the stub models the real
  display filter, so *every* case in the suite holds the script to `--all`);
- ✎ an instance of another config appearing after the restart is **not** adopted as the replacement;
- ✎ `--unlink` with a checkout whose manifest fails validation still restores the stash, exit 0;
- a real install directory is stashed, its contents intact, and the symlink created;
- an existing symlink is re-pointed, and no second stash is made;
- an occupied stash path refuses with exit 1 and leaves the install path exactly as it was;
- **✎ two answering instances and a stale inherited signature** → the session's signature from
  `systemctl --user show-environment` is the one passed to the restart, and the nested one is never
  chosen; the restart stub records the environment it was called with;
- **✎ no session signature while a nested instance answers** → exit 1 with the install path
  untouched (asserted: no symlink, no stash);
- ✎ no session signature and nothing answering → links, skips the restart, exit 0;
- **✎ restart fails and the old shell still pings** → exit 1, the refusal text appears in the
  output, and the receipt does not claim success; separately, that the non-zero status does not
  abort the script early under `set -e`;
- ✎ restart exits non-zero *and* a new pid appears → exit 0 with the stderr surfaced as a warning;
- a slow replacement that appears at 5s → exit 0;
- no replacement and nothing answering → exit 1 with the journal hint;
- **✎ a non-default `XDG_CONFIG_HOME`** → the script still targets `$HOME/.config/omarchy/plugins`;
- `--unlink` removes the symlink and puts the stashed clone back.

## Docs

Rewrite README § Local development loop (`README.md:396`) around `mise run link`, and state the
multi-worktree fact plainly: one global plugin id, several worktrees, `readlink` answers which one
is live. Keep the existing warning that editing QML needs a restart rather than a rescan — finding
11 confirms it is still true — and note that the target handles it.

## Deliberately out of scope

- **An upstream Omarchy issue**, now with a concrete suggested fix: `omarchy-restart-shell` should
  read `HYPRLAND_INSTANCE_SIGNATURE` from `systemctl --user show-environment` exactly as it already
  reads `OMARCHY_PATH`, rather than only deriving it when the variable is empty; and it should
  establish that the launch channel answers *before* `quickshell kill`, so a caller with a stale
  environment cannot lose the bar with no supervisor to recover it.
- **A second upstream Omarchy issue**, from finding 11: the plugin hot reload tears components down
  and rebuilds them but never clears the QML type cache, because its guard tests for a `Qt.`
  function that does not exist in QML. So saving a file under `~/.config/omarchy/plugins/` reloads
  the component from cached source and appears to work while serving the old code — which also makes
  the shell README's "saving a file reloads plugin code automatically" misleading as written.
- **The 171 stale `$XDG_RUNTIME_DIR/hypr/*` directories** the integration suite leaves behind.
