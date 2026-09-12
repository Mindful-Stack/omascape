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
  `os.execute("mkdir -p …")` and `os.rename` all work from a dispatched chunk (probed
  2026-09-12), so the observer can create its directory and publish the state file atomically.
- `hl.on("screenshare.state", cb)` fires with `(active: boolean, type: number, name: string)`
  (upstream documents Active, Type, Name; the second argument is not a session id). A screenshot
  fires `true` then `false`. Subscriptions have `:remove()` and `:is_active()`. The event is
  Lua-only; Quickshell cannot observe shares directly.
- `hl.layer_rule({ match = { namespace = "omyview" }, no_screen_share = true })` is the layer form.
- Hyprland's IPC socket emits `configreloaded>>` on `hyprctl reload` (captured on socket2;
  Quickshell surfaces it via `Hyprland.rawEvent`). **A config reload discards the
  dispatched-chunk globals** (probed 2026-09-12: a global set before `hyprctl reload` is gone
  after it), so rules and the observer created by chunks vanish on every reload and must be
  re-installed.
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

**`lockInstallLua()`** — idempotent. The layer rule and the share observer are created FIRST,
unconditionally, before anything touches the filesystem, so a broken `$XDG_RUNTIME_DIR` (or a
write/rename failure) degrades only share detection — never the lock rules themselves. The
dir-creation-and-publish step runs in its own inner `pcall` and is re-raised on failure, so the
outer `ok, err` (what `reportLua` reports) carries the filesystem failure while the layer rule
and subscription created above it are left standing:
```lua
local L = _G.omyview_lock
if not L then
  L = { rules = {}, sharing = 0, sub = nil, layer = nil, dir = nil }
  _G.omyview_lock = L
end
function L.publish()                                          -- defined unconditionally; reads L.dir at call time
  local tmp, dst = L.dir .. "/share-state.tmp", L.dir .. "/share-state"
  local f = io.open(tmp, "w"); if not f then error("cannot write share-state") end
  local w = f:write(L.sharing > 0 and "1" or "0"); local c = f:close()
  if not w or not c then os.remove(tmp); error("write share-state failed") end
  local ok, err = os.rename(tmp, dst)
  if not ok then os.remove(tmp); error("rename share-state: " .. tostring(err)) end
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
local pok, perr = pcall(function()                             -- filesystem step, isolated
  if not L.dir then
    local base = os.getenv("XDG_RUNTIME_DIR"); if not base then error("XDG_RUNTIME_DIR unset") end
    local dir = base .. "/omyview"
    local r = os.execute("mkdir -p '" .. dir .. "'")           -- once; Lua 5.4 returns true, 5.1 returns 0
    if r ~= true and r ~= 0 then error("mkdir failed") end
    L.dir = dir                                                 -- assigned only on success, so a failed install can retry
  end
  L.publish()
end)
if not pok then error(perr, 0) end                             -- re-raised so the outer ok, err (reportLua) sees it
```
- `sharing` counts starts minus ends, clamped at 0. It only drives the placeholder; a stuck
  count shows the placeholder longer than needed, never exposes anything. An idempotent
  re-install preserves it; only a fresh Lua state (Hyprland start or reload) starts at 0. A
  share already running when the observer is created is therefore not detected until the next
  share event: accepted false negative (enforcement does not depend on it).
- `publish()` writes `1`/`0` atomically, checking write and close before the rename so a failed
  write never replaces valid state, and removing the temp file on any failure (write, close, or
  rename) so it never lingers; every install publishes the current value so a fresh shell never
  reads a missing file for long.
- The layer rule and observer subscription are created before the dir/publish step is attempted,
  and are unaffected by its failure — a broken runtime directory (or a write/rename failure)
  only means the share-state file goes stale or missing; the lock rules the layer rule and the
  sync chunk maintain are never affected by it.

**`lockSyncLua(armed)`** — `armed` is the full array of selectors (`"3"`, `"special:scratchpad"`):
```lua
local L = _G.omyview_lock; if not L then error("lock not installed") end
local want = {}; for _, sel in ipairs(ARMED) do want[sel] = true end
local failed = {}
local function step(sel, f) local ok, err = pcall(f); if not ok then failed[#failed + 1] = sel .. ": " .. tostring(err) end end
for sel in pairs(want) do
  step(sel, function()
    local r = L.rules[sel]
    if not r then
      r = hl.window_rule({ name = "omyview-lock-" .. sel, match = { workspace = sel }, no_screen_share = true, enabled = true })
      L.rules[sel] = r
    else
      local eok, eerr = pcall(function() r:set_enabled(true) end)
      if not eok then L.rules[sel] = nil; error(eerr, 0) end    -- drop the dead handle; the next sync recreates it
    end
  end)
end
for sel, r in pairs(L.rules) do if not want[sel] then step(sel, function() r:set_enabled(false) end) end end
local ok, err = #failed == 0, table.concat(failed, "; ")
-- reportLua('lock sync')   -- one report naming every selector that failed
```
Every create/enable/disable is guarded on its own, so one failure never prevents the other
selectors from being protected or stale rules from being disabled. A failed re-enable clears
its selector's handle from `L.rules` rather than leaving a broken one there forever: the next
sync that arms the same selector sees no handle and creates a fresh rule instead of retrying a
handle that keeps throwing. `ARMED` is the array literal interpolated by the builder; **in
JavaScript, before interpolation**, each selector must match `/^(\d+|special:[A-Za-z0-9_-]+)$/`;
anything else is dropped from the chunk and reported via the notification path.

**Rule semantics to prove in the plan's first task, on 0.56.2, with captured pixels** (not
`is_enabled()`): create enabled → capture an existing window is black; `set_enabled(false)` →
capture shows it; `set_enabled(true)` → black again; a window *moved onto* the workspace while
the rule is enabled → black; a window moved off → visible; a floating window on the workspace →
black; a fullscreen window → black. Upstream notes that dynamic toggling wants named rules; the
rules are named for that reason.

## Overview side

**State.** `OmyviewLocks.qml` (new, beside `OmyviewConfig.qml`): a watched `FileView` on the
locks file. `armed: var` is **null until the first load resolves** ("unresolved"), then an array
of selectors. `onLoadFailed` distinguishes `FileViewError.FileNotFound` from every other error
(permission, a directory in its place, a transient I/O failure, …) via the `FileViewError` enum
(`Quickshell.Io`) — a missing file resolves to `[]` once, on the first load only (a *later*
"missing" load, e.g. the file was deleted after a successful read, keeps the in-memory set); any
other error, and a malformed (parseable-but-invalid or unparseable) file, keeps the previous
value — still null if it was the first load — and is reported once via the notification path.
The reducer (`Logic.applyLocksTo(current, raw, status)`, status one of `"ok"` / `"missing"` /
`"error:<text>"`) is pure and shared between the component and its offscreen test stub, so both
agree on this. `toggle(sel)` is a no-op while unresolved or `sel` fails
`Logic.validLockSelector` (shared as `Logic.toggleSelector(armed, sel)`, which returns the next
array or `null` to mean "refused"). A second watched `FileView` on the share-state file exposes
`sharing: bool` (`"1"`), false when missing or unreadable. `placeholder(sel) = armed !== null &&
armed.includes(sel) && sharing`.

**Persistence ordering in `toggle(sel)`:** update the in-memory `armed` first, dispatch
`lockSyncLua(armed)` immediately (the compositor is the enforcement; it must not wait for disk),
then write the file atomically (temp + rename). A write failure is reported and leaves the
in-memory set as the truth for this session; the next toggle retries. Rapid toggles each
dispatch the full set, so the last dispatch wins and the compositor never sees a partial state.

**Selectors.** `Logic.wsSelector(id)` already yields `"3"` / `"special:scratchpad"`; boxes are
keyed by it for lock purposes. The file stores selectors, so the scratchpad entry survives its
dynamic id.

**Sync points.** `lockInstallLua()` is dispatched on `Component.onCompleted` (kept loaded: shell
start), on the `configreloaded` raw event, and in `open()`. `lockSyncLua(armed)` is dispatched
**only when `armed` is resolved**: on the locks file's first successful load and every accepted
change, on `configreloaded`, in `open()`, and after every `toggle`. While `armed` is unresolved
no sync is sent, so a shell restart can never disable rules the compositor still holds (the
`FileView` loads asynchronously; the retained rules keep protecting until the file is read).
All dispatches are idempotent. Installation is not awaited: `Hyprland.dispatch` is fire-and-forget
and there is no completion barrier before `open()` maps the surface (see Edge cases).

Quickshell's `FileView` watches the file's *parent directory*, not the file itself: if that
directory does not exist at `FileView` creation, the watch never attaches, and no `fileChanged`
ever fires for it later even once the directory and file show up (see Edge cases, "Shell start
before the runtime dir exists"). `OmyviewLocks.refresh()` (`stateFile.reload(); locksFile.reload()`)
re-attaches it; `lockInstall()` restarts a 400ms `Timer` that calls it, and `open()` also calls it
directly (after `lockInstall(); lockSync()`) as a belt-and-braces re-attach on every summon.

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
  edit), not something a share triggers. Probed: globals do NOT survive a reload, so this window
  is real and the `configreloaded` re-install is load-bearing, not redundant.
- **Overview mapped before its layer rule exists** (a share running at shell start, and the
  overview opened within the few milliseconds before the install chunk lands): the overview's
  surface can be captured. Accepted. Two mitigations bound it: the rule is dispatched at shell
  start, long before a human can press SUPER+P; and the overview's own thumbnails are screencopy
  captures of windows that are themselves under `no_screen_share`, so they are expected to be
  black too — a live-test item (below), not a claim.
- **Hyprland restart**: ends every share and every capture client; the shell's next
  `configreloaded`/open re-installs.
- **Shell restart / crash**: the compositor table and rules are untouched (install is
  idempotent), so protection never lapses. Stale intent (a disarm written to the file but the
  shell died before syncing) is corrected by the full-set sync on the next start.
- **Compositor crash leaving `share-state` = `1`**: the next install publishes `0` (counter
  resets). Until then the overview shows placeholders for armed boxes — a false positive, never
  a leak.
- **Shell start before the runtime dir exists**: `$XDG_RUNTIME_DIR/omyview` (holding
  `share-state`) does not exist until the install chunk's `mkdir -p` runs — asynchronously, after
  the `FileView` on it is already constructed. Quickshell watches a `FileView`'s *parent
  directory*; a directory that is missing at construction means the watch never attaches, so
  every later write to `share-state` (a share starting or ending) would go unseen for the rest of
  the session, with no error — nothing fails, it just silently never updates. Mitigated by
  `OmyviewLocks.refresh()` (`reload()` on both files, re-attaching the watch), called ~400ms
  after every `lockInstall()` (a `Timer`, giving the directory time to appear) and once more
  directly in `open()`. Applies in principle to the locks file's own directory too
  (`~/.config/omarchy/`), but that directory is created well before omyview ever runs (Omarchy's
  own config layout), so it is not observed to be missing in practice — `refresh()` covers it for
  free regardless.
- **Locks file missing on the first load**: resolves to `[]` (first run). **Missing on a later
  load** (the user deleted the file after a successful read): the in-memory set is kept, not
  reset to `[]` — only a first, never-yet-resolved load may treat "missing" as "empty".
  **Malformed, or any other read error, on the first load**: `armed` stays null (still
  unresolved); reported once via the notification path; `toggle` remains a no-op, and
  `lockToggleSelected()` tells the user once per open why Ctrl+L is doing nothing ("omyview:
  locks file unreadable — fix or delete ~/.config/omarchy/omyview-locks.json") rather than
  silently swallowing the keypress. **Malformed, or any other read error, on a later load**: the
  last valid set is kept and enforced; reported once; the next successful write (the next
  accepted toggle) replaces the file with a fresh, valid one.
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
  `fire(event, ...)` helper. Cases: install twice → one layer rule, one active subscription, a publish on
  each install (value `0` on a fresh state), and the counter preserved across the second
  install; sync `["3"]` → rule `omyview-lock-3` created enabled; sync `[]` → disabled,
  handle kept; sync `["3"]` again → same handle re-enabled (no second rule); sync
  `["3","special:scratchpad"]` → both enabled; share start → `1` published, rules untouched
  (already enabled); second start then one end → still `1`; last end → `0`; end without start
  → clamped at `0`; a rule creation or setter throwing → one report naming it, every other
  selector still created/enabled and every stale rule still disabled (per-step pcall); a
  failed mkdir → install reports and `L.dir` stays unset so the next install retries; a failed
  write → no rename (state file unchanged);
  invalid selector dropped and reported; `os.rename` failing → reported; `Logic.notifyLua(text)`
  round-trips a backslash, a quote and a newline into a single valid Lua string (escaped, then
  flattened) rather than breaking the chunk or losing the character.
- **Tier 1, `tests/tst_layout.qml`**: a `placeholder` workspace yields a box with
  `placeholder: true` and no tiles; an `armed` one without placeholder is unchanged;
  `Logic.parseLocks` accepts a valid file (de-duplicated) and rejects a non-object, a missing
  `armed` array and a bad selector; `Logic.applyLocksTo(current, raw, status)` — missing on the
  first load → `[]`, changed; missing later → `current` kept, unchanged; an error or a malformed
  file on the first load → still `null`, reported; the same later → the previous value kept,
  reported; `"ok"` with a valid file → parsed, changed; `Logic.toggleSelector(armed, sel)` adds,
  removes, and returns `null` (refused) for `null` armed or an invalid selector, without
  mutating its input.
- **Offscreen UI (`tests/ui/lock.qml`)**, with prepare.py replacing `OmyviewLocks.qml` by a
  stub (the fixture has no Quickshell.Io) whose `armed` starts null and offers `loadArmed`,
  `setSharing` and recorded `writes` — real file watching and atomic writes are live-check
  items: Ctrl+L on ws 3 writes `armed: ["3"]` and dispatches install + sync
  with `"3"`; Ctrl+L again writes `[]` and dispatches a sync without it; the badge follows;
  writing `1` to the state file locks armed boxes (tiles gone, glyph shown, capture handle
  null) and `0` restores tiles; **positive control**: a query matching a window on ws 3 shows 1
  match before, 0 while placeholder, 1 after; a selected match whose box becomes a placeholder
  falls to the successor rule; Ctrl+L on the scratchpad row writes `special:scratchpad`; a drop
  onto a placeholder box dispatches the move and leaves no pending row; a pending drop onto ws 3
  followed by the state file flipping to `1` leaves no row; reopen re-reads the file and
  re-dispatches install + sync; a malformed file keeps the previous set; a `configreloaded` raw
  event re-dispatches install + sync; **no sync is dispatched before the locks file has
  loaded** (the fixture delays the load and asserts the dispatch list holds only the install);
  a write failure (unwritable path) is reported and the in-memory set still drives the badge
  and the sync; open() installs and syncs the loaded set exactly once each, install before sync
  (pinned by index, on a view built and reset right before that one `open()` call); a toggle
  attempted while unresolved reports "locks file unreadable" once per open, not once per
  keypress; a padded (synthetic, empty) workspace still carries `armed`/`placeholder` so an
  otherwise-empty workspace can be armed and keeps its badge.
- **Live (plan's first task, before any UI work)**: the rule-semantics sequence above with
  `grim` captures inspected as pixels (an unarmed workspace as positive control). (The
  `configreloaded` event name and the loss of globals on reload are already verified.) **Live (final)**: a
  real monitor share through the portal (e.g. a video-call test page or `wf-recorder`), armed
  workspaces black in the recorded output including the first frame after switching to them,
  the overview absent from the recording, the overview's own thumbnail of an armed window black
  (if it is not, the placeholder is load-bearing and the mapping gap above widens to "thumbnails
  visible for milliseconds"), and the state file flipping on start and end.
