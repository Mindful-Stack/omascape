# Omascape — recognise key repeats that arrive as real key events (design)

Date: 2026-09-29 · Target: Omarchy Quattro (fcitx5 on by default), Hyprland 0.56.2, Quickshell 0.3.1.
Status: **designed, not built.**

## Problem

Holding Space to peek sometimes makes the preview flicker. It happens after the overview has been
open while a workspace switch (SUPER+Q, SUPER+1–9) focused a window, and then Space is held.

## Root cause (measured)

Temporary logging in the live shell (Space presses and releases with `isAutoRepeat`, peek
transitions, key-catcher focus, raw Hyprland events), reproduced by the owner on 2026-09-29, gave
two results:

- **Before the switch**, a held Space repeats as Qt auto-repeat, with a release and a press every
  25 ms, **both flagged `isAutoRepeat = true`**. The peek ignores them and stays open.
- **After the switch**, Hyprland reports `activelayout>>hl-virtual-keyboard-fcitx5,Swedish`, and
  `hyprctl devices` then lists `hl-virtual-keyboard-fcitx5` as the **main** keyboard. From then on,
  every repeat of a held key arrives as a release and a press **1 ms apart, both with
  `isAutoRepeat = false`**. The first comes after 595 ms, then one every 25 ms, which matches
  `repeat_delay = 600` and `repeat_rate = 40`. The peek reads each pair as a real key-up and a
  fresh press, so `peekRelease()` then `PEEK OPEN` runs 40 times a second. That is the flicker.

fcitx5, Omarchy's input-method daemon, takes over the keyboard when a text-input window gains
focus, and it generates key repeat itself as discrete events. The overview's focused item is a
plain `Item` that asks for no input method, so Omascape cannot switch this off from its side. It
has to tolerate it.

## Blast radius

Every place that trusts `isAutoRepeat` is affected under the same conditions. That was found by
reading the code; only the peek was observed.

| Site | Under fcitx5 repeats |
|---|---|
| Space release ends a peek (`Overview.qml` `Keys.onReleased`) | flicker (observed) |
| Ctrl+W closes the target, `!e.isAutoRepeat` | **a held Ctrl+W closes a window every 25 ms** |
| Ctrl+, opens settings, `!e.isAutoRepeat` | settings toggles repeatedly |
| digits in `activate: "select"` (`Logic.digitActivate(…, e.isAutoRepeat)`) | a held digit commits ("same digit again") |
| `menuDismissKey` / `settingsDismissKey` released, `!e.isAutoRepeat` | a key that dismissed a menu stops being swallowed mid-hold |
| `SettingsPanel.handleKey`, Enter, `!e.isAutoRepeat` | a held Enter re-fires the row |

## Design

**One repeat detector, applied once at the key catcher.** Every site above then reads its answer
instead of `e.isAutoRepeat`.

- **A release is provisional for a grace period**, `Logic.KEY_RELEASE_GRACE_MS = 50`. A release that
  Qt did not flag as a repeat is recorded as pending, and its effects wait for the grace to expire.
- **A press of the same key while its release is pending is a repeat.** The pending release is
  dropped as if it never happened, and the press is handled with `repeat = true`. A press Qt already
  flags as a repeat is a repeat too.
- **When the grace expires**, a pending release takes effect: the existing release body runs,
  moved into `handleKeyRelease(key)`.
- **Why 50 ms.** The measured fcitx5 gap between a synthetic release and its press is 1 ms. A person
  re-pressing the same key takes 80 ms or more, and a fast double-tap is around 100 ms. 50 ms
  separates the two with room on both sides, and the only cost is that releasing Space closes a
  peek 50 ms later.
- **Qt-flagged repeat releases** (`isAutoRepeat = true`) are ignored, as every release guard does
  today.
- **An expired release takes effect before the next press is judged**, so a late timer can never
  turn a genuine re-press into a repeat. The timer is started, never restarted, so another key's
  repeats cannot keep pushing a pending release back.
- **Focus loss flushes every pending release first.** A release that happened before the loss really
  happened, and its press, if it was synthetic, goes to another surface. After the flush the
  existing `peekAbort()` sees `peekKeyDown = false` and latches nothing.
- **`open()` resets the detector.** Nothing pending carries across summons.
- **The state lives in `logic.js`** as a small tracker object with pure functions (`trackPress`,
  `trackRelease`, `dueReleases`), which are unit-tested there. `Overview.qml` owns the one timer
  that expires the grace.
- **`SettingsPanel.handleKey`** receives a plain `{ key, modifiers, text, isAutoRepeat }` copy with
  `isAutoRepeat` set to the detector's answer. Its own tests already call it with plain objects.

**Test fixture.** `Overview.qml` exposes `property int keyReleaseGraceMs`. Its production default is
`Logic.KEY_RELEASE_GRACE_MS`, and at `<= 0` a release takes effect synchronously, exactly as it does
today. `tests/ui/prepare.py` rewrites the default to `0`, so the 83 existing Space press/release
sites keep their semantics unchanged. The new tests set `50` explicitly, and the suites' `cleanup()`
restores `0`. A logic test pins `KEY_RELEASE_GRACE_MS === 50`, so the production value cannot drift
unnoticed.

As a bonus, repeats become testable offscreen for the first time. QtTest cannot set `isAutoRepeat`,
but it can send the release-then-press pairs fcitx5 sends, so several existing "no offscreen test,
QtTest cannot synthesize isAutoRepeat" gaps close.

## Testing

- **Logic**: the tracker's press, release and expiry cases, per key, including a Qt-flagged repeat
  and a slow real re-press; plus `KEY_RELEASE_GRACE_MS === 50`.
- **UI, with grace 50**:
  - **Space**: hold Space, then five release/press pairs with no wait, then a 120 ms wait with the key
    still held. A counter on `peekingChanged` records no change. A final release followed by an
    80 ms wait closes the peek.
  - **Ctrl+W**: Ctrl+W, then release/press pairs of W. Exactly one close is dispatched.
  - **Digit, select mode**: a held digit shows the selection and never commits.
  - **Double-tap**: a digit released, then after more than 50 ms the same digit pressed again,
    enters. That press is a fresh press, not a repeat.
- **By hand**: the owner's repro. Open, switch workspace with SUPER+Q, hold Space, and there is no
  flicker.

## Out of scope

Stopping fcitx5 from taking the keyboard, which is a system configuration matter. The overview
already asks for no input method.
