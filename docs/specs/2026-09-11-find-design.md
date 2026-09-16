# Omascape — find: type-ahead window search (design)

Date: 2026-09-11 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1 ·
builds on v2 + window states + monitor groups (`main` at `17d3dec`).
Status: **approved design, pre-implementation.** Branch `find`.

## Goal

Locate a window by name when many look alike. Press SUPER+P, type `slack`, press Enter: the Slack
window is highlighted while typing, and Enter focuses it (switching workspace and raising it).

## Scope

**In:** type-ahead filtering on any printable key (no explicit find mode), fuzzy ranking over
class and title, highlight + dim, cycling between matches, a find bar in the hint row, Enter
focuses the selected match, Esc clears the query, tests.

**Out:** windows on `special:` workspaces (the scratchpad stays excluded from the overview and
therefore from find), cursor editing / paste in the query, matching on workspace names, persisting
a query across summons, any action on bare letters. Ctrl+letter chords are **reserved** for
future actions (scratchpad toggle, workspace lock) and are ignored by this feature.

## Decisions (brainstorm 2026-09-11)

- **No mode.** Any letter starts the query; the query being non-empty is what changes the keys.
  Esc with a query clears it, Esc without one closes — "unwind one level" without a level
  variable. Chosen over an explicit `F` mode because the common path is one keystroke shorter and
  needs no mode indicator; the cost is that bare letters are no longer available as action keys.
- **Digits jump while the query is empty**, and are query characters once a letter has been typed.
- **Space never starts a query**; it appends once a query exists.
- **Enter focuses the window** (`hl.dsp.focus({ window = "address:…" })`, the tile-click path),
  not just its workspace — a floating or covered match is raised too.
- **Arrows stay spatial, Tab cycles by rank** (revised 2026-09-12 after live use). With a query,
  the four arrows use the normal nearest-in-direction rule restricted to workspaces that hold a
  match — Down from 1 lands on 6 if 6 has a match, Right from 2 skips a non-matching 3 — and
  select the best-ranked match on the workspace they land on. Tab/Shift+Tab step through the
  ranked list, wrapping. Rank-cycling on the arrows was tried first and felt arbitrary.
- **The find bar replaces the hint row** at the bottom of the card; no card resize, no layout
  shift.

## Behaviour

Keys, by whether `query` is empty:

| Key                       | query empty                         | query non-empty                          |
|---------------------------|-------------------------------------|------------------------------------------|
| letter / punctuation      | starts the query                    | appends                                  |
| space                     | ignored                             | appends                                  |
| digit                     | jump to workspace (1–9, 0 = 10)     | appends                                  |
| Backspace                 | nothing                             | deletes the last character               |
| Ctrl+Backspace            | nothing                             | clears the query                         |
| Esc                       | close the overlay                   | clear the query                          |
| Enter                     | jump to the selected workspace      | focus the selected match's window, close |
| Tab / Shift+Tab           | none                                | next / previous match by rank (wraps)    |
| Up / Down / Left / Right  | spatial box navigation              | spatial, among workspaces with a match   |
| Ctrl+letter               | ignored (reserved)                  | ignored (reserved)                       |

"Printable" is a key event with non-empty `text` and no Ctrl/Alt/Meta modifier. Enter with a query
but no match does nothing. Mouse behaviour is unchanged: a tile click focuses that window, a box
click jumps, a drag moves — all regardless of the query.

Clearing the query (Esc, Ctrl+Backspace, or deleting the last character) restores the box
selection to the workspace selected before the query started (`preQuerySelectedId`). If that
workspace no longer exists, the selection goes to the **focused** workspace, and to the first box
if there is none. This is deliberately not `rebuild()`'s rule (nearest surviving position): after
a search the user has no positional expectation to preserve. Every change of selection made by
find — typing, cycling, restoring — is followed by `ensureSelectedVisible()`, since assigning
`selectedIndex` alone does not scroll the Flickable.

## Matching — `Logic.findMatches(query, windows)`

Pure function in `logic.js`, Tier 1 unit-tested. Input: the query and the window list that
`buildInput()` already produces (`{ address, cls, title, … }`, special workspaces already
excluded), in layout order. Output: an array of `{ address, score }`, best first; empty for an
empty query.

- **Subsequence match**, case-insensitive: every query character must occur in order in the
  haystack. A window matches if either its class or its title matches. The score is that of the
  **best alignment**, not the first: for `ab`, "xax ab" scores its whole-word `ab`, not the
  isolated `a` at index 1 followed by a distant `b`.
- **Score** (higher is better) = best of the class score and the title score, where each is the
  sum of per-character bonuses: consecutive with the previous match, at the start of the haystack,
  or at the start of a word (after space, `-`, `_`, `.`, `/`, `:`); minus a small length penalty
  so a shorter haystack wins a tie. The penalty counts at most 80 haystack characters, so a
  real match always scores above zero and a very long title can never outweigh a word-start
  bonus. Scores are a ranking key only; the sign carries no meaning beyond that guarantee. The class score carries a fixed bonus so `slack` ranks the
  Slack window above a browser tab titled "Slack alternatives".
- **Stable**: ties keep layout order, so the ranking does not jitter while typing.
- Query characters are matched against the haystack lowercased; no diacritic folding (out of
  scope; `åäö` are matched literally).

## Visuals (query non-empty)

- **Tiles.** A matching tile draws an accent outline (a dedicated `accent` input on the tile,
  not `borderColor`, so a drop-target border and a match ring stay distinguishable); the
  selected match draws it at 2 px and the selection frame moves to that match's workspace box.
  Non-matching tiles fade to 0.35 opacity. Both changes animate with `motion.fast` / `motion.hover`
  and are instant with motion off.
- **Find bar.** The hint `Row` at the bottom of the card is replaced (same anchors, same height
  budget) by a `FindBar` item spanning the card interior, showing one group centred where the
  hints sit: a search glyph, the query text, and `n of m` (`n` = selected rank 1-based, `m` =
  match count). The query takes its natural width, capped at what the glyph and count leave,
  eliding at its *start* so the newest characters stay visible. A long query never widens the
  bar or pushes the count out of the card. With the query empty the hint row returns,
  carrying one new hint `type · find`. If `config.hint` is off, the card reserves no hint space
  normally but grows by the bar height while a query is active — the bar is the only place the
  query is visible, so it is never suppressed.
- **No match.** The bar shows the query in the muted foreground and `0 matches`; no tile is
  highlighted, tiles are still dimmed (the query is active), the selection frame stays where it
  was, Enter does nothing.

## State and data flow

`Overview` gains:

- `query: string` — cleared in `open()`.
- `matches: var` — ranked addresses from `Logic.findMatches`.
- `matchIndex: int` — index into `matches`, -1 when none.
- `preQuerySelectedId: int` — the box selection to restore when the query clears.

Two entry points recompute `matches` from `_windowByAddress` (the last `buildInput()` result), and
they choose the selection differently:

- **Query edit** (`setQuery(q)`, from typing, Backspace, Ctrl+Backspace): `matchIndex` becomes 0
  when there is any match, else -1. The best match for the *new* query is always the selection,
  so a browser that won for `s` cannot stay selected once `slack` ranks Slack first.
- **Background rebuild** (`rebuild()`, after `applyTiles`, while a query is active): windows opening
  or closing re-rank the list, but the selected *address* is kept if it still matches. If it is
  gone, the successor is the old `matchIndex` clamped to the new last index (removing 4 of 6
  selects the new 4th, removing the last selects the new last, removing the sole match gives -1).
  With no matches left the box selection stays where the frame already is.

Both then update the tile roles `matched` and `selectedMatch` in one diff-guarded pass over the
model (`applyMatchRoles`), move `selectedIndex` to the selected match's box, and scroll it into
view. A background rebuild that keeps the same match scrolls only if that match changed box (the
window moved workspace); a same-match settle tick never scrolls. Cycling (arrows/Tab) changes
`matchIndex` only and does the same two steps. Enter dispatches
`hl.dsp.focus({ window = "address:<addr>" })` and `root.close()` — the same two lines the tile
click uses.

`FindBar.qml` is display-only: properties `query`, `count`, `index` (visibility is the
caller's, bound to the query being non-empty), plus theme
inputs; no key handling, no focus. The key catcher remains the single focus item.

## Edge cases

- `open()` resets `query`, `matches`, `matchIndex`; a kept-loaded overlay never shows a stale
  filter.
- A drag with a query active behaves as today; the drop-target highlight takes precedence over the
  match outline on that one tile while the drag lasts, and that tile is never dimmed, so the drop
  border and insertion preview stay fully readable.
- The selection frame never leaves the current match on a rebuild unless that window is gone
  (successor rule above).
- Hyprland forwards SUPER chords over the overlay's exclusive focus (verified in v1), so SUPER+P
  still toggles the overlay mid-query.

## Tests

- **Tier 1, `tests/tst_find.qml`**: `findMatches` — subsequence and non-match, case-insensitivity,
  consecutive and word-start bonuses, class bonus over title, shorter-haystack tie-break, stable
  order for equal scores, empty query → empty result, best alignment over first occurrence, capped
  length penalty; `appendQueryText` — control characters, space, printable and multi-char text.
- **Tier 1, offscreen UI (`tests/ui/`)**: special-workspace windows never reach the match list
  (a `buildInput()` contract, with a positive control); typing through the key catcher sets `matched` /
  `selectedMatch` roles and the bar text; Tab cycles; Esc clears the query and restores the box
  selection; a second Esc closes; a digit jumps with an empty query and appends with a query.
  Selection rules: a query edit that changes rank 1 moves the selection to the new rank 1 even
  when the old selection still matches; a rebuild keeps the selected address; removal of the
  selected match at a middle, last, and sole position picks the clamped successor. Restore:
  clearing the query after the pre-query workspace vanished selects the focused workspace.
  Visibility: on an overflowing layout (more rows than the card height), typing a query whose
  best match sits in the last row scrolls it into view, and so does cycling to it and restoring
  a pre-query box outside the viewport.
- **Tier 2**: nothing new.
