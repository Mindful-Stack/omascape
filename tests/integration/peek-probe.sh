#!/usr/bin/env bash
# Tier 2 for the peek spec: the three claims no offscreen tier can reach. Runs in the nested rig
# (tests/integration/lib.sh). Cases 1-2 need only IPC; cases 3-4 need wtype/grim and SKIP loudly
# without them rather than reporting a result the rig did not observe.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck disable=SC2119   # require_bins takes no arguments; drag.sh/fullscreen.sh call it bare
require_bins
start_nested
start_quickshell
ipc openOverview
# `a` is fullscreen-toggled by case 2 and peeked as a window by case 1's second pass; `b` exists so
# case 2's workspace has two windows to place (one recovered-slot fullscreen, one plain tiled) and
# doubles as case 1's mid-hold retarget target ("navigate" below) — neither is spawned only to be
# existence-checked.
a=$(spawn_window); b=$(spawn_window)
[[ -n "$a" && -n "$b" ]] || { echo "FAIL: could not spawn two windows"; dump; exit 1; }
ws=$(wsof "$a")
ipc selectWs "$ws"

# --- 1. the peek changes no compositor state ---------------------------------------------------
# The spec's strongest claim and the cheapest to check. Snapshot, hold, navigate, release,
# snapshot: the compositor JSON must be byte-identical. Diffed, never eyeballed. Includes the
# focused window and the cursor position (review round 2, item 5) — focus/cursor theft is exactly
# what fullscreen.sh:44-51 guards elsewhere in this rig, and the peek's own clauses touch neither,
# so a regression there deserves the same coverage.
snap() { hc clients -j | jq -S '[.[]|{address,at,size,workspace:.workspace.id,fullscreen,floating}]'
         hc workspaces -j | jq -S '[.[]|{id,monitor,windows}]'
         hc monitors -j | jq -S '[.[]|{name,activeWorkspace:.activeWorkspace.id}]'
         hc activewindow -j | jq -S '{address}'
         hc cursorpos -j | jq -S .; }
# Run once per target kind (review round 2, item 2: a bare IPC run never peeked a WINDOW at all —
# `pointerLive` is always false in this rig, so `Logic.target` fell through to `selectedId` on
# every prior run). `label` names which target kind this pass covers in its PASS/FAIL line.
run_case1() {
    local label="$1" before after
    before=$(snap)
    ipc peekHold
    [[ "$(ipc peekState | jq -r .peeking)" == "true" ]] || {
        echo "FAIL 1 ($label): peekHold did not open a hold"; dump; exit 1; }
    # Navigate mid-hold: `b` is a live retarget (Logic.target's cursorAddress branch), the
    # production path Tab/arrows drive. A real navigation must not touch the compositor either —
    # this is what actually justifies the word "navigate" in the comment above.
    ipc setCursor "$b"
    ipc peekRelease
    after=$(snap)
    if [[ "$before" == "$after" ]]; then echo "PASS 1 ($label): a peek hold changed no compositor state"
    else echo "FAIL 1 ($label): compositor state changed across a peek"
         diff <(echo "$before") <(echo "$after") || true; exit 1; fi
}
ipc setCursor ""                       # no cursor target: resolveTarget() falls through to selectedId
run_case1 "workspace target"
ipc setCursor "$a"                     # cursorAddress outranks selectedId: resolveTarget() is now window a
run_case1 "window target"
ipc setCursor ""                       # leave a clean baseline for the cases below

# --- 2. a workspace mini-map places a fullscreen window in its slot -----------------------------
# Task 1 and 2's parity argument, observed end to end: with one fullscreen and one tiled window,
# the mini-map must report TWO non-overlapping rows. A peek that skipped slot recovery reports the
# fullscreen row spanning the box and swallowing its neighbour.
#
# NOTE: the brief's original step 2 text dispatched `window.fullscreen` with a bare
# `action = "on"|"off"`. Every other call site in this repo (production `logic.js:603`,
# `fullscreen.sh`, `probe-fullscreen.sh`) dispatches `{ window = ..., mode = "fullscreen",
# action = "toggle" }` — there is no on/off form attested anywhere against this Hyprland build.
# Using the same toggle form here (the window is freshly spawned, so its starting state is known
# non-fullscreen) achieves the same on/off effect without inventing an unverified dispatcher call.
fs_toggle() { hc dispatch "hl.dsp.window.fullscreen({window='address:$1', mode='fullscreen', action='toggle'})" >/dev/null; }
fs_toggle "$a"
wait_fs "$a" 2
# Poll peekRows() rather than trust one read (review round 2, item 3): rebuild() alone re-reads
# Quickshell's cached toplevel data; the actual refresh (requestRefresh() -> Hyprland.
# refreshToplevels(), now called inside peekRows() itself) is asynchronous, so the model can still
# lag hyprctl's own view for a few ticks on a slower machine — `wait_fs` above only proves hyprctl
# itself has the new state, never that Quickshell's copy of it has caught up.
rows="[]"
for _ in $(seq 1 40); do
    rows=$(ipc peekRows)
    echo "$rows" | jq -e '[.[].fullscreen] | any(. > 0)' >/dev/null 2>&1 && break
    sleep 0.1
done
fsmodes=$(echo "$rows" | jq -c '[.[].fullscreen]')
# Fail loudly on a stale model instead of letting the overlap check pass for the trivial reason
# that two ordinary tiles never overlap — precisely how the race this probe fixed once already
# (peekRows() lacking its own rebuild()) slipped through as a false PASS.
echo "$fsmodes" | jq -e 'any(. > 0)' >/dev/null 2>&1 || {
    echo "FAIL 2: no row is fullscreen or maximized: model stale, case 2 did not exercise slot recovery"
    echo "$rows"; dump; exit 1; }
n=$(echo "$rows" | jq 'length')
[[ "$n" == "2" ]] || { echo "FAIL 2: mini-map has $n rows, expected 2"; echo "$rows"; dump; exit 1; }
# Non-overlap on at least one axis, for the pair. Computed in jq so the assertion is on the data,
# not on a human reading two rects.
ov=$(echo "$rows" | jq '
  .[0] as $p | .[1] as $q |
  (($p.x + $p.w) <= ($q.x + 1) or ($q.x + $q.w) <= ($p.x + 1) or
   ($p.y + $p.h) <= ($q.y + 1) or ($q.y + $q.h) <= ($p.y + 1))')
if [[ "$ov" == "true" ]]; then echo "PASS 2: mini-map rows do not overlap (fullscreen modes $fsmodes)"
else echo "FAIL 2: the fullscreen peek tile covers its neighbour"; echo "$rows"; exit 1; fi
fs_toggle "$a"
wait_fs "$a" 0

# --- 3. live pixels ----------------------------------------------------------------------------
# One screenshot proves only that SOMETHING was drawn, which the icon fallback also satisfies. So
# capture twice during one hold of a window whose content changes, and require the frames to
# DIFFER. Skipped, not faked, without grim.
#
# Review round 2, item 1 found this case vacuous as first written, for three compounding reasons,
# all fixed below: (a) an UNCROPPED grim capture grabs the whole nested screen, so churn anywhere
# on it (a tile appear animation, the peek's own fade-in) satisfies `cmp` regardless of what the
# peek itself is showing — now cropped to the peek's own fitted box, read fresh over IPC
# (`peekBox()`) rather than hardcoded, since a literal geometry would silently stop matching the
# peek the moment any layout constant changed; (b) `date +%%N` (double `%`, a leftover escape from
# the plan's heredoc) prints the literal string "%N", not nanoseconds — fixed to `date +%N`;
# (c) the hold was never asserted open before capturing, so a cancelled hold passed too — now
# asserted via `peekState`, the same way case 1 already does.
if ! command -v grim >/dev/null 2>&1; then
  echo "SKIP 3: grim missing; cannot tell a live capture from the icon fallback"
else
  # A third, animating scratch window — spawned and polled for the same way spawn_window() does it
  # (review round 2, item 7: a bare `sleep 1.5` guessed at a delay instead of observing the window
  # actually arrive), rather than reused from `a`/`b`, which case 2 has just fullscreen-toggled.
  old=$(hc clients -j | jq '[.[].address]')
  hc dispatch 'hl.dsp.exec_cmd("foot -e sh -c \"while :; do date +%N; sleep 0.2; done\"")' >/dev/null
  c=""
  for _ in $(seq 1 40); do
      c=$(hc clients -j | jq -r --argjson old "$old" 'first(.[]|.address as $a|select($old|index($a)|not)|.address)')
      [[ -z "$c" ]] || break
      sleep 0.1
  done
  [[ -n "$c" ]] || { echo "FAIL 3: animating scratch window did not appear"; dump; exit 1; }
  sleep 1.5   # let its first paints (and their scrollback churn) settle before it is the capture target
  # Peek WINDOW `c` specifically (review round 2, item 2): without this, `resolveTarget()` falls
  # through to the selected WORKSPACE, and the single large `ScreencopyView` case 3 is named after
  # — the window-peek path — is never exercised at this tier at all.
  ipc setCursor "$c"
  ipc peekHold
  [[ "$(ipc peekState | jq -r .peeking)" == "true" ]] || { echo "FAIL 3: peekHold did not open a hold"; dump; exit 1; }
  box=$(ipc peekBox)
  [[ "$box" != "null" ]] || { echo "FAIL 3: peekBox() returned no box for an open hold"; dump; exit 1; }
  read -r bx by bw bh < <(echo "$box" | jq -r '"\(.x) \(.y) \(.w) \(.h)"')
  [[ "$bw" -gt 0 && "$bh" -gt 0 ]] || { echo "FAIL 3: peekBox() returned a degenerate box ($box)"; dump; exit 1; }
  geom="${bx},${by} ${bw}x${bh}"
  WAYLAND_DISPLAY="$socket" grim -g "$geom" "$tmp/peek-1.png"
  sleep 1.2
  WAYLAND_DISPLAY="$socket" grim -g "$geom" "$tmp/peek-2.png"
  ipc peekRelease
  ipc setCursor ""
  if cmp -s "$tmp/peek-1.png" "$tmp/peek-2.png"; then
    echo "FAIL 3: two frames 1.2s apart, cropped to the peek's own box ($geom), are identical — the peek is not showing live pixels"; exit 1
  else echo "PASS 3: the peek's content changed between frames, cropped to its own box (live capture)"; fi
fi

# --- 4. real auto-repeat ------------------------------------------------------------------------
# The only path to a genuine isAutoRepeat event. Whether Hyprland generates repeats for a wtype
# virtual keyboard is MEASURED here, not assumed: if no repeat is observed the guard is reported
# UNVERIFIED rather than passed.
if ! command -v wtype >/dev/null 2>&1; then
  echo "SKIP 4: wtype missing; real auto-repeat has no other path in this rig"
else
  ipc setCursor ""                     # clean baseline: a real Space peeks the selected workspace, not case 3's window
  ipc selectWs "$ws"
  sel_before=$(ipc peekState)
  WAYLAND_DISPLAY="$socket" wtype -P space
  sleep 2                                    # well past any repeat delay
  held=$(ipc peekState)
  WAYLAND_DISPLAY="$socket" wtype -p space
  sleep 0.3
  done_=$(ipc peekState)
  echo "FACT 4: before=$sel_before held=$held after=$done_"
  # A proper if/elif, not `A || { ...}` followed by an unconditional PASS line: the brief's
  # original draft printed UNVERIFIED and then fell through to print PASS 4 regardless, which is
  # exactly the dishonest outcome ("recorded as verified when it was never exercised") this case
  # exists to prevent. UNVERIFIED and PASS are mutually exclusive outcomes here. Note on scope
  # (spec's Verified facts section has the full account): this case cannot distinguish a GUARDED
  # auto-repeat from an UNGUARDED one that happens to re-enter the same press branch harmlessly —
  # it only establishes that a real held key opens a peek and a real release closes it — not a
  # COUNT of openings, which is exactly what "distinguish guarded from unguarded" would need.
  # Repeat-*swallowing* itself is pinned offscreen, in tests/ui/peek.qml's mutation-verified
  # second-press proxy, not here.
  if [[ "$(echo "$held" | jq -r .peeking)" != "true" ]]; then
    echo "UNVERIFIED 4: the held key never opened a peek — wtype may not reach the overlay's"
    echo "              keyboard focus in this rig. The guard is NOT established; do not record"
    echo "              it as verified."
  elif [[ "$(echo "$done_" | jq -r .peeking)" != "false" ]]; then
    echo "FAIL 4: the peek survived the release"; exit 1
  else
    echo "PASS 4: a 2s held Space opened a peek and closed on release"
  fi
fi
echo "peek-probe: done"
