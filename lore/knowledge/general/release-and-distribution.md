---
title: Release and distribution — two channels, one of which needs main to sit still
description: Direct installs track main's tip, so every merge ships; the marketplace listing instead publishes a maintainer-verified snapshot SHA, which means main must be frozen from filing the verification request until it is approved — moving main invalidates the request.
tags: [release, ci, tooling, omarchy, dev-workflow]
---

# Release and distribution — two channels, one of which needs `main` to sit still

There is no build step and no publishing automation: the plugin is distributed as a git checkout,
so Omarchy does the shipping. But it ships through **two channels with opposite requirements**, and
that is the whole difficulty.

| Channel | What it installs | What it demands of `main` |
| --- | --- | --- |
| Direct git install | `main`'s tip, always | that it never rewrites history |
| Marketplace listing | a maintainer-verified snapshot SHA | that it **stops moving** while a request is pending |

Verified 2026-09-20 against the installed Omarchy at `~/.local/share/omarchy/bin`.

## Channel 1 — a direct git install tracks `main`

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
  on the tip of `main` is what the next `omarchy plugin update` installs — which is also why a
  merge during a marketplace freeze is not a neutral act.
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

## Channel 2 — the marketplace publishes a frozen snapshot

The listing does not track `main`. A maintainer verifies **one specific commit** and publishes
that, so the unit of release is a SHA somebody looked at, not a branch tip. Getting a newer commit
listed means running a **release train**:

1. **Develop on branches.** Merge only finished work — the same flow as today.
2. **Batch the PRs, merge them together**, bump `manifest.json`'s `version`, and tag (`v0.5.0`).
3. **File "Verify and publish a newer upstream commit"** on the verification form, with the plugin
   id, the repo URL, and the **full 40-character SHA**. Not the short form, not the tag name.
4. **Freeze `main`** until the maintainer applies `approved-and-verified`.

**Step 4 is the mechanism, not politeness.** The reviewer validates the commit you named against
what they fetch. If `main` has moved on by the time they look, the request is about a snapshot
that is no longer the branch tip and it stalls.

That is exactly what happened to the omascape submission,
[marketplace#7262](https://github.com/omacom/omarchy-plugin-marketplace/issues/7262) — open since
2026-09-16, labelled `validated` and `needs-fixes`. Marketplace validation and the automated
security baseline both passed at `64ec97b`, and the reviewer then closed the loop with:

> The validated marketplace/security snapshot is `64ec97b…`, but the current default-branch HEAD
> is `5790e24…`. This submission cannot be approved against a different repository state.

Note what that requires: the validated snapshot must **be** the default-branch HEAD, not merely
exist in history. Publishing from a release branch does not satisfy it. `main` has kept going
since — `a72ecda`, then four more merges to `7200771`, twelve past the verified commit — and the
superseded Omyview listing stays live until this one lands. The reasoning is recorded in
[[adrs/0006-marketplace-publication]].

> **`main` is not frozen today, and a pending request would already be stale.** On 2026-09-20
> alone, PR #32 merged as `4e2dfb8` and PR #34 as `7200771`. `64ec97b` is now 154 commits behind
> the tip. Before filing the next request, agree the freeze window and hold it — a merge during
> review costs another round trip, and this has now cost three.

The two channels pull in opposite directions during a freeze: direct-install users get nothing new
while the train is held, and the fix is to keep freezes short and batched rather than to merge
through them.

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

## Versions and tags name the snapshot

Neither is an install mechanism — no installer resolves a tag, and nothing reads `manifest.json`'s
`version` at runtime. The tag still earns its place: it **names the verified snapshot**, so the
request in step 3 can point at something human-readable and a user can read a real version off the
listing. The 40-character SHA is what the request carries; the tag is how everyone else refers to
it.

Which means the bump and the tag belong to **step 2 of the train**, not to whichever feature PR
happens to feel significant. Historically they rode along inside a feature PR — `0.3.0` → `0.4.0`
landed in the Omyview→Omascape rename (PR #17) — and the result is visible: `v0.4.0` is **160
commits behind `main`**, so every direct-install user is running something the version string does
not describe.

There is no `CHANGELOG.md` and no release workflow. A changelog would be worth its keep at the
point where trains become regular, since step 2 already defines the batch it would describe.

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
to a full commit SHA rather than a tag, with the reason in a comment. **Neither is stylistic.**
Both were supply-chain review findings on the marketplace submission — a mutable `actions/checkout@v4`
tag and a missing least-privilege `permissions` block — fixed in omascape#19. Reverting either
re-opens a resolved review point.

`main` is protected: `logic-tests` is a required check and force-pushes are blocked. Both follow
from the two channels above — a red commit on `main` is a shipped regression, and a rewritten
history is an un-updatable install. Protection is also the only practical way to hold a freeze:
"do not merge for a few days" is a message in a thread, while an enforced rule is not something a
green PR can talk you past.

> **Not yet enabled.** As of 2026-09-20 the GitHub API reports "Branch not protected" for `main`,
> so neither rule is enforced and the convention rests on habit. It is a repository settings
> change, not a code change: Settings → Branches → add a rule for `main` requiring `logic-tests`
> and disallowing force-pushes. Until then, treat the two rules above as binding anyway — the
> consequences land on users, not on the repository.

## See also

- [[general/testing]] — what Tier 1 actually covers before a merge ships.
- [[general/architecture]] — the files that make up the shipped plugin.
- [[adrs/0004-qt-compatibility-floor]] — why CI's Qt is the one that matters.
- [[learnings/omarchy-plugin-install-mechanics]] — what `omarchy plugin add` does on the user's
  machine, and why the manifest `id` cannot change.
- [[general/feature-workflow]] — how a change gets to the point of being merged at all.
