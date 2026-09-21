---
title: "ADR-0010: The default branch is the published plugin tree, and development moves to `dev`"
description: "Omarchy installs the default branch verbatim and the marketplace reviews the whole installed tree, so main carries only runtime and community-health files, built from dev by scripts/publish.sh."
tags: [adr, release, omarchy, marketplace, tooling, ci]
status: accepted
date: 2026-09-21
deciders: [Daniel Thyselius]
confidence: high
---

# ADR-0010: The default branch is the published plugin tree, and development moves to `dev`

## Status

Accepted 2026-09-21, and it supersedes [[adrs/0006-marketplace-publication]]. The release train
and the full-SHA submission survive from that record; the freeze on `main` does not, because this
decision removes the thing the freeze existed to prevent.

## Context

`omarchy plugin add` runs a bare `git clone` of the default branch and `omarchy plugin update`
runs `git fetch origin HEAD` + `git merge --ff-only FETCH_HEAD`. Neither takes a ref. So the
default branch is not a branch in the ordinary sense: **it is the artifact**, byte for byte, in
every user's plugin directory.

Measured on `67dcc5c`, that artifact was 8.4 MB across 182 files. Sixteen of them are the
plugin: eleven root `.qml` files, `logic.js`, `manifest.json`, `README.md`, `preview.webp` and
`LICENSE`, 639 KB in total. `docs/` alone was 6.6 MB, most of it one 4.5 MB demo GIF. Every
import in the QML surface resolves inside those sixteen files, and every reference to `docs/`,
`tests/` or `scripts/` in the runtime code is a comment.

The listing review made the cost concrete. Marketplace submission
[#7262](https://github.com/omacom/omarchy-plugin-marketplace/issues/7262) was blocked four
separate times, and only the first was about code the plugin runs:

1. CI actions pinned to tags rather than SHAs, and a missing `permissions:` block (omascape#19).
2. `.devcontainer/devcontainer.json`, whose `postCreateCommand` piped `claude.ai/install.sh`
   into bash — a container definition the plugin has no relationship with.
3. `scripts/setup.sh`, flagged for a clone-then-execute pair that lived *inside a `-h` help
   heredoc* and had nothing to clone.
4. The root `CLAUDE.md`: *"a publisher-controlled agent instruction surface unrelated to the
   plugin's runtime function [that] can cause an agent reviewing or modifying the installed
   plugin to execute repository commands."*

The pattern is the finding. The reviewed surface is the whole repository, not the part that runs,
and each round cost a turn in someone else's queue. Left in place were `docs/`, `lore/`,
`scripts/dev-link.sh`, `tests/`, `Makefile`, `mise.toml` and `household.json` — all of them the
same kind of thing, none of them examined yet. The automated baseline was already reporting two
capabilities from exactly that set: `service-management` from `scripts/dev-link.sh`, and
`installer` from two `lore/` files matched on their heading text.

The review offered the remedy directly: *"Remove the root agent-instruction file from the
published plugin tree (or publish an artifact containing only runtime plugin files)."*

## Considered options

- **Delete the flagged file and re-submit.** One commit, clears the block, and leaves every other
  non-runtime file in the artifact for a reviewer to find next time.
- **A second repository holding the artifact.** Clean separation, but the marketplace listing is
  bound to a repository URL: changing it means re-pointing an open submission, and it splits
  issues, stars and every existing user's `git remote`.
- **Make the default branch the artifact and move development to `dev`.** One repository, one
  URL, and the class of finding stops existing rather than the instance.

## Decision

`main` is the published plugin tree. `dev` is the project.

- `main` carries the root `.qml` files, `logic.js`, `manifest.json`, `preview.webp`, `LICENSE`,
  `.gitignore`, a transformed `README.md`, the three community-health files, and the issue and PR
  templates — which GitHub reads from the default branch only. Nothing else. Twenty-four files.
- `.github/workflows/` is **not** published. Workflows run from the branch the event happened on,
  so CI still gates `dev`, and `ci.yml` installs Lua with `sudo apt-get` — a line that means
  nothing on a branch with no tests and everything to a scanner reading an installed tree.
- Pull requests target `dev`. Nothing is committed to `main` by hand.
- `scripts/publish.sh` builds the release commit with plumbing against a temporary index: no
  branch is checked out, no worktree is touched, nothing is pushed. It refuses to build a tree
  whose manifest entry point is missing, whose QML imports do not resolve inside the published
  set, whose README links a screenshot that is no longer in the source, or which matches the
  marketplace's own baseline patterns. Where Omarchy is installed it also runs
  `omarchy-plugin-validate` against the built tree — step 4 of `omarchy plugin update`, which
  hard-resets the user to `ORIG_HEAD` on failure, so a tree it rejects strands every install on
  its current commit without anything appearing to break.
- The release commit records its source in a `Source-commit:` trailer. The next train checks that
  commit is an ancestor of the new source, which is how "nothing already published gets rolled
  back" is enforced without requiring `main` to be an ancestor of `dev` — it never is again after
  the first publish.
- The published README is generated: the `## Contributing` section is replaced by a pointer at
  `dev`, and `docs/screenshots/` links are rewritten to `raw.githubusercontent.com`. That section
  is also the one place in the runtime surface that tripped the baseline, through the sample
  `dev:link` output at `README.md:487`.

## Consequences

- The class of finding closes. A file that is not runtime and not community health is not in the
  artifact, so it cannot be reviewed, flagged, or shipped.
- **The freeze is gone.** `main` moves only when a maintainer runs the train, so it sits still
  through a review on its own and `dev` keeps merging throughout. What is held now is the
  *publish*, not the repository. ADR-0006's worst consequence — "direct-install users receive
  nothing while a freeze is on, including bug fixes" — was the freeze colliding with the one
  branch everything merged to, and there is no longer one branch.
- Installs drop from 8.4 MB across 182 files to 655 KB across 24, and the first release is an
  ordinary fast-forward: the files it removes are files no installed copy ever loaded.
- `omarchy plugin update` shows `git diff HEAD FETCH_HEAD` before the user confirms. That diff
  becomes readable — a release is now the runtime change, not the release plus forty specs.
- A new runtime file that is not a root `.qml` must be added to the published set by hand.
  Forgetting means an overlay that loads on `dev` and fails on every installed copy, which is why
  the import guard exists and why `tests/publish.sh` covers it.
- The repository's front page is now the published tree. README screenshots resolve against
  `dev` over HTTPS rather than relatively, so renaming one breaks the front page — guarded, but
  only as well as the guard.
- Contributors land on a default branch that is not where the work happens. CONTRIBUTING.md and
  the README both open by saying so; it will still catch people out.
- `main` has no CI. Its contents are a subset of a `dev` tree that was green, and the publish
  guards cover the assembly, but nothing runs a test against the artifact itself. The closest
  thing is `omarchy-plugin-validate`, and it only runs where Omarchy is installed — which is a
  maintainer's machine, never CI.
- **Branch protection on `main` now works by exception rather than by rule.** Its required
  `logic-tests` check can never go green, which is what stops a pull request being merged there,
  and the release push lands only because administrators are exempt. That is a deliberate
  trade — an unmergeable branch is worth more here than a pushable one — but it means enabling
  "Include administrators" on `main` silently breaks releases, and the error says nothing about
  protection. `dev` takes over as the branch where the check is real.
- Publishing writes a branch ref without checking it out, so a worktree holding `main` would be
  left on the new commit with the old files on disk — which git reads as a full set of staged
  additions, every one a development file the release had just removed. Committing there would
  republish the entire development tree. `publish.sh` refuses instead; `tests/publish.sh` covers
  both that and the case where the maintainer is simply standing on `main`.

## Assumptions and invalidation triggers

- *Assumes Omarchy keeps installing the default branch verbatim.* Trigger: `omarchy plugin add`
  learns `--branch`, a tag, or an exact SHA ⇒ supersede; the artifact stops having to be the
  default branch and `main` can go back to being ordinary.
- *Assumes the marketplace keeps reviewing the whole repository rather than the loaded subset.*
  Trigger: the review scopes itself to the manifest's entry points ⇒ the security argument goes,
  though the 8.4 MB one does not.
- *Assumes a generated default branch stays cheap.* Trigger: the publish transform grows past
  the README — a second generated file, or a rewrite that needs to know about content ⇒ revisit;
  at that point a real build step or a separate artifact repository is the honest answer.
- *Assumes contributors can be pointed at `dev` reliably.* Trigger: pull requests keep arriving
  against `main` ⇒ amend with branch protection that rejects them outright rather than a note in
  a file.

## See also

- [[adrs/0006-marketplace-publication]] — superseded. The release train, the full-SHA submission
  and the CI conventions come from there and still hold.
- [[general/release-and-distribution]] — the measured mechanics of both channels.
- [[adrs/0001-dev-install-path]] — why the install path is a symlink locally and must not be one
  in the repository.
- [[adrs/0003-test-tiers]] — what CI gates before a train departs.
