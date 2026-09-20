---
title: Testing — which tier a test belongs in, and how to write it
description: Tier 1 (`mise run test`) gates every merge and holds 542 test functions across five runners; a logic test is auto-discovered, a UI suite must be registered in tests/ui/run.sh by hand, and the offscreen fixture fails loudly rather than silently only where prepare.py guards it.
tags: [testing, ci, qml, javascript, tooling]
---

# Testing — which tier a test belongs in, and how to write it

[[adrs/0003-test-tiers]] records *why* there are two tiers and why a third was rejected. This node
is the working rule: where a new test goes, what it is called, and what has to be edited for it to
run at all. Counts taken 2026-09-20 against `origin/main` (`7200771`).

## Pick the tier, then pick the runner

`mise run test` → `tests/run.sh` is Tier 1 and is the only thing CI runs. It is five runners in
sequence, and "Tier 1 passed" means all five:

| Put it here | When | How it runs |
| --- | --- | --- |
| `tests/tst_*.qml` | Pure `logic.js` behaviour — geometry, reconcile, ranking, config parsing | `qmltestrunner -input tests/`, auto-discovered |
| `tests/ui/*.qml` | Anything needing real bindings, timers, `MouseArea` or a scene | `tests/ui/run.sh` → offscreen fixture built by `tests/ui/prepare.py` |
| `tests/lua/tst_chunks.lua` | A generated Lua chunk's behaviour | `tests/lua-check.sh`, real interpreter — see [[languages/lua/testing]] |
| `tests/dev-link.sh` | `scripts/dev-link.sh` behaviour | stub-driven bash, 112 assertions — see [[languages/bash/test-harnesses]] |
| `tests/split-lore.sh` | `scripts/split-lore.sh` behaviour | throwaway git repos, 32 assertions |
| `tests/integration/` | Only a real compositor can show it | `mise run test-integration`, **not in CI** |

If it can be answered by calling a `Logic.*` function, it belongs in `tests/tst_*.qml` — that
tier is cheap, hermetic and already holds 188 of the 542 test functions.

## Registering the test

- **`tests/tst_*.qml` is free.** The runner scans `tests/` for the `tst_` prefix, so a new file
  runs the moment it exists.
- **`tests/ui/*.qml` is not.** `tests/ui/run.sh` copies each suite into the fixture by name, one
  `cp` line per file — eleven of them today, one per suite. **A new `tests/ui/foo.qml` that is not
  added to that list simply never runs, and nothing reports it.** Add the `cp` line in the same
  commit as the suite.

## Naming and assertions

Test functions are `test_` plus a snake_case sentence describing the behaviour, not the function
under test: `test_word_start_beats_mid_word`, `test_equal_scores_keep_input_order`,
`test_best_alignment_not_first_occurrence`. 180 of the 188 logic-tier names carry at least one
underscore after the prefix; the eight that do not are single-word cases.

Assertions across both QML tiers: `compare` 1503, `verify` 597, `fuzzyCompare` 36, `fail` 23,
`tryVerify` 9, `tryCompare` 1. Prefer `compare` — it prints both values on failure where `verify`
prints only "false". `fuzzyCompare` is for animated or scaled geometry only.

## Every test says what it falsifies

The strongest convention in this suite is one comment line. **350 `Distinguishes:` comments sit
against 542 test functions**, each naming the specific wrong implementation the test would catch.
11 of the 17 test files use it, led by `tests/ui/actions.qml` (78) and `tests/tst_actions.qml`
(55).

```qml
// Distinguishes: a fixture where a synthetic mouseMove never reaches the HoverHandler — which
// would make every pointer-targeting test below vacuously pass on the keyboard path.
function test_a_mouse_move_makes_the_pointer_live() {
```

It is not a description of the test. It names the **bug that would survive without it**, which is
a different sentence and a much harder one to write — and writing it is the check. A test whose
`Distinguishes:` line can only say "it would be broken" is a test that is asserting the
implementation back to itself.

Three forms recur, and all three are worth copying:

- **The regression it was written for.** `// Distinguishes: THE bug this suite exists for (found
  on a real desktop, 2026-09-18)` — with the date and where it was found, so the test can be read
  years later as the record of an incident.
- **The plausible wrong fix.** `tests/ui/monitors.qml:98` distinguishes "THE regression a naive
  'skip what has no monitor' produces" — it pins the *near miss*, not just the bug.
- **Fixture health.** `tests/ui/actions.qml`, `activate.qml` and `peek.qml` each open with a
  `// ---- fixture health ----` section whose tests exist only to prove the other tests are not
  vacuous: that `keyClick` reaches the key catcher, that a synthetic `mouseMove` reaches the
  `HoverHandler`. **An offscreen fixture can fail by doing nothing**, and every assertion after it
  passes. If a new UI suite depends on a synthetic event reaching a handler, prove it reaches the
  handler first.

Write the line before the test body. If you cannot say what a passing run rules out, the test is
not ready.

**Wait on a condition, not on a duration.** Use `tryVerify(() => cond)` whenever the test is
waiting for something to become true. Use `wait(N)` only where the test is deliberately asserting
that something has **not** happened yet within a window — a negative-time assertion `tryVerify`
cannot express.

> **The suite does not comply yet.** There are 150 `wait(N)` calls across 18 distinct literal
> durations (48 × `wait(30)`, 25 × `wait(400)`, one `wait(3000)`) against 10 uses of
> `tryVerify`/`tryCompare`. A literal wait encodes a guess about machine speed, and the durations
> here were evidently tuned by hand until they passed. Migration is on touch, not a sweep:
> [omascape#35](https://github.com/Mindful-Stack/omascape/issues/35). The rule above applies to
> new tests from now.

## The offscreen fixture fails loudly only where it is told to

`tests/ui/prepare.py` (422 lines) builds the fixture from production QML, replacing only the
shell and compositor adapters, so drag handlers, models, bindings and timers are the real ones.
Two guards make its substitutions safe, and both matter when you add a component:

- Every substitution goes through `replaced(text, old, new, what, count=1)`, which raises
  `SystemExit` unless the pattern matches *exactly* the expected number of times. A renamed
  delegate or a second `Variants` block fails the generator by name instead of quietly leaving an
  uninstantiated surface that reads as "the feature is broken".
- **An unresolved `Color.*` reference is a `QWARN`, not a compile error** — the suite would pass
  having rendered nothing. `prepare.py` rewrites `Color.menu.*` and `Color.bar.*` to a literal and
  then greps the fixture for any surviving `Color.` reference, exiting if one is found. **A new
  `Color.<namespace>` in production QML needs its own rewrite in `prepare.py`**; the guard will
  tell you, which is the only reason it is safe to forget.

A fixture divergence is worth a comment where it exists: `Overview.qml:905-909` records that
`prepare.py` rewrites every `PanelWindow {` into `Item {`, which makes a `mapToItem` call legal in
the fixture that throws in the running shell.

## A `SKIP:` is not a pass

CI sets `CI: "1"` (`.github/workflows/ci.yml`). `tests/lua-check.sh:20-24` turns its missing-runtime
skip into a failure under that variable. **It is the only place that does.** Every skip path in
`tests/integration/` exits 0 — `lib.sh:8`, `actions-probe.sh:7,15,79,82,139,154`,
`lock-probe.sh:22`, `peek-probe.sh:117,158` — so an integration run can report success having
tested almost nothing. When reading a Tier 2 result, read the output, not the exit code.

**A new Tier 1 gate must carry that `CI:` guard**, or it is a check that passes when its runtime
is missing. The shape, and the two shell harness idioms to copy from, are in
[[languages/bash/test-harnesses]].

## Before opening a PR

`README.md` § Testing carries the checklist and it is the repo-local standard: `mise run test`
passes, `omarchy plugin validate .` passes, plus the manual overlay checks that no tier covers.
Say in the PR which of them you ran — see [[general/release-and-distribution]].

## See also

- [[general/architecture]] — why the logic tier can be this large.
- [[frameworks/quickshell/review-checklist]] — what to check in the QML itself.
- [[languages/lua/testing]] — the parse-and-behave pair for generated chunks.
- [[languages/bash/test-harnesses]] — how the two bash suites assert, and what a `SKIP:` owes you.
- [[languages/bash/script-conventions]] — every runner here is a bash entry point.
- [[domain/targeting-and-pointer-liveness]] — the rule the largest suites exist to pin.
- [[general/feature-workflow]] — where a plan's tasks come from, and the gotcha list that
  belongs here instead of in the next plan preamble.
