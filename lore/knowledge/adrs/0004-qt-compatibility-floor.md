---
title: "ADR-0004: Qt 6.4 is the compatibility floor, even though local is 6.11"
description: "QML must stay valid on Qt 6.4 because that is what CI's runner provides, so legacy reserved words as identifiers and Qt 6.7+ per-corner radius are forbidden — both compile locally on 6.11 and break the build."
tags: [adr, ci, qml, testing, tooling]
status: accepted
date: 2026-09-20
deciders: [Daniel Thyselius]
confidence: high
---

# ADR-0004: Qt 6.4 is the compatibility floor, even though local is 6.11

## Status

Accepted (retrospective) 2026-09-20; the decision predates this record. First dependent code:
`.github/workflows/ci.yml`.

## Context

Development happens on Arch with Qt 6.11.2. CI runs on `ubuntu-latest` and installs Qt 6 from
the distribution's packages, which is an older release — 6.4 in practice.

QML's failure mode across that gap is the expensive one: an unknown property is a **compile**
error, not a warning and not a runtime fallback. So code using anything newer than the CI
compiler parses and runs perfectly on the developer's machine and fails the build with a message
about a property that plainly exists.

Two specific traps have cost time repeatedly:

- Legacy reserved words are rejected as identifiers by Qt 6.4's parser: `long`, `short`, `int`,
  `char`, `float`, `double`, `byte`, `boolean`, `final`, `native`. A variable called `long`
  is fine locally and a syntax error on CI. One test had to rename `query200` for this reason.
- Per-corner radius (`topLeftRadius` and friends) is Qt 6.7+. Qt 6.4 has no per-side borders
  either, which is why square top corners are drawn with three overlay strips rather than the
  obvious property.

The gotcha is repeated in at least six plan and brief documents, which is what makes it a
decision rather than a note: it keeps being rediscovered.

## Considered options

- **Develop against 6.4 and treat it as the floor** — CI stays the authority, and the code runs
  on whatever Ubuntu users have.
- **Pin CI to a newer Qt** — write modern QML and use the properties that exist, at the cost of
  installing Qt outside the distribution's packages on every run.
- **Let local and CI differ and fix breakages as they appear** — no constraint on the code at
  all, and no setup work.

## Decision

QML and JavaScript in this repository must remain valid on Qt 6.4, because CI's Qt is the
authority on whether the build passes and it is the older one.

The rules this implies:

- Never use a legacy reserved word as an identifier.
- Never use a property newer than 6.4. Per-corner radius and per-side borders are out; draw the
  effect another way.
- `gh pr checks` after every push is part of the loop, not an afterthought. A local pass is not
  evidence the build is green, and this is the first thing to suspect when CI fails on code that
  passed locally.

## Consequences

- The overlay is written against a compiler four minor versions behind the one it is developed
  on, so some effects take a workaround where a property would do. The square-corner strips are
  the standing example.
- A local `mise run test` pass does not mean CI will pass. That is a real and permanent gap in
  the feedback loop, and the reason the loop includes waiting on CI.
- **Nothing pins the floor.** `ci.yml` installs Qt from `ubuntu-latest` apt with no version
  constraint, so the actual floor is whatever that image happens to ship. If the image moves to a
  newer Qt, the constraint silently loosens and this record becomes wrong without anything
  failing; if it moves to an older one, code that was fine starts breaking. The version in this
  record's title is therefore an observation, not a guarantee.
- The forbidden-identifier list has to be remembered by a human. No lint enforces it, so the
  error surfaces as a CI failure minutes after the push rather than in the editor.

## Assumptions and invalidation triggers

- *Assumes `ubuntu-latest` provides Qt 6.4.* Trigger: the runner image changes its Qt version
  ⇒ amend, and state the new floor. This will happen without warning.
- *Assumes CI installing Qt from apt is preferable to pinning a version.* Trigger: the
  unpinned floor causes a surprise break ⇒ supersede with a decision to pin explicitly.
- *Assumes the constraint is cheap enough to hold by hand.* Trigger: a linter or `qmllint`
  configuration can enforce the floor ⇒ amend and let the tool carry it.

## See also

- [[adrs/0003-test-tiers]] — Tier 1 is what CI runs, and where this gap shows up.
- `ROADMAP.md` for the per-corner radius finding; `.github/workflows/ci.yml` for the install.
