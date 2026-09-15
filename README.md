# Omyview

A workspace overview overlay for [Omarchy](https://omarchy.org)'s Quickshell shell.
Press **SUPER+P** to get a visual, spatial overview of every workspace — grouped by
monitor, with a **live thumbnail** of each window in its real position — then jump to a
workspace, or **drag a window onto another workspace** to move it there.

Built to replace the dead `walker`-based `workspace-picker.sh` after Omarchy Quattro
removed `walker`.

## Features

- **Live window previews.** Each window is a real, live thumbnail of its contents (via
  Quickshell's `ScreencopyView`), drawn at its true relative position and size, with the app
  icon as fallback. Captures only run while the overview is open.
- **Drag-and-drop between workspaces.** Grab a window and drop it on another workspace box to
  move it there — a *silent* move that doesn't switch you to that workspace. The overview
  stays open so you can keep organizing.
- **Fullscreen-aware.** A workspace with a fullscreen window still shows every window in its real
  tiled slot; the fullscreen one carries a small corner badge. Click the badge to un-fullscreen it
  without leaving the overview. Floating windows always show on top of tiled ones.
- **Per-monitor groups.** Workspaces are grouped per monitor, derived live from Hyprland's
  workspace→monitor mapping, and stacked by workspace number (the group holding `1` first,
  then the one holding `6`, and so on) — the layout never reshuffles depending on which screen
  you open it from. Each group
  carries a chip with a laptop or external-screen icon and the connector name; the focused
  monitor's group sits on a faint accent backdrop. Undocked collapses to a single flush group.
- **Always 1–0.** Workspaces `1`..`10` are always shown, even ones Hyprland has not created yet,
  so every number key has a visible target (`workspaces` in the config, `0` to turn it off).
- **Fast selection.** Number keys jump (`1`–`9`, `0` = 10), arrow keys move the highlight +
  `Enter`, click a window to focus it, middle-click to close it. `Esc` or a click outside closes.
- **Type to find:** any letter starts a fuzzy filter over window class and title; matches ring
  in the accent colour, the best one is selected. The arrows move between matching workspaces
  the way they normally move between workspaces, `Tab`/`Shift+Tab` cycle matches by rank,
  `Enter` focuses the selected window, `Esc` clears the query (a second `Esc` closes).
  Digits jump while the query is empty and type once it is not. Ctrl+letter chords are reserved.
- **Scratchpad:** `Ctrl+S` shows Omarchy's scratchpad as its own row below the workspaces
  (hidden on every open). `Enter` or a click on it brings the scratchpad up; drop a window on it
  to send it there silently; find covers its windows while the row is shown.
- **Theme-aware.** Pulls the active Omarchy theme's colors and fonts, so it matches the bar
  and re-themes automatically.
- **Zero idle cost.** The component stays loaded with the shell so open and close can animate,
  but nothing runs until you summon it: captures start when the surface is mapped and stop when
  it hides (only the config-file watcher and one `hyprctl` probe at startup run before that).

---

## Install

### Requirements

- Omarchy **Quattro (4.x)** or newer, with the Quickshell shell (`omarchy-shell` on your
  `PATH` — it ships with Omarchy). Quickshell must provide `Quickshell.Wayland`
  `ScreencopyView` + `ToplevelManager` (0.3.x does).
- A **recent Hyprland** (developed against 0.56.2). Omyview uses Hyprland's typed `hl.dsp.*`
  dispatchers for focus/move/close and requires **Lua configuration mode** (`hyprland.lua`),
  as used by Omarchy Quattro. A legacy `.conf` session rejects those dispatchers.
- The **dwindle** layout for drag-to-rearrange. On any other layout a tiled drop still moves
  the window to the target workspace, but it is not re-tiled at the drop point (the
  cursor-based insert is a dwindle behaviour). Floating drops work on every layout.

### 1. Add the plugin

```bash
omarchy plugin add https://github.com/Mindful-Stack/omyview.git --enable
```

This clones the plugin into `~/.config/omarchy/plugins/se.mindfulstack.omyview/` (the folder
is named after the manifest `id`, not the repo) and enables it. New plugins default to
disabled, so the `--enable` flag matters — without it, run `omarchy plugin enable
se.mindfulstack.omyview` afterwards.

Verify it's installed and enabled:

```bash
omarchy plugin list | grep omyview
# se.mindfulstack.omyview   enabled   third-party   overlay   Omyview
```

### 2. Bind a key to toggle it

Omyview only appears when you toggle it, so bind a key. **SUPER+P** is the intended bind.

If your Omarchy uses the Lua binding config (`~/.config/hypr/bindings.lua`):

```lua
o.bind("SUPER + P", "Workspace overview", "omarchy-shell shell toggle se.mindfulstack.omyview")
```

If you use plain Hyprland config (`~/.config/hypr/bindings.conf` or `hyprland.conf`):

```ini
bind = SUPER, P, exec, omarchy-shell shell toggle se.mindfulstack.omyview
```

Then reload Hyprland so the bind takes effect:

```bash
hyprctl reload
```

### 3. Use it

Press **SUPER+P**. The overlay opens on your focused monitor.

| Key / action             | Effect                                                    |
| ------------------------ | --------------------------------------------------------- |
| **SUPER+P**              | Toggle the overlay (open and close)                       |
| **1–9, 0**               | Jump to that workspace (`0` = 10)                         |
| **← → ↑ ↓**              | Move the highlight                                        |
| **Enter**                | Jump to the highlighted workspace                         |
| **Drag a window**        | Drop it on another workspace box to move it there (silent)|
| **Click a window**       | Focus that window and close the overview                  |
| **Middle-click a window**| Close that window                                         |
| **Click an empty box**   | Jump to that workspace                                    |
| **Click the ⛶ badge**    | Turn fullscreen off for that window (overview stays open) |
| **Type a letter**        | Start a fuzzy find over window class and title             |
| **Tab / Shift+Tab** (query active) | Cycle matches by rank                             |
| **↑ ↓ ← →** (query active)         | Move spatially among workspaces that hold a match |
| **Enter** (query active) | Focus the selected match and close                        |
| **Esc** (query active)   | Clear the query                                            |
| **Ctrl+S**                          | Show / hide the scratchpad row                        |
| **Enter / click the empty row** (scratchpad) | Bring the scratchpad up and close           |
| **click a tile in the row** (scratchpad) | Focus that window, raised above its siblings   |
| **Esc / click-out**      | Close                                                     |

Digits jump to a workspace only while the query is empty; once you've typed a letter, digits
are query characters too. Ctrl+letter chords are reserved for future actions.

### Updating

```bash
omarchy plugin update se.mindfulstack.omyview
```

### Uninstalling

```bash
omarchy plugin remove se.mindfulstack.omyview
```

…then delete the SUPER+P bind you added and `hyprctl reload`.

### Troubleshooting

- **Nothing happens on SUPER+P.** Check the plugin is `enabled` (`omarchy plugin list |
  grep omyview`) and that your bind targets the exact id `se.mindfulstack.omyview`. Re-run
  `hyprctl reload` after editing the bind.
- **`summon: plugin not enabled` in the shell log.** Run `omarchy plugin enable
  se.mindfulstack.omyview`.
- **It opens on the wrong monitor.** Focused-monitor targeting is verified on a single
  display; multi-monitor is still being validated — see `ROADMAP.md`.

---

## Configuration

Optional user settings live in `~/.config/omarchy/omyview.json` (watched; edits apply live):

```json
{
  "scrim": true,
  "hint": true,
  "workspaces": 10,
  "motion": "auto"
}
```

- `scrim` — dim the desktop behind the picker while it is open (default `true`).
- `hint` — show the key hints under the workspace grid (default `true`).
- `workspaces` — always show workspaces `1`..`N` (default `10`, matching the 1–0 keys), even
  ones Hyprland has not created yet, e.g. a `persistent:true` workspace whose monitor is
  unplugged. A missing workspace is drawn as an empty well next to its numeric neighbours (on the
  monitor of the nearest lower existing workspace), so the layout never depends on which screen
  has focus; Hyprland decides the real monitor when you jump or drop there, and the picker then
  follows. `0` shows only what Hyprland reports.
- `motion` — `"auto"` (default) animates only when Hyprland's `animations:enabled` is on;
  `"full"` always animates; `"off"` never does (every duration is 0).

### Blurred scrim (optional, Hyprland side)

Hyprland can frost the desktop behind the picker instead of only dimming it. This is a
compositor setting, so it lives in your Hyprland config rather than in the plugin, and it needs
blur enabled globally (a GPU cost while the picker is open). Lua config
(`~/.config/hypr/*.lua` on Omarchy Quattro):

```lua
hl.config({ decoration = { blur = { enabled = true } } })
hl.layer_rule({ match = { namespace = "omyview" }, blur = true, ignore_alpha = 0.3 })
```

Classic config:

```ini
decoration:blur:enabled = true
layerrule = blur, omyview
layerrule = ignorealpha 0.3, omyview
```

Colours follow the active Omarchy theme (`menu` surface roles and the shared fill alphas), so
the picker re-themes with everything else. Layout constants live in the `params` object near
the top of `Overview.qml` (cell size caps, `cellInset`, `cellSpacing`, `rowSpacing`, the
`minTileW`/`minTileH` clamps). After editing QML, run `omarchy restart shell` (see the note in
Contributing about why a plain rescan isn't enough).

### Let the picker animate itself (Hyprland side)

Omyview animates its own open and close (a short fade and scale). Hyprland also animates
layer surfaces by default, so without a rule the two stack: a compositor fade on top of the
picker's own. Omarchy gives its shell overlays a `no_anim` rule; give `omyview` the same.
Lua config (`~/.config/hypr/looknfeel.lua` or any file loaded by `hyprland.lua`):

```lua
hl.layer_rule({ match = { namespace = "omyview" }, no_anim = true, animation = "none" })
```

Classic config:

```ini
layerrule = noanim, omyview
```

With `"motion": "off"` (or `"auto"` while Hyprland's `animations:enabled` is off) the picker
does not animate at all, and you may prefer to leave the compositor's layer animation on.

---

## Contributing

Contributions are welcome — bug reports, fixes, and the roadmap items in `ROADMAP.md`.

### Project layout

| File          | What it is                                                        |
| ------------- | ----------------------------------------------------------------- |
| `manifest.json` | Omarchy plugin manifest (id, kind, entry point). Schema v1.     |
| `Overview.qml`  | The whole plugin — a single QML component (the overlay).        |
| `DESIGN.md`     | What it does and why (the v1 design).                           |
| `PLAN.md`       | How it was built, task by task, with the verified gotchas.      |
| `ROADMAP.md`    | What's next (docked verification, both-screens dimming, thumbs).|

If you're new to Quickshell/QML: it's Qt Quick (declarative UI, JavaScript for logic). You
don't need to know it deeply — `Overview.qml` is self-contained and commented, and the shell
APIs it uses (`Hyprland.*`, `Quickshell.*`, `Color.menu.*`) are documented inline in
`DESIGN.md`.

### Local development loop

1. **Work against a live checkout.** The version Omarchy runs lives at
   `~/.config/omarchy/plugins/se.mindfulstack.omyview/` (a clone of this repo). Either edit
   there directly, or clone this repo elsewhere for development:

   ```bash
   git clone git@github.com:Mindful-Stack/omyview.git
   cd omyview
   ```

2. **Edit `Overview.qml`.**

3. **Reload the shell to see the change:**

   ```bash
   omarchy restart shell
   ```

   > ⚠️ **Editing QML requires `omarchy restart shell`, not just a rescan.**
   > `omarchy-shell shell rescanPlugins` reloads the manifest/registry but **not** the live
   > QML component, so your code change won't show until a full shell restart.

4. **Validate the manifest** before you commit (the shell enforces the same checks and will
   silently refuse a bad manifest):

   ```bash
   omarchy plugin validate .
   ```

### Testing

There's no unit-test harness — this is a visual overlay, so "testing" means reloading the
shell and checking behavior. Before opening a PR, confirm:

- [ ] `omarchy plugin validate .` passes.
- [ ] SUPER+P opens and closes the overlay; `Esc` and click-outside close it.
- [ ] Number keys `1`–`0` jump to the right workspace; arrows + `Enter` work; click works.
- [ ] The window mini-map roughly matches your real window layout.
- [ ] It re-themes correctly after `omarchy theme next` (or any theme switch).
- [ ] If you have a second monitor: the two-row layout and per-monitor mini-map coordinates
      are correct (this path is still being validated — call it out in the PR).

### Submitting changes

1. Branch off `main`: `git checkout -b your-change`.
2. Keep commits focused; write a clear message explaining the *why*.
3. If you change behavior, update `DESIGN.md`/`ROADMAP.md` to match.
4. Open a PR against `Mindful-Stack/omyview`. Describe what you tested from the checklist
   above (a screenshot or short screen recording helps a lot for UI changes).

Maintainers: **@DanielThyselius**, **@dotnetemmanuel**.

---

## License

MIT — see [LICENSE](LICENSE).

### Drag regression checks

`mise run test` runs pure layout tests and offscreen Qt mouse-event tests. The latter use
production drag handlers, models, bindings and timers with only shell/compositor adapters
replaced (`tests/ui/prepare.py`); they need Python 3 as well as Qt6 test tooling.

`mise run test-integration` launches an isolated **Lua-configured** Hyprland and real Quickshell.
It checks repeated floating placement on an offset monitor, floating workspace transfer,
tiled workspace transfer without changing the active workspace, and tiled drops that re-tile
left of / above the hovered window and onto a hidden workspace. Requires Hyprland,
Quickshell, foot and jq, plus a running Wayland session for the nested output.

Floating drops keep the full window within the target monitor's usable bounds. Dropping
outside a workspace cancels. A **tiled** drop behaves like Hyprland's own drag-and-drop:
the window is re-tiled as a split of the tile you drop it on, on the side you drop it
(the hovered half is previewed while dragging). With two windows that is a swap; with more
it re-organises the layout. This works across workspaces, including hidden ones, without
changing the active workspace, and an empty destination just fills. Grouped windows are not
re-tiled; fullscreen windows are treated as tiled (the workspace's fullscreen state is restored
after a drop, and a fullscreen window dragged to another workspace arrives tiled). Edge scrolling
helps reach workspaces below the viewport. `mise run test-integration` also runs
`tests/integration/fullscreen.sh` (badge, fullscreen anchors, in-place re-tile).

While in transit the dragged tile is a ghost: it shrinks to 60% around the point you grabbed
and turns translucent, so the drop highlight stays visible. The **pointer** decides where a
tiled window goes (as the cursor does in a native drag); a floating window lands so the grabbed
point ends up under the pointer.
