# Omascape — re-seat the pointer when the overview maps (design)

Date: 2026-09-27 · Target: Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1.
Status: **designed, not built.** Found while hand-verifying the bar button
(`docs/specs/2026-09-24-bar-icon-design.md` on `feat/bar-icon`, "The dead second click").

## Problem

On a monitor that is not at layout position (0,0), a click made after the overview opens and
**before the pointer moves** is dropped. Open the overview by its bar button, click the same spot
again to close it, and nothing happens. Moving the mouse first, then clicking, works. The keybind
summon has the same dead first click; the bar button only makes it obvious, because the
natural second click comes without moving.

## Root cause (Hyprland 0.56.2, not Omascape)

`src/desktop/view/LayerSurface.cpp:203` (tag v0.56.2, commit efb5099), in `onMap`, for a layer that
grabs keyboard focus (the overview's surface is `OnDemand`):

```cpp
const auto LOCAL = g_pInputManager->getMouseCoordsInternal()
                 - Vector2D(m_geometry.x + PMONITOR->m_position.x, m_geometry.y + PMONITOR->m_position.y);
g_pSeatManager->setPointerFocus(m_wlSurface->resource(), LOCAL);
```

`m_geometry` is already global (`Renderer.cpp` `arrangeLayerArray` builds it from
`full_area = {monitor.position, monitor.size}`), so the monitor offset is subtracted twice. The
client receives `wl_pointer.enter` at a point far outside its surface. Qt then places a press
before any motion outside every item, and the press is dropped silently.

**Evidence.** A standalone Quickshell client under `WAYLAND_DEBUG`, with the cursor still at
(849, 2650) on eDP-1 at (200, 1440), mapped a full-screen `OnDemand` overlay. The client received
`enter(449.1, −229.8)`, where it expected (649, 1210). The error is exactly the monitor offset.
Two runs with the cursor verified still gave the same result. Instrumented Omascape agreed: the
bar lost the pointer on map, and the overview's scrim saw neither hover nor press until the first
motion.

**Upstream.** Hyprland `main` removed both `LOCAL` computations in d29916a
(hyprwm/Hyprland#15899, 2026-08-21, "decouple pointer focus from layer-surface
keyboard_interactivity"). They are replaced by `simulateMouseMovement()`. No release contains that
commit as of v0.56.2.

**Workaround, verified.** A same-position `hl.dsp.cursor.move` after the map makes Hyprland send a
`wl_pointer.motion` with correct coordinates while the cursor does not move. In the repro that
was `motion(649.12, 1210.16)`, twice.

## Design

- Hyprland posts `openlayer>>omascape` right after that `setPointerFocus` (`LayerSurface.cpp:218`).
  Overview's existing `onRawEvent` handler gains one branch: while `opened`, on that event,
  dispatch the existing `Logic.regrabFocusLua()`. That chunk is a same-position cursor warp, it is
  already in the `tests/lua-check.sh` dump fixture, and it already has a behaviour test. No new
  Lua is added.
- `Logic.overviewMappedEvent(event)` is a pure predicate. It is true only for name `openlayer` with
  data exactly `omascape`, which excludes the `omascape-catcher` surfaces (keyboard focus `None`,
  so they never hit the bug), other namespaces and malformed events.
- **Ungated.** On a monitor at (0,0) the warp is a harmless no-op motion (`logic.js`, the
  `regrabFocusLua` comment). A gate would read a `lastIpcObject` snapshot that can go stale
  silently (`lore/knowledge/frameworks/hyprland/compositor-state.md`).
- **Why not a compositor-side `layer.opened` hook.** It would be synchronous, but it would also be
  a second resident `hl.on` subscription, with a reinstall lifecycle, that outlives a plugin
  unload. The event route has an async hop of a few milliseconds, which no human click beats.
- **Why not a timer after `open()`.** It guesses when the surface has mapped. A warp before the map
  does nothing.
- **Removal.** Once Omarchy ships a Hyprland containing d29916a, drop the branch and the
  predicate. The learning records this.

## Testing

- **Tier 1 logic** (`tests/tst_actions.qml`, next to the `focusStealingEvent` test): the predicate's
  true and false cases.
- **Tier 1 UI** (`tests/ui/actions.qml`, the `closewindow` pattern): a fake `openlayer`/`omascape`
  while open sends exactly one `cursor.move`. The catcher's namespace sends none, and so does the
  same event while closed.
- **By hand, not CI** (ADR-0003): on the offset laptop panel, open with the bar button and click
  again without moving, and it closes. Also rerun the `WAYLAND_DEBUG` repro against the linked
  build and look for a correcting `motion` right after the `enter`.

## Docs

`lore/knowledge/learnings/hyprland-056-layer-enter-offset.md` records the bug, the evidence, the
workaround and the removal condition.
