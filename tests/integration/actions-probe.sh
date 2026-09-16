#!/usr/bin/env bash
# Live probe of the Hyprland 0.56.2 Lua facts the actions spec depends on. Read-only apart from
# floating one window it creates itself and moving workspaces between monitors (cases 3-4, which
# only run with two monitors connected). Reports FACT lines; asserts only what it can observe.
set -euo pipefail
for bin in hyprctl jq; do command -v "$bin" >/dev/null || { echo "SKIP: $bin missing"; exit 0; }; done
# NOTE (discovered running this probe, 2026-09-16): `hyprctl eval <code>` never prints a Lua
# return value -- per `hyprctl --help` it only prints "ok" / "error: ...". `hyprctl repl <code>`
# is the subcommand documented to "issue a Lua string and print the result", confirmed against
# this build (`return 42` -> "42" via repl, "ok" via eval). Using `repl` here, not `eval`, is the
# one deviation from the brief's script text; it is required to make case 1's FACT line carry the
# actual return value instead of the literal string "ok" on every run.
ev() { hyprctl repl "$1" | sed 's/^[^:]*: //'; }

# --- 1. get_windows() shape -------------------------------------------------------------------
WS=$(hyprctl -j activeworkspace | jq -r .id)
echo "FACT get_windows: $(ev "local w = hl.get_workspace(\"$WS\") local t = w:get_windows() return tostring(type(t)) .. ' n=' .. tostring(#t) .. ' first=' .. tostring(t[1] and t[1].address)")"
# Property: #t must equal the client count hyprctl reports for this workspace, and t[1].address
# must be non-nil. A wrong indexing base shows up as n=0 with a non-empty workspace.
N=$(hyprctl -j clients | jq "[.[] | select(.workspace.id == $WS)] | length")
echo "FACT hyprctl client count on ws $WS: $N"

# --- 2. float on/off is absolute, not a toggle ------------------------------------------------
# Against a window the probe creates itself, never the user's focused window: this runs on a live
# desktop someone is working on, and floating their window out from under them is not acceptable
# collateral for a test. The scratch window is closed again at the end.
command -v foot >/dev/null || { echo "SKIP: foot missing for the float probe"; exit 0; }
foot -T omyview-probe-window -e sh -c 'sleep 60' >/dev/null 2>&1 &
sleep 1.2
A=$(hyprctl -j clients | jq -r '.[] | select(.title=="omyview-probe-window") | .address')
[ -n "$A" ] || { echo "SKIP: probe window did not appear"; exit 0; }
closeprobe() { hyprctl dispatch "hl.dsp.window.close({ window = \"address:$A\" })" >/dev/null 2>&1; }
trap closeprobe EXIT
flo() { hyprctl -j clients | jq -r ".[] | select(.address==\"$A\") | .floating"; }
hyprctl dispatch 'hl.dsp.window.float({ window = "address:'"$A"'", action = "on" })' >/dev/null
F1=$(flo)
hyprctl dispatch 'hl.dsp.window.float({ window = "address:'"$A"'", action = "on" })' >/dev/null
F2=$(flo)
hyprctl dispatch 'hl.dsp.window.float({ window = "address:'"$A"'", action = "off" })' >/dev/null
F3=$(flo)
echo "FACT float on→$F1 on-again→$F2 off→$F3"
# Property: F2 is what discriminates. A toggle implementation gives F1=true F2=false, and the
# first assertion alone would pass on it.
[ "$F1" = true ] && [ "$F2" = true ] && [ "$F3" = false ] || { echo "FAIL: action=on/off is not an absolute state"; exit 1; }

# --- 3/4. monitor operations ------------------------------------------------------------------
MONS=$(hyprctl -j monitors | jq 'length')
if [ "$MONS" -lt 2 ]; then
  echo "SKIP: cases 3 (workspace.move) and 4 (swap_monitors) need two monitors; run them on the nested rig"
  exit 0
fi
MA=$(hyprctl -j monitors | jq -r '.[0].name'); MB=$(hyprctl -j monitors | jq -r '.[1].name')
CUR=$(hyprctl -j cursorpos | jq -r '"\(.x),\(.y)"')
HID=$(hyprctl -j workspaces | jq -r --arg m "$MA" '[.[] | select(.monitor==$m)] | map(select(.id > 0)) | .[0].id')
hyprctl dispatch 'hl.dsp.workspace.move({ monitor = "'"$MB"'", workspace = "'"$HID"'" })' >/dev/null; sleep 0.3
echo "FACT move ws $HID → $MB: now on $(hyprctl -j workspaces | jq -r ".[] | select(.id==$HID) | .monitor"), cursor $(hyprctl -j cursorpos | jq -r '"\(.x),\(.y)"') (was $CUR)"
hyprctl dispatch 'hl.dsp.workspace.swap_monitors({ monitor1 = "'"$MA"'", monitor2 = "'"$MB"'" })' >/dev/null; sleep 0.3
echo "FACT after swap: $MA shows $(hyprctl -j monitors | jq -r --arg m "$MA" '.[] | select(.name==$m) | .activeWorkspace.id'), $MB shows $(hyprctl -j monitors | jq -r --arg m "$MB" '.[] | select(.name==$m) | .activeWorkspace.id')"
echo "NOTE: workspace placement was changed by this probe; restore it by hand."
