---
title: Release and distribution — main is the release channel
description: Omarchy installs the plugin by cloning the default branch and updates it with a fast-forward merge, so every merge to main ships to every user; the manifest version and git tags are labels, and rewriting main's history breaks updates for existing installs.
tags: [release, ci, tooling, omarchy, dev-workflow]
---

# Release and distribution — `main` is the release channel

There is no release pipeline, no changelog and no publishing step. That is not an oversight: the
plugin is distributed as a git checkout, so Omarchy does the shipping. Verified 2026-09-20 against
the installed Omarchy at `~/.local/share/omarchy/bin`.

## How the plugin actually reaches a user

**Install** — `omarchy plugin add <url>` runs `git clone -- "$url" "$stage"`
(`omarchy-plugin-add:120`). No `--branch`, no `--depth`: the user gets **the default branch**,
which is `main`.

**Update** — `omarchy plugin update <id>` (`omarchy-plugin-update:38-78`):

1. `git -C "$dir" fetch --quiet origin HEAD`
2. shows the user `git diff HEAD FETCH_HEAD` and asks
3. `git -C "$dir" merge --ff-only FETCH_HEAD`
4. runs `omarchy-plugin-validate "$dir"`, and on failure `git reset --hard ORIG_HEAD`

Four rules fall straight out of that, and all four are invisible from inside this repository:

- **Every merge to `main` is a release.** There is no staging branch and no tag gate. Whatever is
  on the tip of `main` is what the next `omarchy plugin update` installs.
- **Never rewrite `main`'s history.** The update is `--ff-only`. A force-push, an amended commit
  or a rebase of published history makes every existing install un-updatable: it fails with
  "cannot fast-forward … you have local changes", which is not what happened and gives the user
  nothing to act on.
- **A manifest that fails validation rolls the user back** and leaves them on the old commit.
  They keep a working plugin, so nothing looks broken — they simply stop receiving updates until
  it is fixed. This is why `README.md` § Local development loop puts `omarchy plugin validate .`
  before the commit, not after.
- **The user reads the diff.** `git diff HEAD FETCH_HEAD` is shown before the confirm, so commit
  messages and diff noise are part of the product.

## What `omarchy plugin validate` enforces

From `omarchy-plugin-validate`: `schemaVersion` must be exactly the JSON number `1`; `id`, `name`,
`version`, `kinds`, `entryPoints` must all be present; `kinds` non-empty; every entry-point value a
relative path with no `..` that **exists as a file**; `id` matching
`^[A-Za-z0-9][A-Za-z0-9._-]*$` and not under the reserved `omarchy.*` namespace; and **no symlink
anywhere inside the plugin folder** except under `.git` (`:115`).

Two of those bite in ordinary work:

- Renaming or moving `Overview.qml` breaks installs unless `manifest.json`'s
  `entryPoints.overlay` moves with it, in the same commit.
- **Never commit a symlink.** The repository currently contains none. Note that
  `mise run dev:link` makes the *install path* a symlink to the worktree — that is deliberate and
  local (see [[adrs/0001-dev-install-path]]), and is why `README.md` says to validate `.` rather
  than the install directory.

## Versions and tags are labels, not a mechanism

`manifest.json` `version` is `0.4.0` and is the only place a version string appears in tracked
code — nothing reads it at runtime. Tags exist for `v0.3.0` and `v0.4.0`, both on PR merge
commits, and nothing consumes them either.

Bumps ride inside the feature PR that earns them rather than a dedicated release commit — `0.3.0`
→ `0.4.0` landed in the Omyview→Omascape rename (PR #17). There is no `CHANGELOG.md` and no
release workflow. Keep it that way unless the distribution model changes; a version that nothing
enforces is cheap, and a release process that nothing runs is not.

## Branching and CI

Branch off `main`, one PR per change, merged as a merge commit — 35 merge commits on `main`, and
the last non-merge commit straight to `main` was 2026-09-15 (`26c6c11`, docs). `README.md`
§ Submitting changes is the repo-local standard: focused commits, a message explaining the *why*,
`DESIGN.md`/`ROADMAP.md` updated when behaviour changes, and the manual checks you ran named in
the PR body.

CI is one workflow, `.github/workflows/ci.yml`, one job `logic-tests` on `ubuntu-latest`. It
installs Qt6 QML test tooling and `lua5.4` from apt, sets `CI: "1"` so a missing runtime fails
instead of skipping, and runs `bash tests/run.sh` — Tier 1 only. Two conventions worth keeping:
`permissions: contents: read` rather than the repository default, and `actions/checkout` pinned
to a full commit SHA rather than a tag, with the reason in a comment.

`main` is protected: `logic-tests` is a required check and force-pushes are blocked. Both follow
from the section above — a red commit on `main` is a shipped regression, and a rewritten history
is an un-updatable install.

> **Not yet enabled.** As of 2026-09-20 the GitHub API reports "Branch not protected" for `main`,
> so neither rule is enforced and the convention rests on habit. It is a repository settings
> change, not a code change: Settings → Branches → add a rule for `main` requiring `logic-tests`
> and disallowing force-pushes. Until then, treat the two rules above as binding anyway — the
> consequences land on users, not on the repository.

## See also

- [[general/testing]] — what Tier 1 actually covers before a merge ships.
- [[general/architecture]] — the files that make up the shipped plugin.
- [[adrs/0004-qt-compatibility-floor]] — why CI's Qt is the one that matters.
