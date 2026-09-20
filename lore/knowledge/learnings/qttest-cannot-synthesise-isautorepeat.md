---
title: "QtTest cannot synthesise isAutoRepeat"
description: "QtTest's QML key-event API cannot set isAutoRepeat and a hand-built event throws before the handler runs, so the one flag-keyed guard (Ctrl+W close-all) has no offscreen test and is a live-check item, while the digit latch deliberately keys on state so a second press covers the repeat path."
tags: [frameworks, quickshell, qml, testing]
confidence: verified
source: developer-input
date: 2026-09-20
---

# QtTest cannot synthesise `isAutoRepeat`

`keyPress`, `keyRelease` and `keyClick` in `QtTest`'s QML API build their key events with
`isAutoRepeat = false`, and there is no argument to set it. The workaround does not work either:
a hand-built event object thrown at `Keys.pressed()` fails to convert to a `QQuickKeyEvent*`
and throws before the handler body runs, so a test built on it passes identically whether or
not the guard exists (`tests/ui/actions.qml`, comment above the close-all cases).

## What the code does

Two guards, two strategies:

- **The `!e.isAutoRepeat` guard on Ctrl+W** (auto-repeat closing a whole workspace from one
  held chord) keys on the flag because nothing else distinguishes the repeat. It has **no
  offscreen test** and is a live-check item: holding Ctrl+W on a workspace with several windows
  must dispatch exactly one close.
- **The digit latch** deliberately does *not* key on the flag for presses — only the release
  handler does — so a second `keyPress` while the key is still held exercises the same path a
  repeat would take, and that is how `tests/ui/actions.qml` covers it.

## The rule

A new auto-repeat guard that keys on the flag is untestable offscreen; say so in a comment at
the guard and add the live check to `README.md` § Testing. Do not "simplify" the latch into a
flag check — it would read cleaner and silently delete its only offscreen test.

## See also

- [[general/testing]] — which tier a test belongs in, and what the offscreen fixture can and cannot do.
- [[domain/targeting-and-pointer-liveness]] — the keyboard-side doctrine these guards serve.
