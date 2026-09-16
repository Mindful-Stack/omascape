# Omascape — workspace lock for screen sharing (design)

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
`no_screen_share` window rules matched on the workspace, a compositor-side share observer
(presentation only), persistence of the armed set, full-set reconciliation on every sync,
re-install on Hyprland config reload, overview visuals (badge, placeholder), tests.

**Out:** per-window locks, blocking navigation to armed workspaces, an indicator outside the
overview, locking by app class, protecting windows the user moves *off* an armed workspace (a
pinned window included: it follows the active workspace, so pinning it on an armed workspace and
then switching away exposes it — the same class of exposure as moving a window off), the unnamed
`special` workspace (share-picker popups; never a box, cannot be armed), and any guarantee about
the first frame after a *Hyprland config reload* (see Edge cases).

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
  **`os.execute`'s return value cannot be trusted, though** (found by the Task 6 live check,
  2026-09-13): the compositor reaps the child itself, so Lua never sees an exit status —
  `os.execute` returns `nil` even when `mkdir -p` succeeded and the directory exists. The
  install chunk does not gate on it; it verifies the directory by opening (and immediately
  removing) a probe file instead. **A bare `mkdir -p` costs ~2.5ms of compositor main-thread
  time** (measured 2026-09-14) — expensive to pay on every install (every overview open), so
  the probe runs FIRST and `mkdir -p` only runs when the probe shows the directory is actually
  missing.
- `hl.on("screenshare.state", cb)` fires with `(active: boolean, type: number, name: string)`
  (upstream documents Active, Type, Name; the second argument is not a session id). A screenshot
  fires `true` then `false`. Subscriptions have `:remove()` and `:is_active()`. The event is
  Lua-only; Quickshell cannot observe shares directly. **`type` distinguishes what is being
  captured** (live-probed 2026-09-14; Hyprland's four share types): `0` monitor (a whole-output
  capture — `grim`, a screen share; `name` is the output, e.g. `eDP-1`), `1` window (a toplevel
  export — opening the overview itself fires exactly this, once per visible thumbnail, with
  `name` the window's title), `2` region (a rectangular crop of the screen — rendered through
  the same output-capture path as a monitor share), `3` none. The observer ignores only
  `type == 1`: a window share cannot capture the overview itself or any other window, so only
  the overview's own thumbnails produce this type; monitor and region shares both count as real
  shares, or every overview open would bump the counter and flip armed boxes to the placeholder
  for no real share at all.
- `hl.layer_rule({ match = { namespace = "omascape" }, no_screen_share = true })` is the layer form.
- **A `no_screen_share` layer rule is NOT used on the overview's own layer**, despite the API
  existing for it: verified from source (`ScreenshareFrame.cpp`) that Hyprland renders such a
  layer as an opaque black rect over the *whole* layer box while it is mapped. The overview's
  panel is fullscreen, so applying this to the overview's own namespace would blank the entire
  shared screen (not just the overview) for as long as it is open — and toplevel export of an
  armed window is denied by Hyprland regardless (the per-workspace `window_rule`, see Compositor
  side), so the overview cannot leak armed pixels without the layer rule either. The same
  per-surface blanking is exactly what the share-time reminder frame WANTS for its own thin edge
  strips (addendum below) — live-probed 2026-09-14 on the bar's namespace: only that surface's
  26 px strip went black in a `grim` capture (mean 0), the rest of the frame was untouched
  (mean 0.133).
- Hyprland's IPC socket emits `configreloaded>>` on `hyprctl reload` (captured on socket2;
  Quickshell surfaces it via `Hyprland.rawEvent`). **A config reload discards the
  dispatched-chunk globals** (probed 2026-09-12: a global set before `hyprctl reload` is gone
  after it), so rules and the observer created by chunks vanish on every reload and must be
  re-installed.
- omascape's config is `~/.config/omarchy/omascape.json`, read through a watched `FileView`.

## Decisions

- **Armed = excluded, always.** Ctrl+L arms/disarms the selected box. An armed workspace's
  rule is enabled from that moment until disarmed, share or not. Chosen over "enable only during
  a share" because an event-driven enable races the first captured frame (codex review, 2026-09-12),
  and a screenshot's first frame is the whole disclosure. Cost: the user's own screenshots of an
  armed workspace are black too; disarm first. No force switch (arming is already immediate).
- **Share detection is presentation only.** The compositor observer only tells the overview
  whether a share is active so it can show the placeholder. A detection race or failure never
  exposes window pixels (armed tiles are icons, and the compositor denies their export); what it
  can expose to a viewer is the armed workspace's app identity — icons, names, a find count —
  until the placeholder lands.
- **No navigation blocking.**
- **Persisted** in `~/.config/omarchy/omascape-locks.json` (`{ "armed": ["3", "special:scratchpad"] }`),
  written atomically by omascape (temp file + rename), re-applied at shell start, on
  `configreloaded`, and on every open.
- **One sync chunk reconciles the whole set.** `lockSyncLua(armed)` creates or enables one
  named rule per armed selector and disables every other rule the table knows. There is no
  separate arm/disarm; every change re-sends the full set. Idempotent by construction.
- **Named rules, one retained handle per selector.** `name = "omascape-lock-" .. sel`; a disarmed
  rule is disabled and its handle kept, so re-arming re-enables it. No accumulation.
- **Install at shell start, not first at open.** The install + sync run when the kept-loaded
  component is created, again on `configreloaded`, and again in `open()` (belt and braces).
- **Placeholder, not blur.** While a share is active, an armed box renders no tiles and no
  capture, and a lock glyph fills the well. Otherwise an armed box shows its windows as app icons
  (the compositor denies toplevel export for windows under the rule) plus the lock badge; during
  a share it shows the placeholder.
- **Two files, one owner each.** omascape owns the locks file. The compositor observer owns
  `$XDG_RUNTIME_DIR/omascape/share-state`, written atomically; content `1`/`0`.
- **Intent vs enforcement.** The badge shows the *armed* intent from the file. Enforcement
  failures (rule creation or enabling throwing) are reported through the existing chunk report
  path (compositor log + notification); the overview does not claim "protected" beyond the
  badge. Accepted: there is no confirmed-enforcement channel back to the shell.

## Behaviour

| Key / action (overview)   | effect                                                                        |
|---------------------------|-------------------------------------------------------------------------------|
| Ctrl+L                    | toggle armed on the selected box; dispatch `lockSyncLua`; write the locks file |
| Enter / digits / click    | unchanged                                                                     |
| drag / drop               | unchanged for the compositor; a window dropped on an armed box is matched by the rule on arrival. In the overview, a drop onto a box that is currently showing the placeholder creates **no optimistic tile** (dispatch only) |
| find                      | never matches windows in a box showing the placeholder; armed boxes outside a share match normally |

Outside the overview: an armed workspace is black in every capture from the moment the sync
chunk runs. Moving a window *off* an armed workspace exposes it; that is by design (the rule is
per workspace, and the user chose to move it).

## Compositor side

All single-line guarded chunks in the existing style (`dispatchGuardLua`, `reportLua`), built in
`logic.js`, parse- and behaviour-tested by `tests/lua-check.sh`.

**`lockInstallLua()`** — idempotent. It creates the `omascape-lockframe` LAYER rule (the
share-time reminder frame's own strips, addendum below) but still no layer rule for the
*overview's* namespace (see Verified facts: a `no_screen_share` layer is an opaque black rect over
that surface's whole box, which for the overview means the whole screen — and it is unnecessary,
since toplevel export of an armed window is denied regardless by the per-workspace `window_rule`
below). The share observer is
created FIRST, unconditionally, before anything touches the filesystem, so a broken
`$XDG_RUNTIME_DIR` (or a write/rename failure) degrades only share detection — never the lock
rules themselves. The verify-dir-and-publish step runs in its own inner `pcall` and is re-raised
on failure, so the outer `ok, err` (what `reportLua` reports) carries the filesystem failure
while the subscription created above it is left standing:
```lua
local L = _G.omascape_lock
if not L then
  L = { rules = {}, sharing = 0, effective = false, grace = nil, sub = nil, subVer = nil,
        dir = nil, frameRule = nil }
  _G.omascape_lock = L
end
if L.effective == nil then L.effective = L.sharing > 0 end   -- an _G table from a pre-hysteresis build
if L.borders then                                            -- round-3 leftovers: window-border rules
  for _, r in pairs(L.borders) do pcall(function() r:set_enabled(false) end) end
  L.borders = nil                                            -- this API cannot remove a rule, only disable it
end
function L.ensureDir()                                         -- probe first; called on EVERY install, see below
  local base = os.getenv("XDG_RUNTIME_DIR"); if not base then error("XDG_RUNTIME_DIR unset") end
  local dir = base .. "/omascape"
  local probe = io.open(dir .. "/.omascape-probe", "w")         -- verify the directory directly, first
  if not probe then
    os.execute("mkdir -p '" .. dir .. "'")                     -- only on a failed probe: see below
    probe = io.open(dir .. "/.omascape-probe", "w")
    if not probe then error("runtime dir unavailable: " .. dir) end
  end
  probe:close(); os.remove(dir .. "/.omascape-probe")
  L.dir = dir
end
function L.publish()                                          -- defined unconditionally; reads L.dir at call time
  local tmp, dst = L.dir .. "/share-state.tmp", L.dir .. "/share-state"
  local f = io.open(tmp, "w")
  if not f then                                                -- the dir may have vanished since install; retry once
    L.ensureDir()
    tmp, dst = L.dir .. "/share-state.tmp", L.dir .. "/share-state"   -- recomputed from L.dir post-recovery
    f = io.open(tmp, "w")
  end
  if not f then error("cannot write share-state") end
  local w = f:write(L.effective and "1" or "0"); local c = f:close()   -- the debounced value, not the raw count
  if not w or not c then os.remove(tmp); error("write share-state failed") end
  local ok, err = os.rename(tmp, dst)
  if not ok then os.remove(tmp); error("rename share-state: " .. tostring(err)) end
end
-- L.apply() is defined here, before the subVer check and the observer subscription below (which
-- calls it), so a fresh subscription's callback always closes over a fully-defined function.
-- Since round 4 the compositor has nothing to reconcile on a share edge -- the cue is the shell's
-- own layer-shell frame, driven by the published state file -- so applying IS publishing. It
-- stays a named function: the observer callback's body text is what LOCK_OBSERVER_VERSION guards,
-- and the indirection means a change on this side needs no version bump.
function L.apply()
  L.publish()
end
if L.subVer ~= LOCK_OBSERVER_VERSION then                      -- see LOCK_OBSERVER_VERSION below
  if L.sub then pcall(function() L.sub:remove() end) end
  L.sub = nil
  L.subVer = LOCK_OBSERVER_VERSION
end
if not (L.sub and L.sub:is_active()) then
  L.sub = hl.on("screenshare.state", function(active, kind)
    if kind == 1 then return end                               -- 1 = window export (the overview's own thumbnails)
    local ok, err = pcall(function()
      L.sharing = math.max(0, L.sharing + (active and 1 or -1))
      if L.sharing > 0 then                                    -- ON edge: immediate, and cancels a pending off
        if L.grace then pcall(function() L.grace:set_enabled(false) end); L.grace = nil end
        if not L.effective then L.effective = true; L.apply() end
      elseif L.effective then                                  -- OFF edge: only arm the grace timer
        if L.grace then pcall(function() L.grace:set_enabled(false) end) end
        local tok, t = pcall(function()
          return hl.timer(function()                           -- a FRESH oneshot per off-edge; see below
            L.grace = nil
            local gok, gerr = pcall(function()
              if L.sharing == 0 and L.effective then L.effective = false; L.apply() end
            end)
            if not gok then print("omascape: share grace timer failed: " .. tostring(gerr)) end
          end, { timeout = LOCK_SHARE_GRACE_MS, type = "oneshot" })
        end)
        L.grace = tok and t or nil
        if not L.grace then L.effective = false; L.apply() end -- no timer at all: degrade to the immediate off
      end
    end)
    if not ok then print("omascape: share observer failed: " .. tostring(err)) end
  end)
end
-- Share-time reminder frame (addendum, round 4): the rule that blanks omascape's own frame strips
-- in every capture. Created once and kept on L (this API can only disable a rule, never remove
-- it, and install runs on every overview open), re-enabled if a surviving handle is disabled,
-- and recreated after a configreloaded like everything else in _G. Its own pcall so a failure
-- here cannot take down the exclusion rules or the observer; re-raised below into the same report.
local fok, ferr = pcall(function()
  if L.frameRule then
    local iok, cur = pcall(function() return L.frameRule:is_enabled() end)
    if (not iok) or cur == false then L.frameRule:set_enabled(true) end
  else
    L.frameRule = hl.layer_rule({ name = "omascape-lockframe",
                                  match = { namespace = "omascape-lockframe" },
                                  no_screen_share = true })
  end
end)
local pok, perr = pcall(function()                             -- filesystem step, isolated
  L.ensureDir()                                                 -- unconditional: see below
  L.apply()
end)
if not fok then error(ferr, 0) end                             -- re-raised so the outer ok, err (reportLua) sees it
if not pok then error(perr, 0) end
```
`os.execute`'s return value is ignored, not checked: on this Hyprland build it is always `nil`,
even when `mkdir -p` succeeded and the directory exists (the compositor reaps the child itself,
so Lua never sees an exit status — found by the Task 6 live check). The directory is verified
directly instead: opening (and immediately removing) a probe file inside it. `L.ensureDir()`
probes FIRST and only calls `os.execute("mkdir -p …")` if that probe fails: a bare `mkdir -p`
measured ~2.5ms of compositor main-thread time, and `L.ensureDir()` runs on every install
(review of the original always-mkdir version, 2026-09-14) — the common case (directory already
there) now costs one file open, not a shell-out.

`L.ensureDir()` runs on **every** install, not only when `L.dir` is nil, and `L.publish()`
retries it once on its own (recomputing `tmp`/`dst` from the possibly-changed `L.dir` before the
retry) if `io.open` fails. `_G.omascape_lock` is compositor Lua state, and it survives a shell
restart — but the runtime directory does not: it can be removed by a cleaner, or is simply gone
after a restart. Without re-verifying, a stale `L.dir` from a previous session would point at
nothing, and `L.publish()` — called from every install *and* every share event — would fail with
"cannot write share-state" forever, since nothing ever re-checked. Confirmed live: `L.dir` was
set to `/run/user/1000/omascape` while the directory did not exist, after the user's first manual
restart.

**`LOCK_OBSERVER_VERSION`** (a `logic.js` constant, currently `4` — bumped at 3 for the
share-time reminder addendum below, whose callback change was `L.publish()` → `L.apply()`, and at
4 for the share-state hysteresis below; deliberately NOT bumped at round 4, where `L.apply()`'s
BODY changed but the callback's own text did not, and every install redefines `L.apply()` on the
shared `L` table before the version check runs) guards the subscription
itself, not just the directory: the observer's callback is a closure created once and owned by
the subscription object, and `_G.omascape_lock` — including that subscription — survives a shell
restart untouched. `L.sub:is_active()` alone would stay `true` forever, so the install's own
idempotence check (`if not (L.sub and L.sub:is_active())`) would never see a reason to replace a
stale callback: a shell restart could deliver a new `logic.js` (and thus a changed callback body,
such as the `kind` filter below) without a `configreloaded` — the only event that drops `_G` —
ever happening, leaving the OLD behaviour running against the NEW shell indefinitely. Every
change to the callback body must bump `LOCK_OBSERVER_VERSION`; a mismatch on install removes the
existing subscription (even though it is still active) before the block below creates a fresh
one.

**`LOCK_SHARE_GRACE_MS`** (a `logic.js` constant, `3000`) — the share signal flaps, so the OFF
direction is debounced. `src/managers/screenshare/ScreenshareSession.cpp` (0.56.2) emits
`screenshare.state(true, …)` on every successfully **copied frame** and `screenshare.state(false,
…)` from a 500 ms timer that fires whenever no frame arrived for half a second. A consumer that
pulls frames irregularly — OBS recording a mostly static screen — therefore makes the compositor
emit false/true pairs for the whole recording: measured 2026-09-14, 20 events in 30 s, every
false run under ~1 s. Applying each edge (versions ≤ 3 did) rewrote `share-state` twice a second,
which the shell's `FileView` dutifully reloaded — since round 4 that file IS the whole cue, so
every rewrite flickers the reminder frame and the overview's placeholder with it. (In round 3 it
also toggled `border_size`, relayouting the workspace: the user saw every window on the armed
workspace "constantly resizing".) So:
- `L.sharing` stays the raw balanced counter, incremented/decremented and clamped on every edge.
- `L.effective` is the debounced boolean the state file (`L.publish()`) follows, and through it
  the reminder frame and the overview's placeholder. A true edge sets it immediately (no delay on the ON edge — the
  reminder must never lag the share starting) and cancels any pending grace; a false edge leaves
  it alone and arms `L.grace`, a `LOCK_SHARE_GRACE_MS` oneshot that clears it only if the count
  is still 0 when it fires. A flap inside the window produces no `set_enabled` on any rule and no
  state-file write at all.
- A **fresh timer per off-edge**, never a re-armed one. Probed live on 0.56.2:
  `hl.timer(cb, { timeout = <ms>, type = "oneshot" })` starts immediately; `set_enabled(false)`
  before it fires cancels it for good (it never fires); `set_enabled(false)` then `(true)` before
  the deadline still fires once, at the original deadline; but a timer that has already fired can
  **not** be restarted — `set_enabled(true)`/`set_timeout` after firing do nothing. `is_enabled()`
  is true only while pending.
- The timer callback carries its own `pcall` + `print`: it runs on the compositor's clock, outside
  the event handler's `pcall`, and `L.apply()` can raise (a publish failure).
- 3 s leaves headroom over the longest measured gap for a fully static screen. The trade-off is
  one-sided: too short means flicker; too long means the rim (and the overview's placeholder)
  lingers a few seconds after the share really ended — cosmetic only, because the exclusion rules
  are always on and privacy never depends on this signal.
- `sharing` counts starts minus ends, clamped at 0. It only drives the placeholder (through
  `L.effective`); a stuck count shows the placeholder longer than needed, never exposes anything.
  An idempotent re-install preserves it; only a fresh Lua state (Hyprland start or reload) starts
  at 0. A share already running when the observer is created is therefore not detected until the
  next share event: accepted false negative (enforcement does not depend on it).
- `publish()` writes `1`/`0` atomically, checking write and close before the rename so a failed
  write never replaces valid state, and removing the temp file on any failure (write, close, or
  rename) so it never lingers; every install publishes the current value so a fresh shell never
  reads a missing file for long.
- The observer subscription is created before the dir/publish step is attempted, and is
  unaffected by its failure — a broken runtime directory (or a write/rename failure) only means
  the share-state file goes stale or missing; the per-workspace rules the sync chunk maintains
  are never affected by it.
- The observer ignores `kind == 1` (window/toplevel export — see Verified facts for all four
  values): the overview's own thumbnails fire `screenshare.state` with `kind = 1` for every
  visible tile, which would otherwise flip armed boxes to the placeholder every time the
  overview itself is open, with no real share happening. Monitor (`0`) and region (`2`) captures
  both count as real shares — a window share cannot capture the overview or any other window, so
  only a window capture is safe to assume is the overview's own thumbnail traffic.

**`lockSyncLua(armed)`** — `armed` is the full array of selectors (`"3"`,
`"special:scratchpad"`):
```lua
local L = _G.omascape_lock; if not L then error("lock not installed") end
local want = {}; for _, sel in ipairs(ARMED) do want[sel] = true end
local failed = {}
local function step(sel, f) local ok, err = pcall(f); if not ok then failed[#failed + 1] = sel .. ": " .. tostring(err) end end
for sel in pairs(want) do
  step(sel, function()
    local r = L.rules[sel]
    if not r then
      r = hl.window_rule({ name = "omascape-lock-" .. sel, match = { workspace = sel }, no_screen_share = true, enabled = true })
      L.rules[sel] = r
    else
      local eok, eerr = pcall(function() r:set_enabled(true) end)
      if not eok then L.rules[sel] = nil; error(eerr, 0) end    -- drop the dead handle; the next sync recreates it
    end
  end)
end
for sel, r in pairs(L.rules) do if not want[sel] then step(sel, function() r:set_enabled(false) end) end end
local ok, err = #failed == 0, table.concat(failed, "; ")
-- No L.publish() here: a sync never changes L.sharing (only the observer does), so republishing
-- would be redundant, and folding a publish failure into this chunk's own ok/err would report
-- "lock sync failed" for a stale runtime directory even though every rule was reconciled
-- correctly. Publishing is the observer/install's job; this report describes rules only.
-- reportLua('lock sync')   -- one report naming every selector that failed
```
Every create/enable/disable is guarded on its own, so one failure never prevents the other
selectors from being protected or stale rules from being disabled. A failed re-enable clears
its selector's handle from `L.rules` rather than leaving a broken one there forever: the next
sync that arms the same selector sees no handle and creates a fresh rule instead of retrying a
handle that keeps throwing. `ARMED` is the array literal interpolated by the builder; **in
JavaScript, before interpolation**, each selector must match
`/^([1-9]\d*|special:[A-Za-z0-9_-]+)$/` — a leading zero is refused (Hyprland parses `"007"` as
workspace `7`, so a hand-edited `"007"` would arm workspace 7 with no badge to show it) and `"0"`
is refused (Hyprland workspaces are 1-indexed). Invalid selectors are refused by
`Logic.parseLocks`/`Logic.toggleSelector` before they can reach a chunk at all; the array filter
inside the sync builder itself is defense in depth, and drops anything that slips through
silently, with no notification.

**Rule semantics to prove in the plan's first task, on 0.56.2, with captured pixels** (not
`is_enabled()`): create enabled → capture an existing window is black; `set_enabled(false)` →
capture shows it; `set_enabled(true)` → black again; a window *moved onto* the workspace while
the rule is enabled → black; a window moved off → visible; a floating window on the workspace →
black; a fullscreen window → black. Upstream notes that dynamic toggling wants named rules; the
rules are named for that reason.

## Overview side

**State.** `OmascapeLocks.qml` (new, beside `OmascapeConfig.qml`): a watched `FileView` on the
locks file. `armed: var` is **null until the first load resolves** ("unresolved"), then an array
of selectors. `onLoadFailed` distinguishes `FileViewError.FileNotFound` from every other error
(permission, a directory in its place, a transient I/O failure, …) via the `FileViewError` enum
(`Quickshell.Io`) — a missing file resolves to `[]` once, on the first load only (a *later*
"missing" load, e.g. the file was deleted after a successful read, keeps the in-memory set); any
other error, and a malformed (parseable-but-invalid or unparseable) file, keeps the previous
value — still null if it was the first load — and is reported once via the notification path.
The reducer (`Logic.applyLocksTo(current, raw, status)`, status one of `"ok"` / `"missing"` /
`"error:<text>"`) is pure and shared between the component and its offscreen test stub, so both
agree on this. `toggleInMemory(sel)` is a no-op while unresolved or `sel` fails
`Logic.validLockSelector` (shared as `Logic.toggleSelector(armed, sel)`, which returns the next
array or `null` to mean "refused"). A second watched `FileView` on the share-state file exposes
`sharing: bool` (`"1"`), false when missing or unreadable. `placeholder(sel) = armed !== null &&
armed.includes(sel) && sharing`.

**Persistence ordering:** update the in-memory `armed` first (`toggleInMemory(sel)`), dispatch
`lockSyncLua(armed)` immediately (the compositor is the enforcement; it must not wait for disk),
then write the file atomically (`persist()`, temp + rename). The split exists so the CALLER
(`lockToggleSelected()`) can enforce that ordering: `toggleInMemory` never touches disk, and
`persist` writes whatever `armed` currently holds, so it must run only right after the sync that
is supposed to precede it. A write failure is reported and leaves the in-memory set as the truth
for this session; the next toggle retries. Rapid toggles each dispatch the full set, so the last
dispatch wins and the compositor never sees a partial state.

**Selectors.** `Logic.wsSelector(id)` already yields `"3"` / `"special:scratchpad"`; boxes are
keyed by it for lock purposes. The file stores selectors, so the scratchpad entry survives its
dynamic id.

**Sync points.** `lockInstallLua()` is dispatched on `Component.onCompleted` (kept loaded: shell
start), on the `configreloaded` raw event, and in `open()`. `lockSyncLua(armed)` is dispatched
**only when `armed` is resolved**: on the locks file's first successful load and every accepted
change, on `configreloaded`, in `open()`, and after every accepted `toggleInMemory` (immediately,
before `persist()`). While `armed` is unresolved
no sync is sent, so a shell restart can never disable rules the compositor still holds (the
`FileView` loads asynchronously; the retained rules keep protecting until the file is read).
All dispatches are idempotent. Installation is not awaited: `Hyprland.dispatch` is fire-and-forget
and there is no completion barrier before `open()` maps the surface (see Edge cases).

"Every accepted change" is load-bearing: `watchChanges`/an explicit `reload()` re-emit `loaded`
even when the bytes on disk did not change (our own atomic write reading its own content back;
a stray watcher firing) — `Logic.applyLocksTo` compares the newly parsed set against the current
one (same selectors, same order) and reports `changed: false` for an echo, so `OmascapeLocks` does
not re-emit `loadedArmed()` for it and the Overview does not re-sync or (while open) re-rebuild.
A `null` current always counts as changed (there is nothing yet to compare against).

Quickshell's `FileView` watches the file's *parent directory*, not the file itself: if that
directory does not exist at `FileView` creation, the watch never attaches, and no `fileChanged`
ever fires for it later even once the directory and file show up (see Edge cases, "Shell start
before the runtime dir exists"). This only affects the state file — `$XDG_RUNTIME_DIR/omascape` is
created asynchronously by the install chunk, after the `FileView` on it already exists — never
the locks file, whose directory (`~/.config/omarchy`) exists before omascape ever runs.
`OmascapeLocks.refresh()` (`stateFile.reload()`) re-attaches the state-file watch; `lockInstall()`
restarts a 400ms `Timer` that calls it, and `open()` also calls it directly (after `lockInstall();
lockSync()`) as a belt-and-braces re-attach on every summon.

**Keys.** Chord branch: `Ctrl+L` → `locks.toggleInMemory(Logic.wsSelector(selectedId))` when
`Logic.hasWs(selectedId)`, then `lockSync()`, then `locks.persist()`. Works with or without a
query.

**Rendering.** `buildInput()` marks each workspace record `armed: bool` and `placeholder: bool`
(armed and sharing). `layout()` copies both onto the box and **emits no tiles** for windows on a
placeholder workspace, so no capture starts. `buildInput()` also leaves those windows out of
`windows`, so find and drag never see them. Box delegate: placeholder → a large lock glyph
(nf-md-lock `\u{F033E}`) at 25 % opacity in the well, numeral hidden. Badge: armed → the lock
glyph after the number. Boxes remain selectable, jump targets and drop targets. An armed box
shows its windows as app icons (the compositor denies toplevel export for windows under the
rule) plus the lock badge; during a share it shows the placeholder instead. The tile's
`capMode` is `"icon"` whenever its box is armed (`locks.isArmed(Logic.wsSelector(model.wsid))`,
a readonly `boxArmed` property on the delegate so it re-evaluates as `locks.armed` changes),
independent of `panel.visible` — armed and sharing both force `"icon"`, only "armed and not
sharing" additionally still lays the tile out (a placeholder workspace emits no tiles at all, so
`capMode` on it is moot).

**Drops and pending state.** `submitDrop` onto a placeholder box dispatches the move but records
no `pendingMoves` entry and sets no optimistic row (the row would keep a live capture on a box
that must show none). When a box *becomes* a placeholder (share starts, or the user arms it
during a share), `rebuild()` first clears `pendingMoves` entries targeting it, so `applyTiles`
drops those rows at once (same mechanism as `hideScratchpad()`). A drag in flight whose window
is on a box that becomes a placeholder is cancelled by the existing "dragged window no longer in
the input → `endDrag()`" check.

**Hint row.** Adds `ctrl+l · lock`.

## Share-time reminder frame (addendum, 2026-09-14; rewritten round 4)

Approved after the first manual pass: the user wanted a local "this workspace is not viewable
by your audience" cue, because a workspace armed for one meeting is easy to forget in the next.

Rounds 1–3 implemented it as Hyprland **window-border** rules (`border_color` / `border_size` on
every window of an armed workspace). Round 4 replaced that with a frame omascape draws itself.
Two facts killed the border approach:

1. **The Lua rule API can only set the ACTIVE border colour.**
   `src/config/lua/types/LuaConfigGradient.cpp` parses any `border_color` string as ONE gradient
   and re-serialises it as `0xAARRGGBB 0deg`, so `parseBorderColorRule`
   (`src/desktop/rule/windowRule/WindowRule.cpp`) never sees the two-token "active inactive" form
   round 3 started emitting: unfocused windows on an armed workspace kept the theme's inactive
   colour. Confirmed in the user's own capture. (The round-1 probe note claiming a single value
   rims every window was wrong, and so was round 3's fix.)
2. **The cue belongs around the workspace, not around each window** — and a `border_size` change
   relayouts the workspace, which is the flicker round 3 chased.

- **Mechanism.** `LockFrame.qml` maps four thin `PanelWindow`s per screen (top, bottom, left,
  right), `WlrLayer.Overlay`, `WlrLayershell.namespace: "omascape-lockframe"`, each
  painting `lockBorderSize` px along its edge. Every strip spans its whole edge — the left/right
  ones the full height, the top/bottom ones the full width — and it is the top/bottom PAINT that is
  inset by the side strips' thickness, so every corner is painted exactly once (a doubled corner
  would read darker on a translucent colour) while all four surfaces still start and end on a
  screen edge, which is what the snapping below relies on. They reserve no space
  (`ExclusionMode.Ignore`), take no keyboard focus, and are click-through: `mask` is set to an
  empty `Region`, the same trick the overview uses while closed. Existence is `visible:`, never
  create/destroy — mapping a layer surface per share edge is the churn the hysteresis exists to
  avoid.
- **Device-pixel snapping (round 4b).** The PAINT is flush against the screen edge on all four
  sides — `lockBorderSize` px of it, exactly what the user asked for. What is bigger is the
  SURFACE: each strip maps `Logic.lockFrameSurfaceSize(thickness, monitor.scale)` logical px, the
  smallest size above the paint whose DEVICE size is a whole number (at scale 1.25 a 6 px paint
  gets an 8 px surface = 10 device px; at scale 1 it gets 7). The blanking box is rasterised from
  the layer's logical geometry × the monitor scale with its origin floored and its size truncated —
  it covers `[floor(start), floor(start) + floor(size))`. A monitor's device size is a whole number
  and every strip starts at logical 0 or at (W or H) − s, so when s·scale is whole the box is
  EXACTLY the surface and the paint, strictly inside it, cannot reach a pixel the box misses. A
  fractional device size always loses one device line, and whichever line that is carries the frame
  colour into the recording: round 4 leaked the inner edge (top band 0.0527), and round 4b's first
  attempt — paint flush, surface one px bigger — leaked the outer one (2576 pixels on device row
  1599 and column 2559).
  The strips therefore span their whole edge (top/bottom the full width, left/right the full
  height) and it is the top/bottom PAINT that carries `leftMargin`/`rightMargin` of `thickness`, so
  corners are still painted exactly once while every surface starts and ends on a screen edge.
  The paint is never snapped, and the search stops 12 px out: on a scale where nothing lands whole,
  `lockFrameSurfaceSize` falls back to `thickness + 1` and a one-device-pixel hairline can show in
  a capture — it discloses nothing. A scale that is not a positive finite number degrades the same
  way rather than throwing, since this runs in a binding.
- **Blanking.** `lockInstallLua()` creates one named LAYER rule,
  `hl.layer_rule({ name = "omascape-lockframe", match = { namespace = "omascape-lockframe" },
  no_screen_share = true })`, kept as `L.frameRule`. A `no_screen_share` layer renders as an
  opaque black rect over that surface's own box while mapped (`ScreenshareFrame.cpp`), so the
  strips go black in every capture: a viewer sees the plain black exclusion box, and the red frame
  is purely local. Live-probed 2026-09-14 against the bar's namespace: exactly that surface's
  26 px strip was black in a `grim` capture (mean 0) while the rest of the frame was untouched
  (mean 0.133) — per-surface blanking, not a whole-screen blank. The rule is created once,
  re-enabled rather than duplicated if a surviving handle is disabled (this Hyprland Lua API can
  only disable a rule, never remove one, and install runs on every overview open), and recreated
  after a `configreloaded` like every other rule, since that drops `_G` entirely. Its own `pcall`,
  so a failure cannot take down the exclusion rules or the share observer — the actual
  protection — and it is re-raised into the install's existing `reportLua` path. When the layer
  rule AND the filesystem step both fail, the install reports the filesystem one: a failed layer
  rule costs the cue's blanking, a failed publish costs share DETECTION, so the frame never appears
  at all.
- **Upgrading off round 3 (round 4b).** A compositor that has been running since round 3 still
  holds `_G.omascape_lock.borders`, a table of `omascape-lock-border-<sel>` window rules that may
  still be enabled and that nothing in round 4 touches. Since this Lua API can disable a rule but
  never remove one, they would keep rimming every window on an armed workspace until the user's
  next config reload — round 4's live check had to run `hyprctl reload` by hand for exactly this.
  The install now disables each one (guarded individually: a dead handle must not abort the
  install) and drops the table, so the sweep happens once.
- **When it shows.** A monitor's frame is visible iff `locks.sharing` **and** the workspace that
  monitor is currently SHOWING is armed. "Shown" is the monitor's special workspace when one is
  open (`lastIpcObject.specialWorkspace.name`, e.g. `special:scratchpad`), else its active
  workspace (`lastIpcObject.activeWorkspace.id`) — exactly the selectors `omascape-locks.json`
  holds. Hyprland reports `specialWorkspace: { id: 0, name: "" }` when none is open (verified on
  0.56.2), which is also what the `activespecialv2>>,,<mon>` payload announces, so the NAME
  decides, not the object's presence.
- **Freshness.** `HyprlandMonitor.lastIpcObject` is a snapshot, and the frame is a binding on it.
  `Overview.qml`'s raw-event handler calls `Hyprland.refreshMonitors()` for exactly the events
  after which the shown workspace can have changed (`Logic.lockFrameRefreshEvent`; payloads
  verified in 0.56.2 source): `workspacev2>>id,name`, `focusedmonv2>>monname,wsid`,
  `activespecialv2>>id,name,monname`, `moveworkspacev2>>id,name,monname`, `monitoraddedv2`,
  `monitorremovedv2` and `configreloaded`. Not the whole stream: a refresh is an IPC round trip,
  and a window title change cannot move a workspace between monitors. The frame re-evaluates on
  `locks.sharing` and `locks.armed` too, since it binds to both.
  The same handler bumps `root.monitorEpoch`, and the per-screen binding reads it
  (`monitor: (root.monitorEpoch, Hyprland.monitorFor(modelData))`). `monitorFor()` is a C++
  invokable returning a one-shot value: nothing notifies QML when Hyprland REPLACES the
  `HyprlandMonitor` object for a screen — which a monitor reconfigure across `configreloaded` does,
  without `Quickshell.screens` changing — so without the epoch the binding would hold a stale (or
  null) pointer and that screen's frame would stay hidden for good.
- **Pure core** (`logic.js`, Tier 1 tested, no QML): `lockFrameShownSelector(mon)`,
  `lockFrameVisible(sharing, armed, mon)`, `lockFrameRefreshEvent(name)`,
  `lockFrameSurfaceSize(thickness, scale)` (see the snapping bullet) and
  `lockColorToQml(hypr)`. The last converts the accepted `rgb(rrggbb)` / `rgba(rrggbbaa)` to
  `#rrggbb` / `#aarrggbb` — the alpha moves to the FRONT, because Qt reads `#rrggbbaa` as
  `#aarrggbb`, so `rgba(ff444480)` passed through unchanged would render as an opaque near-black.
  Anything else degrades to the default red rather than an invalid colour string, which QML would
  resolve to black. A malformed monitor snapshot yields `null`/`false` and never throws: these run
  in bindings that re-evaluate on every monitor event, including ones landing before the first
  refresh.
- **Config** (`~/.config/omarchy/omascape.json`, parsed by `Logic.parseConfig`): unchanged keys.
  `lockBorder` (string, default `"rgb(ff4444)"`; only the `rgb(hhhhhh)` / `rgba(hhhhhhhh)` hex
  forms are accepted — Hyprland's own colour syntax, kept for continuity with the rest of the
  user's config — anything else falls back to the default) and `lockBorderSize` (integer 0–20,
  default 6; **0 hides the frame**). `OmascapeConfig`'s watched `FileView` applies an edit live and
  the frame binds to both directly, so no `lockSync()` round trip through the compositor is
  involved any more; the round-2 `onLockBorderChanged`/`onLockBorderSizeChanged` handlers are gone.
- **What a viewer sees.** Effectively a black screen on an armed workspace: the exclusion box with
  the frame strips blacked out by the layer rule, and **no trace of the frame itself**. Verified
  2026-09-15 with the snapped-surface geometry, as a controlled experiment on HDMI-A-1
  (2560x1440, scale 1, `lockBorderSize: 6`, share triggered by `grim` itself — the first capture
  flips the state file, the second one 1 s later sees the frame):
  - layer rule **enabled**: **zero** frame-coloured pixels (R ≥ 180, G/B ≤ 130) in the whole
    capture, mean 0.00252.
  - layer rule **disabled** (`frameRule:set_enabled(false)`, the control): **21016** frame-coloured
    pixels, and device **row 0, row 1439, column 0 and column 2559 are frame-coloured across their
    whole length** — the paint really is flush against all four physical edges.
  - re-enabled: back to **zero**.
  The surfaces measured 7 logical px there (scale 1) and 8 logical px on eDP-1 (scale 1.25) — the
  snapping, live. The same 8-logical-px surface at scale 1.25 was measured earlier the same day
  with a completely black capture (every band mean exactly 0, zero frame-coloured pixels), while a
  7-logical-px one leaked 2576 pixels; a fresh capture-side control on eDP-1 was not possible
  because its armed workspace held a FULLSCREEN window, whose own exclusion box blacks the entire
  capture (it is drawn after the layer rects, so it covers the frame too — a stronger result, but
  not a discriminating one). Earlier rounds' numbers, for the record: round 4's inner-edge hairline
  read 0.0527 in the top band, and round 4b's first attempt left device row 1599 and column 2559
  frame-coloured. The bar (and any other unblanked layer) is visible in a capture as always; only
  windows on the armed workspace and the frame's own surfaces are blacked.
- **Presentation only.** The reminder shares the observer's race and its `kind == 1` filter; a
  missed event costs the cue, never protection. Since round 3 it also lags the *end* of a share by
  up to `LOCK_SHARE_GRACE_MS` (3 s) — same reasoning: the cue may linger, never under-report.
- **Tests.** Lua: install creates the layer rule with `no_screen_share` on the
  `omascape-lockframe` namespace, a second install neither duplicates it nor leaves a surviving
  disabled handle disabled, and a failing `hl.layer_rule` is reported through the install's own
  path while the observer and the publish still land. The hysteresis cases (round 3, driving the
  mock's `hl.timer`/`M.elapse`) now assert the state file through a `hl.__renames` counter — four
  flapping edges inside the grace window commit no further publish; an off edge takes effect only
  after the full `LOCK_SHARE_GRACE_MS` (checked at grace − 1 ms and at grace); a true edge inside
  the window cancels the pending timer for good; a sync publishes nothing at all. The suite reads
  `LOCK_SHARE_GRACE_MS` out of the same rendered chunk file rather than copying the number.
  Tier 1: the five pure functions, including the special-closed payload falling back to the active
  workspace, a malformed monitor object, `rgba(ff444480)` → `#80ff4444`, and
  `lockFrameSurfaceSize` over the scales that matter (1, 1.25, 1.5, 2 and the awkward 1.2 / 1.6 /
  rounded thirds, plus `NaN` and `0` degrading to `thickness + 1`). UI
  (`tests/ui/lock.qml`): the frame appears only while sharing an armed workspace, stays hidden for
  an unarmed workspace on the same monitor (positive control: the monitor switches to it), follows
  an open special workspace and drops when `activespecialv2>>,,TEST` closes it, takes its
  thickness and colour from non-default config values, disappears at `lockBorderSize: 0`, and a
  `workspacev2` raw event refreshes the monitor snapshot exactly once while an unrelated event
  does not. The fixture resolves the strips' layer-shell anchors into real geometry keyed to the
  exact anchor set, the `implicit*` surface line and the paint's own anchors and margins, so
  changing any of them fails `prepare.py` loudly instead of leaving a strip the geometry assertions
  would pass on.
  Round 4b adds: at stub scale 1.25 a 6 px paint gets 8 px surfaces on all four strips with the
  paint flush to each screen edge (top `y = 0`, bottom `y = 2`, left `x = 0`, right `x = 2`, and
  the top paint inset by 6 on both sides), while at stub scale 1 the same config gets the smallest
  7 px surfaces — so neither the snapping nor the flush paint can regress unnoticed; a monitor
  object REPLACED behind the same screen — swapped without notifying, the way
  `monitorFor()` behaves — is picked up after a refresh event. Lua: an install over a round-3
  `_G.omascape_lock` disables its `L.borders` rules and drops the table (and survives a handle
  whose `set_enabled` throws); an install where both the layer rule and the filesystem step fail
  reports the filesystem one, while each still reports when it fails alone.

## Edge cases

- **Share starts while the overview is open**: the state file flips → `FileView` fires →
  `rebuild()` → armed boxes drop tiles and captures, glyph appears. Ending reverses it.
- **Arming during a share**: rule enabled immediately; viewers see black; the box switches to
  the placeholder on the same rebuild.
- **Hyprland config reload**: Lua globals are lost, so the rules and the observer are gone until
  omascape sees `configreloaded` and re-installs (milliseconds). A capture in that window can
  see armed windows. Accepted and documented; a reload is a user action (theme change, config
  edit), not something a share triggers. Probed: globals do NOT survive a reload, so this window
  is real and the `configreloaded` re-install is load-bearing, not redundant.
- **Overview mapped before install completes** (a share running at shell start, and the overview
  opened within the few milliseconds before the install/sync chunks land): the overview's own
  surface is not layer-excluded (the only layer rule is the reminder frame's own namespace, never
  the overview's — see Verified facts) and so is
  visible in the capture like any other window. What matters is what it shows: the overview's
  thumbnails of armed windows are denied by the compositor (the per-workspace `window_rule`,
  Compositor side above — but only once the sync for that selector has actually run), so the
  only thing a viewer can see of the overview, even mapped this early, is unarmed thumbnails,
  icons and glyphs — never an armed window's live content. The rule is dispatched at shell start,
  long before a human can press SUPER+P, which bounds how early "before the sync has run" can
  realistically be.
- **Hyprland restart**: ends every share and every capture client. The shell process itself
  restarts along with the compositor, so re-install happens via `Component.onCompleted` on the
  fresh start — not a later `configreloaded` or `open()` on a process that survived the restart.
- **Shell restart / crash**: the compositor table and rules are untouched (install is
  idempotent), so protection never lapses. Stale intent (a disarm written to the file but the
  shell died before syncing) is corrected by the full-set sync on the next start.
- **Compositor crash leaving `share-state` = `1`**: the next install publishes `0` (counter
  resets). Until then the overview shows placeholders for armed boxes — a false positive, never
  a leak.
- **Shell start before the runtime dir exists**: `$XDG_RUNTIME_DIR/omascape` (holding
  `share-state`) does not exist until the install chunk's `mkdir -p` runs — asynchronously, after
  the `FileView` on it is already constructed. Quickshell watches a `FileView`'s *parent
  directory*; a directory that is missing at construction means the watch never attaches, so
  every later write to `share-state` (a share starting or ending) would go unseen for the rest of
  the session, with no error — nothing fails, it just silently never updates. Mitigated by
  `OmascapeLocks.refresh()` (`stateFile.reload()`, re-attaching just that watch), called ~400ms
  after every `lockInstall()` (a `Timer`, giving the directory time to appear) and once more
  directly in `open()`. The locks file does not need this: its directory (`~/.config/omarchy/`)
  is created well before omascape ever runs (Omarchy's own config layout), so its `FileView`'s
  watch attaches at construction — `refresh()` deliberately leaves it alone, both because it
  needs no help and because an explicit `reload()` re-emits `loaded` even with unchanged content
  (see Sync points), which would otherwise cost a redundant sync on every refresh.
- **Locks file missing on the first load**: resolves to `[]` (first run). **Missing on a later
  load** (the user deleted the file after a successful read): the in-memory set is kept, not
  reset to `[]` — only a first, never-yet-resolved load may treat "missing" as "empty".
  **Malformed, or any other read error, on the first load**: `armed` stays null (still
  unresolved); reported once per open via the notification path (a stuck `FileView` can re-emit
  `loaded` — or `onLoadFailed` again — without the error changing, and unlike the armed set a
  parse error has no "unchanged" case to compare against, so the guard is a simple once-per-open
  latch instead); `toggleInMemory` remains a no-op, and `lockToggleSelected()` tells the user, also once
  per open, why Ctrl+L is doing nothing ("omascape: locks file unreadable — fix or delete
  ~/.config/omarchy/omascape-locks.json") rather than silently swallowing the keypress.
  **Malformed, or any other read error, on a later load**: the last valid set is kept and
  enforced; reported once per open; the next successful write (the next accepted toggle)
  replaces the file with a fresh, valid one.
- **A selector whose workspace does not exist**: kept in the file and in the rule table; the
  rule matches nothing until the workspace returns; the badge shows only when its box exists.
- **Pinned windows**: reported on the workspace they were pinned from, but a pinned window
  follows the *active* workspace visually — so pinning a window on an armed workspace and then
  switching to an unarmed one exposes it, the same class of exposure as moving a window off an
  armed workspace (Scope/Out), and equally out of scope to prevent. Confirm and document with a
  live capture (below), not a claim.
- **Two monitors**: rules are per workspace, so the monitor does not matter.

## Tests

- **Tier 1, Lua behaviour suite** — each case runs the chunks in a **fresh Lua environment**
  (`_G` isolated per case; the current runner shares the host `_G` and must be changed), with
  stubs for `os.getenv`, `os.execute`, `os.rename`, `io.open` (in-memory files) and a mock `hl`
  with `window_rule` and `layer_rule` (the latter carries the reminder frame's namespace rule —
  see the addendum), named rule objects with `set_enabled`/`is_enabled`, and `on` with a
  `fire(event, ...)` helper. Cases: install twice → one active subscription, a publish on
  each install (value `0` on a fresh state), and the counter preserved across the second
  install; every install publishes the current value even over a pre-seeded stale share-state
  file (a fresh mock's file seeded `"1"` before `LOCK_INSTALL` runs → `"0"` after); sync `["3"]`
  → rule `omascape-lock-3` created enabled; sync `[]` → disabled,
  handle kept; sync `["3"]` again → same handle re-enabled (no second rule); sync
  `["3","special:scratchpad"]` → both enabled; share start → `1` published, rules untouched
  (already enabled); second start then one end → still `1`; last end → `0`; end without start
  → clamped at `0` (since round 3 the mock also models `hl.timer`, and every "end" case advances
  its fake clock past `LOCK_SHARE_GRACE_MS` — an end that leaves another share running arms no
  timer at all); a rule creation or setter throwing → one report naming it, every other
  selector still created/enabled and every stale rule still disabled (per-step pcall); a
  failed mkdir → install reports and `L.dir` stays unset so the next install retries; a failed
  write → no rename (state file unchanged);
  invalid selector dropped silently (no report — see Compositor side); `os.rename` failing → reported; `Logic.notifyLua(text)`
  round-trips a backslash, a quote and a newline into a single valid Lua string (escaped, then
  flattened) rather than breaking the chunk or losing the character; a text past the 200-character
  budget whose 200th raw character is a backslash still parses (the raw text is sliced BEFORE
  escaping, so a `\` never straddles the cut and gets split into a lone, chunk-breaking trailing
  backslash) and its rendered text ends with the truncation marker.
- **Tier 1, `tests/tst_layout.qml`**: a `placeholder` workspace yields a box with
  `placeholder: true` and no tiles; an `armed` one without placeholder is unchanged;
  `Logic.parseLocks` accepts a valid file (de-duplicated) and rejects a non-object, a missing
  `armed` array and a bad selector; `Logic.applyLocksTo(current, raw, status)` — missing on the
  first load → `[]`, changed; missing later → `current` kept, unchanged; an error or a malformed
  file on the first load → still `null`, reported; the same later → the previous value kept,
  reported; `"ok"` with a valid file → parsed, changed; **an identical reload (same selectors,
  same order) → unchanged**, a reordered or different set → changed, so a `watchChanges`/
  `reload()` echo does not read as a real edit; `Logic.toggleSelector(armed, sel)` adds,
  removes, and returns `null` (refused) for `null` armed or an invalid selector, without
  mutating its input.
- **Offscreen UI (`tests/ui/lock.qml`)**, with prepare.py replacing `OmascapeLocks.qml` by a
  stub (the fixture has no Quickshell.Io) whose `armed` starts null and offers `loadArmed`,
  `setSharing` and recorded `writes`/`writeAt` — real file watching and atomic writes are
  live-check items: Ctrl+L on ws 3 writes `armed: ["3"]` and dispatches install + sync
  with `"3"`; Ctrl+L again writes `[]` and dispatches a sync without it; the badge follows;
  **the sync is dispatched before the write** (`writeAt` records how many commands the
  compositor had already seen when `persist()` ran, and it equals the total after Ctrl+L
  returns — the write happened after the last dispatch, never before it); an armed box's tile
  falls back to `capMode: "icon"` outside a share too (armed alone is enough — the compositor
  denies the capture either way), unarmed tiles staying `"live"`; writing `1` to the state file
  additionally drops the armed box's tiles entirely (glyph shown) and `0` restores them;
  **positive control**: a query matching a window on ws 3 shows 1
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
  otherwise-empty workspace can be armed and keeps its badge; **loading the identical set twice
  in a row dispatches no second sync** (the stub shares `Logic.applyLocksTo`'s comparison, so
  this exercises the same code path a real `reload()` echo would hit).
- **Live (plan's first task, before any UI work)**: the rule-semantics sequence above with
  `grim` captures inspected as pixels (an unarmed workspace as positive control). (The
  `configreloaded` event name and the loss of globals on reload are already verified.) **Live (final)**: a
  real monitor share through the portal (e.g. a video-call test page or `wf-recorder`), armed
  workspaces black in the recorded output including the first frame after switching to them,
  the overview itself now visible in the recording (there is no overview-layer exclusion — see
  Verified facts), the overview's own tile for an armed window showing its app icon
  rather than the window's content (confirming the toplevel-export denial reaches the overview's
  own captures, not only a fresh `grim` of the workspace directly), the placeholder glyph
  in place of tiles once a share is active, and pinned-window exposure across a workspace switch
  (Edge cases) confirmed and documented, and the state file flipping on start and end.
