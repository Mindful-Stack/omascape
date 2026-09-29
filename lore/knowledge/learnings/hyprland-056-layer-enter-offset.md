---
title: "Hyprland 0.56 hands a mapping layer an off-by-the-monitor pointer enter"
description: "LayerSurface.cpp subtracts the monitor's layout offset twice when computing the wl_pointer.enter position for a keyboard-grabbing layer, so on any monitor not at (0,0) a click made before the next motion is dropped; Omascape warps the cursor in place on its own openlayer event to correct it."
tags: [frameworks, hyprland, quickshell, compositor]
confidence: verified
source: developer-input
date: 2026-09-27
---

# Hyprland 0.56 hands a mapping layer an off-by-the-monitor pointer enter

## The symptom

On a monitor that is not at layout position (0,0), a click made after the overview opens and
**before the pointer moves** is dropped. Open the overview by its bar button, click the same spot
again to close it, and nothing happens; moving the mouse first, then clicking, works. The keybind
summon has the same dead first click — the bar button only makes it obvious, because the natural
second click comes without moving.

## The cause

`src/desktop/view/LayerSurface.cpp:203` (tag v0.56.2, commit `efb5099`), in `onMap`, for a layer
that grabs keyboard focus (`OnDemand`, which the overview's own surface is):

```cpp
const auto LOCAL = g_pInputManager->getMouseCoordsInternal()
                 - Vector2D(m_geometry.x + PMONITOR->m_position.x, m_geometry.y + PMONITOR->m_position.y);
g_pSeatManager->setPointerFocus(m_wlSurface->resource(), LOCAL);
```

`m_geometry` is already global — `Renderer.cpp`'s `arrangeLayerArray` builds it from
`full_area = {monitor.position, monitor.size}` — so `PMONITOR->m_position` is subtracted a second
time. The client receives `wl_pointer.enter` at a point far outside its surface. Qt then places a
press before any motion outside every item, and the press is dropped silently: nothing logs it.

## The evidence

A standalone Quickshell client under `WAYLAND_DEBUG`, with the cursor still at (849, 2650) on
eDP-1 at (200, 1440), mapped a full-screen `OnDemand` overlay. The client received
`enter(449.1, −229.8)`, where it expected (649, 1210) — the error is exactly the monitor offset.
Two runs with the cursor verified still gave the same result. Instrumented Omascape agreed: the
bar lost the pointer on map, and the overview's scrim saw neither hover nor press until the first
motion.

## The workaround, and where it lives

A same-position `hl.dsp.cursor.move` after the map makes Hyprland send a `wl_pointer.motion` with
the correct coordinates, without the cursor moving. In the repro that was `motion(649.12,
1210.16)`, twice.

`Logic.overviewMappedEvent(event)` (`logic.js:869-871`) is a pure predicate: true only for name
`openlayer` with data exactly `omascape`. `Overview.qml`'s `onRawEvent` (`Overview.qml:1895-1898`)
dispatches the existing `Logic.regrabFocusLua()` warp on that event while the overview is
`opened`. No new Lua chunk was added — `regrabFocusLua` was already in the `tests/lua-check.sh`
dump fixture with its own behaviour test, from the unrelated focus-stealing-on-close fix
([[learnings/overlay-layer-focus-must-be-ondemand]] is the sibling case for that surface's
keyboard focus, not this bug).

The branch is ungated on monitor position: on a monitor at (0,0) the warp is a harmless no-op
motion. A gate would have to read a `monitor.lastIpcObject` snapshot that can go stale silently
([[frameworks/hyprland/compositor-state]]).

## Accepted side effects

- **The cursor re-shows on every summon.** The warp re-shows a cursor `cursor:hide_on_key_press`
  (Omarchy's default) had hidden, because Hyprland's simulated move emits `input.mouse.move`,
  which clears `hiddenOnKeyboard` (`Renderer.cpp:154-163`). The cursor already reappeared on
  close — `onUnmap` simulates a move the same way — so this only moves an existing reappearance
  earlier.
- **One extra regrab is possible.** `warpTo` calls `rawMonitorFocus` on the monitor under the
  cursor (`PointerController.cpp:28`): if the cursor rests on a different monitor than the one the
  overview mapped on, monitor focus moves there and the resulting `focusedmonv2` triggers one more
  regrab. Not a loop — `FocusState.cpp:274` returns early on a focus change already in effect.
- **The warp re-primes pointer liveness rather than arming it.** The warp's own hover report would
  otherwise read as motion, arming `pointerLive` on what is really the resting position and handing
  a keyboard-summoned Ctrl+W to whatever tile the cursor happens to rest over. `Overview.qml`'s
  `onRawEvent` resets `pointerPrimed` and restarts `pointerPrime` immediately before dispatching
  the warp (`Overview.qml:1896`), so the corrected report that follows is read as a position, not a
  move — the same priming rule `notePointerMove` already applies to a summon's first hover
  (`Overview.qml:549-558`).

## Why the catchers are exempt

The per-monitor catcher surfaces (`omascape-catcher`) are keyboard-`None`
([[learnings/overlay-layer-focus-must-be-ondemand]]), so `LayerSurface.cpp`'s `GRABSFOCUS` path
never runs for them and they never hit this bug. `Logic.overviewMappedEvent` matches
`data === "omascape"` exactly, which excludes them along with every other namespace and any
malformed event.

## Removal condition

Hyprland `main` removed both `LOCAL` computations in `d29916a` (hyprwm/Hyprland#15899,
2026-08-21, "decouple pointer focus from layer-surface keyboard_interactivity"), replacing them
with `simulateMouseMovement()`. No release contains that commit as of v0.56.2. Once Omarchy ships
a Hyprland containing it, drop the `overviewMappedEvent` branch in `Overview.qml`'s `onRawEvent`
and the predicate in `logic.js` — the re-prime it carries goes with it.

## See also

- [[learnings/overlay-layer-focus-must-be-ondemand]] — the other layer-shell/keyboard-focus trap
  on this same overlay, and why the catchers are `None`.
- [[frameworks/hyprland/compositor-state]] — why the fix is ungated rather than reading a
  monitor snapshot.
- Design: `docs/specs/2026-09-27-pointer-reseat-design.md`.
