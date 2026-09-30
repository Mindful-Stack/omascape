---
title: "Under fcitx5, a held key's repeats arrive as real key events, not Qt auto-repeat"
description: "Under fcitx5, a held key repeats as release+press pairs 1 ms apart with isAutoRepeat false, so guards trusting the flag read a hold as fresh presses; a release now only takes effect after KEY_RELEASE_GRACE_MS (50 ms), and a same-key press inside it is a repeat."
tags: [frameworks, quickshell, qml, compositor]
confidence: verified
source: developer-input
date: 2026-09-29
---

# Under fcitx5, a held key's repeats arrive as real key events, not Qt auto-repeat

## The symptom

Holding Space to peek sometimes made the preview flicker, but only after the overview had been
open while a workspace switch (SUPER+Q, SUPER+1–9) focused a window, and Space was then held.

## The measurement

Temporary logging in the live shell (Space presses and releases with `isAutoRepeat`, peek
transitions, key-catcher focus, raw Hyprland events), reproduced by the owner on 2026-09-29:

- **Before the switch**, a held Space repeats as ordinary Qt auto-repeat: a release and a press
  every 25 ms, both flagged `isAutoRepeat = true`.
- **After the switch**, Hyprland reports `activelayout>>hl-virtual-keyboard-fcitx5,Swedish`, and
  `hyprctl devices` then lists `hl-virtual-keyboard-fcitx5` as the **main** keyboard. From then on,
  every repeat of a held key arrives as a release and a press **1 ms apart, both with
  `isAutoRepeat = false`** — the first after 595 ms, then one every 25 ms, matching
  `repeat_delay = 600` / `repeat_rate = 40`. Every guard reading `isAutoRepeat` sees a stream of
  fresh presses instead of one hold.

Full detail: `docs/specs/2026-09-29-synthetic-key-repeat-design.md`.

## Why Omascape tolerates it rather than preventing it

fcitx5, Omarchy's input-method daemon, takes over the keyboard once a text-input window has had
focus, and it generates repeat itself as discrete synthetic events. The overview's focused item is
a plain `Item` that asks for no input method, so Omascape's overlay is not what triggers the
takeover. The switch is compositor-wide: it happens when *another* window gains text-input focus.
No Omascape-side mechanism to opt this surface out was found; system-level options (fcitx5 or
Hyprland input-method configuration) were not investigated. So the overview tolerates the repeats
it is handed rather than preventing them.

## The rule

**Never trust `e.isAutoRepeat` alone; go through `Logic.trackPress`.** Every guard that used to
read the raw flag now reads the tracker's answer instead, computed once per press at the key
catcher (`Overview.qml:2246`, `var rep = Logic.trackPress(root._keyRepeat, e.key,
e.isAutoRepeat)`), and threaded to the sites that need it — including
`SettingsPanel.handleKey`'s own copy of `isAutoRepeat` (`Overview.qml:2333`).

The tracker (`logic.js:1741-1786`) is a small pending-release map with pure functions:

- `Logic.KEY_RELEASE_GRACE_MS` (`logic.js:1741`) is `50`.
- `Logic.trackPress(tr, key, qtRepeat)` (`logic.js:1744`) answers true when Qt already flagged the
  press, or when the same key has a release still pending — the fcitx5 case.
- `Logic.trackRelease(tr, key, qtRepeat, now)` (`logic.js:1750`) records a real release as pending;
  a Qt-flagged repeat release is ignored, as every release guard already was.
- `Logic.dueReleases(tr, now, grace, force)` (`logic.js:1757`) and `Logic.nextReleaseDueIn(tr, now,
  grace)` (`logic.js:1777`) let `Overview.qml` flush releases whose grace has passed and re-arm a
  single timer targeted at the OLDEST pending release, so a second key let go later can never
  delay an older one past its own grace.

`Overview.qml` owns the one timer: `keyReleaseGraceMs` (`Overview.qml:634`),
`flushKeyReleases()` (`Overview.qml:640-644`), `armKeyReleaseGrace()` (`Overview.qml:649-654`) and
`handleKeyRelease()` (`Overview.qml:655-664`), which holds the release body — `Keys.onReleased`
(`Overview.qml:2443`) only records the release as provisional and arms the grace; it no longer
runs the release effects inline.

## The 50 ms grace, and why

A release is provisional: it does not take effect until `KEY_RELEASE_GRACE_MS` has passed with no
press of the same key. A press inside that window drops the pending release and is treated as a
repeat instead. 50 ms was chosen because the measured fcitx5 gap between a synthetic release and
its press is 1 ms, while a person re-pressing the same key takes 80 ms or more (a fast double-tap
is around 100 ms) — 50 ms separates the two with room on both sides. The one case this reads
wrong is a deliberate same-key double-tap faster than 50 ms, and it fails safe: in select mode, `2
2` faster than the grace only selects workspace 2, it does not enter, since the second press lands
while the first release is still pending.

## The fixture's 0 grace

`tests/ui/prepare.py` rewrites `keyReleaseGraceMs` to `0` for the offscreen suites. At `<= 0` a
release takes effect synchronously (`Overview.qml:2447`, `if (root.keyReleaseGraceMs <= 0) {
root.flushKeyReleases(true); return }`), exactly as it did before this tracker existed — so the
roughly 80 pre-existing Space press/release sites keep their semantics unchanged, and only the tests that
explicitly set `50` exercise the grace itself.

## See also

- [[learnings/hyprland-056-layer-enter-offset]] — another key-catcher/timing trap on this same
  focused item.
- [[frameworks/quickshell/component-patterns]] — the leaf-component conventions this tracker's
  host (`Overview.qml`) follows.
- Design: `docs/specs/2026-09-29-synthetic-key-repeat-design.md`.
