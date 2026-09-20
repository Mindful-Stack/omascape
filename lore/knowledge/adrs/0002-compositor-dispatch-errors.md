---
title: "ADR-0002: Compositor operations are atomic Lua chunks that surface swallowed errors"
description: "Each compositor operation is one Lua chunk rendered on a single line, whose guarded pcall spans dispatch through a run() helper that raises on { ok = false }, because hl.dispatch never raises and an unparseable chunk is dropped silently."
tags: [adr, compositor, lua, hyprland, testing]
status: accepted
date: 2026-09-20
deciders: [Daniel Thyselius]
confidence: high
---

# ADR-0002: Compositor operations are atomic Lua chunks that surface swallowed errors

## Status

Accepted (retrospective) 2026-09-20; the decision predates this record. First dependent code:
`logic.js` (the chunk builders) and `tests/tst_layout.qml`.

## Context

Omascape drives Hyprland by handing it Lua. Two properties of that interface shape everything
else, and both fail quietly.

`hl.dispatch` never raises. A dispatcher that fails returns `{ ok = false, error = … }`, so code
that ignores the return value cannot tell a completed operation from a refused one.

An unparseable chunk is worse: the compositor drops it silently and reports the failure nowhere —
not to the caller, not to a log. A typo in generated Lua is therefore invisible at runtime and
indistinguishable from a no-op.

Multi-step operations compound this. Replaying a native tiled drop means float, then move, then
measure, then insert; a partial failure halfway through leaves a window in a state no single step
intended.

## Considered options

- **Dispatch each step separately from QML and check each return** — the control flow stays in
  JavaScript, where it is easy to read, debug and unit-test.
- **One chunk per operation, with the error handling inside the chunk** — the whole operation
  reaches the compositor as a single unit, so there is no window in which QML and the compositor
  disagree about how far it got.
- **One chunk per operation with no error handling** — by far the least code, and the happy path
  is identical.

## Decision

Each compositor operation is built as one Lua chunk, rendered on a single line, and every
chunk defines this helper before its first `pcall`:

```lua
local function run(d) local r = hl.dispatch(d) if r and r.ok == false then error(tostring(r.error), 0) end return r end
```

The rules that follow:

- Every `local ok, err = pcall(function() … end)` span — the risky steps and their cleanup —
  dispatches through `run()`, never bare `hl.dispatch`. `tests/tst_layout.qml` asserts this per
  span, per chunk.
- The best-effort focus and cursor restore deliberately stays raw `hl.dispatch`. Those steps are
  allowed to fail without failing the operation, so raising there would be wrong. This is the one
  intentional exception, and it is why the rule is written per guarded span rather than as a
  blanket ban on `hl.dispatch`.
- Every chunk is parse-checked by a real Lua interpreter before it can ship, because the
  compositor will not tell us. `tests/lua-check.sh` renders all chunks and `load()`s each one.
- That check carries a count floor: it fails unless at least 24 chunks render. Silent or empty
  output must not be able to pass as success.
- A failure that does reach the user gets a notification and a printed message, not a swallowed
  return.

## Consequences

- The operation's control flow lives in generated Lua, not in JavaScript, so it cannot be
  stepped through in a debugger and is harder to read than the equivalent QML.
- The chunk builders are string concatenation, which makes escaping a real hazard: text
  interpolated into a chunk must be escaped before it is truncated, or a budget cut can leave a
  trailing backslash that escapes the chunk's own closing quote.
- Every new chunk must be added to the dump fixture *and* the count floor raised, or the guard
  silently stops covering it while still passing.
- The count floor is a magic number that has to be maintained by hand. It catches an empty dump,
  which is what it is for, but it does not notice a chunk that renders wrongly.
- Multi-step operations are all-or-nothing from the compositor's point of view, which is the
  point, but it also means a partial failure reports one error for the whole operation rather
  than naming the step that broke.

## Assumptions and invalidation triggers

- *Assumes `hl.dispatch` signals failure by return value rather than by raising.* Trigger:
  Hyprland's Lua API starts raising on dispatcher failure ⇒ amend; `run()` becomes redundant.
- *Assumes the compositor drops unparseable chunks silently.* Trigger: it starts reporting parse
  errors to the caller or a log ⇒ amend; the real-Lua parse gate could be relaxed.
- *Assumes chunks stay small enough to build by concatenation.* Trigger: a chunk needs real
  control flow or exceeds what a single line can carry readably ⇒ supersede with a decision about
  shipping Lua as files.

## See also

- [[adrs/0003-test-tiers]] — the tier that runs the parse and behaviour suites.
- [[frameworks/hyprland/compositor-state]] — the read side of the same boundary: snapshots,
  refresh and the monitor epoch.
- `docs/specs/2026-09-12-lock-design.md`, `docs/specs/2026-09-15-actions-design.md` — the
  operations this shapes. Guard: `tests/tst_layout.qml`; parse and behaviour gate:
  `tests/lua-check.sh`, `tests/lua/tst_chunks.lua`.
