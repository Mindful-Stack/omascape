# Omascape — motion (2026-09-10)

Branch `animations`, based on `main` (after #4, #5, #7). The last piece of the end-4 parity
work: one motion vocabulary applied to open/close, selection, hover, drag and reconcile.

## Principles

1. **One vocabulary.** A single `motion` block in `Overview.qml` owns every duration and easing.
   No literal `duration:` anywhere else. Tiles receive it as properties (they do not import the
   shell).
2. **Direct manipulation is never animated.** The dragged tile follows the pointer exactly; only
   its *lift* (scale/opacity) and its *release* animate. Edge-scroll offsets stay instant.
3. **Layout motion, not creation motion.** Items animate when they *move* or *change state*, not
   when they are created at open (the card entrance covers that). Rebuilds that change nothing
   must produce no motion.
4. **Respect the desktop.** Default `motion: "auto"` follows Hyprland `animations:enabled`;
   `"full"` / `"off"` override in `~/.config/omarchy/omascape.json`. `off` sets every duration to 0.
5. **Snappy.** A picker is a transient tool: fast 90 ms, normal 160 ms, enter 200 ms, exit
   120 ms. Movement uses `OutCubic`, hover `OutQuad`, entrance an emphasised decelerate
   (`OutBack` with a small overshoot, or `OutCubic` if that feels too playful).

## Motion inventory

| Moment | Today | Proposed |
|---|---|---|
| Open | card pops in | scrim fades in (normal); card fades in and scales 0.96 → 1 (enter) |
| Close / jump | card pops out | card fades out and scales to 0.98 (exit); scrim fades; window stays visible until done |
| Keyboard selection | frame glides x/y 160 ms | same, plus width/height (all cells share one size today; the Behaviors are there for per-monitor cell sizes later), via `motion.normal` |
| Selection during drag | frame dims to 40 % (120 ms) | via `motion.fast` |
| Tile hover | scale 1 → 1.03 (100 ms) | via `motion.fast`, `OutQuad` |
| Drag lift | scale 0.6 + opacity 0.6 (100 ms) | via `motion.fast` |
| Drag release | scale/opacity back (100 ms) | via `motion.fast`; then **settle**: tile x/y/w/h glide from the drop point to the compositor's real geometry (`motion.normal`) instead of jumping |
| Drop wash / insertion half | appear instantly | fade in/out (`motion.fast`) |
| Window opened while overview is open | tile appears at once | fade in + scale 0.9 → 1 (`motion.normal`) |
| Window closed while open | tile vanishes | no exit animation (model removal is instant; not worth the deferred-remove machinery) |
| Windows moved in the compositor while open | tiles jump on reconcile | tiles glide (`motion.normal`) — same Behavior as the settle |
| Card resize (workspaces added, columns change) | jump | card width/height glide (`motion.normal`); tiles glide with their boxes |
| Badge, numeral, chips, hints | static | static (no state animation; badge and numeral ride along with their box's layout glide) |

## Mechanics and gotchas

- **Exit animation needs the window alive.** `PanelWindow.visible` becomes
  `opened || card.opacity > 0` (the pattern Omarchy's PopupCard uses). `close()` flips `opened`;
  the window hides when the fade ends. Keyboard focus must be released at once, not at the end.
- **Hyprland also animates layers.** Omarchy gives its own overlays `no_anim = true` layer rules
  so the shell animates instead of the compositor. Document the same rule for `omascape`:
  `hl.layer_rule({ match = { namespace = "omascape" }, no_anim = true, animation = "none" })`.
  Without it, open/close double-animate (compositor fade + ours).
- **Tile glide vs drag.** The drag sets `x/y` directly through `drag.target`; a `Behavior on x`
  would fight it, and gating it on `!dragging` is not enough (disabling a Behavior does not stop
  a transition in flight, and the C++ drag write leaves the QML binding installed, so the glide
  re-asserts on its next tick). So the glide runs on separate `targetX`/`targetY` properties;
  `beginGrab` detaches `x/y` with a plain write and the drag owns them; release parks the
  targets at the drop point and rebinds them to the model — that rebind is the settle.
- **Boxes must be reconciled, not recreated.** Boxes and badges are `Repeater`s over the
  `root.boxes` array today, so every rebuild recreates them at their new position; a tile
  gliding into a box that has already jumped looks wrong. Boxes become an address-keyed
  `ListModel` reconciled in place (`applyBoxes`, keyed by workspace id), exactly like tiles.
- **Suppress motion on the first layout.** `Behavior`s only fire on *changes*, and delegates are
  created at their final position, so open produces no tile motion. Rebuilds that re-set identical
  values produce none either (`ListModel.set` with equal values still emits; compare before
  setting, which `applyTiles` can do cheaply).
- **Reduced motion detection.** `Quickshell.Io.Process` runs `hyprctl getoption animations:enabled -j`
  once per open (cheap, async); result cached in `config.motionEffective`. Fixture stubs it.
- **Tests (offscreen).** Durations are read from the `motion` block, so tests can set
  `view.motion.scale = 0` for instant assertions and `> 0` for a few timing checks: the frame
  glides (intermediate x between boxes after half the duration); the dragged tile's x is exact
  during a drag; after release the tile settles to the reconciled geometry; with `motion: off`
  every duration is 0.

## Out of scope

Per-window fullscreen/maximize badges (codex `window-states` branch), tile exit animation,
workspace-switch animation (Hyprland's own).

## Decisions (2026-09-10)

- **Entrance:** fade + scale from centre (0.96 → 1 in, → 0.98 out).
- **Motion policy:** `"auto"` follows Hyprland `animations:enabled`; `"full"` / `"off"` override.
- **Tile appear:** fade + scale 0.9 → 1 for windows opened while the picker is showing; no exit
  animation.
- **Timing:** snappy — fast 90 ms, normal 160 ms, enter 200 ms, exit 120 ms.

## Build order

1. `motion` block + config key + Hyprland query (fixture-stubbed); rewire the existing
   Behaviors (frame glide/dim, hover, lift/release) to it. Test: `off` zeroes every duration.
2. Open/close: scrim and card fade/scale, window stays visible through the exit, focus released
   at once. README gains the `no_anim` layer rule.
3. Boxes as a reconciled `ListModel` (pure refactor, no motion). Then reconcile motion: tile
   glide targets (`targetX`/`targetY`, see the mechanics bullet) plus w/h Behaviors; box, badge
   and card-size glides; settle after a drop. Tests: exact x during drag, glide after release,
   no motion on an identical rebuild.
4. Drop wash and insertion half fades; tile appear animation.
5. Live feel pass on light and dark themes; tune overshoot or drop it.
