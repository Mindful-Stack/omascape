---
title: Lua chunk testing
description: Chunks are checked twice — parsed by a real interpreter so a silent drop cannot pass, then run against `tests/lua/mock_hl.lua`, where a new dispatcher must be applied and never stubbed as a no-op.
tags: [languages, lua, testing]
---

# Lua chunk testing

Two files hold all the real Lua in the repository: `tests/lua/mock_hl.lua` (345 lines) and
`tests/lua/tst_chunks.lua`. Both exist because a generated chunk has two independent ways to
fail invisibly. Counts taken 2026-09-20 against this branch's base, `a72ecda`; `main` has moved
on since, so the totals read low. The rules, not the totals, are the standard.

## Two checks, for two failure modes

`tests/lua-check.sh` does both, in order:

1. **Parse.** Every chunk is rendered and passed to a real interpreter's `load()`. An
   unparseable chunk is dropped *silently* by the compositor and reported nowhere, so a syntax
   error is otherwise indistinguishable from a no-op at runtime.
2. **Behave.** `tests/lua/tst_chunks.lua` runs the chunks against the mock `hl` and asserts
   dispatch order and end state.

The parse step carries a count floor (`lua-check.sh:84`): it fails unless at least 24 chunks
render, because *silent or empty output must not pass as success*. Adding a chunk means raising
the floor.

Under `CI: "1"` — set by `.github/workflows/ci.yml` — a missing interpreter is a **failure**, not
a skip. Locally it still skips, so read the output rather than the exit code. See
[[adrs/0003-test-tiers]].

## The mock must apply, never stub

`mock_hl.lua:7-8` states the rule:

> A new dispatcher used by a chunk must be added to `hl.dsp` **and** applied in `hl.dispatch`;
> never stub it as a no-op, or "ends tiled"-style checks become vacuous.

A no-op dispatcher makes the chunk look correct while proving nothing: the assertion that a window
"ends tiled" passes because nothing ever untiled it. This is the single easiest way to add a test
that cannot fail.

The mock mirrors the real contract deliberately: like Hyprland's, its `hl.dispatch` **never
raises** — it returns `{ ok = true }`, or `{ ok = false, error = … }` when `hl.__fail_on` names
the dispatcher. The chunk's own `run()` guard is what turns that into the failure path, so the
mock exercises the guard rather than replacing it.

## What the mock deliberately does not model

Stated up front in `mock_hl.lua` so tests do not assert things it cannot support: geometry never
re-lays out (there is no dwindle), and focus is a constant. **Assert dispatch order and end state,
never geometry.**

Injection points, rather than editing the mock per test: `hl.__fail_on` (with `hl.__fail_nth` and
`hl.__fail_sel` to target an occurrence or a selector), `hl.__runtime_dir`, `hl.__dir_exists`,
`hl.__os` / `hl.__io` fakes that fall through to the real libraries via `__index`, and counters
like `hl.__opens` and `hl.__mkdirs`.

Two traps the mock documents because the real compositor has them:

- `hl.__os.execute` always returns nil, like the real compositor's Lua, which reaps the child
  itself. A chunk must verify a directory some other way — a probe file — and never by trusting
  that return value.
- `hl.notification` is missing on older Hyprland, which is why `reportLua` wraps the
  notification in its own `pcall`.

## Assertion style

Message assertions use substring matching, not equality:

```lua
  assert(text:find("XDG_RUNTIME_DIR", 1, true), "names the share-state failure, got: " .. text)
```

The `true` makes it a plain find rather than a pattern. Assert on the part of the message you mean
and include the actual text in the failure message.

Note what this does not cover: a substring assertion will not notice a Lua position prefix
creeping into a message, so it cannot police `error()` levels. That rule is held by convention
and review, not by a test — see [[languages/lua/chunk-authoring]].

## See Also

- [[languages/lua/chunk-authoring]] — how the chunks under test are built.
- [[adrs/0002-compositor-dispatch-errors]] — the contract both checks defend.
- [[adrs/0003-test-tiers]] — Tier 1 is what CI runs.
- `docs/plans/2026-09-10-hardening.md` — the plan that built both checks and the mock; also
  records that the `qml` runtime is `/usr/lib/qt6/bin/qml` from `qml-qt6` on Ubuntu noble and
  not on `PATH` there.
