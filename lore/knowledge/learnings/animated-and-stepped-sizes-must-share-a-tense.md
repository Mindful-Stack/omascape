---
title: "A stepped size next to an animated one is spurious motion"
description: "The card's height is in flight for 160 ms after any layout change, so a reader of a size must pick a tense: hold your place against the growing card with the SHOWN value, ask \"does this fit?\" with the RESTING one — backwards gives spurious motion no warning or settled assertion catches."
tags: [frameworks, quickshell, qml, ui]
confidence: verified
source: developer-input
date: 2026-09-20
---

# A stepped size next to an animated one is spurious motion

Measured twice on 2026-09-20 in the offscreen fixture, once in each direction.

`card.implicitHeight` carries a `Behavior` (`motion.normal` = 160 ms, `motion.move`), so after
**any** layout change the card's size is a value in flight for the next 160 ms while the content
that caused the change is already at its new size. Every reader of a size therefore picks a
tense, implicitly. Picking the wrong one is not an error, a `QWARN`, or a test failure — it is
motion that runs counter to the card's own, and it reads to the user as a flicker.

## Both directions, both shipped

| Site | Asked for | Should have asked | What it looked like |
| --- | --- | --- | --- |
| `toggleScratchpad()`'s scroll-into-view | the IN-FLIGHT `flick.height` | the resting `flick.restingHeight` | a row the card was already growing to fit measured as below the fold, so the grid scrolled **242 px** down and slid back up over the next 160 ms, against the card's growth (1920x1080, bar mode) |
| `hintBox`, a `Column` anchored to the card's bottom | its own new size, in one frame, against a card edge that had not moved yet | the card's curve — `Behavior on height` at the same duration and easing | `?` shoved the first hint tier **21 px** up in a single frame and walked it back down. Bar mode pins the card's top, so the row's resting position is identical before and after: every one of those pixels was spurious |

The second one had a quieter half in the same commit: `flick.height` subtracted the *resting*
hint budget from the card's *animated* height, so expanding a tier took 21 px off the viewport
at once and gave it back over 160 ms — clipping the bottom row of tiles and uncovering it again.

## The rule

Name both forms and make the choice explicit at each site. `Overview.qml` now does:

- `card.hintSpace` — RESTING, built from `implicitHeight`. What the card sizes itself *to*.
- `card.shownHintSpace` — SHOWN, built from `height`. What stands on the card *this frame*.
- `flick.restingHeight` — the viewport size the card is heading for, derived from the canvas and
  the cap rather than from the animated `implicitHeight`.

Then:

- Anything that must **hold its place** against a growing card subtracts the SHOWN value, so both
  terms move together (`flick.height`).
- Anything deciding **"does this fit?"** asks the RESTING one, because the answer is about where
  the layout lands, not where it currently is (`toggleScratchpad`, `restingHeight` itself).
- A `Positioner` (`Column`/`Row`) anchored to an edge that animates needs its **own** `Behavior on
  height`, same duration and easing, plus `clip` — otherwise it takes its new size in one frame
  and hauls its children against the edge it is pinned to. With the two curves matched, the
  growth is *uncovered* in the room the card gains, which is the same trick `card.clip` plays
  during the bar-mode unfurl.

Both `Behavior`s sit behind the coarser `root.layoutMotion` gate, not `motion.enabled` — see
[[frameworks/quickshell/theming-and-motion]].

## Why it survives review and the suite

Neither bug changes a single resting value. Every assertion taken after the animation settles
passes, in both the broken and the fixed code, and with `motion.scale = 0` — which most of the UI
suite sets — the defect cannot occur at all, because nothing is ever in flight.

Catching it takes a sample **during** the 160 ms, with motion deliberately turned back on:

```qml
view.motion.scale = 1
var start = view.testHintRow.mapToItem(view, 0, 0).y
keyClick("?")
var worst = 0
for (var i = 0; i < 12; i++) {           // 12 x 20 ms spans the 160 ms animation
    wait(20)
    worst = Math.max(worst, Math.abs(view.testHintRow.mapToItem(view, 0, 0).y - start))
}
verify(worst <= 1, "the row must stay put while the card grows beneath it")
```

Bar mode is the sharpest place to assert it: the card's top is pinned and it grows downward, so
anything above the grown edge has an identical resting position before and after and the claim
becomes "must not move at all" rather than "must not overshoot". Wait for `layoutMotion` first —
the entrance (200 ms) and `openSettle` (300 ms) both suppress the layout `Behavior`s, so a sample
taken too early measures the card still opening and cannot show the defect either way.

## See also

- [[frameworks/quickshell/theming-and-motion]] — where `motion.normal`/`motion.move` and the
  `layoutMotion` gate are defined, and the rule that every `Behavior` is guarded.
- [[learnings/a-behavior-cannot-share-x-with-drag-target]] — the other way a `Behavior` fights
  something else writing the same property.
- [[general/testing]] — the offscreen tier both measurements were taken in, and why a settled
  assertion is not enough.
- [[adrs/0003-test-tiers]] — which tier a motion claim belongs in.
