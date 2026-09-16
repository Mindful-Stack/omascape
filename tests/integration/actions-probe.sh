#!/usr/bin/env bash
# Live probe of the Hyprland 0.56.2 Lua facts the actions spec depends on. Read-only apart from
# floating one window it creates itself and moving workspaces between monitors (cases 3-4, which
# only run with two monitors connected). Reports FACT lines; asserts what it can actually observe
# rather than printing a value and trusting the reader to eyeball it.
set -euo pipefail
for bin in hyprctl jq; do command -v "$bin" >/dev/null || { echo "SKIP: $bin missing"; exit 0; }; done

# `hyprctl <unknown-subcommand>` prints "unknown request" and exits 0 on this build -- so a typo'd
# or removed `repl` subcommand would not fail loudly on its own. Prove it actually evaluates and
# returns a value before relying on it below.
hyprctl repl 'return 1' | grep -qx 1 || { echo "SKIP: hyprctl repl unavailable"; exit 0; }

# NOTE (discovered running this probe, 2026-09-16): `hyprctl eval <code>` never prints a Lua
# return value -- per `hyprctl --help` it only prints "ok" / "error: ...". `hyprctl repl <code>`
# is the subcommand documented to "issue a Lua string and print the result", confirmed against
# this build (`return 42` -> "42" via repl, "ok" via eval). Using `repl` here, not `eval`, is the
# one deviation from the original brief's script text.
#
# `ev()` fails loudly rather than laundering a failure into a plausible-looking value: it checks
# `hyprctl repl`'s own exit status directly (not through a pipe, so `set -e`/`pipefail` see it),
# and additionally treats an `error:`-prefixed reply as a failure in case a future build prints
# one with exit 0. Earlier drafts piped through `sed 's/^[^:]*: //'`, which strips exactly the
# `error: ` prefix and would have re-printed a Lua error as though it were the FACT's value.
ev() {
  local out
  out=$(hyprctl repl "$1") || { echo "FAIL: hyprctl repl: $out" >&2; exit 1; }
  case "$out" in
    error:*) echo "FAIL: hyprctl repl reported a Lua error: $out" >&2; exit 1 ;;
  esac
  printf '%s\n' "$out"
}

# --- shared cleanup ------------------------------------------------------------------------------
# One trap covers both mutations this script can make: the scratch window (cases 1-2) and monitor
# placement (cases 3-4). Armed before anything is created so an abort at any point still cleans up
# whatever had actually happened by then, rather than only what happens to run to completion.
A=""
DID_MOVE=0
DID_SWAP=0
MA=""; MB=""; HID=""
cleanup() {
  local rc=$?
  if [ -n "$A" ]; then
    hyprctl dispatch "hl.dsp.window.close({ window = \"address:$A\" })" >/dev/null 2>&1 || true
  fi
  # swap_monitors is its own inverse; undo it before undoing the move, then move the workspace
  # back to where it was. Plain `hyprctl dispatch workspace N` is a Lua syntax error in this
  # config mode and silently does nothing, so both restores go through hl.dsp in Lua form.
  if [ "$DID_SWAP" -eq 1 ]; then
    hyprctl dispatch 'hl.dsp.workspace.swap_monitors({ monitor1 = "'"$MA"'", monitor2 = "'"$MB"'" })' >/dev/null 2>&1 || true
  fi
  if [ "$DID_MOVE" -eq 1 ]; then
    hyprctl dispatch 'hl.dsp.workspace.move({ monitor = "'"$MA"'", workspace = "'"$HID"'" })' >/dev/null 2>&1 || true
  fi
  if [ "$DID_MOVE" -eq 1 ] || [ "$DID_SWAP" -eq 1 ]; then
    echo "NOTE: workspace placement was changed by this probe; a best-effort restore was dispatched -- verify by hand."
  fi
  exit "$rc"
}
trap cleanup EXIT

# --- 1/2 setup: a scratch window, never the user's focused one ---------------------------------
# Cases 1 and 2 both need a window that this script owns: case 1 needs a workspace it can prove is
# non-empty (rather than trusting whatever the user happens to have open), case 2 needs something
# safe to float. A missing `foot` or a window that never appears skips only cases 1-2; it must not
# cancel cases 3-4 below, which are independent of it.
SCRATCH_OK=0
if command -v foot >/dev/null; then
  foot -T omyview-probe-window -e sh -c 'sleep 60' >/dev/null 2>&1 &
  sleep 1.2
  A=$(hyprctl -j clients | jq -r '.[] | select(.title=="omyview-probe-window") | .address' | head -n1)
  if [ -n "$A" ]; then
    SCRATCH_OK=1
  else
    echo "SKIP: probe window did not appear; skipping cases 1 and 2"
  fi
else
  echo "SKIP: foot missing; skipping cases 1 and 2"
fi

if [ "$SCRATCH_OK" -eq 1 ]; then
  # --- 1. get_windows() shape --------------------------------------------------------------------
  # Probe the scratch window's own workspace, not just "the active one": that guarantees a
  # non-empty workspace by construction, so n=0 can never pass silently the way it would on a
  # workspace the script merely assumes has something on it.
  WS=$(hyprctl -j clients | jq -r --arg a "$A" '.[] | select(.address==$a) | .workspace.id')
  REPLY=$(ev "local w = hl.get_workspace(\"$WS\"); local t = w:get_windows(); local a = {}; for i, win in ipairs(t) do a[i] = tostring(win.address) end; return tostring(type(t)) .. ' n=' .. tostring(#t) .. ' first=' .. tostring(t[1] and t[1].address) .. ' all=' .. table.concat(a, ',')")
  echo "FACT get_windows: $REPLY"
  N=$(hyprctl -j clients | jq "[.[] | select(.workspace.id == $WS)] | length")
  echo "FACT hyprctl client count on ws $WS: $N"
  TYPE=$(printf '%s' "$REPLY" | awk '{print $1}')
  NLUA=$(printf '%s' "$REPLY" | sed -n 's/.* n=\([0-9][0-9]*\) .*/\1/p')
  FIRST=$(printf '%s' "$REPLY" | sed -n 's/.* first=\(.*\) all=.*/\1/p')
  ADDRS=$(printf '%s' "$REPLY" | sed -n 's/.*all=//p')
  # Property: #t must equal the client count hyprctl reports for this workspace and be > 0 (given
  # for free here, since the scratch window is on it); t[1].address must be non-nil; and the
  # scratch window's own address -- read independently from `hyprctl -j clients`, in its native
  # 0x... form -- must appear in the addresses get_windows() returned, so "carries the 0x prefix"
  # is a direct comparison against a known value, not an inference from one sample.
  if [ "$TYPE" != "table" ] || [ "$NLUA" != "$N" ] || [ "$N" -le 0 ]; then
    echo "FAIL: get_windows() shape mismatch (type=$TYPE lua-n=$NLUA hyprctl-n=$N)"
    exit 1
  fi
  case "$FIRST" in
    ""|nil) echo "FAIL: get_windows() first address is nil on a non-empty workspace"; exit 1 ;;
  esac
  case ",$ADDRS," in
    *",$A,"*) : ;;
    *) echo "FAIL: get_windows() addresses ($ADDRS) did not include the scratch window's address ($A) verbatim"; exit 1 ;;
  esac

  # --- 2. float on/off is absolute, not a toggle -------------------------------------------------
  # Against the same scratch window, never the user's focused window: this runs on a live desktop
  # someone is working on, and floating their window out from under them is not acceptable
  # collateral for a test. The scratch window is closed again at the end (the shared cleanup trap).
  flo() { hyprctl -j clients | jq -r ".[] | select(.address==\"$A\") | .floating"; }
  F0=$(flo)
  hyprctl dispatch 'hl.dsp.window.float({ window = "address:'"$A"'", action = "on" })' >/dev/null
  F1=$(flo)
  hyprctl dispatch 'hl.dsp.window.float({ window = "address:'"$A"'", action = "on" })' >/dev/null
  F2=$(flo)
  hyprctl dispatch 'hl.dsp.window.float({ window = "address:'"$A"'", action = "off" })' >/dev/null
  F3=$(flo)
  echo "FACT float base→$F0 on→$F1 on-again→$F2 off→$F3"
  # Property: F2 is what discriminates. A toggle implementation gives F1=true F2=false, and the
  # first assertion alone would pass on it.
  [ "$F1" = true ] && [ "$F2" = true ] && [ "$F3" = false ] || { echo "FAIL: action=on/off is not an absolute state"; exit 1; }
fi

# --- 3/4. monitor operations ---------------------------------------------------------------------
# Independent of the scratch window above: these run (or SKIP for lacking a second monitor)
# regardless of whether foot was available or cases 1-2 ran.
MONS=$(hyprctl -j monitors | jq 'length')
if [ "$MONS" -lt 2 ]; then
  echo "SKIP: cases 3 (workspace.move) and 4 (swap_monitors) need two monitors; run them on the nested rig"
  exit 0
fi
MA=$(hyprctl -j monitors | jq -r '.[0].name'); MB=$(hyprctl -j monitors | jq -r '.[1].name')
FOCUSED=$(hyprctl -j monitors | jq -r '.[] | select(.focused==true) | .name')

# --- 3. workspace.move ----------------------------------------------------------------------------
# HID must be a workspace that is actually hidden on MA -- not merely "the first positive id on
# MA", which can be the workspace the user is currently looking at -- so this exercises the
# "hidden" case the spec documents, not accidentally the "active" one. Guarded against jq handing
# back nothing (no hidden workspace on MA to test with).
MA_ACTIVE_BEFORE=$(hyprctl -j monitors | jq -r --arg m "$MA" '.[] | select(.name==$m) | .activeWorkspace.id')
HID=$(hyprctl -j workspaces | jq -r --arg m "$MA" --argjson act "$MA_ACTIVE_BEFORE" \
  '[.[] | select(.monitor==$m and .id>0 and .id!=$act)] | (.[0].id // empty)')
if [ -z "$HID" ]; then
  echo "SKIP: no hidden (non-active) workspace on $MA to test workspace.move"
else
  CUR=$(hyprctl -j cursorpos | jq -r '"\(.x),\(.y)"')
  hyprctl dispatch 'hl.dsp.workspace.move({ monitor = "'"$MB"'", workspace = "'"$HID"'" })' >/dev/null
  DID_MOVE=1
  sleep 0.3
  NOW_MON=$(hyprctl -j workspaces | jq -r ".[] | select(.id==$HID) | .monitor")
  NEWCUR=$(hyprctl -j cursorpos | jq -r '"\(.x),\(.y)"')
  # Precondition recorded explicitly so "no cursor warp" and "no warp was expected because the
  # workspace wasn't active on the focused monitor" cannot print identically: this run always
  # tests the hidden case (active-on-MA=false by construction), never the active-monitor case
  # that is expected to warp -- that case is not exercised here to avoid moving the workspace the
  # user is actually looking at.
  echo "FACT move: focused-monitor=$FOCUSED ws $HID was hidden on $MA (active-on-MA-before=false) -> moved to $MB -> now on $NOW_MON; cursor before=$CUR after=$NEWCUR"
fi

# --- 4. swap_monitors ------------------------------------------------------------------------------
MA_BEFORE=$(hyprctl -j monitors | jq -r --arg m "$MA" '.[] | select(.name==$m) | .activeWorkspace.id')
MB_BEFORE=$(hyprctl -j monitors | jq -r --arg m "$MB" '.[] | select(.name==$m) | .activeWorkspace.id')
hyprctl dispatch 'hl.dsp.workspace.swap_monitors({ monitor1 = "'"$MA"'", monitor2 = "'"$MB"'" })' >/dev/null
DID_SWAP=1
sleep 0.3
MA_AFTER=$(hyprctl -j monitors | jq -r --arg m "$MA" '.[] | select(.name==$m) | .activeWorkspace.id')
MB_AFTER=$(hyprctl -j monitors | jq -r --arg m "$MB" '.[] | select(.name==$m) | .activeWorkspace.id')
echo "FACT swap: focused-monitor=$FOCUSED before $MA=$MA_BEFORE $MB=$MB_BEFORE -> after $MA=$MA_AFTER $MB=$MB_AFTER"
