---
title: "ADR-0006: Publishing runs as a release train, and `main` freezes during review"
description: "Marketplace listing requires the validated snapshot to be the default-branch HEAD, so releases are batched, tagged and submitted by full SHA, and no commit reaches main until the maintainer applies approved-and-verified."
tags: [adr, release, omarchy, tooling, ci]
status: superseded
date: 2026-09-20
deciders: [Daniel Thyselius]
confidence: medium
---

# ADR-0006: Publishing runs as a release train, and `main` freezes during review

## Status

Proposed 2026-09-20. **Superseded 2026-09-21 by [[adrs/0010-published-tree-is-the-default-branch]].**

The train ran once — batched, bumped to 0.5.1, tagged, filed — and the freeze held. What it did
not survive was the finding that arrived next: the review is of the whole repository, not of the
code the plugin loads, so freezing `main` protected the snapshot while doing nothing about what
the snapshot contained. ADR-0010 makes `main` the published tree instead, which removes the need
for a freeze rather than enforcing one. The release train, the full-SHA submission and the two CI
conventions below carry forward unchanged.

## Context

Omascape ships through two channels with different units of release. A direct
`omarchy plugin add` clones the default branch and `omarchy plugin update` fast-forwards onto its
tip, so every merge to `main` reaches those users. The Omarchy plugin marketplace instead lists a
commit that a maintainer has verified, and its checks stamp a specific SHA: marketplace validation
and the automated security baseline both recorded
`64ec97b554ac4b2414b0e05469f9c949cf7909a8` on the omascape submission, and a human supply-chain
review ran against `c6cc8e55…` before that.

The two do not compose automatically, and the review is explicit about which one wins. On
[marketplace#7262](https://github.com/omacom/omarchy-plugin-marketplace/issues/7262) the reviewer
closed the loop with: *"The validated marketplace/security snapshot is `64ec97b…`, but the current
default-branch HEAD is `5790e24…`. This submission cannot be approved against a different
repository state."* The requirement is that the validated snapshot **is** the default-branch HEAD
at review time — not that it exists somewhere in history.

Meanwhile this repository merges often. As of 2026-09-20 `main` stands twelve merges past
`64ec97b`, having moved twice that day alone, and the submission has been open since 2026-09-16
carrying `validated` and `needs-fixes`. The superseded `se.mindfulstack.omyview` listing stays
live until this one lands, so the drift has a user-visible cost as well as a process one.

## Considered options

- **Re-request validation after every merge** — day-to-day work is never blocked, and a fix can
  always ship to direct-install users the moment it is ready.
- **Batch releases and freeze `main` during review** — the submitted snapshot is still HEAD when
  the reviewer looks, so the request resolves in one round trip.
- **Merge less often** — fewer, larger merges shrink the drift window without anyone having to
  hold a freeze or coordinate a window.

## Decision

Publication runs as a release train, and `main` stops moving for the duration of a review.

- Develop on branches; merge only finished work.
- Batch a set of PRs and merge them together, bump `manifest.json`'s `version`, and tag the
  result (`v0.5.0`).
- File "Verify and publish a newer upstream commit" with the plugin id, the repository URL and
  the **full 40-character SHA** — not the short form and not the tag name.
- **Merge nothing to `main` until the maintainer applies `approved-and-verified`.** A green PR is
  not an exception; the freeze is what makes the request answerable.

The version bump and the tag belong to the train, not to whichever feature PR feels significant.
Branch protection is how the freeze is held in practice: "do not merge for a few days" is a
message in a thread, and an enforced rule is not something a passing check can argue with.

## Consequences

- Direct-install users receive nothing while a freeze is on, including bug fixes. A user-affecting
  regression discovered mid-review forces a choice between shipping it and restarting the review.
- The freeze length is set by someone else's queue, not by this project. #7262 has been open since
  2026-09-16.
- Batched releases produce larger diffs, and `omarchy plugin update` shows `git diff HEAD
  FETCH_HEAD` to every updating user before they confirm — so the diff is part of the product and
  gets harder to read.
- The tag finally denotes something real. It also exposes how far the old habit drifted: `v0.4.0`
  is 160 commits behind `main`, so the first train carries an unusually large catch-up.
- Two CI conventions stop being stylistic and become load-bearing: `actions/checkout` pinned to a
  full commit SHA and `permissions: contents: read`. Both were supply-chain review findings on
  this submission, fixed in omascape#19. Reverting either re-opens a resolved review point.

## Assumptions and invalidation triggers

- *Assumes the marketplace requires the validated snapshot to equal default-branch HEAD.* Trigger:
  it accepts a tag or an arbitrary SHA that is not HEAD ⇒ supersede; the freeze stops being
  necessary and publication moves to a release branch.
- *Assumes Omarchy keeps this review model.* **A marketplace update is expected.** Trigger: the
  new marketplace ships ⇒ re-verify every claim here against it and supersede. This is the most
  likely way this record dies, which is why its confidence is `medium`.
- *Assumes review latency stays short enough to freeze through.* Trigger: a freeze blocks a
  user-affecting fix ⇒ amend with a break-glass rule that says what is allowed to land and what
  happens to the pending request.
- *Assumes direct installs keep tracking the default branch.* Trigger: `omarchy plugin add` learns
  `--branch` or tag resolution ⇒ supersede; the two channels stop pulling against each other.

## See also

- [[general/release-and-distribution]] — the measured mechanics of both channels.
- [[adrs/0003-test-tiers]] — what CI actually gates before a train departs.
- [[adrs/0001-dev-install-path]] — why the install path is a symlink locally and must not be one
  in the repository.
