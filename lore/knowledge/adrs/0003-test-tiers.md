---
title: "ADR-0003: Two test tiers, and the third is deliberately not built"
description: "Tier 1 runs offscreen in CI and gates every merge; Tier 2 is a nested Hyprland run kept out of CI because it needs a compositor; Tier 3 pixel-level pointer e2e is rejected as flaky and low-value."
tags: [adr, testing, ci, tooling, lua]
status: accepted
date: 2026-09-20
deciders: [Daniel Thyselius]
confidence: high
---

# ADR-0003: Two test tiers, and the third is deliberately not built

## Status

Accepted (retrospective) 2026-09-20; the decision predates this record. First dependent code:
`tests/run.sh` and `.github/workflows/ci.yml`.

## Context

Omascape is a compositor overlay. Most of what it does is arithmetic — laying out windows,
reconciling workspaces, matching a search query — but the thing the user sees is a Wayland
surface driven by a real compositor, and a good deal of it is only verifiable by looking at it.

Anything that needs a live Hyprland cannot run on a GitHub runner. Anything that needs real
pointer input needs `ydotool` and a real seat on top of that. So the question was not whether to
test at these levels, but which levels earn a place in the gate that blocks a merge.

## Considered options

- **One suite, everything in CI** — a single command and a single answer, with nothing to
  remember about which level you ran.
- **Split by what the environment can provide** — the gate stays fast and hermetic, and the
  expensive levels stay runnable on demand without holding up a merge.
- **Split, and build every level including pixel-level pointer e2e** — the highest confidence
  available, since the thing actually under test is a pointer interacting with a surface.

## Decision

Tests are split by what the environment can provide, and only the hermetic level gates a merge.

- **Tier 1** is `mise run test` → `tests/run.sh`, and it is what CI runs. It is everything that
  works offscreen: the pure logic suites (`tests/tst_*.qml` under `qmltestrunner` with
  `QT_QPA_PLATFORM=offscreen`), the offscreen UI fixture built from production QML by
  `tests/ui/prepare.py`, the real-Lua parse and behaviour suites (`tests/lua-check.sh`), and the
  stub-driven shell tests (`tests/dev-link.sh`). No compositor, no seat, no display.
- **Tier 2** is `mise run test-integration`: a nested, isolated Hyprland asserting semantics that
  only a real compositor shows, such as silent-move behaviour. It is **not** in CI, because a
  runner cannot give it a compositor.
- **Tier 3** — full pointer-drag pixel e2e — is **rejected**, not deferred. It needs `ydotool`,
  it is flaky, and its marginal value over Tier 1's offscreen mouse-event tests does not justify
  either cost.

A `SKIP:` is not a pass. Where a tier can detect that its own runtime is missing, CI makes that
fatal rather than silent: `.github/workflows/ci.yml` sets `CI: "1"`, and `tests/lua-check.sh`
turns its skip into a failure under that variable, on the grounds that CI is supposed to install
what it needs.

## Consequences

- A merge is gated only on what runs without a compositor. Everything Tier 2 covers is
  unprotected by CI and depends on someone remembering to run it.
- The `SKIP:`-is-fatal rule is enforced in exactly one place. `tests/integration/` still exits 0
  on each of its several skip paths, so an integration run can report success having tested
  almost nothing — and since it is not in CI, nothing else catches that.
- Tier 1 carries a lot for one name: four different runners, two languages and a Python fixture
  generator. "Tier 1 passed" is a weaker statement than it sounds, and `tests/run.sh` failing
  does not say which part failed without reading the output.
- Rejecting Tier 3 means pointer behaviour is verified against synthesised Qt mouse events on an
  offscreen surface, not against a real seat. A bug that only appears with real input would not
  be caught by any tier.
- The offscreen UI fixture is generated from production QML rather than hand-written, so it
  cannot drift from the real components — but it also means a change to those components can
  break the fixture generator rather than the test, which reads as an unrelated failure.

## Assumptions and invalidation triggers

- *Assumes CI cannot provide a Wayland compositor.* Trigger: a runner image or container can host
  a nested Hyprland reliably ⇒ amend, and promote Tier 2 into the gate.
- *Assumes pointer-level e2e stays flaky and low-value.* Trigger: a drag or drop bug ships that
  Tier 1's offscreen mouse events could not have caught ⇒ supersede; the rejection was wrong.
- *Assumes skip-detection is worth having in only the tier that can detect it.* Trigger: an
  integration SKIP masks a real regression ⇒ amend and make the integration skips fatal too.

## See also

- [[adrs/0002-compositor-dispatch-errors]] — the Lua parse and behaviour suites inside Tier 1.
- [[adrs/0004-qt-compatibility-floor]] — why Tier 1 passing locally is not the same as CI
  passing.
- `README.md` § Testing, `DESIGN.md`, `ROADMAP.md` for the tier naming; `tests/run.sh`,
  `tests/ui/prepare.py`, `.github/workflows/ci.yml`.
