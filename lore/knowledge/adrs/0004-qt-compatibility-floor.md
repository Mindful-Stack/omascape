---
title: "ADR-0004: Qt 6.9 is the compatibility floor, pinned in CI"
description: "QML must stay valid on Qt 6.9, the oldest Qt whose QtQuick.Effects has the RectangularShadow the card uses, and CI installs exactly that instead of the runner's apt Qt 6.4. Legacy reserved words are still rejected in .qml files on 6.9 (not on 6.11), so that rule stays."
tags: [adr, ci, qml, testing, tooling]
status: accepted
date: 2026-09-20
deciders: [Daniel Thyselius]
confidence: high
---

# ADR-0004: Qt 6.9 is the compatibility floor, pinned in CI

## Status

Accepted 2026-09-20. Amends the same-day retrospective record of the 6.4 floor: that floor was
an observation of what `ubuntu-latest`'s apt happened to ship, this one is a decision and CI
installs it. First dependent code: `.github/workflows/ci.yml`, the `QMLTESTRUNNER` override in
`tests/run.sh`, `tests/ui/run.sh` and `tests/lua-check.sh`.

## Context

Development happens on Arch with Qt 6.11.2, which is also what Omarchy ships. Until this
record CI ran on `ubuntu-latest` with the distribution's Qt, 6.4, and the code was written to
stay valid there.

QML's failure mode across a version gap is the expensive one: an unknown property is a
**compile** error, not a warning and not a runtime fallback. So code using anything newer than
the CI compiler parses and runs perfectly on the developer's machine and fails the build with a
message about a property that plainly exists. Two traps cost time repeatedly under the 6.4
floor: legacy reserved words as identifiers, and Qt 6.7+ per-corner radius (the reason the first
drop-down prototype faked square corners with three overlay strips).

The 6.4 floor was also not the truth about the shipped plugin. `SoftShadow.qml` is a
`RectangularShadow` from `QtQuick.Effects`, which is Qt 6.9+
(`docs/specs/2026-09-10-restyle-design.md` § Design), and `tests/ui/prepare.py` stubs it
because the offscreen platform cannot run the shader — so CI never compiled the real shadow,
and a user on Qt 6.4 would have had a plugin that passed CI and did not render. The floor CI
held and the floor the plugin needed had drifted apart without anything failing.

Measured before deciding, with a one-file probe run through `qmltestrunner` on both versions:

| | Qt 6.9.3 | Qt 6.11.2 |
|---|---|---|
| `property int long: 1`, `var int = 3` in a `.qml` file | **rejected** — "Expected token `identifier`" | accepted |
| `var long = 5` in a `.pragma library` `.js` file | accepted | accepted |

So the reserved-word trap is a property of the QML-mode lexer up to at least 6.9 and is gone by
6.11; it applies to `.qml` files only, and it stays a rule here. The full Tier 1 suite passes on
6.9.3 with the pinned runner.

## Considered options

- **Keep 6.4 as the floor and keep working around it** — free, but the floor was already
  fiction: the shadow needs 6.9, and the runner's apt Qt is unpinned, so the real constraint was
  "whatever the image ships".
- **Pin CI to Qt 6.9 and call that the floor** — CI compiles what users need and no more;
  installing Qt outside apt costs one action and a cache hit per run.
- **Pin CI to 6.11 to match local** — removes the gap entirely, and with it the only check that
  the plugin runs on anything but the newest Qt. Omarchy users on a slightly older Arch snapshot
  would be unprotected.

## Decision

**QML in this repository must remain valid on Qt 6.9**, and CI installs Qt 6.9 explicitly
(`jurplel/install-qt-action`, `version: '6.9.*'`, pinned to a commit SHA) rather than taking
whatever the runner image ships. The test runners honour a `QMLTESTRUNNER` environment variable
so CI can name the pinned binary; without it they fall back to the distro lookups as before.

The rules this implies:

- **Never use a legacy reserved word as an identifier in a `.qml` file**: `long`, `short`,
  `int`, `char`, `float`, `double`, `byte`, `boolean`, `final`, `native`. Qt 6.9 rejects them
  in QML mode and 6.11 does not, so the mistake is invisible locally. `.js` files accept them on
  both, but the rule is kept for `logic.js` too so nobody has to remember which file they are in.
- **Never use a property newer than 6.9.** Check the "Since: Qt 6.x" line in the docs. Per-corner
  radius (6.7) and `RectangularShadow` (6.9) are in; anything introduced in 6.10 or 6.11 is out.
- `gh pr checks` after every push is part of the loop, not an afterthought. A local pass is not
  evidence the build is green, and this is the first thing to suspect when CI fails on code that
  passed locally.

## Consequences

- The floor is now the same number for CI and for users, and it is pinned: the version in this
  record's title is a guarantee, not an observation. Moving it is a deliberate edit to `ci.yml`
  and an amendment here.
- The gap between local (6.11) and CI (6.9) shrinks from seven minor versions to two, but it does
  not close, and the reserved-word trap lives exactly in that gap. A local `mise run test` pass
  still does not mean CI will pass.
- The square-corner strips workaround is obsolete; per-corner radius is available. The shipped
  drop-down already attaches square corners by construction and does not need it.
- CI takes one more step and a ~1 GB cached download instead of an apt install. Lua still comes
  from apt.
- The forbidden-identifier list still has to be remembered by a human. No lint enforces it, so
  the error surfaces as a CI failure minutes after the push rather than in the editor. The probe
  above is cheap to re-run if the list is ever in doubt: one `TestCase` with the identifiers,
  through the pinned runner.

## Assumptions and invalidation triggers

- *Assumes `RectangularShadow` is the newest Qt feature the plugin uses.* Trigger: a component
  needs something from 6.10+ ⇒ amend, bump `ci.yml`, and say so here.
- *Assumes the Qt download stays cacheable and the action stays maintained.* Trigger: the
  install step becomes the slowest or flakiest part of CI ⇒ supersede with a container image
  carrying the pinned Qt.
- *Assumes the constraint is cheap enough to hold by hand.* Trigger: a linter or `qmllint`
  configuration can enforce the floor ⇒ amend and let the tool carry it.
- *Assumes Omarchy keeps shipping Qt ≥ 6.9.* It ships 6.11 today and Arch does not go backwards.

## See also

- [[adrs/0003-test-tiers]] — Tier 1 is what CI runs, and where the local/CI gap shows up.
- [[frameworks/quickshell/review-checklist]] — the per-change checklist that carries these rules.
- `docs/specs/2026-09-10-restyle-design.md` for the `RectangularShadow` requirement;
  `.github/workflows/ci.yml` for the install.
