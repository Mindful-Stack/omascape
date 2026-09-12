# Omyview — workspace lock for screen sharing (design)

Date: 2026-09-12 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1 ·
builds on find (merged) and the scratchpad row (PR #13, branch `scratchpad`).
Status: **approved design, pre-implementation.** Branch `lock` (off `scratchpad`; rebase onto
`main` once #13 merges).

## Goal

During a screen share, workspaces the user has marked as sensitive show nothing to viewers, and
the overview makes the state visible and easy to change. Marking is done ahead of time
("armed"); the lock takes effect by itself when a share starts, or on demand.

## Scope

**In:** per-workspace arming (including the scratchpad row), a force switch, compositor-real
exclusion via `no_screen_share` window rules matched on the workspace, exclusion of the overview's
own layer from shares, a compositor-side share handler installed by omyview, persistence of the
armed set, the overview visuals (badge, placeholder), tests.

**Out:** per-window locks, blocking navigation to locked workspaces (in the overview or in
Hyprland), a lock indicator outside the overview (bar), locking by app class, protecting against
a viewer seeing the *workspace switch* itself (Hyprland shows a black area; that is the point).

## Verified facts (2026-09-12, Hyprland 0.56.2 on this machine)

- `hl.window_rule({ match = { workspace = "<id>" }, no_screen_share = true })` is accepted;
  unknown fields and unknown match keys are rejected, so both are real. A capture (`grim`, the
  same screencopy path shares use) of a workspace under such a rule shows **solid black** where
  the windows are; layers (the bar) still render. It applied to windows already on the workspace.
- Rules can be created `enabled = false` and toggled with `rule:set_enabled(bool)`.
- Lua globals persist between dispatched chunks (one interpreter), and the `io` library works.
- `hl.on("screenshare.state", cb)` fires with `(active: boolean, id: number, monitor: string)`;
  a screenshot fires `true` then `false`. Subscriptions have `:remove()`. The event is Lua-only
  (not on the IPC socket), so Quickshell cannot observe shares directly.
- `hl.layer_rule({ match = { namespace = "omyview" }, no_screen_share = true })` is the layer form
  (`no_screen_share` is a typed `HL.LayerRuleSpec` field).
- omyview's config is `~/.config/omarchy/omyview.json`, read through a watched `FileView`.

## Decisions (brainstorm 2026-09-12)

- **Real exclusion, not overview-only.** Locked windows are black in every capture. The
  overview's own layer is excluded too, so viewers never see thumbnails.
- **Armed by default, force on demand.** Ctrl+L arms/disarms the selected box. Ctrl+Shift+L
  toggles force. A workspace is *locked* when it is armed and (a share is active or force is on).
- **No navigation blocking.** Switching to a locked workspace is safe for the viewer; the
  overview only shows the state.
- **Persisted.** The armed set and the force flag live in `~/.config/omarchy/omyview-locks.json`
  (beside the existing config), written by omyview and re-applied on shell start.
- **Placeholder, not blur.** A locked box renders no tiles and no capture; a lock glyph sits in
  the well. An armed, unlocked box renders normally with a small lock badge beside its number.
- **Handler installed by omyview at runtime.** No Hyprland config changes. Idempotent, so a
  Hyprland restart is repaired on the next shell start or overview open.
- **Two files, one owner each.** omyview owns the locks file. The compositor handler owns the
  share-state file `$XDG_RUNTIME_DIR/omyview/share-state` (`1` or `0`). Neither side writes the
  other's file.
- **Granularity is the workspace.** The scratchpad is a workspace here and is armed like any
  other box; its rule matches by name (`special:scratchpad`), so its dynamic id is irrelevant.

## Behaviour

| Key / action (overview)   | effect                                                                          |
|---------------------------|---------------------------------------------------------------------------------|
| Ctrl+L                    | toggle armed on the selected box; write the locks file; dispatch arm / disarm    |
| Ctrl+Shift+L              | toggle force; write the locks file; dispatch force(on/off)                       |
| Enter / digits / click    | unchanged (no blocking)                                                          |
| drag / drop               | unchanged; a window dropped on a locked box is covered by the rule on arrival    |
| find                      | never matches windows in a locked box; armed-unlocked boxes match normally       |

Outside the overview: when a share starts, every armed workspace goes black for viewers within
the same compositor tick; when the last share ends (and force is off) they return.

## Compositor side — `Logic.lockInstallLua()`, `lockArmLua(sel)`, `lockDisarmLua(sel)`, `lockForceLua(on)`

All single-line guarded chunks in the existing style (`dispatchGuardLua`, `reportLua`), built
in `logic.js` and parse/behaviour-tested by `tests/lua-check.sh`.

**Install** (idempotent; dispatched at shell start, and before any arm/disarm/force):
```lua
local L = _G.omyview_lock or { rules = {}, sharing = 0, force = false, sub = nil, layer = nil }
_G.omyview_lock = L
if not L.layer then L.layer = hl.layer_rule({ match = { namespace = "omyview" }, no_screen_share = true }) end
function L.apply()
  local on = L.sharing > 0 or L.force
  for _, r in pairs(L.rules) do r:set_enabled(on) end
  local dir = os.getenv("XDG_RUNTIME_DIR") .. "/omyview"
  os.execute("mkdir -p '" .. dir .. "'")            -- once; cheap
  local f = io.open(dir .. "/share-state", "w"); if f then f:write(on and "1" or "0"); f:close() end
end
if not L.sub then
  L.sub = hl.on("screenshare.state", function(active) L.sharing = math.max(0, L.sharing + (active and 1 or -1)); L.apply() end)
end
```
- `sharing` is a counter: two simultaneous shares (or a screenshot during a share) must not
  unlock early. A screenshot outside a share produces 1 then 0: rules flip on and off for a few
  milliseconds, which is harmless and correct.
- `share-state` reflects **effective** lock (`sharing > 0 or force`), which is what the overview
  needs to render; it is rewritten on every apply.
- Not verified yet: whether `os.execute` is available to the compositor's Lua. If it is not, the
  install chunk creates the directory with `io.open` on a marker file after omyview has created
  the directory itself at start (omyview owns the runtime dir creation in that case). The plan
  probes this first.

**Arm** (`sel` = `"3"` or `"special:scratchpad"`):
```lua
local L = _G.omyview_lock
if not L.rules[sel] then L.rules[sel] = hl.window_rule({ match = { workspace = sel }, no_screen_share = true, enabled = false }) end
L.apply()
```
**Disarm:** `local r = L.rules[sel]; if r then r:set_enabled(false); L.rules[sel] = nil end`.
**Force:** `L.force = on; L.apply()`.

Rules are never destroyed (the API has no remove); a disarmed rule is disabled and dropped from
the table. Re-arming the same selector after a disarm creates a second rule object; the first
stays disabled forever. Accepted: a handful of dead disabled rules per session.

## Overview side

**State.** `OmyviewLocks.qml` (new, beside `OmyviewConfig.qml`): a watched `FileView` on
`~/.config/omarchy/omyview-locks.json` with `{ "armed": ["3", "special:scratchpad"], "force": false }`;
properties `armed: var` (array of selectors), `force: bool`, functions `toggleArmed(sel)`,
`toggleForce()` that write the file atomically (write to a temp name, rename). A second watched
`FileView` on `$XDG_RUNTIME_DIR/omyview/share-state` exposes `sharing: bool` (missing file =
false). `locked(sel) = armed.includes(sel) && (sharing || force)`.

**Selectors.** `Logic.wsSelector(id)` already yields `"3"` / `"special:scratchpad"`; boxes are
keyed by it for lock purposes. The locks file stores selectors, not ids, so the scratchpad
entry survives Hyprland's dynamic id.

**Start-up.** A Hyprland restart cannot be detected from the shell, so `open()` always dispatches
`lockInstallLua()` followed by one `lockArmLua` per armed selector and `lockForceLua(force)`.
All idempotent; a few dispatches per open is cheap. (Shell start alone is not enough: Hyprland
may restart while the shell keeps running.)

**Keys.** Chord branch: `Ctrl+L` → `toggleArmed(wsSelector(selectedId))` when `hasWs(selectedId)`;
`Ctrl+Shift+L` (Shift is outside the chord mask, so test `e.modifiers & ShiftModifier`) →
`toggleForce()`. Each write is followed by the dispatches for that change.

**Rendering.** `buildInput()` marks each workspace record `locked: bool`; `layout()` passes it to
the box and **emits no tiles for windows on a locked workspace** (the capture never starts).
Box delegate: locked → the well draws a large lock glyph (nf-md-lock, `\u{F033E}`) at 25 %
opacity where the numeral goes, and `occupied` stays true so the numeral is hidden. Badge: armed
(locked or not) → a small lock glyph after the number (`3 🔒` rendered with the Nerd glyph).
Locked boxes remain selectable, drop targets, and jump targets.

**Find.** `buildInput()` leaves locked workspaces' windows out of `windows`, so `findMatches`
never sees them; toggling force or a share starting while a query is active re-ranks on the next
rebuild (the share-state file change triggers a rebuild).

**Hint row.** Adds `ctrl+l · lock`. (The row already widens the card; one more entry.)

## Edge cases

- A share starts while the overview is open: the state file flips, the `FileView` fires,
  `rebuild()` runs, locked boxes drop their tiles and captures stop. A share ending reverses it.
- Arming the currently focused workspace during a share: black for viewers immediately; the
  user's own screen is unchanged.
- The locks file is missing or malformed: `armed = []`, `force = false`, and the first toggle
  writes a fresh file.
- The runtime dir or state file is missing (fresh login, handler not yet installed): `sharing =
  false`; the first `open()` installs the handler, which writes `0`.
- Hyprland restart while the shell runs: the Lua state is gone; the next `open()` re-installs and
  re-arms; until then armed workspaces are not protected. Acceptable — a restart also ends any
  share.
- Shell restart: omyview re-reads its file and re-arms on the first open; the compositor table
  already exists and is untouched (install is idempotent), so protection never lapses.
- A workspace id in the armed set that does not exist right now: kept; the rule matches nothing
  until the workspace returns. Shown as armed only when its box exists.
- The unnamed `special` workspace (share popups) is never a box, so it cannot be armed.

## Tests

- **Tier 1, Lua behaviour suite** (mock gains `layer_rule`, `window_rule` objects with
  `set_enabled`/`is_enabled`, `on`/subscriptions with a `fire(event, ...)` helper, `os.getenv`,
  `io`): install twice → one layer rule, one subscription (idempotent); arm creates a disabled
  rule; share start enables every armed rule and writes `1`; a second share start then one end
  keeps rules enabled (counter); last end disables and writes `0`; force on with no share enables;
  disarm disables and forgets; arm after disarm works; dispatch/rule failure reported.
- **Tier 1, `tests/tst_layout.qml`**: a `locked` workspace yields a box with `locked: true` and
  no tiles; an unlocked one is unchanged.
- **Tier 1, `tests/tst_find.qml`**: none needed (windows are filtered before ranking).
- **Offscreen UI (`tests/ui/lock.qml`)**: the fixture points the locks `FileView` and the
  share-state `FileView` at temp files (prepare.py rewrites the two paths to fixture-local
  files): Ctrl+L on ws 3 writes `armed: ["3"]` and dispatches install + arm; Ctrl+L again
  disarms; Ctrl+Shift+L writes `force: true`, dispatches force, and the armed box loses its tiles
  and shows the glyph; writing `1` to the state file (simulating the handler) locks armed boxes
  and a rebuild follows; `0` unlocks; a locked box still jumps on Enter and is a drop target;
  find with a query matching a window on a locked box shows 0 matches; Ctrl+L on the scratchpad
  row writes `special:scratchpad`; reopen re-reads the file and re-dispatches install + arm.
- **Tier 2 / live**: start a real share (a browser tab-share or `wf-recorder`), confirm armed
  workspaces are black in the shared picture and the overview is absent from it; confirm the
  state file flips.
