#!/usr/bin/env bash
# Tier 2 for the peek spec: the three claims no offscreen tier can reach. Runs in the nested rig
# (tests/integration/lib.sh). Cases 1-2 need only IPC; cases 3-4 need wtype/grim and SKIP loudly
# without them rather than reporting a result the rig did not observe.
set -euo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/integration/lib.sh
source "$(dirname "$0")/lib.sh"
require_bins hyprctl jq quickshell foot
start_nested
start_quickshell
ipc openOverview
a=$(spawn_window); b=$(spawn_window)
[[ -n "$a" && -n "$b" ]] || { echo "FAIL: could not spawn two windows"; dump; exit 1; }
ws=$(wsof "$a")
ipc selectWs "$ws"

# --- 1. the peek changes no compositor state ---------------------------------------------------
# The spec's strongest claim and the cheapest to check. Snapshot, hold, navigate, release,
# snapshot: the compositor JSON must be byte-identical. Diffed, never eyeballed.
snap() { hc clients -j | jq -S '[.[]|{address,at,size,workspace:.workspace.id,fullscreen,floating}]'
         hc workspaces -j | jq -S '[.[]|{id,monitor,windows}]'
         hc monitors -j | jq -S '[.[]|{name,activeWorkspace:.activeWorkspace.id}]'; }
before=$(snap)
ipc peekHold
[[ "$(ipc peekState | jq -r .peeking)" == "true" ]] || { echo "FAIL: peekHold did not open a hold"; dump; exit 1; }
ipc peekRelease
after=$(snap)
if [[ "$before" == "$after" ]]; then echo "PASS 1: a peek hold changed no compositor state"
else echo "FAIL 1: compositor state changed across a peek"; diff <(echo "$before") <(echo "$after") || true; exit 1; fi

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
rows=$(ipc peekRows)
n=$(echo "$rows" | jq 'length')
[[ "$n" == "2" ]] || { echo "FAIL 2: mini-map has $n rows, expected 2"; echo "$rows"; dump; exit 1; }
# Non-overlap on at least one axis, for the pair. Computed in jq so the assertion is on the data,
# not on a human reading two rects.
ov=$(echo "$rows" | jq '
  .[0] as $p | .[1] as $q |
  (($p.x + $p.w) <= ($q.x + 1) or ($q.x + $q.w) <= ($p.x + 1) or
   ($p.y + $p.h) <= ($q.y + 1) or ($q.y + $q.h) <= ($p.y + 1))')
fsmodes=$(echo "$rows" | jq -c '[.[].fullscreen]')
if [[ "$ov" == "true" ]]; then echo "PASS 2: mini-map rows do not overlap (fullscreen modes $fsmodes)"
else echo "FAIL 2: the fullscreen peek tile covers its neighbour"; echo "$rows"; exit 1; fi
fs_toggle "$a"
wait_fs "$a" 0

# --- 3. live pixels ----------------------------------------------------------------------------
# One screenshot proves only that SOMETHING was drawn, which the icon fallback also satisfies. So
# capture twice during one hold of a window whose content changes, and require the frames to
# DIFFER. Skipped, not faked, without grim.
if ! command -v grim >/dev/null 2>&1; then
  echo "SKIP 3: grim missing; cannot tell a live capture from the icon fallback"
else
  hc dispatch 'hl.dsp.exec_cmd("foot -e sh -c \"while :; do date +%%N; sleep 0.2; done\"")' >/dev/null
  sleep 1.5
  ipc peekHold
  WAYLAND_DISPLAY="$socket" grim "$tmp/peek-1.png" && sleep 1.2 && WAYLAND_DISPLAY="$socket" grim "$tmp/peek-2.png"
  ipc peekRelease
  if cmp -s "$tmp/peek-1.png" "$tmp/peek-2.png"; then
    echo "FAIL 3: two frames 1.2s apart are identical — the peek is not showing live pixels"; exit 1
  else echo "PASS 3: the peek's content changed between frames (live capture)"; fi
fi

# --- 4. real auto-repeat ------------------------------------------------------------------------
# The only path to a genuine isAutoRepeat event. Whether Hyprland generates repeats for a wtype
# virtual keyboard is MEASURED here, not assumed: if no repeat is observed the guard is reported
# UNVERIFIED rather than passed.
if ! command -v wtype >/dev/null 2>&1; then
  echo "SKIP 4: wtype missing; real auto-repeat has no other path in this rig"
else
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
  # exists to prevent. UNVERIFIED and PASS are mutually exclusive outcomes here.
  if [[ "$(echo "$held" | jq -r .peeking)" != "true" ]]; then
    echo "UNVERIFIED 4: the held key never opened a peek — wtype may not reach the overlay's"
    echo "              keyboard focus in this rig. The guard is NOT established; do not record"
    echo "              it as verified."
  elif [[ "$(echo "$done_" | jq -r .peeking)" != "false" ]]; then
    echo "FAIL 4: the peek survived the release"; exit 1
  else
    echo "PASS 4: a 2s held Space opened one peek and closed on release"
  fi
fi
echo "peek-probe: done"
