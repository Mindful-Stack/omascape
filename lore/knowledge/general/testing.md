---
title: Testing — which tier a test belongs in, and how to write it
description: Tier 1 (`mise run test`) gates every merge and holds 532 test functions across four runners; a logic test is auto-discovered, a UI suite must be registered in tests/ui/run.sh by hand, and the offscreen fixture fails loudly rather than silently only where prepare.py guards it.
tags: [testing, ci, qml, javascript, tooling]
---

# Testing — which tier a test belongs in, and how to write it

[[adrs/0003-test-tiers]] records *why* there are two tiers and why a third was rejected. This node
is the working rule: where a new test goes, what it is called, and what has to be edited for it to
run at all. Counts taken 2026-09-20 against `origin/main`.

## Pick the tier, then pick the runner

`mise run test` → `tests/run.sh` is Tier 1 and is the only thing CI runs. It is four runners in
sequence, and "Tier 1 passed" means all four:

| Put it here | When | How it runs |
| --- | --- | --- |
| `tests/tst_*.qml` | Pure `logic.js` behaviour — geometry, reconcile, ranking, config parsing | `qmltestrunner -input tests/`, auto-discovered |
| `tests/ui/*.qml` | Anything needing real bindings, timers, `MouseArea` or a scene | `tests/ui/run.sh` → offscreen fixture built by `tests/ui/prepare.py` |
| `tests/lua/tst_chunks.lua` | A generated Lua chunk's behaviour | `tests/lua-check.sh`, real interpreter — see [[languages/lua/testing]] |
| `tests/dev-link.sh` | `scripts/dev-link.sh` behaviour | stub-driven bash, 117 assertion call sites |
| `tests/integration/` | Only a real compositor can show it | `mise run test-integration`, **not in CI** |

If it can be answered by calling a `Logic.*` function, it belongs in `tests/tst_*.qml` — that
tier is cheap, hermetic and already holds 188 of the 532 test functions.

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

## Before opening a PR

`README.md` § Testing carries the checklist and it is the repo-local standard: `mise run test`
passes, `omarchy plugin validate .` passes, plus the manual overlay checks that no tier covers.
Say in the PR which of them you ran — see [[general/release-and-distribution]].

## See also

- [[general/architecture]] — why the logic tier can be this large.
- [[frameworks/quickshell/review-checklist]] — what to check in the QML itself.
- [[languages/lua/testing]] — the parse-and-behave pair for generated chunks.
