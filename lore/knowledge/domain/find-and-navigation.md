---
title: Find has no mode — the query's emptiness is the mode
description: Any letter starts a query and the query being non-empty is what changes the keys, so digits jump while it is empty and type once it is not; matching is a best-alignment dynamic programme over class and title, and ties break on input order so the ranking cannot jitter while typing.
tags: [domain, javascript, ui, testing]
---

# Find has no mode — the query's emptiness is the mode

There is no find mode to enter or leave. **Any letter starts a query, and the query being
non-empty is the only thing that changes what the keys do.** Measured 2026-09-20 against
`origin/main` (`7200771`); design in `docs/specs/2026-09-11-find-design.md`.

The key handler computes it once — `var finding = root.query.length > 0` — and reads it at five
places. [[domain/targeting-and-pointer-liveness]] covers what the query does to the
*target*; this node is what it does to the keys and the ranking.

## What the emptiness decides

| Key | Query empty | Query active |
|---|---|---|
| a letter | starts the query | appends |
| a digit | jumps to that workspace (or select-then-enter under the `select` policy) | appends |
| `Space` | peeks the target | appends |
| `?` | toggles the hint tier | appends |
| `Tab` | steps the **workspace** selection | cycles matches **by rank** |
| arrows | step the **window cursor** | step spatially over **boxes holding a match** |
| `Backspace` | — | deletes one; `Ctrl+Backspace` clears |

The arrow behaviour is the subtle one, and both halves are deliberate. Without a query the arrows
move the window cursor while `Tab` moves the workspace — *"the Cmd+Tab / Alt+Tab habit, with the
key that summoned the overview under the same hand"*. With a query they go back to being spatial,
but only over boxes that hold a match, so `Right` from workspace 2 lands on 4 when 3 has none and
the grid still reads as a grid. That half was revised into the spec after live use.

**`Escape` unwinds one level at a time** rather than branching on `finding`: clear the window
cursor if there is one, else clear the query if there is one, else close. Because `setQuery()`
clears the cursor, those two can never both be set, and the ladder is total.

**Find and the cursor are the same intent and never coexist.** `setQuery()` clears the window
cursor on the first character, with the reason in the line itself.

## `appendQueryText` decides what is typing

Not the key handler — a pure function, because the Qt behaviour it guards against is not obvious:

- **Control characters never extend the query.** `Backspace`, `Escape`, `Return` and `Tab` all
  arrive with *non-empty* `text` on Qt, so testing "does the event have text" is not enough; the
  function rejects anything below `0x20` plus `0x7f`.
- **Whitespace never *starts* a query**, but appends once one exists.
- **Digits are accepted here.** Whether a digit jumps instead is the key handler's decision, made
  from whether the query is empty — so the two rules stay in one place each.

## Ranking

`Logic.fuzzyScore(needle, hay)` is a dynamic programme over (query character, haystack position),
scoring **best alignment, not first occurrence** — greedy first-occurrence would trap "ab" on the
isolated `a` of "xax ab" and miss the whole word.

| Contribution | Value |
|---|---|
| a matched character | 1 |
| directly following the previous match | +2 |
| at a word start | +3 |
| per haystack character | −0.01, capped at 80 characters |
| the match was on the window class, not the title | +2 |

The length cap exists so a real match always scores above zero and a very long title cannot
outweigh a word-start bonus. The class bonus exists so `"slack"` ranks the Slack app above a
browser tab titled "Slack …".

`findMatches` scores class and title and keeps the better of the two, then sorts **score
descending, input order ascending**. The stable tie-break is what stops the list jittering while
the user types.

## One recorded near-miss worth not undoing

A class hit computes `(base − penalty) + bonus` and a title hit `(base + bonus) − penalty`. These
are mathematically equal and can differ **by one ulp** in doubles, which would skip the
order tie-break and let the ranking jitter after all. The comment records that it is unreachable
with realistic window names — **0 of 300k generated cases** — and states the rule for anyone
editing the line: *add the bonus before subtracting the penalty*. Do not "tidy" that expression.

## See also

- [[domain/targeting-and-pointer-liveness]] — why a query with no match is a terminal "no target".
- [[domain/ubiquitous-language]] — cursor, selection, target, latch.
- [[languages/javascript/code-style]] — why the key codes here are hand-written hex.
- [[general/testing]] — `tests/tst_find.qml` and `tests/ui/find.qml` carry 56 `Distinguishes:`
  comments between them.
- `docs/specs/2026-09-11-find-design.md`; the digit rule under the `select` policy is
  `docs/specs/2026-09-18-activate-select-design.md`.
