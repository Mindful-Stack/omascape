# Omyview — workspace lock for screen sharing (design)

Date: 2026-09-12 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1 ·
builds on find (merged) and the scratchpad row (PR #13, branch `scratchpad`).
Status: **approved design, pre-implementation** (revised after a codex review, 2026-09-12).
Branch `lock` (off `scratchpad`; rebase onto `main` once #13 merges).

## Goal

Workspaces the user has armed show nothing to anyone capturing the screen — screen shares,
recordings, screenshots — from the moment they are armed, and the overview makes the state
visible and easy to change.

## Scope

**In:** per-workspace arming (including the scratchpad row), compositor-real exclusion via named
`no_screen_share` window rules matched on the workspace, exclusion of the overview's own layer,
a compositor-side share observer (presentation only), persistence of the armed set, full-set
reconciliation on every sync, re-install on Hyprland config reload, overview visuals (badge,
placeholder), tests.

**Out:** per-window locks, blocking navigation to armed workspaces, an indicator outside the
overview, locking by app class, protecting windows the user moves *off* an armed workspace,
the unnamed `special` workspace (share-picker popups; never a box, cannot be armed), and any
guarantee about the first frame after a *Hyprland config reload* (see Edge cases).

## Verified facts (2026-09-12, Hyprland 0.56.2 on this machine)

- `hl.window_rule({ match = { workspace = "<id>" }, no_screen_share = true })` is accepted;
  unknown fields and unknown match keys are rejected. A capture (`grim`, the screencopy path
  shares use) of a workspace under an already-active rule shows **solid black** where the
  windows are; layers (the bar) still render. The rule applied to windows already on the
  workspace at creation time.
- Rules can be created `enabled = false` and toggled with `rule:set_enabled(bool)`; the spec
  field `name` exists on `HL.WindowRuleSpec`.
- Lua globals persist between dispatched chunks (one interpreter). `io.open`, `os.getenv`,
  `os.execute("mkdir -p …")` and (to verify in the plan's first task) `os.rename` work from a
  dispatched chunk.
- `hl.on("screenshare.state", cb)` fires with `(active: boolean, type: number, name: string)`
  (upstream documents Active, Type, Name; the second argument is not a session id). A screenshot
  fires `true` then `false`. Subscriptions have `:remove()` and `:is_active()`. The event is
  Lua-only; Quickshell cannot observe shares directly.
- `hl.layer_rule({ match = { namespace = "omyview" }, no_screen_share = true })` is the layer form.
- Hyprland's IPC socket emits `configreloaded` (Quickshell surfaces it via `Hyprland.rawEvent`).
  A config reload re-runs the Lua config and discards the dispatched-chunk globals (upstream:
  Lua state is torn down on reload) — to confirm in the plan's first task by probing a global
  across `hyprctl reload`.
- omyview's config is `~/.config/omarchy/omyview.json`, read through a watched `FileView`.

## Decisions

- **Armed = excluded, always.** Ctrl+L arms/disarms the selected box. An armed workspace's
  rule is enabled from that moment until disarmed, share or not. Chosen over "enable only during
  a share" because an event-driven enable races the first captured frame (codex review, 2026-09-12),
  and a screenshot's first frame is the whole disclosure. Cost: the user's own screenshots of an
  armed workspace are black too; disarm first. No force switch (arming is already immediate).
- **Share detection is presentation only.** The compositor observer only tells the overview
  whether a share is active so it can show the placeholder; a race there is harmless.
- **No navigation blocking.**
- **Persisted** in `~/.config/omarchy/omyview-locks.json` (`{ "armed": ["3", "special:scratchpad"] }`),
  written atomically by omyview (temp file + rename), re-applied at shell start, on
  `configreloaded`, and on every open.
- **One sync chunk reconciles the whole set.** `lockSyncLua(armed)` creates or enables one
  named rule per armed selector and disables every other rule the table knows. There is no
  separate arm/disarm; every change re-sends the full set. Idempotent by construction.
- **Named rules, one retained handle per selector.** `name = "omyview-lock-" .. sel`; a disarmed
  rule is disabled and its handle kept, so re-arming re-enables it. No accumulation.
- **Install at shell start, not first at open.** The install + sync run when the kept-loaded
  component is created, again on `configreloaded`, and again in `open()` (belt and braces).
  The overview's layer rule therefore exists before the overview can be mapped, except in the
  reload window (Edge cases).
- **Placeholder, not blur.** While a share is active, an armed box renders no tiles and no
  capture, and a lock glyph fills the well. Otherwise an armed box renders normally with a small
  lock badge beside its number.
- **Two files, one owner each.** omyview owns the locks file. The compositor observer owns
  `$XDG_RUNTIME_DIR/omyview/share-state`, written atomically; content `1`/`0`.
- **Intent vs enforcement.** The badge shows the *armed* intent from the file. Enforcement
  failures (rule creation or enabling throwing) are reported through the existing chunk report
  path (compositor log + notification); the overview does not claim "protected" beyond the
  badge. Accepted: there is no confirmed-enforcement channel back to the shell.

## Behaviour

| Key / action (overview)   | effect                                                                        |
|---------------------------|-------------------------------------------------------------------------------|
| Ctrl+L                    | toggle armed on the selected box; write the locks file; dispatch `lockSyncLua` |
| Enter / digits / click    | unchanged                                                                     |
| drag / drop               | unchanged for the compositor; a window dropped on an armed box is matched by the rule on arrival. In the overview, a drop onto a box that is currently showing the placeholder creates **no optimistic tile** (dispatch only) |
| find                      | never matches windows in a box showing the placeholder; armed boxes outside a share match normally |

Outside the overview: an armed workspace is black in every capture from the moment the sync
chunk runs. Moving a window *off* an armed workspace exposes it; that is by design (the rule is
per workspace, and the user chose to move it).

## Compositor side

All single-line guarded chunks in the existing style (`dispatchGuardLua`, `reportLua`), built in
`logic.js`, parse- and behaviour-tested by `tests/lua-check.sh`.

**`lockInstallLua()`** — idempotent:
```lua
local L = _G.omyview_lock
if not L then
  L = { rules = {}, sharing = 0, sub = nil, layer = nil, dir = nil }
  _G.omyview_lock = L
end
if not L.dir then
  local base = os.getenv("XDG_RUNTIME_DIR"); if not base then error("XDG_RUNTIME_DIR unset") end
  L.dir = base .. "/omyview"
  if os.execute("mkdir -p '" .. L.dir .. "'") ~= true and os.execute("mkdir -p '" .. L.dir .. "'") ~= 0 then error("mkdir failed") end
end
function L.publish()
  local tmp, dst = L.dir .. "/share-state.tmp", L.dir .. "/share-state"
  local f = io.open(tmp, "w"); if not f then error("cannot write share-state") end
  f:write(L.sharing > 0 and "1" or "0"); f:close()
  local ok, err = os.rename(tmp, dst); if not ok then error("rename share-state: " .. tostring(err)) end
end
if not L.layer then L.layer = hl.layer_rule({ name = "omyview-lock-layer", match = { namespace = "omyview" }, no_screen_share = true }) end
if not (L.sub and L.sub:is_active()) then
  L.sub = hl.on("screenshare.state", function(active)
    local ok, err = pcall(function()
      L.sharing = math.max(0, L.sharing + (active and 1 or -1)); L.publish()
    end)
    if not ok then print("omyview: share observer failed: " .. tostring(err)) end
  end)
end
L.publish()
```
- `sharing` counts starts minus ends, clamped at 0. It only drives the placeholder; a stuck
  count shows the placeholder longer than needed, never exposes anything. It resets on install.
- `publish()` writes `1`/`0` atomically; install publishes the current state so a fresh shell
  never reads a missing file for long.

**`lockSyncLua(armed)`** — `armed` is the full array of selectors (`"3"`, `"special:scratchpad"`):
```lua
local L = _G.omyview_lock; if not L then error("lock not installed") end
local want = {}; for _, sel in ipairs(ARMED) do want[sel] = true end
local ok, err = pcall(function()
  for sel in pairs(want) do
    local r = L.rules[sel]
    if not r then
      r = hl.window_rule({ name = "omyview-lock-" .. sel, match = { workspace = sel }, no_screen_share = true, enabled = true })
      L.rules[sel] = r
    else
      r:set_enabled(true)
    end
  end
  for sel, r in pairs(L.rules) do if not want[sel] then r:set_enabled(false) end end
end)
-- reportLua('lock sync')
```
where `ARMED` is the array literal interpolated by the builder (selectors are validated to
`^[0-9]+$` or `^special:[%w_-]+$` before interpolation; anything else is dropped and reported).

**Rule semantics to prove in the plan's first task, on 0.56.2, with captured pixels** (not
`is_enabled()`): create enabled → capture an existing window is black; `set_enabled(false)` →
capture shows it; `set_enabled(true)` → black again; a window *moved onto* the workspace while
the rule is enabled → black; a window moved off → visible; a floating window on the workspace →
black; a fullscreen window → black. Upstream notes that dynamic toggling wants named rules; the
rules are named for that reason.

## Overview side

**State.** `OmyviewLocks.qml` (new, beside `OmyviewConfig.qml`): a watched `FileView` on the
locks file; `armed: var` (array of selectors; the last valid set is kept when the file is
missing or malformed, and a malformed file is reported once via the notification path);
`toggle(sel)` writes the file atomically. A second watched `FileView` on the share-state file
exposes `sharing: bool` (`"1"`), false when missing or unreadable. `placeholder(sel) =
armed.includes(sel) && sharing`.

**Selectors.** `Logic.wsSelector(id)` already yields `"3"` / `"special:scratchpad"`; boxes are
keyed by it for lock purposes. The file stores selectors, so the scratchpad entry survives its
dynamic id.

**Sync points.** `Overview` dispatches `lockInstallLua()` then `lockSyncLua(armed)`:
1. on `Component.onCompleted` (kept loaded: shell start);
2. on `Hyprland.rawEvent` named `configreloaded`;
3. in `open()`;
4. after every `toggle(sel)`.
All idempotent. (The shell's `Hyprland` object emits the raw event name; the plan verifies the
exact string with a live `hyprctl reload`.)

**Keys.** Chord branch: `Ctrl+L` → `locks.toggle(Logic.wsSelector(selectedId))` when
`Logic.hasWs(selectedId)`, then sync. Works with or without a query.

**Rendering.** `buildInput()` marks each workspace record `armed: bool` and `placeholder: bool`
(armed and sharing). `layout()` copies both onto the box and **emits no tiles** for windows on a
placeholder workspace, so no capture starts. `buildInput()` also leaves those windows out of
`windows`, so find and drag never see them. Box delegate: placeholder → a large lock glyph
(nf-md-lock `\u{F033E}`) at 25 % opacity in the well, numeral hidden. Badge: armed → the lock
glyph after the number. Boxes remain selectable, jump targets and drop targets.

**Drops and pending state.** `submitDrop` onto a placeholder box dispatches the move but records
no `pendingMoves` entry and sets no optimistic row (the row would keep a live capture on a box
that must show none). When a box *becomes* a placeholder (share starts, or the user arms it
during a share), `rebuild()` first clears `pendingMoves` entries targeting it, so `applyTiles`
drops those rows at once (same mechanism as `hideScratchpad()`). A drag in flight whose window
is on a box that becomes a placeholder is cancelled by the existing "dragged window no longer in
the input → `endDrag()`" check.

**Hint row.** Adds `ctrl+l · lock`.

## Edge cases

- **Share starts while the overview is open**: the state file flips → `FileView` fires →
  `rebuild()` → armed boxes drop tiles and captures, glyph appears. Ending reverses it.
- **Arming during a share**: rule enabled immediately; viewers see black; the box switches to
  the placeholder on the same rebuild.
- **Hyprland config reload**: Lua globals are lost, so the rules and the observer are gone until
  omyview sees `configreloaded` and re-installs (milliseconds). A capture in that window can
  see armed windows. Accepted and documented; a reload is a user action (theme change, config
  edit), not something a share triggers. If the plan's probe shows globals *survive* a reload,
  this window does not exist and the `configreloaded` sync is merely redundant.
- **Hyprland restart**: ends every share and every capture client; the shell's next
  `configreloaded`/open re-installs.
- **Shell restart / crash**: the compositor table and rules are untouched (install is
  idempotent), so protection never lapses. Stale intent (a disarm written to the file but the
  shell died before syncing) is corrected by the full-set sync on the next start.
- **Compositor crash leaving `share-state` = `1`**: the next install publishes `0` (counter
  resets). Until then the overview shows placeholders for armed boxes — a false positive, never
  a leak.
- **Locks file missing/malformed**: keep the last valid set (empty on first run); report once;
  the next toggle writes a fresh file.
- **A selector whose workspace does not exist**: kept in the file and in the rule table; the
  rule matches nothing until the workspace returns; the badge shows only when its box exists.
- **Pinned windows**: reported on the workspace they were pinned from; whether a pinned window
  shown over an armed workspace is black is a live-test item, not a claim.
- **Two monitors**: rules are per workspace, so the monitor does not matter. The overview's own
  layer is excluded on every monitor by the layer rule.

## Tests

- **Tier 1, Lua behaviour suite** — each case runs the chunks in a **fresh Lua environment**
  (`_G` isolated per case; the current runner shares the host `_G` and must be changed), with
  stubs for `os.getenv`, `os.execute`, `os.rename`, `io.open` (in-memory files) and a mock `hl`
  gaining `layer_rule`, named rule objects with `set_enabled`/`is_enabled`, and `on` with a
  `fire(event, ...)` helper. Cases: install twice → one layer rule, one active subscription, one
  publish of `0`; sync `["3"]` → rule `omyview-lock-3` created enabled; sync `[]` → disabled,
  handle kept; sync `["3"]` again → same handle re-enabled (no second rule); sync
  `["3","special:scratchpad"]` → both enabled; share start → `1` published, rules untouched
  (already enabled); second start then one end → still `1`; last end → `0`; end without start
  → clamped at `0`; a rule setter throwing → reported once, remaining rules still processed
  (the loop continues after pcall per rule — the builder wraps each `set_enabled` individually);
  invalid selector dropped and reported; `os.rename` failing → reported.
- **Tier 1, `tests/tst_layout.qml`**: a `placeholder` workspace yields a box with
  `placeholder: true` and no tiles; an `armed` one without placeholder is unchanged.
- **Offscreen UI (`tests/ui/lock.qml`)**, with prepare.py pointing both `FileView`s at
  fixture-local temp files: Ctrl+L on ws 3 writes `armed: ["3"]` and dispatches install + sync
  with `"3"`; Ctrl+L again writes `[]` and dispatches a sync without it; the badge follows;
  writing `1` to the state file locks armed boxes (tiles gone, glyph shown, capture handle
  null) and `0` restores tiles; **positive control**: a query matching a window on ws 3 shows 1
  match before, 0 while placeholder, 1 after; a selected match whose box becomes a placeholder
  falls to the successor rule; Ctrl+L on the scratchpad row writes `special:scratchpad`; a drop
  onto a placeholder box dispatches the move and leaves no pending row; a pending drop onto ws 3
  followed by the state file flipping to `1` leaves no row; reopen re-reads the file and
  re-dispatches install + sync; a malformed file keeps the previous set; a `configreloaded` raw
  event re-dispatches install + sync.
- **Live (plan's first task, before any UI work)**: the rule-semantics sequence above with
  `grim` captures inspected as pixels (an unarmed workspace as positive control), the
  `configreloaded` event name, and whether globals survive `hyprctl reload`. **Live (final)**: a
  real monitor share through the portal (e.g. a video-call test page or `wf-recorder`), armed
  workspaces black in the recorded output including the first frame after switching to them,
  the overview absent from the recording, and the state file flipping on start and end.
